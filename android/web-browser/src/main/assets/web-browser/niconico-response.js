/* Reuses youku-response.js's bounded forwarding and early-document ownership.
 * Keep a bounded graph per actual API identity in this one owned document.
 * SPA prefetch never becomes playable until the current watch ID matches.
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
    if(e.graph&&e.state.niconicoGraphs?.get(e.graph.id)===e.graph){e.graph.status=status;update(e.state);}
    if(e.state.niconicoPlaylistPending?.get(e.url)===e.id)e.state.niconicoPlaylistPending.delete(e.url);
  };
  const drop=key=>{const s=early.get(key);if(!s)return;early.delete(key);clearTimeout(s.expiry);for(const e of active.values())if(e.state===s)release(e,'context_changed');};
  const prune=()=>{for(const [key,s] of early)if(Date.now()-s.created>TTL)drop(key);};
  const owner=d=>{
    const state=stateFor(d);
    if(state)return state.niconico&&d.frameId===0&&state.privateContext===d.incognito&&(!state.cookieStore||!d.cookieStoreId||state.cookieStore===d.cookieStoreId)?state:null;
    if(hasFrame(d)||!Number.isInteger(d.tabId)||d.tabId<0||d.frameId!==0||typeof d.incognito!=='boolean')return null;
    const page=d.documentUrl;if(!Thru3DNiconico.documentPage(page))return null;
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
    const id=Thru3DNiconico.page(s.page),rendered=s.niconicoRendered;
    let g=s.niconicoGraphs?.get(id);
    if(rendered?.id===id&&rendered.page===s.page){
      const master=s.niconicoPlaylists?.get(rendered.root)?.master;
      // The rendered facade supplies identity, never a made-up network request.
      // Only its exact already-observed root and declared children can bind.
      if(master)g={meta:{id,root:rendered.root},master,rendered:true,
        leaves:new Map([...s.niconicoPlaylists].filter(([,v])=>v.leaf).map(([u,v])=>[u,v.leaf])),status:'rendered_player'};
      else if(g?.meta?.root!==rendered.root)g=null;
    }
    s.niconicoMeta=g?.meta||null;s.niconicoMaster=g?.master||null;s.niconicoLeaves=g?.leaves||new Map();
    const values=Thru3DNiconico.records(s.niconicoMeta,s.niconicoMaster,s.niconicoLeaves,[...(s.items?.values()||[])],s.page);
    s.niconicoData=new Map(values.map(v=>[v.id,g?.rendered?{...v,binding:'rendered_player'}:v]));s.niconicoStatus=values.length?'normalized':g?.status||'idle';notify(s);
  };
  const attach=s=>{
    if(!s.niconico)return;prune();const matches=[...early].filter(([,value])=>same(value,s));if(matches.length!==1)return;
    const [key,value]=matches[0];early.delete(key);clearTimeout(value.expiry);
    s.niconicoGraphs=value.niconicoGraphs;s.niconicoPlaylists=value.niconicoPlaylists;s.niconicoPlaylistPending=value.niconicoPlaylistPending;
    for(const e of active.values())if(e.state===value)e.state=s;update(s);
  };
  const cancel=s=>{
    for(const e of active.values())if(e.state===s)release(e,'cancelled');
    for(const [key,value] of early)if(same(value,s))drop(key);
    s.niconicoGraphs?.clear();s.niconicoPlaylists?.clear();s.niconicoPlaylistPending?.clear();s.niconicoRootOwners?.clear();s.niconicoRendered=null;
    s.niconicoMeta=null;s.niconicoMaster=null;s.niconicoLeaves?.clear();s.niconicoData?.clear();
  };
  const navigate=d=>{for(const [key,s] of early)if(s.key===`${d.tabId}:${d.frameId}`||d.type==='main_frame'&&s.key.startsWith(`${d.tabId}:`))drop(key);};
  const resource=(s,url)=>[...(s.niconicoGraphs?.values()||[])].some(g=>[...g.leaves.values()].some(v=>v.resources.includes(url)))||
    [...(s.niconicoPlaylists?.values()||[])].some(v=>v.leaf?.resources.includes(url));
  const observeRendered=(s,value)=>{
    const previous=s.niconicoRootOwners?.get(value?.root);
    const other=[...(s.niconicoGraphs?.values()||[])].some(g=>g.meta?.root===value?.root&&g.id!==value?.id);
    s.niconicoRendered=value&&value.page===s.page&&value.id===Thru3DNiconico.page(s.page)&&Thru3DNiconico.address(value.root)&&
      !other&&(!previous||previous===value.id)?{id:value.id,page:value.page,root:value.root}:null;
    if(s.niconicoRendered){
      s.niconicoRootOwners ||=new Map();s.niconicoRootOwners.set(value.root,value.id);
      while(s.niconicoRootOwners.size>32)s.niconicoRootOwners.delete([...s.niconicoRootOwners.keys()].find(root=>root!==value.root));
    }
    update(s);
  };
  browser.webRequest.onBeforeRequest.addListener(d=>{
    if(!['GET','POST'].includes(d.method)||active.size>=8)return;
    const s=owner(d),u=Thru3DNiconico.address(d.url);if(!s||!u)return;
    const api=d.method==='POST'&&Thru3DNiconico.accessId(u.href);
    s.niconicoGraphs ||= new Map();
    let graph;
    if(api){
      graph={id:api,meta:null,master:null,leaves:new Map(),status:'observing'};
      s.niconicoGraphs.delete(api);s.niconicoGraphs.set(api,graph);
      while(s.niconicoGraphs.size>4){
        const current=Thru3DNiconico.page(s.page),id=[...s.niconicoGraphs.keys()].find(id=>id!==current&&id!==api);
        for(const e of active.values())if(e.state===s&&e.graph.id===id)release(e,'evicted');
        s.niconicoGraphs.delete(id);
      }
      update(s);
    }else{
      if(d.method!=='GET')return;
      const matches=[...s.niconicoGraphs.values()].filter(g=>u.href===g.meta?.root||g.master?.variants.some(v=>v.video===u.href||v.audio===u.href));
      if(matches.length>1)return;graph=matches[0]||null;
      const declared=[...(s.niconicoPlaylists?.values()||[])].some(v=>v.master?.variants.some(t=>t.video===u.href||t.audio===u.href));
      if(!graph&&!declared&&!/\.m3u8$/i.test(u.pathname))return;
    }
    const root=!api&&u.href===graph?.meta?.root;
    const limit=api?256*1024:root?Thru3DNiconico.MASTER_LIMIT:Thru3DNiconico.LEAF_LIMIT;
    let stream;try{stream=browser.webRequest.filterResponseData(d.requestId);}catch(_){return;}
    s.niconicoPlaylistPending ||= new Map();if(!api)s.niconicoPlaylistPending.set(u.href,d.requestId);
    const e={id:d.requestId,url:u.href,state:s,graph,stream,chunks:[],size:0,ok:null,stopped:false,released:false};active.set(e.id,e);
    e.timer=setTimeout(()=>release(e,'timeout'),TTL);
    const complete=()=>{
      if(e.released||!e.stopped||e.ok===null)return;
      if(!e.ok||owner(d)!==e.state||api&&e.state.niconicoGraphs?.get(graph.id)!==graph||
        !api&&e.state.niconicoPlaylistPending?.get(u.href)!==e.id){release(e,'context_changed');return;}
      e.released=true;clearTimeout(e.timer);active.delete(e.id);
      try{
        const bytes=new Uint8Array(e.size);let at=0;for(const c of e.chunks){bytes.set(c,at);at+=c.length;}
        const text=new TextDecoder('utf-8',{fatal:true}).decode(bytes),state=e.state;
        if(api){graph.meta=Thru3DNiconico.rights(JSON.parse(text),'https://www.nicovideo.jp/watch/'+graph.id);graph.status=graph.meta?'metadata':'invalid_data';}
        else {
          const master=Thru3DNiconico.master(text,u.href),leaf=master?null:Thru3DNiconico.leaf(text,u.href);
          state.niconicoPlaylists ||= new Map();state.niconicoPlaylists.delete(u.href);
          if(master||leaf)state.niconicoPlaylists.set(u.href,{master,leaf});
          while(state.niconicoPlaylists.size>32){
            const oldest=[...state.niconicoPlaylists.keys()].find(key=>key!==state.niconicoRendered?.root);
            state.niconicoPlaylists.delete(oldest);
          }
          state.niconicoPlaylistPending.delete(u.href);
          if(graph){if(root){graph.master=master;graph.status=master?'master':'unsupported_master';}
            else {if(leaf)graph.leaves.set(u.href,leaf);else graph.leaves.delete(u.href);graph.status=leaf?'leaf':'protected_or_invalid';}}
        }
        update(state);
      }catch(_){if(graph)graph.status='invalid_data';update(e.state);}
      finally{try{flush(e);stream.close();}catch(_){try{stream.disconnect();}catch(_){}e.detached=true;}}
    };
    e.complete=complete;e.api=api;
    stream.ondata=event=>{
      if(e.detached||e.released)return;
      if(e.size+event.data.byteLength>limit){try{flush(e);stream.write(event.data);}catch(_){}release(e,'oversize');return;}
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
  return {attach,cancel,navigate,observeMedia:update,observeRendered,resource};
};
