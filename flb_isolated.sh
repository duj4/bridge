cp -p flb-jeprof-isolated.sh \
  "flb-jeprof-isolated.sh.bak.$(date +%Y%m%d%H%M%S)" \
  2>/dev/null || true

cat > flb-jeprof-isolated.sh <<'SCRIPT'
#!/usr/bin/env bash
# Fluent Bit jeprof isolated analyzer v3
# No hostPath: stream selected heap files between Pods.

set -Eeuo pipefail
umask 077

TARGET="${1:-}"
NS="${NS:-}"
OUT_DIR="${OUT_DIR:-$HOME/flb-heap-reports}"
KEEP_POD="${KEEP_POD:-0}"
PROFILE_DIR="${PROFILE_DIR:-/var/log/fluent-bit-heap-profiles}"

if [[ ! "$TARGET" =~ ^fluent-bit-[a-z0-9]+$ ]]; then
  echo "Usage: $0 fluent-bit-<pod-suffix>" >&2
  exit 2
fi

command -v kubectl >/dev/null || {
  echo "ERROR: kubectl missing" >&2
  exit 1
}

mkdir -p "$OUT_DIR"

K=(kubectl)
[[ -z "$NS" ]] || K+=(-n "$NS")

# ============================================================
# 1. Read target container identity
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

CID="$("${K[@]}" get pod "$TARGET" \
  -o jsonpath='{.status.containerStatuses[?(@.name=="fluent-bit")].containerID}')"

[[ -n "$NODE" && -n "$IMAGE" &&
   -n "$STARTED" && -n "$CID" ]] || {
  echo "ERROR: Fluent Bit is not running" >&2
  exit 1
}

[[ "$IMAGE" == *5.1.5-heap-prof-libunwind* ]] || {
  echo "ERROR: Unexpected image: $IMAGE" >&2
  exit 1
}

[[ "$PROFILE_DIR" == /var/log/fluent-bit-heap-profiles ]] || {
  echo "ERROR: Unexpected profile directory" >&2
  exit 1
}

SA="${SA:-default}"
START_EPOCH="$(date -u -d "$STARTED" +%s)"

ANALYSIS_IMAGE="$IMAGE"

IMAGE_ID="${IMAGE_ID#docker-pullable://}"
IMAGE_ID="${IMAGE_ID#docker://}"

if [[ "$IMAGE_ID" =~ ^[^[:space:]]+@sha256:[[:xdigit:]]{64}$ ]]; then
  ANALYSIS_IMAGE="$IMAGE_ID"
fi

STAMP="$(date -u +%m%d%H%M%S)"
ANALYZER="flb-jeprof-${TARGET#fluent-bit-}-${STAMP}"

REPORT="$OUT_DIR/$ANALYZER.txt"
MANIFEST="$OUT_DIR/$ANALYZER.yaml"

POD_CREATED=0

exec > >(tee -a "$REPORT") 2>&1

# ============================================================
# 2. Cleanup and failure diagnostics
# ============================================================

on_exit() {
  local rc=$?
  trap - EXIT

  if (( POD_CREATED )); then
    if (( rc == 0 )); then
      if [[ "$KEEP_POD" == 1 ]]; then
        echo "Analyzer preserved: $ANALYZER"
      else
        "${K[@]}" delete pod "$ANALYZER" \
          --wait=false \
          --ignore-not-found=true || true
      fi
    else
      echo "=== ANALYSIS FAILURE: exit=$rc ==="

      "${K[@]}" get pod "$ANALYZER" -o wide || true

      "${K[@]}" get pod "$ANALYZER" \
        -o jsonpath='{range .status.containerStatuses[*]}{.name}{" reason="}{.state.waiting.reason}{.state.terminated.reason}{" exit="}{.state.terminated.exitCode}{"\n"}{end}' \
        || true

      "${K[@]}" logs "$ANALYZER" \
        -c analyzer --tail=80 || true

      "${K[@]}" describe pod "$ANALYZER" |
        sed -n '/Events:/,$p' || true

      echo "Analysis Pod preserved: $ANALYZER"
    fi
  fi

  echo "Report: $REPORT"
  exit "$rc"
}

