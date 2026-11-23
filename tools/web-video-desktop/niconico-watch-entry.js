/* Test-only helpers for ordinary Niconico homepage and recommendation touches. */
const Thru3DNiconicoWatchPage = value => {
  try {
    const url = new URL(value);
    if (url.origin !== 'https://www.nicovideo.jp' || url.username || url.password) return null;
    const id = /^\/watch\/((?:sm|so|nm)[0-9]{1,20})\/?$/.exec(url.pathname)?.[1];
    return id ? {id, page: url.origin + url.pathname} : null;
  } catch (_) {
    return null;
  }
};

const Thru3DNiconicoWatchCard = (document, current = '') => {
  const view = document.defaultView;
  if (document.location.origin !== 'https://www.nicovideo.jp' ||
      (current ? Thru3DNiconicoWatchPage(document.location.href)?.id !== current : document.location.pathname !== '/')) return null;

  const cards = new Map();
  for (const anchor of document.querySelectorAll('a[href]')) {
    const page = Thru3DNiconicoWatchPage(anchor.href);
    if (!page || page.id === current || cards.has(page.id)) continue;
    for (const node of [anchor, ...anchor.querySelectorAll('img,picture,span')]) {
      const rect = node.getBoundingClientRect();
      const left = Math.max(0, rect.left), top = Math.max(0, rect.top);
      const right = Math.min(view.innerWidth, rect.right), bottom = Math.min(view.innerHeight, rect.bottom);
      if (right - left < 42 || bottom - top < 16) continue;
      const x = Math.round((left + right) / 2), y = Math.round((top + bottom) / 2);
      if (!anchor.contains(document.elementFromPoint(x, y))) continue;
      cards.set(page.id, {id: page.id, x, y});
      break;
    }
  }
  const visible = [...cards.values()];
  // Watch recommendations are usually to the right of the main player.
  return (current ? visible.find(card => card.x >= view.innerWidth * .55) : visible[0]) || visible[0] || null;
};
