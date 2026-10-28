const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const tools = require('../android/web-browser/src/main/assets/bookmark-remote/app.js');
test('bulk preview deduplicates and excludes credentials, OAuth and unsafe schemes', () => {
  const result = tools.prepare(tools.lines('example.com\nhttps://example.com/\nhttps://good.example/a#anchor\nfile:///secret\nhttps://user:pass@example.com\nhttps://example.com/?%63ode=private\njavascript:alert(1)'), [{url:'https://example.com'}]);
  assert.equal(result.duplicate, 2); assert.equal(result.invalid, 4);
  assert.deepEqual(result.additions, [{url:'https://good.example/a',title:'good.example'}]);
});
test('export escapes imported markup and excludes invalid URLs', () => {
  const html = tools.html([{url:'https://example.com/?q="<&',title:'<img src=x onerror=alert(1)>'},{url:'javascript:alert(1)',title:'bad'}]);
  assert.ok(html.includes('&lt;img')); assert.ok(!html.includes('<img')); assert.ok(html.includes('&quot;&lt;&amp;')); assert.ok(!html.includes('javascript:'));
});
test('feedback uses exact page URLs and explicit fields, without login data or invented errors', () => {
  const text = tools.feedback([{url:'https://example.com/watch?v=abc&list=def',title:'Title\nsecond line',at:1793155200000,cookies:'secret',error:'injected'},
    {url:'https://example.com/?token=secret',title:'Skip'}], {heading:'Feedback',issue:'Issue',visited:'Visited'});
  assert.ok(text.includes('Issue: \n')); assert.ok(text.includes('Title second line'));
  assert.ok(text.includes('https://example.com/watch?v=abc&list=def')); assert.ok(text.includes('2026-10-28'));
  assert.ok(!text.includes('secret') && !text.includes('injected'));
});
test('page uses the shared four-language catalog without missing UI strings', () => {
  const root = 'android/web-browser/src/main/assets/bookmark-remote/';
  const html = fs.readFileSync(root+'index.html','utf8'), js = fs.readFileSync(root+'app.js','utf8');
  const catalog = JSON.parse(fs.readFileSync('app/godot/i18n/translations.json','utf8'));
  const keys = [...html.matchAll(/data-(?:t|placeholder)="([^"]+)"/g), ...js.matchAll(/\bt\('([^']+)'\)/g), ...js.matchAll(/\bformat\('([^']+)'/g)].map(m=>m[1]);
  for (const lang of ['zh','zh_Hant','ja']) for (const key of keys) assert.ok(catalog[lang][key], `${lang}: ${key}`);
});
