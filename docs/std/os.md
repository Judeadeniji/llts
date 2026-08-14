# OS (`std/os`)

The `os` module provides operating system-level interactions such as environment variables, process execution, and working directory management.

## Functions

### `exec(cmd: string) -> string | ExecError`
Executes a shell command (`sh -c`) and returns its standard output as a string.

**Parameters:**
- `cmd`: The shell command to execute.

**Returns:**
The command's standard output. If the command fails, throws an `ExecError`.

**Example:**
```llts
const os = import("std/os");
const out = os.exec("echo 'Hello, World!'");
print(out); // Hello, World!\n
```

### `getEnv(key: string) -> string | null | EnvError`
Retrieves the value of an environment variable.

**Parameters:**
- `key`: The name of the environment variable.

**Returns:**
The string value of the environment variable, or `null` if the variable does not exist. Throws an `EnvError` if retrieval fails.

**Example:**
```llts
const os = import("std/os");
const path = os.getEnv("PATH");
```

### `setEnv(key: string, val: string) -> null | EnvError`
Sets the value of an environment variable.

**Parameters:**
- `key`: The name of the environment variable.
- `val`: The value to set.

**Returns:**
`null` on success. Throws an `EnvError` on failure.

**Example:**
```llts
const os = import("std/os");
os.setEnv("MY_VAR", "my_value");
```

### `exit(code: int) -> void`
Terminates the program immediately with the specified exit code.

**Parameters:**
- `code`: An integer representing the exit status (0 typically indicates success).

**Example:**
```llts
const os = import("std/os");
os.exit(1); // Exit with error code 1
```

### `cwd() -> string | CwdError`
Gets the current working directory.

**Returns:**
A string representing the absolute path to the current working directory. Throws `CwdError` on failure.

**Example:**
```llts
const os = import("std/os");
const dir = os.cwd();
print(dir);
```

### `chdir(dir: string) -> null | ChdirError`
Changes the current working directory.

**Parameters:**
- `dir`: The target directory path.

**Returns:**
`null` on success. Throws `ChdirError` if the directory change fails.

**Example:**
```llts
const os = import("std/os");
os.chdir("/tmp");
```

### `pid() -> int`
Gets the current process ID.

**Returns:**
An integer representing the current process ID.

**Example:**
```llts
const os = import("std/os");
print("PID: " + os.pid());
```

### `args() -> array`
Gets the command-line arguments passed to the program.

**Returns:**
An array of arguments. The first element (`args()[0]`) is the source path. Remaining elements are trailing CLI arguments after host flags (or after `--`):

```bash
llts run program.lls hello world
llts run program.lls -- -r  # "-r" is a program arg, not a host flag
```

**Example:**
```llts
const os = import("std/os");
const argv = os.args();
print("Program path: " + argv[0]);
print("Arg count: " + len(argv));
```

### `platform() -> string`
Gets the operating system platform name.

**Returns:**
A string representing the current OS (e.g., `"linux"`, `"macos"`, `"windows"`).

**Example:**
```llts
const os = import("std/os");
print("Running on: " + os.platform());
```
