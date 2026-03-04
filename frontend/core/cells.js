// cells.js — Signal-based cell registry
//
// Cells are named reactive values managed by the Racket process.  The
// Racket side sends `cell:register` (initial value) and `cell:update`
// (new value) messages.  Each cell is backed by a @preact/signals-core
// `signal`, so any Lit component that reads a cell's `.value` inside an
// `effect()` will automatically re-render when the value changes.

import { signal } from '@preact/signals-core';
import { onMessage } from './bridge.js';

/** @type {Map<string, import('@preact/signals-core').Signal>} */
const cells = new Map();

/**
 * Get (or lazily create) the signal for a named cell.
 *
 * @param {string} name — cell name, e.g. "counter"
 * @returns {import('@preact/signals-core').Signal}
 */
export function getCell(name) {
  if (!cells.has(name)) {
    cells.set(name, signal(undefined));
  }
  return cells.get(name);
}

/**
 * Resolve a value that may be a cell reference.
 *
 * If `value` is a string starting with "cell:", return the current
 * `.value` of the corresponding signal (reading it will subscribe an
 * enclosing `effect`).  Otherwise return the value as-is.
 *
 * @param {*} value
 * @returns {*}
 */
export function resolveValue(value) {
  if (typeof value === 'string' && value.startsWith('cell:')) {
    const cellName = value.slice(5); // strip "cell:"
    return getCell(cellName).value;
  }
  return value;
}

/**
 * Wire up the bridge listeners that keep the cell registry in sync with
 * the Racket process.
 */
export function initCells() {
  // cell:register — Racket sends this once per cell at startup
  onMessage('cell:register', (msg) => {
    const { name, value } = msg;
    if (!name) return;
    const cell = getCell(name);
    cell.value = value;
    console.debug(`[cells] registered "${name}" =`, value);
  });

  // cell:update — Racket sends this whenever a cell value changes
  onMessage('cell:update', (msg) => {
    const { name, value } = msg;
    if (!name) return;
    const cell = getCell(name);
    cell.value = value;
    console.debug(`[cells] updated "${name}" =`, value);
  });

  console.log('[cells] Cell registry initialised');
}
