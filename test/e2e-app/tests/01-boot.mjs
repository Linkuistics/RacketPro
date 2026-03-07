// 01-boot.mjs — Verify the app boots correctly: layout rendered, cells registered.

export const name = 'App boot sequence';

export async function run(h) {
  // Core layout elements exist
  h.assert(await h.elementExists('hm-vbox'), 'hm-vbox exists');
  h.assert(await h.elementExists('hm-breadcrumb'), 'hm-breadcrumb exists');
  h.assert(await h.elementExists('hm-statusbar'), 'hm-statusbar exists');
  h.assert(await h.elementExists('hm-filetree'), 'hm-filetree exists');
  h.assert(await h.elementExists('hm-tabs'), 'hm-tabs exists');
  h.assert(await h.elementExists('hm-editor'), 'hm-editor exists');

  // Key cells are registered and have expected initial values
  const status = await h.getCellValue('status');
  h.assert(typeof status === 'string', `status cell is a string: "${status}"`);

  h.assertFalsy(await h.getCellValue('stepper-active'), 'stepper-active is falsy at boot');
  h.assertFalsy(await h.getCellValue('repl-running'), 'repl-running is falsy at boot');
  h.assertFalsy(await h.getCellValue('file-dirty'), 'file-dirty is falsy at boot');

  const stepperStep = await h.getCellValue('stepper-step');
  h.assertEqual(stepperStep, 0, 'stepper-step is 0 at boot');
}
