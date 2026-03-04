// bridge.js — Tauri IPC wrapper
//
// Provides a thin abstraction over Tauri's event system and invoke API.
// The Rust bridge emits events named "racket:<type>" for each JSON-RPC
// message received from the Racket process.  This module normalises them
// into plain type strings (e.g. "cell:update") and dispatches to
// registered handlers.

/** @type {Map<string, Set<function>>} */
const handlers = new Map();

/**
 * Register a handler for a specific Racket message type.
 * When the Rust bridge emits a "racket:<type>" Tauri event, all handlers
 * registered under <type> will be called with the message payload.
 *
 * @param {string} type — message type, e.g. "cell:update"
 * @param {function} callback — receives the full message object
 * @returns {function} unsubscribe function
 */
export function onMessage(type, callback) {
  if (!handlers.has(type)) {
    handlers.set(type, new Set());
  }
  handlers.get(type).add(callback);

  // Return an unsubscribe function
  return () => {
    const set = handlers.get(type);
    if (set) {
      set.delete(callback);
      if (set.size === 0) handlers.delete(type);
    }
  };
}

/**
 * Send an event to the Racket process via the Tauri invoke bridge.
 * This calls the `send_to_racket` command defined in lib.rs.
 *
 * @param {string} event — event name (e.g. "increment")
 * @param {object} [payload={}] — additional fields merged into the message
 */
export async function dispatch(event, payload = {}) {
  const message = { type: 'event', name: event, ...payload };
  try {
    await window.__TAURI__.core.invoke('send_to_racket', { message });
  } catch (err) {
    console.error(`[bridge] dispatch("${event}") failed:`, err);
  }
}

/**
 * Initialise the bridge by subscribing to all known Tauri event types
 * emitted by the Rust bridge.  Each Tauri event name is "racket:<type>".
 *
 * The event payload from Tauri is `{ payload: <message> }` — we unwrap
 * it and fan out to the registered handlers.
 */
export async function initBridge() {
  const eventTypes = [
    'cell:register',
    'cell:update',
    'layout:set',
    'lifecycle:ready',
    'pong',
  ];

  const listen = window.__TAURI__?.event?.listen;
  if (!listen) {
    console.warn('[bridge] Tauri event API not available — running outside Tauri?');
    return;
  }

  for (const type of eventTypes) {
    const tauriEventName = `racket:${type}`;
    await listen(tauriEventName, (event) => {
      const msg = event.payload;
      console.debug(`[bridge] <-- ${type}`, msg);
      const cbs = handlers.get(type);
      if (cbs) {
        for (const cb of cbs) {
          try {
            cb(msg);
          } catch (err) {
            console.error(`[bridge] handler error for "${type}":`, err);
          }
        }
      }
    });
  }

  console.log('[bridge] Tauri event listeners registered');
}
