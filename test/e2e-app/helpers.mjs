// helpers.mjs — Core utilities for driving the live HeavyMental app via the
// debug eval facility.  Write JS to eval-input.js → poll eval-output.txt.
//
// Usage:  import { evalInApp, waitForApp, ... } from './helpers.mjs';

import { writeFileSync, readFileSync, unlinkSync, existsSync } from 'node:fs';

// ── File paths ──────────────────────────────────────────────────────────

const DEBUG_DIR  = '/tmp/heavymental-debug';
const EVAL_INPUT = `${DEBUG_DIR}/eval-input.js`;
const EVAL_OUTPUT = `${DEBUG_DIR}/eval-output.txt`;

// ── Timing ──────────────────────────────────────────────────────────────

const POLL_MS         = 200;   // how often we check for output
const EVAL_TIMEOUT_MS = 10_000; // max wait for a single eval
const APP_TIMEOUT_MS  = 30_000; // max wait for app boot

const sleep = ms => new Promise(r => setTimeout(r, ms));

// ── Core eval ───────────────────────────────────────────────────────────

/**
 * Execute JavaScript in the running WebView via the eval facility.
 *
 * The Rust watcher wraps our code in `(async function() { CODE })()`,
 * so `return <expr>` works and `await` is available.
 *
 * @param {string} jsCode  — Code to evaluate (use `return` for a value)
 * @returns {Promise<any>}   Parsed result (string, object, or undefined)
 * @throws If the eval returns an ERROR: prefix or times out
 */
export async function evalInApp(jsCode) {
  // 1. Remove stale output so we detect only a FRESH result
  if (existsSync(EVAL_OUTPUT)) unlinkSync(EVAL_OUTPUT);

  // 2. Write the code for the watcher to pick up
  writeFileSync(EVAL_INPUT, jsCode, 'utf-8');

  // 3. Poll for the result
  const deadline = Date.now() + EVAL_TIMEOUT_MS;
  while (Date.now() < deadline) {
    await sleep(POLL_MS);
    if (!existsSync(EVAL_OUTPUT)) continue;

    const raw = readFileSync(EVAL_OUTPUT, 'utf-8');

    // Error from JS
    if (raw.startsWith('ERROR: ')) {
      throw new Error(`evalInApp error:\n${raw}`);
    }
    // Error from Rust eval() itself
    if (raw.startsWith('RUST_EVAL_ERROR: ')) {
      throw new Error(`evalInApp Rust error:\n${raw}`);
    }
    // Explicit undefined return
    if (raw === '(undefined)') return undefined;

    // Try JSON parse (objects/arrays/numbers/booleans)
    try { return JSON.parse(raw); } catch { /* not JSON */ }

    // Plain string
    return raw;
  }

  throw new Error(`evalInApp timed out after ${EVAL_TIMEOUT_MS}ms`);
}

// ── Wait helpers ────────────────────────────────────────────────────────

/**
 * Wait until the app's WebView has rendered (hm-vbox exists).
 */
export async function waitForApp() {
  const deadline = Date.now() + APP_TIMEOUT_MS;
  while (Date.now() < deadline) {
    try {
      const ok = await evalInApp(
        `return document.querySelector('hm-vbox') !== null`
      );
      if (ok) return;
    } catch {
      // App not ready yet — keep polling
    }
    await sleep(1000);
  }
  throw new Error(`waitForApp timed out after ${APP_TIMEOUT_MS}ms`);
}

/**
 * Poll until a JS expression returns a truthy value.
 *
 * @param {string} jsExpr    — Expression (wrapped in `return (...)`)
 * @param {number} timeoutMs — Max wait (default 10s)
 * @returns {Promise<any>}     The truthy result
 */
export async function waitForCondition(jsExpr, timeoutMs = EVAL_TIMEOUT_MS) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const val = await evalInApp(`return await (${jsExpr})`);
      if (val) return val;
    } catch { /* not ready yet */ }
    await sleep(POLL_MS);
  }
  throw new Error(`waitForCondition timed out: ${jsExpr}`);
}

