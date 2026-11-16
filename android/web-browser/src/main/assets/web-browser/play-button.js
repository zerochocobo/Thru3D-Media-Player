/* One accessible, ray-friendly webpage action shared by the verified site adapters. */
const Thru3DPlayButton = (() => {
  'use strict';
  let presentationVisible = true;
  const controls = new Set();
  const allowed = doc => presentationVisible && !doc.fullscreenElement;
  const setPresentationVisible = value => {
    presentationVisible = value === true;
    for (const sync of controls) sync();
  };
  const visible = element => {
    const r = element.getBoundingClientRect();
    return r.width > 0 && r.height > 0 && r.bottom > 0 && r.right > 0 && r.top < innerHeight && r.left < innerWidth;
  };
  const create = (doc, box, site, clicked) => {
    const label = /^zh/i.test(doc.documentElement.lang || navigator.language || '') ? '播放 Beta' : 'Play Beta';
    const host = doc.createElement('span'), root = host.attachShadow({mode:'closed'});
    host.dataset.thru3dPlayBeta = site;
    host.style.cssText = 'position:absolute;top:12px;right:12px;z-index:2147483000;pointer-events:none;line-height:normal;';
    const style = doc.createElement('style');
    style.textContent = 'button{all:initial;box-sizing:border-box;display:flex;align-items:center;justify-content:center;gap:10px;min-height:68px;min-width:180px;padding:14px 22px;border:2px solid #81c9ed;border-radius:36px;background:#122435f5;color:#fff;font:600 22px/1.3 system-ui,sans-serif;cursor:pointer;pointer-events:auto;box-shadow:0 2px 7px #0006}button:hover,button:focus-visible{background:#285273;outline:3px solid #b2e5ff}button:active{background:#36739a}button:disabled{opacity:.55;cursor:default}';
    const button = doc.createElement('button'); button.type = 'button'; button.textContent = '▶ ' + label;
    button.setAttribute('aria-label',label);
    root.append(style,button);
    const position = getComputedStyle(box).position;
    if (position === 'static') box.style.position = 'relative';
    // Site adapters own host.hidden/readiness. A separate display gate survives their
    // updates and newly created buttons without clearing any capture/selection state.
    const sync = () => {
      if (allowed(doc)) host.style.removeProperty('display');
      else host.style.setProperty('display','none','important');
    };
    const interactive = () => allowed(doc) && !host.hidden && !button.disabled && host.isConnected && visible(box);
    controls.add(sync); doc.addEventListener('fullscreenchange',sync,true); sync();
    button.addEventListener('pointerdown',e=>{if(e.isTrusted && interactive())e.stopPropagation();});
    button.addEventListener('click',e=>{
      if (!e.isTrusted || !interactive()) return;
      e.preventDefault();e.stopPropagation();clicked();
    });
    box.append(host);
    return {host,button,label,interactive,
      enabled(value,reason='') {button.disabled=!value;button.title=reason || label;},
      dispose() {controls.delete(sync);doc.removeEventListener('fullscreenchange',sync,true);host.remove();if(position==='static' && box.style.position==='relative')box.style.position='';}
    };
  };
  return {create,visible,setPresentationVisible};
})();
