/* Observed Mango metadata and invocation URLs. No API replay or page-code execution. */
const Thru3DMango = (() => {
  'use strict';
  const address = value => {
    try {
      if(typeof value!=='string'||value.length>16384)return null;
      const u=new URL(value);
      return u.protocol==='https:'&&!u.username&&!u.password&&!u.hash?u:null;
    }catch(_){return null;}
  };
  const page = value => {
    const u=address(value);
    if(!u||u.port||!['mgtv.com','www.mgtv.com','w.mgtv.com'].includes(u.hostname))return null;
    const id=/^\/(?:s|b|v)\/(?:[A-Za-z0-9_-]+\/)*([1-9][0-9]{0,19})\.html$/.exec(u.pathname)?.[1];
    return id?{id}:null;
  };
  const json = text => {
    if(typeof text!=='string'||text.length>2*1024*1024)throw new Error('Invalid metadata text');
    text=text.trim();
    if(!text.startsWith('{')){
      const match=/^[A-Za-z_$][\w.$]{0,128}\s*\(\s*(\{[\s\S]*\})\s*\)\s*;?$/.exec(text);
      if(!match)throw new Error('Invalid metadata wrapper');text=match[1];
    }
    const value=JSON.parse(text);
    if(!value||Array.isArray(value)||typeof value!=='object')throw new Error('Invalid metadata object');
    return value;
  };
  const success = raw => raw&&['0','200'].includes(String(raw.code));
  const video = (raw,requested) => {
    const info=raw?.data?.info,drm=raw?.data?.drm;
    if(!/^[1-9][0-9]{0,19}$/.test(requested)||!success(raw)||!info||
      typeof info.video_id==='number'&&!Number.isSafeInteger(info.video_id)||String(info.video_id)!==requested)return null;
    const duration=Number(info.duration);
    if(!Number.isFinite(duration)||duration<=0||duration>172800)return null;
    const clear=String(info.drmFlag)==='0'&&!!drm&&typeof drm==='object'&&!Array.isArray(drm)&&
      ['licenseUrl','drmFirm','drmType'].every(k=>drm[k]==='');
    const trial=Number(info.trialtime);
    return {id:requested,duration,clear,...(Number.isFinite(trial)&&trial>0&&trial<duration-2?{trial_duration:trial}:{})};
  };
  const sources = (raw,requested,metadata) => {
    const d=raw?.data;
    if(!metadata||metadata.id!==requested||!metadata.clear||!success(raw)||
      !Array.isArray(d?.stream_domain)||d.stream_domain.length<1||d.stream_domain.length>8||
      !Array.isArray(d.stream)||d.stream.length<1||d.stream.length>16)return [];
    const urls=new Set();
    for(const domain of d.stream_domain){
      if(!address(domain))continue;
      for(const stream of d.stream){
        if(typeof stream.url!=='string'||!stream.url||stream.url.length>16384)continue;
        try{
          if(!stream.url.startsWith('/')&&!address(stream.url))continue;
          const u=address(new URL(stream.url,domain).href);if(u)urls.add(u.href);
        }catch(_){}
      }
    }
    return [...urls];
  };
  const matchDispatch = (declared,actual) => {
    const u=address(actual);if(!u||!Array.isArray(declared)||declared.length>128)return null;
    // The actual JSONP invocation adds browser IDs and a callback. Keep every
    // declared parameter and its multiplicity; added media selectors are rejected.
    const matches=[...new Set(declared)].filter(value=>{
      const base=address(value);if(!base||base.origin!==u.origin||base.pathname!==u.pathname)return false;
      for(const key of new Set(base.searchParams.keys())){
        const expected=base.searchParams.getAll(key),values=u.searchParams.getAll(key);
        if(expected.length!==values.length||expected.some((v,i)=>v!==values[i]))return false;
      }
      for(const key of new Set(u.searchParams.keys()))if(!base.searchParams.has(key)){
        if(!['callback','did','suuid'].includes(key)||u.searchParams.getAll(key).length!==1)return false;
        const value=u.searchParams.get(key);
        if(!value||value.length>256||/[\x00-\x20\x7f]/.test(value)||key==='callback'&&!/^[A-Za-z_$][\w.$]{0,128}$/.test(value))return false;
      }
      return true;
    });
    return matches.length===1?matches[0]:null;
  };
  const manifest = raw => raw?.status==='ok' ? address(raw.info)?.href||null : null;
  // New SDK streamList embeds the selected dispatch response in stream.disp.
  // It is a declaration only: a successful same-document HLS is still required.
  const inline = (raw,requested,metadata) => {
    if(!metadata?.clear||metadata.id!==requested||!success(raw)||!Array.isArray(raw.data?.stream)||raw.data.stream.length>16)return [];
    const hevc=raw.data.stream_h265;
    if(hevc!=null&&(!Array.isArray(hevc)||hevc.length>16))return [];
    const entries=new Map();
    for(const stream of [...raw.data.stream,...(hevc||[])]){
      const url=manifest(stream?.disp),width=Number(stream?.videoWidth),height=Number(stream?.videoHeight);
      if(!url||!Number.isInteger(width)||!Number.isInteger(height)||width<1||height<1||width>16384||height>16384)continue;
      entries.set(JSON.stringify([url,width,height]),{url,width,height});
    }
    return entries.size<=16?[...entries.values()]:[];
  };
  const matchInline = (declared,actual) => {
    const u=address(actual);if(!u||!Array.isArray(declared)||declared.length>16)return null;
    const matches=declared.filter(entry=>{
      const base=address(entry?.url);if(!base||base.origin!==u.origin||base.pathname!==u.pathname)return false;
      for(const key of new Set(base.searchParams.keys())){
        if(JSON.stringify(base.searchParams.getAll(key))!==JSON.stringify(u.searchParams.getAll(key)))return false;
      }
      // Observed SDK timing counters; every declared media parameter is unchanged.
      for(const key of new Set(u.searchParams.keys()))if(!base.searchParams.has(key)){
        if(!['ftc','sftc'].includes(key)||u.searchParams.getAll(key).length!==1)return false;
        const value=u.searchParams.get(key);if(!value||value.length>256||/[\x00-\x20\x7f]/.test(value))return false;
      }
      return true;
    });
    return matches.length===1?matches[0]:null;
  };
  const files = (raw,requested,metadata) => {
    if(!metadata?.clear||metadata.id!==requested||!sources(raw,requested,metadata).length)return [];
    // New SDKs can leave the dispatch URL empty for a file they load through
    // another route. A hash is only an identity hint, never a constructed URL:
    // network.js must still observe that exact document's successful HLS.
    // Android's SDK can remember HEVC support after its first AVC playback.
    // The next streamList declares that family's different file identities.
    // Keep the existing clear/current-ID graph and successful request checks.
    const hevc=raw.data.stream_h265;
    if(hevc!=null&&(!Array.isArray(hevc)||hevc.length>16))return [];
    const files=[...new Set([...raw.data.stream,...(hevc||[])].filter(s=>typeof s?.fileHash==='string'&&/^[a-f0-9]{32,64}$/i.test(s.fileHash)).map(s=>s.fileHash.toLowerCase()))];
    return files.length<=16?files:[];
  };
  const matchFile = (declared,actual) => {
    const u=address(actual);if(!u||!Array.isArray(declared)||declared.length>16)return null;
    const leaf=u.pathname.split('/').pop().toLowerCase();
    const matches=[...new Set(declared)].filter(hash=>/^[a-f0-9]{32,64}$/.test(hash)&&leaf===hash+'.m3u8');
    return matches.length===1?matches[0]:null;
  };
  const expectedDuration = (data,v) => {
    if(Math.abs(v.duration-data.duration)<=2)return data.duration;
    const trial=data.trial_duration;
    return Number.isFinite(trial)&&trial>0&&trial<data.duration-2&&Math.abs(v.duration-trial)<=2&&
      data.inline_manifests?.some(r=>r.width===v.videoWidth&&r.height===v.videoHeight&&data.manifests?.includes(r.url))?trial:0;
  };
  const owner = (records,document,live) => {
    const p=page(document);if(!p||!Array.isArray(records)||!Array.isArray(live))return null;
    const data=records.filter(d=>d.id===p.id&&d.clear&&Number.isFinite(d.duration)&&d.duration>0);
    if(data.length!==1)return null;
    const matching=live.filter(v=>v.isConnected&&v.closest?.('#mgtv-player-wrap')&&!v.mediaKeys&&v.readyState>=1&&
      (v.currentSrc||'').startsWith('blob:')&&v.videoWidth>0&&v.videoHeight>0&&Number.isFinite(v.duration)&&
      v.duration>0&&v.duration<=172800&&expectedDuration(data[0],v)>0);
    if(matching.length!==1)return null;
    const main=matching[0],box=main.closest('#mgtv-player-wrap');
    if(main.closest?.('mango-ad-layer, .mango-ad-layer, .as_stage-item'))return null;
    // The new SDK preloads a complete main video while a separate ad is on air.
    // Do not transfer that parked programme until its player has finished the ad.
    const onAir=live.some(v=>{
      if(v===main||v.closest?.('#mgtv-player-wrap')!==box)return false;
      const ad=v.closest?.('mango-ad-layer, .mango-ad-layer');
      if(!ad&&(v.paused!==false||v.ended))return false;
      const rect=v.getBoundingClientRect?.();if(rect&&(rect.width<=0||rect.height<=0))return false;
      const layer=ad||v;
      const style=typeof getComputedStyle==='function'?getComputedStyle(layer):null;
      return !style||style.display!=='none'&&style.visibility!=='hidden'&&style.opacity!=='0';
    });
    return onAir?null:main;
  };
  const binding = (video,records,requests,document,live) => {
    if(owner(records,document,live)!==video)return null;
    const data=records.find(d=>d.id===page(document).id&&d.clear);
    if(!/^[a-f0-9]{1,8}$/.test(data.revision||'')||!Array.isArray(data.manifests)||data.manifests.length<1||data.manifests.length>8||
      data.manifests.some(value=>!address(value))||video.videoWidth>16384||video.videoHeight>16384)return null;
    const expected=expectedDuration(data,video),preview=expected!==data.duration;
    const manifests=preview?[...new Set((data.inline_manifests||[]).filter(r=>r.width===video.videoWidth&&r.height===video.videoHeight&&data.manifests.includes(r.url)).map(r=>r.url))]:data.manifests;
    const observed=requests.filter(r=>r.kind==='hls'&&(manifests.includes(r.url)||manifests.includes(r.original_url)));
    if(!observed.length||new Set(observed.map(r=>r.url)).size>6)return null;
    return {id:data.id,page:document,clear:true,revision:data.revision,manifests,
      expected_duration:expected,program_duration:data.duration,preview,preview_duration:preview?data.trial_duration:0,
      duration:video.duration,width:video.videoWidth,height:video.videoHeight};
  };
  return {address,page,json,video,sources,matchDispatch,manifest,inline,matchInline,files,matchFile,owner,binding};
})();
