/* Passive forwarding of the player's own successful metadata responses. No request replay. */
const Thru3DTencentResponses = (stateFor,publish,hasFrame) => {
  'use strict';
  hasFrame ||= ()=>false;
  const filter={urls:['https://*/getvinfo*','https://*/getinfo*','https://*/proxyhttp*','https://*/vinfo_proxy*'],types:['xmlhttprequest','script','other']};
  const active=new Map(),early=new Map(),TTL=15000;
  const same=(a,b)=>a.key===b.key&&a.page===b.page&&a.privateContext===b.privateContext&&
    (!a.document||!b.document||a.document===b.document)&&(!a.cookieStore||!b.cookieStore||a.cookieStore===b.cookieStore);
  const notify=state=>{if(!state.early)publish(state);};
  const drop=key=>{
    const state=early.get(key);if(!state)return;early.delete(key);clearTimeout(state.expiry);state.tencentData?.clear();state.tencentEnvelopes?.clear();
    for(const e of active.values())if(e.state===state)release(e,'context_changed');
  };
  const prune=()=>{for(const [key,state] of early)if(Date.now()-state.created>TTL)drop(key);};
  const owner=d=>{
    const current=stateFor(d);if(current)return current;
    if(hasFrame(d)||!Number.isInteger(d.tabId)||d.tabId<0||!Number.isInteger(d.frameId)||d.frameId<0||typeof d.incognito!=='boolean')return null;
    const page=d.documentUrl||d.originUrl;if(!Thru3DTencent.page(page))return null;
    try{if(d.originUrl&&new URL(d.originUrl).origin!==new URL(page).origin)return null;}catch(_){return null;}
    prune();const key=`${d.tabId}:${d.frameId}:${d.documentId||''}:${page}`;
    if(!early.has(key)){
      const state={key:`${d.tabId}:${d.frameId}`,page,document:d.documentId,
        privateContext:d.incognito,cookieStore:d.cookieStoreId||'',tencent:true,early:true,created:Date.now()};
      early.set(key,state);state.expiry=setTimeout(()=>drop(key),TTL);
    }
    while(early.size>16)drop(early.keys().next().value);
    return early.get(key);
  };
  const release=(e,reason)=>{
    if(e.released)return;e.released=true;clearTimeout(e.timer);active.delete(e.id);e.chunks=[];
    try{e.stream.disconnect();e.detached=true;}catch(_){}
    e.state.tencentStatus=reason;notify(e.state);
  };
  const cancel=state=>{for(const e of active.values())if(e.state===state)release(e,'cancelled');
    for(const [key,value] of early)if(same(value,state))drop(key);};
  const attach=state=>{
    if(!state.tencent)return;prune();
    const matches=[...early].filter(([,value])=>same(value,state));if(matches.length!==1)return;
    for(const [key,value] of matches){
      early.delete(key);clearTimeout(value.expiry);state.tencentData=value.tencentData;state.tencentEnvelopes=value.tencentEnvelopes;state.tencentStatus=value.tencentStatus;state.tencentCapture=value.tencentCapture;state.tencentShape=value.tencentShape;
      for(const e of active.values())if(e.state===value)e.state=state;
      notify(state);
    }
  };
  const navigate=d=>{
    const matches=state=>state.key===`${d.tabId}:${d.frameId}`||d.type==='main_frame'&&state.key?.startsWith(`${d.tabId}:`);
    for(const [key,value] of early)if(matches(value))drop(key);
  };
  browser.webRequest.onBeforeRequest.addListener(d=>{
    const state=owner(d);if(!state?.tencent||!Thru3DTencent.page(state.page)||!['GET','POST'].includes(d.method))return;
    const u=new URL(d.url);if(!['/getvinfo','/getinfo','/proxyhttp','/vinfo_proxy'].includes(u.pathname)||active.size>=8)return;
    const ids=u.searchParams.getAll('vid');if(ids.length>1||ids.length&&!/^[A-Za-z0-9]{11}$/.test(ids[0]))return;
    let stream;try{stream=browser.webRequest.filterResponseData(d.requestId);}catch(_){return;}
    const e={id:d.requestId,state,stream,chunks:[],size:0,ok:null,stopped:false,released:false};active.set(e.id,e);
    state.tencentCapture||={response_seen:0,early_responses:0};state.tencentCapture.response_seen++;
    if(state.early)state.tencentCapture.early_responses++;
    state.tencentStatus='observing';notify(state);
    e.timer=setTimeout(()=>release(e,'timeout'),15000);
    e.complete=()=>{
      if(e.released||!e.stopped||e.ok===null)return;
      if(!e.ok||owner(d)!==e.state){release(e,'context_changed');return;}
      e.released=true;clearTimeout(e.timer);active.delete(e.id);
      try {
        const body=new Uint8Array(e.size);let offset=0;for(const c of e.chunks){body.set(c,offset);offset+=c.length;}
        const text=new TextDecoder('utf-8',{fatal:true}).decode(body);
        const state=e.state,raw=Thru3DTencent.json(text),shape=Thru3DTencent.shape(raw),data=Thru3DTencent.normalize(raw,ids[0]||'');
        if(u.pathname==='/vinfo_proxy')state.tencentShape=Thru3DTencent.describe(raw);
        const hint=Thru3DTencent.envelope(raw,ids[0]||'');
        if(hint){
          state.tencentEnvelopes||=new Map();state.tencentEnvelopes.delete(hint.flowid);state.tencentEnvelopes.set(hint.flowid,hint);
          while(state.tencentEnvelopes.size>8)state.tencentEnvelopes.delete(state.tencentEnvelopes.keys().next().value);
        }
        Object.assign(state.tencentCapture,shape);
        if(data){
          state.tencentData||=new Map();const key=data.id+':'+data.revision;
          state.tencentData.delete(key);state.tencentData.set(key,data);
          while(state.tencentData.size>8||JSON.stringify([...state.tencentData.values()]).length>192*1024)state.tencentData.delete(state.tencentData.keys().next().value);
        }
        state.tencentStatus=data?'normalized':'unsupported_data';notify(state);
      }catch(_){e.state.tencentStatus='invalid_data';notify(e.state);}
      finally{e.chunks=[];}
    };
    stream.ondata=event=>{
      if(e.detached)return;
      try{stream.write(event.data);}catch(_){release(e,'stream_error');return;}
      if(e.released)return;
      if((e.size+=event.data.byteLength)>2*1024*1024){release(e,'oversize');return;}
      e.chunks.push(new Uint8Array(event.data).slice());
    };
    stream.onstop=()=>{if(e.detached)return;e.stopped=true;try{stream.close();}catch(_){release(e,'stream_error');return;}if(!e.released)e.complete();};
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
  return {cancel,attach,navigate};
};
