// primitives/editor.js — mr-editor
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

import { LitElement, html, css } from 'lit';
import { onMessage, dispatch } from '../bridge.js';
import {
  racketLanguageId,
  racketLanguageConfig,
  racketTokenProvider,
} from '../racket-language.js';

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
  console.log('[mr-editor] Racket language registered');
}

class MrEditor extends LitElement {
  static properties = {
    filePath:  { type: String, attribute: 'file-path' },
    language:  { type: String },
    theme:     { type: String },
    readOnly:  { type: Boolean, attribute: 'read-only' },
  };

  static styles = css`
    :host {
      display: block;
      width: 100%;
      height: 100%;
      position: relative;
      overflow: hidden;
    }

    #editor-container {
      width: 100%;
      height: 100%;
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
    /** @type {import('monaco-editor').monaco.IDisposable|null} */
    this._changeDisposable = null;
    /** @type {import('monaco-editor').monaco.IDisposable|null} */
    this._saveDisposable = null;
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
      console.error('[mr-editor] Failed to initialise Monaco:', err);
    }
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

    const container = this.shadowRoot.getElementById('editor-container');
    if (!container) {
      console.error('[mr-editor] Editor container not found');
      return;
    }

    this._editor = monaco.editor.create(container, {
      value: '',
      language: this.language,
      theme: this.theme,
      readOnly: this.readOnly,
      automaticLayout: true,
      minimap: { enabled: false },
      fontSize: 14,
      fontFamily: "'JetBrains Mono', 'Fira Code', 'Cascadia Code', monospace",
      tabSize: 2,
      scrollBeyondLastLine: false,
    });

    // Track changes for dirty state
    this._changeDisposable = this._editor.onDidChangeModelContent(() => {
      if (!this._dirty) {
        this._dirty = true;
        dispatch('editor:dirty', { path: this.filePath });
      }
    });

    // Cmd/Ctrl+S keybinding for save
    const KeyMod = monaco.KeyMod;
    const KeyCode = monaco.KeyCode;
    this._saveDisposable = this._editor.addAction({
      id: 'mr-editor-save',
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

    console.log('[mr-editor] Monaco editor created');
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
        if (language !== undefined) this.language = language;

        if (this._editor && this._monaco) {
          // Update model language if changed
          const model = this._editor.getModel();
          if (model && language) {
            this._monaco.editor.setModelLanguage(model, language);
          }
          this._editor.setValue(content || '');
          this._dirty = false;
        }
      })
    );

    // editor:set-content — replace content without changing path
    this._unsubs.push(
      onMessage('editor:set-content', (msg) => {
        const { content } = msg;
        if (this._editor) {
          this._editor.setValue(content || '');
          this._dirty = false;
        }
      })
    );
  }

  disconnectedCallback() {
    super.disconnectedCallback();

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

    console.log('[mr-editor] Editor disposed');
  }
}

customElements.define('mr-editor', MrEditor);
