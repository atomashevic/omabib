#!/usr/bin/env node
// Unit tests for plugin/components/OverviewText.js and Format.js.
// Optional argument: a real alphaXiv overview .md file to parse end to end.
'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert');

function load(name) {
  const file = path.join(__dirname, '..', 'plugin', 'components', name);
  const source = fs.readFileSync(file, 'utf8').replace(/^\.pragma library\s*$/m, '');
  const context = {};
  vm.createContext(context);
  vm.runInContext(source, context, { filename: file });
  // Values created inside the vm context are not deepStrictEqual to this
  // realm's; round-trip them through JSON so assertions compare structure.
  const wrapped = {};
  for (const [k, v] of Object.entries(context)) {
    wrapped[k] = typeof v === 'function' ? (...args) => {
      const r = v(...args);
      return r === undefined ? r : JSON.parse(JSON.stringify(r));
    } : v;
  }
  return wrapped;
}

const O = load('OverviewText.js');
const F = load('Format.js');
let passed = 0;
function test(name, fn) { fn(); passed++; console.log('PASS:', name); }

test('escapes raw HTML and refuses non-http links', () => {
  const html = O.inline('<script>alert(1)</script> [x](javascript:alert(1)) [ok](https://example.org/a?b=1)');
  assert(!html.includes('<script>'), html);
  assert(html.includes('&lt;script&gt;'), html);
  assert(!/href="javascript/i.test(html), html);
  assert(html.includes('<a href="https://example.org/a?b=1">ok</a>'), html);
});

test('bold, italic and code', () => {
  assert.strictEqual(O.inline('a **b** *c* `d<e>`'), 'a <b>b</b> <i>c</i> <tt>d&lt;e&gt;</tt>');
  assert.strictEqual(O.inline('2 * 3 * 4'), '2 * 3 * 4');
});

test('drops the report title, numbers headings, groups paragraphs', () => {
  const b = O.blocks('# Research Report: “X”\n\n## 1. Authors and Institutions\n\nLine one\nline two.\n\n### 3.1 Central concept\n\nText');
  assert.deepStrictEqual(b.map(x => x.type), ['h2', 'p', 'h3', 'p']);
  assert.strictEqual(b[0].number, '1');
  assert.strictEqual(b[0].text, 'Authors and Institutions');
  assert.strictEqual(b[1].html, 'Line one line two.');
  assert.strictEqual(b[2].number, '3.1');
});

test('ordered list items keep their indented explanation', () => {
  const b = O.blocks('Intro:\n\n1. **First question?**  \n   Why it matters.\n\n2. **Second?**  \n   More detail.\n\nAfter.');
  assert.deepStrictEqual(b.map(x => x.type), ['p', 'ol', 'p']);
  assert.strictEqual(b[1].items.length, 2);
  assert.strictEqual(b[1].items[0].html, '<b>First question?</b>');
  assert.strictEqual(b[1].items[0].detail, 'Why it matters.');
  assert.strictEqual(b[1].items[1].marker, '2.');
});

test('bullets, quotes, tables, code and rules', () => {
  const b = O.blocks('- a\n- b\n\n> quoted\n\n| h1 | h2 |\n|---|---|\n| x | **y** |\n\n```\ncode <here>\n```\n\n---');
  assert.deepStrictEqual(b.map(x => x.type), ['ul', 'quote', 'table', 'code', 'hr']);
  assert.deepStrictEqual(b[2].header, ['h1', 'h2']);
  assert.deepStrictEqual(b[2].rows[0], ['x', '<b>y</b>']);
  assert.strictEqual(b[3].text, 'code <here>');
});

test('section strip uses short names', () => {
  const b = O.blocks('## 1. Authors and Institutions\n\nx\n\n## 2. Position within the Broader Research Landscape\n\ny\n\n## 5. Main Findings and Results\n\nz');
  assert.deepStrictEqual(Array.from(O.sections(b), s => s.title), ['Authors', 'Landscape', 'Findings']);
});

test('### sections when the overview opens with prose', () => {
  const b = O.blocks('This report provides a detailed analysis.\n\n### 1. Authors and Institution(s)\n\nx\n\n#### Detail\n\ny\n\n### 5. Main Findings and Results\n\nz');
  assert.deepStrictEqual(b.map(x => x.type), ['p', 'h2', 'p', 'h3', 'p', 'h2', 'p']);
  assert.deepStrictEqual(Array.from(O.sections(b), s => s.title), ['Authors', 'Findings']);
});

test('nested bullets stay with their parent item', () => {
  const b = O.blocks('*   **Behavioral Patterns:**\n    *   **Self-sufficient:** high rates.\n    *   **Stochastic:** below\n        baseline.\n*   **Scaling Paradox:** more.');
  assert.deepStrictEqual(b.map(x => x.type), ['ul']);
  assert.strictEqual(b[0].items.length, 2);
  assert.deepStrictEqual(b[0].items[0].sub, ['<b>Self-sufficient:</b> high rates.', '<b>Stochastic:</b> below baseline.']);
  assert.deepStrictEqual(b[0].items[1].sub, []);
});

test('format helpers', () => {
  assert.strictEqual(F.shortAuthors('Wang, Steven and Hunt, Kyle and Tang, Shaojie'), 'Wang et al.');
  assert.strictEqual(F.shortAuthors('Das, Anath Bandhu and Pal, Pinaki'), 'Das & Pal');
  assert.strictEqual(F.shortAuthors('Arnault Chatelain and Étienne Ollion'), 'Chatelain & Ollion');
  assert.strictEqual(F.fullAuthors('Wang, Steven and Hunt, Kyle and Tang, Shaojie', 2), 'Steven Wang, Kyle Hunt, +1 more');
  assert.strictEqual(F.fullAuthors('{World Research Organization}'), 'World Research Organization');
  const now = Date.parse('2026-09-15T09:00:00Z');
  assert.strictEqual(F.relativeTime('2026-09-14T18:52:39.090Z', now), '14h ago');
  assert.strictEqual(F.relativeTime('2026-09-15 08:02:08', now), '57m ago');
  assert.strictEqual(F.evidenceLabel('PDF p. 4 · /home/x/paper.pdf'), 'p. 4');
  assert.strictEqual(F.arxivId({ fields: { doi: '10.48550/arxiv.2609.07987' } }), '2609.07987');
  assert.strictEqual(F.arxivId({ fields: { url: 'https://arxiv.org/pdf/2401.01234v2.pdf' } }), '2401.01234v2');
  assert.strictEqual(F.dirname('/home/a/.local/share/omabib/pdfs/x.pdf', '/home/a'), '~/.local/share/omabib/pdfs');
});

const real = process.argv[2];
if (real) {
  test('real overview parses end to end', () => {
    const md = fs.readFileSync(real, 'utf8');
    const b = O.blocks(md);
    const s = O.sections(b);
    assert(s.length >= 5, JSON.stringify(s));
    assert(!b.some(x => /^Research Report/.test(x.text || '')), 'title dropped');
    assert(b.some(x => x.type === 'ol' || x.type === 'ul'), 'lists are parsed');
    assert(!b.some(x => x.type === 'p' && /^\*\s/.test(x.html)), 'no bullet falls through as a paragraph');
    assert(!JSON.stringify(b).includes('<script'), 'no raw tags');
    console.log('      sections:', Array.from(s, x => x.number + ' ' + x.title).join(' | '));
  });
}
console.log(`${passed} passed`);
