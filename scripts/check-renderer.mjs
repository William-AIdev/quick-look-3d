import { readFile, readdir } from 'node:fs/promises';
import assert from 'node:assert/strict';
const dist = new URL('../renderer/dist/', import.meta.url);
const html = await readFile(new URL('index.html', dist), 'utf8');
assert.deepEqual(await readdir(dist), ['index.html'], 'Renderer must be a single HTML file');
assert.ok(html.includes('data:application/wasm;base64,'), 'Draco WASM must be embedded');
assert.doesNotMatch(html, /<script[^>]+src\s*=/i, 'Scripts must be embedded');
assert.doesNotMatch(html, /<link[^>]+href\s*=/i, 'Styles must be embedded');
console.log('PASS: single-file renderer with embedded decoder and no external scripts/styles');
