# User-Defined Types

LLTS supports several mechanisms for defining custom data types: nominal structs, enumerations, closed error sets, distinct nominal types, and transparent aliases.

---

## 1. Struct Declarations (`@struct`)

Structs are nominal aggregate data types that group named fields and associate methods with an explicit memory layout.

### Declaration and Instantiation
```lls
@struct Point {
    x: f64;
    y: f64;
}

pub @func main() {
    # Initializing struct fields by name
    $pt = Point { x: 3.0, y: 4.0 };
    print(pt.x, pt.y);
}
```

### Methods & Receiver Semantics
Methods are declared inside the `@struct` body using `@func`. The first parameter is always the receiver (`self`):

1. **Value Receiver (`self`):** Operates on a copy of the struct or reads fields without modifying the caller's instance:
   ```lls
   @func length(self): f64 {
       return (self.x * self.x + self.y * self.y) ** 0.5;
   }
   ```

2. **Pointer Receiver (`self: *StructName`):** Operates directly on the struct by reference, allowing in-place mutations:
   ```lls
   @func translate(self: *Point, dx: f64, dy: f64) {
       self.x = self.x + dx;
       self.y = self.y + dy;
   }
   ```

### Method Invocation
Both value and pointer methods use identical dot syntax (`.`):

```lls
$p = Point { x: 0.0, y: 0.0 };
p.translate(5.0, 10.0); # Automatically passes &p for pointer receiver
print(p.length());
```

---

## 2. Enumerations (`@enum`)

Enumerations define closed sets of named variants. By default, variants are integer-backed and auto-increment starting from `0`.

### Standard Enums
```lls
@enum Status {
    Pending,   # 0
    Active,    # 1
    Completed, # 2
}

$s: Status = Status.Active;
print(s); # 1
```

### Explicit Discriminants
Enum variants can also be assigned explicit integer or string values:

```lls
@enum HttpCode {
    Ok = 200,
    NotFound = 404,
    ServerError = 500,
}

@enum Action {
    Start = "START",
    Stop = "STOP",
}
```

- Variants are accessed using `EnumName.Variant`.
- Enums compare equal to their discriminant values and work seamlessly in `@switch` expressions.

---

## 3. Closed Error Sets (`@error`)

Typed error sets declare closed categories of error conditions:

```lls
@error FileError {
    NotFound,
    PermissionDenied,
    DiskFull,
}
```

### Usage in Error Unions
Error set members are returned as error values and unwrap through error unions:

```lls
@func open_file(path: string): string | FileError {
    @if (path == "") {
        return FileError.NotFound;
    }
    return "contents";
}

$res = open_file("");
@if (@isError(res)) {
    print("Encountered error:", res);
}
```

- Error sets are nominal and separate from dynamic string errors created via `error("message")`.
- Multiple error sets can be combined into a merged error set using the intersection operator `&` (`FileError & NetError`).

---

## 4. Distinct Nominal Types (`@type`)

The `@type` directive creates a **Go-style nominal, distinct type** based on an underlying type:

```lls
@type UserId = i64;
@type AccountId = i64;
```

### Non-Interchangeability
Although `UserId` and `AccountId` both share `i64` as their underlying storage representation, they are strictly distinct types. The compiler forbids assigning one to the other:

```lls
$u: UserId = @as(UserId, 100);
# $a: AccountId = u; # Compile Error: UserId is not assignable to AccountId
```

### Conversion Sugar
Converting between distinct types or from the underlying type uses either `@as` or constructor call sugar:

```lls
# Using @as
$uid = @as(UserId, 42);

# Using constructor sugar T(x)
$acc = AccountId(42);
```

### Nominal Shapes
`@type` can also bind anonymous structural shapes into nominal types:

```lls
@type Vector3 = { x: f64; y: f64; z: f64; };

$v: Vector3 = Vector3 { x: 1.0, y: 2.0, z: 3.0 };
```

---

## 5. Transparent Type Aliases (`@alias`)

The `@alias` directive creates a **transparent type alias**. Unlike `@type`, an alias does not create a new type identity — it is completely interchangeable with the underlying type:

```lls
@alias Int = i64;
@alias Callback = @func(i64): void;

$n: Int = 100; # Exactly equivalent to $n: i64 = 100;
$m: i64 = n;   # Valid: Int and i64 are identical
```

### When to Use `@type` vs `@alias`

| Feature | `@type Name = T;` | `@alias Name = T;` |
| :--- | :--- | :--- |
| **Identity** | Nominal, distinct type | Transparent synonym |
| **Assignability** | Only assignable to same `@type` | Freely assignable to/from `T` |
| **Safety** | Prevents mixing IDs, units, currencies | Convenience and readability |
| **Constructor Sugar** | `Name(val)` supported | Not applicable |
