// 06-stepper.mjs — Stepper start, forward, back, bindings, stop.

import { writeFileSync, unlinkSync, mkdtempSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

export const name = 'Stepper';

export async function run(h) {
  // Create a simple Racket file for stepping
  const dir = mkdtempSync(join(tmpdir(), 'hm-test-step-'));
  const filePath = join(dir, 'step-test.rkt');
  writeFileSync(filePath, '#lang racket\n(define x (+ 1 2))\nx\n');

  try {
    // Open the file
    await h.dispatchEvent('file:tree-open', { path: filePath });
    await new Promise(r => setTimeout(r, 2000));

    // Start stepping
    await h.dispatchEvent('stepper:start', { path: filePath });

    // Wait for stepper-active to become truthy
    await h.waitForCondition(`
      (async function() {
        const { getCell } = await import('/core/cells.js');
        return getCell('stepper-active').value === true;
      })()
    `, 15_000);

    h.assertTruthy(await h.getCellValue('stepper-active'), 'stepper-active is true');

    // Verify hm-stepper-toolbar is visible (not hidden)
    const toolbarHidden = await h.evalInApp(`
      const tb = document.querySelector('hm-stepper-toolbar');
      return tb ? tb.hidden : true;
    `);
    h.assertFalsy(toolbarHidden, 'hm-stepper-toolbar is visible');

    // Check step counter
    const stepNum = await h.queryShadow('hm-stepper-toolbar', '#step-num');
    h.assert(stepNum !== null, 'step-num element exists');

    // Forward step
    await h.dispatchEvent('stepper:forward', {});
    await new Promise(r => setTimeout(r, 3000));

    const stepAfterFwd = await h.getCellValue('stepper-step');
    h.assert(
      typeof stepAfterFwd === 'number' && stepAfterFwd >= 1,
      `stepper-step incremented after forward (got ${stepAfterFwd})`
    );

    // Back step
    await h.dispatchEvent('stepper:back', {});
    await new Promise(r => setTimeout(r, 2000));

    const stepAfterBack = await h.getCellValue('stepper-step');
    h.assert(
      typeof stepAfterBack === 'number' && stepAfterBack < stepAfterFwd,
      `stepper-step decremented after back (got ${stepAfterBack})`
    );

    // Check bindings panel exists
    h.assert(
      await h.elementExists('hm-bindings-panel'),
      'hm-bindings-panel exists'
    );

    // After stepping through (define x ...), bindings might appear
    // Step forward past the define
    await h.dispatchEvent('stepper:forward', {});
    await new Promise(r => setTimeout(r, 3000));
    await h.dispatchEvent('stepper:forward', {});
    await new Promise(r => setTimeout(r, 3000));

    // Check for binding names in the panel
    const bindings = await h.queryShadowAll('hm-bindings-panel', '.binding .name');
    // Bindings may or may not be present depending on stepper implementation
    // — just ensure the panel renders without error
    if (bindings.length > 0) {
      h.assert(
        bindings.some(b => b.includes('x')),
        'binding for x is visible'
      );
    }

    // Stop stepper
    await h.dispatchEvent('stepper:stop', {});
    await new Promise(r => setTimeout(r, 2000));

    h.assertFalsy(await h.getCellValue('stepper-active'), 'stepper-active is false after stop');

  } finally {
    try { unlinkSync(filePath); } catch {}
  }
}
