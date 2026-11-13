/* Resume only the retained file video, with a real page gesture. No site SDK or URL discovery. */
const Thru3DDirectReturn = (() => {
  'use strict';
  const create = ({valid, available, changed}) => {
    let saved = null, control = null, permitUntil = 0, pending = null, timeout = null;
    const now = () => Date.now();
    const dispose = () => {
      if (!control) return;
      control.resize?.disconnect(); control.host.remove(); control = null;
      removeEventListener('scroll', sync, true); removeEventListener('resize', sync);
    };
    const cancelTimeout = () => { if (timeout !== null) clearTimeout(timeout); timeout = null; };
    const clear = () => { saved = null; permitUntil = 0; pending = null; cancelTimeout(); dispose(); };
    const current = () => {
      if (saved && !valid(saved)) clear();
      return saved;
    };
    const holds = video => current()?.video === video && !pending && now() >= permitUntil;
    const resume = event => {
      const owner = current();
      if (!event.isTrusted || !owner || !available() || pending && !pending.retryable) return;
      event.preventDefault(); event.stopPropagation();
      event.stopImmediatePropagation?.();
      const attempt = {};
      cancelTimeout();
      pending = attempt; permitUntil = 0;
      sync();
      // Calling play synchronously retains browser user activation, including in an iframe.
      const complete = () => {
        if (current() !== owner || pending !== attempt) return;
        cancelTimeout(); pending = null;
        if (!owner.video.paused) clear();
        else { permitUntil = 0; sync(); }
        changed();
      };
      // A seek may still be fetching bytes after 15 seconds. Keep the user's
      // play request alive, but expose a retry; never pause valid buffering.
      timeout = setTimeout(() => {
        if (current() !== owner || pending !== attempt) return;
        timeout = null; attempt.retryable = true; sync();
      }, 15000);
      try { Promise.resolve(owner.video.play()).then(complete, complete); }
      catch (_) { complete(); }
    };
    function sync() {
      const owner = current();
      if (!owner || !available()) { dispose(); return; }
      if (!pending && !owner.video.paused && !holds(owner.video)) { clear(); return; }
      if (!document.createElement || !document.documentElement) return;
      if (control && !control.host.isConnected) dispose();
      if (!control) {
        const host = document.createElement('span'), root = host.attachShadow({mode:'closed'});
        host.dataset.thru3dResumeWeb = '';
        host.style.cssText = 'all:initial;position:fixed;z-index:2147483001;pointer-events:none;line-height:normal;';
        const style = document.createElement('style');
        style.textContent = 'button{all:initial;box-sizing:border-box;display:flex;align-items:center;justify-content:center;width:72px;height:72px;border:2px solid #b2e5ff;border-radius:50%;background:#122435ed;color:#fff;font:32px/1 system-ui,sans-serif;cursor:pointer;pointer-events:auto;box-shadow:0 2px 9px #0008}button:hover,button:focus-visible{background:#285273;outline:3px solid #b2e5ff}button:disabled{opacity:.6}';
        const button = document.createElement('button'); button.type = 'button'; button.textContent = '▶';
        const lang = document.documentElement.lang || navigator.language || '';
        const label = /^zh/i.test(lang) ? '继续网页播放' : /^ja/i.test(lang) ? 'ウェブで再生' : 'Resume web video';
        button.setAttribute('aria-label', label); button.title = label;
        // The website must not interpret this button as its own play/pause toggle.
        button.addEventListener('pointerdown', event => { if (event.isTrusted) event.stopPropagation(); });
        button.addEventListener('click', resume);
        root.append(style, button);
        const full = document.fullscreenElement;
        const parent = full && full !== owner.video && full.contains?.(owner.video) ? full : document.documentElement;
        parent.append(host);
        control = {host, button};
        if (typeof ResizeObserver !== 'undefined') {
          control.resize = new ResizeObserver(sync); control.resize.observe(owner.video);
        }
        addEventListener('scroll', sync, {passive:true, capture:true});
        addEventListener('resize', sync, {passive:true});
      }
      // Canvas/VR players may hide <video>. Use its nearest visible container.
      let element = owner.video, rect = null;
      for (let n = 0; element && n < 5; n++, element = element.parentElement) {
        const box = element.getBoundingClientRect?.();
        if (box?.width >= 96 && box.height >= 72) { rect = box; break; }
      }
      let x = innerWidth - 56, y = innerHeight - 56;
      let visible = innerWidth >= 80 && innerHeight >= 80;
      if (rect) {
        const left = Math.max(0, rect.left), right = Math.min(innerWidth, rect.right);
        const top = Math.max(0, rect.top), bottom = Math.min(innerHeight, rect.bottom);
        visible &&= right - left >= 80 && bottom - top >= 80;
        x = (left + right) / 2; y = (top + bottom) / 2;
      }
      control.host.style.display = visible ? '' : 'none';
      control.host.style.left = (x - 36) + 'px'; control.host.style.top = (y - 36) + 'px';
      control.button.disabled = !!pending && !pending.retryable;
      control.button.textContent = pending && !pending.retryable ? '…' : '▶';
      control.button.setAttribute('aria-busy', pending ? 'true' : 'false');
    }
    const gesture = event => {
      const owner = current();
      if (!event.isTrusted || !owner || !available() || pending) return;
      const path = event.composedPath?.() || [];
      if (control && path.includes(control.host)) return;
      const rect = owner.video.getBoundingClientRect?.();
      const inside = rect && Number.isFinite(event.clientX) && Number.isFinite(event.clientY) &&
        event.clientX >= rect.left && event.clientX <= rect.right && event.clientY >= rect.top && event.clientY <= rect.bottom;
      // Existing video controls can still initiate playback. Unrelated page clicks
      // must not release a delayed autoplay attempt.
      if (path.includes(owner.video) || inside) permitUntil = now() + 2000;
    };
    const actionEvent = event => event.isTrusted && control && control.host.isConnected &&
      control.host.style.display !== 'none' && (event.composedPath?.() || []).includes(control.host);
    // Match the existing verified webpage actions: reserve only our shadow
    // control, before a site's document-wide touch handler cancels its click.
    for (const name of ['pointerdown','mousedown','touchstart','pointerup','mouseup','touchend'])
      addEventListener(name,event=>{if(actionEvent(event))event.stopImmediatePropagation();},true);
    addEventListener('click',event=>{if(actionEvent(event))resume(event);},true);
    return {holds, sync, gesture, clear, restore(owner) { clear(); saved = owner; }};
  };
  return {create};
})();
