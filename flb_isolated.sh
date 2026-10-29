cat > flb-jeprof-isolated.sh <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

TARGET="${1:-fluent-bit-qfxfs}"
OUT_DIR="${OUT_DIR:-$HOME/flb-heap-reports}"

K=(kubectl)
[[ -n "${NS:-}" ]] && K+=(-n "$NS")

# Discover the existing Fluent Bit container.
NODE="$("${K[@]}" get pod "$TARGET" \
  -o jsonpath='{.spec.nodeName}')"

IMAGE="$("${K[@]}" get pod "$TARGET" \
  -o jsonpath='{.spec.containers[?(@.name=="fluent-bit")].image}')"

SA="$("${K[@]}" get pod "$TARGET" \
  -o jsonpath='{.spec.serviceAccountName}')"

STARTED="$("${K[@]}" get pod "$TARGET" \
  -o jsonpath='{.status.containerStatuses[?(@.name=="fluent-bit")].state.running.startedAt}')"

[[ -n "$NODE" && -n "$IMAGE" && -n "$STARTED" ]] || {
  echo "ERROR: Cannot determine target container identity"
  exit 1
}

[[ "$IMAGE" == *heap-prof-libunwind* ]] || {
  echo "ERROR: Target is not running the profiling image"
  exit 1
}

START_EPOCH="$(date -u -d "$STARTED" +%s)"
ANALYZER="flb-jeprof-${TARGET#fluent-bit-}-$(date -u +%m%d%H%M%S)"

mkdir -p "$OUT_DIR"
REPORT="$OUT_DIR/${ANALYZER}.txt"

echo "Target: $TARGET"
echo "Node: $NODE"
echo "Image: $IMAGE"
echo "Started: $STARTED"
echo "Analyzer: $ANALYZER"

# Create a separate analysis Pod on the same Worker.
# Mount the host directory READ ONLY.
"${K[@]}" create -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${ANALYZER}
  labels:
    app: flb-jeprof-analysis
spec:
  nodeName: ${NODE}
  serviceAccountName: ${SA:-default}
  automountServiceAccountToken: false
  restartPolicy: Never

  containers:
    - name: analyzer
      image: ${IMAGE}
      imagePullPolicy: IfNotPresent

      command: ["/bin/sh", "-ec"]
      args:
        - |
          echo "=== ISOLATED JEPROF ANALYSIS ==="
          echo "Target process: ${TARGET}"
          echo "Started UTC: ${STARTED}"

          BIN=/fluent-bit/bin/fluent-bit
          FILTER='^(prof_backtrace_impl|je_prof_backtrace|je_prof_tctx_create|je_malloc_default|prof_alloc_prep)\$'

          FILES=\$(find /profiles -maxdepth 1 -type f -name '${TARGET}.*.i*.heap' -mmin +1 -printf '%T@ %p\n' | awk -v start='${START_EPOCH}' '\$1 >= start {print \$2}' | sort -V)

          if [ -z "\$FILES" ]; then
            echo "ERROR: No completed profiles for current process"
            exit 2
          fi

          COUNT=\$(printf '%s\n' "\$FILES" | wc -l)
          FIRST=\$(printf '%s\n' "\$FILES" | head -1)
          LAST=\$(printf '%s\n' "\$FILES" | tail -1)

          echo "Profile count: \$COUNT"
          echo "First: \$FIRST"
          echo "Last: \$LAST"

          echo "=== LATEST IN-USE ALLOCATIONS ==="

          timeout 180 jeprof --text --show_bytes --exclude="\$FILTER" "\$BIN" "\$LAST" > /tmp/heap-latest.txt 2>&1
          sed -n '1,65p' /tmp/heap-latest.txt

          if [ "\$COUNT" -ge 2 ] && [ "\$FIRST" != "\$LAST" ]; then
            echo "=== HEAP DIFF: LAST - FIRST ==="

            timeout 180 jeprof --text --show_bytes --exclude="\$FILTER" --base="\$FIRST" "\$BIN" "\$LAST" > /tmp/heap-diff.txt 2>&1
            sed -n '1,85p' /tmp/heap-diff.txt
          else
            echo "Only one valid profile; Diff unavailable"
          fi

          echo "=== ANALYSIS COMPLETE ==="

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

  volumes:
    - name: profiles
      hostPath:
        path: /var/log/fluent-bit-heap-profiles
        type: Directory
EOF

echo "=== ANALYSIS OUTPUT ==="

if ! "${K[@]}" logs -f "$ANALYZER" -c analyzer \
  --pod-running-timeout=120s 2>&1 | tee "$REPORT"; then

  echo "Analysis Pod failed or could not start."
  "${K[@]}" describe pod "$ANALYZER" | tail -55 || true
  exit 1
fi

echo "Saved report: $REPORT"
echo "Analyzer Pod: $ANALYZER"
echo "Cleanup: ${K[*]} delete pod $ANALYZER"
SCRIPT

chmod +x flb-jeprof-isolated.sh
bash -n flb-jeprof-isolated.sh
