#!/usr/bin/env bash
# Emit LLVM bitcode and link a native executable with clang.
# Usage: scripts/emit-run.sh examples/llvm_arith.lls
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:?source .lls file}"
OUT_DIR="${ROOT}/.zig-cache/llvm-emit"
mkdir -p "$OUT_DIR"
BASE="$(basename "$SRC" .lls)"
BC="$OUT_DIR/$BASE.bc"
LL="$OUT_DIR/$BASE.ll"
EXE="$OUT_DIR/$BASE"

cd "$ROOT"
zig build
./zig-out/bin/llts emit "$SRC" -o "$BC" --emit-llvm "$LL"

# Prefer clang-21 when present (matches llvm-zig LLVM 21 bitcode).
CLANG=""
for c in clang-21 clang; do
  if command -v "$c" >/dev/null 2>&1; then CLANG="$c"; break; fi
done
if [[ -z "$CLANG" ]]; then
  echo "error: need clang or clang-21 to link bitcode" >&2
  exit 1
fi

# Native arena runtime and std native functions.
RT="${ROOT}/zig-out/lib/llts-runtime.o"
RT_NATIVES="${ROOT}/zig-out/lib/llts-runtime-natives.o"
if [[ ! -f "$RT" || ! -f "$RT_NATIVES" ]]; then
  echo "error: missing runtime objects — run 'zig build' first" >&2
  exit 1
fi

"$CLANG" "$BC" "$RT" "$RT_NATIVES" -o "$EXE" -lm -lcurl -s -Wl,--gc-sections
echo "running $EXE"
"$EXE"
