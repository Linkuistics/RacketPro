// renderer.js — Primitive tree to DOM
//
// The Racket process sends a layout tree (via the "layout:set" message)
// describing the UI as a nested structure of primitive types (vbox, hbox,
// heading, text, button, etc.).  This module turns that tree into a live
// DOM tree of `hm-<type>` custom elements.

import { onMessage } from './bridge.js';

/** @type {HTMLElement|null} */
let root = null;

/**
 * Create a `hm-<type>` custom element from a node descriptor, set its
 * properties, and recursively render its children.
 *
 * @param {object} node — { type, props, children }
 * @param {HTMLElement} parent — DOM element to append into
 */
export function renderNode(node, parent, index = 0) {
  if (!node || !node.type) return;

  const tagName = `hm-${node.type}`;
  const el = document.createElement(tagName);

  // Copy props to the element. Hyphenated Racket props are set as HTML
  // attributes (so Lit's attribute→property reflection picks them up).
  // Other props are set as JS properties directly.
  if (node.props) {
    // Map Racket prop names to component property names where they
    // differ or would collide with native DOM properties.
    const propMap = {
      text: 'content',       // Racket 'text' → component 'content'
      style: 'textStyle',    // Racket 'style' → 'textStyle' (avoid CSSStyleDeclaration)
    };

    for (const [key, value] of Object.entries(node.props)) {
      const mapped = propMap[key];
      if (mapped && (node.type === 'heading' || node.type === 'text')) {
        el[mapped] = value;
      } else if (key.includes('-')) {
        // Hyphenated props (file-path, pty-id, min-size, read-only) →
        // set as attributes so Lit's attribute reflection works
        el.setAttribute(key, value);
      } else {
        el[key] = value;
      }
    }
  }

  // Recursively render children
  if (Array.isArray(node.children)) {
    node.children.forEach((child, index) => {
      renderNode(child, el, index);
    });
  }

  // Assign named slots for hm-split children and ensure they fill the pane
  if (parent && parent.tagName === 'HM-SPLIT') {
    el.slot = index === 0 ? 'first' : 'second';
    el.style.width = '100%';
    el.style.height = '100%';
  }

  parent.appendChild(el);
}

/**
 * Clear the root container and render a full layout tree into it.
 *
 * @param {object} tree — root node of the layout tree
 */
export function setLayout(tree) {
  if (!root) {
    console.error('[renderer] No root container — call initRenderer() first');
    return;
  }
  // Clear existing content and switch from centered loading layout to
  // a full-height flex column that stretches to fill the viewport.
  root.textContent = '';
  root.style.display = 'flex';
  root.style.flexDirection = 'column';
  root.style.alignItems = 'stretch';
  root.style.justifyContent = 'stretch';
  root.style.fontSize = '';
  root.style.overflow = 'hidden';
  renderNode(tree, root);
  console.debug('[renderer] Layout rendered');
}

/**
 * Initialise the renderer.
 *
 * @param {HTMLElement} container — the root DOM element (#app)
 */
export function initRenderer(container) {
  root = container;

  // Listen for layout:set messages from the Racket bridge
  onMessage('layout:set', (msg) => {
    const layout = msg.layout;
    if (layout) {
      setLayout(layout);
    } else {
      console.warn('[renderer] layout:set message missing "layout" field', msg);
    }
  });

  console.log('[renderer] Renderer initialised');
}
