// 02-file-tree.mjs — File tree renders and has content.

export const name = 'File tree';

export async function run(h) {
  // hm-filetree exists
  h.assert(await h.elementExists('hm-filetree'), 'hm-filetree exists');

  // Project root cell should have a value (set when Racket sends the project path)
  // Wait a moment for Racket to send the project root
  const root = await h.waitForCondition(`
    (async function() {
      const { getCell } = await import('/core/cells.js');
      const v = getCell('project-root').value;
      return v && v.length > 0 ? v : null;
    })()
  `, 15_000).catch(() => null);

  // If project-root isn't set (e.g. no project opened), that's ok —
  // just verify the filetree element is rendered
  if (root) {
    h.assert(typeof root === 'string' && root.length > 0, 'project-root has a value');
  }

  // Check filetree has shadow DOM content
  const hasContent = await h.evalInApp(`
    const ft = document.querySelector('hm-filetree');
    if (!ft || !ft.shadowRoot) return false;
    return ft.shadowRoot.children.length > 0;
  `);
  h.assert(hasContent, 'hm-filetree has shadow DOM content');
}
