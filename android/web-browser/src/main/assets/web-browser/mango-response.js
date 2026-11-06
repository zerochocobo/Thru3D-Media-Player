/* Frame/early-document ownership follows tencent-response.js. JSONP bytes stay unchanged. */
const Thru3DMangoResponses = (stateFor,publish,hasFrame) => {
  'use strict';
  hasFrame ||= ()=>false;
  const filter={urls:['https://*/*'],types:['xmlhttprequest','script','other']};
  const active=new Map(),early=new Map(),TTL=15000,LIMIT=2*1024*1024;
  const same=(a,b)=>{
    const x=Thru3DMango.page(a.page),y=Thru3DMango.page(b.page);
    return !!x&&!!y&&x.id===y.id&&a.key===b.key&&a.privateContext===b.privateContext&&
      (!a.document||!b.document||a.document===b.document)&&(!a.cookieStore||!b.cookieStore||a.cookieStore===b.cookieStore)&&
      new URL(a.page).origin===new URL(b.page).origin;
  };
  const notify=s=>{if(!s.early)try{publish(s);}catch(_){}};
  const flush=e=>{const chunks=e.chunks;e.chunks=[];for(const c of chunks)e.stream.write(c.buffer);};
  const release=(e,status)=>{
    if(e.released)return;e.released=true;clearTimeout(e.timer);active.delete(e.id);
    try{flush(e);}catch(_){}try{e.stream.disconnect();}catch(_){}e.detached=true;
    e.state.mangoStatus=status;notify(e.state);
  };
  const drop=key=>{
    const state=early.get(key);if(!state)return;early.delete(key);clearTimeout(state.expiry);
    for(const e of active.values())if(e.state===state)release(e,'context_changed');
  };
  const prune=()=>{for(const [key,state] of early)if(Date.now()-state.created>TTL)drop(key);};
  const owner=d=>{
    const state=stateFor(d);
    if(state)return state.privateContext===d.incognito&&(!state.cookieStore||!d.cookieStoreId||state.cookieStore===d.cookieStoreId)?state:null;
    if(hasFrame(d)||!Number.isInteger(d.tabId)||d.tabId<0||!Number.isInteger(d.frameId)||d.frameId<0||typeof d.incognito!=='boolean')return null;
    const page=d.documentUrl||d.originUrl;if(!Thru3DMango.page(page))return null;
    try{if(d.originUrl&&new URL(d.originUrl).origin!==new URL(page).origin)return null;}catch(_){return null;}
    prune();const key=`${d.tabId}:${d.frameId}:${d.documentId||''}:${page}`;
    if(!early.has(key)){
      const s={key:`${d.tabId}:${d.frameId}`,page,document:d.documentId,privateContext:d.incognito,cookieStore:d.cookieStoreId||'',mango:true,early:true,created:Date.now()};
      early.set(key,s);s.expiry=setTimeout(()=>drop(key),TTL);
    }
    while(early.size>16)drop(early.keys().next().value);
    return early.get(key);
  };
  const revision=value=>{let h=2166136261;for(let i=0;i<value.length;i++)h=Math.imul(h^value.charCodeAt(i),16777619);return(h>>>0).toString(16);};
  const mediaRoot=(s,c)=>{
    if(!s.mango||!s.mangoMeta?.clear||s.mangoMeta.id!==Thru3DMango.page(s.page)?.id||c.kind!=='hls')return null;
    return [c.original_url,c.url].find(value=>Thru3DMango.matchFile(s.mangoFiles,value)||Thru3DMango.matchInline(s.mangoInline,value))||null;
  };
  const update=s=>{
    // A same-document HLS can finish before its metadata, or remain loaded while
    // the SDK refreshes streamList. Revalidate exact file identity against the
    // new clear graph; keep that media request's own headers and original age.
    const inline=[];
    for(const c of s.items?.values()||[]){
      const age=Date.now()-c.at;
      if(!Number.isFinite(c.at)||age<0||age>1800000)continue;
      const root=mediaRoot(s,c);if(!root)continue;
      s.mangoManifests||=new Set();
      if(s.mangoManifests.size<8||s.mangoManifests.has(root)){
        s.mangoManifests.add(root);s.mangoStatus='normalized';
        const declaration=Thru3DMango.matchInline(s.mangoInline,root);
        if(declaration)inline.push({url:root,width:declaration.width,height:declaration.height});
      }
    }
    s.mangoData=new Map();
    if(s.mangoMeta?.clear&&s.mangoManifests?.size){
      const manifests=[...s.mangoManifests],data={...s.mangoMeta,manifests,inline_manifests:inline};
      data.revision=revision(JSON.stringify(data));s.mangoData.set(data.id,data);
    }
    notify(s);
  };
  const attach=s=>{
    if(!s.mango)return;prune();const matches=[...early].filter(([,value])=>same(value,s));if(matches.length!==1)return;
    const [key,value]=matches[0];early.delete(key);clearTimeout(value.expiry);
    for(const field of ['mangoMeta','mangoDeclared','mangoManifests','mangoData','mangoStatus','mangoGeneration','mangoFiles','mangoInline'])s[field]=value[field];
    for(const e of active.values())if(e.state===value)e.state=s;
    notify(s);
  };
  const cancel=s=>{
    for(const e of active.values())if(e.state===s)release(e,'cancelled');
    for(const [key,value] of early)if(same(value,s))drop(key);
    s.mangoData?.clear();s.mangoDeclared=[];s.mangoManifests?.clear();s.mangoMeta=null;s.mangoFiles=[];s.mangoInline=[];
  };
  const navigate=d=>{
    for(const [key,s] of early)if(s.key===`${d.tabId}:${d.frameId}`||d.type==='main_frame'&&s.key.startsWith(`${d.tabId}:`))drop(key);
  };
  browser.webRequest.onBeforeRequest.addListener(d=>{
    if(d.method!=='GET'||active.size>=8)return;
    const s=owner(d),p=s?.mango&&Thru3DMango.page(s.page),u=Thru3DMango.address(d.url);if(!p||!u)return;
    const api=['/player/video','/player/getSource','/video/streamList'].includes(u.pathname);
    const ids=u.searchParams.getAll('video_id');
    if(api&&(ids.length!==1||ids[0]!==p.id))return;
    const kind=api?u.pathname:Thru3DMango.matchDispatch(s.mangoDeclared||[],d.url)?'dispatch':'';
    if(!kind)return;
    if(api){
      s.mangoGeneration=(s.mangoGeneration||0)+1;
      s.mangoFiles=[];s.mangoInline=[];
      if(kind==='/player/video'||kind==='/video/streamList')s.mangoMeta=null;
      s.mangoDeclared=[];s.mangoManifests=new Set();s.mangoStatus='observing';update(s);
    }
    let stream;try{stream=browser.webRequest.filterResponseData(d.requestId);}catch(_){return;}
    const e={id:d.requestId,state:s,generation:s.mangoGeneration,stream,chunks:[],size:0,ok:null,stopped:false,released:false};active.set(e.id,e);
    e.timer=setTimeout(()=>release(e,'timeout'),TTL);
    const complete=()=>{
      if(e.released||!e.stopped||e.ok===null)return;
      if(!e.ok||owner(d)!==e.state||e.generation!==e.state.mangoGeneration){release(e,'context_changed');return;}
      e.released=true;clearTimeout(e.timer);active.delete(e.id);
      try{
        const bytes=new Uint8Array(e.size);let at=0;for(const c of e.chunks){bytes.set(c,at);at+=c.length;}
        const raw=Thru3DMango.json(new TextDecoder('utf-8',{fatal:true}).decode(bytes)),state=e.state;
        if(kind==='/video/streamList'){
          state.mangoMeta=Thru3DMango.video(raw,p.id);state.mangoDeclared=Thru3DMango.sources(raw,p.id,state.mangoMeta);state.mangoManifests=new Set();
          state.mangoFiles=Thru3DMango.files(raw,p.id,state.mangoMeta);
          state.mangoInline=Thru3DMango.inline(raw,p.id,state.mangoMeta);
          state.mangoStatus=state.mangoDeclared.length?'sources':state.mangoMeta?.clear?'unbound_sources':'protected_or_invalid';
        }else if(kind==='/player/video'){
          state.mangoMeta=Thru3DMango.video(raw,p.id);state.mangoDeclared=[];state.mangoManifests=new Set();
          state.mangoStatus=state.mangoMeta?.clear?'metadata':'protected_or_invalid';
        }else if(kind==='/player/getSource'){
          state.mangoDeclared=Thru3DMango.sources(raw,p.id,state.mangoMeta);
          state.mangoFiles=Thru3DMango.files(raw,p.id,state.mangoMeta);
          state.mangoInline=Thru3DMango.inline(raw,p.id,state.mangoMeta);
          state.mangoStatus=state.mangoDeclared.length?'sources':'unbound_sources';
        }else{
          const manifest=Thru3DMango.manifest(raw);
          if(!manifest)throw new Error('Invalid dispatch result');
          state.mangoManifests||=new Set();if(state.mangoManifests.size>=8&&!state.mangoManifests.has(manifest))throw new Error('Manifest budget');
          state.mangoManifests.add(manifest);state.mangoStatus='normalized';
        }
        update(state);
      }catch(_){e.state.mangoStatus='invalid_data';notify(e.state);}
      finally{
        // Publish declarations before releasing JSONP to the page. Its callback
        // can immediately initiate the next request in another browser process.
        try{flush(e);stream.close();}catch(_){try{stream.disconnect();}catch(_){}e.detached=true;}
      }
    };
    e.complete=complete;
    stream.ondata=event=>{
      if(e.detached||e.released)return;
      if(e.size+event.data.byteLength>LIMIT){
        try{flush(e);stream.write(event.data);}catch(_){}release(e,'oversize');return;
      }
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
  // Called only after network.js has a successful HLS response and the exact
  // document's onSendHeaders observation. No API credentials are inherited.
  const observeMedia=(s,c)=>{
    const root=mediaRoot(s,c);
    if(!root)return;
    s.mangoManifests||=new Set();if(s.mangoManifests.size>=8&&!s.mangoManifests.has(root))return;
    s.mangoManifests.add(root);s.mangoStatus='normalized';update(s);
  };
  return {attach,cancel,navigate,observeMedia};
};
