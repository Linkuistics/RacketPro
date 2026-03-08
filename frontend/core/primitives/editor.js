// primitives/editor.js — hm-editor
//
// Monaco Editor wrapper as a Lit Web Component.  Dynamically imports the
// vendored Monaco bundle, registers the Racket language (once), and creates
// an editor instance inside Shadow DOM.
//
// Bridge messages:
//   editor:open          — open a file (path, content, language)
//   editor:set-content   — replace editor content
//
// Dispatches to Racket:
//   editor:dirty          — first edit after a load
//   editor:save-request   — Cmd/Ctrl+S with { path, content }
//   document:opened       — file loaded into editor (uri, text, languageId)
//   document:changed      — debounced content change (uri, text)

import { LitElement, html, css } from 'lit';
import { effect } from '@preact/signals-core';
import { getCell } from '../cells.js';
import { onMessage, dispatch } from '../bridge.js';
import { initLangIntel } from '../lang-intel.js';
import { ArrowOverlay } from '../arrows.js';
import {
  racketLanguageId,
  racketLanguageConfig,
  racketTokenProvider,
} from '../racket-language.js';
import {
  rhombusLanguageId,
  rhombusLanguageConfig,
  rhombusTokenProvider,
} from '../rhombus-language.js';

/** Whether the Racket language has been registered with Monaco. */
let racketRegistered = false;

/**
 * Register the Racket language with Monaco's language registry.
 * Safe to call multiple times — only registers once.
 *
 * @param {typeof import('monaco-editor').monaco} monaco
 */
function registerRacketLanguage(monaco) {
  if (racketRegistered) return;
  monaco.languages.register({ id: racketLanguageId });
  monaco.languages.setLanguageConfiguration(racketLanguageId, racketLanguageConfig);
  monaco.languages.setMonarchTokensProvider(racketLanguageId, racketTokenProvider);
  racketRegistered = true;
  console.log('[hm-editor] Racket language registered');
}

/** Whether the Rhombus language has been registered with Monaco. */
let rhombusRegistered = false;

/**
 * Register the Rhombus language with Monaco's language registry.
 * Safe to call multiple times — only registers once.
 *
 * @param {typeof import('monaco-editor').monaco} monaco
 */
function registerRhombusLanguage(monaco) {
  if (rhombusRegistered) return;
  monaco.languages.register({ id: rhombusLanguageId });
  monaco.languages.setLanguageConfiguration(rhombusLanguageId, rhombusLanguageConfig);
  monaco.languages.setMonarchTokensProvider(rhombusLanguageId, rhombusTokenProvider);
  rhombusRegistered = true;
  console.log('[hm-editor] Rhombus language registered');
}

class HmEditor extends LitElement {
  static properties = {
    filePath:  { type: String, attribute: 'file-path' },
    language:  { type: String },
    theme:     { type: String },
    readOnly:  { type: Boolean, attribute: 'read-only' },
    vimMode:   { type: Boolean, state: true },
  };

  static styles = css`
    :host {
      display: block;
      width: 100%;
      height: 100%;
      position: relative;
      overflow: hidden;
      box-sizing: border-box;
    }

    :host([hidden]) {
      display: none;
    }

    #editor-container {
      width: 100%;
      height: 100%;
    }

    .vim-status {
      position: absolute;
      bottom: 0;
      left: 0;
      right: 0;
      height: 20px;
      background: var(--bg-statusbar, #e8e8e8);
      color: var(--fg-statusbar, #616161);
      font-family: var(--font-mono);
      font-size: 11px;
      padding: 2px 8px;
      display: none;
    }
    :host([vim-mode]) .vim-status {
      display: block;
    }
  `;

  constructor() {
    super();
    this.filePath = '';
    this.language = 'racket';
    this.theme = 'vs';
    this.readOnly = false;

    /** @type {import('monaco-editor').monaco.editor.IStandaloneCodeEditor|null} */
    this._editor = null;
    /** @type {typeof import('monaco-editor').monaco|null} */
    this._monaco = null;
    /** @type {boolean} Whether the editor content is dirty since last load. */
    this._dirty = false;
    /** @type {Function[]} Unsubscribe functions for bridge listeners. */
    this._unsubs = [];
    /** @type {number|null} Debounce timer for document:changed dispatch. */
    this._changeTimer = null;
    /** @type {import('monaco-editor').monaco.IDisposable|null} */
    this._changeDisposable = null;
    /** @type {import('monaco-editor').monaco.IDisposable|null} */
    this._saveDisposable = null;
    this._disposeVisibility = null;
    this._arrowOverlay = null;
    /** @type {string[]} Monaco decoration IDs for stepper highlighting. */
    this._stepperDecorations = [];
    /** @type {boolean} Whether vim mode is enabled. */
    this.vimMode = false;
    /** @type {{dispose(): void}|null} Active vim mode instance. */
    this._vimMode = null;
  }

