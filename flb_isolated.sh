# Backup previous version
cp -p flb-jeprof-isolated.sh \
  "flb-jeprof-isolated.sh.bak.$(date +%Y%m%d%H%M%S)" \
  2>/dev/null || true

cat > flb-jeprof-isolated.sh <<'SCRIPT'
#!/usr/bin/env bash
# One-shot, isolated jeprof analysis for a Fluent Bit pod on OpenShift.
set -Eeuo pipefail
umask 077

TARGET="${1:-}"
if [[ -z "$TARGET" ]]; then
  echo "Usage: $0 <fluent-bit-pod>" >&2
  echo "Optional: NS=fluent OUT_DIR=~/flb-heap-reports KEEP_POD=1 $0 <pod>" >&2
  exit 2
fi

NS="${NS:-}"
OUT_DIR="${OUT_DIR:-$HOME/flb-heap-reports}"
KEEP_POD="${KEEP_POD:-0}"
K=(kubectl)
[[ -z "$NS" ]] || K+=(-n "$NS")

command -v kubectl >/dev/null || {
  echo "ERROR: kubectl not found" >&2
  exit 1
}

mkdir -p "$OUT_DIR"

# ============================================================
# 1. Read Target Fluent Bit Container Identity
# ============================================================

NODE="$("${K[@]}" get pod "$TARGET" \
  -o jsonpath='{.spec.nodeName}')"

IMAGE="$("${K[@]}" get pod "$TARGET" \
  -o jsonpath='{.spec.containers[?(@.name=="fluent-bit")].image}')"

IMAGE_ID="$("${K[@]}" get pod "$TARGET" \
  -o jsonpath='{.status.containerStatuses[?(@.name=="fluent-bit")].imageID}')"

SA="$("${K[@]}" get pod "$TARGET" \
  -o jsonpath='{.spec.serviceAccountName}')"

STARTED="$("${K[@]}" get pod "$TARGET" \
  -o jsonpath='{.status.containerStatuses[?(@.name=="fluent-bit")].state.running.startedAt}')"

CONTAINER_ID="$("${K[@]}" get pod "$TARGET" \
  -o jsonpath='{.status.containerStatuses[?(@.name=="fluent-bit")].containerID}')"

if [[ -z "$NODE" || -z "$IMAGE" ||
      -z "$STARTED" || -z "$CONTAINER_ID" ]]; then
  echo "ERROR: Target Fluent Bit container is not currently running." >&2
  exit 1
fi

if [[ "$IMAGE" != *heap-prof-libunwind* ]]; then
  echo "ERROR: Unexpected image: $IMAGE" >&2
  exit 1
fi

SA="${SA:-default}"
START_EPOCH="$(date -u -d "$STARTED" +%s)"

# Prefer the exact image digest when available.
ANALYSIS_IMAGE="$IMAGE"

if [[ "$IMAGE_ID" =~ ^[^[:space:]]+@sha256:[a-fA-F0-9]{64}$ ]]; then
  ANALYSIS_IMAGE="$IMAGE_ID"
fi

SHORT="${TARGET#fluent-bit-}"
STAMP="$(date -u +%m%d%H%M%S)"

ANALYZER="flb-jeprof-${SHORT}-${STAMP}-$$"

MANIFEST="$OUT_DIR/$ANALYZER.yaml"
REPORT="$OUT_DIR/$ANALYZER.txt"

# ============================================================
# 2. Script Executed Inside the Analyzer Container
# ============================================================

ANALYZER_CODE="$(cat <<'IN_ANALYZER'
set -eu
umask 077

export HOME=/work
export TMPDIR=/work
export TMP=/work
export TEMP=/work
export JEPROF_TMPDIR=/work

BIN=/fluent-bit/bin/fluent-bit
PREFIX="/profiles/${TARGET_POD}"

FILTER='^(prof_backtrace_impl|je_prof_backtrace|je_prof_tctx_create|je_malloc_default|prof_alloc_prep)$'

echo '=== ANALYZER START ==='
date -u '+UTC %Y-%m-%dT%H:%M:%SZ'

echo "Pod: $TARGET_POD"
echo "Target started epoch: $TARGET_START_EPOCH"
echo "Expected profile prefix: $PREFIX"
echo "Binary: $BIN"

