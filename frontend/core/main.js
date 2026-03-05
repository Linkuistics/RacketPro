// main.js — Application entry point
//
// Wires together the Tauri bridge, reactive cell registry, layout
// renderer, and all primitive web components.

import { initBridge, signalReady, onMessage } from './bridge.js';
import { initCells } from './cells.js';
import { initRenderer } from './renderer.js';
import './primitives/layout.js';
import './primitives/content.js';
import './primitives/input.js';
import './primitives/split.js';
import './primitives/chrome.js';
import './primitives/editor.js';
import './primitives/terminal.js';
import './primitives/tabs.js';
import './primitives/filetree.js';
import './primitives/panel-header.js';
import './primitives/error-panel.js';
import './primitives/stepper.js';
import './lang-intel.js';

async function boot() {
  console.log('[boot] 1/5 starting...');

  // Phase 1: Set up the bridge (registers tauriListen but does NOT flush)
  await initBridge();
  console.log('[boot] 2/5 bridge initialised');

  // Phase 2: Register all message handlers — these call onMessage() which
  // triggers ensureListener() to register Tauri event listeners eagerly.
  initCells();
  console.log('[boot] 3/5 cells initialised');
  const app = document.getElementById('app');
  app.textContent = '';
  initRenderer(app);
  console.log('[boot] 4/5 renderer initialised');
  onMessage('lifecycle:ready', () => console.log('[boot] Racket core is ready'));

  // Phase 3: Signal ready — now that all listeners are registered, tell
  // Rust to flush queued messages.  Events arrive into existing listeners.
  await signalReady();

  console.log('[boot] 5/5 signalReady complete — frontend ready');
}

boot().catch(e => console.error('[HeavyMental] Boot failed:', e));
