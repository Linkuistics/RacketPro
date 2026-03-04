// hm-element.js — Base class for HeavyMental Web Components
//
// Extends LitElement with a deferred _init() hook that runs in a clean
// macrotask, avoiding the WKWebView IPC deadlock that occurs when a
// component makes Tauri IPC calls (event.listen, invoke, etc.) during
// the synchronous layout:set render pass.
//
// Components should override _init() instead of firstUpdated() for any
// initialisation that involves IPC (onMessage, dispatch, invoke, etc.).
// Simple render-only components can still use firstUpdated() safely.

import { LitElement } from 'lit';

export class HmElement extends LitElement {
  firstUpdated() {
    // Defer to a new macrotask so we are never inside a WKWebView
    // IPC callback when _init() makes its own IPC calls.
    setTimeout(() => this._init(), 0);
  }

  /**
   * Override this instead of firstUpdated() for any initialisation
   * that involves Tauri IPC (onMessage, dispatch, invoke, etc.).
   * Guaranteed to run in a clean macrotask context.
   */
  _init() {}
}