test -r "$BIN" || {
  echo 'ERROR: Matching Fluent Bit binary not readable'
  exit 10
}

command -v jeprof >/dev/null || {
  echo 'ERROR: jeprof missing'
  exit 11
}

test -d /profiles || {
  echo 'ERROR: HostPath directory not mounted'
  exit 12
}

ls -ld /profiles

# ============================================================
# 3. Find Completed Profiles from Current Process
# ============================================================

find /profiles \
  -maxdepth 1 \
  -type f \
  -name "${TARGET_POD}.*.i*.heap" \
  -mmin +1 \
  -size +0c \
  -printf '%T@ %p\n' \
  > /work/all-profiles.txt

awk -v t="$TARGET_START_EPOCH" \
  '$1 + 0 >= t + 0 {print $2}' \
  /work/all-profiles.txt |
  sort -V > /work/current-profiles.txt

COUNT="$(wc -l < /work/current-profiles.txt | tr -d ' ')"

echo "Current-process complete interval profiles: $COUNT"

if [ "$COUNT" -lt 1 ]; then
  echo 'ERROR: No matching completed .i.heap files.'
  echo 'Directory sample (names only):'
  ls -1 /profiles | head -30 || true
  exit 13
fi

FIRST="$(head -1 /work/current-profiles.txt)"
LAST="$(tail -1 /work/current-profiles.txt)"

echo "First: $FIRST"
echo "Last:  $LAST"

# ============================================================
# 4. Analyze Latest Heap
# ============================================================

echo '=== LAST PROFILE: IN-USE BYTES ==='

if timeout 180 jeprof \
  --text \
  --show_bytes \
  --inuse_space \
  --exclude="$FILTER" \
  "$BIN" "$LAST" \
  > /work/latest.txt 2>&1; then

  sed -n '1,70p' /work/latest.txt

else
  RC=$?
  sed -n '1,120p' /work/latest.txt
  echo "ERROR: jeprof latest failed, exit=$RC"
  exit "$RC"
fi

# ============================================================
# 5. Analyze Heap Growth
# ============================================================

if [ "$COUNT" -ge 2 ] && [ "$FIRST" != "$LAST" ]; then

  echo '=== HEAP DIFF: LAST - FIRST (IN-USE BYTES) ==='

  if timeout 180 jeprof \
    --text \
    --show_bytes \
    --inuse_space \
    --exclude="$FILTER" \
    --base="$FIRST" \
    "$BIN" "$LAST" \
    > /work/diff.txt 2>&1; then

    sed -n '1,95p' /work/diff.txt

  else
    RC=$?
    sed -n '1,120p' /work/diff.txt
    echo "ERROR: jeprof diff failed, exit=$RC"
    exit "$RC"
  fi

else
  echo 'Only one completed profile: cannot calculate Diff.'
fi

echo '=== ANALYSIS COMPLETE ==='

IN_ANALYZER
)"

# ============================================================
# 6. Generate an Isolated Analysis Pod
# ============================================================

cat > "$MANIFEST" <<EOF
apiVersion: v1
kind: Pod

metadata:
  name: $ANALYZER
  labels:
    app: flb-jeprof-analysis

spec:
  nodeName: $NODE
  serviceAccountName: $SA
  automountServiceAccountToken: false
  restartPolicy: Never

  containers:
    - name: analyzer

      image: $ANALYSIS_IMAGE
      imagePullPolicy: IfNotPresent

      command: ["/bin/sh", "-eu"]
      args:
        - |
$(printf '%s\n' "$ANALYZER_CODE" | sed 's/^/          /')

      env:
        - name: TARGET_POD
          value: "$TARGET"

        - name: TARGET_START_EPOCH
          value: "$START_EPOCH"

      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
        seccompProfile:
          type: RuntimeDefault

      resources:
        requests:
          cpu: 100m
          memory: 128Mi

        limits:
          cpu: 500m
          memory: 1Gi

      volumeMounts:
        - name: profiles
          mountPath: /profiles
          readOnly: true

        - name: scratch
          mountPath: /work

  volumes:
    - name: profiles
      hostPath:
        path: /var/log/fluent-bit-heap-profiles
        type: Directory

    - name: scratch
      emptyDir:
        sizeLimit: 256Mi
