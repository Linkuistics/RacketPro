// renderer.js — Layout tree to DOM with ID-based diffing
//
// The Racket process sends a layout tree (via "layout:set") describing the
// UI as nested nodes. Each node carries a stable 'id' in its props, assigned
// by Racket. The renderer diffs by ID: matching nodes are reused and updated
// in place, new nodes are created, missing nodes are removed.

import { onMessage } from './bridge.js';

/** @type {HTMLElement|null} */
let root = null;

/**
 * Create a `hm-<type>` custom element from a node descriptor, set its
 * properties, and recursively render its children.
 *
 * @param {object} node — { type, props, children }
 * @param {HTMLElement} parent — DOM element to append into
 * @param {number} index — sibling index (for slot assignment)
 */
function createNode(node, parent, index = 0) {
  if (!node || !node.type) return null;

  const tagName = `hm-${node.type}`;
  const el = document.createElement(tagName);

  // Set all props
  applyProps(el, node.type, node.props || {});

  // Store layout ID for future diffing
  if (node.props?.id) {
    el.dataset.layoutId = node.props.id;
  }

  // Recursively create children
  if (Array.isArray(node.children)) {
    node.children.forEach((child, i) => {
      createNode(child, el, i);
    });
  }

  // Assign named slots for hm-split children
  if (parent && parent.tagName === 'HM-SPLIT') {
    el.slot = index === 0 ? 'first' : 'second';
    el.style.width = '100%';
    el.style.height = '100%';
  }

  parent.appendChild(el);
  return el;
}

/**
 * Apply props from a layout node to a DOM element.
 */
function applyProps(el, nodeType, props) {
  const propMap = {
    text: 'content',
    style: 'textStyle',
  };

  for (const [key, value] of Object.entries(props)) {
    // Skip 'id' — it's for diffing, not a DOM property
    if (key === 'id') continue;

    const mapped = propMap[key];
    if (mapped && (nodeType === 'heading' || nodeType === 'text')) {
      el[mapped] = value;
    } else if (key.includes('-')) {
      el.setAttribute(key, value);
    } else {
      el[key] = value;
    }
  }
}

/**
 * Diff-reconcile a new layout tree against existing DOM children.
 * Matches nodes by their 'id' prop for stable identity.
 *
 * @param {HTMLElement} parent — the DOM parent to reconcile into
 * @param {Array} newChildren — array of layout node descriptors
 */
function reconcileChildren(parent, newChildren) {
  if (!Array.isArray(newChildren)) newChildren = [];

  // Build map: id → existing DOM element
  const existingById = new Map();
  for (const child of parent.children) {
    const id = child.dataset?.layoutId;
    if (id) {
      existingById.set(id, child);
    }
  }

  // Track which elements we've matched
  const matched = new Set();
  const newOrder = [];

  for (let i = 0; i < newChildren.length; i++) {
    const node = newChildren[i];
    if (!node || !node.type) continue;

    const nodeId = node.props?.id;
    const existing = nodeId ? existingById.get(nodeId) : null;

    if (existing && existing.tagName === `HM-${node.type}`.toUpperCase()) {
      // Reuse existing element — update props
      applyProps(existing, node.type, node.props || {});

      // Assign split slots if needed
      if (parent.tagName === 'HM-SPLIT') {
        existing.slot = i === 0 ? 'first' : 'second';
        existing.style.width = '100%';
        existing.style.height = '100%';
      }

      // Recursively reconcile children
      reconcileChildren(existing, node.children || []);

      matched.add(nodeId);
      newOrder.push(existing);
    } else {
      // New node — create it
      const el = document.createElement(`hm-${node.type}`);
      applyProps(el, node.type, node.props || {});

      // Store layout ID for future diffing
      if (nodeId) {
        el.dataset.layoutId = nodeId;
      }

      // Assign split slots
      if (parent.tagName === 'HM-SPLIT') {
        el.slot = i === 0 ? 'first' : 'second';
        el.style.width = '100%';
        el.style.height = '100%';
      }

      // Recursively create children
      if (Array.isArray(node.children)) {
        node.children.forEach((child, ci) => {
          createNode(child, el, ci);
        });
      }

      newOrder.push(el);
    }
  }

  // Remove unmatched elements (extension panels that were unloaded, etc.)
  for (const [id, el] of existingById) {
    if (!matched.has(id)) {
      el.remove();
    }
  }

  // Reorder DOM children to match new layout order
  for (let i = 0; i < newOrder.length; i++) {
    const el = newOrder[i];
    if (el.parentNode !== parent) {
      parent.appendChild(el);
    } else if (parent.children[i] !== el) {
      parent.insertBefore(el, parent.children[i]);
    }
  }
}

/**
 * Set (or diff-update) the full layout tree.
 *
 * On first call, creates the entire tree from scratch.
 * On subsequent calls, diffs by node ID to preserve existing DOM elements.
 *
 * @param {object} tree — root node of the layout tree
 */
export function setLayout(tree) {
  if (!root) {
    console.error('[renderer] No root container — call initRenderer() first');
    return;
  }

  if (root.children.length === 0) {
    // First render — create everything, set up root styles
    root.textContent = '';
    root.style.display = 'flex';
    root.style.flexDirection = 'column';
    root.style.alignItems = 'stretch';
    root.style.justifyContent = 'stretch';
    root.style.fontSize = '';
    root.style.overflow = 'hidden';

    createNode(tree, root, 0);
    console.debug('[renderer] Layout rendered (initial)');
  } else {
    // Subsequent render — diff against existing DOM
    const rootEl = root.children[0];
    if (!rootEl) {
      // Shouldn't happen, but fallback to full create
      root.textContent = '';
      createNode(tree, root, 0);
      return;
    }

    // Update root props
    applyProps(rootEl, tree.type, tree.props || {});

    // Reconcile children
    reconcileChildren(rootEl, tree.children || []);

    console.debug('[renderer] Layout reconciled (diff)');
  }
}

/**
 * Re-exported for compatibility — delegates to createNode.
 */
export function renderNode(node, parent, index = 0) {
  return createNode(node, parent, index);
}

/**
 * Initialise the renderer.
 *
 * @param {HTMLElement} container — the root DOM element (#app)
 */
export function initRenderer(container) {
  root = container;

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
