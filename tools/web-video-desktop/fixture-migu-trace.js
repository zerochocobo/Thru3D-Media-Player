/* Emulator fixture only. Records completed ranges without retaining URLs or headers in a report. */
const Thru3DFixtureMiguTrace = (() => {
  const sample = page => /^https:\/\/www\.miguvideo\.com\/p\/vertical\/(968096380|966398567)$/.exec(page || '')?.[1];
  const bags = new WeakMap();
  const pending = new Map();
  const documents = new Map();
  const maxBytes = 512 * 1024;
  const filter = {urls: ['https://*.miguvideo.com/*.m3u8*'], types: ['xmlhttprequest', 'media', 'other']};

  function address(text, base) {
    try {
      const url = new URL(text, base);
      if (url.protocol === 'https:' && !url.username && !url.password && !url.hash && !url.port) return url;
    } catch (_) {}
    return null;
  }

  function parseLeaf(text, base) {
    const lines = text.split(/\r?\n/).map(line => line.trim());
    if (lines[0] !== '#EXTM3U' || !lines.includes('#EXT-X-ENDLIST') ||
        lines.some(line => /^#EXT-X-(?:STREAM-INF|KEY|SESSION-KEY|MAP|BYTERANGE|DISCONTINUITY|GAP|DEFINE)/.test(line))) return null;
    const segments = new Map();
    let duration = 0, length = 0;
    for (const line of lines.slice(1)) {
      if (line.startsWith('#EXTINF:')) {
        if (length !== 0) return null;
        length = Number(line.slice(8).split(',', 1)[0]);
        if (!Number.isFinite(length) || length <= 0 || length > 120) return null;
      } else if (line && !line.startsWith('#')) {
        const url = address(line, base);
        if (!url || !length || segments.has(url.href) || segments.size >= 2000) return null;
        segments.set(url.href, [duration, duration + length]);
        duration += length;
        length = 0;
      }
    }
    return length === 0 && segments.size && duration <= 172800 ? {duration, segments} : null;
  }

  function bodyLinks(text, base, id) {
    const raw=text.trim(),links=new Set();let value=raw,kind='url';
    const call=/^([A-Za-z_$][A-Za-z0-9_.$]{0,96})\s*\(([\s\S]*)\)\s*;?$/.exec(raw);
    if(call){
      const expected=address(base)?.searchParams.getAll('crossdomain');
      if(expected?.length!==1||call[1]!==expected[0])return {kind:'jsonp_unbound',urls:[]};
      try{value=JSON.parse(call[2]);kind='jsonp';}catch(_){return {kind:'opaque',urls:[]};}
    }else if(/^[{[\"]/.test(raw)){
      try{value=JSON.parse(raw);kind='json';}catch(_){return {kind:'opaque',urls:[]};}
    }
    const walk=(node,depth)=>{
      if(depth>4||links.size>=32)return;
      if(typeof node==='string'){
        const u=address(node),ids=u?.searchParams.getAll('ProgramID');
        if(u&&/\.m3u8$/i.test(u.pathname)&&ids?.length===1&&ids[0]===id)links.add(node);
      }else if(Array.isArray(node)){for(const child of node.slice(0,16))walk(child,depth+1);}
      else if(node&&typeof node==='object')for(const key of Object.keys(node).slice(0,32))walk(node[key],depth+1);
    };
    walk(value,0);return {kind:links.size?kind:'opaque',urls:[...links]};
  }

  function snapshot(state) {
    if (!sample(state.page)) return null;
    const saved = bags.get(state);
    const bag = saved?.page === state.page ? saved : null;
    const leaves = [...(bag?.leaves.values() || [])].map(leaf => {
      const ranges = [];
      let received = 0;
      for (const [url, [start, end]] of leaf.segments) {
        if (!bag.received.has(url)) continue;
        received++;
        if (ranges.at(-1)?.[1] === start) ranges.at(-1)[1] = end;
        else if (ranges.length < 16) ranges.push([start, end]);
      }
      return {duration: leaf.duration, segments: leaf.segments.size, received, ranges};
    });
    const urls=[...(bag?.requests||[])];
    return {response_filter: typeof browser.webRequest.filterResponseData === 'function', route_hls: bag?.requests.size || 0, leaves,
      responses:[...(bag?.responses||new Map())].map(([url,data])=>({request_index:urls.indexOf(url),...data})),
      redirects:(bag?.redirects||[]).map(r=>({from_request_index:urls.indexOf(r.from),to_request_index:urls.indexOf(r.to),status:r.status,
        same_host:address(r.from)?.host===address(r.to)?.host,same_path:address(r.from)?.pathname===address(r.to)?.pathname})),
      body_links:[...(bag?.bodyLinks||new Map())].flatMap(([from,links])=>links.urls.map(to=>({from_request_index:urls.indexOf(from),to_request_index:urls.indexOf(to),
        format:links.kind,exactly_observed:bag.requests.has(to)}))).slice(0,128)};
  }

  function install(lookup, publish) {
    function context(details) {
      if (details.frameId !== 0 || !sample(details.documentUrl)) return null;
      const state = lookup(details);
      if (!state || state.page !== details.documentUrl || state.documentPage !== state.page) return null;
      if (bags.get(state)?.page !== state.page) bags.set(state, {page: state.page, requests: new Set(), leaves: new Map(), received: new Set(),responses:new Map(),redirects:[],bodyLinks:new Map()});
      documents.set(details.tabId, state);
      while (documents.size > 16) documents.delete(documents.keys().next().value);
      return state;
    }
    browser.webRequest.onBeforeRequest.addListener(details => {
      const state = context(details);
      const uri = address(details.url);
      const ids = uri?.searchParams.getAll('ProgramID');
      if (!state || ids?.length !== 1 || ids[0] !== sample(state.page) || pending.has(details.requestId)) return;
      const bag = bags.get(state);
      if (bag.requests.size >= 32 || pending.size >= 8 || bag.leaves.size >= 8) return;
      bag.requests.add(details.url);
      if (typeof browser.webRequest.filterResponseData !== 'function') return;
      let stream;
      try { stream = browser.webRequest.filterResponseData(details.requestId); } catch (_) { return; }
      const request = {size: 0, status: 0, final: details.url}, parts = [];
      pending.set(details.requestId, request);
      const timer = setTimeout(() => { forget(); stream.disconnect(); }, 10000);
      function forget() {
        clearTimeout(timer);
        if (pending.get(details.requestId) === request) pending.delete(details.requestId);
      }
      stream.ondata = event => {
        try { stream.write(event.data); } catch (_) { forget(); return; }
        request.size += event.data.byteLength;
        if (request.size <= maxBytes) parts.push(new Uint8Array(event.data).slice());
        else { forget(); stream.disconnect(); }
      };
      stream.onerror = forget;
      stream.onstop = () => {
        forget();
        try { stream.close(); } catch (_) { return; }
        if (request.status !== 200 || context(details) !== state || bags.get(state) !== bag || request.size > maxBytes) return;
        const bytes = new Uint8Array(request.size);
        let offset = 0;
        for (const part of parts) { bytes.set(part, offset); offset += part.length; }
        const text=new TextDecoder().decode(bytes),leaf = parseLeaf(text, request.final);
        const links=leaf?null:bodyLinks(text,request.final,sample(state.page));
        if(links&&bag.bodyLinks.size<16)bag.bodyLinks.set(request.final,links);
        if(bag.responses.size<16)bag.responses.set(request.final,{status:request.status,body_bytes:request.size,
          body_shape:text.trimStart().startsWith('#EXTM3U')?(text.includes('#EXT-X-STREAM-INF:')?'hls_master':leaf?'hls_clear_leaf':'hls_other'):
            /^[\s]*[{[]/.test(text)?'json_like':text.trimStart().startsWith('<')?'xml_like':'other',
          ...(links?{body_structure:links.kind,programme_links:links.urls.length}:{})});
        if (leaf && bag.leaves.size < 8) bag.leaves.set(request.final, leaf);
        publish(state);
      };
    }, filter, ['blocking']);
    browser.webRequest.onHeadersReceived.addListener(details => {
      const request = pending.get(details.requestId);
      if (request) { request.final = details.url; request.status = details.statusCode; }
      const state=context(details),bag=state&&bags.get(state);
      if(bag&&bag.requests.has(details.url)&&bag.responses.size<16)bag.responses.set(details.url,{status:details.statusCode});
    }, filter);
    browser.webRequest.onBeforeRedirect.addListener(details=>{
      const state=context(details),bag=state&&bags.get(state);
      if(bag&&bag.requests.has(details.url)&&address(details.redirectUrl)&&bag.redirects.length<16)bag.redirects.push({from:details.url,to:details.redirectUrl,status:details.statusCode});
    },filter);
    browser.webRequest.onCompleted.addListener(details => {
      const state = context(details);
      if (!state || details.statusCode !== 200 && details.statusCode !== 206) return;
      const bag = bags.get(state);
      if (bag.received.size >= 1200 || bag.received.has(details.url)) return;
      bag.received.add(details.url);
      if ([...bag.leaves.values()].some(leaf => leaf.segments.has(details.url))) publish(state);
    }, {urls: ['https://*/*'], types: ['xmlhttprequest', 'media', 'other']});
  }

  function observed(tab, page) {
    const state = documents.get(tab);
    if (!sample(page) || !state || state.page !== page || state.documentPage !== page) return null;
    return {trace: snapshot(state), requests: [...state.items.values()].filter(r => r.kind === 'hls').slice(-24)
      .map(r => ({kind: r.kind, url: r.url, original_url: r.original_url, at: r.at}))};
  }
  return {install, snapshot, observed, bodyLinks};
})();
