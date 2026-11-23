const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

const context = vm.createContext({URL});
vm.runInContext(fs.readFileSync(__dirname + '/niconico-watch-entry.js', 'utf8') +
  ';globalThis.watch = Thru3DNiconicoWatchPage;globalThis.card = Thru3DNiconicoWatchCard;', context);
const root = 'https://www.nicovideo.jp';

function documentAt(path, items) {
  const document = {
    location: new URL(root + path),
    defaultView: {innerWidth: 1000, innerHeight: 750},
    querySelectorAll: () => anchors,
    elementFromPoint(x, y) {
      return anchors.find(a => !a.covered && x >= a.bounds.left && x <= a.bounds.right &&
        y >= a.bounds.top && y <= a.bounds.bottom);
    },
  };
  const anchors = items.map(({href, left = 100, top = 100, covered = false, nested = false}) => {
    const bounds = {left, top, right: left + 190, bottom: top + 95};
    const thumb = {getBoundingClientRect: () => bounds};
    return {
      href, bounds, covered,
      getBoundingClientRect: () => nested ? {left, top, right: left, bottom: top} : bounds,
      querySelectorAll: () => nested ? [thumb] : [],
      contains(hit) { return hit === this; },
    };
  });
  return document;
}

test('uses only exact official watch paths and omits source query strings', () => {
  assert.equal(context.watch(root + '/watch/so7?ref=watch').page, root + '/watch/so7');
  for (const bad of ['https://other.test/watch/sm7', root + '/watch/%73m7', root + '/series/7',
    'https://user@www.nicovideo.jp/watch/sm7', root + '/watch/sm7/extra']) {
    assert.equal(context.watch(bad), null);
  }
});

test('home selection uses a visible nested thumbnail and skips occluded and foreign cards', () => {
  const document = documentAt('/', [
    {href: 'https://other.test/watch/sm7'},
    {href: root + '/watch/sm8', covered: true, left: 310},
    {href: root + '/watch/sm9', nested: true, left: 520},
  ]);
  assert.equal(context.card(document).id, 'sm9');
  assert.equal(context.card(document).x, 615);
});

test('watch selection excludes the current clip and uses a visible sidebar recommendation', () => {
  const document = documentAt('/watch/sm9', [
    {href: root + '/watch/sm9'},
    {href: root + '/watch/sm10', left: 310},
    {href: root + '/watch/so11', left: 600},
  ]);
  assert.equal(context.card(document, 'sm9').id, 'so11');
  assert.equal(context.card(document, 'sm8'), null);
  assert.equal(context.card(document), null);
});
