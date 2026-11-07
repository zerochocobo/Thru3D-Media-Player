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
  const networkContext = (reset = false) => {
    try { networkPort?.postMessage({ type: "context", page: location.href, enabled: networkEnabled, bilibili: bilibiliEnabled, douyin: douyinEnabled, weibo: weiboEnabled, tencent:tencentEnabled, mango:mangoEnabled, youku:youkuEnabled, reset }); } catch (_) {}
  };
  const mediaEpoch = new WeakMap();
  const connectNetwork = () => {
    network = [];
    tencentData = [];mangoData=[];mangoCapture={};
    youkuData=[];youkuCapture={};
    tencentCapture = {};tencentShape=[];tencentEnvelopes=[];
    douyinData = [];
    bilibiliData = []; bilibiliViews = [];
    networkPort = browser.runtime.connect({ name: "thru3d_network" });
    const connection = networkPort;
    networkPort.onMessage.addListener(message => {
      if (connection !== networkPort || message?.type !== "network" || message.page !== location.href) return;
      network = Array.isArray(message.candidates) ? message.candidates.slice(0, 24) : [];
      douyinData = Array.isArray(message.douyin) ? message.douyin.slice(0,16) : [];
      douyinObservation = message.douyin_observation || {};
      douyinApiPaths = Array.isArray(message.douyin_api_paths) ? message.douyin_api_paths.slice(0,32) : [];
      bilibiliData = Array.isArray(message.bilibili) ? message.bilibili.slice(0, 4) : [];
      bilibiliViews = Array.isArray(message.bilibili_views) ? message.bilibili_views.slice(0, 4) : [];
      mangoData = Array.isArray(message.mango)?message.mango.slice(0,8):[];mangoCapture=message.mango_capture||{};
      youkuData = Array.isArray(message.youku)?message.youku.slice(0,8):[];youkuCapture=message.youku_capture||{};
      tencentData = Array.isArray(message.tencent) ? message.tencent.slice(0,8) : [];
      tencentStatus = message.tencent_status || 'idle';
      tencentCapture = message.tencent_capture || {};
      tencentShape = message.tencent_shape || [];
      tencentEnvelopes = Array.isArray(message.tencent_envelopes)?message.tencent_envelopes.slice(0,8):[];
      bilibiliStatus = message.bilibili_status || 'idle'; bilibiliResponseApi = message.bilibili_response_api === true;
      changed();
    });
    networkPort.onDisconnect.addListener(() => { if (connection === networkPort) { network = []; mangoData=[];mangoCapture={};youkuData=[];youkuCapture={};tencentData = [];tencentCapture={};tencentShape=[];tencentEnvelopes=[]; douyinData = []; bilibiliData = []; bilibiliViews = []; bilibiliInitial = null; changed(); } });
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
    weiboControls?.sync(weiboEnabled);
    if (networkPage !== location.href) {
      if (pauseLease?.page !== location.href) pauseLease = null;
      networkPage = location.href; network = []; mangoChoice=null;mangoData=[];mangoCapture={};weiboChoice = null;tencentChoice=null;tencentData=[];tencentCapture={};tencentShape=[];tencentEnvelopes=[];
      youkuChoice=null;youkuData=[];youkuCapture={};
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
    const tencentTargets = [],mangoTargets=[],youkuTargets=[];
    const live = [...videos.keys()].filter(v => v.isConnected && !v.ended && (v.currentSrc || v.readyState > 0));
    const ordered = [...videos].filter(([v])=>{if (v.isConnected) return true; videos.delete(v); return false;});
    if (weiboEnabled) {
      const visible = new Map(ordered.map(([v])=>[v,Thru3DWeibo.visible(v)]));
      ordered.sort(([a],[b]) => Number(weiboChoice?.video === b) - Number(weiboChoice?.video === a) || Number(visible.get(b)) - Number(visible.get(a)));
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
      const douyinPrimary = douyinEnabled && typeof Thru3DDouyin !== 'undefined'
        ? Thru3DDouyin.owner(douyinData, location.href, live.filter(v=>!encrypted.has(v))) : null;
      const mangoPrimary=mangoEnabled?Thru3DMango.owner(mangoData,location.href,live.filter(v=>!encrypted.has(v))):null;
      const youkuPrimary=youkuEnabled?Thru3DYouku.owner(youkuData,location.href,live.filter(v=>!encrypted.has(v))):null;
      // Generic MSE capture still requires a single player. Site-bound owners can
      // use exact declared files even when MSE fetches before its loadstart event.
      let requests = protectedMedia || !(networkEnabled || bilibiliEnabled || douyinEnabled || weiboEnabled || tencentEnabled || mangoEnabled || youkuEnabled) ? [] : network.filter(c => c.url === currentSource || c.original_url === currentSource ||
        currentSource.startsWith('blob:') && (bilibiliEnabled ? primary === video :
          douyinEnabled ? douyinPrimary === video : youkuEnabled ? youkuPrimary===video : mangoEnabled ? mangoPrimary===video&&c.at>=epoch.since : tencentEnabled ? !!video.closest?.('#main-player .txp_videos_container') && c.at >= epoch.since : !weiboEnabled && live.length === 1 && c.at >= epoch.since));
      if(youkuEnabled)requests=requests.filter(c=>c.kind==='hls'&&youkuData.some(d=>d.id===Thru3DYouku.page(location.href)?.id&&d.streams.some(t=>
        Thru3DYouku.sameManifest(t.url,c.url)||Thru3DYouku.sameManifest(t.url,c.original_url))));
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
      const douyin = douyinEnabled && !protectedMedia && typeof Thru3DDouyin !== 'undefined' &&
        (douyinData.map(d=>Thru3DDouyin.binding(d,location.href,video,requests)).find(Boolean) ||
          Thru3DDouyin.direct(douyinData,location.href,video,requests,douyinObservation));
      const douyinReady = !!douyin && (!currentSource.startsWith('blob:') || !douyin.data.audio?.length || !!douyin.data.observed_audio || douyin.data.observed_muxed === true);
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
        tencent,tencent_ready:!!tencent,tencent_status:pageTencent.data?'normalized':tencentStatus,tencent_request:tencentClicked?tencentChoice.request:0,
        ...(tencentEnabled ? {tencent_shape:currentTencentShape} : {}),
        ...(tencentEnabled ? {tencent_capture:{...tencentCapture,...pageTencent.capture,metadata:tencentRecords.length,requests:network.length,
          ...Thru3DTencent.diagnostics(performance.getEntriesByType?.('resource') || [],tencentPolicyAt)}} : {}),
        douyin: douyin ? {...douyin.data,page:location.href} : null,
        douyin_ready: douyinReady,
        weibo, weibo_ready: !!weibo, weibo_selected: weiboSelected,
        weibo_request: weiboSelected && Date.now() - weiboChoice.at < 15000 ? weiboChoice.request : 0,
        douyin_diagnostics: douyinDiagnostics && douyinEnabled && typeof Thru3DDouyin !== 'undefined'
          ? {...Thru3DDouyin.diagnostics(douyinData,location.href,video,requests),bound_chars:douyin?JSON.stringify({...douyin.data,page:location.href}).length:0} : null,
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
    try { port.postMessage({ type: "media", videos: items,
      ...(mangoEnabled?{mango_capture:mangoCapture}:{}),
      ...(youkuEnabled?{youku_capture:youkuCapture}:{}),
      ...(tencentEnabled ? {tencent_capture:{...tencentCapture,...pageTencent.capture,status:pageTencent.data?'normalized':tencentStatus,metadata:tencentRecords.length,requests:network.length}} : {}),
      suspended, pause_token: pauseLease?.token || 0,
      pause_has_media: controlled.length > 0, pause_held: !!pauseLease && controlled.every(v => v.paused || v.ended) }); }
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
      video.addEventListener("play", () => { if (suspended) video.pause(); else holdPaused(video); });
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
  const scanShadows = (root, depth = 0) => {
    if (closed || depth > 4) return;
    for (const element of root.querySelectorAll("*")) {
      if (!element.localName.includes("-")) continue;
      const shadow = element.openOrClosedShadowRoot || element.shadowRoot;
      if (!shadow) continue;
      if (!shadows.has(shadow)) {
        shadows.add(shadow);
        mutation.observe(shadow, { childList: true, subtree: true });
        observe(shadow);
      }
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
      const weibo = message.weibo === true;
      if (weibo !== weiboEnabled) { weiboEnabled = weibo; weiboChoice = null; network = []; networkContext(true); changed(); }
      if (enabled !== networkEnabled) { networkEnabled = enabled; network = []; networkContext(true); changed(); }
      else networkContext();
    } else if (message?.action === "pause_media") {
      const token = message.token;
      if (!Number.isSafeInteger(token) || token <= lastPauseToken) return;
      lastPauseToken = token;
      // MediaSession.pause may have completed before this message arrives. Preserve
      // the native snapshot of this port's original playing IDs, not the new pause.
      const ids = Array.isArray(message.playing_ids) ? message.playing_ids.slice(0,16).map(String) : [];
      pauseLease = {token, page:location.href, videos:new Map(), playingIds:new Set(ids)};
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
    } else if (message?.action === "restore_mango") {
      const video=[...videos].find(([,id])=>String(id)===message.id)?.[0],epoch=video&&mediaEpoch.get(video);
      const target=video&&epoch?.id===message.epoch&&Thru3DMango.binding(video,mangoData,network.filter(c=>c.at>=epoch.since),location.href,[...videos.keys()].filter(v=>!encrypted.has(v)));
      if(!target||target.page!==message.page||target.revision!==message.revision)return;
      suspended=false;
      if(Number.isFinite(message.time)&&message.time>=0){try{video.currentTime=Math.min(message.time,video.duration);}catch(_){}}
      if(message.play===true){try{Promise.resolve(video.play()).catch(()=>{});}catch(_){}}
      else video.pause();
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
