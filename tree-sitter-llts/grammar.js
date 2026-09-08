/**
 * @file Tree-sitter grammar for LLTS (.lls)
 * @author LLTS contributors
 * @license MIT
 */

/// <reference types="tree-sitter-cli/dsl" />
// @ts-check

const PREC = {
  assign: 1,
  pipe_or: 2,
  and: 3,
  bit_or: 4,
  bit_xor: 5,
  bit_and: 6,
  equality: 7,
  compare: 8,
  shift: 9,
  add: 10,
  mul: 11,
  power: 12,
  range: 13,
  unary: 14,
  postfix: 15,
  call: 16,
};

/**
 * @param {RuleOrLiteral} sep
 * @param {RuleOrLiteral} rule
 */
function sep1(sep, rule) {
  return seq(rule, repeat(seq(sep, rule)));
}

/**
 * @param {RuleOrLiteral} sep
 * @param {RuleOrLiteral} rule
 */
function sep(sep, rule) {
  return optional(sep1(sep, rule));
}

export default grammar({
  name: "llts",

  extras: ($) => [/\s/, $.comment],

  word: ($) => $.identifier,

  conflicts: ($) => [],

  rules: {
    source_file: ($) => repeat($._statement),

    comment: (_) => token(seq("#", /[^\n]*/)),

    // --- statements -------------------------------------------------------

    _statement: ($) =>
      choice(
        $.const_declaration,
        $.func_declaration,
        $.struct_declaration,
        $.enum_declaration,
        $.error_declaration,
        $.type_declaration,
        $.alias_declaration,
        $.extern_declaration,
        $.variable_declaration,
        $.return_statement,
        $.break_statement,
        $.continue_statement,
        $.defer_statement,
        $.expression_statement,
        $.empty_statement,
      ),

    empty_statement: (_) => ";",

    const_declaration: ($) =>
      seq(
        optional($.pub),
        "@const",
        field("name", $.register),
        optional(seq(":", field("type", $._type))),
        "=",
        field("value", $._expression),
        ";",
      ),

    variable_declaration: ($) =>
      seq(
        field("name", $.register),
        optional(seq(":", field("type", $._type))),
        field("operator", $.assignment_operator),
        field("value", $._expression),
        ";",
      ),

    func_declaration: ($) =>
      seq(
        optional($.pub),
        "@func",
        field("name", $.identifier),
        field("parameters", $.parameter_list),
        optional(seq(":", field("return_type", $._type))),
        field("body", $.block),
      ),

    parameter_list: ($) =>
      seq("(", sep(",", $.parameter), optional(","), optional("..."), ")"),

    parameter: ($) =>
      seq(
        field("name", choice($.identifier, $.register)),
        optional(seq(":", field("type", $._type))),
      ),

    struct_declaration: ($) =>
      seq(
        optional($.pub),
        "@struct",
        field("name", $.identifier),
        "{",
        repeat(choice($.struct_field, $.func_declaration)),
        "}",
      ),

    struct_field: ($) =>
      seq(field("name", $.identifier), ":", field("type", $._type), ";"),

    enum_declaration: ($) =>
      seq(
        optional($.pub),
        "@enum",
        field("name", $.identifier),
        "{",
        sep(",", $.enum_variant),
        optional(","),
        "}",
      ),

    enum_variant: ($) => field("name", $.identifier),

    error_declaration: ($) =>
      seq(
        optional($.pub),
        "@error",
        field("name", $.identifier),
        "{",
        sep(",", $.enum_variant),
        optional(","),
        "}",
      ),

    type_declaration: ($) =>
      seq(
        optional($.pub),
        "@type",
        field("name", $.identifier),
        "=",
        field("type", $._type),
        ";",
      ),

    alias_declaration: ($) =>
      seq(
        optional($.pub),
        "@alias",
        field("name", $.identifier),
        "=",
        field("type", $._type),
        ";",
      ),

    extern_declaration: ($) =>
      seq(optional($.pub), "@extern", field("name", $.identifier), ";"),

    return_statement: ($) =>
      seq("return", optional(field("value", $._expression)), ";"),

    break_statement: ($) =>
      seq(
        "break",
        optional(seq(":", field("label", $.identifier))),
        optional(field("value", $._expression)),
        ";",
      ),

    continue_statement: ($) =>
      seq("continue", optional(seq(":", field("label", $.identifier))), ";"),

    defer_statement: ($) =>
      seq(
        field("kind", choice("defer", "errdefer")),
        choice(
          // Prefer `defer { ... }` over `defer <block-expr>;`
          prec(1, field("body", $.block)),
          seq(field("body", $._expression), ";"),
        ),
      ),

    expression_statement: ($) =>
      choice(
        // `@if` / `@for` / `@switch` / blocks as statements — no `;` required
        prec(
          1,
          choice(
            $.if_expression,
            $.for_expression,
            $.switch_expression,
            $.block,
            $.labeled_expression,
          ),
        ),
        seq($._expression, ";"),
      ),

    // --- expressions ------------------------------------------------------

    _expression: ($) =>
      choice(
        $.assignment_expression,
        $.binary_expression,
        $.unary_expression,
        $.try_expression,
        $.call_expression,
        $.index_expression,
        $.member_expression,
        $.struct_init,
        $.if_expression,
        $.for_expression,
        $.switch_expression,
        $.labeled_expression,
        $.block,
        $._primary,
      ),

    assignment_expression: ($) =>
      prec.right(
        PREC.assign,
        seq(
          field("left", $._expression),
          field("operator", $.assignment_operator),
          field("right", $._expression),
        ),
      ),

    binary_expression: ($) => {
      /**
       * @param {number} precedence
       * @param {RuleOrLiteral} operator
       */
      const binary = (precedence, operator) =>
        prec.left(
          precedence,
          seq(
            field("left", $._expression),
            field("operator", operator),
            field("right", $._expression),
          ),
        );

      return choice(
        binary(PREC.pipe_or, "||"),
        binary(PREC.and, "&&"),
        binary(PREC.bit_or, "|"),
        binary(PREC.bit_xor, "~"),
        binary(PREC.bit_and, "&"),
        binary(PREC.equality, choice("==", "!=")),
        binary(PREC.compare, choice(">", ">=", "<", "<=")),
        binary(PREC.shift, choice("<<", ">>")),
        binary(PREC.add, choice("+", "-", "|>")),
        binary(PREC.mul, choice("*", "/", "%", "**")),
        binary(PREC.power, "^"),
        binary(PREC.range, ".."),
      );
    },

    unary_expression: ($) =>
      prec.right(
        PREC.unary,
        seq(
          field("operator", choice("!", "-", "~", "&", "*")),
          field("argument", $._expression),
        ),
      ),

    try_expression: ($) =>
      prec.left(PREC.postfix, seq(field("argument", $._expression), "?")),

    call_expression: ($) =>
      prec.left(
        PREC.call,
        seq(
          field("function", $._expression),
          field("arguments", $.argument_list),
        ),
      ),

    argument_list: ($) =>
      seq("(", sep(",", $._expression), optional(","), ")"),

    index_expression: ($) =>
      prec.left(
        PREC.postfix,
        seq(
          field("object", $._expression),
          "[",
          field("index", optional($._expression)),
          optional(seq("..", field("end", optional($._expression)))),
          "]",
        ),
      ),

    member_expression: ($) =>
      prec.left(
        PREC.postfix,
        seq(
          field("object", $._expression),
          ".",
          field("property", $.identifier),
        ),
      ),

    struct_init: ($) =>
      prec(
        PREC.postfix,
        seq(
          field("type", choice($.identifier, $.member_expression)),
          "{",
          sep(",", $.field_initializer),
          optional(","),
          "}",
        ),
      ),

    field_initializer: ($) =>
      seq(field("name", $.identifier), ":", field("value", $._expression)),

    labeled_expression: ($) =>
      seq(
        field("label", $.identifier),
        ":",
        field(
          "body",
          choice(
            $.block,
            $.if_expression,
            $.for_expression,
            $.switch_expression,
          ),
        ),
      ),

    block: ($) => seq("{", repeat($._statement), "}"),

    if_expression: ($) =>
      prec.right(
        seq(
          "@if",
          "(",
          field("condition", $._expression),
          ")",
          optional($.capture),
          field("consequence", $.block),
          optional(
            seq(
              "@else",
              field(
                "alternative",
                choice($.block, $.if_expression),
              ),
            ),
          ),
        ),
      ),

    for_expression: ($) =>
      seq(
        "@for",
        "(",
        field("iterable", $._expression),
        ")",
        optional($.capture),
        field("body", $.block),
      ),

    capture: ($) =>
      seq("|", field("name", $.identifier), optional(seq(",", field("index", $.identifier))), "|"),

    switch_expression: ($) =>
      seq(
        "@switch",
        "(",
        field("value", $._expression),
        ")",
        "{",
        sep(",", $.switch_arm),
        optional(","),
        "}",
      ),

    switch_arm: ($) =>
      seq(
        field("pattern", choice($.else_pattern, sep1(",", $._expression))),
        "=>",
        field("body", $.block),
      ),

    else_pattern: (_) => "@else",

    // `$name` is declaration-only in LLTS; expressions use the bare identifier.
    // `[N]T` appears as a value in `@new(arena, [256]byte)`.
    _primary: ($) =>
      choice(
        $.identifier,
        $.number,
        $.string,
        $.boolean,
        $.null,
        $.parenthesized_expression,
        $.array_literal,
        $.array_type,
        $.error_literal,
        $.intrinsic_call,
        $.const_literal,
      ),

    parenthesized_expression: ($) => seq("(", $._expression, ")"),

    array_literal: ($) =>
      seq("[", sep(",", $._expression), optional(","), "]"),

    error_literal: ($) =>
      seq("error", "(", sep(",", $._expression), optional(","), ")"),

    const_literal: ($) =>
      seq("const", choice($.string, $.array_literal)),

    // Per-intrinsic shapes; `@new` takes values (incl. types-as-exprs / inits).
    intrinsic_call: ($) =>
      choice(
        seq("@import", "(", field("path", $.string), ")"),
        seq("@typeOf", "(", field("value", $._expression), ")"),
        seq("@nameOf", "(", field("value", $._expression), ")"),
        seq("@isError", "(", field("value", $._expression), ")"),
        seq("@sizeOf", "(", field("type", $._type), ")"),
        seq(
          "@as",
          "(",
          field("type", $._type),
          ",",
          field("value", $._expression),
          optional(","),
          ")",
        ),
        seq(
          "@new",
          "(",
          field("arena", $._expression),
          ",",
          field("value", $._expression),
          optional(seq(",", field("length", $._expression))),
          optional(","),
          ")",
        ),
      ),

    // --- types ------------------------------------------------------------

    _type: ($) =>
      choice(
        $.type_union,
        $.type_intersection,
        $.pointer_type,
        $.optional_type,
        $.array_type,
        $.shape_type,
        $.function_type,
        $.error_type,
        $.const_type,
        $.type_identifier,
        $.parenthesized_type,
      ),

    type_identifier: ($) =>
      prec.right(seq($.identifier, repeat(seq(".", $.identifier)))),

    parenthesized_type: ($) => seq("(", $._type, ")"),

    type_union: ($) =>
      prec.left(1, seq(field("left", $._type), "|", field("right", $._type))),

    type_intersection: ($) =>
      prec.left(2, seq(field("left", $._type), "&", field("right", $._type))),

    pointer_type: ($) => prec(3, seq("*", field("type", $._type))),

    // `?T` (incl. `?*T`) — optional sugar; `?` binds tighter than `&`/`|`.
    optional_type: ($) => prec(4, seq("?", field("type", $._type))),

    array_type: ($) =>
      prec(
        3,
        choice(
          seq("[", "]", field("element", $._type)),
          seq("[", field("length", $.number), "]", field("element", $._type)),
        ),
      ),

    shape_type: ($) => seq("{", repeat($.struct_field), "}"),

    function_type: ($) =>
      seq(
        "@func",
        "(",
        sep(",", $._type),
        optional(","),
        optional("..."),
        ")",
        optional(seq(":", field("return_type", $._type))),
      ),

    error_type: (_) => "error",

    const_type: ($) => seq("const", $.string),

    // --- tokens -----------------------------------------------------------

    pub: (_) => "pub",

    boolean: (_) => choice("true", "false"),

    null: (_) => "null",

    assignment_operator: (_) =>
      choice(
        "=",
        "+=",
        "-=",
        "*=",
        "/=",
        "%=",
        "^=",
        "&&=",
        "||=",
        "&=",
        "|=",
        "~=",
        "<<=",
        ">>=",
      ),

    register: (_) => token(/\$[A-Za-z_][A-Za-z0-9_]*/),

    identifier: (_) => token(/[A-Za-z_][A-Za-z0-9_]*/),

    number: (_) =>
      token(
        choice(
          /0[xX][0-9a-fA-F]+/,
          /0[bB][01]+/,
          /0[oO][0-7]+/,
          /[0-9]+(\.[0-9]+)?/,
        ),
      ),

    string: (_) =>
      token(
        choice(
          /"(?:[^"\\]|\\.)*"/,
          /'(?:[^'\\]|\\.)*'/,
        ),
      ),
  },
});