  render() {
    return html`
      <link rel="stylesheet" href="./vendor/monaco/monaco-editor.css">
      <div id="editor-container"></div>
    `;
  }

  async firstUpdated() {
    try {
      await this._initMonaco();
      this._setupBridgeListeners();
    } catch (err) {
      console.error('[hm-editor] Failed to initialise Monaco:', err);
    }
    // Hide editor when no file is open
    setTimeout(() => {
      const cell = getCell('current-file');
      this._disposeVisibility = effect(() => {
        const val = cell.value;
        this.toggleAttribute('hidden', !val);
      });
    }, 0);
  }

  /**
   * Dynamically import Monaco, register the Racket language, and create
   * the editor instance inside the shadow DOM container.
   */
  async _initMonaco() {
    const mod = await import('monaco-editor');
    const monaco = mod.monaco;
    this._monaco = monaco;

    // Register Racket language (idempotent)
    registerRacketLanguage(monaco);

    // Register Rhombus language (idempotent)
    registerRhombusLanguage(monaco);

    const container = this.shadowRoot.getElementById('editor-container');
    if (!container) {
      console.error('[hm-editor] Editor container not found');
      return;
    }

    this._editor = monaco.editor.create(container, {
      value: '',
      language: this.language,
      theme: this.theme,
      readOnly: this.readOnly,
      automaticLayout: true,
      minimap: { enabled: false },
      fontSize: 13,
      fontWeight: '300',
      fontFamily: "'OperatorMonoSSm Nerd Font Mono', 'SF Mono', 'Fira Code', Menlo, monospace",
      tabSize: 2,
      scrollBeyondLastLine: false,
    });

    // Inject check-syntax semantic coloring styles into shadow root
    const csStyle = document.createElement('style');
    csStyle.textContent = `
      .hm-cs-lexically-bound { color: #0000CD !important; }
      .hm-cs-imported { color: #006400 !important; }
      .hm-cs-set\\!d { color: #8B0000 !important; }
      .hm-cs-free-variable { text-decoration: wavy underline red !important; }
      .hm-cs-unused-require { opacity: 0.5 !important; text-decoration: line-through !important; }
    `;
    this.shadowRoot.appendChild(csStyle);

    // Stepper expression highlight style
    const stepperStyle = document.createElement('style');
    stepperStyle.textContent = `
      .hm-stepper-highlight { background: rgba(255, 235, 59, 0.3) !important; }
    `;
    this.shadowRoot.appendChild(stepperStyle);

    // Track changes for dirty state + debounced document:changed
    this._changeDisposable = this._editor.onDidChangeModelContent((e) => {
      if (!this._dirty) {
        this._dirty = true;
        dispatch('editor:dirty', { path: this.filePath });
      }
      // Debounced document:changed for language intelligence
      if (this._changeTimer) clearTimeout(this._changeTimer);
      this._changeTimer = setTimeout(() => {
        this._changeTimer = null;
        if (!this._editor) return;
        const text = this._editor.getValue();
        dispatch('document:changed', {
          uri: this.filePath,
          text,
        });
      }, 500);
    });

    // Cmd/Ctrl+S keybinding for save
    const KeyMod = monaco.KeyMod;
    const KeyCode = monaco.KeyCode;
    this._saveDisposable = this._editor.addAction({
      id: 'hm-editor-save',
      label: 'Save File',
      keybindings: [KeyMod.CtrlCmd | KeyCode.KeyS],
      run: () => {
        const content = this._editor.getValue();
        dispatch('editor:save-request', {
          path: this.filePath,
          content,
        });
      },
    });

    // Initialize language intelligence with Monaco and editor references
    initLangIntel(monaco, this._editor);

    // Mount Check Syntax arrow overlay
    this._arrowOverlay = new ArrowOverlay(this._editor, monaco, this.shadowRoot);

    // Expose filePath on editor for lang-intel to read
    this._editor.filePath = this.filePath;

    console.log('[hm-editor] Monaco editor created');
  }

