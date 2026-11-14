# LLTS Syntax and Grammar Reference

This document defines the formal lexical structure, tokens, literal formats, operator precedence, and grammar rules of LLTS.

---

## 1. Source Text and Encoding

- **File Extension:** LLTS source files use the `.lls` extension (compiled bytecode containers use `.llb`).
- **Character Encoding:** Source files must be valid UTF-8 encoded text.
- **Whitespace:** Spaces, tabs (`\t`), and newlines (`\n`, `\r\n`) are treated as whitespace. Whitespace separates tokens and is otherwise insignificant.
- **Statement Termination:** Statements are terminated with a semicolon (`;`).

---

## 2. Comments

Comments begin with `#` and run to the end of the line:

```lls
# This is a full-line comment
$total = 100; # This is an inline comment
```

LLTS does not support multi-line block comments (`/* ... */`).

---

## 3. Identifiers and Sigils

### Identifier Rules
- Must begin with an ASCII letter (`a-z`, `A-Z`) or underscore (`_`).
- Subsequent characters may include letters, digits (`0-9`), and underscores.
- Valid: `count`, `_temp`, `total_sum_2`, `vecX`.

### The `$` Declaration Sigil
In LLTS, variable bindings are introduced using the `$` sigil:

```lls
$x = 10;                # Declaration of mutable variable x
@const $pi = 3.14159;   # Declaration of immutable variable pi
$name: string = "LLTS"; # Declaration with explicit type annotation
```

> **Rule:** The `$` sigil is used **only** at the declaration site. Subsequent reads, updates, or passes of the variable use the bare identifier:
> ```lls
> x = x + 5; # Correct
> # $x = 10; # Rejected: rebinding an existing name with $ is invalid in the same scope
> ```

### The `@` Compiler Prefix
The `@` prefix designates compiler keywords, directives, and intrinsics. User identifiers cannot begin with `@`.

---

## 4. Keywords and Compiler Directives

### Standard Keywords
Reserved identifiers that cannot be used as variable or function names:

| Keyword | Usage |
| :--- | :--- |
| `true`, `false` | Boolean literal values |
| `null` | Absence of an optional value |
| `return` | Returns from the enclosing function |
| `break` | Breaks from a loop, block, or value expression |
| `continue` | Continues to the next iteration of a loop or switch prong |
| `pub` | Exports a symbol for use outside its declaring module |
| `defer` | Schedules execution of a statement on scope exit |
| `errdefer` | Schedules execution of a statement on error exit |
| `error` | Constructs dynamic errors (`error("msg")`) or denotes the dynamic error type |
| `const` | Used in expression-level literal assertions (`const "admin"`) |

### Compiler Directives (`@`-prefixed)
Directives handled intrinsically by the compiler front end:

| Directive | Purpose |
| :--- | :--- |
| `@func` | Function and method declaration |
| `@struct` | Aggregate struct declaration |
| `@enum` | Enumeration declaration |
| `@error` | Closed typed error set declaration |
| `@type` | Nominal, distinct type declaration |
| `@alias` | Transparent type alias declaration |
| `@extern` | External C function binding (native only) |
| `@const` | Immutable binding modifier |
| `@if`, `@else` | Conditional branching and value expressions |
| `@switch` | Pattern matching and value expressions |
| `@for` | Range, conditional, and collection loops |
| `@comptime` | Explicit compile-time evaluation |
| `@import` | Module import intrinsic |
| `@asm` | Inline target assembly intrinsic (native backend) |
| `@as` | Explicit numeric / width conversion |
| `@typeOf` | Compile-time type introspection |
| `@sizeOf` | Byte size introspection of a type |
| `@nameOf` | Display name introspection of a type |
| `@isError` | Runtime error check |
| `@addrOf` | Explicit memory address intrinsic |
| `@concat` | Byte and string concatenation intrinsic |
| `@new` | Legacy heap allocation (VM only) |

---

## 5. Literals

### Integer Literals
Integers default to 64-bit signed integers (`i64`) unless annotated or coerced:

- **Decimal:** `0`, `42`, `1_000_000` (underscores allowed as digit separators)
- **Hexadecimal:** Prefix `0x` or `0X` (`0x2A`, `0xFF_FF`)
- **Binary:** Prefix `0b` or `0B` (`0b101010`, `0b1111_0000`)
- **Octal:** Prefix `0o` or `0O` (`0o755`, `0o52`)

### Floating-Point Literals
Floats default to 64-bit precision (`f64`):

- **Standard:** `0.0`, `3.14159`, `120.0`
- **Scientific Notation:** `1e6`, `2.5e-3`, `1E+10`

### String Literals
Double-quoted strings representing immutable byte slices (`[]byte`):

```lls
$greeting = "Hello, World!\n";
```

Supported escape sequences:
- `\n` — Newline
- `\r` — Carriage return
- `\t` — Tab
- `\\` — Backslash
- `\"` — Double quote
- `\'` — Single quote

