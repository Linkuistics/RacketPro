// theme.js — Apply Racket-driven themes to CSS custom properties
//
// Listens for "theme:apply" messages from Racket. Each message contains
// a map of CSS custom property names (without '--' prefix) to values.
// Updates document.documentElement.style and syncs Monaco editor theme.

import { onMessage } from './bridge.js';

// Keys in the theme hash that are NOT CSS variables
const NON_CSS_KEYS = new Set(['name', 'monaco-theme']);

/**
 * Apply a theme's CSS variables to the document root.
 * @param {Object} variables — theme hash with property names and values
 */
function applyCssVariables(variables) {
  const root = document.documentElement;
  for (const [key, value] of Object.entries(variables)) {
    if (NON_CSS_KEYS.has(key)) continue;
    root.style.setProperty(`--${key}`, value);
  }
}

/**
 * Set the Monaco editor theme.
 * @param {string} monacoTheme — "vs" or "vs-dark"
 */
function applyMonacoTheme(monacoTheme) {
  if (window.monaco?.editor) {
    window.monaco.editor.setTheme(monacoTheme);
  }
}

/**
 * Initialise theme message handlers.
 */
export function initTheme() {
  onMessage('theme:apply', (msg) => {
    const variables = msg.variables || {};
    const monacoTheme = variables['monaco-theme'] || 'vs';

    applyCssVariables(variables);
    applyMonacoTheme(monacoTheme);

    console.log(`[theme] Applied theme: ${variables.name || 'unknown'}`);
  });
}
