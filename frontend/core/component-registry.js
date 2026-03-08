// component-registry.js — Dynamic custom element registration
//
// When the Racket process sends `component:register`, we dynamically define
// a new Lit-based custom element.  `component:unregister` marks the tag as
// inactive (the Custom Elements registry doesn't support true removal, so
// we track state ourselves).
//
// Message shapes (from component.rkt):
//   component:register  { tag, properties, template, style, script }
//   component:unregister { tag }

import { LitElement, html, css } from 'lit';
import { getCell } from './cells.js';
import { onMessage } from './bridge.js';
import { effect } from '@preact/signals-core';

/** @type {Map<string, typeof LitElement>} */
const registeredComponents = new Map();

/**
 * Wire up bridge listeners for component:register and component:unregister.
 * Call once during app boot, alongside initCells / initRenderer.
 */
export function initComponentRegistry() {
  onMessage('component:register', (msg) => {
    registerComponent(msg);
  });

  onMessage('component:unregister', (msg) => {
    unregisterComponent(msg.tag);
  });

  console.log('[component-registry] Component registry initialised');
}

/**
 * Define a new custom element from a Racket component descriptor.
 *
 * @param {object} desc
 * @param {string} desc.tag — custom element tag name (must contain a hyphen)
 * @param {Array<{name:string, default:*}>} [desc.properties]
 * @param {string|object} [desc.template] — HTML template string or layout tree
 * @param {string} [desc.style] — CSS string
 * @param {string} [desc.script] — JS source defining methods on a `methods` object
 */
function registerComponent({ tag, properties, template, style, script }) {
  if (registeredComponents.has(tag)) {
    console.warn(`[component-registry] Component ${tag} already registered, skipping`);
    return;
  }

  // Build Lit property definitions and defaults from the descriptor
  const propDefs = {};
  const defaults = {};
  for (const { name, default: def } of (properties || [])) {
    propDefs[name] = { type: typeof def === 'number' ? Number : String };
    defaults[name] = def;
  }

  // Capture template/properties in the closure so the class can reference them
  const _properties = properties || [];
  const _template = template || '';
  const _script = script;

  // Create the Lit element subclass
  const ComponentClass = class extends LitElement {
    static properties = propDefs;

    constructor() {
      super();
      for (const [name, def] of Object.entries(defaults)) {
        this[name] = def;
      }
      this._methods = {};
      this._cellEffects = [];
    }

    connectedCallback() {
      super.connectedCallback();

      // Parse and execute the script block — it should assign to `methods`
      if (_script) {
        try {
          const scriptFn = new Function('self', `
            const methods = {};
            ${_script}
            return methods;
          `);
          this._methods = scriptFn(this);
        } catch (e) {
          console.error(`[component-registry] Script error in ${tag}:`, e);
        }
      }
      if (this._methods.connected) this._methods.connected.call(this);

      // Set up cell subscriptions for property defaults that are cell references
      for (const { name, default: def } of _properties) {
        if (typeof def === 'string' && def.startsWith('cell:')) {
          const cellName = def.slice(5);
          const dispose = effect(() => {
            this[name] = getCell(cellName).value;
            this.requestUpdate();
          });
          this._cellEffects.push(dispose);
        }
      }
    }

    disconnectedCallback() {
      super.disconnectedCallback();
      if (this._methods.disconnected) this._methods.disconnected.call(this);
      // Clean up cell effect subscriptions
      this._cellEffects.forEach(d => d());
      this._cellEffects = [];
    }

    updated() {
      if (this._methods.updated) {
        const props = {};
        for (const { name } of _properties) {
          props[name] = this[name];
        }
        this._methods.updated.call(this, props);
      }
    }

    render() {
      if (typeof _template === 'object' && _template.type) {
        // Layout tree from the ui macro — create nested elements
        return this._renderLayoutTree(_template);
      }

      // String template — simple property interpolation
      let processed = _template;
      for (const { name } of _properties) {
        processed = processed.replaceAll(`\${${name}}`, this[name] ?? '');
      }
      const tpl = document.createElement('template');
      tpl.innerHTML = processed;
      return html`${tpl.content.cloneNode(true)}`;
    }

    /**
     * Render a layout-tree node (from the ui macro) into a DOM element
     * wrapped in a Lit html template result.
     */
    _renderLayoutTree(node) {
      const el = document.createElement(
        node.type.startsWith('hm-') ? node.type : `hm-${node.type}`
      );
      if (node.props) {
        for (const [k, v] of Object.entries(node.props)) {
          if (k === 'id') continue;
          if (k.includes('-')) {
            el.setAttribute(k, v);
          } else {
            el[k] = v;
          }
        }
      }
      if (Array.isArray(node.children)) {
        for (const child of node.children) {
          if (child && child.type) {
            el.appendChild(this._renderLayoutTree(child).values[0]);
          }
        }
      }
      return html`${el}`;
    }
  };

  // Apply styles via adoptedStyleSheets (avoids needing unsafeCSS which
  // isn't exported from the vendored Lit bundle)
  if (style) {
    try {
      const sheet = new CSSStyleSheet();
      sheet.replaceSync(style);
      ComponentClass.elementStyles = [sheet];
    } catch (e) {
      console.error(`[component-registry] CSS error in ${tag}:`, e);
    }
  }

  customElements.define(tag, ComponentClass);
  registeredComponents.set(tag, ComponentClass);
  console.debug(`[component-registry] Registered <${tag}>`);
}

/**
 * Mark a component tag as unregistered.
 *
 * The Custom Elements registry doesn't support undefining an element, so
 * existing instances will continue to work but no new registrations of the
 * same tag are possible.
 *
 * @param {string} tag — the custom element tag name
 */
function unregisterComponent(tag) {
  registeredComponents.delete(tag);
  console.debug(`[component-registry] Unregistered <${tag}>`);
}
