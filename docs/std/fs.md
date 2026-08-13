# fs

The `fs` module provides a cross-platform filesystem API. It allows reading, writing, and manipulating files and directories.

Implementations live on [`Dir`](#dir). Module-level helpers are thin forwards to **`fs.cwd`** (Zig-flavored):

```llts
fs.readFile(path);       # primary API
fs.cwd.readFile(path);   # same
```

Most path helpers (`readFile`, `writeFile`, `appendFile`, `deleteFile`, `exists`, `mkdir`, `rename`, `copyFile`, `symlink`, `readlink`, `chmod`) are implemented in LLS on top of [`std/syscall`](syscall.md) and [`std/buffer`](buffer.md). `readDir`, `stat`, `mkdirAll`, and `realpath` still use host natives.

## Structs

### `Stat`
Represents file status information.

```llts
pub @struct Stat {
    size: int;
    mtime: int;
    atime: int;
    ctime: int;
    kind: int;
}
```

* **size**: Size of the file in bytes.
* **mtime**: Last modification time in milliseconds.
* **atime**: Last access time in milliseconds.
* **ctime**: Creation time in milliseconds.
* **kind**: The type of the file. `1` for file, `2` for directory, `3` for symlink, `0` for unknown.

### `Dir`
Directory handle. Today `kind: 0` means cwd-relative paths (a real directory fd may come later).

```llts
pub @struct Dir {
    kind: int;
    # methods: readFile, writeFile, … (see Functions)
}

pub $cwd = Dir{ kind: 0 };
```

Use `fs.cwd` for the default handle, or construct `Dir{ kind: 0 }` locally.

## Functions

All functions below are available as both top-level functions in the `fs` module and as methods on a `Dir` instance. Top-level forms call through `cwd`.

### `readFile(path)`
Reads the entire contents of a file into a string.
* **Arguments:** `path` (string)
* **Returns:** `string`

### `readFileBuffer(path)`
Reads the entire contents of a file into a byte buffer.
* **Arguments:** `path` (string)
* **Returns:** `buffer`

### `writeFile(path, content)`
Writes a string to a file, creating it if it does not exist or truncating it if it does.
* **Arguments:** `path` (string), `content` (string)
* **Returns:** `null`

### `writeFileBuffer(path, buf)`
Writes the contents of a buffer to a file.
* **Arguments:** `path` (string), `buf` (buffer)
* **Returns:** `null`

### `appendFile(path, content)`
Appends a string to the end of a file.
* **Arguments:** `path` (string), `content` (string)
* **Returns:** `null`

### `deleteFile(path)`
Deletes a file.
* **Arguments:** `path` (string)
* **Returns:** `null`

### `exists(path)`
Checks if a file or directory exists.
* **Arguments:** `path` (string)
* **Returns:** `bool`

### `mkdir(path)`
Creates a new directory.
* **Arguments:** `path` (string)
* **Returns:** `null`

### `mkdirAll(path)`
Creates a new directory and all necessary parent directories.
* **Arguments:** `path` (string)
* **Returns:** `null`

### `readDir(path)`
Reads the contents of a directory.
* **Arguments:** `path` (string)
* **Returns:** `array` of strings (filenames)

### `stat(path)`
Gets status information for a file or directory. Note that the underlying builtin currently returns an array `[size, mtime, atime, ctime, kind]`.
* **Arguments:** `path` (string)
* **Returns:** `array` containing 5 numbers `[size, mtime, atime, ctime, kind]`.

### `rename(old, new)`
Renames or moves a file or directory.
* **Arguments:** `old` (string), `new` (string)
* **Returns:** `null`

### `copyFile(src, dst)`
Copies a file from `src` to `dst`.
* **Arguments:** `src` (string), `dst` (string)
* **Returns:** `null`

### `symlink(target, path)`
Creates a symbolic link at `path` pointing to `target`.
* **Arguments:** `target` (string), `path` (string)
* **Returns:** `null`

### `readlink(path)`
Reads the target value of a symbolic link.
* **Arguments:** `path` (string)
* **Returns:** `string`

### `realpath(path)`
Resolves the absolute path, following symbolic links.
* **Arguments:** `path` (string)
* **Returns:** `string`

### `chmod(path, mode)`
Changes the permissions of a file (stubbed across platforms currently).
* **Arguments:** `path` (string), `mode` (int)
* **Returns:** `int` (always returns `0`)

## Examples

```llts
@const $fs = @import("std/fs");

# Write to a file (module or cwd)
fs.writeFile("test.txt", "Hello World!\n");
fs.cwd.appendFile("test.txt", "Appended line.\n");

$content = fs.readFile("test.txt");
print(content);

$does_exist = fs.exists("test.txt");
print(does_exist);

$files = fs.readDir(".");
print(files);

$file_stat = fs.stat("test.txt");
print(file_stat[0]);

fs.deleteFile("test.txt");
```
