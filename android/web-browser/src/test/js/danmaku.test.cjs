const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname, '../../main/assets/web-browser/danmaku.js'), 'utf8');
const context = vm.createContext({});
vm.runInContext(source, context);
const api = vm.runInContext('Thru3DDanmaku', context);

test('blur radii become zero while offsets, colours and layer count stay', () => {
  assert.equal(api.unblur('rgb(0, 0, 0) 1px 0px 1px, rgb(0, 0, 0) 0px 1px 1px, rgb(0, 0, 0) 0px -1px 1px, rgb(0, 0, 0) -1px 0px 1px'),
    'rgb(0, 0, 0) 1px 0px 0px, rgb(0, 0, 0) 0px 1px 0px, rgb(0, 0, 0) 0px -1px 0px, rgb(0, 0, 0) -1px 0px 0px');
  assert.equal(api.unblur('rgba(0, 0, 0, 0.5) 0px 0px 2px, rgb(255, 255, 255) 0px 1px 0px'),
    'rgba(0, 0, 0, 0.5) 0px 0px 0px, rgb(255, 255, 255) 0px 1px 0px');
  // Colour after the lengths (author syntax) and fractional radii.
  assert.equal(api.unblur('1px 1px 2.5px #000'), '1px 1px 0px #000');
});
test('values without blur, none and unparseable values are left alone', () => {
  assert.equal(api.unblur('rgb(0, 0, 0) 1px 0px 0px, rgb(0, 0, 0) 0px 1px 0px'), null);
  assert.equal(api.unblur('rgb(0, 0, 0) 1px 1px'), null);
  assert.equal(api.unblur('none'), null);
  assert.equal(api.unblur(''), null);
  assert.equal(api.unblur('var(--x)'), null);
  assert.equal(api.unblur('rgb(0, 0, 0) 1px 1px 1px 1px'), null);
});
test('top-level comma split keeps function arguments together', () => {
  assert.deepEqual([...api.layers('rgba(1, 2, 3, 0.4) 1px 1px 1px, red 0px 0px 2px')], ['rgba(1, 2, 3, 0.4) 1px 1px 1px', 'red 0px 0px 2px']);
});

// Minimal DOM: enough for the event-driven stage detection.
class Element {
  constructor(parent, text = '', shadow = 'none') {
    this.parentElement = parent; this.children = []; this.isConnected = true; this.textContent = text;
    this.firstChild = text ? {} : null; this.siteShadow = shadow; this.inline = new Map();
    if (parent) parent.children.push(this);
    this.style = {
      getPropertyValue: name => this.inline.get(name)?.value || '',
      getPropertyPriority: name => this.inline.get(name)?.priority || '',
      setProperty: (name, value, priority = '') => this.inline.set(name, { value, priority }),
      removeProperty: name => this.inline.delete(name),
    };
  }
  querySelectorAll() { const out = []; const walk = e => e.children.forEach(c => { out.push(c); walk(c); }); walk(this); return out; }
}
const harness = () => {
  const listeners = {};
  const body = new Element(null);
  const win = {
    Element,
    document: { body, addEventListener: (type, fn) => { listeners[type] = fn; } },
    getComputedStyle: e => ({ textShadow: e.inline.get('text-shadow')?.value || e.siteShadow, animationDuration: e.duration || '8s', transitionDuration: e.duration || '0s, 8s' }),
  };
  api.start(win);
  const fire = (target, type = 'animationstart', propertyName = '', isTrusted = true) => listeners[type]({ target, type, propertyName, isTrusted });
  return { body, fire };
};
const blurred = 'rgb(0, 0, 0) 1px 0px 1px, rgb(0, 0, 0) 0px 1px 1px';
const flat = 'rgb(0, 0, 0) 1px 0px 0px, rgb(0, 0, 0) 0px 1px 0px';

