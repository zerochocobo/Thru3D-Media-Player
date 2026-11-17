const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../../main/assets/thunder-login/review.js'), 'utf8');
function harness(url = 'https://i.xunlei.com/xlcaptcha/android.html') {
  const sent = []; let receive, disconnect, tick, connected = 0, supplied;
  const page = {reviewCb(value) { supplied = value; }};
  const window = {wrappedJSObject: page}; window.top = window;
  const port = {postMessage(value) {sent.push(value);}, onMessage: {addListener(fn) {receive = fn;}}, onDisconnect: {addListener(fn) {disconnect = fn;}}};
  vm.runInNewContext(source, {location: {href: url}, window, cloneInto: value => value,
    setInterval(fn) { tick = fn; return 1; }, clearInterval() {},
    browser: {runtime: {connectNative() {connected++; return port;}}}});
  return {sent, page, receive: value => receive(value), disconnect: () => disconnect(), tick: () => tick(), connected: () => connected, supplied: () => supplied};
}
test('ordinary pages receive no bridge; bound native challenge initializes official review', () => {
  const h = harness(); assert.equal(h.page.XLJSWebViewBridge, undefined);
  const review = {creditkey: 'fixture-credit', reviewurl: 'https://i.xunlei.com/xlcaptcha/vertifyPhone.html'};
  h.receive({type: 'review', review}); h.tick(); assert.equal(h.supplied(), review);
  assert.equal(harness('https://elsewhere.invalid/').connected(), 0);
});
test('only a successful review produces a one-shot result; disconnect revokes it', () => {
  const h = harness(); h.receive({type: 'review', review: {creditkey: 'old'}}); h.tick();
  const send = value => h.page.XLJSWebViewBridge.sendMessage('nativeRecvOperationResult', JSON.stringify(value), '');
  send({roCommand: 'other', roErrorCode: '0', roData: {creditkey: 'ignored'}});
  send({roCommand: 'android_review', roErrorCode: '30001', roData: {creditkey: 'ignored'}});
  assert.equal(h.sent.length, 1);
  send({roCommand: 'android_review', roErrorCode: '0', roData: {creditkey: 'new-credit'}});
  send({roCommand: 'android_review', roErrorCode: '0', roData: {creditkey: 'duplicate'}});
  assert.equal(h.sent.length, 2); assert.equal(h.sent[1].credit_key, 'new-credit');
  const cancelled = harness(); cancelled.receive({type: 'review', review: {}}); cancelled.tick(); cancelled.disconnect();
  cancelled.page.XLJSWebViewBridge.sendMessage('nativeRecvOperationResult', JSON.stringify({roCommand:'android_review',roErrorCode:'0',roData:{creditkey:'late'}}));
  assert.equal(cancelled.sent.length, 1);
});
