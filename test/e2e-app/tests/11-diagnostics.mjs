// 11-diagnostics.mjs — Full check-syntax diagnostics pipeline.
// REAL diagnostics from drracket/check-syntax — not injected mocks.

import { writeFileSync, unlinkSync, mkdtempSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

export const name = 'Real check-syntax diagnostics';

export async function run(h) {
  const dir = mkdtempSync(join(tmpdir(), 'hm-test-diag-'));
  const errorFile = join(dir, 'has-error.rkt');
  const cleanFile = join(dir, 'clean.rkt');

  // File with a known error: unbound identifier
  writeFileSync(errorFile, '#lang racket\n(define x 42)\n(foo x)\n');
  // Clean file: no errors
  writeFileSync(cleanFile, '#lang racket\n(define y 10)\n(+ y 1)\n');

  try {
    // ── Open error file ──
    await h.dispatchEvent('file:tree-open', { path: errorFile });
    await h.waitForCell('current-file',
      `v === '${errorFile.replace(/'/g, "\\'")}'`, 10_000);

    // Wait for check-syntax to complete and diagnostics to arrive.
    // Error panel rows appear when intel:diagnostics is processed.
    // Give check-syntax time: it's a real Racket analysis.
    let rows = [];
    const deadline = Date.now() + 30_000;
    while (Date.now() < deadline) {
      await new Promise(r => setTimeout(r, 1000));
      rows = await h.getErrorPanelRows();
      if (rows.length > 0) break;
    }

    h.assert(rows.length > 0, 'error panel shows diagnostics for file with error');

    // The error should mention "foo" (unbound identifier)
    const fooError = rows.find(r => r.message.toLowerCase().includes('foo'));
    h.assert(fooError, `error panel mentions "foo" — got: ${rows.map(r => r.message).join('; ')}`);

    // Verify Monaco markers also exist
    const markers = await h.getMonacoMarkers();
    h.assert(markers.length > 0, 'Monaco has diagnostic markers');

    // ── Open clean file ──
    await h.dispatchEvent('file:tree-open', { path: cleanFile });
    await h.waitForCell('current-file',
      `v === '${cleanFile.replace(/'/g, "\\'")}'`, 10_000);

    // Wait for analysis of clean file
    await new Promise(r => setTimeout(r, 5000));

    // Error panel should clear (show "No problems" or be empty)
    const isEmpty = await h.errorPanelIsEmpty();
    const cleanRows = await h.getErrorPanelRows();
    // Either empty state or no rows
    h.assert(isEmpty || cleanRows.length === 0,
      `clean file has no diagnostics (empty=${isEmpty}, rows=${cleanRows.length})`);

  } finally {
    try { unlinkSync(errorFile); } catch {}
    try { unlinkSync(cleanFile); } catch {}
  }
}
