#!/usr/bin/env bash
# Drive self-hosted example compiles. The LLS compile_one helper cannot use
# os.args() in the same program as the self-hosted compiler (host panic).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
LLTS="${LLTS:-./zig-out/bin/llts}"
PATH_FILE=/tmp/llts_smoke_path.txt

default_examples=(
  examples/paren_test.lls
  examples/vars.lls
  examples/functions.lls
  examples/mutual.lls
  examples/loop_test.lls
  examples/blocks.lls
  examples/methods.lls
  examples/showcase.lls
  examples/enums.lls
  examples/widths.lls
)

paths=()
use_all=0
for a in "$@"; do
  if [[ "$a" == "all" || "$a" == "--all" ]]; then
    use_all=1
  else
    paths+=("$a")
  fi
done

if [[ "$use_all" -eq 1 ]]; then
  paths=()
  for f in examples/*.lls; do
    paths+=("$f")
  done
elif [[ ${#paths[@]} -eq 0 ]]; then
  paths=("${default_examples[@]}")
fi

pass=0
fail=0
for path in "${paths[@]}"; do
  echo "== $path"
  # trim path file to exact path bytes (no trailing newline issues for __readFile consumers)
  printf '%s' "$path" > "$PATH_FILE"
  if ! out="$("$LLTS" run self_hosted/tools/compile_one.lls 2>&1)"; then
    echo "FAIL compile"
    echo "$out"
    fail=$((fail + 1))
    continue
  fi
  llb="$(echo "$out" | tail -n1)"
  if ! "$LLTS" run "$llb"; then
    echo "FAIL run $llb"
    fail=$((fail + 1))
    continue
  fi
  echo "ok $llb"
  pass=$((pass + 1))
done

echo "examples: $pass ok, $fail fail"
if [[ "$fail" -gt 0 ]]; then
  exit 1
fi