// ── DOM query helpers ───────────────────────────────────────────────────

/**
 * querySelector inside a custom element's shadow root.
 * Returns the element's textContent (or null if not found).
 */
export function queryShadow(tagName, selector) {
  return evalInApp(`
    const el = document.querySelector('${tagName}');
    if (!el || !el.shadowRoot) return null;
    const target = el.shadowRoot.querySelector('${selector}');
    return target ? target.textContent.trim() : null;
  `);
}

/**
 * querySelectorAll inside shadow root — returns array of textContent strings.
 */
export function queryShadowAll(tagName, selector) {
  return evalInApp(`
    const el = document.querySelector('${tagName}');
    if (!el || !el.shadowRoot) return [];
    const nodes = el.shadowRoot.querySelectorAll('${selector}');
    return Array.from(nodes).map(n => n.textContent.trim());
  `);
}

/**
 * Check if a DOM element exists.
 */
export function elementExists(selector) {
  return evalInApp(`return document.querySelector('${selector}') !== null`);
}

/**
 * Read a reactive cell's current signal value.
 */
export function getCellValue(name) {
  return evalInApp(`
    const { getCell } = await import('/core/cells.js');
    const sig = getCell('${name}');
    return sig.value !== undefined ? sig.value : null;
  `);
}

/**
 * Read a property from a custom element instance.
 */
export function getComponentProp(tagName, prop) {
  return evalInApp(`
    const el = document.querySelector('${tagName}');
    return el ? el.${prop} : null;
  `);
}

/**
 * Dispatch an event to Racket via the bridge.
 * This sends { type: "event", name, ...payload } to Racket.
 */
export function dispatchEvent(name, payload = {}) {
  const payloadStr = JSON.stringify(payload);
  return evalInApp(`
    const { dispatch } = await import('/core/bridge.js');
    await dispatch('${name}', ${payloadStr});
    return true;
  `);
}

/**
 * Send a raw JSON-RPC message to Racket (for non-event message types
 * like "file:write:result" that bypass the event dispatcher).
 */
export function sendRawMessage(message) {
  const msgStr = JSON.stringify(message);
  return evalInApp(`
    await window.__TAURI__.core.invoke('send_to_racket', { message: ${msgStr} });
    return true;
  `);
}

// ── Monaco helpers ────────────────────────────────────────────────────

/**
 * Read the Monaco editor's current text content.
 */
export function getMonacoValue() {
  return evalInApp(`
    const ed = document.querySelector('hm-editor');
    return ed?._editor?.getValue() ?? null;
  `);
}

/**
 * Read Monaco diagnostic markers for the current model.
 * Returns array of { severity, message, startLineNumber, startColumn, ... }.
 */
export function getMonacoMarkers() {
  return evalInApp(`
    const ed = document.querySelector('hm-editor');
    if (!ed?._editor || !ed?._monaco) return [];
    const model = ed._editor.getModel();
    if (!model) return [];
    return JSON.parse(JSON.stringify(
      ed._monaco.editor.getModelMarkers({ resource: model.uri })
    ));
  `);
}

/**
 * Read Monaco decorations, optionally filtered by CSS class prefix.
 * @param {string} [prefix] — Filter for inlineClassName starting with this prefix
 */
export function getMonacoDecorations(prefix = '') {
  return evalInApp(`
    const ed = document.querySelector('hm-editor');
    if (!ed?._editor || !ed?._monaco) return [];
    const all = ed._editor.getDecorationsInRange(
      new ed._monaco.Range(1, 1, 99999, 1)
    ) || [];
    const filtered = ${prefix ? `all.filter(d => d.options?.inlineClassName?.startsWith('${prefix}'))` : 'all'};
    return filtered.map(d => ({
      range: d.range,
      className: d.options?.inlineClassName || null,
    }));
  `);
}

