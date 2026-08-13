# Structs and Methods (llts)

## 1. Overview
This document outlines the syntax, types, and constraints for defining and interacting with structs and methods in the `llts` language. This reference is designed for automated agents to correctly generate or parse `llts` source code.

## 2. Struct Definitions
Structs in `llts` are user-defined data structures encapsulating strongly typed fields.

**Syntax Rules:**
- Declared using the `@struct` directive.
- Followed by the struct name (PascalCase convention recommended) and a block enclosed in `{}`.
- Each field is declared as `identifier: type;`.
- Every field declaration **must** end with a semicolon `;`.
- Supported primitive types include `int`, `string`. Other structs can also be used as types.

**Example:**
```llts
@struct Point {
    x: int;
    y: int;
}
```

## 3. Instantiation and Field Access
Struct instances are created without the `new` keyword, using curly braces for inline field initialization.

**Syntax Rules:**
- Instantiation format: `StructName { field1: value1, field2: value2 }`
- Field initializations within the instantiation block are separated by **commas** `,`.
- When assigning the instance to a new variable, use the `$` prefix for variable declaration: `$varName = ...`.
- Fields are accessed and mutated using dot notation `.`.

**Example:**
```llts
@const $debug = @import("std/debug");

$p = Point { x: 10, y: 20 };

# Access
$ok = debug.assert(p.x == 10);

# Mutation
p.x = 42;
```

## 4. Nested Structs
Struct fields can be of another struct type, allowing deep composition.

**Syntax Rules:**
- Declare the field type as the nested struct's name.
- During instantiation, provide an inline instantiation of the nested struct.
- Nested fields are accessed using chained dot notation.

**Example:**
```llts
@const $debug = @import("std/debug");

@struct Rect {
    point: Point;
    width: int;
    height: int;
    name: string;
}

$r = Rect { 
    point: Point { x: 5, y: 10 }, 
    width: 100, 
    height: 200,
    name: "My Awesome Rect"
};

# Nested access and mutation
r.point.x = 99;
$ok = debug.assert(r.point.x == 99);
```

## 5. Methods
Methods are functions bound to a specific struct, enabling behavior encapsulation.

**Syntax Rules:**
- Methods are defined **inside** the struct body block.
- Declared using the `@func` directive followed by the method name.
- The first parameter must be explicitly named `self`, which acts as the reference to the calling instance.
- Subsequent parameters do not require explicit type annotations in the signature (based on standard examples).
- Access instance fields inside the method using `self.fieldName`.
- Methods are invoked on an instance using dot notation. The `self` parameter is implicitly passed during invocation.

**Example:**
```llts
@const $debug = @import("std/debug");

@struct Vector3 {
    x: int;
    y: int;
    z: int;

    @func translate(self, dx, dy, dz) {
        self.x = self.x + dx;
        self.y = self.y + dy;
        self.z = self.z + dz;
        debug.info("Vector3 translated");
    }

    @func scale(self, factor) {
        self.x = self.x * factor;
        debug.info("Vector3 scaled");
    }
}

$v = Vector3 { x: 10, y: 20, z: 30 };

# Invocation: 'self' is implicit
v.translate(5, 5, 5);
v.scale(2);
```

## 7. `@sizeOf`

Struct size is `field_count * 16` bytes (one VM slot per field). `@sizeOf(Point)` and `@sizeOf(p)` agree when `p` is typed. See [Type introspection](errors.md#sizeof).