EOF

# ============================================================
# 7. Create the Analyzer Pod
# ============================================================

{
  echo "Report UTC: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Target: $TARGET"
  echo "Node: $NODE"
  echo "Image: $ANALYSIS_IMAGE"
  echo "Container ID: $CONTAINER_ID"
  echo "Target started: $STARTED"
  echo "Analyzer: $ANALYZER"
  echo "Manifest: $MANIFEST"
  echo "== CREATE ANALYZER POD =="
} | tee "$REPORT"

if ! "${K[@]}" create -f "$MANIFEST" 2>&1 |
  tee -a "$REPORT"; then

  echo "ERROR: Pod creation failed." | tee -a "$REPORT"
  exit 1
fi

# ============================================================
# 8. Wait for Pod Completion
# ============================================================

PHASE="Pending"

for ((i=0; i<150; i++)); do

  PHASE="$(
    "${K[@]}" get pod "$ANALYZER" \
      -o jsonpath='{.status.phase}' 2>/dev/null || true
  )"

  if [[ "$PHASE" == Succeeded || "$PHASE" == Failed ]]; then
    break
  fi

  sleep 2
done

echo "== POD PHASE: ${PHASE:-unknown} ==" | tee -a "$REPORT"

# ============================================================
# 9. Collect Actual Logs and Exit Code
# ============================================================

echo "== ANALYZER LOGS ==" | tee -a "$REPORT"

"${K[@]}" logs "$ANALYZER" \
  -c analyzer --timestamps 2>&1 |
  tee -a "$REPORT" || true

EXIT_CODE="$(
  "${K[@]}" get pod "$ANALYZER" \
    -o jsonpath='{.status.containerStatuses[?(@.name=="analyzer")].state.terminated.exitCode}' \
    2>/dev/null || true
)"

FINAL_STARTED="$(
  "${K[@]}" get pod "$TARGET" \
    -o jsonpath='{.status.containerStatuses[?(@.name=="fluent-bit")].state.running.startedAt}' \
    2>/dev/null || true
)"

echo "Analyzer phase=$PHASE exitCode=${EXIT_CODE:-unknown}" |
  tee -a "$REPORT"

# ============================================================
# 10. Failure Handling
# ============================================================

if [[ "$PHASE" != Succeeded ||
      "$EXIT_CODE" != 0 ||
      "$FINAL_STARTED" != "$STARTED" ]]; then

  echo '== POD EVENTS / STATE ==' | tee -a "$REPORT"

  "${K[@]}" get pod "$ANALYZER" \
    -o jsonpath='{range .status.containerStatuses[*]}{.name}{" state="}{.state.terminated.reason}{" exit="}{.state.terminated.exitCode}{" waiting="}{.state.waiting.reason}{" message="}{.state.waiting.message}{"\n"}{end}' \
    2>&1 | tee -a "$REPORT" || true

  "${K[@]}" describe pod "$ANALYZER" 2>&1 |
    sed -n '/Events:/,$p' |
    tee -a "$REPORT" || true

  if [[ "$FINAL_STARTED" != "$STARTED" ]]; then
    echo 'ERROR: Fluent Bit restarted during analysis; comparison is not trustworthy.' |
      tee -a "$REPORT"
  fi

  echo "FAILED or incomplete; analyzer preserved: $ANALYZER" |
    tee -a "$REPORT"

  echo "Saved report: $REPORT"
  exit 1
fi

# ============================================================
# 11. Success and Cleanup
# ============================================================

echo 'ANALYSIS SUCCEEDED' | tee -a "$REPORT"

if [[ "$KEEP_POD" == 1 ]]; then

  echo "Analyzer preserved (KEEP_POD=1): $ANALYZER" |
    tee -a "$REPORT"

else

  "${K[@]}" delete pod "$ANALYZER" --wait=false 2>&1 |
    tee -a "$REPORT" || true

fi

echo "Saved report: $REPORT"

SCRIPT

chmod +x flb-jeprof-isolated.sh
bash -n flb-jeprof-isolated.sh && echo "BASH SYNTAX PASSED"
