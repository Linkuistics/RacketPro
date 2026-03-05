// @ts-check
import { test, expect } from '@playwright/test';
import {
  bootApp,
  sendBootMessages,
  waitForMonaco,
  fireEvent,
  getInvocations,
  clearInvocations,
} from './fixtures.js';

/**
 * HeavyMental Phase 3 — UI E2E Tests
 *
 * These tests mock the Tauri backend, inject simulated Racket messages,
 * and verify the frontend DOM responds correctly. This exercises the
 * full Phase 3 language intelligence pipeline in the browser.
 */

// ── Group 1: Layout Rendering ────────────────────────────────────────

test.describe('Layout rendering', () => {
  test.beforeEach(async ({ page }) => {
    await bootApp(page);
    await sendBootMessages(page);
  });

  test('boot renders layout with root vbox', async ({ page }) => {
    const app = page.locator('#app');

    // #app should have children (not empty or "Loading")
    const childCount = await app.evaluate((el) => el.children.length);
    expect(childCount).toBeGreaterThan(0);

    // Root element should be hm-vbox
    const firstChild = await app.evaluate((el) => el.children[0]?.tagName);
    expect(firstChild).toBe('HM-VBOX');

    // "Loading" text should be gone
    const text = await app.evaluate((el) => el.textContent);
    expect(text).not.toContain('Loading');
  });

  test('all layout components present', async ({ page }) => {
    const expected = [
      'hm-split',
      'hm-editor',
      'hm-terminal',
      'hm-filetree',
      'hm-tabs',
      'hm-statusbar',
      'hm-error-panel',
      'hm-panel-header',
    ];

    for (const tag of expected) {
      const count = await page.locator(tag).count();
      expect(count, `Expected ${tag} to be in the DOM`).toBeGreaterThan(0);
    }
  });

  test('status bar shows cell values', async ({ page }) => {
    // The "status" cell was registered as "Ready" during boot
    const statusText = await page.locator('hm-statusbar').evaluate((el) => {
      return el.shadowRoot?.textContent || '';
    });
    expect(statusText).toContain('Ready');
  });

  test('cell reactivity updates status bar', async ({ page }) => {
    // Update the status cell
    await fireEvent(page, 'cell:update', { name: 'status', value: 'Analyzing...' });

    // Wait for Lit to re-render
    await page.waitForFunction(() => {
      const sb = document.querySelector('hm-statusbar');
      return sb?.shadowRoot?.textContent?.includes('Analyzing...');
    });

    const statusText = await page.locator('hm-statusbar').evaluate((el) => {
      return el.shadowRoot?.textContent || '';
    });
    expect(statusText).toContain('Analyzing...');
  });
});

// ── Group 2: Editor ──────────────────────────────────────────────────

test.describe('Editor', () => {
  test.beforeEach(async ({ page }) => {
    await bootApp(page);
    await sendBootMessages(page);
    await waitForMonaco(page);
  });

  test('editor loads file content', async ({ page }) => {
    const testContent = '#lang racket\n(define x 42)\n(+ x 1)';
    await fireEvent(page, 'editor:open', {
      path: '/tmp/test-project/test.rkt',
      content: testContent,
      language: 'racket',
    });

    // Wait for Monaco to have the content
    await page.waitForFunction(
      (expected) => {
        const editor = document.querySelector('hm-editor');
        return editor?._editor?.getValue() === expected;
      },
      testContent
    );

    // Verify Monaco editor container is present in shadow DOM
    const hasMonaco = await page.locator('hm-editor').evaluate((el) => {
      return el.shadowRoot?.querySelector('.monaco-editor') !== null;
    });
    expect(hasMonaco).toBe(true);

    // Verify content
    const value = await page.locator('hm-editor').evaluate((el) => {
      return el._editor?.getValue();
    });
    expect(value).toBe(testContent);
  });

  test('editor language set correctly', async ({ page }) => {
    await fireEvent(page, 'editor:open', {
      path: '/tmp/test-project/test.rkt',
      content: '#lang racket\n(+ 1 2)',
      language: 'racket',
    });

    // Wait for content to load
    await page.waitForFunction(() => {
      const editor = document.querySelector('hm-editor');
      return editor?._editor?.getValue()?.includes('#lang racket');
    });

    const lang = await page.locator('hm-editor').evaluate((el) => {
      return el._editor?.getModel()?.getLanguageId();
    });
    expect(lang).toBe('racket');
  });

  test('editor goto sets cursor position', async ({ page }) => {
    await fireEvent(page, 'editor:open', {
      path: '/tmp/test-project/test.rkt',
      content: '#lang racket\n(define x 42)\n(+ x 1)',
      language: 'racket',
    });

    // Wait for content to load
    await page.waitForFunction(() => {
      const editor = document.querySelector('hm-editor');
      return editor?._editor?.getValue()?.includes('#lang racket');
    });

    // Send goto command (Racket uses 0-based columns, editor:goto handler adds +1)
    await fireEvent(page, 'editor:goto', { line: 2, col: 8 });

    // Verify cursor position (editor:goto converts: lineNumber=line, column=col+1)
    const position = await page.locator('hm-editor').evaluate((el) => {
      const pos = el._editor?.getPosition();
      return pos ? { lineNumber: pos.lineNumber, column: pos.column } : null;
    });
    expect(position).toEqual({ lineNumber: 2, column: 9 });
  });
});

