#!/usr/bin/env node
// run-tests.mjs — Spawn the live HeavyMental app and drive E2E tests through
// the debug eval facility.
//
// Usage:  node test/e2e-app/run-tests.mjs [filter]
//   filter — optional substring to match test filenames (e.g. "boot" "stepper")

import { spawn, execSync } from 'node:child_process';
import { existsSync, rmSync, mkdirSync, readdirSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(__dirname, '../..');

// ── Config ──────────────────────────────────────────────────────────────

const DEBUG_DIR  = '/tmp/heavymental-debug';
const BINARY     = resolve(ROOT, 'src-tauri/target/debug/heavy-mental');
const TESTS_DIR  = resolve(__dirname, 'tests');

// ── Preflight ───────────────────────────────────────────────────────────

function preflight() {
  if (!existsSync(BINARY)) {
    console.log('Debug binary not found. Building...');
    execSync('cargo build', { cwd: resolve(ROOT, 'src-tauri'), stdio: 'inherit' });
    if (!existsSync(BINARY)) {
      console.error(`Binary still missing at ${BINARY}`);
      process.exit(1);
    }
  }
  console.log(`Binary: ${BINARY}`);
}

// ── App lifecycle ───────────────────────────────────────────────────────

let appProcess = null;

function spawnApp() {
  // Clean debug dir for a fresh run
  rmSync(DEBUG_DIR, { recursive: true, force: true });
  mkdirSync(DEBUG_DIR, { recursive: true });

  appProcess = spawn(BINARY, [], {
    cwd: ROOT,
    stdio: ['ignore', 'pipe', 'pipe'],
    env: { ...process.env, RUST_LOG: 'info' },
  });

  // Stream app output for debugging
  appProcess.stdout.on('data', d => {
    for (const line of d.toString().split('\n').filter(Boolean)) {
      console.log(`  [app:out] ${line}`);
    }
  });
  appProcess.stderr.on('data', d => {
    for (const line of d.toString().split('\n').filter(Boolean)) {
      console.log(`  [app:err] ${line}`);
    }
  });
  appProcess.on('exit', (code, sig) => {
    console.log(`  [app] exited (code=${code}, signal=${sig})`);
  });
}

function killApp() {
  if (appProcess && !appProcess.killed) {
    appProcess.kill('SIGTERM');
    // Force-kill after grace period; unref so it doesn't block Node exit
    const t = setTimeout(() => {
      try { if (appProcess && !appProcess.killed) appProcess.kill('SIGKILL'); }
      catch { /* already dead */ }
    }, 3000);
    t.unref();
  }
}

// ── Test discovery & execution ──────────────────────────────────────────

async function discoverTests(filter) {
  const files = readdirSync(TESTS_DIR)
    .filter(f => f.endsWith('.mjs'))
    .sort();

  const filtered = filter
    ? files.filter(f => f.includes(filter))
    : files;

  const tests = [];
  for (const file of filtered) {
    const mod = await import(resolve(TESTS_DIR, file));
    tests.push({ file, name: mod.name || file, run: mod.run });
  }
  return tests;
}

async function runTests(filter) {
  const tests = await discoverTests(filter);
  if (tests.length === 0) {
    console.log('No tests found.');
    return { passed: 0, failed: 0, skipped: 0 };
  }

  // Import helpers lazily so the module is only loaded once
  const helpers = await import('./helpers.mjs');

  let passed = 0, failed = 0, skipped = 0;

  for (const test of tests) {
    const label = `${test.file}: ${test.name}`;
    process.stdout.write(`  ${label} ... `);

    try {
      await test.run(helpers);
      console.log('PASS');
      passed++;
    } catch (err) {
      console.log('FAIL');
      console.log(`    ${err.message}`);
      if (err.stack && !err.message.includes(err.stack)) {
        // Print first 3 stack frames for context
        const frames = err.stack.split('\n').slice(1, 4).join('\n');
        console.log(`    ${frames}`);
      }
      failed++;
    }
  }

  return { passed, failed, skipped };
}

// ── Main ────────────────────────────────────────────────────────────────

async function main() {
  const filter = process.argv[2] || null;

  console.log('═══ HeavyMental E2E Tests (Debug Harness) ═══\n');

  // 1. Preflight
  preflight();

  // 2. Spawn app
  console.log('\nSpawning app...');
  spawnApp();

  // 3. Wait for ready
  const helpers = await import('./helpers.mjs');
  console.log('Waiting for app to be ready...');
  try {
    await helpers.waitForApp();
    console.log('App ready.\n');
  } catch (err) {
    console.error(`App failed to start: ${err.message}`);
    killApp();
    process.exit(1);
  }

  // 4. Run tests
  console.log('Running tests:\n');
  const results = await runTests(filter);

  // 5. Report
  console.log('\n═══ Results ═══');
  console.log(`  Passed:  ${results.passed}`);
  console.log(`  Failed:  ${results.failed}`);
  console.log(`  Skipped: ${results.skipped}`);
  console.log(`  Total:   ${results.passed + results.failed + results.skipped}`);

  // 6. Cleanup
  killApp();

  process.exit(results.failed > 0 ? 1 : 0);
}

// Ensure cleanup on unexpected exit
process.on('SIGINT', () => { killApp(); process.exit(130); });
process.on('SIGTERM', () => { killApp(); process.exit(143); });
process.on('uncaughtException', (err) => {
  console.error(`Uncaught: ${err.message}`);
  killApp();
  process.exit(1);
});

main();
