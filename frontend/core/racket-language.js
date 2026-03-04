// racket-language.js — Monarch tokenizer for Racket
//
// Defines syntax highlighting rules for Racket in Monaco Editor's Monarch
// format.  Covers #lang lines, comments (line and nested block), strings,
// character literals, numbers (with Racket prefixes), booleans, keywords,
// bracket matching, and quote/quasiquote shorthand.

/**
 * Language identifier used with monaco.languages.register().
 * @type {string}
 */
export const racketLanguageId = 'racket';

/**
 * Language configuration for bracket matching, auto-closing pairs,
 * and comment toggling.
 * @type {import('monaco-editor').languages.LanguageConfiguration}
 */
export const racketLanguageConfig = {
  comments: {
    lineComment: ';',
    blockComment: ['#|', '|#'],
  },

  brackets: [
    ['(', ')'],
    ['[', ']'],
    ['{', '}'],
  ],

  autoClosingPairs: [
    { open: '(', close: ')' },
    { open: '[', close: ']' },
    { open: '{', close: '}' },
    { open: '"', close: '"', notIn: ['string'] },
    { open: '#|', close: '|#' },
  ],

  surroundingPairs: [
    { open: '(', close: ')' },
    { open: '[', close: ']' },
    { open: '{', close: '}' },
    { open: '"', close: '"' },
  ],
};

/**
 * Monarch tokenizer rules for Racket syntax.
 * @type {import('monaco-editor').languages.IMonarchLanguage}
 */
