/* Passive diagnostics only. No request replay, page injection or private URL/body reports. */
const Thru3DYoukuRequestTrace = (() => {
  'use strict';
  const requests=new Map(),shapes=[],records=new Map(),observedHls=[];
  const page=value=>{try{const u=new URL(value);return u.protocol==='https:'&&u.hostname==='v.youku.com'&&/^\/v_show\/id_([A-Za-z0-9=]+)\.html$/.exec(u.pathname)?.[1]||null;}catch(_){return null;}};
  const safePath=value=>value.split('/').map(s=>['h5','ups','get.json','api','player','play'].includes(s)||/^mtop\.[a-z.]{1,100}$/.test(s)?s:s?'{id}':'').join('/').slice(0,180);
  const queryKeys=u=>[...new Set(u.searchParams.keys())].filter(k=>/^[A-Za-z_][A-Za-z0-9_]{0,63}$/.test(k)).slice(0,32);
  const filter={urls:['https://*/*']};
  browser.webRequest.onBeforeRequest.addListener(d=>{
    const id=page(d.documentUrl);if(!id||!['xmlhttprequest','script'].includes(d.type))return;
    const u=new URL(d.url);
    requests.set(d.requestId,{path:safePath(u.pathname),query_keys:queryKeys(u),type:d.type,frame:d.frameId,status:0,state:'requested'});
    while(requests.size>80)requests.delete(requests.keys().next().value);
    if(!/(?:\/ups\/get\.json$|\/mtop\.youku\.play\.ups\.appinfo\.get\/)/i.test(u.pathname))return;
    let stream;try{stream=browser.webRequest.filterResponseData(d.requestId);}catch(_){return;}
    let chunks=[],size=0;
    stream.ondata=e=>{stream.write(e.data);size+=e.data.byteLength;if(size<=2*1024*1024)chunks.push(new Uint8Array(e.data));else chunks=[];};
    stream.onerror=()=>{chunks=[];};
    stream.onstop=()=>{
      stream.close();const nodes=[],shape={path:safePath(u.pathname),bytes:size,parsed:false,nodes};
      try{
        if(size>2*1024*1024)throw new Error();
        const bytes=new Uint8Array(size);let offset=0;for(const c of chunks){bytes.set(c,offset);offset+=c.length;}
        let text=new TextDecoder().decode(bytes).trim();
        if(!text.startsWith('{')){const m=/^[A-Za-z_$][\w.$]{0,128}\s*\(\s*(\{[\s\S]*\})\s*\)\s*;?$/.exec(text);if(!m)throw new Error();text=m[1];}
        const root=JSON.parse(text);
        const normalized=typeof Thru3DYouku==='undefined'?null:Thru3DYouku.normalize(root,d.documentUrl);
        const key=`${d.tabId}:${d.frameId}`;
        const data=root?.data?.data;
        const normalization={api_match:root.api==='mtop.youku.play.ups.appinfo.get',success:root.ret?.length===1&&root.ret[0]==='SUCCESS::调用成功',
          error_zero:root.data?.e?.code===0,envelope_plain:root.data?.enc===0,id_match:data?.video?.encodeid===id,
          default_video:data?.video?.drm_type==='default',
          manifest_schemes:Array.isArray(data?.stream)?data.stream.slice(0,8).map(s=>{try{return new URL(s?.m3u8_url).protocol;}catch(_){return 'invalid';}}):[]};
        records.set(key,{page:d.documentUrl,document:d.documentId,data:normalized,normalization});while(records.size>8)records.delete(records.keys().next().value);
        const walk=(value,path,depth)=>{
          if(depth>7||nodes.length>=180)return;
          if(Array.isArray(value)){
            nodes.push({path,type:'array',count:value.length});
            if(!/\.(?:segs|ad|watermark|playlog)$/.test(path))for(const item of value.slice(0,2))walk(item,path+'[]',depth+1);
          }else if(value&&typeof value==='object'){
            const keys=Object.keys(value).filter(k=>/^[A-Za-z_][A-Za-z0-9_]{0,63}$/.test(k)).slice(0,40);
            nodes.push({path,type:'object',keys});
            const first=['ret','e','enc','data','preview','video','stream','ups','encodeid','seconds','drm_type','width','height','milliseconds_video','m3u8_url','stream_type'];
            const ordered=[...keys].sort((a,b)=>(first.includes(a)?first.indexOf(a):100)-(first.includes(b)?first.indexOf(b):100));
            for(const k of ordered)if(!['ad','ykad','user','uploader','watermark','playlog','controller','stream_ext','stream_types','tags','subcategories'].includes(k))walk(value[k],path+'.'+k,depth+1);
          }else{
            const key=path.split('.').pop(),node={path,type:typeof value};
            if(typeof value==='string'){
              node.chars=value.length;
              if(/^(?:id|vid|encodeid|videoid|video_id)$/i.test(key))node.current_id=value===id;
              if(/^(?:encrypt|drm|drm_type|stream_type|status|error|code|preview|pay_type|is_try|ispreview)$/i.test(key)&&/^[A-Za-z0-9_|-]{0,40}$/.test(value))node.enum=value;
              if(key==='ret')node.success=value==='SUCCESS::调用成功';
            }
            if(typeof value==='number'&&/^(?:(?:video_?)?(?:width|height|duration)|seconds|milliseconds_video|drm_type|preview|is_try|code|error|e|enc)$/i.test(key))node.value=value;
            if(typeof value==='boolean')node.value=value;
            nodes.push(node);
          }
        };
        walk(root,'response',0);shape.parsed=true;
      }catch(_){}
      chunks=[];shapes.push(shape);while(shapes.length>8)shapes.shift();
    };
  },filter,['blocking']);
  browser.webRequest.onHeadersReceived.addListener(d=>{
    const r=requests.get(d.requestId);if(r){r.status=d.statusCode;r.state='headers';}
    if(!page(d.documentUrl)||!r||![200,206].includes(d.statusCode))return;
    const mime=(d.responseHeaders||[]).find(h=>h.name.toLowerCase()==='content-type')?.value||'';
    if(!/mpegurl/i.test(mime)&&!new URL(d.url).pathname.endsWith('.m3u8'))return;
    observedHls.push({url:d.url,tab:d.tabId,frame:d.frameId,document:d.documentId,page:d.documentUrl});
    while(observedHls.length>16)observedHls.shift();
  },filter,['responseHeaders']);
  browser.webRequest.onCompleted.addListener(d=>{const r=requests.get(d.requestId);if(r){r.status=d.statusCode;r.state='completed';}},filter);
  browser.webRequest.onErrorOccurred.addListener(d=>{const r=requests.get(d.requestId);if(r)r.state='error';},filter);
  return {snapshot:(media=[],sender={})=>{
    const record=records.get(`${sender.tab?.id}:${sender.frameId}`);
    const same=record&&record.page===sender.url&&(!record.document||!sender.documentId||record.document===sender.documentId);
    const data=same?record.data:null;
    const observed=observedHls.filter(r=>r.tab===sender.tab?.id&&r.frame===sender.frameId&&r.page===sender.url&&
      (!r.document||!sender.documentId||r.document===sender.documentId));
    const programme=data?{id:data.id,duration:data.duration,streams:data.streams.length,
      matches:media.map(v=>({id:String(v.id),width:v.width,height:v.height,
        same_duration:Math.abs(v.duration-data.duration)<=2,
        observed_hls:data.streams.filter(s=>s.width===v.width&&s.height===v.height&&
          [...(v.network||[]).filter(r=>r.kind==='hls'),...observed].some(r=>Thru3DYouku.sameManifest(s.url,r.url)||Thru3DYouku.sameManifest(s.url,r.original_url))).length}))}:null;
    return {requests:[...requests.values()],shapes,programme,normalization:same?record.normalization:null};
  }};
})();
