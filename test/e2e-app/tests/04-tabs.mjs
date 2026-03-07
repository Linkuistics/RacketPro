// 04-tabs.mjs — Tab creation, switching, close.

import { writeFileSync, unlinkSync, mkdtempSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

export const name = 'Tab management';

export async function run(h) {
  const dir = mkdtempSync(join(tmpdir(), 'hm-test-tabs-'));
  const file1 = join(dir, 'alpha.rkt');
  const file2 = join(dir, 'beta.rkt');
  writeFileSync(file1, '#lang racket\n"alpha"\n');
  writeFileSync(file2, '#lang racket\n"beta"\n');

  try {
    // Open first file → expect one tab
    await h.dispatchEvent('file:tree-open', { path: file1 });
    await new Promise(r => setTimeout(r, 2000));

    let tabs = await h.queryShadowAll('hm-tabs', '.tab-label');
    h.assert(tabs.length >= 1, `at least 1 tab after opening first file (got ${tabs.length})`);

    // Open second file → expect two tabs, second is active
    await h.dispatchEvent('file:tree-open', { path: file2 });
    await new Promise(r => setTimeout(r, 2000));

    tabs = await h.queryShadowAll('hm-tabs', '.tab-label');
    h.assert(tabs.length >= 2, `at least 2 tabs after opening second file (got ${tabs.length})`);

    // Active file should be beta.rkt
    const active = await h.getCellValue('current-file');
    h.assertEqual(active, file2, 'current-file is second opened file');

    // Close the active tab (tab:close-request is Frontend→Racket direction)
    await h.dispatchEvent('tab:close-request', { path: file2 });
    await new Promise(r => setTimeout(r, 2000));

    tabs = await h.queryShadowAll('hm-tabs', '.tab-label');
    // After close, should have one fewer tab
    const hasAlpha = tabs.some(t => t.includes('alpha'));
    h.assert(hasAlpha, 'alpha.rkt tab still present after closing beta');

  } finally {
    try { unlinkSync(file1); } catch {}
    try { unlinkSync(file2); } catch {}
  }
}
