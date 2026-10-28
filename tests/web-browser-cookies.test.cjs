const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
let listener;
let queries = [];
let source = [
  { name: 'session', value: 'synthetic', domain: '.youtube.com', path: '/', secure: true, hostOnly: false },
  { name: 'partitioned', value: 'synthetic', domain: '.youtube.com', partitionKey: { topLevelSite: 'https://other.test' } }
];
const replies = [];
const context = {
  setTimeout() {},
  browser: {
    cookies: { async getAll(query) { queries.push(query); return source; } },
    runtime: { connectNative(name) {
      assert.equal(name, 'thru3d_cookies');
      return { onMessage: { addListener(fn) { listener = fn; } },
        onDisconnect: { addListener() {} }, postMessage(reply) { replies.push(reply); } };
    } }
  }
};
vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../android/web-browser/src/main/assets/web-browser/background.js'), 'utf8'), context);
(async () => {
  const request = '12345678-1234-1234-1234-123456789abc';
  await listener({ request, domains: ['youtube.com.evil.test'] });
  assert.equal(queries.length, 0);
  await listener({ request, domains: ['youtube.com'] });
  assert.equal(replies[0].cookies.length, 1);
  assert.equal(replies[0].cookies[0].name, 'session');
  source = Array(257).fill(source[0]);
  await listener({ request, domains: ['youtube.com'] });
  assert.equal(replies[1].ok, false);
  assert.equal(replies[1].cookies.length, 0);
  source = [];
  await listener({ request, domains: ['weibo.com', 'weibo.cn'] });
  assert.deepEqual(queries.slice(-2).map(q => q.domain), ['weibo.com', 'weibo.cn']);
  const count = queries.length;
  await listener({ request, domains: ['youtube.com', 'weibo.cn'] });
  assert.equal(queries.length, count, 'An unrelated account cannot be mixed into a session');
  console.log('Browser cookie background scope and limits: passed');
})().catch(error => { console.error(error); process.exitCode = 1; });
