// bridge.js — Tauri IPC wrapper
//
// Provides a thin abstraction over Tauri's event system and invoke API.
// The Rust bridge emits events named "racket:<type>" for each JSON-RPC
// message received from the Racket process.  This module normalises them
// into plain type strings (e.g. "cell:update") and dispatches to
// registered handlers.
//
// ── Bridge lifecycle FSM ──────────────────────────────────────────────
//
//   idle ──initBridge()──→ booting ──signalReady()──→ ready ⇄ dispatching
//
//   idle        No Tauri API yet.  ensureListener() is a no-op.
//   booting     Tauri API available.  Handlers register, but no
//               event.listen() IPC calls — they're batched for
//               signalReady() to avoid WKWebView deadlocks.
//   ready       Normal operation.  New listeners register immediately.
//   dispatching Inside a Tauri event callback.  New listeners are
//               deferred to a macrotask (WKWebView deadlock avoidance).
// ──────────────────────────────────────────────────────────────────────

/** @type {'idle'|'booting'|'ready'|'dispatching'} */
let _state = 'idle';

/** @type {Map<string, Set<function>>} */
const handlers = new Map();

/** @type {Map<string, function>} Tauri unlisten functions keyed by type */
const activeListeners = new Map();

/** Reference to the Tauri listen function, set during initBridge(). */
let tauriListen = null;

/**
 * Queue for listener types awaiting sequential registration.
 * Used by both `dispatching` (deferred to macrotask) and `ready`
 * (immediate but serialised) states to ensure only one event.listen()
 * IPC call is in flight at a time — concurrent calls deadlock WKWebView.
 */
const _listenerQueue = [];
let _processingQueue = false;

/**
 * Process the listener registration queue one type at a time.
 * Re-entrant safe: if already running, new entries are picked up
 * by the existing while-loop iteration.
 */
async function processListenerQueue() {
  if (_processingQueue) return;
  _processingQueue = true;
  try {
    while (_listenerQueue.length > 0) {
      const type = _listenerQueue.shift();
      if (activeListeners.get(type) !== null) continue; // already registered
      await registerListener(type);
      console.log(`[bridge] queued listener registered: "${type}"`);
    }
  } finally {
    _processingQueue = false;
  }
}

/**
 * Register a Tauri event listener for the given message type.
 *
 * @param {string} type — message type, e.g. "cell:update"
 */
async function registerListener(type) {
  const tauriEventName = `racket:${type}`;
  const unlisten = await tauriListen(tauriEventName, (event) => {
    const msg = event.payload;
    console.debug(`[bridge] <-- ${type}`, msg);
    const cbs = handlers.get(type);
    if (cbs) {
      const prev = _state;
      _state = 'dispatching';
      try {
        for (const cb of cbs) {
          try {
            cb(msg);
          } catch (err) {
            console.error(`[bridge] handler error for "${type}":`, err);
          }
        }
      } finally {
        _state = prev;
      }
    }
  });
  activeListeners.set(type, unlisten);
}

/**
 * Ensure a Tauri event listener exists for the given message type.
 * Behaviour depends on the current FSM state — see diagram above.
 *
 * @param {string} type — message type, e.g. "cell:update"
 */
function ensureListener(type) {
  if (activeListeners.has(type)) return;

  // Mark as pending so concurrent calls don't double-register
  activeListeners.set(type, null);

  switch (_state) {
    case 'idle':
    case 'booting':
      // No IPC calls during boot — signalReady() will batch-register
      // all pending types sequentially to avoid WKWebView deadlock.
      return;

    case 'dispatching':
      // Defer to a macrotask — calling event.listen() from inside a
      // WKWebView evaluateJavaScript callback deadlocks macOS.
      // The queue ensures sequential registration even when multiple
      // types are deferred in the same dispatch cycle.
      _listenerQueue.push(type);
      setTimeout(() => processListenerQueue(), 0);
      return;

    case 'ready':
      // Queue for sequential processing — even outside a dispatch,
      // concurrent event.listen() IPC calls can deadlock WKWebView.
      _listenerQueue.push(type);
      processListenerQueue();
      return;
  }
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
 * Initialise the bridge.  Transitions: idle → booting.
 *
 * Stores a reference to the Tauri `listen` function so that `onMessage()`
 * can collect handler registrations.  Does NOT call frontend_ready —
 * the caller must call signalReady() after all handlers are registered.
 */
export async function initBridge() {
  tauriListen = window.__TAURI__?.event?.listen;
  if (!tauriListen) {
    console.warn('[bridge] Tauri event API not available — running outside Tauri?');
    return;
  }
  _state = 'booting';
  console.log(`[bridge] ${_state}: bridge initialised`);
}

/**
 * Register all pending listeners, then signal Rust to flush.
 * Transitions: booting → ready.
 *
 * Must be called AFTER all init functions (initCells, initRenderer, etc.)
 * have registered their handlers via onMessage().
 */
export async function signalReady() {
  if (_state !== 'booting') return;

  // Register all pending listeners sequentially — each await completes
  // before the next IPC call, avoiding concurrent event.listen() calls
  // that deadlock WKWebView on macOS.
  //
  // We loop until no pending types remain because async component init
  // (e.g. Monaco dynamic import → initLangIntel) can add new types
  // between our await calls while we're still in 'booting' state.
  let pending;
  while ((pending = [...activeListeners.entries()]
    .filter(([, unlisten]) => unlisten === null)
    .map(([type]) => type)).length > 0) {
    console.log(`[bridge] ${_state}: registering ${pending.length} listeners:`, pending);
    for (const type of pending) {
      await registerListener(type);
    }
  }

  _state = 'ready';
  console.log(`[bridge] ${_state}: all listeners registered, calling frontend_ready...`);

  try {
    await window.__TAURI__.core.invoke('frontend_ready');
    console.log(`[bridge] ${_state}: queued messages flushed`);
  } catch (err) {
    console.error(`[bridge] frontend_ready invoke failed:`, err);
  }
}

// ---------------------------------------------------------------------------
// Request / Response correlation
// ---------------------------------------------------------------------------
// Allows the frontend to send a request to Racket and receive a correlated
// response.  Each request carries a unique numeric `id`; when Racket replies
// with a message bearing the same `id`, the corresponding Promise resolves.
// Used by completion providers and other query-response interactions.

let nextRequestId = 1;
const pendingRequests = new Map();

/**
 * Send a request to the Racket process and return a Promise that resolves
 * when a response with a matching `id` arrives.
 *
 * @param {string} type — request name (e.g. "textDocument/completion")
 * @param {object} [payload={}] — additional fields merged into the message
 * @returns {Promise<any>}
 */
export function request(type, payload = {}) {
  const id = nextRequestId++;
  const message = { type: 'event', name: type, id, ...payload };
  return new Promise((resolve, reject) => {
    pendingRequests.set(id, { resolve, reject });
    window.__TAURI__.core.invoke('send_to_racket', { message })
      .catch(reject);
  });
}

/**
 * Resolve a pending request by its `id`.  Called when a response message
 * arrives from Racket bearing the same `id` that was sent in `request()`.
 *
 * @param {number} id — the request id
 * @param {any} data — the response payload
 */
export function resolveRequest(id, data) {
  const pending = pendingRequests.get(id);
  if (pending) {
    pendingRequests.delete(id);
    pending.resolve(data);
  }
}
