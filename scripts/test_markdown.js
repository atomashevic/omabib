#!/usr/bin/env node
// Unit tests for plugin/components/Markdown.js: the note features (source
// line ranges, math, fenced code) on top of what test_overview_text.js covers.
'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert');

function load(name) {
  const file = path.join(__dirname, '..', 'plugin', 'components', name);
  const context = {};
  vm.createContext(context);
  // `.import "X.js" as Y` becomes a global Y holding that file's functions.
  let source = fs.readFileSync(file, 'utf8').replace(/^\.pragma library\s*$/m, '');
  source = source.replace(/^\.import "([^"]+\.js)" as (\w+)\s*$/mg, (_, dep, alias) => {
    const inner = {};
    vm.createContext(inner);
    vm.runInContext(fs.readFileSync(path.join(__dirname, '..', 'plugin', 'components', dep), 'utf8').replace(/^\.pragma library\s*$/m, ''), inner);
    context[alias] = inner;
    return '';
  });
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

const M = load('Markdown.js');
let passed = 0;
function test(name, fn) { fn(); passed++; console.log('PASS:', name); }
const style = {reading: 'Noto Sans', mono: 'Mono', size: 14, heading: 16, small: 11, text: '#b9bec6', bright: '#eceff2', muted: '#9a9ea5', dim: '#71757c', line: '#2b2f37', codeBg: '#181a1f', link: '#ff5c5c', urgent: '#ff0000'};

test('blocks keep their source line ranges', () => {
  const b = M.blocks('# Title\n\nfirst line\nsecond line\n\n- a\n- b\n  more\n\n```py\nx = 1\n```\n\n$$\na^2\n$$\n\n> q');
  assert.deepStrictEqual(b.map(x => [x.type, x.start, x.end]), [['h1', 0, 0], ['p', 2, 3], ['ul', 5, 7], ['code', 9, 11], ['math', 13, 15], ['quote', 17, 17]]);
});

test('note headings map # to h1, ## to h2, deeper to h3', () => {
  assert.deepStrictEqual(M.blocks('# a\n## b\n### c\n#### d').map(x => x.type), ['h1', 'h2', 'h3', 'h3']);
});

test('inline math, currency and escaped dollars', () => {
  const math = [];
  const html = M.inline('Cost $5 and $10; energy $E=mc^2$ and \\$x\\$ and \\(a_b\\)', math);
  assert.strictEqual(JSON.stringify(math), JSON.stringify([{tex: 'E=mc^2', display: false}, {tex: 'a_b', display: false}]));
  assert(html.startsWith('Cost $5 and $10; energy \uE0020\uE003 and $x$ and \uE0021\uE003'), JSON.stringify(html));
  assert.deepStrictEqual(M.inline('$ x$ and $x $', []), '$ x$ and $x $');
});

test('underscores and stars inside math and code are not emphasis', () => {
  const math = [];
  const html = M.inline('_see_ $x_1 * y_2 * z$ `a_b_c`', math);
  assert.strictEqual(math[0].tex, 'x_1 * y_2 * z');
  assert(html.startsWith('<i>see</i> '), html);
  assert(html.includes('<tt>a_b_c</tt>'), html);
});

test('display math: single line, multi-line and \\[ \\]', () => {
  const b = M.blocks('$$ \\sum_i x_i $$\n\n$$\n\\frac{a}{b}\n+ c\n$$\n\n\\[\ny\n\\]');
  assert.deepStrictEqual(b.map(x => x.type), ['math', 'math', 'math']);
  assert.strictEqual(b[0].tex, '\\sum_i x_i');
  assert.strictEqual(b[1].tex, '\\frac{a}{b}\n+ c');
  assert.strictEqual(b[2].tex, 'y');
  assert.deepStrictEqual(Array.from(M.mathKeys(b), k => k.key), ['D:\\sum_i x_i', 'D:\\frac{a}{b}\n+ c', 'D:y']);
});

test('an unclosed fence or math block runs to the end', () => {
  const b = M.blocks('text\n\n```js\nlet a = 1\n\nstill code');
  assert.deepStrictEqual(b.map(x => [x.type, x.start, x.end]), [['p', 0, 0], ['code', 2, 5]]);
  assert.strictEqual(b[1].lang, 'js');
  assert.deepStrictEqual(M.blocks('$$\nx').map(x => [x.type, x.start, x.end]), [['math', 0, 1]]);
});

test('rendered math becomes images; pending and failed math shows TeX', () => {
  const b = M.blocks('Energy $E<mc^2$.\n\n$$\\frac{1}{2}$$\n\nBad $\\oops$');
  const rendered = {'I:E<mc^2': {path: '/tmp/a b.svg', width: 30, height: 20}, 'D:\\frac{1}{2}': {path: '/tmp/d.svg', width: 12, height: 30}, 'I:\\oops': {error: 'unknown command'}};
  const html = M.toHtml(b, style, rendered);
  assert(html.includes('<img src="file:///tmp/a%20b.svg" width="30" height="20" style="vertical-align:middle">'), html);
  assert(/<p align="center"[^>]*>&nbsp;<img src="file:\/\/\/tmp\/d.svg" width="12" height="30">&nbsp;<\/p>/.test(html), html);
  assert(html.includes('<font color="#ff0000">$\\oops$</font>'), html);
  const pending = M.toHtml(b, style, {});
  assert(pending.includes('<font color="#71757c">$E&lt;mc^2$</font>'), pending);
  assert(!pending.includes('\uE002'), 'placeholders resolved');
});

test('code blocks: language label, escaped body, one padded cell', () => {
  const html = M.toHtml(M.blocks('```python\nif a < b:\n    print("<x>")\n```'), style, {});
  assert(html.includes('<table width="100%"') && html.includes('background-color:#181a1f'), html);
  assert(html.includes('>python</p>'), html);
  assert(html.includes('white-space:pre-wrap') && html.includes('if a &lt; b:<br>    print(&quot;&lt;x&gt;&quot;)</p></td>'), html);
});

test('private-use characters in the source cannot forge placeholders', () => {
  const html = M.toHtml(M.blocks('x \uE0020\uE003 y'), style, {});
  assert(!html.includes('<img') && html.includes('x 0 y'), html);
});

console.log(`${passed} passed`);
