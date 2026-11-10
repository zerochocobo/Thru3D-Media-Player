/* Passive response discovery. Nothing is injected into the page's JS world, replayed,
 * persisted or logged. Runtime ports are scoped by Gecko's tab/frame sender identity. */
(() => {
  "use strict";
  const frames = new Map(), pending = new Map();
  const TTL = 1800000, MAX = 24, REQUESTS = 256;
  const filter = { urls: ["http://*/*", "https://*/*"] };
  const key = d => `${d.tabId}:${d.frameId}`;
  const oldest = state => ((state.ted||state.redbull||state.streamable||state.archive||state.odysee||state.dailymotionBodies) && [...state.items].find(([,r])=>r.kind==='segment')?.[0]) || state.items.keys().next().value;
  const url = (value, page = false) => {
    try { const u = new URL(value); return /^https?:$/.test(u.protocol) && !u.username && !u.password &&
      (page || !u.hash) && value.length <= 16384 ? u : null; } catch (_) { return null; }
  };
  const header = (list, name) => (list || []).find(h => h.name.toLowerCase() === name)?.value || "";
  const headers = list => {
    const result = {};
    let size = 0;
    for (const h of list || []) {
      const name = h.name.toLowerCase(), value = h.value;
      // In particular, never replay Range/If-Range, hop-by-hop or browser fetch headers.
      if (!/^(user-agent|referer|origin|cookie|authorization|accept|accept-language|x-[a-z0-9-]{1,100})$/.test(name) ||
          typeof value !== "string" || value.length > 8192 || /[\x00-\x1f\x7f]/.test(value)) continue;
      if (Object.keys(result).length >= 24 || (size += value.length) > 24576) return null;
      result[name] = value;
    }
    return result;
  };
  const kind = (u, mime, d, bilibili = false) => {
    if (/mpegurl/.test(mime)) return "hls";
    if (mime === "application/dash+xml") return "dash";
    // A successful HTML/JSON error or API response is not a manifest, even with that suffix.
    if (/^(text\/html|application\/(?:json|problem\+json))$/.test(mime)) return "";
    if (/\.m3u8$/i.test(u.pathname)) return "hls";
    if (/\.mpd$/i.test(u.pathname)) return "dash";
    if (/\.(?:ts|m2ts|aac|mp3|vtt|srt|key)$/i.test(u.pathname)) return "segment";
    if (/\.(?:m4s|cmfv|cmfa)$/i.test(u.pathname) || /(?:^|[/_-])(?:init|segment|chunk)[-_.\d]/i.test(u.pathname))
      return bilibili || /(?:^|\.)bilivideo\.(com|cn)$/.test(u.hostname) && typeof Thru3DBilibili !== 'undefined' && Thru3DBilibili.mediaCid(u.href) ? "file" : "segment";
    if (/^(?:video|audio)\/(?:mp4|webm|x-matroska|quicktime)$/.test(mime) ||
        /\.(?:mp4|m4v|m4a|webm|mkv|mov)$/i.test(u.pathname)) return "file";
    return "";
  };
  const publish = state => {
    const now = Date.now();
    for (const [id, c] of state.items) if (now - c.at > TTL) state.items.delete(id);
    while (JSON.stringify([...state.items.values()]).length > (state.bilibili ? 96 : 192) * 1024) state.items.delete(oldest(state));
    try { state.port.postMessage({ type: "network", page: state.page, candidates: [...state.items.values()],
      naver:[...(state.naverData?.values()||[])],naver_capture:state.naverCapture||{},
      ...(state.dailymotionBodies?{dailymotion_bodies:[...state.dailymotionBodies.values()]}:{}),
      ...(state.dailymotionCapture?{dailymotion_capture:state.dailymotionCapture}:{}),
      bilibili: [...(state.biliResponses?.values() || [])], bilibili_requested: [...(state.biliRequests?.keys() || [])].filter(k => !k.startsWith('view:')),
      bilibili_views: [...(state.biliViews?.values() || [])],
      douyin: [...(state.douyinData?.values() || [])],
      mango: [...(state.mangoData?.values() || [])],mango_capture:{status:state.mangoStatus||'idle',metadata:!!state.mangoMeta,clear:state.mangoMeta?.clear===true,
        id:state.mangoMeta?.id||'',duration:state.mangoMeta?.duration||0,declared_dispatches:state.mangoDeclared?.length||0,manifests:state.mangoManifests?.size||0,
        declared_files:state.mangoFiles?.length||0,
        bound_hls:[...state.items.values()].filter(r=>r.kind==='hls'&&(state.mangoManifests?.has(r.url)||state.mangoManifests?.has(r.original_url))).length},
      niconico:[...(state.niconicoData?.values()||[])],niconico_capture:{status:state.niconicoStatus||'idle',metadata:!!state.niconicoMeta,master:!!state.niconicoMaster,leaves:state.niconicoLeaves?.size||0,bound:state.niconicoData?.size||0},
      twitch:[...(state.twitchData?.values()||[])],twitch_capture:{status:state.twitchStatus||'idle',metadata:state.twitchMeta?.size||0,bound:state.twitchData?.size||0,...state.twitchCounters},
      youku:[...(state.youkuData?.values()||[])],youku_capture:{status:state.youkuStatus||'idle',metadata:!!state.youkuMeta,
        id:state.youkuMeta?.id||'',duration:state.youkuMeta?.duration||0,declared_streams:state.youkuMeta?.streams.length||0,
        bound_hls:[...(state.youkuData?.values()||[])].reduce((n,d)=>n+d.manifests.length,0)},
      tencent: [...(state.tencentData?.values() || [])], tencent_envelopes:[...(state.tencentEnvelopes?.values()||[])],tencent_status: state.tencentStatus || 'idle',tencent_capture:state.tencentCapture||{},tencent_shape:state.tencentShape||[],
      douyin_observation: state.douyinObservation || {},
      douyin_api_paths: [...(state.douyinApiPaths || [])],
      bilibili_status: state.biliStatus || 'idle', bilibili_response_api: typeof browser.webRequest.filterResponseData === 'function' }); } catch (_) {}
  };
  browser.runtime.onConnect.addListener(port => {
    const s = port.sender;
    if (port.name !== "thru3d_network" || s?.id !== browser.runtime.id || !Number.isInteger(s.tab?.id) ||
        s.tab.id < 0 || !Number.isInteger(s.frameId) || !url(s.url, true)) return;
    const id = `${s.tab.id}:${s.frameId}`;
    const state = { key:id, port, page: s.url, parentPage:s.tab.url, documentPage: s.url, document: s.documentId, enabled: false, bilibili: false,
      douyin: typeof Thru3DDouyin !== 'undefined' && Thru3DDouyin.documentPage(s.url),
      weibo: typeof Thru3DWeibo !== 'undefined' && Thru3DWeibo.documentPage(s.url),
      tencent: typeof Thru3DTencent !== 'undefined' && !!Thru3DTencent.page(s.url),
      mango: typeof Thru3DMango !== 'undefined' && !!Thru3DMango.page(s.url),
      youku: typeof Thru3DYouku !== 'undefined' && !!Thru3DYouku.page(s.url),
      niconico: typeof Thru3DNiconico !== 'undefined' && s.frameId===0 && Thru3DNiconico.documentPage(s.url),
      twitch: typeof Thru3DTwitch !== 'undefined' && s.frameId===0 && !!Thru3DTwitch.page(s.url),
      tiktok: typeof Thru3DTikTok !== 'undefined' && s.frameId===0 && Thru3DTikTok.documentPage(s.url),
      instagram: typeof Thru3DInstagram !== 'undefined' && s.frameId===0 && Thru3DInstagram.documentPage(s.url),
      ted: typeof Thru3DTed !== 'undefined' && s.frameId===0 && Thru3DTed.documentPage(s.url),
      redbull: typeof Thru3DRedBull !== 'undefined' && s.frameId===0 && Thru3DRedBull.documentPage(s.url),
      streamable: typeof Thru3DStreamable !== 'undefined' && s.frameId===0 && Thru3DStreamable.documentPage(s.url),
      reddit: typeof Thru3DReddit !== 'undefined' && s.frameId===0 && Thru3DReddit.documentPage(s.url),
      naver: typeof Thru3DNaver !== 'undefined' && s.frameId===0 && Thru3DNaver.documentPage(s.url),
      archive: typeof Thru3DArchive !== 'undefined' && s.frameId===0 && Thru3DArchive.documentPage(s.url),
      odysee: typeof Thru3DOdysee !== 'undefined' && s.frameId===0 && Thru3DOdysee.documentPage(s.url),
      dailymotion:typeof Thru3DDailymotion!=='undefined'&&Thru3DDailymotion.frame(s.url)&&Thru3DDailymotion.documentPage(s.tab.url),
      iqiyi: typeof Thru3DIqiyi !== 'undefined' && !!Thru3DIqiyi.page(s.url),
      privateContext: s.tab.incognito === true, cookieStore: typeof s.tab.cookieStoreId === 'string' ? s.tab.cookieStoreId : '',
      items: new Map(), timer: null };
    const old = frames.get(id);
    if (old) { clearTimeout(old.timer); old.port.disconnect(); }
    frames.set(id, state);
    if(state.tencent)tencentResponses?.attach(state);
    if(state.mango)mangoResponses?.attach(state);
    if(state.youku)youkuResponses?.attach(state);
    if(state.niconico)niconicoResponses?.attach(state);
    if(state.twitch)twitchResponses?.attach(state);
    if(state.douyin)douyinResponses?.restore(state);
    while (frames.size > 64) { const oldest = frames.keys().next().value; frames.get(oldest).port.disconnect(); frames.delete(oldest); }
    port.onMessage.addListener(message => {
      if (frames.get(id) !== state || message?.type !== "context" || !url(message.page, true) ||
          new URL(message.page).origin !== new URL(s.url).origin) return;
      const bili = message.bilibili === true && typeof Thru3DBilibili !== 'undefined' && !!Thru3DBilibili.page(message.page);
      const douyin = message.douyin === true && typeof Thru3DDouyin !== 'undefined' && Thru3DDouyin.documentPage(message.page);
      const weibo = message.weibo === true && typeof Thru3DWeibo !== 'undefined' && Thru3DWeibo.documentPage(message.page);
      const tencent = message.tencent === true && typeof Thru3DTencent !== 'undefined' && !!Thru3DTencent.page(message.page);
      const mango = message.mango === true && typeof Thru3DMango !== 'undefined' && !!Thru3DMango.page(message.page);
      const youku = message.youku === true && typeof Thru3DYouku !== 'undefined' && !!Thru3DYouku.page(message.page);
      const niconico = message.niconico === true && s.frameId===0 && typeof Thru3DNiconico !== 'undefined' && Thru3DNiconico.documentPage(message.page);
      const iqiyi = message.iqiyi === true && typeof Thru3DIqiyi !== 'undefined' && !!Thru3DIqiyi.page(message.page);
      const twitch = message.twitch === true && s.frameId===0 && typeof Thru3DTwitch !== 'undefined' && !!Thru3DTwitch.page(message.page);
      const tiktok = message.tiktok === true && s.frameId===0 && typeof Thru3DTikTok !== 'undefined' && Thru3DTikTok.documentPage(message.page);
      const instagram = message.instagram === true && s.frameId===0 && typeof Thru3DInstagram !== 'undefined' && Thru3DInstagram.documentPage(message.page);
      const ted = message.ted === true && s.frameId===0 && typeof Thru3DTed !== 'undefined' && Thru3DTed.documentPage(message.page);
      const redbull = message.redbull === true && s.frameId===0 && typeof Thru3DRedBull !== 'undefined' && Thru3DRedBull.documentPage(message.page);
      const streamable = message.streamable === true && s.frameId===0 && typeof Thru3DStreamable !== 'undefined' && Thru3DStreamable.documentPage(message.page);
      const reddit = message.reddit === true && s.frameId===0 && typeof Thru3DReddit !== 'undefined' && Thru3DReddit.documentPage(message.page);
      const naver = message.naver === true && s.frameId===0 && typeof Thru3DNaver !== 'undefined' && Thru3DNaver.documentPage(message.page);
      const archive = message.archive === true && s.frameId===0 && typeof Thru3DArchive !== 'undefined' && Thru3DArchive.documentPage(message.page);
      const odysee = message.odysee === true && s.frameId===0 && typeof Thru3DOdysee !== 'undefined' && Thru3DOdysee.documentPage(message.page);
      const dailymotion=message.dailymotion===true&&typeof Thru3DDailymotion!=='undefined'&&Thru3DDailymotion.frame(message.page)&&Thru3DDailymotion.documentPage(state.parentPage);
      if (message.page !== state.page || message.reset === true || (message.enabled === true) !== state.enabled || bili !== state.bilibili || douyin !== state.douyin || weibo !== state.weibo || tencent !== state.tencent || mango !== state.mango || youku !== state.youku || iqiyi !== state.iqiyi || niconico !== state.niconico || twitch !== state.twitch || tiktok !== state.tiktok || instagram !== state.instagram || ted !== state.ted || redbull !== state.redbull || naver !== state.naver || reddit !== state.reddit || streamable !== state.streamable || archive !== state.archive || odysee !== state.odysee || dailymotion!==state.dailymotion) {
        // Bilibili can preload the next part before pushState. Retain only this document's
        // bounded observations; the content script must bind CID to the current part map.
        const sameBili = bili && state.bilibili && Thru3DBilibili.sameDocumentPage(message.page, state.page);
        const sameDouyin = douyin && state.douyin;
        const sameTencent = tencent && state.tencent;
        const sameMango = mango && state.mango && Thru3DMango.page(message.page)?.id===Thru3DMango.page(state.page)?.id;
        const sameYouku = youku && state.youku && Thru3DYouku.page(message.page)?.id===Thru3DYouku.page(state.page)?.id;
        const sameNiconico=niconico&&state.niconico; // Same owned port/document; graphs remain keyed by actual API video ID.
        const sameTikTok=tiktok&&state.tiktok; // Same owned port/document; current React ID and exact file bind each card.
        const sameInstagram=instagram&&state.instagram; // Same owned port/document; current React ID and exact file bind each card.
        const sameTed=ted&&state.ted; // Same owned port/document; current React ID and exact file bind each card.
        const sameRedBull=redbull&&state.redbull; // Same owned port/document; current React ID and exact file bind each card.
        const sameStreamable=streamable&&state.streamable; // Same owned document; canonical item and exact declared file bind the player.
        const sameReddit=reddit&&state.reddit; // Same owned document; canonical item and exact declared file bind the player.
        const sameNaver=naver&&state.naver; // Same owned document; canonical item and exact declared file bind the player.
        const sameArchive=archive&&state.archive; // Same owned document; canonical item and exact declared file bind the player.
        const sameOdysee=odysee&&state.odysee; // Same owned document; canonical item and exact declared file bind the player.
        const sameDailymotion=dailymotion&&state.dailymotion&&message.page===state.page;
        const sameIqiyi = iqiyi && state.iqiyi && Thru3DIqiyi.page(message.page)?.id===Thru3DIqiyi.page(state.page)?.id;
        const sameTwitch=twitch&&state.twitch&&Thru3DTwitch.page(message.page)===Thru3DTwitch.page(state.page)&&
          new URL(message.page).origin===new URL(state.page).origin;
        if (!sameBili) { responses?.cancel(state); state.biliStatus = 'idle'; state.biliResponses = new Map(); state.biliRequests = new Map(); state.biliViews = new Map(); }
        if (!sameDouyin) { douyinResponses?.cancel(state); state.douyinData = new Map(); state.douyinApiPaths = new Set(); }
        if (!sameTencent) { tencentResponses?.cancel(state); state.tencentData = new Map();state.tencentEnvelopes=new Map(); }
        if (!sameMango) mangoResponses?.cancel(state);
        if (!sameYouku) youkuResponses?.cancel(state);
        if (!sameNiconico) niconicoResponses?.cancel(state);
        if (!sameTwitch) twitchResponses?.cancel(state);
        if (!sameNaver) naverResponses?.cancel(state);
        if (!sameBili && !sameDouyin && !sameTencent && !sameMango && !sameYouku && !sameIqiyi && !sameNiconico && !sameTwitch && !sameTikTok && !sameInstagram && !sameTed && !sameRedBull && !sameNaver && !sameReddit && !sameStreamable && !sameArchive && !sameOdysee && !sameDailymotion) state.items.clear();
        state.bilibili = bili;
        state.douyin = douyin;
        state.weibo = weibo;
        state.tencent = tencent;
        state.mango = mango;
        state.youku = youku;state.iqiyi=iqiyi;state.niconico=niconico;state.twitch=twitch;state.tiktok=tiktok;state.instagram=instagram;state.ted=ted;state.redbull=redbull;state.naver=naver;state.reddit=reddit;state.streamable=streamable;state.archive=archive;state.odysee=odysee;
        if(message.page!==state.page||message.enabled!==true&&message.dailymotion!==true)dailymotionResponses?.cancel(state);
        state.page = message.page; state.enabled = message.enabled === true;state.dailymotion=dailymotion;
        if(sameNiconico)niconicoResponses?.observeMedia(state);
        if (!sameBili && !sameDouyin && !sameTencent && !sameMango && !sameYouku && !sameIqiyi && !sameNiconico && !sameTwitch && !sameTikTok && !sameInstagram && !sameTed && !sameRedBull && !sameNaver && !sameReddit && !sameStreamable && !sameArchive && !sameOdysee && !sameDailymotion) for (const [request, value] of pending) if (value.state === state) pending.delete(request);
        publish(state);
      }
      if(state.niconico)niconicoResponses?.observeRendered(state,message.niconico_rendered);
    });
    port.onDisconnect.addListener(() => {
      responses?.cancel(state);
      douyinResponses?.cancel(state);
      tencentResponses?.cancel(state);
      mangoResponses?.cancel(state);
      youkuResponses?.cancel(state);
      niconicoResponses?.cancel(state);
      twitchResponses?.cancel(state);
      dailymotionResponses?.cancel(state);naverResponses?.cancel(state);
      clearTimeout(state.timer);
      if (frames.get(id) === state) frames.delete(id);
      for (const [request, value] of pending) if (value.state === state) pending.delete(request);
    });
    if(state.douyin&&state.douyinData?.size)publish(state);
  });
  const stateFor = d => {
    const state = frames.get(key(d));
    const sameBili = state?.bilibili && typeof Thru3DBilibili !== 'undefined' &&
      Thru3DBilibili.sameDocumentPage(d.documentUrl, state.page) &&
      (d.documentId && state.document || d.documentUrl?.split('#')[0] === state.documentPage.split('#')[0]);
    const sameDouyin = state?.douyin && typeof Thru3DDouyin !== 'undefined' && Thru3DDouyin.documentPage(d.documentUrl) &&
      (d.documentId && state.document || d.documentUrl?.split('#')[0] === state.documentPage.split('#')[0]);
    const plex = state && typeof Thru3DPlex !== 'undefined' && Thru3DPlex.address(d.url, state.page);
    const sameWeibo = state?.weibo && typeof Thru3DWeibo !== 'undefined' && Thru3DWeibo.documentPage(d.documentUrl) &&
      (d.documentId && state.document || d.documentUrl?.split('#')[0] === state.documentPage.split('#')[0]);
    const sameTencent = state?.tencent && typeof Thru3DTencent !== 'undefined' && Thru3DTencent.page(d.documentUrl) &&
      (d.documentId && state.document || d.documentUrl?.split('#')[0] === state.documentPage.split('#')[0]);
    const sameMango = state?.mango && typeof Thru3DMango !== 'undefined' && Thru3DMango.page(d.documentUrl)?.id===Thru3DMango.page(state.page)?.id &&
      (d.documentId && state.document || d.documentUrl?.split('#')[0] === state.documentPage.split('#')[0]);
    const sameYouku = state?.youku && typeof Thru3DYouku !== 'undefined' && !!Thru3DYouku.page(d.documentUrl) &&
      (d.documentId && state.document || d.documentUrl?.split('#')[0] === state.documentPage.split('#')[0]);
    const sameNiconico=state?.niconico&&d.frameId===0&&typeof Thru3DNiconico!=='undefined'&&Thru3DNiconico.documentPage(d.documentUrl)&&
      (d.documentId&&state.document||d.documentUrl?.split('#')[0]===state.documentPage.split('#')[0]);
    // Twitch removes tracking query parameters using replaceState. Gecko keeps
    // the original document URL; the same public clip AND document UUID bind it.
    const sameTwitch=state?.twitch&&d.frameId===0&&typeof Thru3DTwitch!=='undefined'&&
      !!Thru3DTwitch.page(d.documentUrl)&&Thru3DTwitch.page(d.documentUrl)===Thru3DTwitch.page(state.page)&&
      !!d.documentId&&d.documentId===state.document;
    const sameTikTok=state?.tiktok&&d.frameId===0&&typeof Thru3DTikTok!=='undefined'&&Thru3DTikTok.documentPage(d.documentUrl)&&
      (d.documentId&&state.document||d.documentUrl?.split('#')[0]===state.documentPage.split('#')[0]);
    const sameInstagram=state?.instagram&&d.frameId===0&&typeof Thru3DInstagram!=='undefined'&&Thru3DInstagram.documentPage(d.documentUrl)&&
      (d.documentId&&state.document||d.documentUrl?.split('#')[0]===state.documentPage.split('#')[0]);
    const sameTed=state?.ted&&d.frameId===0&&typeof Thru3DTed!=='undefined'&&Thru3DTed.documentPage(d.documentUrl)&&
      (d.documentId&&state.document||d.documentUrl?.split('#')[0]===state.documentPage.split('#')[0]);
    const sameRedBull=state?.redbull&&d.frameId===0&&typeof Thru3DRedBull!=='undefined'&&Thru3DRedBull.documentPage(d.documentUrl)&&
      (d.documentId&&state.document||d.documentUrl?.split('#')[0]===state.documentPage.split('#')[0]);
    const sameStreamable=state?.streamable&&d.frameId===0&&typeof Thru3DStreamable!=='undefined'&&Thru3DStreamable.documentPage(d.documentUrl)&&
      (d.documentId&&state.document||d.documentUrl?.split('#')[0]===state.documentPage.split('#')[0]);
    const sameReddit=state?.reddit&&d.frameId===0&&typeof Thru3DReddit!=='undefined'&&Thru3DReddit.documentPage(d.documentUrl)&&
      (d.documentId&&state.document||d.documentUrl?.split('#')[0]===state.documentPage.split('#')[0]);
    const sameNaver=state?.naver&&d.frameId===0&&typeof Thru3DNaver!=='undefined'&&Thru3DNaver.documentPage(d.documentUrl)&&
      (d.documentId&&state.document||d.documentUrl?.split('#')[0]===state.documentPage.split('#')[0]);
    const sameArchive=state?.archive&&d.frameId===0&&typeof Thru3DArchive!=='undefined'&&Thru3DArchive.documentPage(d.documentUrl)&&
      (d.documentId&&state.document||d.documentUrl?.split('#')[0]===state.documentPage.split('#')[0]);
    const sameOdysee=state?.odysee&&d.frameId===0&&typeof Thru3DOdysee!=='undefined'&&Thru3DOdysee.documentPage(d.documentUrl)&&
      (d.documentId&&state.document||d.documentUrl?.split('#')[0]===state.documentPage.split('#')[0]);
    const sameIqiyi = state?.iqiyi && typeof Thru3DIqiyi !== 'undefined' && !!Thru3DIqiyi.page(d.documentUrl) &&
      (d.documentId && state.document || d.documentUrl?.split('#')[0] === state.documentPage.split('#')[0]);
    if (!state || !(state.enabled || state.bilibili || state.douyin || state.weibo || state.tencent || state.mango || state.youku || state.iqiyi || state.niconico || state.twitch || state.tiktok || state.instagram || state.ted || state.redbull || state.naver || state.reddit || state.streamable || state.archive || state.odysee || state.dailymotion || plex) || d.tabId < 0 || (d.documentId && state.document && d.documentId !== state.document) ||
        (d.documentUrl && d.documentUrl.split('#')[0] !== state.page.split('#')[0] && !sameBili && !sameDouyin && !sameWeibo && !sameTencent && !sameMango && !sameYouku && !sameIqiyi && !sameNiconico && !sameTwitch && !sameTikTok && !sameInstagram && !sameTed && !sameRedBull && !sameNaver && !sameReddit && !sameStreamable && !sameArchive && !sameOdysee)) return null;
    return state;
  };
  const responses = typeof Thru3DBilibiliResponses === 'undefined' ? null : Thru3DBilibiliResponses(stateFor, publish);
  const tencentResponses = typeof Thru3DTencentResponses === 'undefined' ? null : Thru3DTencentResponses(stateFor,publish,d=>frames.has(key(d)));
  const mangoResponses = typeof Thru3DMangoResponses === 'undefined' ? null : Thru3DMangoResponses(stateFor,publish,d=>frames.has(key(d)));
  const youkuResponses = typeof Thru3DYoukuResponses === 'undefined' ? null : Thru3DYoukuResponses(stateFor,publish,d=>frames.has(key(d)));
  const niconicoResponses=typeof Thru3DNiconicoResponses==='undefined'?null:Thru3DNiconicoResponses(stateFor,publish,d=>frames.has(key(d)));
  const twitchResponses=typeof Thru3DTwitchResponses==='undefined'?null:Thru3DTwitchResponses(stateFor,publish,d=>frames.has(key(d)));
  const naverResponses=typeof Thru3DNaverResponses==='undefined'?null:Thru3DNaverResponses(stateFor,publish);
  const dailymotionResponses=typeof Thru3DDailymotionResponses==='undefined'?null:Thru3DDailymotionResponses(stateFor,publish);
  // Metadata is only a hint; it never supplies request credentials. Gecko can
  // attribute the site's prefetch/worker API to frame -1 or to the original SPA
  // document URL. Keep file-request ownership on the strict stateFor path above.
  const douyinMetadataState = d => {
    const direct=stateFor(d);if(direct)return direct;
    // Firefox service/shared workers have no tab/frame identity. Only their known
    // detail response can supply metadata to one exact current content owner.
    // File requests continue to use stateFor above and never inherit this scope.
    if (d.tabId === -1 && d.frameId === -1) {
      const request = url(d.url);
      const origins = [d.documentUrl, d.originUrl].filter(Boolean);
      if (d.method !== 'GET' || d.parentFrameId != null && d.parentFrameId !== -1 ||
          !(typeof Thru3DDouyin !== 'undefined' && Thru3DDouyin.address(d.url)) || request?.pathname !== '/aweme/v1/web/aweme/detail/' ||
          typeof Thru3DDouyin === 'undefined' || typeof d.incognito !== 'boolean' ||
          !origins.length || origins.some(value => !Thru3DDouyin.documentPage(value))) return null;
      const ids = request.searchParams.getAll('aweme_id');
      if (ids.length !== 1 || !/^[1-9][0-9]{14,19}$/.test(ids[0])) return null;
      const owners = [...frames.values()].filter(state => state.douyin && state.key.endsWith(':0') &&
        state.privateContext === d.incognito && (!state.cookieStore || !d.cookieStoreId || state.cookieStore === d.cookieStoreId) &&
        Thru3DDouyin.page(state.page)?.id === ids[0]);
      return owners.length === 1 ? owners[0] : null;
    }
    const state=frames.get(`${d.tabId}:${d.frameId<0?0:d.frameId}`);
    if(!state?.douyin||typeof Thru3DDouyin==='undefined'||
      !(Thru3DDouyin.documentPage(d.documentUrl)||Thru3DDouyin.documentPage(d.originUrl))||
      d.frameId>=0&&d.documentId&&state.document&&d.documentId!==state.document)return null;
    return state;
  };
  const douyinResponses = typeof Thru3DDouyinResponses === 'undefined' ? null : Thru3DDouyinResponses(douyinMetadataState,publish,d=>frames.has(key(d)));
  const transportRequest=d=>{
    const state=stateFor(d);
    if(state?.naver&&typeof Thru3DNaver!=='undefined'){
      const target=Thru3DNaver.resource(d.url)?.source;if(!target)return d;
      return {...d,url:target,request_url:d.url,redirectUrl:d.redirectUrl?Thru3DNaver.resource(d.redirectUrl)?.source||d.redirectUrl:d.redirectUrl};
    }
    if(typeof Thru3DDailymotion==='undefined'||!state?.dailymotion)return d;
    const target=Thru3DDailymotion.transport(d.url);if(!target)return d;
    return {...d,url:target,request_url:d.url,redirectUrl:d.redirectUrl?Thru3DDailymotion.transport(d.redirectUrl)||d.redirectUrl:d.redirectUrl};
  };
  browser.webRequest.onBeforeRequest.addListener(d => {
    if (d.type !== "main_frame" && d.type !== "sub_frame") return;
    tencentResponses?.navigate(d);
    mangoResponses?.navigate(d);
    youkuResponses?.navigate(d);
    niconicoResponses?.navigate(d);
    twitchResponses?.navigate(d);
    for (const [id, state] of frames) if (id === key(d) || d.type === "main_frame" && id.startsWith(`${d.tabId}:`)) {
      state.port.disconnect(); frames.delete(id);
    }
  }, filter);
  browser.webRequest.onSendHeaders.addListener(d => {
    d=transportRequest(d);
    const state = stateFor(d);
    if (!state || d.method !== "GET" || !["media", "xmlhttprequest", "other"].includes(d.type) || !url(d.url)) return;
    const safe = headers(d.requestHeaders);
    if (!safe) return;
    const previous = pending.get(d.requestId);
    pending.set(d.requestId, { state, url: d.url, original: previous?.state === state ? previous.original : d.url, headers: safe, sent: true, at: Date.now() });
    for (const [id, p] of pending) if (Date.now() - p.at > 30000) pending.delete(id);
    while (pending.size > REQUESTS) pending.delete(pending.keys().next().value);
  }, filter, ["requestHeaders"]);
  browser.webRequest.onHeadersReceived.addListener(d => {
    d=transportRequest(d);
    // Structural diagnostics only: no query values, request headers or JSON bodies.
    const observed = douyinMetadataState(d), address = url(d.url);
    if (observed?.douyin && address && Thru3DDouyin.address(address.href) && d.method === 'GET' &&
        /^\/aweme\/v1\/web\/[a-z0-9_/]{1,120}$/.test(address.pathname) &&
        /^application\/json(?:;|$)/i.test(header(d.responseHeaders, 'content-type'))) {
      const path = '/aweme/v1/web/' + address.pathname.slice('/aweme/v1/web/'.length).split('/')
        .map(part => /^[a-z_]{0,40}$/.test(part) ? part : '{id}').join('/');
      observed.douyinApiPaths ||= new Set();
      if (!observed.douyinApiPaths.has(path)) {
        observed.douyinApiPaths.add(path);
        while (observed.douyinApiPaths.size > 32) observed.douyinApiPaths.delete(observed.douyinApiPaths.values().next().value);
        publish(observed);
      }
    }
    const state = stateFor(d), u = url(d.url), request = pending.get(d.requestId);
    if (!state || !u || d.method !== "GET" || ![200, 206].includes(d.statusCode)) return;
    const mime = header(d.responseHeaders, "content-type").split(";")[0].trim().toLowerCase();
    const type = kind(u, mime, d, state.bilibili) || (state.niconico&&niconicoResponses?.resource(state,d.url)?"segment":"") ||
      (dailymotionResponses?.resource(state,d.url)?"hls":"");
    if (!type || type === "segment" && !(state.tencent || state.iqiyi || state.niconico || state.ted || state.redbull || state.naver || state.reddit || state.streamable || state.archive || state.odysee || state.dailymotion)) return;
    if(state.niconico&&type!=="hls"&&!niconicoResponses?.resource(state,d.url))return;
    // Bilibili's paused cover can load a cached alternate audio URL without any
    // onSendHeaders event. It cannot replace a replayable request with empty headers:
    // the CDN rejects that native request (403). Keep the earlier exact observation;
    // never borrow headers from another URL, or extend its lifetime from a cache hit.
    if ((state.bilibili || state.douyin || state.weibo || state.tencent || state.mango || state.youku || state.iqiyi || state.niconico || state.twitch || state.tiktok || state.instagram || state.ted || state.redbull || state.naver || state.reddit || state.streamable || state.archive || state.odysee || state.dailymotion) && !(request?.state === state && request.url === d.url && request.sent === true)) return;
    // A cached response can have no onSendHeaders. Do not invent Cookie/Authorization.
    const safe = request?.state === state && request.url === d.url ? request.headers : {};
    // Plex Web sends its token in a request header. With generic capture disabled,
    // retain only a successful, authenticated library request from this exact frame.
    if (!(state.enabled || state.bilibili || state.douyin || state.weibo || state.tencent || state.mango || state.youku || state.iqiyi || state.niconico || state.twitch || state.tiktok || state.instagram || state.ted || state.redbull || state.naver || state.reddit || state.streamable || state.archive || state.odysee || state.dailymotion) &&
        !(typeof Thru3DPlex !== 'undefined' && Thru3DPlex.source(d.url, state.page, safe))) return;
    const c = { url: d.url, kind: type, mime, headers: safe, at: Date.now(), cookies: [],
      original_url: request?.state === state ? request.original : d.url,
      length: header(d.responseHeaders, "content-length").slice(0, 24),
      range: header(d.responseHeaders, "content-range").slice(0, 80) };
    if(state.naver){c.request_id=d.requestId;c.request_url=d.request_url||d.url;}
    if(typeof Thru3DDailymotion!=='undefined'&&Thru3DDailymotion.frame(state.page)&&Thru3DDailymotion.documentPage(state.parentPage)){
      c.request_id=d.requestId;
      c.request_url=d.request_url||d.url;
      const body=state.dailymotionBodies?.get(d.url);if(body?.request_id===d.requestId)c.kind=body.format;
    }
    const previous = state.items.get(d.url);
    if (state.archive && c.kind === 'file') {
      c.request_original_url=c.original_url;
      // Native prefix/range reads use the already observed final URL. Keep its
      // current-item download relationship, while the new request keeps ONLY
      // its own headers/cookies. Only fresh successful requests can keep this
      // current-document relationship live; cached responses above cannot.
      if (c.original_url === c.url && previous?.kind === 'file' && previous.original_url !== previous.url && typeof Thru3DArchive !== 'undefined') {
        const owner=Thru3DArchive.page(state.page), original=Thru3DArchive.address(previous.original_url);
        const parts=original?.pathname.split('/'), age=c.at-previous.at;
        if (owner && Thru3DArchive.documentPage(previous.original_url) && parts?.length===4 &&
            parts[1]==='download' && parts[2]===owner.id && /\.(?:mp4|webm)$/i.test(parts[3]) &&
            Number.isFinite(age) && age>=0 && age<=TTL) {
          c.original_url=previous.original_url;
        }
      }
    }
    c.cookies = previous && previous.headers.cookie === safe.cookie ? previous.cookies : [];
    state.items.delete(d.url); state.items.set(d.url, c);
    mangoResponses?.observeMedia(state,c);
    if(state.youku&&c.kind==='hls')youkuResponses?.observeMedia(state,c);
    if(state.niconico)niconicoResponses?.observeMedia(state,c);
    if(state.twitch)twitchResponses?.observeMedia(state,c);
    while (state.items.size > MAX || JSON.stringify([...state.items.values()]).length > 192 * 1024)
      state.items.delete(oldest(state));
    // Range traffic often repeats several times a second. Report changed credentials/resources,
    // not every segment; a periodic refresh still keeps a long-playing resource eligible.
    if (!previous || c.at - previous.reported > 30000 || c.original_url !== previous.original_url || JSON.stringify(safe) !== JSON.stringify(previous.headers)) {
      c.reported = c.at;
      if (!state.timer) state.timer = setTimeout(() => { state.timer = null; publish(state); }, 100);
    } else c.reported = previous.reported;
    if ((!previous || previous.headers.cookie !== safe.cookie || c.at - (previous.cookiesAt || 0) > 30000) && safe.cookie) {
      c.cookiesAt = c.at;
      // Preserve scope, and only include cookies actually present on this exact request.
      // Partitioned cookies unavailable through cookies.getAll remain exact-request-only.
      browser.cookies.getAll({ url: d.url, ...(d.cookieStoreId ? { storeId: d.cookieStoreId } : {}) }).then(cookies => {
        if (state.items.get(d.url) !== c) return;
        const sent = new Set(safe.cookie.split(/;\s*/));
        c.cookies = cookies.filter(cookie => !cookie.partitionKey && !cookie.firstPartyDomain &&
          sent.has(`${cookie.name}=${cookie.value}`)).slice(0, 128).map(({ name, value, domain, path, secure, hostOnly, expirationDate }) =>
            ({ name, value, domain, path, secure, hostOnly, expirationDate }));
        if (JSON.stringify(c.cookies).length > 24576) c.cookies = [];
        if (!state.timer) state.timer = setTimeout(() => { state.timer = null; publish(state); }, 100);
      }).catch(() => {});
    } else c.cookiesAt = previous?.cookiesAt || 0;
  }, filter, ["responseHeaders"]);
  const finish = d => pending.delete(d.requestId);
  browser.webRequest.onCompleted.addListener(finish, filter);
  browser.webRequest.onErrorOccurred.addListener(finish, filter);
  browser.webRequest.onBeforeRedirect.addListener(d => {
    d=transportRequest(d);
    const request = pending.get(d.requestId);
    if (request && url(d.redirectUrl)) pending.set(d.requestId, { ...request, url: d.redirectUrl, headers: {}, sent: false });
    else finish(d);
  }, filter);
})();
