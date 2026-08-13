# std/json

The `json` module provides standard utilities for parsing and stringifying JSON data. It acts as a wrapper over the native `__jsonParse` and `__jsonStringify` VM built-ins.

## Functions

### `parse(str)`

Parses a JSON-formatted string into a corresponding llts-zig value.

**Signature:**
```javascript
pub @func parse(str)
```

**Parameters:**
- `str`: A string containing valid JSON data.

**Returns:**
Returns a value representing the parsed JSON structure. The mapping from JSON types to llts-zig types is as follows:
- JSON `null` -> `.null`
- JSON Boolean -> `.bool`
- JSON Number (integer) -> `.int`
- JSON Number (float) -> `.float`
- JSON String -> `.slice` (string)
- JSON Array -> Pointer to an array of values
- JSON Object -> `.module` (object with properties)

**Errors:**
If the JSON parsing fails, it throws a `JsonError` with the error description payload.

**Example:**
```javascript
const json = @import("std/json.lls");

const data = json.parse("{\"name\": \"Alice\", \"age\": 30}");
print(data.name); // "Alice"
print(data.age);  // 30
```

### `stringify(val)`

Converts a llts-zig value into a JSON-formatted string.

**Signature:**
```javascript
pub @func stringify(val)
```

**Parameters:**
- `val`: Any valid llts-zig value.

**Returns:**
Returns a string containing the serialized JSON representation of `val`.
- `list` and `.ptr` array values are serialized into JSON Arrays (`[]`).
- `map` and `module` values are serialized into JSON Objects (`{}`).
- Unrecognized or complex types that cannot be explicitly mapped will be represented as the string `"[Object]"`.
- Error values stored in arrays are serialized as the string `"[Error]"`.

**Errors:**
If serialization fails, it throws a `JsonError` with the corresponding error message payload.

**Example:**
```javascript
const json = @import("std/json.lls");

const obj = {
    name: "Bob",
    age: 25
};

const str = json.stringify(obj);
print(str); // '{"name":"Bob","age":25}'
```
