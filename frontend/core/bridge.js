// bridge.js — Tauri IPC wrapper
//
// Provides a thin abstraction over Tauri's event system and invoke API.
// The Rust bridge emits events named "racket:<type>" for each JSON-RPC
// message received from the Racket process.  This module normalises them
// into plain type strings (e.g. "cell:update") and dispatches to
// registered handlers.

/** @type {Map<string, Set<function>>} */
const handlers = new Map();

/** @type {Map<string, function>} Tauri unlisten functions keyed by type */
const activeListeners = new Map();

/** Reference to the Tauri listen function, set during initBridge(). */
let tauriListen = null;

/**
 * Ensure a Tauri event listener exists for the given message type.
 * Lazily creates one the first time a handler is registered for a type,
 * so new message types from Racket work without updating a whitelist.
 *
 * @param {string} type — message type, e.g. "cell:update"
 */
async function ensureListener(type) {
  if (activeListeners.has(type) || !tauriListen) return;

  const tauriEventName = `racket:${type}`;
  const unlisten = await tauriListen(tauriEventName, (event) => {
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
  activeListeners.set(type, unlisten);
}

/**
 * Register a handler for a specific Racket message type.
 * When the Rust bridge emits a "racket:<type>" Tauri event, all handlers
 * registered under <type> will be called with the message payload.
 *
 * Lazily registers a Tauri listener the first time a handler is added for
 * a given type, so new message types work without maintaining a whitelist.
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

  // Lazily register the Tauri listener for this type
  ensureListener(type);

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
 * Initialise the bridge.
 *
 * Stores a reference to the Tauri `listen` function so that `onMessage()`
 * can lazily register listeners for any message type.  After init, signals
 * the Rust backend via the `frontend_ready` command so that queued startup
 * messages are flushed to the WebView.
 */
export async function initBridge() {
  tauriListen = window.__TAURI__?.event?.listen;
  if (!tauriListen) {
    console.warn('[bridge] Tauri event API not available — running outside Tauri?');
    return;
  }

  // Eagerly register listeners for any types that already have handlers
  // (registered before initBridge was called).
  for (const type of handlers.keys()) {
    await ensureListener(type);
  }

  // Signal the Rust backend that our listeners are ready — this flushes
  // any messages that Racket emitted before the WebView was loaded.
  try {
    await window.__TAURI__.core.invoke('frontend_ready');
    console.log('[bridge] frontend_ready acknowledged — queued messages flushed');
  } catch (err) {
    console.error('[bridge] frontend_ready invoke failed:', err);
  }

  console.log('[bridge] Bridge initialised');
}
