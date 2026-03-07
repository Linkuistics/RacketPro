// 07-breadcrumb.mjs — Breadcrumb path display and action buttons.

import { writeFileSync, unlinkSync, mkdtempSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

export const name = 'Breadcrumb + action buttons';

export async function run(h) {
  // Verify breadcrumb exists
  h.assert(await h.elementExists('hm-breadcrumb'), 'hm-breadcrumb exists');

  // Open a file so the breadcrumb shows a path
  const dir = mkdtempSync(join(tmpdir(), 'hm-test-bc-'));
  const filePath = join(dir, 'crumb-test.rkt');
  writeFileSync(filePath, '#lang racket\n42\n');

  try {
    await h.dispatchEvent('file:tree-open', { path: filePath });
    await new Promise(r => setTimeout(r, 2000));

    // Breadcrumb should show the filename
    const pathText = await h.queryShadow('hm-breadcrumb', '.path');
    h.assert(pathText !== null, 'breadcrumb .path element exists');
    if (pathText) {
      h.assertContains(pathText, 'crumb-test.rkt', 'breadcrumb shows filename');
    }

    // Run button should be visible (not running, not stepping)
    const runBtnExists = await h.evalInApp(`
      const bc = document.querySelector('hm-breadcrumb');
      if (!bc || !bc.shadowRoot) return false;
      const btn = bc.shadowRoot.querySelector('.action-btn.run');
      return btn !== null;
    `);
    h.assertTruthy(runBtnExists, 'run action button exists');

    // Step button should be visible
    const stepBtnExists = await h.evalInApp(`
      const bc = document.querySelector('hm-breadcrumb');
      if (!bc || !bc.shadowRoot) return false;
      const btn = bc.shadowRoot.querySelector('.action-btn.step');
      return btn !== null;
    `);
    h.assertTruthy(stepBtnExists, 'step action button exists');

  } finally {
    try { unlinkSync(filePath); } catch {}
  }
}
