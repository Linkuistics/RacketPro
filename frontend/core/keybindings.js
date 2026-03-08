// keybindings.js — Global keyboard shortcut handler
//
// Receives the active keymap from Racket via "keybindings:set" messages.
// Captures keydown events that Monaco doesn't handle and dispatches
// the mapped action back to Racket.

import { onMessage, dispatch } from './bridge.js';

/** @type {Map<string, string>} shortcut → action */
const keymap = new Map();

/** @type {boolean} whether we're in recording mode (for keybinding editor) */
let recording = false;

/** @type {function|null} callback for recording mode */
let recordCallback = null;

/**
 * Convert a KeyboardEvent to a shortcut string like "Cmd+Shift+F".
 */
function eventToShortcut(e) {
  const parts = [];
  if (e.metaKey || e.ctrlKey) parts.push('Cmd');
  if (e.altKey) parts.push('Alt');
  if (e.shiftKey) parts.push('Shift');

  const key = e.key;
  // Skip modifier-only keys
  if (['Meta', 'Control', 'Alt', 'Shift'].includes(key)) return null;

  // Normalize key names
  const normalizedKey = key.length === 1 ? key.toUpperCase() : key;
  parts.push(normalizedKey);

  return parts.join('+');
}

/**
 * Initialise the keybinding system.
 */
export function initKeybindings() {
  // Receive keymap from Racket
  onMessage('keybindings:set', (msg) => {
    keymap.clear();
    const kb = msg.keybindings || {};
    for (const [shortcut, action] of Object.entries(kb)) {
      keymap.set(shortcut, action);
    }
    console.log(`[keybindings] Loaded ${keymap.size} keybindings`);
  });

  // Global keydown handler
  document.addEventListener('keydown', (e) => {
    // Recording mode for keybinding editor
    if (recording && recordCallback) {
      e.preventDefault();
      e.stopPropagation();
      const shortcut = eventToShortcut(e);
      if (shortcut) {
        recordCallback(shortcut);
        recording = false;
        recordCallback = null;
      }
      return;
    }

    const shortcut = eventToShortcut(e);
    if (!shortcut) return;

    const action = keymap.get(shortcut);
    if (action) {
      // Don't capture if focus is inside Monaco editor — let Monaco handle it
      // unless it's a shortcut Monaco wouldn't know about
      const activeEl = document.activeElement;
      const inMonaco = activeEl?.closest?.('.monaco-editor');

      // These shortcuts should always be captured (not editor-internal)
      const alwaysCapture = new Set([
        'settings', 'find-in-project', 'new-file', 'open-file',
        'save-file', 'run', 'step-through', 'expand-macros',
      ]);

      if (inMonaco && !alwaysCapture.has(action)) {
        return; // Let Monaco handle it
      }

      e.preventDefault();
      e.stopPropagation();
      dispatch('keybinding:action', { action });
    }
  }, true); // Use capture phase
}

/**
 * Start recording mode for the keybinding editor.
 * The next key combination will be passed to the callback.
 * @param {function} callback — receives the shortcut string
 */
export function startRecording(callback) {
  recording = true;
  recordCallback = callback;
}

/**
 * Cancel recording mode.
 */
export function cancelRecording() {
  recording = false;
  recordCallback = null;
}

/**
 * Get the current keymap for display in settings.
 * @returns {Map<string, string>}
 */
export function getKeymap() {
  return new Map(keymap);
}
