; LLTS highlight queries
; Extension resolves conflicts via CAPTURE_PRIORITY (higher wins).

(comment) @comment

(string) @string
(number) @number
(boolean) @boolean
(null) @constant.builtin
(register) @variable
(assignment_operator) @operator

; Default identifiers (overridden by higher-priority captures)
(identifier) @variable

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

[
  "="
  "+"
  "-"
  "*"
  "/"
  "%"
  "^"
  "=="
  "!="
  ">"
  ">="
  "<"
  "<="
  "&&"
  "||"
  "**"
  "|>"
  ".."
  "=>"
  "&"
  "|"
  "~"
  "<<"
  ">>"
  "!"
  "?"
] @operator

[
  "(" ")" "[" "]" "{" "}"
] @punctuation.bracket

[
  "," ";" ":" "." "..."
] @punctuation.delimiter

; --- names -----------------------------------------------------------------

(parameter name: (identifier) @variable.parameter)
(parameter name: (register) @variable.parameter)
(capture name: (identifier) @variable.parameter)

(labeled_expression label: (identifier) @label)
(break_statement label: (identifier) @label)
(continue_statement label: (identifier) @label)

(struct_field name: (identifier) @property)
(field_initializer name: (identifier) @property)

(member_expression
  property: (identifier) @property)

(enum_variant name: (identifier) @constant)

(func_declaration name: (identifier) @function)
(call_expression function: (identifier) @function)
(call_expression
  function: (member_expression
    property: (identifier) @function.method))

; --- types -----------------------------------------------------------------

(type_identifier) @type
(type_identifier (identifier) @type)

(struct_declaration name: (identifier) @type)
(enum_declaration name: (identifier) @type)
(error_declaration name: (identifier) @type)
(type_declaration name: (identifier) @type)
(alias_declaration name: (identifier) @type)

(struct_init type: (identifier) @type)
(struct_init type: (member_expression) @type)

; PascalCase (Point, ExprKind) — not SCREAMING_SNAKE (LIMIT)
((identifier) @type (#match? @type "^[A-Z][a-z]"))

; ExprKind.Literal → type + enum constant
(member_expression
  object: ((identifier) @type (#match? @type "^[A-Z][a-z]"))
  property: (identifier) @constant)
