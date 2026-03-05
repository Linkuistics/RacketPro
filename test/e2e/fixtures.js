// fixtures.js — Tauri mock injection, boot data, and shared test helpers
//
// Provides everything needed to test the HeavyMental frontend without
// a real Tauri backend.  The mock intercepts listen() / invoke() calls
// so we can fire simulated Racket messages and inspect what the frontend
// sends back.

// ── Tauri Mock ────────────────────────────────────────────────────────
// Injected via page.addInitScript() BEFORE the page loads.
// Must be a plain string (no imports, no ES module syntax).

export const TAURI_MOCK_SCRIPT = `
(function() {
  // Storage for registered Tauri event listeners
  window.__tauriListeners = {};

  // Storage for invoke() calls (frontend → Racket messages)
  window.__tauriInvocations = [];

  window.__TAURI__ = {
    core: {
      invoke: async function(cmd, args) {
        window.__tauriInvocations.push({ cmd, args });
        // Return empty for commands that expect a response
        if (cmd === 'frontend_ready') return;
        if (cmd === 'send_to_racket') return;
        if (cmd === 'debug_log') return;
        if (cmd === 'debug_write') return;
        if (cmd === 'list_dir') return { entries: [] };
        return null;
      },
    },
    event: {
      listen: async function(eventName, callback) {
        if (!window.__tauriListeners[eventName]) {
          window.__tauriListeners[eventName] = [];
        }
        window.__tauriListeners[eventName].push(callback);
        // Return an unlisten function
        return function() {
          var arr = window.__tauriListeners[eventName];
          if (arr) {
            var idx = arr.indexOf(callback);
            if (idx >= 0) arr.splice(idx, 1);
          }
        };
      },
    },
  };

  // Fire a simulated Racket message through the Tauri event system.
  // The bridge listens on "racket:<type>" events with payload = message object.
  window.__fireEvent = function(type, payload) {
    var eventName = 'racket:' + type;
    var listeners = window.__tauriListeners[eventName] || [];
    var event = { payload: payload };
    for (var i = 0; i < listeners.length; i++) {
      try { listeners[i](event); } catch(e) { console.error('[mock] listener error:', e); }
    }
  };

  // Retrieve invoke() calls filtered by command name
  window.__getInvocations = function(cmd) {
    return window.__tauriInvocations.filter(function(i) { return i.cmd === cmd; });
  };

  // Clear recorded invocations
  window.__clearInvocations = function() {
    window.__tauriInvocations = [];
  };
})();
`;

// ── Boot Data ─────────────────────────────────────────────────────────
// Mirrors the cells and layout from racket/heavymental-core/main.rkt

export const CELLS = [
  { name: 'current-file', value: '' },
  { name: 'file-dirty', value: false },
  { name: 'title', value: 'HeavyMental' },
  { name: 'status', value: 'Ready' },
  { name: 'language', value: '' },
  { name: 'cursor-pos', value: '' },
  { name: 'project-root', value: '/tmp/test-project' },
  { name: 'dirty-files', value: [] },
  { name: 'repl-running', value: false },
  { name: 'stepper-active', value: false },
  { name: 'stepper-step', value: 0 },
  { name: 'stepper-total', value: -1 },
];

export const LAYOUT = {
  type: 'vbox',
  props: { flex: '1' },
  children: [
    {
      type: 'split',
      props: { direction: 'horizontal', ratio: 0.17, 'min-size': 120 },
      children: [
        {
          type: 'filetree',
          props: { 'root-path': 'cell:project-root' },
          children: [],
        },
        {
          type: 'vbox',
          props: { flex: '1' },
          children: [
            { type: 'tabs', props: {}, children: [] },
            {
              type: 'breadcrumb',
              props: { file: 'cell:current-file', root: 'cell:project-root' },
              children: [],
            },
            {
              type: 'split',
              props: { direction: 'vertical', ratio: 0.65 },
              children: [
                {
                  type: 'editor',
                  props: { 'file-path': '', language: 'racket' },
                  children: [],
                },
                {
                  type: 'vbox',
                  props: { flex: '1' },
                  children: [
                    { type: 'panel-header', props: { label: 'TERMINAL' }, children: [] },
                    { type: 'terminal', props: { 'pty-id': 'repl' }, children: [] },
                    { type: 'panel-header', props: { label: 'PROBLEMS' }, children: [] },
                    { type: 'error-panel', props: {}, children: [] },
                    { type: 'stepper-toolbar', props: {}, children: [] },
                    { type: 'bindings-panel', props: {}, children: [] },
                  ],
                },
              ],
            },
          ],
        },
      ],
    },
    {
      type: 'statusbar',
      props: {
        content: 'cell:status',
        language: 'cell:language',
        position: 'cell:cursor-pos',
      },
      children: [],
    },
  ],
};

// ── Helper Functions ──────────────────────────────────────────────────

/**
 * Inject Tauri mock and navigate to the app.
 * Waits for initBridge() to complete and the renderer to be ready.
 */
export async function bootApp(page) {
  // Inject mock before any scripts run
  await page.addInitScript(TAURI_MOCK_SCRIPT);
  await page.goto('/');

  // Wait for the bridge to initialise (it calls frontend_ready)
  await page.waitForFunction(() =>
    window.__getInvocations('frontend_ready').length > 0
  );
}

/**
 * Send all cell registrations and the layout tree to simulate Racket boot.
 */
export async function sendBootMessages(page) {
  // Register all cells
  for (const cell of CELLS) {
    await page.evaluate(
      ({ name, value }) => window.__fireEvent('cell:register', { name, value }),
      cell
    );
  }

  // Send the layout
  await page.evaluate(
    (layout) => window.__fireEvent('layout:set', { layout }),
    LAYOUT
  );

  // Wait for layout to render — the root vbox should be in the DOM
  await page.waitForSelector('hm-vbox');
}

/**
 * Wait for Monaco editor to fully initialise inside hm-editor.
 * Returns when the internal _editor instance is available.
 */
export async function waitForMonaco(page) {
  await page.locator('hm-editor').evaluate((el) => {
    return new Promise((resolve) => {
      const check = () => (el._editor ? resolve() : setTimeout(check, 100));
      check();
    });
  });
}

/**
 * Fire a simulated event from "Racket" to the frontend.
 */
export async function fireEvent(page, type, payload) {
  await page.evaluate(
    ({ type, payload }) => window.__fireEvent(type, payload),
    { type, payload }
  );
}

/**
 * Get all send_to_racket invocations from the frontend.
 */
export async function getInvocations(page, cmd = 'send_to_racket') {
  return page.evaluate((cmd) => window.__getInvocations(cmd), cmd);
}

/**
 * Clear recorded invocations.
 */
export async function clearInvocations(page) {
  await page.evaluate(() => window.__clearInvocations());
}
