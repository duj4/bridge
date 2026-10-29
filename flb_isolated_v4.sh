cp -p flb-jeprof-isolated.sh \
  "flb-jeprof-isolated.sh.bak.$(date +%Y%m%d%H%M%S)"

python3 - <<'PY'
from pathlib import Path

p = Path("flb-jeprof-isolated.sh")
s = p.read_text()

marker = 'echo "=== ANALYSIS COMPLETE ==="\n\nIN_ANALYZER'

if "=== FULL-STACK ATTRIBUTION V4 ===" in s:
    print("V4 already applied.")
    raise SystemExit(0)

if s.count(marker) != 1:
    raise SystemExit("ERROR: Unexpected script structure")

addition = r'''
# === FULL-STACK ATTRIBUTION V4 ===

run_collapsed_growth() {
  title="$1"
  baseline="$2"
  current="$3"
  name="$4"

  file="/work/${name}.collapsed.txt"
  errors="/work/${name}.errors.txt"

  echo "=== FULL STACK GROWTH: $title ==="

  if timeout 180 jeprof \
       --collapsed \
       --inuse_space \
       --show_bytes \
       --base="/work/profiles/$baseline" \
       "$BIN" "/work/profiles/$current" \
       > "$file" 2> "$errors"; then
    :
  else
    rc=$?
    echo "ERROR: collapsed analysis failed (exit=$rc)"
    sed -n '1,30p' "$errors"
    exit "$rc"
  fi

  echo "--- TOP 20 POSITIVE FULL STACKS (estimated bytes) ---"

  awk '
    NF >= 2 && ($NF + 0) > 0 {
      n = $NF
      sub(/[[:space:]]+[^[:space:]]+$/, "", $0)
      printf "%.0f\t%s\n", n, $0
    }
  ' "$file" | sort -k1,1nr | head -20

  echo "--- TOP 10 NEGATIVE FULL STACKS (estimated bytes) ---"

  awk '
    NF >= 2 && ($NF + 0) < 0 {
      n = $NF
      sub(/[[:space:]]+[^[:space:]]+$/, "", $0)
      printf "%.0f\t%s\n", n, $0
    }
  ' "$file" | sort -k1,1n | head -10

  for pattern in \
    'CRYPTO_malloc' \
    'msgpack_sbuffer_write' \
    'unpack_metric_array_entry' \
    'flb_tail_file_append' \
    'cio_memfs_open' \
    'cb_loki_flush'
  do
    echo "--- POSITIVE STACKS CONTAINING: $pattern ---"

    awk -v needle="$pattern" '
      index($0, needle) && NF >= 2 && ($NF + 0) > 0 {
        n = $NF
        sub(/[[:space:]]+[^[:space:]]+$/, "", $0)
        printf "%.0f\t%s\n", n, $0
      }
    ' "$file" | sort -k1,1nr | head -5
  done
}

if [ "$FIRST" != "$MIDDLE" ] &&
   [ "$MIDDLE" != "$LAST" ]; then

  run_collapsed_growth \
    'FIRST -> MIDDLE' \
    "$FIRST" "$MIDDLE" \
    'growth-first-middle'

  run_collapsed_growth \
    'MIDDLE -> LAST' \
    "$MIDDLE" "$LAST" \
    'growth-middle-last'
fi

run_collapsed_growth \
  'FIRST -> LAST' \
  "$FIRST" "$LAST" \
  'growth-first-last'

'''

s = s.replace(marker, addition + marker, 1)
p.write_text(s)

print("Full-stack attribution enabled.")
PY

bash -n flb-jeprof-isolated.sh &&
  echo "BASH SYNTAX PASSED"
