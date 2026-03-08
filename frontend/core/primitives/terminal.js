// primitives/terminal.js — hm-terminal
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
import { onMessage, dispatch } from '../bridge.js';

class HmTerminal extends LitElement {
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
      box-sizing: border-box;
      background: var(--bg-terminal, #FFFFFF);
      padding: 6px 8px;
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
    /** @type {import('@xterm/xterm').IDisposable|null} */
    this._linkProviderDisposable = null;
    /** @type {Function|null} Unlisten for terminal settings. */
    this._unsubSettings = null;
  }

  render() {
    return html`
      <link rel="stylesheet" href="./vendor/xterm/xterm.css">
      <div id="terminal-container"></div>
    `;
  }

  async firstUpdated() {
    try {
      // Set up PTY listeners FIRST so we don't miss early output
      // (the REPL prompt arrives before xterm finishes initialising).
      this._pendingOutput = [];
      await this._setupPtyListeners();

      await this._initTerminal();

      // Replay any output that arrived while xterm was loading
      for (const data of this._pendingOutput) {
        this._terminal.write(data);
      }
      this._pendingOutput = null;

      this._setupResizeObserver();
      this._setupSettingsListener();

      // Request saved settings — the boot-time terminal:apply-settings
      // message may have arrived before our listener was registered.
      dispatch('settings:request', {});

      // Focus the terminal so the REPL is ready for input on startup
      this._terminal.focus();
    } catch (err) {
      console.error('[hm-terminal] Failed to initialise xterm:', err);
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
      fontSize: 13,
      fontWeight: '300',
      fontFamily: "'SF Mono', 'Fira Code', Menlo, monospace",
      theme: {
        background: '#FFFFFF',
        foreground: '#333333',
        cursor: '#007ACC',
        cursorAccent: '#FFFFFF',
        selectionBackground: '#ADD6FF',
      },
    });

    this._terminal.loadAddon(this._fitAddon);

    const container = this.shadowRoot.getElementById('terminal-container');
    if (!container) {
      console.error('[hm-terminal] Terminal container not found');
      return;
    }

    this._terminal.open(container);
    this._fitAddon.fit();

    // Racket error link provider — detects "path:line:col:" patterns
    // in terminal output and makes them clickable to jump to source.
    this._linkProviderDisposable = this._terminal.registerLinkProvider({
      provideLinks: (bufferLineNumber, callback) => {
        const line = this._terminal.buffer.active.getLine(bufferLineNumber);
        if (!line) { callback(undefined); return; }
        const text = line.translateToString();

        // Match Racket error locations: /path/to/file.rkt:10:5
        const regex = /(\/[^\s:]+\.(?:rkt|rhm|scrbl)):(\d+):(\d+)/g;
        const links = [];
        let match;
        while ((match = regex.exec(text)) !== null) {
          // Capture match values in locals — the `match` variable mutates
          // on each iteration, so the activate closure must not reference it.
          const filePath = match[1];
          const fileLine = parseInt(match[2], 10);
          const fileCol = parseInt(match[3], 10);
          const startX = match.index + 1;
          const endX = match.index + match[0].length + 1;

          links.push({
            range: {
              start: { x: startX, y: bufferLineNumber },
              end: { x: endX, y: bufferLineNumber },
            },
            text: match[0],
            activate: () => {
              // Dispatch to Racket to open the file and jump to position
              window.__TAURI__.core.invoke('send_to_racket', {
                message: {
                  type: 'event',
                  name: 'editor:goto-file',
                  path: filePath,
                  line: fileLine,
                  col: fileCol,
                },
              }).catch((err) => {
                console.error('[hm-terminal] goto-file failed:', err);
              });
            },
          });
        }
        callback(links.length > 0 ? links : undefined);
      },
    });

    // Forward user input to the Rust PTY
    this._onDataDisposable = this._terminal.onData((data) => {
      if (!this.ptyId) return;
      window.__TAURI__.core.invoke('pty_input', {
        id: this.ptyId,
        data: data,
      }).catch((err) => {
        console.error('[hm-terminal] pty_input failed:', err);
      });
    });

    // Report initial size to the PTY
    this._reportResize();

    console.log('[hm-terminal] xterm terminal created', this.ptyId ? `(pty: ${this.ptyId})` : '');
  }

  /**
   * Listen for PTY output and exit events from Tauri.
   */
  async _setupPtyListeners() {
    if (!window.__TAURI__?.event?.listen) {
      console.warn('[hm-terminal] Tauri event API not available');
      return;
    }

    // pty:output — write PTY output to terminal (filtered by pty-id)
    this._unlistenOutput = await window.__TAURI__.event.listen('pty:output', (event) => {
      const { id, data } = event.payload;
      if (id !== this.ptyId) return;
      if (this._terminal) {
        this._terminal.write(data);
      } else if (this._pendingOutput) {
        this._pendingOutput.push(data);
      }
    });

    // pty:created — a new PTY was created for our pty-id; report the
    // current terminal dimensions so the new process knows its real size.
    // Without this, a restarted PTY defaults to 80×24 while xterm.js may
    // be a very different size, causing Racket's xrepl to crash.
    this._unlistenCreated = await window.__TAURI__.event.listen('pty:created', (event) => {
      const { id } = event.payload;
      if (id === this.ptyId) {
        this._reportResize();
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

    let resizeTimer = null;
    this._resizeObserver = new ResizeObserver(() => {
      // Debounce to prevent infinite resize loops when layout is settling
      if (resizeTimer) return;
      resizeTimer = setTimeout(() => {
        resizeTimer = null;
        if (this._fitAddon) {
          this._fitAddon.fit();
          this._reportResize();
        }
      }, 50);
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
      console.error('[hm-terminal] pty_resize failed:', err);
    });
  }

  /**
   * Listen for terminal settings changes and apply them live.
   */
  _setupSettingsListener() {
    const applyTerminalSettings = (s) => {
      if (!this._terminal || !s) return;
      if (s.fontSize) this._terminal.options.fontSize = s.fontSize;
      if (s.fontFamily) this._terminal.options.fontFamily = s.fontFamily;
      // Re-fit after font change (different font size = different grid)
      if (this._fitAddon) {
        this._fitAddon.fit();
        this._reportResize();
      }
    };
    this._unsubSettings = onMessage('terminal:apply-settings', (msg) => {
      applyTerminalSettings(msg.settings);
    });
    this._unsubSettings2 = onMessage('settings:current', (msg) => {
      applyTerminalSettings(msg.settings?.terminal);
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
    if (this._unlistenCreated) {
      this._unlistenCreated();
      this._unlistenCreated = null;
    }
    if (this._unlistenExit) {
      this._unlistenExit();
      this._unlistenExit = null;
    }

    // Unlisten settings
    if (this._unsubSettings) {
      this._unsubSettings();
      this._unsubSettings = null;
    }
    if (this._unsubSettings2) {
      this._unsubSettings2();
      this._unsubSettings2 = null;
    }

    // Dispose xterm resources
    if (this._linkProviderDisposable) {
      this._linkProviderDisposable.dispose();
      this._linkProviderDisposable = null;
    }
    if (this._onDataDisposable) {
      this._onDataDisposable.dispose();
      this._onDataDisposable = null;
    }
    if (this._terminal) {
      this._terminal.dispose();
      this._terminal = null;
    }
    this._fitAddon = null;

    console.log('[hm-terminal] Terminal disposed');
  }
}

customElements.define('hm-terminal', HmTerminal);
