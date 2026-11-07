/* Anonymous research only: forward original bytes, retain bounded schema, never replay requests. */
const Thru3DIqiyiRequestTrace = (() => {
  'use strict';
  const requests=new Map(),responses=[],unattributed=[];
  const page=value=>{try{const u=new URL(value);return u.protocol==='https:'&&!u.username&&!u.password&&!u.port&&u.hostname==='www.iqiyi.com'&&/^\/([vw]_[A-Za-z0-9]+)\.html$/.exec(u.pathname)?.[1]||null;}catch(_){return null;}};
  const owner=d=>({tab:d.tabId,frame:d.frameId,document:d.documentId,page:d.documentUrl});
  const keys=value=>value&&typeof value==='object'?Object.keys(value).filter(k=>/^[A-Za-z_][A-Za-z0-9_]{0,63}$/.test(k)).slice(0,48):[];
  const shape=root=>{
    const nodes=[];
    const walk=(value,path,depth)=>{
      if(depth>8||nodes.length>=240)return;
      if(Array.isArray(value)){
        nodes.push({path,type:'array',count:value.length});
        for(const item of value.slice(0,2))walk(item,path+'[]',depth+1);
      }else if(value&&typeof value==='object'){
        const names=keys(value);nodes.push({path,type:'object',keys:names});
        const first=['code','data','program','video','audio','duration','stl','bid','ff','scrsz','m3u8','drmType','drm_type','isSel','fs'];
        names.sort((a,b)=>(first.includes(a)?first.indexOf(a):100)-(first.includes(b)?first.indexOf(b):100));
        for(const k of names)if(!/^(?:user|userInfo|account|ads|ad|statistics|log|cookie|token)$/i.test(k))walk(value[k],path+'.'+k,depth+1);
      }else{
        const name=path.split('.').pop(),node={path,type:value===null?'null':typeof value};
        if(typeof value==='string'){
          node.chars=value.length;
          if(/^(?:code|ff|drmType|drm_type|encryption_scheme|status|codec|vcodec|acodec|isSel|bid)$/i.test(name)&&/^[A-Za-z0-9_|-]{0,32}$/.test(value))node.enum=value;
          if(name==='m3u8'){
            const text=value.trim();node.hls=text.startsWith('#EXTM3U');
            if(node.hls){node.key_tags=(text.match(/#EXT-X-KEY:/g)||[]).length;node.endlist=text.includes('#EXT-X-ENDLIST');}
            else if(text.startsWith('{')&&text.length<=2*1024*1024){
              try{const descriptor=JSON.parse(text);node.json_descriptor=true;walk(descriptor,path+'.descriptor',depth+1);}catch(_){}
            }
          }
        }
        if(typeof value==='number'&&/^(?:code|duration|dur|stl|bid|ff|drmType|drm_type|isSel|width|height|fps|fr|real_bit_rate|vsize|bytes|length|lmt|prv)$/i.test(name))node.value=value;
        if(typeof value==='boolean'&&/^(?:isSel|selected|preview|trial|encrypted|drm)$/i.test(name))node.value=value;
        nodes.push(node);
      }
    };
    walk(root,'response',0);return nodes;
  };
  const filter={urls:['https://*/*','http://*/*']};
  browser.webRequest.onBeforeRequest.addListener(d=>{
    let u;try{u=new URL(d.url);}catch(_){return;}
    const dash=/\/dash$/.test(u.pathname),accelerator=u.pathname==='/player/lw/lwplay/accelerator.js',
      extension=/\.(m3u8|mp4|m4a|m4s|ts|f4v)$/i.exec(u.pathname)?.[1]?.toLowerCase();
    if(!page(d.documentUrl)){
      const origin=value=>{try{return new URL(value).origin==='https://www.iqiyi.com';}catch(_){return false;}};
      if(dash&&(origin(d.documentUrl)||origin(d.originUrl))){
        unattributed.push({tab:d.tabId,frame:d.frameId,document_present:!!d.documentUrl,document_id:!!d.documentId,
          origin_page:!!page(d.originUrl),document_origin:origin(d.documentUrl)});
        while(unattributed.length>16)unattributed.shift();
      }
      return;
    }
    if(!dash&&!accelerator&&!extension&&!['xmlhttprequest','media'].includes(d.type))return;
    const record={...owner(d),kind:dash?'dash':accelerator?'accelerator':extension||'api',type:d.type,status:0,state:'requested',
      query_keys:[...new Set(u.searchParams.keys())].filter(k=>/^[A-Za-z_][A-Za-z0-9_]{0,63}$/.test(k)).slice(0,40)};
    requests.set(d.requestId,record);while(requests.size>96)requests.delete(requests.keys().next().value);
    if(!dash&&!accelerator)return;
    let stream;try{stream=browser.webRequest.filterResponseData(d.requestId);}catch(_){record.filter='unavailable';return;}
    let chunks=[],size=0;
    stream.ondata=e=>{stream.write(e.data);size+=e.data.byteLength;if(size<=2*1024*1024)chunks.push(new Uint8Array(e.data));else chunks=[];};
    stream.onerror=()=>{chunks=[];record.filter='error';};
    stream.onstop=()=>{
      stream.close();const response={...owner(d),kind:record.kind,bytes:size,parsed:false,nodes:[]};
      try{
        if(size>2*1024*1024)throw new Error();
        const bytes=new Uint8Array(size);let at=0;for(const chunk of chunks){bytes.set(chunk,at);at+=chunk.length;}
        let text=new TextDecoder().decode(bytes).trim();
        if(!text.startsWith('{')){const m=/^[A-Za-z_$][\w.$]{0,128}\s*\(\s*(\{[\s\S]*\})\s*\)\s*;?$/.exec(text);if(!m)throw new Error();text=m[1];}
        response.nodes=shape(JSON.parse(text));response.parsed=true;
      }catch(_){}
      chunks=[];responses.push(response);while(responses.length>8)responses.shift();
    };
  },filter,['blocking']);
  browser.webRequest.onHeadersReceived.addListener(d=>{
    const r=requests.get(d.requestId);if(!r)return;r.status=d.statusCode;r.state='headers';
    const mime=(d.responseHeaders||[]).find(h=>h.name.toLowerCase()==='content-type')?.value||'';
    r.mime=/mpegurl/i.test(mime)?'hls':/json/i.test(mime)?'json':/^video\//i.test(mime)?'video':/^audio\//i.test(mime)?'audio':'other';
  },filter,['responseHeaders']);
  browser.webRequest.onCompleted.addListener(d=>{const r=requests.get(d.requestId);if(r){r.status=d.statusCode;r.state='completed';}},filter);
  browser.webRequest.onErrorOccurred.addListener(d=>{const r=requests.get(d.requestId);if(r){r.state='error';r.error=/^NS_[A-Z0-9_]{1,80}$/.test(d.error||'')?d.error:'other';}},filter);
  return {snapshot:(sender={})=>{
    const matches=r=>r.tab===sender.tab?.id&&r.frame===sender.frameId&&r.page===sender.url&&
      (!r.document||!sender.documentId||r.document===sender.documentId);
    const safe=r=>Object.fromEntries(Object.entries(r).filter(([k])=>!['tab','frame','document','page'].includes(k)));
    return {requests:[...requests.values()].filter(matches).map(safe),responses:responses.filter(matches).map(safe),
      unattributed_dash:unattributed.filter(r=>r.tab===sender.tab?.id).map(safe)};
  }};
})();
