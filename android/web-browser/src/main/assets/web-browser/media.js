/* Extension isolated world. No page-provided code is evaluated by the native bridge. */
(() => {
  "use strict";
  let port;
  const videos = new Map();
  const encrypted = new WeakSet();
  let nextId = 0;
  let closed = false;
  let scheduled = false;
  let suspended = false;
  let handoff = null;
  let pauseLease = null, lastPauseToken = 0;
  const resuming = new WeakMap();
  let iqiyiReturnPause = null;
  let tiktokReturnPause = null;
  const keepTikTokReturnPaused=video=>{
    const saved=tiktokReturnPause;if(!saved)return false;
    const age=Date.now()-saved.at;
    if(age<0||age>30000||saved.page!==location.href||!saved.video.isConnected||saved.video.currentSrc!==saved.source||mediaEpoch.get(saved.video)?.id!==saved.epoch||Thru3DTikTok.declaration(saved.video,location.href)?.id!==saved.owner){tiktokReturnPause=null;return false;}
    return video===saved.video;
  };
  let instagramReturnPause = null, instagramRestore = null;
  const keepInstagramReturnPaused=video=>{
    const saved=instagramReturnPause;if(!saved)return false;
    const age=Date.now()-saved.at;
    if(age<0||age>30000||saved.page!==location.href||!saved.video.isConnected||saved.video.currentSrc!==saved.source||mediaEpoch.get(saved.video)?.id!==saved.epoch||Thru3DInstagram.declaration(saved.video,location.href)?.id!==saved.owner){instagramReturnPause=null;return false;}
    return video===saved.video;
  };
  let tedReturnPause = null;
  const keepTedReturnPaused=video=>{
    const saved=tedReturnPause;if(!saved)return false;
    const age=Date.now()-saved.at;
    if(age<0||age>30000||saved.page!==location.href||!saved.video.isConnected||saved.video.currentSrc!==saved.source||mediaEpoch.get(saved.video)?.id!==saved.epoch||Thru3DTed.declaration(saved.video,location.href)?.id!==saved.owner){tedReturnPause=null;return false;}
    return video===saved.video;
  };
  let redbullReturnPause = null;
  const keepRedBullReturnPaused=video=>{
    const saved=redbullReturnPause;if(!saved)return false;
    const age=Date.now()-saved.at;
    if(age<0||age>30000||saved.page!==location.href||!saved.video.isConnected||saved.video.currentSrc!==saved.source||mediaEpoch.get(saved.video)?.id!==saved.epoch||Thru3DRedBull.owner(saved.video,document)?.current.id!==saved.owner){redbullReturnPause=null;return false;}
    return video===saved.video;
  };
  let streamableReturnPause = null;
  const keepStreamableReturnPaused=video=>{
    const saved=streamableReturnPause;if(!saved)return false;
    const age=Date.now()-saved.at;
    if(age<0||age>30000||saved.page!==location.href||!saved.video.isConnected||saved.video.currentSrc!==saved.source||mediaEpoch.get(saved.video)?.id!==saved.epoch||Thru3DStreamable.declaration(saved.video,document)?.id!==saved.owner){streamableReturnPause=null;return false;}
    return video===saved.video;
  };
  let redditReturnPause = null;
  const keepRedditReturnPaused=video=>{
    const saved=redditReturnPause;if(!saved)return false;
    const age=Date.now()-saved.at;
    if(age<0||age>30000||saved.page!==location.href||!saved.video.isConnected||saved.video.currentSrc!==saved.source||mediaEpoch.get(saved.video)?.id!==saved.epoch||Thru3DReddit.declaration(saved.video,document)?.id!==saved.owner){redditReturnPause=null;return false;}
    return video===saved.video;
  };
  let naverReturnPause = null;
  const keepNaverReturnPaused=video=>{
    const saved=naverReturnPause;if(!saved)return false;
    const age=Date.now()-saved.at;
    if(age<0||age>30000||saved.page!==location.href||!saved.video.isConnected||saved.video.currentSrc!==saved.source||mediaEpoch.get(saved.video)?.id!==saved.epoch){naverReturnPause=null;return false;}
    return video===saved.video;
  };
  let archiveReturnPause = null;
  const keepArchiveReturnPaused=video=>{
    const saved=archiveReturnPause;if(!saved)return false;
    const age=Date.now()-saved.at;
    if(age<0||age>30000||saved.page!==location.href||!saved.video.isConnected||saved.video.currentSrc!==saved.source||mediaEpoch.get(saved.video)?.id!==saved.epoch||Thru3DArchive.declaration(saved.video,document)?.id!==saved.owner){archiveReturnPause=null;return false;}
    return video===saved.video;
  };
  let odyseeReturnPause = null;
  const keepOdyseeReturnPaused=video=>{
    const saved=odyseeReturnPause;if(!saved)return false;
    const age=Date.now()-saved.at;
    if(age<0||age>30000||saved.page!==location.href||!saved.video.isConnected||saved.video.currentSrc!==saved.source||mediaEpoch.get(saved.video)?.id!==saved.epoch||Thru3DOdysee.declaration(saved.video,document)?.id!==saved.owner){odyseeReturnPause=null;return false;}
    return video===saved.video;
  };
  let dailymotionReturnPause = null;
  const keepDailymotionReturnPaused=video=>{
    const saved=dailymotionReturnPause;if(!saved)return false;
    const age=Date.now()-saved.at;
    if(age<0||age>30000||saved.page!==location.href||!saved.video.isConnected||saved.video.currentSrc!==saved.source||mediaEpoch.get(saved.video)?.id!==saved.epoch||Thru3DDailymotion.declaration(saved.video,document)?.id!==saved.owner){dailymotionReturnPause=null;return false;}
    return video===saved.video;
  };
  let niconicoReturnPause = null;
  const keepNiconicoReturnPaused=video=>{
    const saved=niconicoReturnPause;if(!saved)return false;
    const age=Date.now()-saved.at;
    if(age<0||age>30000||saved.page!==location.href||!saved.video.isConnected||saved.video.currentSrc!==saved.source||mediaEpoch.get(saved.video)?.id!==saved.epoch||Thru3DNiconico.page(location.href)!==saved.owner){niconicoReturnPause=null;return false;}
    return video===saved.video;
  };
  let douyinReturnPause = null;
  const keepDouyinReturnPaused = video => {
    const saved=douyinReturnPause;if(!saved)return false;
    const age=Date.now()-saved.at,owner=typeof Thru3DDouyinCurrent!=='undefined'&&Thru3DDouyinCurrent.owner(saved.video,location.href);
    if(age<0||age>30000||saved.page!==location.href||!saved.video.isConnected||saved.video.currentSrc!==saved.source||mediaEpoch.get(saved.video)?.id!==saved.epoch||owner?.id!==saved.owner){douyinReturnPause=null;return false;}
    return video===saved.video;
  };
  const keepIqiyiReturnPaused = video => {
    const saved=iqiyiReturnPause;
    if(!saved)return false;
    const age=Date.now()-saved.at;
    if(age<0||age>30000||saved.page!==location.href||!saved.video.isConnected||saved.video.currentSrc!==saved.source||mediaEpoch.get(saved.video)?.id!==saved.epoch){iqiyiReturnPause=null;return false;}
    return video===saved.video;
  };
  // The site's seek completion can call play again after we restored a paused
  // position. Preserve that return intent through buffering, until a real gesture.
  for(const name of ['pointerdown','mousedown','touchstart','keydown'])addEventListener(name,event=>{
    if(event.isTrusted){iqiyiReturnPause=null;douyinReturnPause=null;niconicoReturnPause=null;tiktokReturnPause=null;instagramReturnPause=null;instagramRestore=null;tedReturnPause=null;redbullReturnPause=null;streamableReturnPause=null;redditReturnPause=null;naverReturnPause=null;archiveReturnPause=null;odyseeReturnPause=null;dailymotionReturnPause=null;}
  },true);
  const holdPaused = video => {
    if (pauseLease && pauseLease.page !== location.href) pauseLease = null;
    if (!pauseLease || !video.isConnected) return;
    if (!pauseLease.videos.has(video)) pauseLease.videos.set(video, {
      source: video.currentSrc, epoch: mediaEpoch.get(video)?.id,
      playing: !video.paused && !video.ended || resuming.has(video) || pauseLease.playingIds.has(String(videos.get(video)))
    });
    video.pause();
  };
  let networkPort, network = [], networkPage = location.href;
  let networkEnabled = false;
  // Begin passive observation at document_start. Android's asynchronous native
  // policy can arrive after ThumbPlayer's first metadata request, just as on Weibo.
  let tencentEnabled = typeof Thru3DTencent !== 'undefined' && !!Thru3DTencent.page(location.href), tencentData = [], tencentStatus = 'idle';
  let tencentPolicyAt = null;
  let tencentCapture = {};
  let tencentShape = [];
  let tencentEnvelopes = [];
  let tencentButton = null, tencentChoice = null, tencentClick = 0;
  const tencentActionEvent = event => event.isTrusted && tencentButton && (event.composedPath?.() || []).includes(tencentButton.host);
  // ThumbPlayer installs document-wide gesture handlers. Reserve only events on
  // our own shadow action, before those handlers can capture or cancel the click.
  for(const name of ['pointerdown','mousedown','touchstart','pointerup','mouseup','touchend'])addEventListener(name,event=>{
    if(tencentActionEvent(event))event.stopImmediatePropagation();
  },true);
  addEventListener('click',event=>{
    if(!tencentActionEvent(event))return;
    event.preventDefault();event.stopImmediatePropagation();tencentButton.activate();
  },true);
  const syncTencentButton = target => {
    if (typeof Thru3DPlayButton === 'undefined') return;
    // Keep the action outside ThumbPlayer's managed child tree and event root.
    const box = target?.video.closest?.('#main-player');
    const mount=document.fullscreenElement||document.body;
    if (!tencentEnabled || !target?.video.isConnected || !box || !mount) {tencentButton?.dispose();tencentButton=null;return;}
    const old=tencentButton?.target;
    if (!old || tencentButton.host.isConnected===false || tencentButton.overlay.parentElement!==mount || old.video!==target.video || old.key!==target.key || old.source!==target.source || old.epoch!==target.epoch || tencentButton.box!==box) {
      tencentButton?.dispose();
      const overlay=document.createElement('span');overlay.dataset.thru3dPlayOverlay='tencent';
      overlay.style.cssText='position:fixed;pointer-events:none;z-index:2147482990;';mount.append(overlay);
      const activate=()=>{
        const current=tencentButton?.target;
        if(closed||suspended||pauseLease||!current||!tencentEnabled||current.video.currentSrc!==current.source||mediaEpoch.get(current.video)?.id!==current.epoch)return;
        tencentChoice={...current,at:Date.now(),request:++tencentClick};changed();
      };
      const control=Thru3DPlayButton.create(document,overlay,'tencent',activate);
      control.host.dataset.thru3dTencent='beta';control.host.dataset.thru3dTencentPage=target.page;
      tencentButton={...control,box,overlay,target,activate,dispose(){control.dispose();overlay.remove();}};
    } else tencentButton.target=target;
    const rect=box.getBoundingClientRect();
    Object.assign(tencentButton.overlay.style,{left:rect.left+'px',top:rect.top+'px',width:rect.width+'px',height:rect.height+'px'});
    tencentButton.host.hidden=!Thru3DPlayButton.visible(target.video);tencentButton.enabled(true);
  };
  let mangoEnabled = typeof Thru3DMango !== 'undefined' && !!Thru3DMango.page(location.href), mangoActionEnabled=false, mangoData=[], mangoCapture={};
  let mangoButton = null, mangoChoice = null, mangoClick = 0;
  const mangoActionEvent = event => event.isTrusted && mangoButton && (event.composedPath?.() || []).includes(mangoButton.host);
  // Mango player installs document-wide gesture handlers. Reserve only events on
  // our own shadow action, before those handlers can capture or cancel the click.
  for(const name of ['pointerdown','mousedown','touchstart','pointerup','mouseup','touchend'])addEventListener(name,event=>{
    if(mangoActionEvent(event))event.stopImmediatePropagation();
  },true);
  addEventListener('click',event=>{
    if(!mangoActionEvent(event))return;
    event.preventDefault();event.stopImmediatePropagation();mangoButton.activate();
  },true);
  const syncMangoButton = target => {
    if (typeof Thru3DPlayButton === 'undefined') return;
    // Keep the action outside Mango player's managed child tree and event root.
    const box = target?.video.closest?.('#mgtv-player-wrap');
    const mount=document.fullscreenElement||document.body;
    if (!mangoEnabled || !mangoActionEnabled || !target?.video.isConnected || !box || !mount) {mangoButton?.dispose();mangoButton=null;return;}
    const old=mangoButton?.target;
    if (!old || mangoButton.host.isConnected===false || mangoButton.overlay.parentElement!==mount || old.video!==target.video || old.key!==target.key || old.source!==target.source || old.epoch!==target.epoch || mangoButton.box!==box) {
      mangoButton?.dispose();
      const overlay=document.createElement('span');overlay.dataset.thru3dPlayOverlay='mango';
      overlay.style.cssText='position:fixed;pointer-events:none;z-index:2147482990;';mount.append(overlay);
      const activate=()=>{
        const current=mangoButton?.target;
        if(closed||suspended||pauseLease||!current||!mangoEnabled||!mangoActionEnabled||current.video.currentSrc!==current.source||mediaEpoch.get(current.video)?.id!==current.epoch)return;
        mangoChoice={...current,at:Date.now(),request:++mangoClick};changed();
      };
      const control=Thru3DPlayButton.create(document,overlay,'mango',activate);
      control.host.dataset.thru3dMango='beta';control.host.dataset.thru3dMangoPage=target.page;
      mangoButton={...control,box,overlay,target,activate,dispose(){control.dispose();overlay.remove();}};
    } else mangoButton.target=target;
    const rect=box.getBoundingClientRect();
    Object.assign(mangoButton.overlay.style,{left:rect.left+'px',top:rect.top+'px',width:rect.width+'px',height:rect.height+'px'});
    mangoButton.host.hidden=!Thru3DPlayButton.visible(target.video);mangoButton.enabled(true);
  };
  let youkuEnabled = typeof Thru3DYouku !== 'undefined' && !!Thru3DYouku.page(location.href), youkuActionEnabled=false, youkuData=[], youkuCapture={};
  let youkuButton = null, youkuChoice = null, youkuClick = 0;
  const youkuActionEvent = event => event.isTrusted && youkuButton && (event.composedPath?.() || []).includes(youkuButton.host);
  // Youku player installs document-wide gesture handlers. Reserve only events on
  // our own shadow action, before those handlers can capture or cancel the click.
  for(const name of ['pointerdown','mousedown','touchstart','pointerup','mouseup','touchend'])addEventListener(name,event=>{
    if(youkuActionEvent(event))event.stopImmediatePropagation();
  },true);
  addEventListener('click',event=>{
    if(!youkuActionEvent(event))return;
    event.preventDefault();event.stopImmediatePropagation();youkuButton.activate();
  },true);
  const syncYoukuButton = target => {
    if (typeof Thru3DPlayButton === 'undefined') return;
    // Keep the action outside Youku player's managed child tree and event root.
    const box = target?.video.closest?.('#ykPlayer');
    const mount=document.fullscreenElement||document.body;
    if (!youkuEnabled || !youkuActionEnabled || !target?.video.isConnected || !box || !mount) {youkuButton?.dispose();youkuButton=null;return;}
    const old=youkuButton?.target;
    if (!old || youkuButton.host.isConnected===false || youkuButton.overlay.parentElement!==mount || old.video!==target.video || old.key!==target.key || old.source!==target.source || old.epoch!==target.epoch || youkuButton.box!==box) {
      youkuButton?.dispose();
      const overlay=document.createElement('span');overlay.dataset.thru3dPlayOverlay='youku';
      overlay.style.cssText='position:fixed;pointer-events:none;z-index:2147482990;';mount.append(overlay);
      const activate=()=>{
        const current=youkuButton?.target;
        if(closed||suspended||pauseLease||!current||!youkuEnabled||!youkuActionEnabled||current.video.currentSrc!==current.source||mediaEpoch.get(current.video)?.id!==current.epoch)return;
        youkuChoice={...current,at:Date.now(),request:++youkuClick};changed();
      };
      const control=Thru3DPlayButton.create(document,overlay,'youku',activate);
      control.host.dataset.thru3dYouku='beta';control.host.dataset.thru3dYoukuPage=target.page;
      youkuButton={...control,box,overlay,target,activate,dispose(){control.dispose();overlay.remove();}};
    } else youkuButton.target=target;
    const rect=box.getBoundingClientRect();
    Object.assign(youkuButton.overlay.style,{left:rect.left+'px',top:rect.top+'px',width:rect.width+'px',height:rect.height+'px'});
    youkuButton.host.hidden=!Thru3DPlayButton.visible(target.video);youkuButton.enabled(true);
  };
  let niconicoEnabled = typeof Thru3DNiconico !== 'undefined' && Thru3DNiconico.documentPage(location.href), niconicoActionEnabled=false, niconicoData=[], niconicoCapture={};
  let niconicoButton = null, niconicoChoice = null, niconicoClick = 0;
  let niconicoRendered=null;
  const niconicoActionEvent = event => event.isTrusted && niconicoButton && (event.composedPath?.() || []).includes(niconicoButton.host);
  // Reserve our own shadow action before the site's gesture handlers capture it.
  for(const name of ['pointerdown','mousedown','touchstart','pointerup','mouseup','touchend'])addEventListener(name,event=>{
    if(niconicoActionEvent(event))event.stopImmediatePropagation();
  },true);
  addEventListener('click',event=>{
    if(!niconicoActionEvent(event))return;
    event.preventDefault();event.stopImmediatePropagation();niconicoButton.activate();
  },true);
  const syncNiconicoButton = target => {
    if (typeof Thru3DPlayButton === 'undefined') return;
    // Keep the action outside Niconico player's managed child tree and event root.
    const box = target?.video;
    const mount=document.fullscreenElement||document.body;
    if (!niconicoEnabled || !niconicoActionEnabled || !target?.video.isConnected || !box || !mount) {niconicoButton?.dispose();niconicoButton=null;return;}
    const old=niconicoButton?.target;
    if (!old || niconicoButton.host.isConnected===false || niconicoButton.overlay.parentElement!==mount || old.video!==target.video || old.key!==target.key || old.source!==target.source || old.epoch!==target.epoch || niconicoButton.box!==box) {
      niconicoButton?.dispose();
      const overlay=document.createElement('span');overlay.dataset.thru3dPlayOverlay='niconico';
      overlay.style.cssText='position:fixed;pointer-events:none;z-index:2147482990;';mount.append(overlay);
      const activate=()=>{
        const current=niconicoButton?.target;
        if(closed||suspended||pauseLease||!current||!niconicoEnabled||!niconicoActionEnabled||current.video.currentSrc!==current.source||mediaEpoch.get(current.video)?.id!==current.epoch)return;
        niconicoChoice={...current,at:Date.now(),request:++niconicoClick};changed();
      };
      const control=Thru3DPlayButton.create(document,overlay,'niconico',activate);
      control.host.dataset.thru3dNiconico='beta';control.host.dataset.thru3dNiconicoPage=target.page;
      niconicoButton={...control,box,overlay,target,activate,dispose(){control.dispose();overlay.remove();}};
    } else niconicoButton.target=target;
    const rect=box.getBoundingClientRect();
    Object.assign(niconicoButton.overlay.style,{left:rect.left+'px',top:rect.top+'px',width:rect.width+'px',height:rect.height+'px'});
    niconicoButton.host.hidden=!Thru3DPlayButton.visible(target.video);niconicoButton.enabled(true);
  };
  let twitchEnabled = typeof Thru3DTwitch !== 'undefined' && !!Thru3DTwitch.page(location.href), twitchActionEnabled=false, twitchData=[], twitchCapture={};
  let twitchButton = null, twitchChoice = null, twitchClick = 0;
  const twitchActionEvent = event => event.isTrusted && twitchButton && (event.composedPath?.() || []).includes(twitchButton.host);
  // Reserve only our own action events before site gesture handlers. Reserve only events on
  // our own shadow action, before those handlers can capture or cancel the click.
  for(const name of ['pointerdown','mousedown','touchstart','pointerup','mouseup','touchend'])addEventListener(name,event=>{
    if(twitchActionEvent(event))event.stopImmediatePropagation();
  },true);
  addEventListener('click',event=>{
    if(!twitchActionEvent(event))return;
    event.preventDefault();event.stopImmediatePropagation();twitchButton.activate();
  },true);
  const syncTwitchButton = target => {
    if (typeof Thru3DPlayButton === 'undefined') return;
    // Keep the action outside Twitch player's managed child tree and event root.
    const box = target?.video;
    const mount=document.fullscreenElement||document.body;
    if (!twitchEnabled || !twitchActionEnabled || !target?.video.isConnected || !box || !mount) {twitchButton?.dispose();twitchButton=null;return;}
    const old=twitchButton?.target;
    if (!old || twitchButton.host.isConnected===false || twitchButton.overlay.parentElement!==mount || old.video!==target.video || old.key!==target.key || old.source!==target.source || old.epoch!==target.epoch || twitchButton.box!==box) {
      twitchButton?.dispose();
      const overlay=document.createElement('span');overlay.dataset.thru3dPlayOverlay='twitch';
      overlay.style.cssText='position:fixed;pointer-events:none;z-index:2147482990;';mount.append(overlay);
      const activate=()=>{
        const current=twitchButton?.target;
        if(closed||suspended||pauseLease||!current||!twitchEnabled||!twitchActionEnabled||current.video.currentSrc!==current.source||mediaEpoch.get(current.video)?.id!==current.epoch)return;
        twitchChoice={...current,at:Date.now(),request:++twitchClick};changed();
      };
      const control=Thru3DPlayButton.create(document,overlay,'twitch',activate);
      control.host.dataset.thru3dTwitch='beta';control.host.dataset.thru3dTwitchPage=target.page;
      twitchButton={...control,box,overlay,target,activate,dispose(){control.dispose();overlay.remove();}};
    } else twitchButton.target=target;
    const rect=box.getBoundingClientRect();
    Object.assign(twitchButton.overlay.style,{left:rect.left+'px',top:rect.top+'px',width:rect.width+'px',height:rect.height+'px'});
    twitchButton.host.hidden=!Thru3DPlayButton.visible(target.video);twitchButton.enabled(true);
  };
  let tiktokEnabled = typeof Thru3DTikTok !== 'undefined' && Thru3DTikTok.documentPage(location.href), tiktokActionEnabled=false, tiktokCapture={};
  let tiktokButton = null, tiktokChoice = null, tiktokClick = 0;
  const tiktokActionEvent = event => event.isTrusted && tiktokButton && (event.composedPath?.() || []).includes(tiktokButton.host);
  // Reserve only our own action events before site gesture handlers. Reserve only events on
  // our own shadow action, before those handlers can capture or cancel the click.
  for(const name of ['pointerdown','mousedown','touchstart','pointerup','mouseup','touchend'])addEventListener(name,event=>{
    if(tiktokActionEvent(event))event.stopImmediatePropagation();
  },true);
  addEventListener('click',event=>{
    if(!tiktokActionEvent(event))return;
    event.preventDefault();event.stopImmediatePropagation();tiktokButton.activate();
  },true);
  const syncTikTokButton = target => {
    if (typeof Thru3DPlayButton === 'undefined') return;
    // Keep the action outside TikTok player's managed child tree and event root.
    const box = target?.video;
    const mount=document.fullscreenElement||document.body;
    if (!tiktokEnabled || !tiktokActionEnabled || !target?.video.isConnected || !box || !mount) {tiktokButton?.dispose();tiktokButton=null;return;}
    const old=tiktokButton?.target;
    if (!old || tiktokButton.host.isConnected===false || tiktokButton.overlay.parentElement!==mount || old.video!==target.video || old.key!==target.key || old.source!==target.source || old.epoch!==target.epoch || tiktokButton.box!==box) {
      tiktokButton?.dispose();
      const overlay=document.createElement('span');overlay.dataset.thru3dPlayOverlay='tiktok';
      overlay.style.cssText='position:fixed;pointer-events:none;z-index:2147482990;';mount.append(overlay);
      const activate=()=>{
        const current=tiktokButton?.target;
        if(closed||suspended||pauseLease||!current||!tiktokEnabled||!tiktokActionEnabled||current.video.currentSrc!==current.source||mediaEpoch.get(current.video)?.id!==current.epoch)return;
        tiktokChoice={...current,at:Date.now(),request:++tiktokClick};changed();
      };
      const control=Thru3DPlayButton.create(document,overlay,'tiktok',activate);
      control.host.dataset.thru3dTiktok='beta';control.host.dataset.thru3dTiktokPage=target.page;
      tiktokButton={...control,box,overlay,target,activate,dispose(){control.dispose();overlay.remove();}};
    } else tiktokButton.target=target;
    const rect=box.getBoundingClientRect();
    Object.assign(tiktokButton.overlay.style,{left:rect.left+'px',top:rect.top+'px',width:rect.width+'px',height:rect.height+'px'});
    tiktokButton.host.hidden=!Thru3DPlayButton.visible(target.video);tiktokButton.enabled(true);
  };
  let instagramEnabled = typeof Thru3DInstagram !== 'undefined' && Thru3DInstagram.documentPage(location.href), instagramActionEnabled=false, instagramCapture={};
  let instagramButton = null, instagramChoice = null, instagramClick = 0;
  const instagramActionEvent = event => event.isTrusted && instagramButton && (event.composedPath?.() || []).includes(instagramButton.host);
  // Reserve only our own action events before site gesture handlers. Reserve only events on
  // our own shadow action, before those handlers can capture or cancel the click.
  for(const name of ['pointerdown','mousedown','touchstart','pointerup','mouseup','touchend'])addEventListener(name,event=>{
    if(instagramActionEvent(event))event.stopImmediatePropagation();
  },true);
  addEventListener('click',event=>{
    if(!instagramActionEvent(event))return;
    event.preventDefault();event.stopImmediatePropagation();instagramButton.activate();
  },true);
  const syncInstagramButton = target => {
    if (typeof Thru3DPlayButton === 'undefined') return;
    // Keep the action outside Instagram player's managed child tree and event root.
    const box = target?.video;
    const mount=document.fullscreenElement||document.body;
    if (!instagramEnabled || !instagramActionEnabled || !target?.video.isConnected || !box || !mount) {instagramButton?.dispose();instagramButton=null;return;}
    const old=instagramButton?.target;
    if (!old || instagramButton.host.isConnected===false || instagramButton.overlay.parentElement!==mount || old.video!==target.video || old.key!==target.key || old.source!==target.source || old.epoch!==target.epoch || instagramButton.box!==box) {
      instagramButton?.dispose();
      const overlay=document.createElement('span');overlay.dataset.thru3dPlayOverlay='instagram';
      overlay.style.cssText='position:fixed;pointer-events:none;z-index:2147482990;';mount.append(overlay);
      const activate=()=>{
        const current=instagramButton?.target;
        if(closed||suspended||pauseLease||!current||!instagramEnabled||!instagramActionEnabled||current.video.currentSrc!==current.source||mediaEpoch.get(current.video)?.id!==current.epoch)return;
        instagramChoice={...current,at:Date.now(),request:++instagramClick};changed();
      };
      const control=Thru3DPlayButton.create(document,overlay,'instagram',activate);
      control.host.dataset.thru3dInstagram='beta';control.host.dataset.thru3dInstagramPage=target.page;
      instagramButton={...control,box,overlay,target,activate,dispose(){control.dispose();overlay.remove();}};
    } else instagramButton.target=target;
    const rect=box.getBoundingClientRect();
    Object.assign(instagramButton.overlay.style,{left:rect.left+'px',top:rect.top+'px',width:rect.width+'px',height:rect.height+'px'});
    instagramButton.host.hidden=!Thru3DPlayButton.visible(target.video);instagramButton.enabled(true);
  };
  let tedEnabled = typeof Thru3DTed !== 'undefined' && Thru3DTed.documentPage(location.href), tedActionEnabled=false, tedCapture={};
  let tedButton = null, tedChoice = null, tedClick = 0;
  const tedActionEvent = event => event.isTrusted && tedButton && (event.composedPath?.() || []).includes(tedButton.host);
  // Reserve only our own action events before site gesture handlers. Reserve only events on
  // our own shadow action, before those handlers can capture or cancel the click.
  for(const name of ['pointerdown','mousedown','touchstart','pointerup','mouseup','touchend'])addEventListener(name,event=>{
    if(tedActionEvent(event))event.stopImmediatePropagation();
  },true);
  addEventListener('click',event=>{
    if(!tedActionEvent(event))return;
    event.preventDefault();event.stopImmediatePropagation();tedButton.activate();
  },true);
  const syncTedButton = target => {
    if (typeof Thru3DPlayButton === 'undefined') return;
    // Keep the action outside Ted player's managed child tree and event root.
    const box = target?.video;
    const mount=document.fullscreenElement||document.body;
    if (!tedEnabled || !tedActionEnabled || !target?.video.isConnected || !box || !mount) {tedButton?.dispose();tedButton=null;return;}
    const old=tedButton?.target;
    if (!old || tedButton.host.isConnected===false || tedButton.overlay.parentElement!==mount || old.video!==target.video || old.key!==target.key || old.source!==target.source || old.epoch!==target.epoch || tedButton.box!==box) {
      tedButton?.dispose();
      const overlay=document.createElement('span');overlay.dataset.thru3dPlayOverlay='ted';
      overlay.style.cssText='position:fixed;pointer-events:none;z-index:2147482990;';mount.append(overlay);
      const activate=()=>{
        const current=tedButton?.target;
        if(closed||suspended||pauseLease||!current||!tedEnabled||!tedActionEnabled||current.video.currentSrc!==current.source||mediaEpoch.get(current.video)?.id!==current.epoch)return;
        tedChoice={...current,at:Date.now(),request:++tedClick};changed();
      };
      const control=Thru3DPlayButton.create(document,overlay,'ted',activate);
      control.host.dataset.thru3dTed='beta';control.host.dataset.thru3dTedPage=target.page;
      tedButton={...control,box,overlay,target,activate,dispose(){control.dispose();overlay.remove();}};
    } else tedButton.target=target;
    const rect=box.getBoundingClientRect();
    Object.assign(tedButton.overlay.style,{left:rect.left+'px',top:rect.top+'px',width:rect.width+'px',height:rect.height+'px'});
    tedButton.host.hidden=!Thru3DPlayButton.visible(target.video);tedButton.enabled(true);
  };
  let redbullEnabled = typeof Thru3DRedBull !== 'undefined' && Thru3DRedBull.documentPage(location.href), redbullActionEnabled=false, redbullCapture={};
  let redbullButton = null, redbullChoice = null, redbullClick = 0;
  const redbullActionEvent = event => event.isTrusted && redbullButton && (event.composedPath?.() || []).includes(redbullButton.host);
  // Reserve only our own action events before site gesture handlers. Reserve only events on
  // our own shadow action, before those handlers can capture or cancel the click.
  for(const name of ['pointerdown','mousedown','touchstart','pointerup','mouseup','touchend'])addEventListener(name,event=>{
    if(redbullActionEvent(event))event.stopImmediatePropagation();
  },true);
  addEventListener('click',event=>{
    if(!redbullActionEvent(event))return;
    event.preventDefault();event.stopImmediatePropagation();redbullButton.activate();
  },true);
  const syncRedBullButton = target => {
    if (typeof Thru3DPlayButton === 'undefined') return;
    // Keep the action outside RedBull player's managed child tree and event root.
    const box = target?.video;
    const mount=document.fullscreenElement||document.body;
    if (!redbullEnabled || !redbullActionEnabled || !target?.video.isConnected || !box || !mount) {redbullButton?.dispose();redbullButton=null;return;}
    const old=redbullButton?.target;
    if (!old || redbullButton.host.isConnected===false || redbullButton.overlay.parentElement!==mount || old.video!==target.video || old.key!==target.key || old.source!==target.source || old.epoch!==target.epoch || redbullButton.box!==box) {
      redbullButton?.dispose();
      const overlay=document.createElement('span');overlay.dataset.thru3dPlayOverlay='redbull';
      overlay.style.cssText='position:fixed;pointer-events:none;z-index:2147482990;';mount.append(overlay);
      const activate=()=>{
        const current=redbullButton?.target;
        if(closed||suspended||pauseLease||!current||!redbullEnabled||!redbullActionEnabled||current.video.currentSrc!==current.source||mediaEpoch.get(current.video)?.id!==current.epoch)return;
        redbullChoice={...current,at:Date.now(),request:++redbullClick};changed();
      };
      const control=Thru3DPlayButton.create(document,overlay,'redbull',activate);
      control.host.dataset.thru3dRedbull='beta';control.host.dataset.thru3dRedbullPage=target.page;
      redbullButton={...control,box,overlay,target,activate,dispose(){control.dispose();overlay.remove();}};
    } else redbullButton.target=target;
    const rect=box.getBoundingClientRect();
    Object.assign(redbullButton.overlay.style,{left:rect.left+'px',top:rect.top+'px',width:rect.width+'px',height:rect.height+'px'});
    redbullButton.host.hidden=!Thru3DPlayButton.visible(target.video);redbullButton.enabled(true);
  };
  let streamableEnabled = typeof Thru3DStreamable !== 'undefined' && Thru3DStreamable.documentPage(location.href), streamableActionEnabled=false, streamableCapture={};
  let redditEnabled=typeof Thru3DReddit!=='undefined'&&Thru3DReddit.documentPage(location.href),redditActionEnabled=false,redditCapture={};
  let redditChoice=null,redditClick=0,redditControls=null;
  const syncRedditButtons=targets=>{
    if(!redditControls&&redditEnabled&&typeof Thru3DReddit!=='undefined')redditControls=Thru3DReddit.controls(document,target=>{
      if(closed||suspended||pauseLease||!redditEnabled||!redditActionEnabled||target.video.currentSrc!==target.source||mediaEpoch.get(target.video)?.id!==target.epoch)return;
      redditChoice={...target,at:Date.now(),request:++redditClick};changed();
    });
    redditControls?.sync(targets,redditEnabled&&redditActionEnabled);
  };
  let naverEnabled=typeof Thru3DNaver!=='undefined'&&Thru3DNaver.documentPage(location.href),naverActionEnabled=false,naverCapture={};
  let naverChoice=null,naverClick=0,naverControls=null,naverData=[];
  const naverEvidence=new WeakMap();
  const syncNaverButtons=targets=>{
    if(!naverControls&&naverEnabled&&typeof Thru3DNaver!=='undefined')naverControls=Thru3DReddit.controls(document,target=>{
      if(closed||suspended||pauseLease||!naverEnabled||!naverActionEnabled||target.video.currentSrc!==target.source||mediaEpoch.get(target.video)?.id!==target.epoch)return;
      naverChoice={...target,at:Date.now(),request:++naverClick};changed();
    },'naver');
    naverControls?.sync(targets,naverEnabled&&naverActionEnabled);
  };
  let streamableButton = null, streamableChoice = null, streamableClick = 0;
  const streamableActionEvent = event => event.isTrusted && streamableButton && (event.composedPath?.() || []).includes(streamableButton.host);
  // Reserve only our own action events before site gesture handlers. Reserve only events on
  // our own shadow action, before those handlers can capture or cancel the click.
  for(const name of ['pointerdown','mousedown','touchstart','pointerup','mouseup','touchend'])addEventListener(name,event=>{
    if(streamableActionEvent(event))event.stopImmediatePropagation();
  },true);
  addEventListener('click',event=>{
    if(!streamableActionEvent(event))return;
    event.preventDefault();event.stopImmediatePropagation();streamableButton.activate();
  },true);
  const syncStreamableButton = target => {
    if (typeof Thru3DPlayButton === 'undefined') return;
    // Keep the action outside Streamable player's managed child tree and event root.
    const box = target?.video;
    const mount=document.fullscreenElement||document.body;
    if (!streamableEnabled || !streamableActionEnabled || !target?.video.isConnected || !box || !mount) {streamableButton?.dispose();streamableButton=null;return;}
    const old=streamableButton?.target;
    if (!old || streamableButton.host.isConnected===false || streamableButton.overlay.parentElement!==mount || old.video!==target.video || old.key!==target.key || old.source!==target.source || old.epoch!==target.epoch || streamableButton.box!==box) {
      streamableButton?.dispose();
      const overlay=document.createElement('span');overlay.dataset.thru3dPlayOverlay='streamable';
      overlay.style.cssText='position:fixed;pointer-events:none;z-index:2147482990;';mount.append(overlay);
      const activate=()=>{
        const current=streamableButton?.target;
        if(closed||suspended||pauseLease||!current||!streamableEnabled||!streamableActionEnabled||current.video.currentSrc!==current.source||mediaEpoch.get(current.video)?.id!==current.epoch)return;
        streamableChoice={...current,at:Date.now(),request:++streamableClick};changed();
      };
      const control=Thru3DPlayButton.create(document,overlay,'streamable',activate);
      control.host.dataset.thru3dStreamable='beta';control.host.dataset.thru3dStreamablePage=target.page;
      streamableButton={...control,box,overlay,target,activate,dispose(){control.dispose();overlay.remove();}};
    } else streamableButton.target=target;
    const rect=box.getBoundingClientRect();
    Object.assign(streamableButton.overlay.style,{left:rect.left+'px',top:rect.top+'px',width:rect.width+'px',height:rect.height+'px'});
    streamableButton.host.hidden=!Thru3DPlayButton.visible(target.video);streamableButton.enabled(true);
  };
  let archiveEnabled = typeof Thru3DArchive !== 'undefined' && Thru3DArchive.documentPage(location.href), archiveActionEnabled=false, archiveCapture={};
  let archiveButton = null, archiveChoice = null, archiveClick = 0;
  const archiveActionEvent = event => event.isTrusted && archiveButton && (event.composedPath?.() || []).includes(archiveButton.host);
  // Reserve only our own action events before site gesture handlers. Reserve only events on
  // our own shadow action, before those handlers can capture or cancel the click.
  for(const name of ['pointerdown','mousedown','touchstart','pointerup','mouseup','touchend'])addEventListener(name,event=>{
    if(archiveActionEvent(event))event.stopImmediatePropagation();
  },true);
  addEventListener('click',event=>{
    if(!archiveActionEvent(event))return;
    event.preventDefault();event.stopImmediatePropagation();archiveButton.activate();
  },true);
  const syncArchiveButton = target => {
    if (typeof Thru3DPlayButton === 'undefined') return;
    // Keep the action outside Archive player's managed child tree and event root.
    const box = target?.video;
    const mount=document.fullscreenElement||document.body;
    if (!archiveEnabled || !archiveActionEnabled || !target?.video.isConnected || !box || !mount) {archiveButton?.dispose();archiveButton=null;return;}
    const old=archiveButton?.target;
    if (!old || archiveButton.host.isConnected===false || archiveButton.overlay.parentElement!==mount || old.video!==target.video || old.key!==target.key || old.source!==target.source || old.epoch!==target.epoch || archiveButton.box!==box) {
      archiveButton?.dispose();
      const overlay=document.createElement('span');overlay.dataset.thru3dPlayOverlay='archive';
      overlay.style.cssText='position:fixed;pointer-events:none;z-index:2147482990;';mount.append(overlay);
      const activate=()=>{
        const current=archiveButton?.target;
        if(closed||suspended||pauseLease||!current||!archiveEnabled||!archiveActionEnabled||current.video.currentSrc!==current.source||mediaEpoch.get(current.video)?.id!==current.epoch)return;
        archiveChoice={...current,at:Date.now(),request:++archiveClick};changed();
      };
      const control=Thru3DPlayButton.create(document,overlay,'archive',activate);
      control.host.dataset.thru3dArchive='beta';control.host.dataset.thru3dArchivePage=target.page;
      archiveButton={...control,box,overlay,target,activate,dispose(){control.dispose();overlay.remove();}};
    } else archiveButton.target=target;
    const rect=box.getBoundingClientRect();
    Object.assign(archiveButton.overlay.style,{left:rect.left+'px',top:rect.top+'px',width:rect.width+'px',height:rect.height+'px'});
    archiveButton.host.hidden=!Thru3DPlayButton.visible(target.video);archiveButton.enabled(true);
  };
  let odyseeEnabled = typeof Thru3DOdysee !== 'undefined' && Thru3DOdysee.documentPage(location.href), odyseeActionEnabled=false, odyseeCapture={};
  let odyseeButton = null, odyseeChoice = null, odyseeClick = 0;
  const odyseeActionEvent = event => event.isTrusted && odyseeButton && (event.composedPath?.() || []).includes(odyseeButton.host);
  // Reserve only our own action events before site gesture handlers. Reserve only events on
  // our own shadow action, before those handlers can capture or cancel the click.
  for(const name of ['pointerdown','mousedown','touchstart','pointerup','mouseup','touchend'])addEventListener(name,event=>{
    if(odyseeActionEvent(event))event.stopImmediatePropagation();
  },true);
  addEventListener('click',event=>{
    if(!odyseeActionEvent(event))return;
    event.preventDefault();event.stopImmediatePropagation();odyseeButton.activate();
  },true);
  const syncOdyseeButton = target => {
    if (typeof Thru3DPlayButton === 'undefined') return;
    // Keep the action outside Odysee player's managed child tree and event root.
    const box = target?.video;
    const mount=document.fullscreenElement||document.body;
    if (!odyseeEnabled || !odyseeActionEnabled || !target?.video.isConnected || !box || !mount) {odyseeButton?.dispose();odyseeButton=null;return;}
    const old=odyseeButton?.target;
    if (!old || odyseeButton.host.isConnected===false || odyseeButton.overlay.parentElement!==mount || old.video!==target.video || old.key!==target.key || old.source!==target.source || old.epoch!==target.epoch || odyseeButton.box!==box) {
      odyseeButton?.dispose();
      const overlay=document.createElement('span');overlay.dataset.thru3dPlayOverlay='odysee';
      overlay.style.cssText='position:fixed;pointer-events:none;z-index:2147482990;';mount.append(overlay);
      const activate=()=>{
        const current=odyseeButton?.target;
        if(closed||suspended||pauseLease||!current||!odyseeEnabled||!odyseeActionEnabled||current.video.currentSrc!==current.source||mediaEpoch.get(current.video)?.id!==current.epoch)return;
        odyseeChoice={...current,at:Date.now(),request:++odyseeClick};changed();
      };
      const control=Thru3DPlayButton.create(document,overlay,'odysee',activate);
      control.host.dataset.thru3dOdysee='beta';control.host.dataset.thru3dOdyseePage=target.page;
      odyseeButton={...control,box,overlay,target,activate,dispose(){control.dispose();overlay.remove();}};
    } else odyseeButton.target=target;
    const rect=box.getBoundingClientRect();
    Object.assign(odyseeButton.overlay.style,{left:rect.left+'px',top:rect.top+'px',width:rect.width+'px',height:rect.height+'px'});
    odyseeButton.host.hidden=!Thru3DPlayButton.visible(target.video);odyseeButton.enabled(true);
  };
  let dailymotionEnabled = typeof Thru3DDailymotion !== 'undefined' && Thru3DDailymotion.frame(location.href), dailymotionActionEnabled=false, dailymotionCapture={},dailymotionBodies=[],dailymotionOwner="";
  let dailymotionButton = null, dailymotionChoice = null, dailymotionClick = 0;
  const dailymotionActionEvent = event => event.isTrusted && dailymotionButton && (event.composedPath?.() || []).includes(dailymotionButton.host);
  // Reserve only our own action events before site gesture handlers. Reserve only events on
  // our own shadow action, before those handlers can capture or cancel the click.
  for(const name of ['pointerdown','mousedown','touchstart','pointerup','mouseup','touchend'])addEventListener(name,event=>{
    if(dailymotionActionEvent(event))event.stopImmediatePropagation();
  },true);
  addEventListener('click',event=>{
    if(!dailymotionActionEvent(event))return;
    event.preventDefault();event.stopImmediatePropagation();dailymotionButton.activate();
  },true);
  const syncDailymotionButton = target => {
    if (typeof Thru3DPlayButton === 'undefined') return;
    // Keep the action outside Dailymotion player's managed child tree and event root.
    const box = target?.video;
    const mount=document.fullscreenElement||document.body;
    if (!dailymotionEnabled || !dailymotionActionEnabled || !target?.video.isConnected || !box || !mount) {dailymotionButton?.dispose();dailymotionButton=null;return;}
    const old=dailymotionButton?.target;
    if (!old || dailymotionButton.host.isConnected===false || dailymotionButton.overlay.parentElement!==mount || old.video!==target.video || old.key!==target.key || old.source!==target.source || old.epoch!==target.epoch || dailymotionButton.box!==box) {
      dailymotionButton?.dispose();
      const overlay=document.createElement('span');overlay.dataset.thru3dPlayOverlay='dailymotion';
      overlay.style.cssText='position:fixed;pointer-events:none;z-index:2147482990;';mount.append(overlay);
      const activate=()=>{
        const current=dailymotionButton?.target;
        if(closed||suspended||pauseLease||!current||!dailymotionEnabled||!dailymotionActionEnabled||current.video.currentSrc!==current.source||mediaEpoch.get(current.video)?.id!==current.epoch)return;
        dailymotionChoice={...current,at:Date.now(),request:++dailymotionClick};changed();
      };
      const control=Thru3DPlayButton.create(document,overlay,'dailymotion',activate);
      control.host.dataset.thru3dDailymotion='beta';control.host.dataset.thru3dDailymotionPage=target.page;
      dailymotionButton={...control,box,overlay,target,activate,dispose(){control.dispose();overlay.remove();}};
    } else dailymotionButton.target=target;
    const rect=box.getBoundingClientRect();
    Object.assign(dailymotionButton.overlay.style,{left:rect.left+'px',top:rect.top+'px',width:rect.width+'px',height:rect.height+'px'});
    dailymotionButton.host.hidden=!Thru3DPlayButton.visible(target.video);dailymotionButton.enabled(true);
  };
  let iqiyiEnabled = typeof Thru3DIqiyi !== 'undefined' && !!Thru3DIqiyi.page(location.href), iqiyiActionEnabled=false;
  let iqiyiButton = null, iqiyiChoice = null, iqiyiClick = 0;
  const iqiyiActionEvent = event => event.isTrusted && iqiyiButton && (event.composedPath?.() || []).includes(iqiyiButton.host);
  // Iqiyi player installs document-wide gesture handlers. Reserve only events on
  // our own shadow action, before those handlers can capture or cancel the click.
  for(const name of ['pointerdown','mousedown','touchstart','pointerup','mouseup','touchend'])addEventListener(name,event=>{
    if(iqiyiActionEvent(event))event.stopImmediatePropagation();
  },true);
  addEventListener('click',event=>{
    if(!iqiyiActionEvent(event))return;
    event.preventDefault();event.stopImmediatePropagation();iqiyiButton.activate();
  },true);
  const syncIqiyiButton = target => {
    if (typeof Thru3DPlayButton === 'undefined') return;
    // Keep the action outside Iqiyi player's managed child tree and event root.
    const box = target?.video.closest?.('#outlayer');
    const mount=document.fullscreenElement||document.body;
    if (!iqiyiEnabled || !iqiyiActionEnabled || !target?.video.isConnected || !box || !mount) {iqiyiButton?.dispose();iqiyiButton=null;return;}
    const old=iqiyiButton?.target;
    if (!old || iqiyiButton.host.isConnected===false || iqiyiButton.overlay.parentElement!==mount || old.video!==target.video || old.key!==target.key || old.source!==target.source || old.epoch!==target.epoch || iqiyiButton.box!==box) {
      iqiyiButton?.dispose();
      const overlay=document.createElement('span');overlay.dataset.thru3dPlayOverlay='iqiyi';
      overlay.style.cssText='position:fixed;pointer-events:none;z-index:2147482990;';mount.append(overlay);
      const activate=()=>{
        const current=iqiyiButton?.target;
        if(closed||suspended||pauseLease||!current||!iqiyiEnabled||!iqiyiActionEnabled||current.page!==location.href||current.video.currentSrc!==current.source||mediaEpoch.get(current.video)?.id!==current.epoch)return;
        iqiyiReturnPause=null;iqiyiChoice={...current,at:Date.now(),request:++iqiyiClick};changed();
      };
      const control=Thru3DPlayButton.create(document,overlay,'iqiyi',activate);
      control.host.dataset.thru3dIqiyi='beta';control.host.dataset.thru3dIqiyiPage=target.page;
      iqiyiButton={...control,box,overlay,target,activate,dispose(){control.dispose();overlay.remove();}};
    } else iqiyiButton.target=target;
    const rect=box.getBoundingClientRect();
    Object.assign(iqiyiButton.overlay.style,{left:rect.left+'px',top:rect.top+'px',width:rect.width+'px',height:rect.height+'px'});
    iqiyiButton.host.hidden=!Thru3DPlayButton.visible(target.video);iqiyiButton.enabled(true);
  };
  const douyinButtons = new Map();let douyinChoice=null,douyinClick=0,douyinActionEnabled=false;
  const douyinActionEvent=event=>event.isTrusted&&[...douyinButtons.values()].find(b=>(event.composedPath?.()||[]).includes(b.host));
  for(const name of ['pointerdown','mousedown','touchstart','pointerup','mouseup','touchend'])addEventListener(name,event=>{
    if(douyinActionEvent(event))event.stopImmediatePropagation();
  },true);
  addEventListener('click',event=>{
    const control=douyinActionEvent(event);if(!control)return;
    event.preventDefault();event.stopImmediatePropagation();control.activate();
  },true);
  const syncDouyinButtons=targets=>{
    if(typeof Thru3DPlayButton==='undefined')return;
    const eligible=douyinEnabled&&douyinActionEnabled?targets.filter(t=>t.video.isConnected&&Thru3DPlayButton.visible(t.video)):[];
    const active=eligible.filter(t=>t.active),current=active.length?active:eligible,keep=new Set(current.map(t=>t.video));
    for(const [v,b] of douyinButtons)if(!keep.has(v)){b.dispose();douyinButtons.delete(v);}
    const mount=document.fullscreenElement||document.body;if(!mount)return;
    for(const target of current){
      let control=douyinButtons.get(target.video),old=control?.target;
      if(!old||!control.host.isConnected||control.overlay.parentElement!==mount||old.key!==target.key||old.source!==target.source||old.epoch!==target.epoch){
        control?.dispose();
        const overlay=document.createElement('span');overlay.dataset.thru3dPlayOverlay='douyin';
        overlay.style.cssText='position:fixed;pointer-events:none;z-index:2147482990;';mount.append(overlay);
        const activate=()=>{
          const selected=douyinButtons.get(target.video)?.target;
          if(closed||suspended||pauseLease||!douyinActionEnabled||!selected||selected.video.currentSrc!==selected.source||mediaEpoch.get(selected.video)?.id!==selected.epoch)return;
          const fresh=Thru3DDouyinCurrent.capture(selected.video,location.href,network);
          if(!fresh||fresh.id+':'+fresh.revision!==selected.key)return;
          douyinReturnPause=null;douyinChoice={...selected,at:Date.now(),request:++douyinClick};changed();
        };
        const button=Thru3DPlayButton.create(document,overlay,'douyin',activate);
        button.host.dataset.thru3dDouyin='beta';button.host.dataset.thru3dDouyinId=target.owner;
        button.host.dataset.thru3dDouyinPage=target.page;
        button.host.dataset.thru3dDouyinVideo=String(videos.get(target.video));
        control={...button,overlay,target,activate,dispose(){button.dispose();overlay.remove();}};douyinButtons.set(target.video,control);
      }else control.target=target;
      const rect=target.video.getBoundingClientRect();
      Object.assign(control.overlay.style,{left:rect.left+'px',top:rect.top+'px',width:rect.width+'px',height:rect.height+'px'});
      control.host.hidden=false;control.enabled(true);
    }
  };
  let bilibiliEnabled = false, bilibiliData = [];
  let bilibiliButton = null, bilibiliChoice = null, bilibiliClick = 0;
  const biliKey = data => [data.id,data.cid,data.part,data.ep || ''].join(':');
  const syncBilibiliButton = target => {
    if (typeof Thru3DPlayButton === 'undefined') return;
    const box = target?.video.closest?.('.bpx-player-video-area, .bilibili-player-video') || target?.video.parentElement;
    if (!bilibiliEnabled || !target?.video.isConnected || !box) {
      bilibiliButton?.dispose();bilibiliButton=null;return;
    }
    const old = bilibiliButton?.target;
    if (!old || old.video !== target.video || old.key !== target.key || old.epoch !== target.epoch ||
        old.source !== target.source || bilibiliButton.box !== box) {
      bilibiliButton?.dispose();
      const control = Thru3DPlayButton.create(document,box,'bilibili',()=>{
        const current = bilibiliButton?.target;
        if (closed || suspended || pauseLease || !current?.ready || bilibiliOwner?.video !== current.video ||
            current.video.currentSrc !== current.source || mediaEpoch.get(current.video)?.id !== current.epoch) return;
        bilibiliChoice = {...current,at:Date.now(),request:++bilibiliClick};changed();
      });
      control.host.dataset.thru3dBilibili='beta';
      bilibiliButton={...control,box,target};
    } else bilibiliButton.target=target;
    bilibiliButton.host.hidden=!Thru3DPlayButton.visible(target.video);
    bilibiliButton.enabled(target.ready,target.ready ? '' : (bilibiliButton.label === '播放 Beta' ? '视频加载中' : 'Video not ready'));
  };
  let weiboEnabled = typeof Thru3DWeibo !== 'undefined' && Thru3DWeibo.documentPage(location.href);
  let weiboChoice = null, weiboRequest = 0, weiboControls;
  const weiboEvidence = new WeakMap();
  // The first detail request can precede Android's policy reply. Observation is
  // limited to this verified official document; native handoff still revalidates.
  let douyinEnabled = typeof Thru3DDouyin !== 'undefined' && Thru3DDouyin.documentPage(location.href), douyinData = [];
  let douyinDiagnostics = false, douyinObservation = {};
  let douyinApiPaths = [], douyinDomAt = 0, douyinDomPage = '', douyinDom = {};
  const douyinDomCounts = () => {
    if (douyinDomPage === location.href && Date.now() - douyinDomAt < 1000) return douyinDom;
    douyinDomPage = location.href; douyinDomAt = Date.now();
    const id = Thru3DDouyin.page(location.href)?.id;
    const counts = {render_data:0,render_current:0,flight_scripts:0,flight_current:0,flight_video:0,inline_current:0,
      inline_model:0,inline_audio:0,resource_entries:0,resource_api:0,resource_related:0,resource_detail:0,
      resource_detail_current:0,resource_detail_other_host:0,resource_detail_worker:0,resource_detail_fetch:0};
    let size = 0;
    for (const script of [...document.querySelectorAll('script:not([src])')].slice(0,128)) {
      const text = script.textContent || ''; if ((size += text.length) > 2 * 1024 * 1024) break;
      const current = !!id && text.includes(id), flight = text.includes('__pace_f');
      if (current) counts.inline_current++;
      if (text.includes('video_model')) counts.inline_model++;
      if (text.includes('bit_rate_audio')) counts.inline_audio++;
      if (script.id === 'RENDER_DATA') { counts.render_data++; if (current) counts.render_current++; }
      if (flight) { counts.flight_scripts++; if (current) counts.flight_current++; if (/awemeId|aweme_id/.test(text)) counts.flight_video++; }
    }
    // Read this document's existing timing entries, retaining only numeric counts.
    // This does not request an API, inspect a response or change handoff ownership.
    try {
      for (const entry of (typeof performance !== 'undefined' ? performance.getEntriesByType('resource') : []).slice(-512)) {
        counts.resource_entries++;
        const value = new URL(entry.name);
        if (value.protocol !== 'https:' || value.username || value.password) continue;
        if (value.pathname.startsWith('/aweme/v1/web/')) counts.resource_api++;
        if (value.pathname === '/aweme/v1/web/aweme/related/') counts.resource_related++;
        if (value.pathname !== '/aweme/v1/web/aweme/detail/') continue;
        counts.resource_detail++;
        const ids = value.searchParams.getAll('aweme_id');
        if (ids.length === 1 && ids[0] === id) counts.resource_detail_current++;
        if (value.hostname !== 'www.douyin.com') counts.resource_detail_other_host++;
        if (entry.workerStart > 0) counts.resource_detail_worker++;
        if (entry.initiatorType === 'fetch') counts.resource_detail_fetch++;
      }
    } catch (_) {}
    return douyinDom = counts;
  };
  let bilibiliViews = [];
  let bilibiliStatus = 'idle', bilibiliResponseApi = false;
  let bilibiliInitial = null, bilibiliInitialPage = '', bilibiliScanAt = 0;
  let bilibiliOwner = null;
  const naverNetworkTrace=[];let naverNetworkConnections=0;
  const traceNaverNetwork=(event,reset=false)=>{
    try{const u=new URL(location.href);if(u.origin!=='https://m.naver.com'||u.pathname!=='/shorts/')return;
      const service=u.searchParams.get('serviceType')||'';
      naverNetworkTrace.push({event,reset,connection:naverNetworkConnections,enabled:naverEnabled,
        supported:typeof Thru3DNaver!=='undefined'&&Thru3DNaver.playbackPage(location.href),
        service:/^[A-Z_]{2,16}$/.test(service)?service:'other',service_values:u.searchParams.getAll('serviceType').length});
      if(naverNetworkTrace.length>16)naverNetworkTrace.shift();
    }catch(_){}
  };
  const networkContext = (reset = false) => {
    traceNaverNetwork('context',reset);
    try { networkPort?.postMessage({ type: "context", page: location.href, enabled: networkEnabled, bilibili: bilibiliEnabled, douyin: douyinEnabled, weibo: weiboEnabled, tencent:tencentEnabled, mango:mangoEnabled, youku:youkuEnabled, iqiyi:iqiyiEnabled, niconico:niconicoEnabled, niconico_rendered:niconicoRendered, twitch:twitchEnabled, tiktok:tiktokEnabled, instagram:instagramEnabled, ted:tedEnabled, redbull:redbullEnabled, streamable:streamableEnabled, reddit:redditEnabled,naver:naverEnabled, archive:archiveEnabled, odysee:odyseeEnabled, dailymotion:dailymotionEnabled, reset }); } catch (_) {}
  };
  const mediaEpoch = new WeakMap();
  const connectNetwork = () => {
    network = [];
    tencentData = [];mangoData=[];mangoCapture={};
    youkuData=[];youkuCapture={};niconicoData=[];niconicoCapture={};twitchData=[];twitchCapture={};tiktokCapture={};instagramCapture={};tedCapture={};dailymotionBodies=[];dailymotionCapture={};naverData=[];
    tencentCapture = {};tencentShape=[];tencentEnvelopes=[];
    douyinData = [];
    bilibiliData = []; bilibiliViews = [];
    networkPort = browser.runtime.connect({ name: "thru3d_network" });
    naverNetworkConnections++;traceNaverNetwork('connected');
    const connection = networkPort;
    networkPort.onMessage.addListener(message => {
      if (connection !== networkPort || message?.type !== "network" || message.page !== location.href) return;
      const priorNaverCount=naverData.length;
      naverData=Array.isArray(message.naver)?message.naver.slice(0,64):[];naverCapture=message.naver_capture||{};
      if(priorNaverCount>0&&!naverData.length)traceNaverNetwork('declarations_cleared');
      dailymotionBodies=Array.isArray(message.dailymotion_bodies)?message.dailymotion_bodies.slice(0,6):[];
      network = Array.isArray(message.candidates) ? message.candidates.slice(0, 24) : [];
      douyinData = Array.isArray(message.douyin) ? message.douyin.slice(0,16) : [];
      douyinObservation = message.douyin_observation || {};
      douyinApiPaths = Array.isArray(message.douyin_api_paths) ? message.douyin_api_paths.slice(0,32) : [];
      bilibiliData = Array.isArray(message.bilibili) ? message.bilibili.slice(0, 4) : [];
      bilibiliViews = Array.isArray(message.bilibili_views) ? message.bilibili_views.slice(0, 4) : [];
      mangoData = Array.isArray(message.mango)?message.mango.slice(0,8):[];mangoCapture=message.mango_capture||{};
      youkuData = Array.isArray(message.youku)?message.youku.slice(0,8):[];youkuCapture=message.youku_capture||{};
      niconicoData=Array.isArray(message.niconico)?message.niconico.slice(0,8):[];niconicoCapture=message.niconico_capture||{};
      twitchData=Array.isArray(message.twitch)?message.twitch.slice(0,16):[];twitchCapture=message.twitch_capture||{};
      tencentData = Array.isArray(message.tencent) ? message.tencent.slice(0,8) : [];
      tencentStatus = message.tencent_status || 'idle';
      tencentCapture = message.tencent_capture || {};
      tencentShape = message.tencent_shape || [];
      tencentEnvelopes = Array.isArray(message.tencent_envelopes)?message.tencent_envelopes.slice(0,8):[];
      bilibiliStatus = message.bilibili_status || 'idle'; bilibiliResponseApi = message.bilibili_response_api === true;
      changed();
    });
    networkPort.onDisconnect.addListener(() => { if (connection === networkPort) { network = []; mangoData=[];mangoCapture={};youkuData=[];youkuCapture={};niconicoData=[];niconicoCapture={};twitchData=[];twitchCapture={};tiktokCapture={};instagramCapture={};tedCapture={};dailymotionBodies=[];dailymotionCapture={};naverData=[];tencentData = [];tencentCapture={};tencentShape=[];tencentEnvelopes=[]; douyinData = []; bilibiliData = []; bilibiliViews = []; bilibiliInitial = null; changed(); } });
    networkContext();
  };
  // Both clients put the access token and selected media version on their video URL.
  // HLS players expose a Blob; resource timing still identifies that manifest without
  // reading account storage or intercepting the site's fetch implementation.
  const serverState = new WeakMap();
  let gestureAt = -Infinity;
  let serverResource = null;
  const serverSource = (value, headers = {}) => {
    const plex = typeof Thru3DPlex !== 'undefined' && Thru3DPlex.source(value, location.href, headers);
    if (plex) return plex;
    if (!/\/videos\/[^/]+\/(?:stream|original|master|main)/i.test(value)) return null;
    try {
      const url = new URL(value, location.href), page = new URL(location.href);
      // Emby resumes with a media fragment start (#t=seconds) on the original timeline.
      if (/^#t=[0-9.]{1,16}$/.test(url.hash)) url.hash = '';
      const params = new Map([...url.searchParams].map(([k, v]) => [k.toLowerCase(), v]));
      if (url.origin !== page.origin || url.username || url.password || url.hash ||
          !/^.*\/videos\/[a-z0-9-]{1,64}\/(?:(?:stream|original)(?:\.[a-z0-9]+)?|(?:master|main)\.m3u8)$/i.test(url.pathname) ||
          !(params.get('api_key') || params.get('apikey')) || !params.get('mediasourceid') || params.get('livestreamid')) return null;
      return { source: url.href, key: url.pathname.replace(/[^/]+$/, '') + params.get('mediasourceid'),
        // HLS and CopyTimestamps retain the original timeline. Only a progressive
        // transcode starts a fresh zero-based media timeline at StartTimeTicks.
        offset: /\.m3u8$|\/original(?:\.[a-z0-9]+)?$/i.test(url.pathname) || params.get('static')?.toLowerCase() === 'true' || params.get('copytimestamps')?.toLowerCase() === 'true'
          ? 0 : Math.max(0, Number(params.get('starttimeticks') || 0) / 1e7) };
    } catch (_) { return null; }
  };
  addEventListener('pointerdown', (event) => { if (event.isTrusted) gestureAt = performance.now(); }, true);
  if (typeof PerformanceObserver !== 'undefined') {
    const resources = new PerformanceObserver((list) => {
      for (const entry of list.getEntries()) {
        const source = serverSource(entry.name);
        if (source && entry.startTime >= gestureAt && performance.now() - gestureAt < 30000) {
          serverResource = { ...source, at: entry.startTime }; changed();
        }
      }
    });
    resources.observe({ type: 'resource', buffered: false });
  }
  const fullscreen = (element) => {
    const root = document.fullscreenElement;
    return !!root && (root === element || !!root.contains?.(element));
  };
  const send = () => {
    scheduled = false;
    if (closed) return;
    if(redbullEnabled&&!suspended&&!pauseLease&&!document.hidden)discoverRedBullShadow();
    weiboControls?.sync(weiboEnabled);
    if (networkPage !== location.href) {
      if (pauseLease?.page !== location.href) pauseLease = null;
      networkPage = location.href; network = []; mangoChoice=null;mangoData=[];mangoCapture={};weiboChoice = null;tencentChoice=null;tencentData=[];tencentCapture={};tencentShape=[];tencentEnvelopes=[];
      youkuChoice=null;youkuData=[];youkuCapture={};niconicoChoice=null;niconicoData=[];niconicoCapture={};twitchChoice=null;twitchData=[];twitchCapture={};tiktokChoice=null;tiktokCapture={};instagramChoice=null;instagramCapture={};tedChoice=null;tedCapture={};redbullChoice=null;redbullCapture={};streamableChoice=null;streamableCapture={};redditChoice=null;redditCapture={};naverChoice=null;naverCapture={};archiveChoice=null;archiveCapture={};odyseeChoice=null;odyseeCapture={};
      bilibiliData = []; bilibiliInitial = null;
      networkContext(true);
    }
    if (bilibiliEnabled && typeof Thru3DBilibili !== 'undefined' &&
        (bilibiliInitialPage !== location.href || (!bilibiliInitial || !bilibiliInitial.data && !bilibiliData.length || bilibiliInitial.identity.pgc) && Date.now() - bilibiliScanAt >= 1000)) {
      bilibiliInitialPage = location.href; bilibiliScanAt = Date.now();
      bilibiliInitial = Thru3DBilibili.initial(document, location.href);
    }
    const items = [];
    const pageTencent=tencentEnabled?Thru3DTencent.pageState(document.defaultView?.wrappedJSObject,tencentEnvelopes,location.href):{status:0,data:null,shape:[]};
    // A matched current page result supersedes older/prefetched responses, even
    // when its protected or unsupported payload correctly leaves no ready target.
    const tencentRecords=pageTencent.id?(pageTencent.data?[pageTencent.data]:[]):tencentData;
    const currentTencentShape=[{path:'diagnostic.page_state.code',kind:'number',sample:pageTencent.status},
      {path:'diagnostic.observed_envelopes.code',kind:'number',sample:tencentEnvelopes.length},...pageTencent.shape,...tencentShape];
    let bilibiliTarget = null;
    const tencentTargets = [],mangoTargets=[],youkuTargets=[],niconicoTargets=[],twitchTargets=[],tiktokTargets=[],instagramTargets=[],tedTargets=[],redbullTargets=[],streamableTargets=[],redditTargets=[],naverTargets=[],archiveTargets=[],odyseeTargets=[],dailymotionTargets=[],iqiyiTargets=[],douyinTargets=[];
    const pageIqiyi=iqiyiEnabled?Thru3DIqiyi.capture(document.defaultView?.wrappedJSObject,location.href,document):null;
    const live = [...videos.keys()].filter(v => v.isConnected && !v.ended && (v.currentSrc || v.readyState > 0));
    if(niconicoEnabled&&typeof Thru3DNiconicoPlayer!=='undefined'&&typeof Thru3DNiconicoPlayer.declaration==='function'){
      const declared=live.filter(v=>!encrypted.has(v)&&v.videoWidth>0&&Thru3DNiconico.visible(v))
        .map(v=>Thru3DNiconicoPlayer.declaration(v,document)).filter(Boolean);
      const selected=declared.length===1?declared[0]:null;
      if(JSON.stringify(selected)!==JSON.stringify(niconicoRendered)){niconicoRendered=selected;networkContext();}
    }
    const ordered = [...videos].filter(([v])=>{if (v.isConnected) return true; videos.delete(v); return false;});
    if (weiboEnabled || naverEnabled || redditEnabled) {
      const visible = new Map(ordered.map(([v])=>[v,Thru3DWeibo.visible(v)]));
      ordered.sort(([a],[b]) => Number((naverEnabled?naverChoice:redditEnabled?redditChoice:weiboChoice)?.video === b) - Number((naverEnabled?naverChoice:redditEnabled?redditChoice:weiboChoice)?.video === a) || Number(visible.get(b)) - Number(visible.get(a)));
    }
    for (const [video, id] of ordered) {
      if (!video.isConnected) { videos.delete(video); continue; }
      if (items.length >= 16) break;
      const protectedMedia = encrypted.has(video) || !!video.mediaKeys;
      const owner = video.closest?.("dl8-video");
      const server = serverState.get(video);
      const epoch = mediaEpoch.get(video);
      const direct = serverSource(video.currentSrc || '', network.find(c=>c.url === video.currentSrc)?.headers);
      const plexResources = live.length === 1 ? network.filter(c=>c.at >= epoch.since)
        .map(c=>serverSource(c.url,c.headers)).filter(c=>c?.plex) : [];
      const resource = direct || ((video.currentSrc || '').startsWith('blob:') && server &&
        (plexResources.at(-1) || serverResource && (!serverResource.plex || live.length === 1) && serverResource.at >= server.started && serverResource));
      if (server && resource && server.key !== resource.key) {
        server.key = resource.key; videos.set(video, ++nextId);
      }
      // Wait for the start position (resume fragment or seek) to settle before handing it off.
      const serverPlay = !!server?.intent && !!resource && !protectedMedia && video.readyState >= 2 && !video.seeking;
      if (serverPlay) server.offset = Number.isFinite(resource.offset) ? resource.offset : 0;
      const currentSource = video.currentSrc || '';
      const douyinOwner=douyinEnabled&&typeof Thru3DDouyinCurrent!=='undefined'?Thru3DDouyinCurrent.owner(video,location.href):null;
      if(douyinEnabled){
        const identity=[location.href,douyinOwner?.id||'',currentSource].join('|');
        if(epoch.douyinIdentity!==undefined&&epoch.douyinIdentity!==identity){epoch.id=++nextId;epoch.since=Date.now();videos.set(video,nextId);}
        epoch.douyinIdentity=identity;
      }
      const retained = bilibiliOwner?.video === video && bilibiliOwner.page === location.href &&
        bilibiliOwner.source === currentSource && bilibiliOwner.epoch === epoch.id ? bilibiliOwner : null;
      let biliIdentity = typeof Thru3DBilibili !== 'undefined' && Thru3DBilibili.viewIdentity(bilibiliViews, location.href) || bilibiliInitial?.identity || retained?.data;
      // Requests for previews/other parts must not discard the current part's inline
      // response or an already validated response evicted from the bounded API list.
      const bili = bilibiliData.find(d => biliIdentity?.pgc
        ? d.ep === biliIdentity.ep && (!biliIdentity.id.startsWith('ss') || biliIdentity.id === 'ss' + d.season) : d.cid === biliIdentity?.cid) ||
        bilibiliInitial?.data || (retained?.data && biliIdentity && retained.data.id === biliIdentity.id &&
          (biliIdentity?.pgc ? retained.data.ep === biliIdentity.ep : retained.cid === biliIdentity?.cid) ? retained.data : null);
      if (biliIdentity?.pgc && bili?.whole && bili.ep === biliIdentity.ep)
        biliIdentity = {...biliIdentity, cid: bili.cid, aid: bili.aid, expected_duration: bili.duration};
      const biliCid = biliIdentity?.cid;
      const sameVideo = biliIdentity?.pgc || bili?.id === biliIdentity?.id || bili?.id === 'av' + biliIdentity?.aid;
      // Scrolling/hover previews leave additional <video> elements in the page. Bind
      // the full current part, not the number or CSS visibility of those elements.
      // An already verified owner survives reparenting, but never a new source/epoch/CID.
      const matching = !bilibiliEnabled || !bili ? [] : live.filter(v => !encrypted.has(v) && !v.mediaKeys &&
        Math.abs(bili.duration - v.duration) <= Math.max(2, bili.duration * .01));
      const remembered = matching.find(v => bilibiliOwner?.video === v && bilibiliOwner.page === location.href &&
        bilibiliOwner.cid === biliCid && bilibiliOwner.source === v.currentSrc && bilibiliOwner.epoch === mediaEpoch.get(v)?.id);
      const primary = remembered || (matching.length === 1 ? matching[0] : null);
      const mangoPrimary=mangoEnabled?Thru3DMango.owner(mangoData,location.href,live.filter(v=>!encrypted.has(v))):null;
      const niconicoPrimary=niconicoEnabled?Thru3DNiconico.owner(niconicoData,location.href,live.filter(v=>!encrypted.has(v))):null;
      const youkuPrimary=youkuEnabled?Thru3DYouku.owner(youkuData,location.href,live.filter(v=>!encrypted.has(v))):null;
      // Generic MSE capture still requires a single player. Site-bound owners can
      // use exact declared files even when MSE fetches before its loadstart event.
      let requests = protectedMedia || !(networkEnabled || bilibiliEnabled || douyinEnabled || weiboEnabled || tencentEnabled || mangoEnabled || youkuEnabled || niconicoEnabled || twitchEnabled || tiktokEnabled || instagramEnabled || tedEnabled || redbullEnabled || naverEnabled || redditEnabled || streamableEnabled || archiveEnabled || odyseeEnabled || dailymotionEnabled) ? [] : network.filter(c => c.url === currentSource || c.original_url === currentSource ||
        currentSource.startsWith('blob:') && (bilibiliEnabled ? primary === video :
          douyinEnabled ? !!douyinOwner : niconicoEnabled ? niconicoPrimary===video : youkuEnabled ? youkuPrimary===video : mangoEnabled ? mangoPrimary===video&&c.at>=epoch.since : tencentEnabled ? !!video.closest?.('#main-player .txp_videos_container') && c.at >= epoch.since : !weiboEnabled && live.length === 1 && c.at >= epoch.since));
      const tiktokDeclaration=tiktokEnabled&&!protectedMedia?Thru3DTikTok.read(video,location.href):null;
      if(tiktokEnabled)requests=tiktokDeclaration?network.filter(c=>c.kind==='file'&&tiktokDeclaration.urls.includes(c.url)):[];
      if(instagramEnabled)requests=Thru3DInstagram.read(video,location.href)?network.filter(c=>c.kind==='file'):[];
      if(tedEnabled)requests=Thru3DTed.read(video,location.href)?network.filter(c=>c.kind==='hls'||c.kind==='segment'):[];
      if(redbullEnabled)requests=Thru3DRedBull.read(video,document)?network.filter(c=>c.kind==='hls'||c.kind==='segment'):[];
      if(naverEnabled)requests=network.filter(c=>c.kind==='file'||c.kind==='segment');
      if(redditEnabled)requests=Thru3DReddit.read(video,document)?network.filter(c=>c.kind==='file'):[];
      if(streamableEnabled)requests=Thru3DStreamable.read(video,document)?network.filter(c=>c.kind==='file'):[];
      if(archiveEnabled)requests=Thru3DArchive.read(video,document)?network.filter(c=>c.kind==='file'):[];
      if(odyseeEnabled){const declaration=Thru3DOdysee.read(video,document);requests=declaration?network.filter(c=>declaration.binding==='rendered_hls'?['hls','segment'].includes(c.kind):c.kind==='file'):[];}
      if(dailymotionEnabled)requests=Thru3DDailymotion.read(video,document)?network.filter(c=>c.kind==='hls'||c.kind==='segment'):[];
      if(youkuEnabled)requests=requests.filter(c=>c.kind==='hls'&&youkuData.some(d=>d.id===Thru3DYouku.page(location.href)?.id&&d.streams.some(t=>
        Thru3DYouku.sameManifest(t.url,c.url)||Thru3DYouku.sameManifest(t.url,c.original_url))));
      if(niconicoEnabled&&!protectedMedia)requests=network.filter(c=>niconicoPrimary===video&&niconicoData.some(d=>d.id===Thru3DNiconico.page(location.href)&&
        (c.url===d.root||d.variants.some(t=>c.url===t.video||c.url===t.audio||t.resources.includes(c.url)))));
      if(iqiyiEnabled&&!protectedMedia&&pageIqiyi?.ready&&pageIqiyi.src===currentSource)requests=network.filter(c=>Thru3DIqiyi.matches(pageIqiyi,c));
      let weibo = null;
      if (weiboEnabled && !protectedMedia && !currentSource.startsWith('blob:')) {
        const retained = weiboEvidence.get(video);
        if (retained?.connection === networkPort && retained.source === currentSource && retained.epoch === epoch.id)
          requests = [...requests,...retained.requests].filter((r,i,list)=>
            Date.now() - r.at <= 1800000 && list.findIndex(c=>c.url === r.url) === i).slice(0,24);
        weibo = Thru3DWeibo.binding(video,requests);
        if (weibo) weiboEvidence.set(video,{connection:networkPort,source:currentSource,epoch:epoch.id,requests});
      }
      const weiboSelected = !!weibo && weiboChoice?.video === video && weiboChoice.page === weibo.page;
      const biliBinding = !bilibiliEnabled ? 'off' : typeof Thru3DBilibili === 'undefined' ? 'adapter_unavailable' :
        !biliIdentity ? Thru3DBilibili.initialStatus() : protectedMedia ? 'protected' : matching.length > 1 && !primary ? 'multiple_players' :
        !bili ? 'response_cid_missing' : !sameVideo || bili.avid && bili.avid !== biliIdentity.aid ? 'video_id_mismatch' :
        !(biliIdentity.expected_duration > 0) ? 'full_duration_missing' :
        Math.abs(bili.duration - biliIdentity.expected_duration) > Math.max(2, bili.duration * .01) ? 'full_duration_mismatch' :
        primary !== video ? 'other_player' : 'matched';
      const biliMatched = bilibiliEnabled && !protectedMedia && primary === video && bili &&
        sameVideo && bili.cid === biliCid &&
        (!bili.avid || bili.avid === biliIdentity.aid) &&
        biliIdentity.expected_duration > 0 &&
        Math.abs(bili.duration - biliIdentity.expected_duration) <= Math.max(2, bili.duration * .01) &&
        Math.abs(bili.duration - video.duration) <= Math.max(2, video.duration * .01)
          ? { ...bili, ...biliIdentity } : null;
      if (biliMatched) {
        // Discovery is a rolling 24-item list, not the lifetime of a playing stream.
        // Retain only previously verified tracks for this exact owner/part/source;
        // preserve original timestamps and the same 30-minute observation limit.
        const urls = new Set([...biliMatched.video,...biliMatched.audio].flatMap(t => t.urls));
        const seen = new Set();
        requests = [...requests,...(retained?.cid === biliCid ? retained.requests || [] : [])].filter(c => {
          if (!urls.has(c.url) || seen.has(c.url) || (Number.isFinite(c.at) && Date.now() - c.at > 1800000)) return false;
          seen.add(c.url);return true;
        }).slice(0,24);
      }
      const biliReady = !!biliMatched && Thru3DBilibili.ready(biliMatched, requests, video.videoWidth, video.videoHeight);
      if (biliReady) bilibiliOwner = {video, page:location.href, cid:biliCid, source:currentSource, epoch:epoch.id,
        data:biliMatched,requests:requests.filter(c=>Number.isFinite(c.at))};
      if (biliMatched) bilibiliTarget={video,source:currentSource,epoch:epoch.id,key:biliKey(biliMatched),ready:biliReady};
      const biliClicked = biliReady && bilibiliChoice?.video === video && bilibiliChoice.key === biliKey(biliMatched) &&
        bilibiliChoice.source === currentSource && bilibiliChoice.epoch === epoch.id && Date.now() - bilibiliChoice.at < 15000;
      const douyin=douyinEnabled&&!protectedMedia&&typeof Thru3DDouyinCurrent!=='undefined'?Thru3DDouyinCurrent.capture(video,location.href,requests):null;
      const douyinReady=!!douyin;
      if(douyin)douyinTargets.push({video,source:currentSource,epoch:epoch.id,key:douyin.id+':'+douyin.revision,page:douyin.page,owner:douyin.id,active:douyinOwner?.active===true});
      const douyinClicked=!!douyin&&douyinChoice?.video===video&&douyinChoice.source===currentSource&&douyinChoice.epoch===epoch.id&&douyinChoice.key===douyin.id+':'+douyin.revision&&Date.now()-douyinChoice.at<15000;
      const tencent = tencentEnabled && !protectedMedia && typeof Thru3DTencent !== 'undefined' ? Thru3DTencent.binding(video,tencentRecords,requests,location.href) : null;
      if(tencent)tencentTargets.push({video,source:currentSource,epoch:epoch.id,key:tencent.id+':'+tencent.revision,page:tencent.page});
      const tencentClicked=!!tencent&&tencentChoice?.video===video&&tencentChoice.source===currentSource&&tencentChoice.epoch===epoch.id&&
        tencentChoice.key===tencent.id+':'+tencent.revision&&Date.now()-tencentChoice.at<15000;
      const mango=mangoEnabled&&!protectedMedia?Thru3DMango.binding(video,mangoData,requests,location.href,live.filter(v=>!encrypted.has(v))):null;
      if(mango)mangoTargets.push({video,source:currentSource,epoch:epoch.id,key:mango.id+':'+mango.revision,page:mango.page});
      const mangoClicked=!!mango&&mangoChoice?.video===video&&mangoChoice.source===currentSource&&mangoChoice.epoch===epoch.id&&
        mangoChoice.key===mango.id+':'+mango.revision&&Date.now()-mangoChoice.at<15000;
      const youku=youkuEnabled&&!protectedMedia?Thru3DYouku.binding(video,youkuData,requests,location.href,live.filter(v=>!encrypted.has(v))):null;
      if(youku)youkuTargets.push({video,source:currentSource,epoch:epoch.id,key:youku.id+':'+youku.revision,page:youku.page});
      const youkuClicked=!!youku&&youkuChoice?.video===video&&youkuChoice.source===currentSource&&youkuChoice.epoch===epoch.id&&
        youkuChoice.key===youku.id+':'+youku.revision&&Date.now()-youkuChoice.at<15000;
      const twitch=twitchEnabled&&!protectedMedia?Thru3DTwitch.binding(video,twitchData,requests,location.href,live.filter(v=>!encrypted.has(v))):null;
      if(twitch)twitchTargets.push({video,source:currentSource,epoch:epoch.id,key:twitch.id+':'+twitch.revision,page:twitch.page});
      const twitchClicked=!!twitch&&twitchChoice?.video===video&&twitchChoice.source===currentSource&&twitchChoice.epoch===epoch.id&&
        twitchChoice.key===twitch.id+':'+twitch.revision&&Date.now()-twitchChoice.at<15000;
      const tiktokDiagnostics={};
      const tiktok=tiktokEnabled&&!protectedMedia?Thru3DTikTok.binding(video,requests,location.href,live.filter(v=>!encrypted.has(v)),tiktokDiagnostics):null;
      if(tiktok)tiktokTargets.push({video,source:currentSource,epoch:epoch.id,key:tiktok.id+':'+tiktok.revision,page:tiktok.page});
      const tiktokClicked=!!tiktok&&tiktokChoice?.video===video&&tiktokChoice.source===currentSource&&tiktokChoice.epoch===epoch.id&&
        tiktokChoice.key===tiktok.id+':'+tiktok.revision&&Date.now()-tiktokChoice.at<15000;
      const instagram=instagramEnabled&&!protectedMedia?Thru3DInstagram.binding(video,requests,location.href,live.filter(v=>!encrypted.has(v))):null;
      if(instagram)instagramTargets.push({video,source:currentSource,epoch:epoch.id,key:instagram.id+':'+instagram.revision,page:instagram.page,has_audio:instagram.has_audio});
      const instagramClicked=!!instagram&&instagramChoice?.video===video&&instagramChoice.source===currentSource&&instagramChoice.epoch===epoch.id&&
        instagramChoice.key===instagram.id+':'+instagram.revision&&Date.now()-instagramChoice.at<15000;
      const ted=tedEnabled&&!protectedMedia?Thru3DTed.binding(video,requests,location.href,live.filter(v=>!encrypted.has(v))):null;
      if(ted)tedTargets.push({video,source:currentSource,epoch:epoch.id,key:ted.id+':'+ted.revision,page:ted.page});
      const tedClicked=!!ted&&tedChoice?.video===video&&tedChoice.source===currentSource&&tedChoice.epoch===epoch.id&&
        tedChoice.key===ted.id+':'+ted.revision&&Date.now()-tedChoice.at<15000;
      const redbull=redbullEnabled&&!protectedMedia?Thru3DRedBull.binding(video,requests,document,live.filter(v=>!encrypted.has(v))):null;
      if(redbull)redbullTargets.push({video,source:currentSource,epoch:epoch.id,key:redbull.id+':'+redbull.revision,page:redbull.page});
      const redbullClicked=!!redbull&&redbullChoice?.video===video&&redbullChoice.source===currentSource&&redbullChoice.epoch===epoch.id&&
        redbullChoice.key===redbull.id+':'+redbull.revision&&Date.now()-redbullChoice.at<15000;
      const streamable=streamableEnabled&&!protectedMedia?Thru3DStreamable.binding(video,requests,document,live.filter(v=>!encrypted.has(v))):null;
      if(streamable)streamableTargets.push({video,source:currentSource,epoch:epoch.id,key:streamable.id+':'+streamable.revision,page:streamable.page});
      const streamableClicked=!!streamable&&streamableChoice?.video===video&&streamableChoice.source===currentSource&&streamableChoice.epoch===epoch.id&&
        streamableChoice.key===streamable.id+':'+streamable.revision&&Date.now()-streamableChoice.at<15000;
      const reddit=redditEnabled&&!protectedMedia?Thru3DReddit.binding(video,requests,document,live.filter(v=>!encrypted.has(v))):null;
      if(reddit)redditTargets.push({video,source:currentSource,epoch:epoch.id,key:reddit.id+':'+reddit.revision,page:reddit.page});
      const redditClicked=!!reddit&&redditChoice?.video===video&&redditChoice.source===currentSource&&redditChoice.epoch===epoch.id&&
        redditChoice.key===reddit.id+':'+reddit.revision&&Date.now()-redditChoice.at<15000;
      const naver=naverEnabled&&!protectedMedia?Thru3DNaver.binding(video,naverData,requests,document,live.filter(v=>!encrypted.has(v))):null;
      if(naver)naverEvidence.set(video,{...naver,epoch:epoch.id});
      if(naver)naverTargets.push({video,source:currentSource,epoch:epoch.id,key:naver.id+':'+naver.revision,page:naver.page});
      const naverClicked=!!naver&&naverChoice?.video===video&&naverChoice.source===currentSource&&naverChoice.epoch===epoch.id&&
        naverChoice.key===naver.id+':'+naver.revision&&Date.now()-naverChoice.at<15000;
      const archive=archiveEnabled&&!protectedMedia?Thru3DArchive.binding(video,requests,document,live.filter(v=>!encrypted.has(v))):null;
      if(archive)archiveTargets.push({video,source:currentSource,epoch:epoch.id,key:archive.id+':'+archive.revision,page:archive.page});
      const archiveClicked=!!archive&&archiveChoice?.video===video&&archiveChoice.source===currentSource&&archiveChoice.epoch===epoch.id&&
        archiveChoice.key===archive.id+':'+archive.revision&&Date.now()-archiveChoice.at<15000;
      const odysee=odyseeEnabled&&!protectedMedia?Thru3DOdysee.binding(video,requests,document,live.filter(v=>!encrypted.has(v))):null;
      if(odysee)odyseeTargets.push({video,source:currentSource,epoch:epoch.id,key:odysee.id+':'+odysee.revision,page:odysee.page});
      const odyseeClicked=!!odysee&&odyseeChoice?.video===video&&odyseeChoice.source===currentSource&&odyseeChoice.epoch===epoch.id&&
        odyseeChoice.key===odysee.id+':'+odysee.revision&&Date.now()-odyseeChoice.at<15000;
      const dailymotionBinding=dailymotionEnabled&&!protectedMedia?Thru3DDailymotion.binding(video,requests,document,live.filter(v=>!encrypted.has(v)),dailymotionBodies):null;
      const dailymotion=dailymotionBinding&&Thru3DDailymotion.page(dailymotionOwner)===dailymotionBinding.id?dailymotionBinding:null;
      if(dailymotion)dailymotionTargets.push({video,source:currentSource,epoch:epoch.id,key:dailymotion.id+':'+dailymotion.revision,page:dailymotion.page});
      const dailymotionClicked=!!dailymotion&&dailymotionChoice?.video===video&&dailymotionChoice.source===currentSource&&dailymotionChoice.epoch===epoch.id&&
        dailymotionChoice.key===dailymotion.id+':'+dailymotion.revision&&Date.now()-dailymotionChoice.at<15000;
      const niconico=niconicoEnabled&&!protectedMedia?Thru3DNiconico.binding(video,niconicoData,requests,location.href,live.filter(v=>!encrypted.has(v))):null;
      if(niconico)niconicoTargets.push({video,source:currentSource,epoch:epoch.id,key:niconico.id+':'+niconico.revision,page:niconico.page});
      const niconicoClicked=!!niconico&&niconicoChoice?.video===video&&niconicoChoice.source===currentSource&&niconicoChoice.epoch===epoch.id&&
        niconicoChoice.key===niconico.id+':'+niconico.revision&&Date.now()-niconicoChoice.at<15000;
      const iqiyi=iqiyiEnabled&&!protectedMedia?Thru3DIqiyi.binding(video,pageIqiyi):null;
      if(iqiyi)iqiyiTargets.push({video,source:currentSource,epoch:epoch.id,key:iqiyi.id+':'+iqiyi.revision,page:iqiyi.page});
      const iqiyiClicked=!!iqiyi&&iqiyiChoice?.video===video&&iqiyiChoice.source===currentSource&&iqiyiChoice.epoch===epoch.id&&
        iqiyiChoice.key===iqiyi.id+':'+iqiyi.revision&&Date.now()-iqiyiChoice.at<15000;
      items.push({ id: videos.get(video), width: video.videoWidth, height: video.videoHeight,
        fullscreen: fullscreen(video) || !!owner && fullscreen(owner),
        source: !protectedMedia ? (resource ? resource.source : /^https?:\/\//i.test(video.currentSrc || '') ? video.currentSrc : '') : '',
        server_headers: !protectedMedia && resource?.plex ? resource.headers : undefined,
        server_play: serverPlay,
        protected: protectedMedia, frame: location.href, agent: navigator.userAgent,
        network: requests, network_epoch: epoch.id, blob: currentSource.startsWith('blob:'),
        bilibili: biliMatched,
        bilibili_ready: biliReady,
        bilibili_request: biliClicked ? bilibiliChoice.request : 0,
        mango,mango_ready:!!mango,mango_request:mangoClicked?mangoChoice.request:0,
        youku,youku_ready:!!youku,youku_request:youkuClicked?youkuChoice.request:0,
        twitch,twitch_ready:!!twitch,twitch_request:twitchClicked?twitchChoice.request:0,
        tiktok,tiktok_source:tiktok?currentSource:"",tiktok_ended:!!tiktok&&video.ended,tiktok_ready:!!tiktok,tiktok_request:tiktokClicked?tiktokChoice.request:0,
        ...(tiktokEnabled&&!protectedMedia?{tiktok_diagnostics:tiktokDiagnostics}:{}),
        instagram,instagram_source:instagram?currentSource:"",instagram_ended:!!instagram&&video.ended,instagram_ready:!!instagram,instagram_request:instagramClicked?instagramChoice.request:0,
        ted,ted_source:ted?currentSource:"",ted_ready:!!ted,ted_request:tedClicked?tedChoice.request:0,
        redbull,redbull_source:redbull?currentSource:"",redbull_ready:!!redbull,redbull_request:redbullClicked?redbullChoice.request:0,
        naver,naver_source:naver?naver.source:"",naver_ready:!!naver,naver_request:naverClicked?naverChoice.request:0,
        reddit,reddit_source:reddit?currentSource:"",reddit_ready:!!reddit,reddit_request:redditClicked?redditChoice.request:0,
        streamable,streamable_source:streamable?currentSource:"",streamable_ready:!!streamable,streamable_request:streamableClicked?streamableChoice.request:0,
        archive,archive_source:archive?currentSource:"",archive_ready:!!archive,archive_request:archiveClicked?archiveChoice.request:0,
        odysee,odysee_source:odysee?currentSource:"",odysee_ready:!!odysee,odysee_request:odyseeClicked?odyseeChoice.request:0,
        dailymotion,dailymotion_source:dailymotion?currentSource:"",dailymotion_ready:!!dailymotion,dailymotion_request:dailymotionClicked?dailymotionChoice.request:0,
        niconico,niconico_source:niconico?currentSource:undefined,niconico_ready:!!niconico,niconico_request:niconicoClicked?niconicoChoice.request:0,
        iqiyi:iqiyi?Thru3DIqiyi.transport(iqiyi):null,iqiyi_source:iqiyi?currentSource:undefined,iqiyi_ready:!!iqiyi,iqiyi_request:iqiyiClicked?iqiyiChoice.request:0,
        ...(iqiyiEnabled&&!protectedMedia&&typeof Thru3DIqiyi.diagnostics==='function'?{iqiyi_diagnostics:Thru3DIqiyi.diagnostics(video,pageIqiyi)}:{}),
        tencent,tencent_ready:!!tencent,tencent_status:pageTencent.data?'normalized':tencentStatus,tencent_request:tencentClicked?tencentChoice.request:0,
        ...(tencentEnabled ? {tencent_shape:currentTencentShape} : {}),
        ...(tencentEnabled ? {tencent_capture:{...tencentCapture,...pageTencent.capture,metadata:tencentRecords.length,requests:network.length,
          ...Thru3DTencent.diagnostics(performance.getEntriesByType?.('resource') || [],tencentPolicyAt)}} : {}),
        douyin,douyin_source:douyin?currentSource:undefined,
        douyin_ready: douyinReady,douyin_request:douyinClicked?douyinChoice.request:0,
        weibo, weibo_ready: !!weibo, weibo_selected: weiboSelected,
        weibo_request: weiboSelected && Date.now() - weiboChoice.at < 15000 ? weiboChoice.request : 0,
        douyin_diagnostics: douyinDiagnostics && douyinEnabled && typeof Thru3DDouyin !== 'undefined'
          ? {...Thru3DDouyin.diagnostics(douyinData,location.href,video,requests),bound_chars:douyin?JSON.stringify(douyin).length:0} : null,
        douyin_observation: douyinDiagnostics && douyinEnabled ? douyinObservation : null,
        douyin_api_paths: douyinDiagnostics && douyinEnabled ? douyinApiPaths : [],
        douyin_dom: douyinDiagnostics && douyinEnabled ? douyinDomCounts() : null,
        bilibili_status: bilibiliStatus, bilibili_response_api: bilibiliResponseApi,
        bilibili_binding: biliBinding, bilibili_api_count: bilibiliData.length,
        bilibili_view_count: bilibiliViews.length,
        layout: owner?.getAttribute("format") || "",
        time: (Number.isFinite(video.currentTime) ? video.currentTime : 0) + (resource && Number.isFinite(resource.offset) ? resource.offset : 0),
        duration: Number.isFinite(video.duration) ? video.duration : 0,
        playing: !video.paused && !video.ended });
    }
    syncBilibiliButton(bilibiliTarget);
    syncTencentButton(tencentTargets.length===1?tencentTargets[0]:null);
    syncMangoButton(mangoTargets.length===1?mangoTargets[0]:null);
    syncYoukuButton(youkuTargets.length===1?youkuTargets[0]:null);
    syncNiconicoButton(niconicoTargets.length===1?niconicoTargets[0]:null);
    syncTwitchButton(twitchTargets.length===1?twitchTargets[0]:null);
    syncTikTokButton(tiktokTargets.length===1?tiktokTargets[0]:null);
    tiktokCapture={status:tiktokTargets.length?'normalized':'idle',metadata:tiktokTargets.length,bound:tiktokTargets.length};
    syncInstagramButton(instagramTargets.length===1?instagramTargets[0]:null);
    instagramCapture={status:instagramTargets.length?'normalized':'idle',metadata:instagramTargets.length,bound:instagramTargets.length,has_audio:instagramTargets.length===1?instagramTargets[0].has_audio:null};
    syncTedButton(tedTargets.length===1?tedTargets[0]:null);
    syncRedBullButton(redbullTargets.length===1?redbullTargets[0]:null);
    syncRedditButtons(redditTargets);syncNaverButtons(naverTargets);
    syncStreamableButton(streamableTargets.length===1?streamableTargets[0]:null);
    syncArchiveButton(archiveTargets.length===1?archiveTargets[0]:null);
    syncOdyseeButton(odyseeTargets.length===1?odyseeTargets[0]:null);
    tedCapture={status:tedTargets.length?'normalized':'idle',metadata:tedTargets.length,bound:tedTargets.length};
    redbullCapture={status:redbullTargets.length?'normalized':'idle',metadata:redbullTargets.length,bound:redbullTargets.length};
    naverCapture={...naverCapture,status:naverTargets.length?'normalized':'idle',metadata:naverData.length,bound:naverTargets.length,lifecycle:naverNetworkTrace.slice()};
    redditCapture={status:redditTargets.length?'normalized':'idle',metadata:redditTargets.length,bound:redditTargets.length};
    streamableCapture={status:streamableTargets.length?'normalized':'idle',metadata:streamableTargets.length,bound:streamableTargets.length};
    archiveCapture={status:archiveTargets.length?'normalized':'idle',metadata:archiveTargets.length,bound:archiveTargets.length};
    odyseeCapture={status:odyseeTargets.length?'normalized':'idle',metadata:odyseeTargets.length,bound:odyseeTargets.length};
    syncDailymotionButton(dailymotionTargets.length===1?dailymotionTargets[0]:null);
    dailymotionCapture={status:dailymotionTargets.length?'normalized':'idle',metadata:dailymotionTargets.length,bound:dailymotionTargets.length};
    syncIqiyiButton(iqiyiTargets.length===1?iqiyiTargets[0]:null);
    syncDouyinButtons(douyinTargets);
    // A declarative VR player may keep its actual <video> in a closed shadow tree.
    // Read only the same public source the player declares; its media session still
    // acknowledges pause before the native handoff.
    if (!items.some(item => item.source || item.protected)) for (const player of document.querySelectorAll("dl8-video")) {
      if (items.length >= 16) break;
      const source = player.querySelector('source[type="video/mp4"], source[type="video/webm"]');
      if (!source || !/^https?:\/\//i.test(source.src || "")) continue;
      items.push({ id: "declared-" + items.length, width: 0, height: 0, source: source.src,
        fullscreen: fullscreen(player),
        protected: false, frame: location.href, agent: navigator.userAgent,
        layout: source.getAttribute("format") || player.getAttribute("format") || "",
        time: 0, duration: 0, playing: false });
    }
    const controlled = [...videos.keys()].filter(v => v.isConnected && (v.currentSrc || v.readyState > 0));
    const report = { type: "media", videos: items,
      ...(mangoEnabled?{mango_capture:mangoCapture}:{}),
      ...(youkuEnabled?{youku_capture:youkuCapture}:{}),
      ...(niconicoEnabled?{niconico_capture:niconicoCapture}:{}),
      ...(twitchEnabled?{twitch_capture:twitchCapture}:{}),
      ...(tiktokEnabled?{tiktok_capture:tiktokCapture}:{}),
      ...(instagramEnabled?{instagram_capture:instagramCapture}:{}),
      ...(tedEnabled?{ted_capture:tedCapture}:{}),
      ...(redbullEnabled?{redbull_capture:redbullCapture}:{}),
      ...(naverEnabled?{naver_capture:naverCapture}:{}),
      ...(redditEnabled?{reddit_capture:redditCapture}:{}),
      ...(streamableEnabled?{streamable_capture:streamableCapture}:{}),
      ...(archiveEnabled?{archive_capture:archiveCapture}:{}),
      ...(odyseeEnabled?{odysee_capture:odyseeCapture}:{}),
      ...(dailymotionEnabled?{dailymotion_capture:dailymotionCapture}:{}),
      ...(tencentEnabled ? {tencent_capture:{...tencentCapture,...pageTencent.capture,status:pageTencent.data?'normalized':tencentStatus,metadata:tencentRecords.length,requests:network.length}} : {}),
      suspended, pause_token: pauseLease?.token || 0,
      pause_has_media: controlled.length > 0, pause_held: !!pauseLease && controlled.every(v => v.paused || v.ended) };
    try { port.postMessage(iqiyiEnabled ? Thru3DIqiyi.fitMediaReport(report) : report); }
    catch (_) { closed = true; }
  };
  const changed = () => {
    if (scheduled || closed) return;
    scheduled = true;
    setTimeout(send, 250);
  };
  const observe = (root) => {
    if (root.nodeType !== 1 && root.nodeType !== 9 && root.nodeType !== 11) return;
    const found = root.matches?.("video") ? [root] : [];
    found.push(...root.querySelectorAll("video"));
    let added = false;
    for (const video of found) {
      if (videos.has(video)) continue;
      added = true;
      videos.set(video, ++nextId);
      mediaEpoch.set(video, { id: nextId, since: Date.now() - 3000, loaded: !!video.currentSrc || video.readyState > 0 });
      serverState.set(video, { started: typeof performance !== 'undefined' ? performance.now() : 0, intent: false, key: '' });
      video.addEventListener('loadstart', () => {
        const epoch = mediaEpoch.get(video);
        if (epoch.loaded) { epoch.since = Date.now(); epoch.id = ++nextId; videos.set(video, nextId); }
        epoch.loaded = true;
        const state = serverState.get(video);
        state.started = gestureAt; state.intent = !suspended && performance.now() - gestureAt < 30000;
        state.key = ''; holdPaused(video); changed();
      });
      video.addEventListener('play', () => {
        const state = serverState.get(video);
        if (!suspended && !state.restoring) {
          if (state.key && !state.intent) videos.set(video, ++nextId);
          state.intent = true; changed();
        }
      });
      video.addEventListener('pause', () => { if (!suspended) { serverState.get(video).intent = false; changed(); } });
      video.addEventListener('ended', () => { serverState.get(video).intent = false; changed(); });
      video.addEventListener("encrypted", () => { encrypted.add(video); changed(); });
      for (const event of ["loadedmetadata", "resize", "durationchange", "play", "playing", "seeked", "pause", "emptied", "ended", "timeupdate"])
        video.addEventListener(event, changed);
      video.addEventListener("play", () => { if (suspended||keepIqiyiReturnPaused(video)||keepDouyinReturnPaused(video)||keepNiconicoReturnPaused(video)||keepTikTokReturnPaused(video)||keepInstagramReturnPaused(video)||keepTedReturnPaused(video)||keepRedBullReturnPaused(video)||keepStreamableReturnPaused(video)||keepRedditReturnPaused(video)||keepNaverReturnPaused(video)||keepArchiveReturnPaused(video)||keepOdyseeReturnPaused(video)||keepDailymotionReturnPaused(video)) video.pause(); else holdPaused(video); });
      for(const event of ['loadeddata','playing','seeked'])video.addEventListener(event,()=>{if(keepIqiyiReturnPaused(video)||keepDouyinReturnPaused(video)||keepNiconicoReturnPaused(video)||keepTikTokReturnPaused(video)||keepInstagramReturnPaused(video)||keepTedReturnPaused(video)||keepRedBullReturnPaused(video)||keepStreamableReturnPaused(video)||keepRedditReturnPaused(video)||keepNaverReturnPaused(video)||keepArchiveReturnPaused(video)||keepOdyseeReturnPaused(video)||keepDailymotionReturnPaused(video))video.pause();});
      holdPaused(video);
    }
    // Feeds and comments mutate constantly; only a new <video> changes the report.
    if (added) changed();
  };
  const mutation = new MutationObserver((records) => {
    for (const record of records) for (const node of record.addedNodes) observe(node);
  });
  mutation.observe(document, { childList: true, subtree: true });
  observe(document);
  // Web-component players (archive.org and others) keep <video> in a shadow root that neither
  // querySelectorAll nor the document observer reaches. Scanning every mutation for custom
  // elements would cost feed-heavy pages; scan after load and after each user press instead.
  const shadows = new WeakSet();
  const observeShadow = shadow => {
    if(!shadow||shadows.has(shadow))return;
    shadows.add(shadow);
    mutation.observe(shadow,{childList:true,subtree:true});
    observe(shadow);
  };
  // The player may attach its root long after the pointer/load scans. Reuse
  // existing reports to discover this one owned host, without a page-wide timer.
  const discoverRedBullShadow = () => {
    for(const host of document.querySelectorAll('rbup-video-tv-streaming'))if(host.isConnected)observeShadow(host.shadowRoot);
  };
  const scanShadows = (root, depth = 0) => {
    if (closed || depth > 4) return;
    for (const element of root.querySelectorAll("*")) {
      if (!element.localName.includes("-")) continue;
      const shadow = element.openOrClosedShadowRoot || element.shadowRoot;
      if (!shadow) continue;
      observeShadow(shadow);
      scanShadows(shadow, depth + 1);
    }
  };
  for (const delay of [0, 2000, 5000, 10000]) setTimeout(() => scanShadows(document), delay);
  addEventListener("pointerdown", () => setTimeout(() => scanShadows(document), 1000), true);
  const connected = () => {
    closed = false;
    port = browser.runtime.connectNative("thru3d_video");
    const connection = port;
    port.onMessage.addListener((message) => {
    if (message?.action === "network_policy") {
      changed();
      douyinDiagnostics = message.diagnostics === true;
      const douyin = message.douyin === true;
      douyinActionEnabled=douyin;
      if (douyin !== douyinEnabled) { douyinEnabled = douyin; douyinData = []; network = []; networkContext(true); changed(); }
      const bili = message.bilibili === true;
      if (bili !== bilibiliEnabled) {
        bilibiliEnabled = bili; bilibiliData = []; bilibiliViews = []; network = []; bilibiliOwner = null;
        networkContext(true); changed();
      }
      const enabled = message.enabled === true;
      if (tencentPolicyAt === null) tencentPolicyAt = performance.now();
      const tencent = message.tencent === true && typeof Thru3DTencent !== 'undefined' && !!Thru3DTencent.page(location.href);
      if (tencent !== tencentEnabled) { tencentEnabled=tencent;tencentData=[];tencentCapture={};tencentShape=[];tencentEnvelopes=[];network=[];networkContext(true);changed(); }
      const mango=message.mango===true&&typeof Thru3DMango!=='undefined'&&!!Thru3DMango.page(location.href);
      mangoActionEnabled=mango;
      if(mango!==mangoEnabled){mangoEnabled=mango;mangoData=[];mangoCapture={};network=[];networkContext(true);changed();}
      const youku=message.youku===true&&typeof Thru3DYouku!=='undefined'&&!!Thru3DYouku.page(location.href);
      youkuActionEnabled=youku;
      if(youku!==youkuEnabled){youkuEnabled=youku;youkuData=[];youkuCapture={};network=[];networkContext(true);changed();}
      const niconico=message.niconico===true&&typeof Thru3DNiconico!=='undefined'&&Thru3DNiconico.documentPage(location.href);
      niconicoActionEnabled=niconico;
      if(niconico!==niconicoEnabled){niconicoEnabled=niconico;niconicoData=[];niconicoCapture={};network=[];networkContext(true);changed();}
      const twitch=message.twitch===true&&typeof Thru3DTwitch!=='undefined'&&!!Thru3DTwitch.page(location.href);
      twitchActionEnabled=twitch;
      if(twitch!==twitchEnabled){twitchEnabled=twitch;twitchData=[];twitchCapture={};tiktokCapture={};instagramCapture={};tedCapture={};dailymotionBodies=[];dailymotionCapture={};naverData=[];network=[];networkContext(true);changed();}
      const tiktok=message.tiktok===true&&typeof Thru3DTikTok!=='undefined'&&Thru3DTikTok.documentPage(location.href);
      tiktokActionEnabled=tiktok;
      if(tiktok!==tiktokEnabled){tiktokEnabled=tiktok;tiktokCapture={};network=[];networkContext(true);changed();}
      const instagram=message.instagram===true&&typeof Thru3DInstagram!=='undefined'&&Thru3DInstagram.documentPage(location.href);
      instagramActionEnabled=instagram;
      if(instagram!==instagramEnabled){instagramEnabled=instagram;instagramCapture={};network=[];networkContext(true);changed();}
      const ted=message.ted===true&&typeof Thru3DTed!=='undefined'&&Thru3DTed.documentPage(location.href);
      tedActionEnabled=ted;
      if(ted!==tedEnabled){tedEnabled=ted;tedCapture={};network=[];networkContext(true);changed();}
      const redbull=message.redbull===true&&typeof Thru3DRedBull!=='undefined'&&Thru3DRedBull.documentPage(location.href);
      redbullActionEnabled=redbull;
      if(redbull!==redbullEnabled){redbullEnabled=redbull;redbullCapture={};network=[];networkContext(true);changed();}
      const streamable=message.streamable===true&&typeof Thru3DStreamable!=='undefined'&&Thru3DStreamable.documentPage(location.href);
      streamableActionEnabled=streamable;
      if(streamable!==streamableEnabled){streamableEnabled=streamable;streamableCapture={};network=[];networkContext(true);changed();}
      const reddit=message.reddit===true&&typeof Thru3DReddit!=='undefined'&&Thru3DReddit.documentPage(location.href);
      redditActionEnabled=reddit;
      if(reddit!==redditEnabled){redditEnabled=reddit;redditCapture={};network=[];networkContext(true);changed();}
      const naver=message.naver===true&&typeof Thru3DNaver!=='undefined'&&Thru3DNaver.documentPage(location.href);
      naverActionEnabled=naver;
      if(naver!==naverEnabled){naverEnabled=naver;naverCapture={};naverData=[];network=[];networkContext(true);changed();}
      const archive=message.archive===true&&typeof Thru3DArchive!=='undefined'&&Thru3DArchive.documentPage(location.href);
      archiveActionEnabled=archive;
      if(archive!==archiveEnabled){archiveEnabled=archive;archiveCapture={};network=[];networkContext(true);changed();}
      const odysee=message.odysee===true&&typeof Thru3DOdysee!=='undefined'&&Thru3DOdysee.documentPage(location.href);
      odyseeActionEnabled=odysee;
      if(odysee!==odyseeEnabled){odyseeEnabled=odysee;odyseeCapture={};network=[];networkContext(true);changed();}
      const dailymotion=message.dailymotion===true&&typeof Thru3DDailymotion!=='undefined'&&Thru3DDailymotion.frame(location.href)&&Thru3DDailymotion.documentPage(message.dailymotion_owner);
      const dailymotionOwnerChanged=dailymotionOwner!==(dailymotion?message.dailymotion_owner:'');
      dailymotionActionEnabled=dailymotion;dailymotionOwner=dailymotion?message.dailymotion_owner:'';
      if(dailymotion!==dailymotionEnabled){dailymotionEnabled=dailymotion;dailymotionBodies=[];dailymotionCapture={};naverData=[];network=[];networkContext(true);changed();}
      else if(dailymotionOwnerChanged)changed();
      const iqiyi=message.iqiyi===true&&typeof Thru3DIqiyi!=='undefined'&&!!Thru3DIqiyi.page(location.href);
      iqiyiActionEnabled=iqiyi;
      if(iqiyi!==iqiyiEnabled){iqiyiEnabled=iqiyi;networkContext(true);changed();}
      const weibo = message.weibo === true;
      if (weibo !== weiboEnabled) { weiboEnabled = weibo; weiboChoice = null; network = []; networkContext(true); changed(); }
      if (enabled !== networkEnabled) { networkEnabled = enabled; network = []; networkContext(true); changed(); }
      else networkContext();
    } else if (message?.action === "pause_media") {
      const token = message.token;
      if (!Number.isSafeInteger(token) || token <= lastPauseToken) return;
      lastPauseToken = token;
      instagramRestore=null;
      // MediaSession.pause may have completed before this message arrives. Preserve
      // the native snapshot of this port's original playing IDs, not the new pause.
      const ids = Array.isArray(message.playing_ids) ? message.playing_ids.slice(0,16).map(String) : [];
      pauseLease = {token, page:location.href, videos:new Map(), playingIds:new Set(ids)};
      if(niconicoEnabled&&typeof Thru3DNiconicoPlayer!=='undefined'){
        const live=[...videos.keys()].filter(v=>!encrypted.has(v)),main=Thru3DNiconico.owner(niconicoData,location.href,live);
        const target=main&&Thru3DNiconico.binding(main,niconicoData,network,location.href,live);
        if(target)Thru3DNiconicoPlayer.pause(main,target,document);
      }
      for (const video of videos.keys()) holdPaused(video);
      send();
    } else if (message?.action === "release_pause_media") {
      const saved = pauseLease;
      if (!saved || saved.token !== message.token) return;
      pauseLease = null;
      if (message.play === true && !suspended && saved.page === location.href) {
        for (const [video, old] of saved.videos) {
          if (!old.playing || !video.isConnected || video.currentSrc !== old.source || mediaEpoch.get(video)?.id !== old.epoch) continue;
          resuming.set(video, saved.token);
          const completed = () => { if (resuming.get(video) === saved.token) resuming.delete(video); changed(); };
          try { Promise.resolve(video.play()).then(completed, completed); } catch (_) { completed(); }
        }
      }
      send();
    } else if (message?.action === "suspend") {
      instagramRestore=null;
      iqiyiReturnPause=null;douyinReturnPause=null;niconicoReturnPause=null;tiktokReturnPause=null;instagramReturnPause=null;tedReturnPause=null;redbullReturnPause=null;streamableReturnPause=null;redditReturnPause=null;naverReturnPause=null;archiveReturnPause=null;odyseeReturnPause=null;dailymotionReturnPause=null;
      // A retained native handoff keeps the exact original playing-state lease.
      // Ordinary tab/background suspension still releases its temporary hold.
      if(message.keep_pause!==true||message.pause_token!==pauseLease?.token)pauseLease = null;
      suspended = true;
      for (const video of videos.keys()) video.pause();
      send(); // A background page's timer may be throttled after Gecko becomes inactive.
    } else if (message?.action === "resume") {
      // Returning to the browser allows user-initiated playback; never auto-play it.
      suspended = false;
      send();
    } else if (message?.action === "capture_video" && Number.isSafeInteger(message.request) && message.request > 0) {
      const entry = [...videos].find(([, id]) => String(id) === message.id);
      const server = entry && serverState.get(entry[0]);
      handoff = entry && { video: entry[0], source: entry[0].currentSrc, request: message.request,
        serverKey: server?.key || '', offset: server?.offset || 0 };
    } else if (message?.action === "restore_video") {
      const saved = handoff;
      const restored = (retry = false) => {
        retry = retry && !!saved && saved.video.isConnected && saved.source === saved.video.currentSrc &&
          (!saved.serverKey || saved.serverKey === serverState.get(saved.video)?.key);
        try { port.postMessage({ type: "restore_video_result", request: message.request, retry }); } catch (_) {}
      };
      if (!saved || saved.request !== message.request || !saved.video.isConnected || saved.source !== saved.video.currentSrc ||
          saved.serverKey && saved.serverKey !== serverState.get(saved.video)?.key) { restored(); return; }
      handoff = null;
      suspended = false;
      const video = saved.video;
      // The restored page must not hand off again until the next deliberate play.
      const server = serverState.get(video);
      if (server) server.intent = false;
      if (Number.isFinite(message.time) && message.time >= 0) {
        const time = Math.max(0, message.time - saved.offset);
        try { video.currentTime = Number.isFinite(video.duration) ? Math.min(time, video.duration) : time; } catch (_) { /* Live media may not seek. */ }
      }
      if (message.play === true) {
        if (server) server.restoring = true;
        const complete = (retry = false) => { if (server) { server.intent = false; server.restoring = false; } send(); restored(retry); };
        try { Promise.resolve(video.play()).then(() => complete(), () => complete(true)); } catch (_) { complete(true); }
      } else { video.pause(); restored(); }
      send();
    } else if (message?.action === "restore_youku") {
      const video=[...videos].find(([,id])=>String(id)===message.id)?.[0],epoch=video&&mediaEpoch.get(video);
      const target=video&&epoch?.id===message.epoch&&Thru3DYouku.binding(video,youkuData,network,location.href,[...videos.keys()].filter(v=>!encrypted.has(v)));
      if(!target||target.page!==message.page||target.revision!==message.revision)return;
      suspended=false;
      if(Number.isFinite(message.time)&&message.time>=0){try{video.currentTime=Math.min(message.time,video.duration);}catch(_){}}
      if(message.play===true){try{Promise.resolve(video.play()).catch(()=>{});}catch(_){}}
      else video.pause();
      send();
    } else if (message?.action === "restore_niconico") {
      const video=[...videos].find(([,id])=>String(id)===message.id)?.[0],epoch=video&&mediaEpoch.get(video);
      const target=video&&epoch?.id===message.epoch&&Thru3DNiconico.binding(video,niconicoData,network,location.href,[...videos.keys()].filter(v=>!encrypted.has(v)));
      if(!target||target.page!==message.page||target.revision!==message.revision)return;
      if(!Number.isFinite(message.time)||message.time<0)return;
      suspended=false;
      niconicoReturnPause=message.play===true?null:{video,source:video.currentSrc,epoch:epoch.id,page:location.href,owner:target.id,at:Date.now()};
      if(typeof Thru3DNiconicoPlayer!=='undefined'){
        if(!Thru3DNiconicoPlayer.restore(video,target,document,Math.min(message.time,video.duration),message.play===true))niconicoReturnPause=null;
        send();return;
      }
      if(Number.isFinite(message.time)&&message.time>=0){try{video.currentTime=Math.min(message.time,video.duration);}catch(_){}}
      if(message.play===true){try{Promise.resolve(video.play()).catch(()=>{});}catch(_){}}
      else video.pause();
      send();
    } else if (message?.action === "restore_douyin") {
      const video=[...videos].find(([,id])=>String(id)===message.id)?.[0],epoch=video&&mediaEpoch.get(video);
      const target=video&&epoch?.id===message.epoch&&Thru3DDouyinCurrent.capture(video,location.href,network);
      if(!target||target.page!==message.page||target.revision!==message.revision||!Number.isFinite(message.time)||message.time<0)return;
      suspended=false;
      douyinReturnPause=message.play===true?null:{video,source:video.currentSrc,epoch:epoch.id,page:location.href,owner:target.id,at:Date.now()};
      try{video.currentTime=Math.min(message.time,video.duration);}catch(_){douyinReturnPause=null;return;}
      if(message.play===true){try{Promise.resolve(video.play()).catch(()=>{});}catch(_){}}
      else video.pause();
      send();
    } else if (message?.action === "restore_iqiyi") {
      const video=[...videos].find(([,id])=>String(id)===message.id)?.[0],epoch=video&&mediaEpoch.get(video);
      const target=video&&epoch?.id===message.epoch&&Thru3DIqiyi.binding(video,Thru3DIqiyi.capture(document.defaultView?.wrappedJSObject,location.href,document));
      if(!target||target.page!==message.page||target.revision!==message.revision)return;
      suspended=false;
      iqiyiReturnPause=message.play===true?null:{video,source:video.currentSrc,epoch:epoch.id,page:location.href,at:Date.now()};
      if(!Thru3DIqiyi.restore(document.defaultView?.wrappedJSObject,video,target,Math.min(message.time,video.duration),message.play===true))return;
      if(message.play!==true)video.pause();
      send();
    } else if (message?.action === "restore_mango") {
      const video=[...videos].find(([,id])=>String(id)===message.id)?.[0],epoch=video&&mediaEpoch.get(video);
      const target=video&&epoch?.id===message.epoch&&Thru3DMango.binding(video,mangoData,network.filter(c=>c.at>=epoch.since),location.href,[...videos.keys()].filter(v=>!encrypted.has(v)));
      if(!target||target.page!==message.page||target.revision!==message.revision)return;
      suspended=false;
      if(Number.isFinite(message.time)&&message.time>=0){try{video.currentTime=Math.min(message.time,video.duration);}catch(_){}}
      if(message.play===true){try{Promise.resolve(video.play()).catch(()=>{});}catch(_){}}
      else video.pause();
      send();
    } else if (message?.action === "restore_twitch") {
      const entry=[...videos].find(([,id])=>String(id)===message.id),video=entry?.[0];
      const live=[...videos.keys()].filter(v=>!encrypted.has(v));
      const target=video&&Thru3DTwitch.binding(video,twitchData,network,location.href,live);
      if(!target||mediaEpoch.get(video)?.id!==message.epoch||target.page!==message.page)return;
      suspended=false;
      if(Number.isFinite(message.time)&&message.time>=0){try{video.currentTime=Math.min(message.time,video.duration);}catch(_){}}
      if(message.play===true){try{Promise.resolve(video.play()).catch(()=>{});}catch(_){}}else video.pause();
      send();
    } else if (message?.action === "restore_tiktok") {
      const entry=[...videos].find(([,id])=>String(id)===message.id),video=entry?.[0];
      const live=[...videos.keys()].filter(v=>!encrypted.has(v));
      const target=video&&Thru3DTikTok.binding(video,network,location.href,live);
      if(!target||mediaEpoch.get(video)?.id!==message.epoch||target.page!==message.page||target.revision!==message.revision||!Number.isFinite(message.time)||message.time<0)return;
      suspended=false;
      tiktokReturnPause=message.play===true?null:{video,source:video.currentSrc,epoch:message.epoch,page:location.href,owner:target.id,at:Date.now()};
      try{video.currentTime=Math.min(message.time,video.duration);}catch(_){tiktokReturnPause=null;return;}
      if(message.play===true){try{Promise.resolve(video.play()).catch(()=>{});}catch(_){}}else video.pause();
      send();
    } else if (message?.action === "restore_instagram") {
      if(message.page!==location.href||!message.identity||!Number.isFinite(message.time)||message.time<0)return;
      // Instagram can replace an ended video when Gecko becomes active. The
      // original port/document and complete content identity must still agree.
      const pending={page:location.href,deadline:performance.now()+3000};instagramRestore=pending;
      const restore=()=>{
        if(instagramRestore!==pending||closed||suspended||pending.page!==location.href||performance.now()>pending.deadline){if(instagramRestore===pending)instagramRestore=null;return;}
        const live=[...videos.keys()].filter(v=>v.isConnected&&!encrypted.has(v)&&!v.mediaKeys);
        const matches=live.map(video=>({video,target:Thru3DInstagram.binding(video,network,location.href,live)}))
          .filter(v=>Thru3DInstagram.matchesIdentity(v.target,message.identity));
        if(matches.length!==1){setTimeout(restore,50);return;}
        const {video,target}=matches[0],epoch=mediaEpoch.get(video);if(!epoch){setTimeout(restore,50);return;}
        instagramRestore=null;
        instagramReturnPause=message.play===true?null:{video,source:video.currentSrc,epoch:epoch.id,page:location.href,owner:target.id,at:Date.now()};
        try{video.currentTime=Math.min(message.time,video.duration);}catch(_){instagramReturnPause=null;return;}
        if(message.play===true){try{Promise.resolve(video.play()).catch(()=>{});}catch(_){}}else video.pause();
        send();
      };
      restore();
    } else if (message?.action === "restore_ted") {
      const entry=[...videos].find(([,id])=>String(id)===message.id),video=entry?.[0];
      const live=[...videos.keys()].filter(v=>!encrypted.has(v));
      const target=video&&Thru3DTed.binding(video,network,location.href,live);
      if(!target||mediaEpoch.get(video)?.id!==message.epoch||target.page!==message.page||target.revision!==message.revision||!Number.isFinite(message.time)||message.time<0)return;
      suspended=false;
      tedReturnPause=message.play===true?null:{video,source:video.currentSrc,epoch:message.epoch,page:location.href,owner:target.id,at:Date.now()};
      try{video.currentTime=Math.min(message.time,video.duration);}catch(_){tedReturnPause=null;return;}
      if(message.play===true){try{Promise.resolve(video.play()).catch(()=>{});}catch(_){}}else video.pause();
      send();
    } else if (message?.action === "restore_redbull") {
      const entry=[...videos].find(([,id])=>String(id)===message.id),video=entry?.[0];
      const live=[...videos.keys()].filter(v=>!encrypted.has(v));
      const target=video&&Thru3DRedBull.binding(video,network,document,live);
      if(!target||mediaEpoch.get(video)?.id!==message.epoch||target.page!==message.page||target.revision!==message.revision||!Number.isFinite(message.time)||message.time<0)return;
      suspended=false;
      redbullReturnPause=message.play===true?null:{video,source:video.currentSrc,epoch:message.epoch,page:location.href,owner:target.id,at:Date.now()};
      try{video.currentTime=Math.min(message.time,video.duration);}catch(_){redbullReturnPause=null;return;}
      if(message.play===true){try{Promise.resolve(video.play()).catch(()=>{});}catch(_){}}else video.pause();
      send();
    } else if (message?.action === "restore_streamable") {
      const entry=[...videos].find(([,id])=>String(id)===message.id),video=entry?.[0];
      const live=[...videos.keys()].filter(v=>!encrypted.has(v));
      const target=video&&Thru3DStreamable.binding(video,network,document,live);
      if(!target||mediaEpoch.get(video)?.id!==message.epoch||target.page!==message.page||target.revision!==message.revision||!Number.isFinite(message.time)||message.time<0)return;
      suspended=false;
      streamableReturnPause=message.play===true?null:{video,source:video.currentSrc,epoch:message.epoch,page:location.href,owner:target.id,at:Date.now()};
      try{video.currentTime=Math.min(message.time,video.duration);}catch(_){streamableReturnPause=null;return;}
      if(message.play===true){try{Promise.resolve(video.play()).catch(()=>{});}catch(_){}}else video.pause();
      send();
    } else if (message?.action === "restore_reddit") {
      const entry=[...videos].find(([,id])=>String(id)===message.id),video=entry?.[0];
      const live=[...videos.keys()].filter(v=>!encrypted.has(v));
      const target=video&&Thru3DReddit.binding(video,network,document,live);
      if(!target||mediaEpoch.get(video)?.id!==message.epoch||target.page!==message.page||target.revision!==message.revision||!Number.isFinite(message.time)||message.time<0)return;
      suspended=false;
      redditReturnPause=message.play===true?null:{video,source:video.currentSrc,epoch:message.epoch,page:location.href,owner:target.id,at:Date.now()};
      try{video.currentTime=Math.min(message.time,video.duration);}catch(_){redditReturnPause=null;return;}
      if(message.play===true){try{Promise.resolve(video.play()).catch(()=>{});}catch(_){}}else video.pause();
      send();
    } else if (message?.action === "restore_naver") {
      const video=[...videos].find(([,id])=>String(id)===message.id)?.[0],saved=video&&naverEvidence.get(video);
      if(!saved||!video.isConnected||video.currentSrc!==saved.current_source||mediaEpoch.get(video)?.id!==message.epoch||saved.epoch!==message.epoch||
        saved.document!==location.href||saved.page!==message.page||saved.revision!==message.revision||!Number.isFinite(message.time)||message.time<0||video.mediaKeys||encrypted.has(video))return;
      suspended=false;
      naverReturnPause=message.play===true?null:{video,source:video.currentSrc,epoch:message.epoch,page:location.href,at:Date.now()};
      try{video.currentTime=Math.min(message.time,video.duration);}catch(_){naverReturnPause=null;return;}
      if(message.play===true){try{Promise.resolve(video.play()).catch(()=>{});}catch(_){}}else video.pause();
      send();
    } else if (message?.action === "restore_archive") {
      const entry=[...videos].find(([,id])=>String(id)===message.id),video=entry?.[0];
      const live=[...videos.keys()].filter(v=>!encrypted.has(v));
      const target=video&&Thru3DArchive.binding(video,network,document,live);
      if(!target||mediaEpoch.get(video)?.id!==message.epoch||target.page!==message.page||target.revision!==message.revision||!Number.isFinite(message.time)||message.time<0)return;
      suspended=false;
      archiveReturnPause=message.play===true?null:{video,source:video.currentSrc,epoch:message.epoch,page:location.href,owner:target.id,at:Date.now()};
      try{video.currentTime=Math.min(message.time,video.duration);}catch(_){archiveReturnPause=null;return;}
      if(message.play===true){try{Promise.resolve(video.play()).catch(()=>{});}catch(_){}}else video.pause();
      send();
    } else if (message?.action === "restore_odysee") {
      const entry=[...videos].find(([,id])=>String(id)===message.id),video=entry?.[0];
      const live=[...videos.keys()].filter(v=>!encrypted.has(v));
      const target=video&&Thru3DOdysee.binding(video,network,document,live);
      if(!target||mediaEpoch.get(video)?.id!==message.epoch||target.page!==message.page||target.revision!==message.revision||!Number.isFinite(message.time)||message.time<0)return;
      suspended=false;
      odyseeReturnPause=message.play===true?null:{video,source:video.currentSrc,epoch:message.epoch,page:location.href,owner:target.id,at:Date.now()};
      try{video.currentTime=Math.min(message.time,video.duration);}catch(_){odyseeReturnPause=null;return;}
      if(message.play===true){try{Promise.resolve(video.play()).catch(()=>{});}catch(_){}}else video.pause();
      send();
    } else if (message?.action === "restore_dailymotion") {
      const entry=[...videos].find(([,id])=>String(id)===message.id),video=entry?.[0];
      const live=[...videos.keys()].filter(v=>!encrypted.has(v));
      const target=video&&Thru3DDailymotion.binding(video,network,document,live,dailymotionBodies);
      if(!target||mediaEpoch.get(video)?.id!==message.epoch||target.page!==message.page||target.revision!==message.revision||!Number.isFinite(message.time)||message.time<0)return;
      suspended=false;
      dailymotionReturnPause=message.play===true?null:{video,source:video.currentSrc,epoch:message.epoch,page:location.href,owner:target.id,at:Date.now()};
      try{video.currentTime=Math.min(message.time,video.duration);}catch(_){dailymotionReturnPause=null;return;}
      if(message.play===true){try{Promise.resolve(video.play()).catch(()=>{});}catch(_){}}else video.pause();
      send();
    } else if (message?.action === "restore_weibo") {
      const entry = [...videos].find(([,id])=>String(id) === message.id);
      const video = entry?.[0], evidence = video && weiboEvidence.get(video);
      const target = video && Thru3DWeibo.binding(video,evidence?.requests || []);
      if (!video || mediaEpoch.get(video)?.id !== message.epoch || target?.page !== message.page ||
          !evidence || evidence.source !== video.currentSrc) return;
      suspended = false;
      if (Number.isFinite(message.time) && message.time >= 0) {
        try { video.currentTime = Math.min(message.time,video.duration); } catch (_) {}
      }
      if (message.play === true) { try { Promise.resolve(video.play()).catch(()=>{}); } catch (_) {} }
      else video.pause();
      send();
    } else if (message?.action === "snapshot") send();
    });
    port.onDisconnect.addListener(() => { if (port === connection) {
      closed = true; pauseLease = null; weiboChoice = null; bilibiliChoice=null;mangoChoice=null;
      mangoButton?.dispose();mangoButton=null;
      youkuButton?.dispose();youkuButton=null;youkuChoice=null;
      niconicoButton?.dispose();niconicoButton=null;niconicoChoice=null;niconicoReturnPause=null;
      twitchButton?.dispose();twitchButton=null;twitchChoice=null;
      tiktokButton?.dispose();tiktokButton=null;tiktokChoice=null;tiktokReturnPause=null;tedReturnPause=null;redbullReturnPause=null;streamableReturnPause=null;redditReturnPause=null;naverReturnPause=null;archiveReturnPause=null;odyseeReturnPause=null;dailymotionReturnPause=null;
      instagramButton?.dispose();instagramButton=null;instagramChoice=null;instagramReturnPause=null;instagramRestore=null;
      tedButton?.dispose();tedButton=null;tedChoice=null;tedReturnPause=null;redbullReturnPause=null;streamableReturnPause=null;redditReturnPause=null;naverReturnPause=null;archiveReturnPause=null;odyseeReturnPause=null;dailymotionReturnPause=null;
      redbullButton?.dispose();redbullButton=null;redbullChoice=null;redbullReturnPause=null;redbullReturnPause=null;streamableReturnPause=null;redditReturnPause=null;naverReturnPause=null;archiveReturnPause=null;odyseeReturnPause=null;dailymotionReturnPause=null;
      naverControls?.dispose();naverControls=null;naverChoice=null;naverReturnPause=null;naverData=[];
      redditControls?.dispose();redditControls=null;redditChoice=null;redditReturnPause=null;naverReturnPause=null;
      streamableButton?.dispose();streamableButton=null;streamableChoice=null;streamableReturnPause=null;redditReturnPause=null;naverReturnPause=null;
      archiveButton?.dispose();archiveButton=null;archiveChoice=null;archiveReturnPause=null;
      odyseeButton?.dispose();odyseeButton=null;odyseeChoice=null;odyseeReturnPause=null;
      dailymotionButton?.dispose();dailymotionButton=null;dailymotionChoice=null;dailymotionReturnPause=null;dailymotionOwner="";
      iqiyiButton?.dispose();iqiyiButton=null;iqiyiChoice=null;
      iqiyiReturnPause=null;
      douyinReturnPause=null;douyinChoice=null;for(const b of douyinButtons.values())b.dispose();douyinButtons.clear();
      bilibiliButton?.dispose();bilibiliButton=null;
      tencentButton?.dispose();tencentButton=null;tencentChoice=null;
    } });
    changed();
  };
  if (typeof Thru3DWeibo !== 'undefined' && Thru3DWeibo.documentPage(location.href)) {
    addEventListener('scroll',changed,{passive:true,capture:true});
    addEventListener('resize',changed,{passive:true});
    weiboControls = Thru3DWeibo.controls(document,(video,target,request)=>{
      if (closed || suspended || pauseLease || !weiboEnabled) return;
      observe(video);
      weiboChoice = {video,page:target.page,request:request ? ++weiboRequest : 0,at:Date.now()};
      changed();
    });
  }
  if(typeof Thru3DTencent!=='undefined'&&Thru3DTencent.page(location.href)){
    addEventListener('scroll',changed,{passive:true,capture:true});addEventListener('resize',changed,{passive:true});
  }
  connected();
  connectNetwork();
  addEventListener("DOMContentLoaded", () => { bilibiliScanAt = 0; changed(); }, {once:true});
  addEventListener("fullscreenchange", () => { if (!closed) send(); }, true);
  addEventListener("pageshow", (event) => {
    if (event.persisted) { if(!closed){closed=true;port.disconnect();} connected(); networkPort.disconnect(); connectNetwork(); }
  });
  addEventListener("pagehide", (event) => {
    network = []; networkPort.disconnect();
    if (!event.persisted) { handoff = null; mutation.disconnect(); videos.clear(); if(!closed){closed=true;port.disconnect();} }
  });
})();
