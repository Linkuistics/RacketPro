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

async function boot() {
  console.log('[MrRacket] Booting...');
  await initBridge();
  initCells();
  const app = document.getElementById('app');
  app.textContent = '';
  initRenderer(app);
  onMessage('lifecycle:ready', () => console.log('[MrRacket] Racket core is ready'));
  console.log('[MrRacket] Frontend ready, waiting for Racket...');
}

boot().catch(e => console.error('[MrRacket] Boot failed:', e));
