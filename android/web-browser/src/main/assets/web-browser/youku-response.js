/* Reuses Mango's bounded byte forwarding and exact frame/early-document ownership. */
const Thru3DYoukuResponses = (stateFor,publish,hasFrame) => {
  'use strict';
  hasFrame ||= ()=>false;
  const filter={urls:['https://*/*'],types:['xmlhttprequest','script','other']};
  const active=new Map(),early=new Map(),TTL=15000,LIMIT=2*1024*1024;
  const same=(a,b)=>{
    const x=Thru3DYouku.page(a.page),y=Thru3DYouku.page(b.page);
    return !!x&&!!y&&x.id===y.id&&a.key===b.key&&a.privateContext===b.privateContext&&
      (!a.document||!b.document||a.document===b.document)&&(!a.cookieStore||!b.cookieStore||a.cookieStore===b.cookieStore)&&
      new URL(a.page).origin===new URL(b.page).origin;
  };
  const notify=s=>{if(!s.early)try{publish(s);}catch(_){}};
  const flush=e=>{const chunks=e.chunks;e.chunks=[];for(const c of chunks)e.stream.write(c.buffer);};
  const release=(e,status)=>{
    if(e.released)return;e.released=true;clearTimeout(e.timer);active.delete(e.id);
    try{flush(e);}catch(_){}try{e.stream.disconnect();}catch(_){}e.detached=true;
    if(e.state.youkuGeneration===e.generation){e.state.youkuStatus=status;notify(e.state);}
  };
  const drop=key=>{const s=early.get(key);if(!s)return;early.delete(key);clearTimeout(s.expiry);for(const e of active.values())if(e.state===s)release(e,'context_changed');};
  const prune=()=>{for(const [key,s] of early)if(Date.now()-s.created>TTL)drop(key);};
  const owner=d=>{
    const state=stateFor(d);
    if(state)return state.privateContext===d.incognito&&(!state.cookieStore||!d.cookieStoreId||state.cookieStore===d.cookieStoreId)?state:null;
    if(hasFrame(d)||!Number.isInteger(d.tabId)||d.tabId<0||!Number.isInteger(d.frameId)||d.frameId<0||typeof d.incognito!=='boolean')return null;
    const page=d.documentUrl||d.originUrl;if(!Thru3DYouku.page(page))return null;
    try{if(d.originUrl&&new URL(d.originUrl).origin!==new URL(page).origin)return null;}catch(_){return null;}
    prune();const key=`${d.tabId}:${d.frameId}:${d.documentId||''}:${page}`;
    if(!early.has(key)){
      const s={key:`${d.tabId}:${d.frameId}`,page,document:d.documentId,privateContext:d.incognito,cookieStore:d.cookieStoreId||'',youku:true,early:true,created:Date.now()};
      early.set(key,s);s.expiry=setTimeout(()=>drop(key),TTL);
    }
    while(early.size>16)drop(early.keys().next().value);
    return early.get(key);
  };
  const update=s=>{
    s.youkuData=new Map();
    const meta=s.youkuMeta;
    if(meta&&meta.id===Thru3DYouku.page(s.page)?.id){
      const manifests=[];
      for(const c of s.items?.values()||[]){
        const age=Date.now()-c.at;
        if(c.kind==='hls'&&Number.isFinite(age)&&age>=0&&age<=1800000&&meta.streams.some(t=>
          Thru3DYouku.sameManifest(t.url,c.url)||Thru3DYouku.sameManifest(t.url,c.original_url)))manifests.push(c.url);
      }
      if(manifests.length){s.youkuData.set(meta.id,{...meta,manifests:[...new Set(manifests)]});s.youkuStatus='normalized';}
    }
    notify(s);
  };
  const attach=s=>{
    if(!s.youku)return;prune();const matches=[...early].filter(([,value])=>same(value,s));if(matches.length!==1)return;
    const [key,value]=matches[0];early.delete(key);clearTimeout(value.expiry);
    for(const field of ['youkuMeta','youkuData','youkuStatus','youkuGeneration'])s[field]=value[field];
    for(const e of active.values())if(e.state===value)e.state=s;
    update(s);
  };
  const cancel=s=>{
    for(const e of active.values())if(e.state===s)release(e,'cancelled');
    for(const [key,value] of early)if(same(value,s))drop(key);
    s.youkuMeta=null;s.youkuData?.clear();
  };
  const navigate=d=>{for(const [key,s] of early)if(s.key===`${d.tabId}:${d.frameId}`||d.type==='main_frame'&&s.key.startsWith(`${d.tabId}:`))drop(key);};
  browser.webRequest.onBeforeRequest.addListener(d=>{
    if(!['GET','POST'].includes(d.method)||active.size>=8)return;
    const u=Thru3DYouku.address(d.url);if(!u||!/^\/h5\/mtop\.youku\.play\.ups\.appinfo\.get\/[0-9.]{1,16}\/$/.test(u.pathname))return;
    const s=owner(d);if(!s?.youku)return;
    s.youkuGeneration=(s.youkuGeneration||0)+1;s.youkuMeta=null;s.youkuData=new Map();s.youkuStatus='observing';notify(s);
    let stream;try{stream=browser.webRequest.filterResponseData(d.requestId);}catch(_){return;}
    const e={id:d.requestId,state:s,generation:s.youkuGeneration,stream,chunks:[],size:0,ok:null,stopped:false,released:false};active.set(e.id,e);
    e.timer=setTimeout(()=>release(e,'timeout'),TTL);
    const complete=()=>{
      if(e.released||!e.stopped||e.ok===null)return;
      if(!e.ok||owner(d)!==e.state||e.generation!==e.state.youkuGeneration){release(e,'context_changed');return;}
      e.released=true;clearTimeout(e.timer);active.delete(e.id);
      try{
        const bytes=new Uint8Array(e.size);let at=0;for(const c of e.chunks){bytes.set(c,at);at+=c.length;}
        e.state.youkuMeta=Thru3DYouku.normalize(Thru3DYouku.json(new TextDecoder('utf-8',{fatal:true}).decode(bytes)),e.state.page);
        e.state.youkuStatus=e.state.youkuMeta?'metadata':'protected_or_invalid';update(e.state);
      }catch(_){e.state.youkuMeta=null;e.state.youkuData=new Map();e.state.youkuStatus='invalid_data';notify(e.state);}
      finally{try{flush(e);stream.close();}catch(_){try{stream.disconnect();}catch(_){}e.detached=true;}}
    };
    e.complete=complete;
    stream.ondata=event=>{
      if(e.detached||e.released)return;
      if(e.size+event.data.byteLength>LIMIT){try{flush(e);stream.write(event.data);}catch(_){}release(e,'oversize');return;}
      e.size+=event.data.byteLength;e.chunks.push(new Uint8Array(event.data).slice());
    };
    stream.onstop=()=>{if(e.detached||e.released)return;e.stopped=true;complete();};
    stream.onerror=()=>release(e,'stream_error');
  },filter,['blocking']);
  browser.webRequest.onHeadersReceived.addListener(d=>{
    const e=active.get(d.requestId);if(!e)return;
    const mime=(d.responseHeaders||[]).find(h=>h.name.toLowerCase()==='content-type')?.value||'';
    e.ok=d.statusCode===200&&/^(?:application\/(?:json|javascript|x-javascript)|text\/(?:javascript|plain))(?:;|$)/i.test(mime);
    if(!e.ok)release(e,'http_rejected');else e.complete();
  },filter,['responseHeaders']);
  browser.webRequest.onBeforeRedirect.addListener(d=>{const e=active.get(d.requestId);if(e)release(e,'redirected');},filter);
  browser.webRequest.onErrorOccurred.addListener(d=>{const e=active.get(d.requestId);if(e)release(e,'stream_error');},filter);
  return {attach,cancel,navigate,observeMedia:update};
};
