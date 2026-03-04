import { signal, effect } from '@preact/signals-core';
import { LitElement, html, css } from 'lit';

const count = signal(0);
effect(() => {
  document.getElementById('app').textContent = `MrRacket: signals work! Count = ${count.value}`;
});
count.value = 42;

console.log('[MrRacket] Lit version:', LitElement ? 'loaded' : 'MISSING');
console.log('[MrRacket] Signals working:', count.value === 42);
