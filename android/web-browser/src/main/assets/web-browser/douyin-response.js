/* Observe only the website's video detail/feed responses, forwarding bytes first. */
const Thru3DDouyinResponses = (stateFor,publish,hasFrame) => {
  'use strict';
  const paths = ['/aweme/v1/web/aweme/detail/','/aweme/v1/web/aweme/related/','/aweme/v1/web/tab/feed/','/aweme/v1/web/aweme/post/'];
  const filter = {urls:paths.map(p=>'https://www.douyin.com'+p+'*'),types:['xmlhttprequest','other']};
  const active = new Map();
  // Cached API bodies may not pass through StreamFilter on reload. Retain only
  // reduced metadata for the same tab/frame, never a request or its credentials.
  // A new document still needs its own exact currentSrc request and decoded size.
  const documents = new Map(), observations=new Map(), ttl=1800000;
  const remember=state=>{
    if(!state.douyinData?.size)return;
    const now=Date.now();documents.delete(state.key);documents.set(state.key,{at:now,data:new Map(state.douyinData)});
    for(const [key,value] of documents)if(now-value.at>ttl)documents.delete(key);
    while(documents.size>8)documents.delete(documents.keys().next().value);
  };
  const restore=state=>{const cached=documents.get(state.key);if(cached&&Date.now()-cached.at<=ttl)state.douyinData=new Map(cached.data);
    const observed=observations.get(state.key);if(observed&&Date.now()-observed.at<30000&&
      (observed.document&&state.document?observed.document===state.document:observed.page===state.page))state.douyinObservation=observed.data;};
  const stop = e => { if (e.released) return; e.released=true;clearTimeout(e.timer);active.delete(e.id);e.chunks=[];try{e.stream.disconnect();}catch(_){} };
  const cancel = state => {for(const e of active.values())if(e.state===state)stop(e);};
  browser.webRequest.onBeforeRequest.addListener(d=>{
    let state=stateFor(d);const u=new URL(d.url);
    // A preload/detail XHR can beat the document's runtime port on cold load.
    // Trusted webRequest frame identity is enough to retain metadata, never
    // credentials; publication still needs the matching live document port.
    if(!state&&!hasFrame(d)&&d.tabId>=0&&Number.isInteger(d.frameId)&&Thru3DDouyin.documentPage(d.documentUrl))
      state={key:`${d.tabId}:${d.frameId}`,page:d.documentUrl,document:d.documentId,douyin:true};
    if(!state?.douyin || d.method!=='GET' || u.origin!=='https://www.douyin.com' || !paths.includes(u.pathname) || active.size>=4)return;
    let stream;try{stream=browser.webRequest.filterResponseData(d.requestId);}catch(_){return;}
    const requested=u.searchParams.get('aweme_id');
    const observation=u.pathname==='/aweme/v1/web/aweme/detail/'&&(!requested||requested===Thru3DDouyin.page(state.page)?.id)
      ?{started:1,worker:d.frameId<0?1:0,tabless_worker:d.tabId<0?1:0,prefetch:d.type==='other'?1:0,document_url_matches:d.documentUrl?.split('#')[0]===state.page.split('#')[0]?1:0,headers:0,status:0,body:0,bytes:0,parsed:0,detail:0,id_string:0,id_matches:0,normalized:0,video:0,ads:0,images:0,encrypted:0,drm_zero_string:0,tracks:0,dimensioned_tracks:0,https_addresses:0,duration_valid:0,data_detail:0,response_code:0}:null;
    if(observation){state.douyinObservation=observation;observations.delete(state.key);observations.set(state.key,{at:Date.now(),document:state.document,page:state.page,data:observation});while(observations.size>8)observations.delete(observations.keys().next().value);}
    const e={id:d.requestId,stream,state,observation,chunks:[],size:0,ok:null};active.set(e.id,e);
    e.timer=setTimeout(()=>stop(e),15000);
    stream.ondata=event=>{if(e.released)return;try{stream.write(event.data);}catch(_){stop(e);return;}
      if((e.size+=event.data.byteLength)>4*1024*1024){stop(e);return;}if(observation)observation.bytes=e.size;e.chunks.push(new Uint8Array(event.data).slice());};
    e.complete=()=>{
      if(e.released||!e.bodyDone||e.ok===null)return;
      e.released=true;clearTimeout(e.timer);active.delete(e.id);
      try{
        if(!e.ok)return;
        const live=stateFor(d);
        if(state.port&&live!==state||live&&d.frameId>=0&&d.documentId&&live.document&&d.documentId!==live.document)return;
        if(live)state=live;
        if(observation)state.douyinObservation=observation;
        const bytes=new Uint8Array(e.size);let n=0;for(const chunk of e.chunks){bytes.set(chunk,n);n+=chunk.length;}
        const raw=Thru3DDouyin.parse(new TextDecoder('utf-8',{fatal:true}).decode(bytes));
        if(observation){
          const detail=raw.aweme_detail,v=detail?.video;
          const tracks=[v?.play_addr,...(Array.isArray(v?.bit_rate)?v.bit_rate.slice(0,32).map(t=>t?.play_addr):[])].filter(Boolean);
          Object.assign(observation,{parsed:1,detail:detail?1:0,id_string:typeof detail?.aweme_id==='string'?1:0,
            id_matches:detail?.aweme_id===Thru3DDouyin.page(state.page)?.id?1:0,video:v?1:0,ads:detail?.is_ads?1:0,images:detail?.images?.length?1:0,
            encrypted:v&&(v.has_drm||v.is_drm||v.drm_type||v.is_encrypted)?1:0,
            drm_zero_string:v&&[v.has_drm,v.is_drm,v.drm_type,v.is_encrypted].includes('0')?1:0,
            tracks:tracks.length,dimensioned_tracks:tracks.filter(t=>Number.isInteger(t.width)&&Number.isInteger(t.height)&&t.width>0&&t.height>0).length,
            https_addresses:tracks.flatMap(t=>Array.isArray(t.url_list)?t.url_list:[]).filter(u=>Thru3DDouyin.address(u)).length,
            duration_valid:Number.isFinite(Number(v?.duration))&&Number(v.duration)>0?1:0,data_detail:raw.data?.aweme_detail?1:0,
            response_code:Number.isInteger(raw.status_code)?raw.status_code:-1});
        }
        if(raw.status_code!==0)return;
        const list=raw.aweme_detail?[raw.aweme_detail]:raw.aweme_list;
        if(!Array.isArray(list)||list.length>100)return;
        state.douyinData ||= new Map();
        for(const item of list.slice(0,16)){const data=Thru3DDouyin.normalize(item);if(item===raw.aweme_detail&&observation)observation.normalized=data?1:0;if(data){const merged=Thru3DDouyin.merge(state.douyinData.get(data.id),data,[...(state.items?.keys()||[])]);state.douyinData.delete(data.id);state.douyinData.set(data.id,merged);}}
        const current=Thru3DDouyin.page(state.page)?.id;
        while(state.douyinData.size>16||JSON.stringify([...state.douyinData.values()]).length>256*1024) {
          const key=[...state.douyinData.keys()].find(k=>k!==current);if(!key)break;state.douyinData.delete(key);
        }
        remember(state);
      }catch(_){}finally{e.chunks=[];if(state.port)publish(state);}
    };
    stream.onstop=()=>{if(e.released)return;e.bodyDone=true;if(observation)observation.body=1;try{stream.close();}catch(_){stop(e);return;}e.complete();};
    stream.onerror=()=>stop(e);
  },filter,['blocking']);
  browser.webRequest.onHeadersReceived.addListener(d=>{const e=active.get(d.requestId);if(!e)return;
    if(e.observation){e.observation.headers=1;e.observation.status=d.statusCode;}
    e.ok=d.statusCode===200&&(d.responseHeaders||[]).some(h=>h.name.toLowerCase()==='content-type'&&/^application\/json(?:;|$)/i.test(h.value||''));
    if(!e.ok)stop(e);else e.complete();},filter,['responseHeaders']);
  for(const event of [browser.webRequest.onErrorOccurred,browser.webRequest.onBeforeRedirect])event.addListener(d=>{const e=active.get(d.requestId);if(e)stop(e);},filter);
  return {cancel,restore};
};