trap on_exit EXIT

echo "Target: $TARGET"
echo "Node: $NODE"
echo "Image: $ANALYSIS_IMAGE"
echo "Container ID: $CID"
echo "Process started: $STARTED"
echo "Analyzer: $ANALYZER"
echo "Report UTC: $(date -u +%FT%TZ)"

# ============================================================
# 3. Discover completed profiles from current process
# ============================================================

echo "=== DISCOVER CURRENT-PROCESS PROFILES ==="

RAW="$(
  "${K[@]}" exec "$TARGET" -c fluent-bit -- \
    find "$PROFILE_DIR" \
      -maxdepth 1 \
      -type f \
      -name "${TARGET}.*.i*.heap" \
      -mmin +1 \
      -size +0c \
      -printf '%T@ %f\n'
)"

mapfile -t FILES < <(
  printf '%s\n' "$RAW" |
    awk -v start="$START_EPOCH" \
      '$1+0 >= start+0 {print $2}' |
    sort -V
)

COUNT="${#FILES[@]}"
echo "Profiles from current process: $COUNT"

(( COUNT >= 2 )) || {
  echo "ERROR: At least two completed profiles required"
  exit 1
}

for f in "${FILES[@]}"; do
  [[ "$f" =~ ^${TARGET}\.[0-9]+\.[0-9]+\.i[0-9]+\.heap$ ]] || {
    echo "ERROR: Unexpected profile filename: $f"
    exit 1
  }
done

FIRST="${FILES[0]}"
MIDDLE="${FILES[COUNT/2]}"
LAST="${FILES[COUNT-1]}"

TRANSFER=("$FIRST")

if [[ "$MIDDLE" != "$FIRST" &&
      "$MIDDLE" != "$LAST" ]]; then
  TRANSFER+=("$MIDDLE")
fi

[[ "$LAST" == "$FIRST" ]] || TRANSFER+=("$LAST")

echo "First: $FIRST"
echo "Middle: $MIDDLE"
echo "Last: $LAST"
echo "Selected files: ${#TRANSFER[@]}"

# ============================================================
# 4. Create a non-privileged Analysis Pod
#
# NO hostPath.
# Only an ephemeral work volume.
# ============================================================

cat > "$MANIFEST" <<YAML
apiVersion: v1
kind: Pod

metadata:
  name: $ANALYZER
  labels:
    app: flb-jeprof-analysis

spec:
  serviceAccountName: $SA
  automountServiceAccountToken: false
  restartPolicy: Never

  containers:
    - name: analyzer

      image: $ANALYSIS_IMAGE
      imagePullPolicy: IfNotPresent

      command: ["/bin/sh", "-ec"]

      args:
        - |
          mkdir -p /work/profiles /work/tmp
          echo 'Analyzer ready; awaiting profile transfer'
          sleep 1800

      securityContext:
        runAsNonRoot: true
        readOnlyRootFilesystem: true
        allowPrivilegeEscalation: false
        seccompProfile:
          type: RuntimeDefault
        capabilities:
          drop: ["ALL"]

      resources:
        requests:
          cpu: 100m
          memory: 256Mi
        limits:
          cpu: 500m
          memory: 1Gi

      volumeMounts:
        - name: work
          mountPath: /work

  volumes:
    - name: work
      emptyDir:
        sizeLimit: 512Mi
YAML

echo "=== CREATE ANALYZER (NO HOSTPATH) ==="

"${K[@]}" create -f "$MANIFEST"

POD_CREATED=1

echo "=== WAIT FOR ANALYZER READY ==="

"${K[@]}" wait \
  --for=condition=Ready \
  "pod/$ANALYZER" \
  --timeout=300s