> **Note:** Standard double-quoted strings cannot span multiple lines. For multiline text, use fenced templates.

### Fenced Multiline Templates
Multiline text and template strings use triple-backtick fences (`` ``` ``) with `${expr}` interpolation:

```lls
$user = "Alice";
$template = ```
Hello, ${user}!
Welcome to LLTS.
```;
```

Inside fenced templates:
- Newlines and indentation are preserved verbatim.
- Interpolated `${expression}` holes are evaluated and formatted into the resulting string.

### Boolean & Null Literals
- `true`, `false` (type `u1` / `bool`)
- `null` (type `null`)

---

## 6. Punctuation and Delimiters

| Delimiter | Usages |
| :--- | :--- |
| `( )` | Grouping expressions, function calls, parameter lists, conditional expressions |
| `{ }` | Blocks, struct/enum/error bodies, struct/shape initializers |
| `[ ]` | Array/slice types (`[N]T`, `[]T`), tuples (`[A, B]`), indexing, slicing (`[start..end]`) |
| `,` | Separator for arguments, parameters, struct fields, and tuple elements |
| `;` | Statement terminator |
| `:` | Type annotations (`$x: i64`), struct field declarations, label declarations (`:loop`) |
| `.` | Member access (`obj.field`), tuple index (`t.0`), optional unwrap (`.?`) |
| `?` | Optional type constructor (`?T`), error unwrap operator (`expr?`) |
| `\|` | Union types (`A \| B`), pipe captures (`@for (items) \|item\|`), bitwise OR |
| `&` | Shape/error intersection (`A & B`), address-of (`&val`), bitwise AND |

---

## 7. Operators and Precedence

LLTS defines 14 levels of binary operator precedence (from lowest binding to highest binding):

| Level | Operators | Associativity | Description | Example |
| :---: | :--- | :---: | :--- | :--- |
| **1** | `=`, `+=`, `-=`, `*=`, `/=`, `%=`, `&=`, `\|=`, `~=`, `<<=`, `>>=` | Right | Assignment & Compound Assignment | `x += 5` |
| **2** | `??` | Left | Null-Coalescing | `name ?? "Default"` |
| **3** | `\|\|` | Left | Logical OR (short-circuiting) | `is_valid \|\| fallback` |
| **4** | `&&` | Left | Logical AND (short-circuiting) | `x > 0 && y > 0` |
| **5** | `\|` | Left | Bitwise OR | `flags \| 0x01` |
| **6** | `~` | Left | Bitwise XOR (binary) | `mask ~ 0xFF` |
| **7** | `&` | Left | Bitwise AND | `val & 0x0F` |
| **8** | `==`, `!=` | Left | Equality & Inequality | `status == 200` |
| **9** | `<`, `<=`, `>`, `>=` | Left | Relational Comparisons | `age >= 18` |
| **10** | `<<`, `>>` | Left | Bitwise Shifts (arithmetic) | `val << 2` |
| **11** | `+`, `-`, `\|>`, `+%`, `-%` | Left | Addition, Subtraction, Pipe, Wrapping Add/Sub | `a + b`, `x \|> f()` |
| **12** | `*`, `/`, `%`, `**`, `*%` | Left | Multiplication, Division, Modulo, Power, Wrapping Mul | `w * h`, `a % b` |
| **13** | `^` | Right | Exponentiation (power) | `2 ^ 8` |
| **14** | `..` | Non-assoc | Range operator | `0..limit` |

### Prefix Operators
Prefix operators bind tighter than any binary operator:
- `-expr` — Arithmetic negation
- `!expr` — Logical NOT
- `~expr` — Bitwise NOT (unary inversion)
- `&place` — Address-of operator (takes pointer to place)
- `const expr` — Literal type narrowing assertion (e.g. `const "ok"`)

### Postfix Operators
Postfix operators have the highest precedence:
- `expr(args...)` — Function or method call
- `expr.field` — Member access
- `expr.0` — Tuple element access
- `expr[i]` — Array or slice index
- `expr[start..end]` — Slicing (with optional bounds `[..]`, `[start..]`, `[..end]`)
- `expr.?` — Optional assertion unwrap (unwraps payload, panics on `null`)
- `expr?` — Error unwrap / try operator (unwraps result or returns error)
- `Type { fields... }` — Struct / shape initializer

---

## 8. Grammar Rules (EBNF Specification)

Below is an EBNF specification of LLTS grammar:

```ebnf
Document       ::= Statement* EOF ;

Statement      ::= Declaration
                 | FunctionDecl
                 | StructDecl
                 | EnumDecl
                 | ErrorDecl
                 | TypeDecl
                 | ExternDecl
                 | DeferStmt
                 | ExprStatement ;

Declaration    ::= ( "pub" )? ( "@const" )? "$" IDENTIFIER ( ":" Type )? "=" Expression ";" ;

FunctionDecl   ::= ( "pub" )? "@func" IDENTIFIER "(" ParameterList? ")" ( ":" Type )? Block ;
ParameterList  ::= Parameter ( "," Parameter )* ( "," "..." )? ;
Parameter      ::= IDENTIFIER ( ":" Type )? ;

StructDecl     ::= ( "pub" )? "@struct" IDENTIFIER StructParams? "{" StructMember* "}" ;
# Generic struct template: each distinct argument list is its own struct.
StructParams   ::= "(" "IDENTIFIER" ":" "type" ( "," "IDENTIFIER" ":" "type" )* ")" ;
StructMember   ::= IDENTIFIER ":" Type ";"
                 | FunctionDecl ;

EnumDecl       ::= ( "pub" )? "@enum" IDENTIFIER "{" EnumVariantList? "}" ;
EnumVariantList::= EnumVariant ( "," EnumVariant )* ( "," )? ;
EnumVariant    ::= IDENTIFIER ( "=" ( NUMBER | STRING ) )? ;

ErrorDecl      ::= ( "pub" )? "@error" IDENTIFIER "{" IdentList? "}" ;
IdentList      ::= IDENTIFIER ( "," IDENTIFIER )* ( "," )? ;

TypeDecl       ::= ( "pub" )? ( "@type" | "@alias" ) IDENTIFIER "=" Type ";" ;
ExternDecl     ::= ( "pub" )? "@extern" STRING ExternItem ;
ExternItem     ::= "@func" IDENTIFIER "(" ExternParams? ")" ( ":" Type )? ";"
                 | IDENTIFIER ":" Type ";" ;
ExternParams   ::= ExternParam ( "," ExternParam )* ( "," "..." )? ;
ExternParam    ::= IDENTIFIER ":" Type ;

DeferStmt      ::= ( "defer" | "errdefer" ) Statement ;

ExprStatement  ::= Expression ";" ;

Block          ::= ( ":" IDENTIFIER )? "{" Statement* "}" ;

Expression     ::= Assignment ;
Assignment     ::= Binary ( AssignOp Assignment )? ;
AssignOp       ::= "=" | "+=" | "-=" | "*=" | "/=" | "%=" | "&=" | "|=" | "~=" | "<<=" | ">>=" ;

Binary         ::= Unary ( BinOp Unary )* ;
Unary          ::= PrefixOp* Postfix ;
PrefixOp       ::= "-" | "!" | "~" | "&" | "const" ;

Postfix        ::= Primary PostfixOp* ;
PostfixOp      ::= "(" ArgumentList? ")"
                 | "." ( IDENTIFIER | NUMBER )
                 | "[" SliceIndex "]"
                 | "{" StructInitFields? "}"
                 | ".?"
                 | "?" ;

SliceIndex     ::= Expression? ( ".." Expression? )? ;

Primary        ::= IDENTIFIER
                 | NUMBER
                 | STRING
                 | TEMPLATE
                 | "true" | "false" | "null"
                 | "(" Expression ")"
                 | "[" ArrayElements? "]"
                 | IfExpr
                 | SwitchExpr
                 | ForExpr
                 | ReturnExpr
                 | BreakExpr
                 | ContinueExpr
                 | IntrinsicCall ;

IfExpr         ::= ( ":" IDENTIFIER )? "@if" "(" Expression ")" ( "|" IDENTIFIER "|" )? Block ( "@else" ( Block | IfExpr ) )? ;

SwitchExpr     ::= ( ":" IDENTIFIER )? "@switch" "(" Expression ")" "{" SwitchProng* "}" ;
SwitchProng    ::= ( PatternList | "@else" ) "=>" Block ;
PatternList    ::= Expression ( "," Expression )* ;

ForExpr        ::= ( ":" IDENTIFIER )? "@for" "(" ForCondition ")" ( "|" IDENTIFIER ( "," IDENTIFIER )? "|" )? Block ;
ForCondition   ::= Expression ( ".." Expression )? ;

ReturnExpr     ::= "return" Expression? ;
BreakExpr      ::= "break" ( ":" IDENTIFIER )? Expression? ;
ContinueExpr   ::= "continue" ( ":" IDENTIFIER )? Expression? ;

Type           ::= PrimaryType ( ( "|" | "&" ) PrimaryType )* ;
PrimaryType    ::= IDENTIFIER
                 | "?" Type
                 | "*" Type
                 | "[" NUMBER? "]" Type
                 | "[" TypeList "]"
                 | "{" ShapeFields? "}"
                 | "@func" "(" TypeList? ")" ( ":" Type )? ;
```

---

## Next Steps

- Explore variables and scoping: [**Variables, Bindings & Scoping**](./variables-and-bindings.md)
- Explore operators and expressions: [**Operators & Expressions**](./operators-and-expressions.md)
- Explore the type system in depth: [**Types Documentation**](./types/README.md)
- Learn how to structure functions and control flow: [**Language Tour**](./tour.md)