// ── Group 3: Language Intelligence ───────────────────────────────────

test.describe('Language intelligence', () => {
  test.beforeEach(async ({ page }) => {
    await bootApp(page);
    await sendBootMessages(page);
    await waitForMonaco(page);

    // Open a file so the editor is active
    await fireEvent(page, 'editor:open', {
      path: '/tmp/test-project/test.rkt',
      content: '#lang racket\n(define x 42)\n(+ x 1)',
      language: 'racket',
    });

    // Wait for content to load
    await page.waitForFunction(() => {
      const editor = document.querySelector('hm-editor');
      return editor?._editor?.getValue()?.includes('#lang racket');
    });
  });

  test('diagnostics create Monaco markers', async ({ page }) => {
    await fireEvent(page, 'intel:diagnostics', {
      uri: '/tmp/test-project/test.rkt',
      items: [
        {
          severity: 'error',
          message: 'unbound identifier: foo',
          range: { startLine: 3, startCol: 1, endLine: 3, endCol: 4 },
          source: 'check-syntax',
        },
      ],
    });

    // Check Monaco model markers
    const markers = await page.locator('hm-editor').evaluate((el) => {
      const model = el._editor?.getModel();
      if (!model) return [];
      const monaco = el._monaco;
      return monaco.editor.getModelMarkers({ resource: model.uri }).map((m) => ({
        severity: m.severity,
        message: m.message,
        startLineNumber: m.startLineNumber,
        startColumn: m.startColumn,
      }));
    });

    expect(markers.length).toBe(1);
    expect(markers[0].message).toBe('unbound identifier: foo');
    // Monaco MarkerSeverity.Error = 8
    expect(markers[0].severity).toBe(8);
    // Column should be 0-based + 1 = 2
    expect(markers[0].startColumn).toBe(2);
  });

  test('diagnostics render in error panel', async ({ page }) => {
    await fireEvent(page, 'intel:diagnostics', {
      uri: '/tmp/test-project/test.rkt',
      items: [
        {
          severity: 'error',
          message: 'unbound identifier: foo',
          range: { startLine: 3, startCol: 1, endLine: 3, endCol: 4 },
          source: 'check-syntax',
        },
      ],
    });

    // Wait for error panel to render the row
    await page.waitForFunction(() => {
      const panel = document.querySelector('hm-error-panel');
      return panel?.shadowRoot?.querySelector('.row') !== null;
    });

    const panelContent = await page.locator('hm-error-panel').evaluate((el) => {
      const rows = el.shadowRoot?.querySelectorAll('.row') || [];
      return Array.from(rows).map((row) => ({
        icon: row.querySelector('.icon')?.textContent?.trim(),
        message: row.querySelector('.message')?.textContent?.trim(),
        location: row.querySelector('.location')?.textContent?.trim(),
      }));
    });

    expect(panelContent.length).toBe(1);
    expect(panelContent[0].message).toBe('unbound identifier: foo');
    expect(panelContent[0].icon).toBe('\u2297'); // ⊗ circled times for error
  });

  test('error panel shows correct count', async ({ page }) => {
    await fireEvent(page, 'intel:diagnostics', {
      uri: '/tmp/test-project/test.rkt',
      items: [
        {
          severity: 'error',
          message: 'first error',
          range: { startLine: 1, startCol: 0, endLine: 1, endCol: 5 },
        },
        {
          severity: 'warning',
          message: 'second issue',
          range: { startLine: 2, startCol: 0, endLine: 2, endCol: 5 },
        },
      ],
    });

    // Wait for rows to render
    await page.waitForFunction(() => {
      const panel = document.querySelector('hm-error-panel');
      const rows = panel?.shadowRoot?.querySelectorAll('.row');
      return rows && rows.length === 2;
    });

    const headerText = await page.locator('hm-error-panel').evaluate((el) => {
      return el.shadowRoot?.querySelector('.header')?.textContent?.trim();
    });

    expect(headerText).toContain('Problems (2)');
  });

  test('error panel click dispatches editor:goto', async ({ page }) => {
    await fireEvent(page, 'intel:diagnostics', {
      uri: '/tmp/test-project/test.rkt',
      items: [
        {
          severity: 'error',
          message: 'test error',
          range: { startLine: 5, startCol: 3, endLine: 5, endCol: 10 },
        },
      ],
    });

    // Wait for the row to appear
    await page.waitForFunction(() => {
      const panel = document.querySelector('hm-error-panel');
      return panel?.shadowRoot?.querySelector('.row') !== null;
    });

    // Clear invocations before clicking
    await clearInvocations(page);

    // Click the error row
    await page.locator('hm-error-panel').evaluate((el) => {
      const row = el.shadowRoot?.querySelector('.row');
      row?.click();
    });

    // Check that editor:goto was dispatched to Racket
    const invocations = await getInvocations(page);
    const gotoInvocation = invocations.find(
      (i) => i.args?.message?.name === 'editor:goto'
    );
    expect(gotoInvocation).toBeTruthy();
    expect(gotoInvocation.args.message.line).toBe(5);
    expect(gotoInvocation.args.message.col).toBe(3);
  });

  test('semantic colors create decorations', async ({ page }) => {
    await fireEvent(page, 'intel:colors', {
      uri: '/tmp/test-project/test.rkt',
      colors: [
        {
          style: 'lexically-bound',
          range: { startLine: 2, startCol: 8, endLine: 2, endCol: 9 },
        },
      ],
    });

    // Verify decorations through Monaco's API (more reliable than DOM queries,
    // since Monaco only renders visible line spans on demand)
    const decorations = await page.locator('hm-editor').evaluate((el) => {
      const model = el._editor?.getModel();
      if (!model) return [];
      const allDecos = el._editor.getDecorationsInRange(
        new el._monaco.Range(1, 1, 100, 1)
      );
      return (allDecos || [])
        .filter((d) => d.options?.inlineClassName?.startsWith('hm-cs'))
        .map((d) => d.options.inlineClassName);
    });

    expect(decorations).toContain('hm-cs-lexically-bound');
  });

  test('arrows hidden by default, shown on hover', async ({ page }) => {
    await fireEvent(page, 'intel:arrows', {
      uri: '/tmp/test-project/test.rkt',
      arrows: [
        {
          kind: 'binding',
          from: { startLine: 2, startCol: 8, endLine: 2, endCol: 9 },
          to: { startLine: 3, startCol: 1, endLine: 3, endCol: 2 },
        },
      ],
    });

    // Arrows should NOT be visible by default
    const initialCount = await page.locator('hm-editor').evaluate((el) => {
      const svg = el.shadowRoot?.querySelector('svg.hm-arrow-overlay');
      return svg?.querySelectorAll('.hm-arrow')?.length ?? 0;
    });
    expect(initialCount).toBe(0);

    // Simulate hover over the arrow's "from" endpoint by triggering
    // Monaco's onMouseMove with a position inside the from range
    await page.locator('hm-editor').evaluate((el) => {
      const overlay = el._arrowOverlay;
      if (!overlay) return;
      // Directly call the internal method with a mock event matching
      // the "from" range (line 2, col 9 which is 1-based col 9 inside
      // startCol=8..endCol=9)
      overlay._onMouseMove({
        target: { position: { lineNumber: 2, column: 9 } },
      });
    });

    const arrowData = await page.locator('hm-editor').evaluate((el) => {
      const svg = el.shadowRoot?.querySelector('svg.hm-arrow-overlay');
      if (!svg) return { count: 0 };
      const paths = svg.querySelectorAll('.hm-arrow');
      return {
        count: paths.length,
        hasPath: paths[0]?.getAttribute('d')?.startsWith('M') ?? false,
        stroke: paths[0]?.getAttribute('stroke'),
      };
    });

    expect(arrowData.count).toBe(1);
    expect(arrowData.hasPath).toBe(true);
    expect(arrowData.stroke).toBe('#4488ff'); // binding arrow color

    // Simulate moving to a non-arrow position — arrows should clear.
    // (We don't use onMouseLeave — WKWebView fires spurious leave events.
    // Arrows clear naturally when the mouse moves to a position with no
    // matching arrows.)
    await page.locator('hm-editor').evaluate((el) => {
      el._arrowOverlay?._onMouseMove({
        target: { position: { lineNumber: 1, column: 1 } },
      });
    });

    const afterMove = await page.locator('hm-editor').evaluate((el) => {
      const svg = el.shadowRoot?.querySelector('svg.hm-arrow-overlay');
      return svg?.querySelectorAll('.hm-arrow')?.length ?? 0;
    });
    expect(afterMove).toBe(0);
  });

  test('intel:clear removes markers, errors, and arrows', async ({ page }) => {
    // First, populate everything
    await fireEvent(page, 'intel:diagnostics', {
      uri: '/tmp/test-project/test.rkt',
      items: [
        {
          severity: 'error',
          message: 'test',
          range: { startLine: 1, startCol: 0, endLine: 1, endCol: 5 },
        },
      ],
    });

    await fireEvent(page, 'intel:arrows', {
      uri: '/tmp/test-project/test.rkt',
      arrows: [
        {
          kind: 'binding',
          from: { startLine: 2, startCol: 8, endLine: 2, endCol: 9 },
          to: { startLine: 3, startCol: 1, endLine: 3, endCol: 2 },
        },
      ],
    });

    // Wait for error panel to have rows
    await page.waitForFunction(() => {
      const panel = document.querySelector('hm-error-panel');
      return panel?.shadowRoot?.querySelector('.row') !== null;
    });

    // Now clear
    await fireEvent(page, 'intel:clear', { uri: '/tmp/test-project/test.rkt' });

    // Wait for error panel to clear
    await page.waitForFunction(() => {
      const panel = document.querySelector('hm-error-panel');
      return panel?.shadowRoot?.querySelector('.row') === null;
    });

    // Verify Monaco markers cleared
    const markerCount = await page.locator('hm-editor').evaluate((el) => {
      const model = el._editor?.getModel();
      if (!model) return -1;
      return el._monaco.editor.getModelMarkers({ resource: model.uri }).length;
    });
    expect(markerCount).toBe(0);

    // Verify error panel is empty
    const emptyText = await page.locator('hm-error-panel').evaluate((el) => {
      return el.shadowRoot?.querySelector('.empty')?.textContent?.trim();
    });
    expect(emptyText).toBe('No problems detected.');

    // Verify SVG arrows cleared
    const arrowCount = await page.locator('hm-editor').evaluate((el) => {
      const svg = el.shadowRoot?.querySelector('svg.hm-arrow-overlay');
      return svg?.querySelectorAll('.hm-arrow')?.length ?? 0;
    });
    expect(arrowCount).toBe(0);
  });
});

// ── Group 4: Document Lifecycle ──────────────────────────────────────

test.describe('Document lifecycle', () => {
  test.beforeEach(async ({ page }) => {
    await bootApp(page);
    await sendBootMessages(page);
    await waitForMonaco(page);
  });

  test('document:opened dispatched on editor:open', async ({ page }) => {
    await clearInvocations(page);

    await fireEvent(page, 'editor:open', {
      path: '/tmp/test-project/hello.rkt',
      content: '#lang racket\n"hello"',
      language: 'racket',
    });

    // Wait for the dispatch to happen
    await page.waitForFunction(() => {
      const invocations = window.__getInvocations('send_to_racket');
      return invocations.some((i) => i.args?.message?.name === 'document:opened');
    });

    const invocations = await getInvocations(page);
    const docOpened = invocations.find(
      (i) => i.args?.message?.name === 'document:opened'
    );

    expect(docOpened).toBeTruthy();
    expect(docOpened.args.message.uri).toBe('/tmp/test-project/hello.rkt');
    expect(docOpened.args.message.text).toBe('#lang racket\n"hello"');
    expect(docOpened.args.message.languageId).toBe('racket');
  });
});
