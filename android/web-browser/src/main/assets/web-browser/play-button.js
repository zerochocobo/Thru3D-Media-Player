/* One accessible, ray-friendly webpage action shared by the verified site adapters. */
const Thru3DPlayButton = (() => {
  'use strict';
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
    button.addEventListener('pointerdown',e=>{if(e.isTrusted)e.stopPropagation();});
    button.addEventListener('click',e=>{
      if (!e.isTrusted || button.disabled || !host.isConnected || !visible(box)) return;
      e.preventDefault();e.stopPropagation();clicked();
    });
    box.append(host);
    return {host,button,label,
      enabled(value,reason='') {button.disabled=!value;button.title=reason || label;},
      dispose() {host.remove();if(position==='static' && box.style.position==='relative')box.style.position='';}
    };
  };
  return {create,visible};
})();
