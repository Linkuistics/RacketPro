// 16-multi-file-workflow.mjs — Multi-file state consistency.
// ENTIRELY NEW: tests state across file switches in the real app.

import { writeFileSync, unlinkSync, mkdtempSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

export const name = 'Multi-file workflow';

export async function run(h) {
  const dir = mkdtempSync(join(tmpdir(), 'hm-test-multi-'));
  const fileA = join(dir, 'alpha.rkt');
  const fileB = join(dir, 'beta.rkt');
  writeFileSync(fileA, '#lang racket\n(define alpha-val "ALPHA")\n');
  writeFileSync(fileB, '#lang racket\n(define beta-val "BETA")\n');

  try {
    // ── Open file A ──
    await h.dispatchEvent('file:tree-open', { path: fileA });
    await h.waitForCell('current-file',
      `v === '${fileA.replace(/'/g, "\\'")}'`, 10_000);
    await new Promise(r => setTimeout(r, 2000));

    // Verify tab exists for A
    let tabs = await h.queryShadowAll('hm-tabs', '.tab-label');
    const hasAlpha = tabs.some(t => t.includes('alpha'));
    h.assert(hasAlpha, 'alpha.rkt tab exists');

    // Verify editor content is file A
    let content = await h.getMonacoValue();
    h.assert(content, 'editor has content for file A');
    h.assertContains(content, 'alpha-val', 'editor shows alpha content');

    // ── Open file B ──
    await h.dispatchEvent('file:tree-open', { path: fileB });
    await h.waitForCell('current-file',
      `v === '${fileB.replace(/'/g, "\\'")}'`, 10_000);
    await new Promise(r => setTimeout(r, 2000));

    // Verify two tabs exist
    tabs = await h.queryShadowAll('hm-tabs', '.tab-label');
    h.assert(tabs.length >= 2,
      `at least 2 tabs after opening both files (got ${tabs.length})`);

    // B is active, editor shows B's content
    const activeFile = await h.getCellValue('current-file');
    h.assertEqual(activeFile, fileB, 'current-file is file B');

    content = await h.getMonacoValue();
    h.assertContains(content, 'beta-val', 'editor shows beta content');

    // ── Switch back to file A ──
    // Use tab:select to switch (Racket reads file and opens in editor)
    await h.dispatchEvent('tab:select', { path: fileA });
    await h.waitForCell('current-file',
      `v === '${fileA.replace(/'/g, "\\'")}'`, 10_000);
    await new Promise(r => setTimeout(r, 2000));

    // Verify A is active again
    const switchedFile = await h.getCellValue('current-file');
    h.assertEqual(switchedFile, fileA, 'current-file is file A after switch');

    content = await h.getMonacoValue();
    h.assertContains(content, 'alpha-val', 'editor shows alpha content after switch');

    // ── Close file B ──
    await h.dispatchEvent('tab:close-request', { path: fileB });
    await new Promise(r => setTimeout(r, 2000));

    // Only file A tab should remain
    tabs = await h.queryShadowAll('hm-tabs', '.tab-label');
    const hasBeta = tabs.some(t => t.includes('beta'));
    h.assertFalsy(hasBeta, 'beta.rkt tab removed after close');

    const stillHasAlpha = tabs.some(t => t.includes('alpha'));
    h.assert(stillHasAlpha, 'alpha.rkt tab still present after closing beta');

  } finally {
    try { unlinkSync(fileA); } catch {}
    try { unlinkSync(fileB); } catch {}
  }
}
