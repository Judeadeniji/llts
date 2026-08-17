# LLVM / Clang Setup Notes (Manjaro)

This document records the issues encountered when integrating
[`llvm-zig`](https://github.com/kassane/llvm-zig) into the `llvm` experimental branch.

---

## Context

`llvm-zig` (`v1.0.0`) provides Zig bindings for the LLVM and Clang C APIs.
Its `build.zig` hardcodes library names targeting **Ubuntu** conventions (e.g. `LLVM-21`, `clang-21`),
which differ from what Arch/Manjaro ships.

---

## Issue 1 — Wrong LLVM version (`LLVM-21` not found)

### Symptom

```
error: unable to find dynamic system library 'LLVM-21' using strategy 'paths_first'
```

### Root Cause

`llvm-zig`'s `build.zig` hardcodes:

```zig
.linux => llvm_module.linkSystemLibrary("LLVM-21", .{}),
```

The system had LLVM **22** installed (`llvm 22.1.6`), not 21.

### Fix

Install the `llvm21` and `llvm21-libs` packages side-by-side with the existing LLVM 22:

```bash
sudo pacman -S extra/llvm21 extra/llvm21-libs
```

This places `libLLVM-21.so` in `/usr/lib/` without replacing the default LLVM installation.

---

## Issue 2 — `clang-21` (historical)

Earlier revisions of this project imported llvm-zig’s **`clang`** module, which
hardcodes `clang-21` on Linux. LLTS now links **only** the `llvm` module (IR /
bitcode), so `clang21` and the `libclang-21.so` symlink are **not required**.

If you re-enable the clang import, install `extra/clang21` and:

```bash
sudo ln -sf /usr/lib/libclang.so.21.1 /usr/lib/libclang-21.so
```

---

## Summary of Commands

```bash
# Install LLVM 21 alongside the default LLVM 22 (required for llvm-zig v1.0.0)
sudo pacman -S extra/llvm21 extra/llvm21-libs
```

---

## Notes

- `llvm-zig` v1.0.0 targets LLVM 21 specifically. If a newer version of the package
  targets LLVM 22+, the `LLVM-21` library name issue should resolve on Manjaro
  without a side install.
- We intentionally did **not** patch the cached `llvm-zig` `build.zig` in
  `~/.cache/zig/p/` since the Zig package cache is read-only and modifications
  there would be lost on the next `zig fetch`.
- After `llts emit`, use `llvm-dis-21` / `clang-21` (or system tools that match
  the bitcode version) to inspect IR or link an executable.