export const racketTokenProvider = {
  defaultToken: '',
  ignoreCase: false,

  keywords: [
    'define', 'define-syntax', 'define-syntax-rule', 'define-values',
    'define-struct', 'define/contract',
    'lambda', 'λ',
    'let', 'let*', 'letrec', 'let-values', 'let-syntax',
    'if', 'cond', 'else', 'when', 'unless', 'case',
    'and', 'or', 'not',
    'begin', 'begin0',
    'set!',
    'quote', 'unquote', 'quasiquote', 'unquote-splicing',
    'syntax', 'syntax-rules', 'syntax-case',
    'match', 'match-let', 'match-define',
    'for', 'for/list', 'for/fold', 'for/hash', 'for/and', 'for/or',
    'for*', 'for*/list', 'for*/fold',
    'do',
    'require', 'provide', 'all-defined-out', 'all-from-out',
    'module', 'module+', 'module*',
    'struct',
    'class', 'class*', 'interface',
    'send', 'new', 'make-object',
    'with-handlers', 'with-syntax',
    'parameterize',
    'dynamic-require',
    'values', 'call-with-values',
    'apply', 'map', 'filter', 'foldl', 'foldr',
    'cons', 'car', 'cdr', 'list', 'append', 'reverse', 'length',
    'null', 'null?', 'pair?', 'list?', 'empty?',
    'equal?', 'eq?', 'eqv?',
    'number?', 'string?', 'symbol?', 'boolean?', 'procedure?',
    'void', 'void?',
    'display', 'displayln', 'print', 'println', 'printf', 'fprintf',
    'newline', 'write',
    'error', 'raise', 'raise-argument-error',
    'contract', '->', '->*', '->i',
    'string-append', 'string-length', 'string-ref', 'substring',
    'format', 'string->number', 'number->string',
    'hash', 'hash-ref', 'hash-set', 'hash-update', 'hash-map',
    'vector', 'vector-ref', 'vector-set!',
    'port?', 'input-port?', 'output-port?',
    'open-input-file', 'open-output-file',
    'read', 'read-line', 'read-syntax',
    'eval', 'namespace-require',
    'thread', 'channel-put', 'channel-get',
    'place', 'place-channel-put', 'place-channel-get',
  ],

  // Symbols that can be part of identifiers in Racket
  // (Racket identifiers are very permissive)
  symbolChars: /[^\s()\[\]{}",'`;#|\\]/,

  tokenizer: {
    root: [
      // #lang line — special treatment
      [/^#lang\s+.*$/, 'meta'],

      // Whitespace
      [/\s+/, 'white'],

      // Nested block comments: #| ... |#
      [/#\|/, 'comment', '@blockComment'],

      // Line comments: ; ...
      [/;.*$/, 'comment'],

      // #! shebang or reader directives
      [/^#!/, 'comment', '@shebang'],
      [/#!(?:eof|no-collect)/, 'meta'],

      // Strings
      [/"/, 'string', '@string'],

      // Character literals: #\space, #\newline, #\a, etc.
      [/#\\(?:space|newline|tab|return|nul|backspace|delete|escape|alarm|vtab|linefeed|rubout)/, 'string.char'],
      [/#\\[a-zA-Z]/, 'string.char'],
      [/#\\u[0-9a-fA-F]{1,6}/, 'string.char'],
      [/#\\./, 'string.char'],

      // Booleans
      [/#t(?:rue)?(?=[\s()\[\]{}",'`;])/, 'constant.boolean'],
      [/#f(?:alse)?(?=[\s()\[\]{}",'`;])/, 'constant.boolean'],
      [/#t(?:rue)?$/, 'constant.boolean'],
      [/#f(?:alse)?$/, 'constant.boolean'],

      // Regexp literals
      [/#rx"/, 'regexp', '@regexp'],
      [/#px"/, 'regexp', '@regexp'],

      // Byte strings
      [/#"/, 'string', '@string'],

      // Numbers with radix prefix
      [/#[bB][01]+(?:\/[01]+)?/, 'number'],
      [/#[oO][0-7]+(?:\/[0-7]+)?/, 'number'],
      [/#[xX][0-9a-fA-F]+(?:\/[0-9a-fA-F]+)?/, 'number'],
      [/#[dD][0-9]+(?:\/[0-9]+)?/, 'number'],

      // Exact/inexact prefix
      [/#[eEiI]#[bBoOxXdD][0-9a-fA-F+\-.\/]+/, 'number'],
      [/#[eEiI][0-9+\-.\/]+/, 'number'],

      // Numbers: floats, fractions, integers (must come before symbol matching)
      [/[+-]?[0-9]+\.[0-9]*(?:[eE][+-]?[0-9]+)?/, 'number.float'],
      [/[+-]?\.[0-9]+(?:[eE][+-]?[0-9]+)?/, 'number.float'],
      [/[+-]?[0-9]+[eE][+-]?[0-9]+/, 'number.float'],
      [/[+-]?[0-9]+\/[0-9]+/, 'number.fraction'],
      [/[+-]?[0-9]+/, 'number'],

      // Complex numbers: 1+2i, 3-4i
      [/[+-]?[0-9]+(?:\.[0-9]*)?[+-][0-9]+(?:\.[0-9]*)?i/, 'number'],

      // Quote shorthand
      [/'/, 'keyword.quote'],
      [/`/, 'keyword.quasiquote'],
      [/,@/, 'keyword.unquote-splicing'],
      [/,/, 'keyword.unquote'],
      [/#'/, 'keyword.syntax-quote'],
      [/#`/, 'keyword.quasisyntax'],
      [/#,@/, 'keyword.unsyntax-splicing'],
      [/#,/, 'keyword.unsyntax'],

      // Hash reader syntax: #hash, #hasheq, etc.
      [/#hash(?:eq|eqv)?(?=\()/, 'type'],

      // Vectors: #(...)
      [/#(?=\()/, 'type'],

      // Brackets
      [/[()[\]{}]/, '@brackets'],

      // Dot (pair notation)
      [/\.(?=\s)/, 'delimiter'],

      // Keywords (identifiers starting with #:)
      [/#:[^\s()\[\]{}",'`;#|\\]+/, 'variable.parameter'],

      // Identifiers — check against keyword list
      [/[^\s()\[\]{}",'`;#|\\][^\s()\[\]{}",'`;#|\\]*/, {
        cases: {
          '@keywords': 'keyword',
          '@default': 'identifier',
        },
      }],
    ],

    // Nested block comment state
    blockComment: [
      [/#\|/, 'comment', '@push'],   // nested opening
      [/\|#/, 'comment', '@pop'],    // closing
      [/[^#|]+/, 'comment'],         // anything else
      [/./, 'comment'],              // single char fallback
    ],

    // Shebang line
    shebang: [
      [/.*$/, 'comment', '@pop'],
    ],

    // String state (handles escape sequences)
    string: [
      [/[^\\"]+/, 'string'],
      [/\\[abtnvfre\\"']/, 'string.escape'],
      [/\\[0-7]{1,3}/, 'string.escape'],
      [/\\x[0-9a-fA-F]{1,2}/, 'string.escape'],
      [/\\u[0-9a-fA-F]{1,4}/, 'string.escape'],
      [/\\U[0-9a-fA-F]{1,8}/, 'string.escape'],
      [/\\\n/, 'string.escape'],
      [/"/, 'string', '@pop'],
    ],

    // Regexp literal state
    regexp: [
      [/[^\\"]+/, 'regexp'],
      [/\\./, 'regexp.escape'],
      [/"/, 'regexp', '@pop'],
    ],
  },
};
