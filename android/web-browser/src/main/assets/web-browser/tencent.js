/* Observed Tencent metadata and the current main player. Never requests a site API. */
const Thru3DTencent = (() => {
  'use strict';
  const address = value => {
    try { const u=new URL(value);return u.protocol==='https:'&&!u.username&&!u.password&&!u.hash&&value.length<=16384?u:null; }
    catch(_){return null;}
  };
  const page = value => {
    const u=address(value);if(!u||u.hostname!=='v.qq.com'||u.port)return null;
    const clip=/^\/x\/page\/([A-Za-z0-9]{11})\.html$/.exec(u.pathname);
    const cover=/^\/x\/cover\/([A-Za-z0-9]{5,32})(?:\/([A-Za-z0-9]{11}))?\.html$/.exec(u.pathname);
    if(!clip&&!cover)return null;
    const ids=u.searchParams.getAll('vid');if(ids.length>1||ids.length&& !/^[A-Za-z0-9]{11}$/.test(ids[0]))return null;
    const id=clip?.[1]||cover?.[2]||ids[0]||'';
    if(ids.length&&id!==ids[0])return null;
    return {id,cover:cover?.[1]||''};
  };
  const canonical = (p,id) => p.cover ? `https://v.qq.com/x/cover/${p.cover}/${id}.html` : `https://v.qq.com/x/page/${id}.html`;
  const revision = text => {let h=2166136261;for(let i=0;i<text.length;i++)h=Math.imul(h^text.charCodeAt(i),16777619);return(h>>>0).toString(16);};
  const json=text=>{
    if(typeof text!=='string'||text.length>2*1024*1024)throw new Error('Invalid metadata text');
    text=text.trim().replace(/^\/\*\*\/\s*/,'');
    if(text.startsWith('{')&&text.endsWith(';'))text=text.slice(0,-1).trimEnd();
    if(!text.startsWith('{')){
      const callback=/^[A-Za-z_$][\w.$]{0,128}\s*\(\s*(\{[\s\S]*\})\s*\)\s*;?$/.exec(text);
      const assignment=/^(?:(?:var|let|const)\s+)?[A-Za-z_$][\w.$]{0,128}\s*=\s*(\{[\s\S]*\})\s*;?$/.exec(text);
      const match=callback||assignment;if(!match)throw new Error('Unsupported metadata wrapper');text=match[1];
    }
    const value=JSON.parse(text);if(!value||Array.isArray(value)||typeof value!=='object')throw new Error('Invalid metadata object');return value;
  };
  const payload=raw=>{
    if(raw&&Object.prototype.hasOwnProperty.call(raw,'ret')){
      if(raw.ret!==0||!raw.data||typeof raw.data!=='object')return null;
      if(raw.data.proxyhttp!=null){
        if(typeof raw.data.proxyhttp.vinfo!=='string')return null;
        raw=raw.data.proxyhttp;
      }else raw=raw.data.vinfo??raw.data.playInfo??raw.data;
    }
    if(typeof raw==='string')raw=json(raw);
    if(raw?.vinfo!=null)raw=typeof raw.vinfo==='string'?json(raw.vinfo):raw.vinfo;
    return raw;
  };
  const flow=value=>typeof value==='string'&&value.length>0&&value.length<=128&&!/[\x00-\x20\x7f]/.test(value)?value:'';
  const envelope=(raw,requested='')=>{
    const d=raw?.ret===0?raw.data:null,id=d?.playInfo?.vid,nonce=flow(d?.flowid);
    if(!/^[A-Za-z0-9]{11}$/.test(id||'')||requested&&requested!==id||!nonce||
      typeof d?.proxyhttp?.vinfo!=='string'||d.proxyhttp.vinfo.length>2*1024*1024||d.videoInfo?.vid&&d.videoInfo.vid!==id)return null;
    const duration=Number(d.videoInfo?.duration);
    return {id,flowid:nonce,duration:Number.isFinite(duration)&&duration>0&&duration<=86400?duration:0};
  };
  const normalize = (raw,requested='') => {
    try {
      const nonce=raw?.ret===0?flow(raw.data?.flowid):'';
      const stated=raw?.ret===0?raw.data?.playInfo?.vid:'';
      const declared=raw?.ret===0?Number(raw.data?.videoInfo?.duration):0;
      raw=payload(raw);
      const list=raw?.vl?.vi;if(!Array.isArray(list)||list.length!==1||Number(raw.code||0)!==0)return null;
      const v=list[0],id=v.vid==null||v.vid===''?stated:v.vid;
      if(!/^[A-Za-z0-9]{11}$/.test(id||'')||requested&&id!==requested||stated&&stated!==id)return null;
      const width=Number(v.vw),height=Number(v.vh),duration=Number(v.td),filename=v.fn;
      if(!Number.isInteger(width)||!Number.isInteger(height)||width<1||height<1||width>8192||height>8192||
        !Number.isFinite(duration)||duration<=0||duration>86400||typeof filename!=='string'||!/^[A-Za-z0-9_.-]{1,256}$/.test(filename))return null;
      // enc/drm are explicit flags in the observed response. The site's numeric
      // "encryption" string is also present for clear MP4; the native container
      // validator still rejects PSSH, encrypted samples and protected HLS.
      const clear=v.enc!=null&&v.drm!=null&&String(v.enc)==='0'&&String(v.drm)==='0';
      const preview=Number(raw.preview||0),full=Number(v.isprevid||0)===0&&Number.isFinite(preview)&&(preview===0||preview>=duration-2)&&
        (!(Number.isFinite(declared)&&declared>0)||Math.abs(declared-duration)<=Math.max(2,declared*.01));
      const urls=(v.ul?.ui||[]).map(u=>u.url).filter(u=>typeof u==='string'&&address(u)).slice(0,8);
      const playlist=typeof v.ul?.m3u8==='string'?v.ul.m3u8:'';
      if(playlist.length>160*1024)return null;
      const lines=playlist.split(/\r?\n/).map(s=>s.trim());
      const hls=playlist&&lines[0]==='#EXTM3U'&&lines.includes('#EXT-X-ENDLIST')&&
        !lines.some(l=>/^#EXT-X-(?:SESSION-)?KEY:/.test(l)&&!/^#EXT-X-(?:SESSION-)?KEY:METHOD=NONE(?:,|$)/.test(l));
      const timeline=hls?lines.filter(l=>l.startsWith('#EXTINF:')).reduce((n,l)=>n+Number(l.slice(8).split(',')[0]),0):duration;
      if(playlist&&!hls||!Number.isFinite(timeline)||timeline<duration-2||timeline>86400)return null;
      return {id,width,height,duration:timeline,content_duration:duration,filename,urls,playlist,
        clear,full,revision:revision([id,width,height,timeline,filename,playlist,...(nonce?[nonce]:[])].join('\n'))};
    }catch(_){return null;}
  };
  const requestMatches = (request,data) => {
    const u=address(request?.url);if(!u)return false;
    return request.kind==='file'&&u.pathname.endsWith('/'+data.filename)||request.kind==='hls'&&data.urls.includes(u.href);
  };
  const references = (data,base) => {
    try {return data.playlist.split(/\r?\n/).map(s=>s.trim()).filter(s=>s&&!s.startsWith('#')).map(s=>{
      const u=new URL(s,base);if(!address(u.href))throw new Error('Invalid HLS reference');return u.href;
    });}catch(_){return [];}
  };
  const binding = (video,records,requests,document) => {
    const p=page(document);if(!p||!video.closest?.('#main-player .txp_videos_container')||!video.isConnected||video.mediaKeys)return null;
    const matches=records.filter(d=>(!p.id||d.id===p.id)&&d.clear&&d.full&&d.width===video.videoWidth&&d.height===video.videoHeight&&
      Number.isFinite(video.duration)&&Math.abs(video.duration-d.duration)<=
        (d.playlist?Math.max(.5,d.duration*.0001):Math.max(2,d.duration*.01))).map(d=>{
        if(video.currentSrc?.startsWith('blob:')) {
          const manifest=d.urls.find(base=>{
            const refs=references(d,base);return refs.length>0&&requests.some(r=>r.kind==='segment'&&(refs.includes(r.url)||refs.includes(r.original_url)));
          });
          if(manifest)return {...d,manifest_url:manifest};
          if(!d.playlist&&requests.some(r=>requestMatches(r,d)))return d;
          return null;
        }
        return requests.some(r=>(r.url===video.currentSrc||r.original_url===video.currentSrc)&&requestMatches(r,d))?d:null;
      }).filter(Boolean);
    if(matches.length!==1)return null;
    const d=matches[0];return {...d,page:canonical(p,d.id)};
  };
  const diagnostics = (entries,policyAt) => {
    const result={api_resources:0,api_before_policy:0,api_script:0,api_xhr:0,api_fetch:0};
    for(const e of entries.slice(0,512)) {
      const u=address(e.name);if(!u||!['/getvinfo','/getinfo','/proxyhttp','/vinfo_proxy'].includes(u.pathname))continue;
      result.api_resources++;
      if(policyAt===null||e.startTime<policyAt)result.api_before_policy++;
      const type={script:'api_script',xmlhttprequest:'api_xhr',fetch:'api_fetch'}[e.initiatorType];if(type)result[type]++;
    }
    return result;
  };
  const shape=raw=>{
    const wrapped=typeof raw?.vinfo==='string';try{raw=payload(raw);}catch(_){}
    const list=raw?.vl?.vi,v=Array.isArray(list)?list[0]:null;
    return {json_ok:1,json_vinfo:wrapped?1:0,json_vi:Array.isArray(list)?Math.min(100,list.length):0,
      json_code_ok:Number(raw?.code||0)===0?1:0,json_id:/^[A-Za-z0-9]{11}$/.test(v?.vid||'')?1:0,
      json_size:Number(v?.vw)>0&&Number(v?.vh)>0?1:0,json_duration:Number(v?.td)>0?1:0,
      json_filename:typeof v?.fn==='string'&&/^[A-Za-z0-9_.-]{1,256}$/.test(v.fn)?1:0};
  };
  const describe=raw=>{
    const nodes=[],numeric=/^(?:ret|code|(?:video|audio|content|total|preview)?(?:width|height|duration|durationms|bitrate|fps|samplerate|channels)|enc|drm|drm_?flag|isprevid|vw|vh|td)$/i;
    const walk=(value,path,depth)=>{
      if(nodes.length>=96||depth>10)return;
      const kind=Array.isArray(value)?'array':value===null?'null':typeof value,node={path,kind};nodes.push(node);
      if(kind==='object'){
        const priority=['ret','data','proxyhttp','vinfo','code','em','vl','vi','vid','fn','vw','vh','td','enc','drm','isprevid','preview','ul','ui','m3u8','url','fl','fi'];
        const weight=k=>{const i=priority.indexOf(k);return i<0?100:i;};
        const keys=Object.keys(value).filter(k=>/^[A-Za-z_][A-Za-z0-9_]{0,63}$/.test(k)).sort((a,b)=>weight(a)-weight(b)).slice(0,32);
        node.keys=keys;for(const k of keys)walk(value[k],path+'.'+k,depth+1);
      }else if(kind==='array'){node.count=Math.min(value.length,4096);for(const child of value.slice(0,2))walk(child,path+'[]',depth+1);}
      else if(kind==='string'){
        node.chars=Math.min(value.length,2*1024*1024);
        if(path.endsWith('.vinfo')&&value.length<=2*1024*1024){
          try{const parsed=json(value);node.count=1;walk(parsed,path+'.json',depth+1);}catch(_){node.count=0;}
        }
      }
      else if(kind==='number'&&numeric.test(path.split('.').pop())&&Number.isFinite(value)&&Math.abs(value)<=1e9)node.sample=value;
    };
    const proxyCode=raw?.data?.proxyhttp?.errCode;
    if(typeof proxyCode==='number'&&Number.isFinite(proxyCode)&&Math.abs(proxyCode)<=1e9)nodes.push({path:'diagnostic.proxy.code',kind:'number',sample:proxyCode});
    const inner=raw?.data?.proxyhttp?.vinfo??raw?.vinfo;
    if(typeof inner==='string'){
      const text=inner.trim().replace(/^\/\*\*\/\s*/,'');
      const format=text.startsWith('{')?0:/^(?:(?:var|let|const)\s+)?[A-Za-z_$][\w.$]{0,128}\s*=/.test(text)?1:/^[A-Za-z_$][\w.$]{0,128}\s*\(/.test(text)?2:
        text.startsWith('<')?3:/^%7b/i.test(text)?4:/^[A-Za-z0-9+/_=-]+$/.test(text)?5:6;
      nodes.push({path:'diagnostic.vinfo_format.code',kind:'number',sample:format});
    }
    walk(raw,'response',0);while(JSON.stringify(nodes).length>32768)nodes.pop();return nodes;
  };
  // Read only primitive own data properties from the site's already processed
  // result. Never invoke page getters/functions or export extension capabilities.
  const pageState=(view,hints,document)=>{
    const result={status:0,id:'',data:null,shape:[],capture:{}},p=page(document);if(!view||!p)return result;
    const own=(object,key)=>object&&typeof object==='object'?Object.getOwnPropertyDescriptor(object,key)?.value:undefined;
    try{
      const state=own(view,'__VINFO_DATA__'),info=own(state,'playInfo'),proxy=own(state,'proxyhttp');
      const id=own(info,'vid'),nonce=own(state,'flowid'),body=own(proxy,'vinfo');result.status=1;
      if(!/^[A-Za-z0-9]{11}$/.test(id||'')||!flow(nonce)||typeof body!=='string'||body.length>2*1024*1024)return result;
      result.status=2;
      const hint=hints.find(h=>h.id===id&&h.flowid===nonce);
      if(p.id&&p.id!==id||!hint)return result;
      result.id=id;
      const raw={ret:0,data:{flowid:nonce,playInfo:{vid:id},videoInfo:{vid:id,duration:hint.duration||0},proxyhttp:{vinfo:body}}};
      result.shape=describe(raw);result.capture=shape(raw);result.data=normalize(raw,id);result.status=result.data?4:3;return result;
    }catch(_){result.status=5;return result;}
  };
  return {page,canonical,normalize,binding,requestMatches,references,diagnostics,shape,describe,json,envelope,pageState};
})();