  /**
   * Subscribe to bridge messages from Racket.
   */
  _setupBridgeListeners() {
    // editor:open — load file content into the editor
    this._unsubs.push(
      onMessage('editor:open', (msg) => {
        const { path, content, language } = msg;
        if (path !== undefined) this.filePath = path;
        if (this._editor) this._editor.filePath = this.filePath;
        if (language !== undefined) this.language = language;

        if (this._editor && this._monaco) {
          // Update model language if changed
          const model = this._editor.getModel();
          if (model && language) {
            this._monaco.editor.setModelLanguage(model, language);
          }
          // Suppress editor:dirty dispatch during programmatic setValue —
          // Monaco fires onDidChangeModelContent synchronously, and
          // dispatching back to Racket during a Tauri event callback
          // deadlocks WKWebView.
          this._dirty = true;
          this._editor.setValue(content || '');
          this._dirty = false;

          // Notify Racket that a document is now open for language intelligence
          dispatch('document:opened', {
            uri: path || '',
            text: content || '',
            languageId: language || 'racket',
          });
        }
      })
    );

    // editor:set-content — replace content without changing path
    this._unsubs.push(
      onMessage('editor:set-content', (msg) => {
        const { content } = msg;
        if (this._editor) {
          this._dirty = true;
          this._editor.setValue(content || '');
          this._dirty = false;
        }
      })
    );

    // editor:goto — jump to a specific position (e.g., from error panel click)
    this._unsubs.push(
      onMessage('editor:goto', (msg) => {
        if (this._editor) {
          const { line, col } = msg;
          const position = { lineNumber: line || 1, column: (col || 0) + 1 };
          this._editor.setPosition(position);
          this._editor.revealPositionInCenter(position);
          this._editor.focus();
        }
      })
    );

    // editor:request-save — Racket asks frontend to trigger a save
    // (e.g., when the user clicks File > Save in the menu bar)
    this._unsubs.push(
      onMessage('editor:request-save', () => {
        if (this._editor) {
          const content = this._editor.getValue();
          dispatch('editor:save-request', {
            path: this.filePath,
            content,
          });
        }
      })
    );

    // Stepper expression highlighting
    this._unsubs.push(
      onMessage('stepper:step', (msg) => {
        if (!this._editor || !this._monaco) return;
        const data = msg.data || {};
        const src = data.pre_src;
        if (src && src.position != null && src.span != null) {
          const model = this._editor.getModel();
          if (!model) return;
          const startPos = model.getPositionAt(src.position - 1); // 1-based offset
          const endPos = model.getPositionAt(src.position - 1 + src.span);
          this._stepperDecorations = this._editor.deltaDecorations(
            this._stepperDecorations,
            [{
              range: new this._monaco.Range(
                startPos.lineNumber, startPos.column,
                endPos.lineNumber, endPos.column
              ),
              options: {
                className: 'hm-stepper-highlight',
                isWholeLine: false,
              },
            }]
          );
          this._editor.revealRangeInCenter(new this._monaco.Range(
            startPos.lineNumber, startPos.column,
            endPos.lineNumber, endPos.column
          ));
        }
      })
    );

    // Clear stepper decorations when stepper stops
    this._unsubs.push(
      onMessage('stepper:finished', () => {
        if (this._editor) {
          this._stepperDecorations = this._editor.deltaDecorations(
            this._stepperDecorations, []
          );
        }
      })
    );

    // Vim mode toggle
    this._unsubs.push(
      onMessage('editor:set-vim-mode', (msg) => {
        this.vimMode = msg.enabled;
        if (this._editor) {
          if (this.vimMode) {
            this._enableVim();
          } else {
            this._disableVim();
          }
        }
      })
    );
  }

  async _enableVim() {
    if (this._vimMode) return;
    try {
      const { initVimMode } = await import('../../vendor/monaco-vim/index.js');
      // Create a status bar element for vim mode indicator
      let statusEl = this.shadowRoot.querySelector('.vim-status');
      if (!statusEl) {
        statusEl = document.createElement('div');
        statusEl.className = 'vim-status';
        this.shadowRoot.appendChild(statusEl);
      }
      this._vimMode = initVimMode(this._editor, statusEl);
      this.toggleAttribute('vim-mode', true);
    } catch (e) {
      console.error('[editor] Failed to enable vim mode:', e);
    }
  }

  _disableVim() {
    if (this._vimMode) {
      this._vimMode.dispose();
      this._vimMode = null;
      const statusEl = this.shadowRoot.querySelector('.vim-status');
      if (statusEl) statusEl.textContent = '';
      this.toggleAttribute('vim-mode', false);
    }
  }

  disconnectedCallback() {
    super.disconnectedCallback();

    if (this._disposeVisibility) {
      this._disposeVisibility();
      this._disposeVisibility = null;
    }

    if (this._arrowOverlay) {
      this._arrowOverlay.dispose();
      this._arrowOverlay = null;
    }

    // Clear debounce timer for document:changed
    if (this._changeTimer) {
      clearTimeout(this._changeTimer);
      this._changeTimer = null;
    }

    // Dispose vim mode (before editor disposal — vim may reference editor)
    this._disableVim();

    // Dispose Monaco resources
    if (this._changeDisposable) {
      this._changeDisposable.dispose();
      this._changeDisposable = null;
    }
    if (this._saveDisposable) {
      this._saveDisposable.dispose();
      this._saveDisposable = null;
    }
    if (this._editor) {
      this._editor.dispose();
      this._editor = null;
    }

    // Unsubscribe bridge listeners
    for (const unsub of this._unsubs) {
      unsub();
    }
    this._unsubs = [];

    console.log('[hm-editor] Editor disposed');
  }
}

customElements.define('hm-editor', HmEditor);
