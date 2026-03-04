// primitives/terminal.js — mr-terminal
//
// xterm.js wrapper as a Lit Web Component.  Dynamically imports the
// vendored xterm bundle and FitAddon, creates a terminal instance
// inside Shadow DOM, and wires it to a Rust-side PTY via Tauri
// commands and events.
//
// PTY communication goes DIRECTLY to Rust (not through the Racket
// bridge) to keep keystroke latency minimal.
//
// Tauri commands (invoked directly):
//   pty_input   — send user input to the PTY
//   pty_resize  — inform PTY of terminal size changes
//
// Tauri events (listened for):
//   pty:output  — PTY produced output (filtered by pty-id)
//   pty:exit    — PTY process exited (filtered by pty-id)

import { LitElement, html, css } from 'lit';

class MrTerminal extends LitElement {
  static properties = {
    ptyId: { type: String, attribute: 'pty-id' },
  };

  static styles = css`
    :host {
      display: block;
      width: 100%;
      height: 100%;
      position: relative;
      overflow: hidden;
      background: #1e1e1e;
    }

    #terminal-container {
      width: 100%;
      height: 100%;
    }
  `;

  constructor() {
    super();
    this.ptyId = '';

    /** @type {import('@xterm/xterm').Terminal|null} */
    this._terminal = null;
    /** @type {import('@xterm/addon-fit').FitAddon|null} */
    this._fitAddon = null;
    /** @type {ResizeObserver|null} */
    this._resizeObserver = null;
    /** @type {Function|null} Unlisten function for pty:output events. */
    this._unlistenOutput = null;
    /** @type {Function|null} Unlisten function for pty:exit events. */
    this._unlistenExit = null;
    /** @type {import('@xterm/xterm').IDisposable|null} */
    this._onDataDisposable = null;
  }

  render() {
    return html`
      <link rel="stylesheet" href="./vendor/xterm/xterm.css">
      <div id="terminal-container"></div>
    `;
  }

  async firstUpdated() {
    try {
      await this._initTerminal();
      this._setupPtyListeners();
      this._setupResizeObserver();
    } catch (err) {
      console.error('[mr-terminal] Failed to initialise xterm:', err);
    }
  }

  /**
   * Dynamically import xterm.js and FitAddon, then create the terminal
   * instance inside the shadow DOM container.
   */
  async _initTerminal() {
    const [xtermMod, fitMod] = await Promise.all([
      import('@xterm/xterm'),
      import('@xterm/addon-fit'),
    ]);

    const Terminal = xtermMod.Terminal;
    const FitAddon = fitMod.FitAddon;

    this._fitAddon = new FitAddon();

    this._terminal = new Terminal({
      cursorBlink: true,
      fontSize: 14,
      fontFamily: "'JetBrains Mono', 'Fira Code', monospace",
      theme: { background: '#1e1e1e', foreground: '#d4d4d4' },
    });

    this._terminal.loadAddon(this._fitAddon);

    const container = this.shadowRoot.getElementById('terminal-container');
    if (!container) {
      console.error('[mr-terminal] Terminal container not found');
      return;
    }

    this._terminal.open(container);
    this._fitAddon.fit();

    // Forward user input to the Rust PTY
    this._onDataDisposable = this._terminal.onData((data) => {
      if (!this.ptyId) return;
      window.__TAURI__.core.invoke('pty_input', {
        id: this.ptyId,
        data: data,
      }).catch((err) => {
        console.error('[mr-terminal] pty_input failed:', err);
      });
    });

    // Report initial size to the PTY
    this._reportResize();

    console.log('[mr-terminal] xterm terminal created', this.ptyId ? `(pty: ${this.ptyId})` : '');
  }

  /**
   * Listen for PTY output and exit events from Tauri.
   */
  async _setupPtyListeners() {
    if (!window.__TAURI__?.event?.listen) {
      console.warn('[mr-terminal] Tauri event API not available');
      return;
    }

    // pty:output — write PTY output to terminal (filtered by pty-id)
    this._unlistenOutput = await window.__TAURI__.event.listen('pty:output', (event) => {
      const { id, data } = event.payload;
      if (id === this.ptyId && this._terminal) {
        this._terminal.write(data);
      }
    });

    // pty:exit — show exit message when PTY process terminates
    this._unlistenExit = await window.__TAURI__.event.listen('pty:exit', (event) => {
      const { id, code } = event.payload;
      if (id === this.ptyId && this._terminal) {
        this._terminal.writeln('');
        this._terminal.writeln(`\r\n\x1b[90m[Process exited with code ${code ?? 'unknown'}]\x1b[0m`);
      }
    });
  }

  /**
   * Set up a ResizeObserver to auto-fit the terminal when the container
   * size changes, and report the new dimensions to the PTY.
   */
  _setupResizeObserver() {
    const container = this.shadowRoot.getElementById('terminal-container');
    if (!container) return;

    this._resizeObserver = new ResizeObserver(() => {
      if (this._fitAddon) {
        this._fitAddon.fit();
        this._reportResize();
      }
    });

    this._resizeObserver.observe(container);
  }

  /**
   * Report the current terminal dimensions to the Rust PTY.
   */
  _reportResize() {
    if (!this._terminal || !this.ptyId) return;

    window.__TAURI__.core.invoke('pty_resize', {
      id: this.ptyId,
      cols: this._terminal.cols,
      rows: this._terminal.rows,
    }).catch((err) => {
      console.error('[mr-terminal] pty_resize failed:', err);
    });
  }

  disconnectedCallback() {
    super.disconnectedCallback();

    // Disconnect ResizeObserver
    if (this._resizeObserver) {
      this._resizeObserver.disconnect();
      this._resizeObserver = null;
    }

    // Unlisten Tauri events
    if (this._unlistenOutput) {
      this._unlistenOutput();
      this._unlistenOutput = null;
    }
    if (this._unlistenExit) {
      this._unlistenExit();
      this._unlistenExit = null;
    }

    // Dispose xterm resources
    if (this._onDataDisposable) {
      this._onDataDisposable.dispose();
      this._onDataDisposable = null;
    }
    if (this._terminal) {
      this._terminal.dispose();
      this._terminal = null;
    }
    this._fitAddon = null;

    console.log('[mr-terminal] Terminal disposed');
  }
}

customElements.define('mr-terminal', MrTerminal);