# Verify OpenShift-assigned UID and work directory permissions.
"${K[@]}" exec "$ANALYZER" -c analyzer -- \
  sh -ec '
    id
    test -w /work
    mkdir -p /work/profiles /work/tmp
    command -v jeprof >/dev/null
    command -v tar >/dev/null
  '

# ============================================================
# 5. Stream selected profiles between Pods
#
# Binary data passes through kubectl memory streams.
# It is not stored on the jump host filesystem.
# ============================================================

echo "=== STREAM PROFILE FILES ==="

"${K[@]}" exec "$TARGET" -c fluent-bit -- \
  tar -C "$PROFILE_DIR" -cf - \
  -- "${TRANSFER[@]}" |
"${K[@]}" exec -i "$ANALYZER" -c analyzer -- \
  tar -C /work/profiles -xf -

echo "=== PROFILE TRANSFER COMPLETE ==="

# ============================================================
# 6. Perform Heap Analysis inside isolated Pod
# ============================================================

"${K[@]}" exec -i "$ANALYZER" -c analyzer -- \
  env \
    FIRST="$FIRST" \
    MIDDLE="$MIDDLE" \
    LAST="$LAST" \
    HOME=/work \
    TMPDIR=/work/tmp \
    JEPROF_TMPDIR=/work/tmp \
  sh -s <<'IN_ANALYZER'

set -eu

BIN=/fluent-bit/bin/fluent-bit

FILTER='^(prof_backtrace_impl|je_prof_backtrace|je_prof_tctx_create|je_malloc_default|prof_alloc_prep)$'

for name in "$FIRST" "$MIDDLE" "$LAST"; do
  test -s "/work/profiles/$name" || {
    echo "ERROR: Missing profile: $name"
    exit 31
  }
done

mkdir -p /work/tmp

run_jeprof() {
  label="$1"
  base="$2"
  latest="$3"
  output="$4"

  echo "=== $label ==="

  if [ -z "$base" ]; then

    if timeout 180 jeprof \
      --text \
      --show_bytes \
      --inuse_space \
      --exclude="$FILTER" \
      "$BIN" \
      "/work/profiles/$latest" \
      > "$output" 2>&1; then

      sed -n '1,85p' "$output"

    else
      rc=$?
      sed -n '1,100p' "$output"
      exit "$rc"
    fi

  else

    if timeout 180 jeprof \
      --text \
      --show_bytes \
      --inuse_space \
      --exclude="$FILTER" \
      --base="/work/profiles/$base" \
      "$BIN" \
      "/work/profiles/$latest" \
      > "$output" 2>&1; then

      sed -n '1,100p' "$output"

    else
      rc=$?
      sed -n '1,100p' "$output"
      exit "$rc"
    fi
  fi
}

run_jeprof \
  'LATEST IN-USE HEAP' \
  '' "$LAST" /work/latest.txt

run_jeprof \
  'GROWTH: FIRST -> LAST' \
  "$FIRST" "$LAST" /work/diff-first-last.txt

if [ "$MIDDLE" != "$FIRST" ] &&
   [ "$MIDDLE" != "$LAST" ]; then

  run_jeprof \
    'GROWTH: MIDDLE -> LAST' \
    "$MIDDLE" "$LAST" /work/diff-middle-last.txt
fi

echo "=== ANALYSIS COMPLETE ==="

IN_ANALYZER

# ============================================================
# 7. Confirm source container did not restart
# ============================================================

NEW_CID="$(
  "${K[@]}" get pod "$TARGET" \
    -o jsonpath='{.status.containerStatuses[?(@.name=="fluent-bit")].containerID}'
)"

[[ "$NEW_CID" == "$CID" ]] || {
  echo "ERROR: Source Fluent Bit restarted during analysis"
  exit 1
}

echo "ANALYSIS SUCCEEDED"

SCRIPT

chmod +x flb-jeprof-isolated.sh
bash -n flb-jeprof-isolated.sh && echo "BASH SYNTAX PASSED"
