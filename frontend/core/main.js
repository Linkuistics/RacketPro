// main.js — Application entry point
//
// Wires together the Tauri bridge, reactive cell registry, layout
// renderer, and all primitive web components.

import { initBridge, onMessage } from './bridge.js';
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

async function boot() {
  console.log('[HeavyMental] Booting...');
  await initBridge();
  initCells();
  const app = document.getElementById('app');
  app.textContent = '';
  initRenderer(app);
  onMessage('lifecycle:ready', () => console.log('[HeavyMental] Racket core is ready'));
  console.log('[HeavyMental] Frontend ready, waiting for Racket...');
}

boot().catch(e => console.error('[HeavyMental] Boot failed:', e));
