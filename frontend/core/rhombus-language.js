// rhombus-language.js — Monarch tokenizer for Rhombus
//
// Rhombus is a Racket language with Python-like syntax.
// This tokenizer handles the basic syntax for editing comfort.

export const rhombusLanguageId = 'rhombus';

export const rhombusLanguageConfig = {
  comments: {
    lineComment: '//',
    blockComment: ['/*', '*/'],
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
    { open: "'", close: "'", notIn: ['string'] },
    { open: '/*', close: '*/' },
  ],
  surroundingPairs: [
    { open: '(', close: ')' },
    { open: '[', close: ']' },
    { open: '{', close: '}' },
    { open: '"', close: '"' },
  ],
  indentationRules: {
    increaseIndentPattern: /:\s*$/,
    decreaseIndentPattern: /^\s*(else|catch|finally)\b/,
  },
};

export const rhombusTokenProvider = {
  defaultToken: '',
  ignoreCase: false,

  keywords: [
    'fun', 'def', 'let', 'val', 'var',
    'class', 'interface', 'extends', 'implements', 'mixin',
    'method', 'override', 'abstract', 'final', 'private',
    'constructor', 'field', 'property',
    'match', 'if', 'cond', 'when', 'unless', 'else',
    'for', 'each', 'in', 'block', 'begin',
    'import', 'export', 'open', 'module', 'namespace',
    'annot', 'bind', 'macro', 'expr', 'defn', 'decl',
    'syntax_class', 'pattern',
    'try', 'catch', 'finally', 'throw',
    'is_a', 'instanceof',
    'this', 'super',
    'enum', 'operator',
    'values', 'return',
  ],

  typeKeywords: [
    'Int', 'String', 'Boolean', 'Float', 'Void', 'Any',
    'List', 'Map', 'Set', 'Array', 'Pair',
    'Syntax', 'Identifier',
  ],

  operators: [
    '=', '==', '!=', '<', '>', '<=', '>=',
    '+', '-', '*', '/', '%',
    '&&', '||', '!', '~',
    '.', '::', ':~', '|>', '++',
    '..', '...', ':',
  ],

  symbols: /[=><!~?:&|+\-*\/\^%]+/,

  tokenizer: {
    root: [
      // #lang line
      [/^#lang\s+.*$/, 'meta'],

      // Whitespace
      [/\s+/, 'white'],

      // Block comments
      [/\/\*/, 'comment', '@blockComment'],

      // Line comments
      [/\/\/.*$/, 'comment'],

      // @-expression comments
      [/@\/\/.*$/, 'comment'],

      // Strings
      [/"/, 'string', '@string'],

      // Character/byte literals
      [/#'[^']*'/, 'string.char'],

      // Booleans
      [/#true\b/, 'constant.boolean'],
      [/#false\b/, 'constant.boolean'],

      // Numbers
      [/[+-]?[0-9]+\.[0-9]*(?:[eE][+-]?[0-9]+)?/, 'number.float'],
      [/[+-]?\.[0-9]+(?:[eE][+-]?[0-9]+)?/, 'number.float'],
      [/0[xX][0-9a-fA-F]+/, 'number.hex'],
      [/0[bB][01]+/, 'number.binary'],
      [/[+-]?[0-9]+/, 'number'],

      // | alternative separator
      [/\|/, 'keyword.operator'],

      // Brackets
      [/[()[\]{}]/, '@brackets'],

      // Operators
      [/@symbols/, {
        cases: {
          '@operators': 'operator',
          '@default': 'delimiter',
        },
      }],

      // Keywords and identifiers
      [/[a-zA-Z_]\w*/, {
        cases: {
          '@keywords': 'keyword',
          '@typeKeywords': 'type',
          '@default': 'identifier',
        },
      }],

      // ~identifier (binding patterns)
      [/~[a-zA-Z_]\w*/, 'variable.parameter'],
    ],

    blockComment: [
      [/\/\*/, 'comment', '@push'],
      [/\*\//, 'comment', '@pop'],
      [/[^/*]+/, 'comment'],
      [/./, 'comment'],
    ],

    string: [
      [/[^\\"$]+/, 'string'],
      [/\\[abtnvfre\\"']/, 'string.escape'],
      [/\$\{/, 'delimiter.bracket', '@interpolation'],
      [/\$[a-zA-Z_]\w*/, 'variable'],
      [/"/, 'string', '@pop'],
    ],

    interpolation: [
      [/\}/, 'delimiter.bracket', '@pop'],
      { include: 'root' },
    ],
  },
};
