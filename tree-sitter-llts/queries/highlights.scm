; LLTS highlight queries
;
; Role palette (AST-first for types; see plan):
;   @comment @keyword @type @constant @constant.builtin @boolean
;   @variable @variable.parameter @label @property @module
;   @function @function.method @function.builtin
;   @operator @operator.unary @operator.range @operator.spread
;   @string @number @punctuation.bracket @punctuation.delimiter
;
; Extension resolves same-span conflicts via CAPTURE_PRIORITY.

; --- literals --------------------------------------------------------------

(comment) @comment
(string) @string
(number) @number
(boolean) @boolean
(null) @constant.builtin

; --- defaults (overridden by higher-priority captures) ---------------------

(identifier) @variable
(register) @variable

; --- keywords / control / decls --------------------------------------------

[
  "return"
  "break"
  "continue"
  "defer"
  "errdefer"
  "const"
  "error"
] @keyword

(pub) @keyword
(else_pattern) @keyword

[
  "@const"
  "@func"
  "@struct"
  "@enum"
  "@error"
  "@type"
  "@alias"
  "@extern"
  "@if"
  "@else"
  "@for"
  "@switch"
] @keyword

[
  "@import"
  "@typeOf"
  "@sizeOf"
  "@nameOf"
  "@as"
  "@new"
  "@isError"
] @function.builtin

(error_literal "error" @keyword)
(const_literal "const" @keyword)
(const_type "const" @keyword)
(error_type) @type
(function_type "@func" @keyword)

; --- operators -------------------------------------------------------------

(assignment_operator) @operator

(binary_expression
  operator: _ @operator)

(binary_expression
  operator: ".." @operator.range)

(unary_expression
  operator: _ @operator.unary)

(try_expression
  "?" @operator.unary)

(index_expression
  ".." @operator.range)

"=>" @operator
"|>" @operator

"..." @operator.spread

; --- punctuation -----------------------------------------------------------

[
  "(" ")"
  "[" "]"
  "{" "}"
] @punctuation.bracket

[
  ","
  ";"
  ":"
  "."
] @punctuation.delimiter

; --- names: params, captures, labels, fields -------------------------------

(parameter
  name: (identifier) @variable.parameter)

(parameter
  name: (register) @variable.parameter)

(capture
  name: (identifier) @variable.parameter)

(capture
  index: (identifier) @variable.parameter)

(labeled_expression
  label: (identifier) @label)

(break_statement
  label: (identifier) @label)

(continue_statement
  label: (identifier) @label)

(struct_field
  name: (identifier) @property)

(field_initializer
  name: (identifier) @property)

(member_expression
  property: (identifier) @property)

; --- functions / methods ---------------------------------------------------

(func_declaration
  name: (identifier) @function)

(call_expression
  function: (identifier) @function)

(call_expression
  function: (member_expression
    property: (identifier) @function.method))

; Module root on multi-segment calls: std.debug.printLn(...)
(call_expression
  function: (member_expression
    object: (member_expression
      object: (identifier) @module)))

(call_expression
  function: (member_expression
    object: (member_expression
      object: (member_expression
        object: (identifier) @module))))

; Same module/method roles without a call: `$p = std.debug.printLn`
; (depth ≥ 2: member(member(...), last))
(member_expression
  object: (member_expression
    object: (identifier) @module)
  property: (identifier) @function.method)

(member_expression
  object: (member_expression
    object: (member_expression
      object: (identifier) @module))
  property: (identifier) @function.method)

; Depth-1 path roots too: `$o = std.debug` / `mem.create` — same green as longer chains.
; Keep `self.x` / typical value fields as variables (not modules).
(member_expression
  object: ((identifier) @module
    (#not-match? @module "^(self|this)$")))

; --- types: declarations (authoritative) -----------------------------------

(struct_declaration
  name: (identifier) @type)

(enum_declaration
  name: (identifier) @type)

(error_declaration
  name: (identifier) @type)

(type_declaration
  name: (identifier) @type)

(alias_declaration
  name: (identifier) @type)

(enum_variant
  name: (identifier) @constant)

(extern_declaration
  name: (identifier) @function)

; --- types: type positions (authoritative) ---------------------------------

(type_identifier) @type

(type_identifier
  (identifier) @type)

(struct_init
  type: (identifier) @type)

(struct_init
  type: (member_expression) @type)

(struct_init
  type: (member_expression
    object: (identifier) @type
    property: (identifier) @type))

(pointer_type
  "*" @operator.unary)

(optional_type
  "?" @operator.unary)

(array_type
  (number) @number)

; --- member chains: type/enum paths ----------------------------------------

; ExprKind.Literal in expression position (fallback when not type_identifier)
(member_expression
  object: ((identifier) @type (#match? @type "^[A-Z][a-z]"))
  property: ((identifier) @constant (#match? @constant "^[A-Z]")))

; Expression-position PascalCase fallback (never overrides decl/type captures
; of equal/higher priority — extension priority: type beats variable)
((identifier) @type (#match? @type "^[A-Z][a-z]"))
