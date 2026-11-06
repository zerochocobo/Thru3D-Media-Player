/* Isolated content-script adapter. A card click selects one DOM player, never a page-wide guess. */
const Thru3DWeibo = (() => {
  'use strict';
  const documentPage = value => {
    try { const u = new URL(value); return u.protocol === 'https:' && !u.username && !u.password &&
      !u.port && ['weibo.com', 'www.weibo.com'].includes(u.hostname); } catch (_) { return false; }
  };
  const page = value => {
    try {
      if (!documentPage(value)) return null;
      const u = new URL(value), fid = /^\/tv\/show\/([0-9]+:(?:[0-9a-f]{32}|[0-9]{16,}))\/?$/.exec(u.pathname)?.[1];
      if (fid) return {id:fid, page:'https://weibo.com/tv/show/' + fid};
      const post = /^\/([0-9]+)\/([A-Za-z0-9]{5,32})\/?$/.exec(u.pathname);
      return post ? {id:post[2], page:'https://weibo.com/' + post[1] + '/' + post[2]} : null;
    } catch (_) { return null; }
  };
  const address = value => {
    try { const u = new URL(value); return value.length <= 16384 && u.protocol === 'https:' &&
      !u.username && !u.password && !u.hash ? u.href : null; } catch (_) { return null; }
  };
  const identity = container => {
    const card = container.closest?.('article');
    if (!card) return null; // Login animation and the detached mini-player are not feed cards.
    const links = root => [...root.querySelectorAll('a[href]')].map(a=>page(a.href)).filter(Boolean);
    const unique = list => [...new Map(list.map(p=>[p.page,p])).values()];
    // A local video permalink disambiguates reposts and multi-video cards when present.
    const local = unique(links(container).filter(p=>p.id.includes(':')));
    if (local.length === 1) return local[0];
    if (local.length > 1 || card.querySelectorAll('video').length > 1) return null;
    const all = unique(links(card)), videos = all.filter(p=>p.id.includes(':'));
    if (videos.length === 1) return videos[0];
    if (videos.length > 1) return null;
    return all.length === 1 ? all[0] : null;
  };
  const container = video => video.closest?.('[page-info]') || video.closest?.('.video-js')?.parentElement;
  const binding = (video, requests) => {
    const box = container(video), target = box && identity(box), source = address(video.currentSrc || '');
    if (!target || !source || video.readyState < 1 || !(video.videoWidth > 0 && video.videoHeight > 0) ||
        !Number.isFinite(video.duration) || video.duration <= 0 || video.duration > 86400) return null;
    const matched = requests.filter(r=>r.kind === 'file' && (r.url === source || r.original_url === source));
    if (new Set(matched.map(r=>r.url)).size !== 1) return null;
    return {...target, source};
  };
  const visible = element => {
    const r = element.getBoundingClientRect();
    return r.width > 0 && r.height > 0 && r.bottom > 0 && r.right > 0 && r.top < innerHeight && r.left < innerWidth;
  };
  const controls = (doc, selected) => {
    const entries = new Map();
    const label = /^zh/i.test(doc.documentElement.lang || navigator.language || '') ? '播放 Beta' : 'Play Beta';
    const sync = enabled => {
      for (const [box, item] of entries) if (!enabled || !box.isConnected || !identity(box)) {
        item.dispose(); entries.delete(box);
      }
      if (!enabled) return;
      // Keep the UI bounded to visible cards; never load off-screen media to discover streams.
      const boxes = [...doc.querySelectorAll('article [page-info], article .video-js')]
        .map(e=>e.matches('.video-js') ? e.parentElement : e);
      for (const box of new Set(boxes)) {
        let item = entries.get(box);
        if (!visible(box)) { if (item) item.host.hidden = true; continue; }
        if (!identity(box)) continue;
        if (!item) {
          if (entries.size >= 32) {
            const old = [...entries].find(([node])=>!visible(node));
            if (!old) continue;
            old[1].dispose(); entries.delete(old[0]);
          }
          item = Thru3DPlayButton.create(doc,box,'weibo',()=>{
            const target = identity(box), list = box.querySelectorAll('video');
            if (!target || list.length !== 1) return;
            const video = list[0];
            selected(video, target, true);
            // Preserve the real user activation. A rejected play stays in the original card.
            if (video.readyState < 2) { try { Promise.resolve(video.play()).catch(()=>{}); } catch (_) {} }
          });
          item.host.dataset.thru3dWeibo = 'beta'; entries.set(box,item);
        }
        item.host.hidden = false;
        item.host.dataset.thru3dWeiboPage = identity(box).page;
        const players = box.querySelectorAll('video'), player = players[0];
        const unsupported = player && (!!player.mediaKeys || /^(?:blob:)|\.(?:m3u8|mpd)(?:[?#]|$)/i.test(player.currentSrc || ''));
        item.button.disabled = players.length !== 1 || !!unsupported;
        item.button.title = unsupported ? (label === '播放 Beta' ? '此视频暂不支持' : 'Video unavailable') : item.button.disabled ? (label === '播放 Beta' ? '先在网页播放视频' : 'Play on the page first') : label;
      }
    };
    doc.addEventListener('pointerdown', e=>{
      if (!e.isTrusted) return;
      const box = e.target.closest?.('[page-info], .video-js');
      const list = box?.querySelectorAll('video'), target = box && identity(box);
      if (target && list?.length === 1) selected(list[0],target,false);
    }, true);
    return {sync};
  };
  return {documentPage, page, address, identity, container, binding, visible, controls};
})();