test('many short moving texts in one container become a comment layer, including earlier items', () => {
  const { body, fire } = harness();
  const stage = new Element(new Element(body));
  const items = Array.from({ length: 9 }, (_, i) => new Element(stage, 'comment ' + i, blurred));
  items.slice(0, 7).forEach(item => fire(item));
  assert.equal(items[0].inline.size, 0, 'Seven moving texts are not yet a comment layer');
  fire(items[7]);
  assert.ok(items.slice(0, 8).every(item => item.inline.get('text-shadow')?.value === flat && item.inline.get('text-shadow').priority === 'important'));
  fire(items[8]);
  assert.equal(items[8].inline.get('text-shadow').value, flat, 'Later comments are flattened when they start moving');
});
test('nested text and transform transitions are handled; other transitions are ignored', () => {
  const { body, fire } = harness();
  const stage = new Element(body);
  const movers = Array.from({ length: 8 }, () => { const wrap = new Element(stage); const text = new Element(wrap, 'barrage', blurred); wrap.textContent = 'barrage'; return [wrap, text]; });
  movers.forEach(([wrap]) => fire(wrap, 'transitionrun', 'opacity'));
  assert.equal(movers[0][1].inline.size, 0, 'Opacity fades are not movement');
  movers.forEach(([wrap]) => fire(wrap, 'transitionrun', 'transform'));
  assert.ok(movers.every(([, text]) => text.inline.get('text-shadow')?.value === flat));
});
test('long text, unblurred shadows and untrusted events are untouched', () => {
  const { body, fire } = harness();
  const stage = new Element(body);
  const long = Array.from({ length: 10 }, () => new Element(stage, 'x'.repeat(200), blurred));
  long.forEach(item => fire(item));
  assert.ok(long.every(item => item.inline.size === 0), 'Moving paragraphs are not comments');
  const crisp = Array.from({ length: 10 }, () => new Element(stage, 'ok', flat));
  crisp.forEach(item => fire(item));
  assert.ok(crisp.every(item => item.inline.size === 0), 'Already crisp outlines are not rewritten');
  const { body: page, fire: send } = harness();
  const scripted = Array.from({ length: 10 }, () => new Element(new Element(page), 'c', blurred));
  const shared = scripted[0].parentElement;
  scripted.forEach(item => { item.parentElement = shared; send(item, 'animationstart', '', false); });
  assert.ok(scripted.every(item => item.inline.size === 0), 'Synthetic events from page script are ignored');
});
test('a recycled comment re-reads the site value after its outline changes', () => {
  const { body, fire } = harness();
  const stage = new Element(body);
  const items = Array.from({ length: 8 }, (_, i) => new Element(stage, 'c' + i, blurred));
  items.forEach(item => fire(item));
  const white = 'rgb(255, 255, 255) 0px 0px 2px';
  items[0].siteShadow = white;
  fire(items[0]);
  assert.equal(items[0].inline.get('text-shadow').value, 'rgb(255, 255, 255) 0px 0px 0px');
  items[1].siteShadow = 'none';
  fire(items[1]);
  assert.equal(items[1].inline.size, 0, 'Our override is removed when the site drops the outline');
});
test('short movements such as carousels are not treated as comments', () => {
  const { body, fire } = harness();
  const slider = new Element(body);
  const slides = Array.from({ length: 10 }, (_, i) => { const e = new Element(slider, 'Slide ' + i, blurred); e.duration = '0.6s'; return e; });
  slides.forEach(item => fire(item, 'transitionrun', 'transform'));
  assert.ok(slides.every(item => item.inline.size === 0), 'Soft caption shadows on a carousel stay soft');
  const quick = Array.from({ length: 10 }, (_, i) => { const e = new Element(slider, 'q' + i, blurred); e.duration = '1200ms'; return e; });
  quick.forEach(item => fire(item));
  assert.ok(quick.every(item => item.inline.size === 0), 'Millisecond durations are converted');
});
