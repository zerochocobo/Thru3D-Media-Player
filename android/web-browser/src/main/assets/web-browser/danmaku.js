/* Comment overlays (danmaku) drawn as moving DOM text are a WebRender hot spot: every
 * blurred text-shadow layer is a blur pass per item per frame. Quest 3, 160 items with
 * Bilibili's 4 x 1px blurred outline: Renderer thread 77%, 62 presents/s; the same
 * outline with zero blur: 20%, 72/s, visually indistinguishable at headset raster size.
 * Site-agnostic: a container in which many short texts are moving at once is a comment
 * layer, whatever the site or class names. Only those texts' shadow blur radii become 0;
 * offsets, colours, layer count, density, speed and site settings stay untouched.
 * Detection uses the CSS animation/transition events the page already raises; overlays
 * moved purely by script each frame are not detected. Each rewrite costs the page one
 * extra restyle (main thread 27% -> 41% at 160 items, batching per frame did not help);
 * the WebRender saving is far larger. */
const Thru3DDanmaku = (() => {
  "use strict";
  const STAGE_ITEMS = 8, WINDOW_MS = 3000, MAX_TEXT = 64, MAX_NODES = 12, ANCESTORS = 3;
  // Comments cross the screen in seconds (Bilibili ~2-8 s, Tencent 8 s, iQiyi 17.5 s);
  // carousels and hover effects that move many captions at once finish well under that.
  const MIN_TRAVEL_S = 1.5;

  // Split on top-level commas only: colours such as rgba(0, 0, 0, 0.5) contain commas.
  const layers = value => {
    const out = []; let depth = 0, start = 0;
    for (let i = 0; i < value.length; i++) {
      const c = value[i];
      if (c === '(') depth++;
      else if (c === ')') depth = Math.max(0, depth - 1);
      else if (c === ',' && depth === 0) { out.push(value.slice(start, i)); start = i + 1; }
    }
    out.push(value.slice(start));
    return out.map(item => item.trim()).filter(Boolean);
  };
  const tokens = layer => {
    const out = []; let depth = 0, current = '';
    for (const c of layer) {
      if (c === '(') depth++;
      if (c === ')') depth = Math.max(0, depth - 1);
      if (/\s/.test(c) && depth === 0) { if (current) out.push(current); current = ''; } else current += c;
    }
    if (current) out.push(current);
    return out;
  };
  const LENGTH = /^-?(?:\d+\.?\d*|\.\d+)(?:px|em|rem|pt)?$/;
  /** Returns the shadow with every blur radius set to 0, or null when nothing is blurred
   * or the value is not a plain computed shadow list. */
  const unblur = value => {
    if (typeof value !== 'string' || !value || value === 'none') return null;
    let changed = false;
    const result = [];
    for (const layer of layers(value)) {
      const parts = tokens(layer);
      const lengths = parts.map((part, index) => LENGTH.test(part) ? index : -1).filter(index => index >= 0);
      if (lengths.length < 2 || lengths.length > 3) return null;
      if (lengths.length === 3 && parseFloat(parts[lengths[2]]) !== 0) { parts[lengths[2]] = '0px'; changed = true; }
      result.push(parts.join(' '));
    }
    return changed ? result.join(', ') : null;
  };

  const start = (win) => {
    const doc = win.document;
    const recent = new WeakMap();        // ancestor -> Map(moving element -> last seen ms)
    const stages = new WeakSet();
    const applied = new WeakMap();       // node -> {value, inline} written by us
    const cache = new Map();
    const shortText = element => {
      const text = element.textContent || '';
      return text.trim().length > 0 && text.length <= MAX_TEXT;
    };
    const ancestors = element => {
      const out = [];
      for (let node = element.parentElement; node && out.length < ANCESTORS && node !== doc.body; node = node.parentElement) out.push(node);
      return out;
    };
    const flatten = element => {
      for (const node of [element, ...element.querySelectorAll('*')].slice(0, MAX_NODES)) {
        if (!node.firstChild && node !== element) continue;
        const previous = applied.get(node);
        // Recycled items can change colour/outline: re-read the site's own value.
        if (previous && node.style.getPropertyValue('text-shadow') === previous.value) {
          if (previous.inline) node.style.setProperty('text-shadow', previous.inline.value, previous.inline.priority);
          else node.style.removeProperty('text-shadow');
        }
        const shadow = win.getComputedStyle(node).textShadow;
        let flat = cache.get(shadow);
        if (flat === undefined) { flat = unblur(shadow); if (cache.size < 256) cache.set(shadow, flat); }
        if (!flat) { applied.delete(node); continue; }
        const inline = node.style.getPropertyValue('text-shadow');
        applied.set(node, { value: flat, inline: inline ? { value: inline, priority: node.style.getPropertyPriority('text-shadow') } : null });
        node.style.setProperty('text-shadow', flat, 'important');
      }
    };
    const seconds = value => Math.max(0, ...String(value || '0s').split(',').map(item => {
      const text = item.trim(); const number = parseFloat(text) || 0;
      return text.endsWith('ms') ? number / 1000 : number;
    }));
    const travel = (element, event) => {
      const style = win.getComputedStyle(element);
      return event.type === 'animationstart' ? seconds(style.animationDuration) : seconds(style.transitionDuration);
    };
    const moving = event => {
      const element = event.target;
      if (!(element instanceof win.Element) || !event.isTrusted) return;
      if (event.type === 'transitionrun' && !/transform|left|right|translate/.test(event.propertyName || '')) return;
      if (!shortText(element) || element.querySelectorAll('*').length > MAX_NODES) return;
      const parents = ancestors(element);
      if (parents.some(ancestor => stages.has(ancestor))) { flatten(element); return; }
      if (travel(element, event) < MIN_TRAVEL_S) return;
      const now = Date.now();
      let staged = false;
      for (const ancestor of parents) {
        let seen = recent.get(ancestor);
        if (!seen) recent.set(ancestor, seen = new Map());
        seen.set(element, now);
        for (const [item, at] of seen) if (now - at > WINDOW_MS || !item.isConnected) seen.delete(item);
        if (seen.size >= STAGE_ITEMS) {
          stages.add(ancestor); staged = true;
          for (const item of seen.keys()) if (item !== element) flatten(item);
          recent.delete(ancestor);
          break;
        }
      }
      if (staged) flatten(element);
    };
    for (const type of ['animationstart', 'transitionrun']) doc.addEventListener(type, moving, true);
  };
  return { unblur, layers, start };
})();
if (typeof window !== 'undefined' && typeof document !== 'undefined') Thru3DDanmaku.start(window);
