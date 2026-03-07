// 08-layout.mjs — Full layout verification with real Racket-declared layout tree.
// Ports phase3.spec.js "Layout rendering" but with REAL Racket layout, not mocks.

export const name = 'Full layout verification';

export async function run(h) {
  // Root should be hm-vbox (Racket's outermost layout container)
  const root = await h.evalInApp(`
    const root = document.querySelector('hm-vbox');
    return root ? root.tagName.toLowerCase() : null;
  `);
  h.assertEqual(root, 'hm-vbox', 'root element is hm-vbox');

  // All expected layout components must be present
  const components = [
    'hm-split',
    'hm-editor',
    'hm-terminal',
    'hm-filetree',
    'hm-tabs',
    'hm-statusbar',
    'hm-error-panel',
    'hm-panel-header',
    'hm-breadcrumb',
  ];

  for (const tag of components) {
    const exists = await h.elementExists(tag);
    h.assert(exists, `${tag} exists in layout`);
  }

  // Status bar has a meaningful status value
  const status = await h.getCellValue('status');
  h.assert(typeof status === 'string' && status.length > 0,
    `status cell has text (got "${status}")`);

  // Verify the layout tree structure: root hm-vbox should contain
  // a split (filetree + content column) and statusbar
  const structure = await h.evalInApp(`
    const root = document.querySelector('hm-vbox');
    if (!root) return [];
    return Array.from(root.children).map(c => c.tagName.toLowerCase());
  `);
  h.assert(Array.isArray(structure), 'root has children');
  h.assert(structure.includes('hm-split'), 'root contains hm-split');
  h.assert(structure.includes('hm-statusbar'), 'root contains hm-statusbar');

  // hm-split should be nested inside the layout
  const splitExists = await h.evalInApp(`
    return document.querySelector('hm-vbox hm-split') !== null;
  `);
  h.assert(splitExists, 'hm-split is nested inside root hm-vbox');
}
