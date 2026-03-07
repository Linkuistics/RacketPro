#!/usr/bin/env node
// run-subset.mjs — Run specific tests by number to isolate failures.
// Usage: node test/e2e-app/run-subset.mjs 05,14
//        node test/e2e-app/run-subset.mjs 11,12,13,14

import { spawn, execSync } from 'node:child_process';
import { existsSync, rmSync, mkdirSync, readdirSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(__dirname, '../..');
const DEBUG_DIR = '/tmp/heavymental-debug';
const BINARY = resolve(ROOT, 'src-tauri/target/debug/heavy-mental');
const TESTS_DIR = resolve(__dirname, 'tests');

const nums = (process.argv[2] || '').split(',').map(s => s.trim()).filter(Boolean);
if (!nums.length) {
  console.error('Usage: node run-subset.mjs 05,14');
  process.exit(1);
}

// Find test files matching the given numbers
const allFiles = readdirSync(TESTS_DIR).filter(f => f.endsWith('.mjs')).sort();
const selected = allFiles.filter(f => nums.some(n => f.startsWith(n + '-')));
if (!selected.length) {
  console.error(`No tests found for: ${nums.join(', ')}`);
  process.exit(1);
}

console.log(`Running tests: ${selected.join(', ')}\n`);

// Spawn app
rmSync(DEBUG_DIR, { recursive: true, force: true });
mkdirSync(DEBUG_DIR, { recursive: true });

const app = spawn(BINARY, [], {
  cwd: ROOT,
  stdio: ['ignore', 'pipe', 'pipe'],
  env: { ...process.env, RUST_LOG: 'info' },
});
app.stdout.on('data', d => {
  for (const line of d.toString().split('\n').filter(Boolean))
    console.log(`  [app:out] ${line}`);
});
app.stderr.on('data', d => {
  for (const line of d.toString().split('\n').filter(Boolean))
    console.log(`  [app:err] ${line}`);
});

const kill = () => {
  if (app && !app.killed) {
    app.kill('SIGTERM');
    setTimeout(() => { try { app.kill('SIGKILL'); } catch {} }, 3000).unref();
  }
};
process.on('SIGINT', () => { kill(); process.exit(130); });

// Wait for app
const helpers = await import('./helpers.mjs');
console.log('Waiting for app...');
try {
  await helpers.waitForApp();
  console.log('App ready.\n');
} catch (e) {
  console.error(`App failed: ${e.message}`);
  kill();
  process.exit(1);
}

// Run selected tests
let passed = 0, failed = 0;
for (const file of selected) {
  const mod = await import(resolve(TESTS_DIR, file));
  const label = `${file}: ${mod.name || file}`;
  process.stdout.write(`  ${label} ... `);
  try {
    await mod.run(helpers);
    console.log('PASS');
    passed++;
  } catch (err) {
    console.log('FAIL');
    console.log(`    ${err.message.split('\n')[0]}`);
    failed++;
  }
}

console.log(`\n${passed} passed, ${failed} failed`);
kill();
process.exit(failed > 0 ? 1 : 0);