/**
 * Read the Monaco model's language ID (e.g. "racket", "javascript").
 */
export function getMonacoLanguage() {
  return evalInApp(`
    const ed = document.querySelector('hm-editor');
    const model = ed?._editor?.getModel();
    return model ? model.getLanguageId() : null;
  `);
}

/**
 * Read the Monaco cursor position. Returns { lineNumber, column } (1-based).
 */
export function getMonacoCursorPosition() {
  return evalInApp(`
    const ed = document.querySelector('hm-editor');
    const pos = ed?._editor?.getPosition();
    return pos ? { lineNumber: pos.lineNumber, column: pos.column } : null;
  `);
}

// ── Terminal helpers ──────────────────────────────────────────────────

/**
 * Read xterm.js buffer content as a single string.
 */
export function getTerminalContent() {
  return evalInApp(`
    const term = document.querySelector('hm-terminal');
    const buf = term?._terminal?.buffer?.active;
    if (!buf) return '';
    const lines = [];
    for (let i = 0; i < buf.length; i++) {
      const line = buf.getLine(i);
      if (line) lines.push(line.translateToString(true));
    }
    return lines.filter(l => l.trim()).join('\\n');
  `);
}

// ── Cell helpers ─────────────────────────────────────────────────────

/**
 * Wait until a cell's value satisfies a predicate expression.
 * @param {string} name — Cell name
 * @param {string} predicateExpr — JS expression using `v` for the cell value
 * @param {number} [timeoutMs] — Max wait (default 10s)
 */
export function waitForCell(name, predicateExpr, timeoutMs = EVAL_TIMEOUT_MS) {
  return waitForCondition(`
    (async function() {
      const { getCell } = await import('/core/cells.js');
      const v = getCell('${name}').value;
      return (${predicateExpr});
    })()
  `, timeoutMs);
}

// ── Error panel helpers ─────────────────────────────────────────────

/**
 * Read error panel rows from shadow DOM.
 * Returns array of { icon, message, location }.
 */
export function getErrorPanelRows() {
  return evalInApp(`
    const panel = document.querySelector('hm-error-panel');
    if (!panel?.shadowRoot) return [];
    const rows = panel.shadowRoot.querySelectorAll('.row');
    return Array.from(rows).map(r => ({
      icon: r.querySelector('.icon')?.textContent?.trim() ?? '',
      message: r.querySelector('.message')?.textContent?.trim() ?? '',
      location: r.querySelector('.location')?.textContent?.trim() ?? '',
    }));
  `);
}

/**
 * Check if the error panel shows "No problems detected."
 */
export function errorPanelIsEmpty() {
  return evalInApp(`
    const panel = document.querySelector('hm-error-panel');
    if (!panel?.shadowRoot) return false;
    const empty = panel.shadowRoot.querySelector('.empty');
    return empty !== null;
  `);
}

// ── Assertions ──────────────────────────────────────────────────────────

export class AssertionError extends Error {
  constructor(message) {
    super(message);
    this.name = 'AssertionError';
  }
}

export function assert(value, message = 'assertion failed') {
  if (!value) throw new AssertionError(message);
}

export function assertEqual(actual, expected, message) {
  if (actual !== expected) {
    const msg = message
      ? `${message}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`
      : `expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`;
    throw new AssertionError(msg);
  }
}

export function assertContains(str, substr, message) {
  if (typeof str !== 'string' || !str.includes(substr)) {
    const msg = message
      ? `${message}: "${str}" does not contain "${substr}"`
      : `"${str}" does not contain "${substr}"`;
    throw new AssertionError(msg);
  }
}

export function assertTruthy(value, message) {
  if (!value) {
    throw new AssertionError(
      message || `expected truthy value, got ${JSON.stringify(value)}`
    );
  }
}

export function assertFalsy(value, message) {
  if (value) {
    throw new AssertionError(
      message || `expected falsy value, got ${JSON.stringify(value)}`
    );
  }
}
