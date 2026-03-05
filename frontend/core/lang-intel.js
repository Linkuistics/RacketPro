// lang-intel.js — Language intelligence cache and Monaco providers
//
// Receives intel:* messages from Racket, caches data, and feeds
// Monaco providers. This is a thin rendering layer — Racket does
// all the heavy lifting.

import { onMessage, request, resolveRequest } from './bridge.js';

// Per-URI caches
const diagnosticsCache = new Map();
const hoversCache = new Map();
const arrowsCache = new Map();
const colorsCache = new Map();
const definitionsCache = new Map();

// Reference to Monaco and editor (set during init)
let monacoRef = null;
let editorRef = null;

/** Disposables for Monaco providers */
const disposables = [];

/** Arrow update callback (set by arrows.js) */
let arrowUpdateCallback = null;

export function onArrowsUpdated(cb) {
  arrowUpdateCallback = cb;
}

export function getArrows(uri) {
  return arrowsCache.get(uri) || [];
}

export function getHovers(uri) {
  return hoversCache.get(uri) || [];
}

export function getDefinitions(uri) {
  return definitionsCache.get(uri) || { defs: [], jumps: [] };
}

/**
 * Initialize language intelligence.
 * Must be called after Monaco is available.
 * @param {typeof import('monaco-editor').monaco} monaco
 * @param {import('monaco-editor').monaco.editor.IStandaloneCodeEditor} editor
 */
export function initLangIntel(monaco, editor) {
  monacoRef = monaco;
  editorRef = editor;

  // ── Diagnostics ──
  onMessage('intel:diagnostics', (msg) => {
    const { uri, items } = msg;
    diagnosticsCache.set(uri, items);
    applyDiagnostics(uri, items);
  });

  // ── Hovers ──
  onMessage('intel:hovers', (msg) => {
    const { uri, hovers } = msg;
    hoversCache.set(uri, hovers);
  });

  // ── Arrows ──
  onMessage('intel:arrows', (msg) => {
    const { uri, arrows } = msg;
    console.log(`[lang-intel] intel:arrows received: ${arrows.length} arrows for ${uri}, callback=${!!arrowUpdateCallback}`);
    arrowsCache.set(uri, arrows);
    if (arrowUpdateCallback) arrowUpdateCallback(uri, arrows);
  });

  // ── Colors ──
  onMessage('intel:colors', (msg) => {
    const { uri, colors } = msg;
    colorsCache.set(uri, colors);
    applySemanticColors(colors);
  });

  // ── Definitions ──
  onMessage('intel:definitions', (msg) => {
    const { uri, defs, jumps } = msg;
    definitionsCache.set(uri, { defs: defs || [], jumps: jumps || [] });
  });

  // ── Completion response ──
  onMessage('intel:completion-response', (msg) => {
    const { id } = msg;
    if (id) resolveRequest(id, msg);
  });

  // ── Clear ──
  onMessage('intel:clear', (msg) => {
    const { uri } = msg;
    diagnosticsCache.delete(uri);
    hoversCache.delete(uri);
    arrowsCache.delete(uri);
    colorsCache.delete(uri);
    definitionsCache.delete(uri);
    const model = editor.getModel();
    if (model) monaco.editor.setModelMarkers(model, 'racket', []);
    if (arrowUpdateCallback) arrowUpdateCallback(uri, []);
  });

  // Register Monaco providers
  registerProviders(monaco);

  console.log('[lang-intel] Language intelligence initialised');
}

// ── Diagnostics → Monaco markers ──

function applyDiagnostics(uri, items) {
  if (!monacoRef || !editorRef) return;
  const model = editorRef.getModel();
  if (!model) return;

  const severityMap = {
    error: monacoRef.MarkerSeverity.Error,
    warning: monacoRef.MarkerSeverity.Warning,
    info: monacoRef.MarkerSeverity.Info,
    hint: monacoRef.MarkerSeverity.Hint,
  };

  const markers = items.map((d) => ({
    severity: severityMap[d.severity] || monacoRef.MarkerSeverity.Error,
    message: d.message,
    startLineNumber: d.range.startLine,
    startColumn: d.range.startCol + 1, // Monaco is 1-based columns
    endLineNumber: d.range.endLine,
    endColumn: d.range.endCol + 1,
    source: d.source || 'check-syntax',
  }));

  monacoRef.editor.setModelMarkers(model, 'racket', markers);
}

