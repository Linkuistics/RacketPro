// renderer.js — Primitive tree to DOM
//
// The Racket process sends a layout tree (via the "layout:set" message)
// describing the UI as a nested structure of primitive types (vbox, hbox,
// heading, text, button, etc.).  This module turns that tree into a live
// DOM tree of `mr-<type>` custom elements.

import { onMessage } from './bridge.js';

/** @type {HTMLElement|null} */
let root = null;

/**
 * Create a `mr-<type>` custom element from a node descriptor, set its
 * properties, and recursively render its children.
 *
 * @param {object} node — { type, props, children }
 * @param {HTMLElement} parent — DOM element to append into
 */
export function renderNode(node, parent) {
  if (!node || !node.type) return;

  const tagName = `mr-${node.type}`;
  const el = document.createElement(tagName);

  // Copy all props as properties (not attributes) on the element.
  // This works well with Lit's property system.
  if (node.props) {
    for (const [key, value] of Object.entries(node.props)) {
      // Map Racket prop names to component property names where they
      // differ or would collide with native DOM properties.
      if (key === 'text' && (node.type === 'heading' || node.type === 'text')) {
        // Racket uses 'text', component uses 'content'
        el.content = value;
      } else if (key === 'style' && node.type === 'text') {
        // Racket uses 'style' for text variants ("mono", "muted"),
        // but el.style is the native CSSStyleDeclaration — use textStyle instead
        el.textStyle = value;
      } else {
        el[key] = value;
      }
    }
  }

  // Recursively render children
  if (Array.isArray(node.children)) {
    for (const child of node.children) {
      renderNode(child, el);
    }
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
  // Clear existing content and reset any inline styles from the loading state
  root.textContent = '';
  root.style.display = '';
  root.style.alignItems = '';
  root.style.justifyContent = '';
  root.style.fontSize = '';
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
