#!/usr/bin/env bash
# Parity harness: for every `runSource(\`...\`)` block in the listed test files
# that exercises the native-backed std modules (len / string / math / fs /
# syscall / buffer / os), compile + run the source through BOTH the bytecode VM
# (`llts run`) and the LLVM backend (`scripts/emit-run.sh`) and diff the output.
#
# Usage: scripts/parity-check.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

zig build

OUT_DIR="${ROOT}/.zig-cache/parity"
mkdir -p "$OUT_DIR"

# Extract each backtick-quoted runSource body as its own .lls source, with a
# single global counter (per-file awk would overwrite earlier files' blocks).
rm -f "$OUT_DIR"/src_*.lls
pass=0
fail=0
skip=0

i=0
awk -v outdir="$OUT_DIR" '
  /runSource\(`/ { in_src=1; n++; next }
  in_src && /`\)/ { in_src=0; next }
  in_src { print > (outdir "/src_" n ".lls") }
' tests/08_stdlib.test.ts tests/19_new_natives.test.ts tests/21_buffer.test.ts tests/24_syscall.test.ts tests/18_http_json.test.ts tests/20_collections.test.ts tests/23_logging.test.ts || true

for src in "$OUT_DIR"/src_*.lls; do
  i=$((i+1))
  # Only run blocks that touch the native-backed modules
  # (len/string/math/fs/syscall/buffer/os).
  if ! grep -qE 'string\.|math\.|\blen\(|fs\.|syscall\.|buffer\.|os\.' "$src"; then
    continue
  fi
  # Skip blocks importing modules not yet backed natively (mem, debug).
  if grep -qE '@import\("(std/)?(mem|debug)' "$src"; then
    continue
  fi
  # runSource bodies end with a trailing empty-ish line; add a main for the LLVM path.
  { cat "$src"; echo "pub @func main() {}"; } > "$OUT_DIR/t_$i.lls"

  # VM output (skip "Error:"-free runs; a compile error in one backend is itself a diff).
  VM_OUT="$OUT_DIR/vm_$i.out"
  ./zig-out/bin/llts run "$OUT_DIR/t_$i.lls" > "$VM_OUT" 2>&1 || true

  # expectError sources make the VM abort (runtime error + leak report); the
  # LLVM backend does not throw yet, so error-channel parity is out of scope.
  if grep -qE '^(Error|ERROR|error:)' "$VM_OUT"; then
    skip=$((skip+1))
    continue
  fi

  LL_OUT="$OUT_DIR/ll_$i.out"
  LL_IR="$OUT_DIR/ll_$i.ll"
  if ./zig-out/bin/llts emit "$OUT_DIR/t_$i.lls" -o "$OUT_DIR/t_$i.bc" --emit-llvm "$LL_IR" > "$OUT_DIR/emit_$i.log" 2>&1; then
    CLANG=""
    for c in clang-21 clang; do
      if command -v "$c" >/dev/null 2>&1; then CLANG="$c"; break; fi
    done
    if "$CLANG" "$OUT_DIR/t_$i.bc" "$ROOT/zig-out/lib/llts-runtime.o" "$ROOT/zig-out/lib/llts-runtime-natives.o" -o "$OUT_DIR/t_$i" -lm -lcurl 2>/dev/null; then
      "$OUT_DIR/t_$i" > "$LL_OUT" 2>&1 || true
    else
      echo "LINK-FAIL" > "$LL_OUT"
    fi
  else
    echo "EMIT-FAIL" > "$LL_OUT"
    cat "$OUT_DIR/emit_$i.log" >> "$LL_OUT"
  fi

  # Normalize: strip trailing whitespace and empty lines; compare.
  if diff <(sed 's/[[:space:]]*$//' "$VM_OUT" | grep -v '^$') \
          <(sed 's/[[:space:]]*$//' "$LL_OUT" | grep -v '^$') > "$OUT_DIR/diff_$i.txt" 2>&1; then
    pass=$((pass+1))
  else
    fail=$((fail+1))
    echo "MISMATCH: $OUT_DIR/t_$i.lls"
    echo "  --- VM ---"; cat "$VM_OUT"
    echo "  --- LLVM ---"; cat "$LL_OUT"
    echo
  fi
done

echo "parity: $pass match, $fail mismatch, $skip skipped-error (of $i candidate sources)"