// ── Semantic colors → decorations ──

let colorDecorations = null;

function applySemanticColors(colors) {
  if (!editorRef) return;

  const decos = colors.map((c) => ({
    range: new monacoRef.Range(
      c.range.startLine, c.range.startCol + 1,
      c.range.endLine, c.range.endCol + 1
    ),
    options: {
      inlineClassName: `hm-cs-${c.style}`,
    },
  }));

  if (colorDecorations) {
    colorDecorations.set(decos);
  } else {
    colorDecorations = editorRef.createDecorationsCollection(decos);
  }
}

// ── Monaco providers ──

function registerProviders(monaco) {
  // Hover provider
  disposables.push(
    monaco.languages.registerHoverProvider('racket', {
      provideHover(model, position) {
        const uri = editorRef?.filePath || '';
        const hovers = hoversCache.get(uri) || [];
        for (const h of hovers) {
          const r = h.range;
          if (position.lineNumber >= r.startLine &&
              position.lineNumber <= r.endLine &&
              position.column >= r.startCol + 1 &&
              position.column <= r.endCol + 1) {
            return {
              range: new monaco.Range(
                r.startLine, r.startCol + 1,
                r.endLine, r.endCol + 1
              ),
              contents: [{ value: h.contents }],
            };
          }
        }
        return null;
      },
    })
  );

  // Definition provider
  disposables.push(
    monaco.languages.registerDefinitionProvider('racket', {
      provideDefinition(model, position) {
        const uri = editorRef?.filePath || '';
        const data = definitionsCache.get(uri);
        if (!data) return null;

        // Check jump targets (references → definition sites)
        for (const j of data.jumps) {
          const r = j.range;
          if (position.lineNumber >= r.startLine &&
              position.lineNumber <= r.endLine &&
              position.column >= r.startCol + 1 &&
              position.column <= r.endCol + 1) {
            // Cross-file jump
            if (j.targetUri) {
              // TODO: open the target file
              return null;
            }
          }
        }

        // Check arrows — find arrow where cursor is at the "to" end
        // and jump to the "from" end (binding site)
        const arrows = arrowsCache.get(uri) || [];
        for (const a of arrows) {
          if (a.kind !== 'binding' && a.kind !== 'require') continue;
          const r = a.to;
          if (position.lineNumber >= r.startLine &&
              position.lineNumber <= r.endLine &&
              position.column >= r.startCol + 1 &&
              position.column <= r.endCol + 1) {
            return {
              uri: model.uri,
              range: new monaco.Range(
                a.from.startLine, a.from.startCol + 1,
                a.from.endLine, a.from.endCol + 1
              ),
            };
          }
        }
        return null;
      },
    })
  );

  // Completion provider (request/response with Racket)
  disposables.push(
    monaco.languages.registerCompletionItemProvider('racket', {
      triggerCharacters: ['('],
      async provideCompletionItems(model, position) {
        const word = model.getWordUntilPosition(position);
        const range = {
          startLineNumber: position.lineNumber,
          endLineNumber: position.lineNumber,
          startColumn: word.startColumn,
          endColumn: word.endColumn,
        };
        const uri = editorRef?.filePath || '';

        try {
          const response = await request('intel:completion-request', {
            uri,
            position: { line: position.lineNumber, col: position.column - 1 },
            prefix: word.word,
          });

          const items = (response?.items || []).map((item) => ({
            label: item.label,
            kind: monaco.languages.CompletionItemKind.Variable,
            insertText: item.label,
            range,
          }));

          return { suggestions: items };
        } catch (err) {
          console.error('[lang-intel] Completion request failed:', err);
          return { suggestions: [] };
        }
      },
    })
  );
}
