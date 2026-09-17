#!/usr/bin/env node
// Unit tests for plugin/components/ChatText.js.
'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert');

const file = path.join(__dirname, '..', 'plugin', 'components', 'ChatText.js');
const context = {};
vm.createContext(context);
vm.runInContext(fs.readFileSync(file, 'utf8').replace(/^\.pragma library\s*$/m, ''), context, { filename: file });
const C = new Proxy(context, { get: (c, k) => (...args) => JSON.parse(JSON.stringify(c[k](...args))) });
let passed = 0;
function test(name, fn) { fn(); passed++; console.log('PASS:', name); }

test('tool labels read like sentences', () => {
  assert.strictEqual(C.toolLabel('mcp__omabib__get_reference', { id: 'r' }), 'Read the reference');
  assert.strictEqual(C.toolLabel('mcp__omabib__search', { query: 'sparse attention' }), 'Searched the library: “sparse attention”');
  assert.strictEqual(C.toolLabel('Read', { file_path: '/data/chats/c/context.json' }), 'Read context.json');
  assert.strictEqual(C.toolLabel('shell', { command: "/usr/bin/bash -lc 'ls /tmp'" }), 'Ran `ls /tmp`');
  assert.strictEqual(C.toolLabel('Bash', { command: 'ls' }), 'Ran `ls`');
  assert.strictEqual(C.toolLabel('mcp__omabib__something_new', {}), 'Omabib: something new');
  assert.strictEqual(C.toolIcon('mcp__omabib__add_note'), 'book');
  assert.strictEqual(C.toolIcon('WebFetch'), 'globe');
});

test('approval cards say what would happen', () => {
  const note = C.approvalSummary('mcp__omabib__add_note', { body: 'Table 2 matters', project_id: null }, 'Claude Code');
  assert.strictEqual(note.title, 'Allow Claude Code to save a note?');
  assert.strictEqual(note.detail, 'Table 2 matters\nScope: Global');
  const fetch = C.approvalSummary('WebFetch', { url: 'https://example.org' }, 'Claude Code');
  assert.strictEqual(fetch.title, 'Allow Claude Code to fetch https://example.org?');
});

test('page references become links outside tags and existing links', () => {
  const html = '<p>See p. 7 and pp. 9–10, page 12.</p><a href="https://x.org/p. 3">p. 3</a><img alt="p. 4">';
  const out = C.linkPages(html);
  assert(out.includes('<a href="omabib-page:7">p. 7</a>'), out);
  assert(out.includes('<a href="omabib-page:9">pp. 9</a>–10'), out);
  assert(out.includes('<a href="omabib-page:12">page 12</a>'), out);
  assert(out.includes('<a href="https://x.org/p. 3">p. 3</a>'), out);
  assert(out.includes('<img alt="p. 4">'), out);
  assert(C.linkPages('<p>p. 2</p>', '#ff5c5c').includes('<a href="omabib-page:2"><font color="#ff5c5c">p. 2</font></a>'));
  assert.strictEqual(C.firstPage('as shown on p. 14 and p. 2'), 14);
  assert.strictEqual(C.firstPage('no pages'), 0);
});

test('status and turn lines', () => {
  assert.strictEqual(C.statusLabel('approval'), 'Waiting for your approval');
  assert.strictEqual(C.statusLabel('idle'), '');
  assert.strictEqual(C.turnLabel({ interrupted: true }), 'Stopped');
  assert.strictEqual(C.turnLabel({ usage: { input_tokens: 6, cache_read_input_tokens: 20412, cache_creation_input_tokens: 39820, output_tokens: 389 } }), '60k read · 389 written');
  assert.strictEqual(C.turnLabel({ usage: { input_tokens: 95620, cached_input_tokens: 80512, output_tokens: 1396 } }), '96k read · 1.4k written');
});

console.log(`${passed} passed`);
