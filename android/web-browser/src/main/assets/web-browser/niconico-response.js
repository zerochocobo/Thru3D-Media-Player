/* Reuses youku-response.js's bounded forwarding and early-document ownership.
 * Only current watch access responses and their declared HLS graph are read.
 * AES keys/segments are never read by this observer; requests retain their own scope. */
const Thru3DNiconicoResponses=(stateFor,publish,hasFrame)=>{
  'use strict';
  hasFrame ||= ()=>false;
  const filter={urls:['https://*/*'],types:['xmlhttprequest','media','other']},active=new Map(),early=new Map(),TTL=15000;
  const same=(a,b)=>Thru3DNiconico.page(a.page)===Thru3DNiconico.page(b.page)&&a.key===b.key&&a.privateContext===b.privateContext&&
    (!a.document||!b.document||a.document===b.document)&&(!a.cookieStore||!b.cookieStore||a.cookieStore===b.cookieStore)&&a.page===b.page;
  const notify=s=>{if(!s.early)try{publish(s);}catch(_){}};
  const flush=e=>{const chunks=e.chunks;e.chunks=[];for(const c of chunks)e.stream.write(c.buffer);};
  const release=(e,status)=>{
    if(e.released)return;e.released=true;clearTimeout(e.timer);active.delete(e.id);
    try{flush(e);}catch(_){}try{e.stream.disconnect();}catch(_){}e.detached=true;
    if(e.state.niconicoGeneration===e.generation){e.state.niconicoStatus=status;notify(e.state);}
  };
  const drop=key=>{const s=early.get(key);if(!s)return;early.delete(key);clearTimeout(s.expiry);for(const e of active.values())if(e.state===s)release(e,'context_changed');};
  const prune=()=>{for(const [key,s] of early)if(Date.now()-s.created>TTL)drop(key);};
  const owner=d=>{
    const state=stateFor(d);
    if(state)return state.niconico&&d.frameId===0&&state.privateContext===d.incognito&&(!state.cookieStore||!d.cookieStoreId||state.cookieStore===d.cookieStoreId)?state:null;
    if(hasFrame(d)||!Number.isInteger(d.tabId)||d.tabId<0||d.frameId!==0||typeof d.incognito!=='boolean')return null;
    const page=d.documentUrl;if(!Thru3DNiconico.page(page))return null;
    try{if(d.originUrl&&new URL(d.originUrl).origin!==new URL(page).origin)return null;}catch(_){return null;}
    prune();const key=`${d.tabId}:${d.frameId}:${d.documentId||''}:${page}`;
    if(!early.has(key)){
      const s={key:`${d.tabId}:${d.frameId}`,page,document:d.documentId,privateContext:d.incognito,cookieStore:d.cookieStoreId||'',niconico:true,early:true,created:Date.now()};
      early.set(key,s);s.expiry=setTimeout(()=>drop(key),TTL);
    }
    while(early.size>16)drop(early.keys().next().value);
    return early.get(key);
  };
  const update=s=>{
    const values=Thru3DNiconico.records(s.niconicoMeta,s.niconicoMaster,s.niconicoLeaves||new Map(),[...(s.items?.values()||[])],s.page);
    s.niconicoData=new Map(values.map(v=>[v.id,v]));if(values.length)s.niconicoStatus='normalized';notify(s);
  };
  const attach=s=>{
    if(!s.niconico)return;prune();const matches=[...early].filter(([,value])=>same(value,s));if(matches.length!==1)return;
    const [key,value]=matches[0];early.delete(key);clearTimeout(value.expiry);
    for(const field of ['niconicoMeta','niconicoMaster','niconicoLeaves','niconicoData','niconicoStatus','niconicoGeneration'])s[field]=value[field];
    for(const e of active.values())if(e.state===value)e.state=s;update(s);
  };
  const cancel=s=>{
    for(const e of active.values())if(e.state===s)release(e,'cancelled');
    for(const [key,value] of early)if(same(value,s))drop(key);
    s.niconicoMeta=null;s.niconicoMaster=null;s.niconicoLeaves?.clear();s.niconicoData?.clear();
  };
  const navigate=d=>{for(const [key,s] of early)if(s.key===`${d.tabId}:${d.frameId}`||d.type==='main_frame'&&s.key.startsWith(`${d.tabId}:`))drop(key);};
  const resource=(s,url)=>[...(s.niconicoLeaves?.values()||[])].some(v=>v.resources.includes(url));
  browser.webRequest.onBeforeRequest.addListener(d=>{
    if(!['GET','POST'].includes(d.method)||active.size>=8)return;
    const s=owner(d),u=Thru3DNiconico.address(d.url);if(!s||!u)return;
    const api=d.method==='POST'&&Thru3DNiconico.access(u.href,s.page),root=!api&&d.method==='GET'&&u.href===s.niconicoMeta?.root;
    const child=!api&&!root&&d.method==='GET'&&s.niconicoMaster?.variants.some(v=>v.video===u.href||v.audio===u.href);
    if(!api&&!root&&!child)return;
    if(api){s.niconicoGeneration=(s.niconicoGeneration||0)+1;s.niconicoMeta=null;s.niconicoMaster=null;s.niconicoLeaves=new Map();s.niconicoData=new Map();s.niconicoStatus='observing';notify(s);}
    let stream;try{stream=browser.webRequest.filterResponseData(d.requestId);}catch(_){return;}
    const e={id:d.requestId,state:s,generation:s.niconicoGeneration,stream,chunks:[],size:0,ok:null,stopped:false,released:false};active.set(e.id,e);
    e.timer=setTimeout(()=>release(e,'timeout'),TTL);
    const complete=()=>{
      if(e.released||!e.stopped||e.ok===null)return;
      if(!e.ok||owner(d)!==e.state||e.generation!==e.state.niconicoGeneration){release(e,'context_changed');return;}
      e.released=true;clearTimeout(e.timer);active.delete(e.id);
      try{
        const bytes=new Uint8Array(e.size);let at=0;for(const c of e.chunks){bytes.set(c,at);at+=c.length;}
        const text=new TextDecoder('utf-8',{fatal:true}).decode(bytes),state=e.state;
        if(api){state.niconicoMeta=Thru3DNiconico.rights(JSON.parse(text),state.page);state.niconicoStatus=state.niconicoMeta?'metadata':'invalid_data';}
        else if(root){state.niconicoMaster=Thru3DNiconico.master(text,u.href);state.niconicoStatus=state.niconicoMaster?'master':'unsupported_master';}
        else {const leaf=Thru3DNiconico.leaf(text,u.href);if(leaf)state.niconicoLeaves.set(u.href,leaf);else state.niconicoLeaves.delete(u.href);state.niconicoStatus=leaf?'leaf':'protected_or_invalid';}
        update(state);
      }catch(_){e.state.niconicoStatus='invalid_data';notify(e.state);}
      finally{try{flush(e);stream.close();}catch(_){try{stream.disconnect();}catch(_){}e.detached=true;}}
    };
    e.complete=complete;e.api=api;
    stream.ondata=event=>{
      if(e.detached||e.released)return;
      if(e.size+event.data.byteLength>(api?256:160)*1024){try{flush(e);stream.write(event.data);}catch(_){}release(e,'oversize');return;}
      e.size+=event.data.byteLength;e.chunks.push(new Uint8Array(event.data).slice());
    };
    stream.onstop=()=>{if(e.detached||e.released)return;e.stopped=true;complete();};
    stream.onerror=()=>release(e,'stream_error');
  },filter,['blocking']);
  browser.webRequest.onHeadersReceived.addListener(d=>{
    const e=active.get(d.requestId);if(!e)return;
    const mime=(d.responseHeaders||[]).find(h=>h.name.toLowerCase()==='content-type')?.value||'';
    e.ok=e.api?[200,201].includes(d.statusCode)&&/^application\/json(?:;|$)/i.test(mime):d.statusCode===200&&/^(?:application|audio)\/(?:x-mpegurl|vnd\.apple\.mpegurl)(?:;|$)/i.test(mime);
    if(!e.ok)release(e,'http_rejected');else e.complete();
  },filter,['responseHeaders']);
  browser.webRequest.onBeforeRedirect.addListener(d=>{const e=active.get(d.requestId);if(e)release(e,'redirected');},filter);
  browser.webRequest.onErrorOccurred.addListener(d=>{const e=active.get(d.requestId);if(e)release(e,'stream_error');},filter);
  return {attach,cancel,navigate,observeMedia:update,resource};
};
