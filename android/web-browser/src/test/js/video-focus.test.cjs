const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const context = vm.createContext({});
vm.runInContext(fs.readFileSync(path.join(__dirname, '../../main/assets/web-browser/video-focus.js'), 'utf8') + ';globalThis.focus=Thru3DVideoFocus;', context);
const { locate, picture } = context.focus;
const video = (rect, options = {}) => ({ isConnected: true, videoWidth: 1920, videoHeight: 1080, paused: false, ended: false, readyState: 4,
  getBoundingClientRect: () => ({ x: rect[0], y: rect[1], width: rect[2], height: rect[3] }), ...options });
const page = (options = {}) => {
  const win = { innerWidth: 1440, innerHeight: 900, mozInnerScreenX: 12, mozInnerScreenY: 34,
    getComputedStyle: element => ({ objectFit: element.fit || 'contain' }), ...options };
  if (!('top' in options)) win.top = win;
  return win;
};
const plain = value => JSON.parse(JSON.stringify(value));

test('object-fit keeps only the picture inside the player box', () => {
  const box = { x: 0, y: 0, width: 1000, height: 1000 };
  assert.deepEqual(plain(picture(box, 1920, 1080, 'contain')), { x: 0, y: 218.75, width: 1000, height: 562.5 });
  assert.deepEqual(plain(picture(box, 1920, 1080, 'cover')), box);
  assert.deepEqual(plain(picture(box, 1920, 1080, 'fill')), box);
  assert.deepEqual(plain(picture(box, 400, 300, 'scale-down')), { x: 300, y: 350, width: 400, height: 300 });
  assert.deepEqual(plain(picture(box, 4000, 3000, 'none')), box);
  assert.deepEqual(plain(picture(box, 0, 0, 'contain')), box, 'no metadata yet: the whole element');
});

test('reports visible pictures in the frame viewport', () => {
  const result = plain(locate(page(), [
    video([100, 100, 1280, 1000]),
    video([1300, 800, 400, 225], { paused: true }),
    video([0, 1000, 640, 360]),
    video([0, 0, 640, 360], { checkVisibility: () => false }),
    video([0, 0, 640, 360], { isConnected: false }),
    video([0, 0, 640, 360], { getBoundingClientRect() { throw new Error('dead'); } })
  ]));
  assert.equal(result.top, true);
  assert.deepEqual(result.screen, [12, 34]);
  assert.deepEqual(result.view, [0, 0, 1440, 900]);
  assert.deepEqual(result.videos, [
    { rect: [100, 240, 1280, 660], playing: true },
    { rect: [1300, 800, 140, 100], playing: false }
  ]);
});

test('uses the visual viewport and marks iframes', () => {
  const frame = page({ visualViewport: { offsetLeft: 0, offsetTop: 300, width: 720, height: 450 }, top: {} });
  const result = plain(locate(frame, [video([0, 200, 640, 360], { readyState: 2 })]));
  assert.equal(result.top, false);
  assert.deepEqual(result.view, [0, 300, 720, 450]);
  assert.deepEqual(result.videos, [{ rect: [0, 300, 640, 260], playing: false }]);
});

test('a cross-origin top and missing screen origin do not throw', () => {
  const frame = page({ mozInnerScreenX: undefined, mozInnerScreenY: undefined });
  Object.defineProperty(frame, 'top', { get() { throw new Error('SecurityError'); } });
  const result = plain(locate(frame, []));
  assert.equal(result.top, false);
  assert.deepEqual(result.screen, [0, 0]);
  assert.equal(locate(page(), Array.from({ length: 40 }, () => video([0, 0, 640, 360]))).videos.length, 16);
});

test('players without a picture are fallbacks only when nothing is shown', () => {
  const iframe = (rect, attrs = {}) => ({ getBoundingClientRect: () => ({ x: rect[0], y: rect[1], width: rect[2], height: rect[3] }), ...attrs });
  const selected = [];
  const frames = [iframe([100, 500, 560, 315]), iframe([900, 0, 300, 250], { checkVisibility: () => false })];
  const document = { querySelectorAll(selector) { selected.push(selector); return frames; } };
  const hiddenVideo = video([200, 100, 960, 540], { checkVisibility: () => false, videoWidth: 1080, videoHeight: 1080 });
  const empty = plain(locate(page({ document, location: { pathname: '/watch', hostname: 'site.test' } }), [hiddenVideo]));
  assert.deepEqual(empty.videos, []);
  assert.deepEqual(empty.fallback, [{ rect: [410, 100, 540, 540], kind: 'video' }, { rect: [100, 500, 560, 315], kind: 'embed' }]);
  assert.match(selected[0], /allowfullscreen/);
  assert.match(selected[0], /embed/);
  const shown = plain(locate(page({ document }), [hiddenVideo, video([0, 0, 640, 360])]));
  assert.deepEqual(shown.fallback, [], 'a visible video leaves no fallbacks');
  const player = plain(locate(page({ top: {}, location: { pathname: '/embed/abc', hostname: 'www.youtube.com' },
    document: { querySelectorAll: () => [] }, innerWidth: 560, innerHeight: 315 }), []));
  assert.deepEqual(player.fallback, [{ rect: [0, 0, 560, 315], kind: 'player' }], 'an embedded player frame reports itself');
  const article = plain(locate(page({ top: {}, location: { pathname: '/ads/slot', hostname: 'ads.test' },
    document: { querySelectorAll: () => [] } }), []));
  assert.deepEqual(article.fallback, [], 'other frames do not');
});
