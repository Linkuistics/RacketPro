// main.js — Application entry point
//
// Wires together the Tauri bridge, reactive cell registry, layout
// renderer, and all primitive web components.

import { initBridge, signalReady, onMessage } from './bridge.js';
import { initCells } from './cells.js';
import { initRenderer } from './renderer.js';
import { initComponentRegistry } from './component-registry.js';
import { initTheme } from './theme.js';
import { initKeybindings } from './keybindings.js';
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
import './primitives/bottom-tabs.js';
import './primitives/tab-content.js';
import './primitives/macro-panel.js';
import './primitives/extension-manager.js';
import './primitives/search-panel.js';
import './primitives/settings-panel.js';
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
  initComponentRegistry();
  console.log('[boot] 4.5/5 component registry initialised');
  initTheme();
  console.log('[boot] 4.6/5 theme system initialised');
  initKeybindings();
  console.log('[boot] 4.7/5 keybindings initialised');
  onMessage('lifecycle:ready', () => console.log('[boot] Racket core is ready'));

  // UI font size — applied as a CSS custom property on :root
  const applyUiSettings = (s) => {
    if (s?.fontSize) {
      document.documentElement.style.setProperty('--ui-font-size', `${s.fontSize}px`);
    }
  };
  onMessage('ui:apply-settings', (msg) => applyUiSettings(msg.settings));
  onMessage('settings:current', (msg) => applyUiSettings(msg.settings?.ui));

  // Settings overlay: show/hide a full-screen settings panel
  onMessage('settings:open', () => {
    if (document.getElementById('settings-overlay')) return;
    const overlay = document.createElement('div');
    overlay.id = 'settings-overlay';
    Object.assign(overlay.style, {
      position: 'fixed', inset: '0', zIndex: '9999',
      background: 'rgba(0,0,0,0.4)',
      display: 'flex', alignItems: 'center', justifyContent: 'center',
    });
    const panel = document.createElement('hm-settings-panel');
    Object.assign(panel.style, {
      width: '720px', height: '500px',
      borderRadius: '8px', overflow: 'hidden',
      boxShadow: '0 8px 32px rgba(0,0,0,0.3)',
    });
    overlay.appendChild(panel);
    document.body.appendChild(overlay);
    // Close on backdrop click or Escape
    overlay.addEventListener('click', (e) => {
      if (e.target === overlay) overlay.remove();
    });
    const onKey = (e) => {
      if (e.key === 'Escape') { overlay.remove(); window.removeEventListener('keydown', onKey, true); }
    };
    window.addEventListener('keydown', onKey, true);
  });

  // Phase 3: Signal ready — now that all listeners are registered, tell
  // Rust to flush queued messages.  Events arrive into existing listeners.
  await signalReady();

  console.log('[boot] 5/5 signalReady complete — frontend ready');
}

boot().catch(e => console.error('[HeavyMental] Boot failed:', e));
