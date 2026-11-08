/* Reuses Youku/Niconico's frame/document ownership. Response bytes pass unchanged
 * immediately; only bounded copies of actual current-page GraphQL are inspected. */
const Thru3DTwitchResponses=(stateFor,publish,hasFrame)=>{
  'use strict';
  hasFrame ||= ()=>false;
  const filter={urls:['https://*/*'],types:['xmlhttprequest','other']},active=new Map(),early=new Map(),TTL=15000,LIMIT=2*1024*1024;
  const same=(a,b)=>!!Thru3DTwitch.page(a.page)&&Thru3DTwitch.page(a.page)===Thru3DTwitch.page(b.page)&&new URL(a.page).origin===new URL(b.page).origin&&
    (a.page===b.page||!!a.document&&a.document===b.document)&&a.key===b.key&&a.privateContext===b.privateContext&&
    (!a.document||!b.document||a.document===b.document)&&(!a.cookieStore||!b.cookieStore||a.cookieStore===b.cookieStore);
  const notify=s=>{if(!s.early)try{publish(s);}catch(_){}};
  const release=e=>{
    if(e.released)return;e.released=true;clearTimeout(e.timer);active.delete(e.id);e.chunks=[];
    if(!e.closed)try{e.stream.disconnect();}catch(_){}
  };
  const drop=key=>{const s=early.get(key);if(!s)return;early.delete(key);clearTimeout(s.expiry);for(const e of active.values())if(e.state===s)release(e);};
  const prune=()=>{for(const [key,s] of early)if(Date.now()-s.created>TTL)drop(key);};
  const owner=d=>{
    const state=stateFor(d);
    if(state)return state.twitch&&d.frameId===0&&state.privateContext===d.incognito&&(!state.cookieStore||!d.cookieStoreId||state.cookieStore===d.cookieStoreId)?state:null;
    if(hasFrame(d)||!Number.isInteger(d.tabId)||d.tabId<0||d.frameId!==0||typeof d.incognito!=='boolean')return null;
    const page=d.documentUrl;if(!Thru3DTwitch.page(page))return null;
    try{if(d.originUrl&&new URL(d.originUrl).origin!==new URL(page).origin)return null;}catch(_){return null;}
    prune();const key=`${d.tabId}:${d.frameId}:${d.documentId||''}:${page}`;
    if(!early.has(key)){
      const s={key:`${d.tabId}:${d.frameId}`,page,document:d.documentId,privateContext:d.incognito,cookieStore:d.cookieStoreId||'',twitch:true,early:true,created:Date.now()};
      early.set(key,s);s.expiry=setTimeout(()=>drop(key),TTL);
    }
    while(early.size>16)drop(early.keys().next().value);
    return early.get(key);
  };
  const update=s=>{
    const values=Thru3DTwitch.records(s.twitchMeta||new Map(),[...(s.items?.values()||[])],s.page);
    s.twitchData=new Map(values.map(v=>[v.source,v]));s.twitchStatus=values.length?'normalized':s.twitchMeta?.size?'metadata':'idle';notify(s);
  };
  const attach=s=>{
    if(!s.twitch)return;prune();const matches=[...early].filter(([,v])=>same(v,s));if(matches.length!==1)return;
    const [key,value]=matches[0];early.delete(key);clearTimeout(value.expiry);
    for(const field of ['twitchMeta','twitchData','twitchStatus','twitchCounters'])s[field]=value[field];
    for(const e of active.values())if(e.state===value)e.state=s;
    update(s);
  };
  const cancel=s=>{
    for(const e of active.values())if(e.state===s)release(e);
    for(const [key,value] of early)if(same(value,s))drop(key);
    s.twitchMeta?.clear();s.twitchData?.clear();s.twitchStatus='idle';
  };
  const navigate=d=>{for(const [key,s] of early)if(s.key===`${d.tabId}:${d.frameId}`||d.type==='main_frame'&&s.key.startsWith(`${d.tabId}:`))drop(key);};
  browser.webRequest.onBeforeRequest.addListener(d=>{
    if(d.method!=='POST'||!Thru3DTwitch.api(d.url)||active.size>=8)return;
    const s=owner(d);if(!s)return;
    s.twitchCounters ||= {started:0,completed:0,parts:0,invalid:0,rejected:0};s.twitchCounters.started++;notify(s);
    let stream;try{stream=browser.webRequest.filterResponseData(d.requestId);}catch(_){return;}
    const e={id:d.requestId,state:s,stream,chunks:[],size:0,ok:null,stopped:false,closed:false,released:false};active.set(e.id,e);
    e.timer=setTimeout(()=>release(e),TTL);
    const complete=()=>{
      if(e.released||!e.stopped||e.ok===null)return;
      if(!e.ok||owner(d)!==e.state){e.state.twitchCounters.rejected++;notify(e.state);release(e);return;}
      try{
        const bytes=new Uint8Array(e.size);let at=0;for(const c of e.chunks){bytes.set(c,at);at+=c.length;}
        const parts=Thru3DTwitch.metadata(new TextDecoder('utf-8',{fatal:true}).decode(bytes),e.state.page);
        e.state.twitchCounters.completed++;e.state.twitchCounters.parts+=parts.length;
        if(parts.length){e.state.twitchMeta ||= new Map();Thru3DTwitch.merge(e.state.twitchMeta,parts);update(e.state);}else notify(e.state);
      }catch(_){e.state.twitchCounters.invalid++;notify(e.state);}finally{release(e);}
    };
    e.complete=complete;
    stream.ondata=event=>{
      if(e.released)return;
      // Forward before copying, including oversized/error responses.
      try{stream.write(event.data);}catch(_){release(e);return;}
      if(e.size+event.data.byteLength>LIMIT){release(e);return;}
      e.size+=event.data.byteLength;e.chunks.push(new Uint8Array(event.data).slice());
    };
    stream.onstop=()=>{if(e.released)return;e.stopped=true;try{stream.close();e.closed=true;}catch(_){}complete();};
    stream.onerror=()=>release(e);
  },filter,['blocking']);
  browser.webRequest.onHeadersReceived.addListener(d=>{
    const e=active.get(d.requestId);if(!e)return;
    const mime=(d.responseHeaders||[]).find(h=>h.name.toLowerCase()==='content-type')?.value||'';
    e.ok=d.statusCode===200&&/^application\/json(?:;|$)/i.test(mime);
    if(!e.ok)release(e);else e.complete();
  },filter,['responseHeaders']);
  for(const event of ['onBeforeRedirect','onErrorOccurred'])browser.webRequest[event].addListener(d=>{const e=active.get(d.requestId);if(e)release(e);},filter);
  return {attach,cancel,navigate,observeMedia:update};
};
