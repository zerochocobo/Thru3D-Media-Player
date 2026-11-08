/* Current Youku programme declarations. No API replay or credential construction.
 * A default stream declaration is not DRM clearance: native probing must also
 * reject protected manifests/segments before this can become a playable Beta. */
const Thru3DYouku = (() => {
  'use strict';
  const address=value=>{
    try{if(typeof value!=='string'||value.length>16384)return null;const u=new URL(value);
      return /^https?:$/.test(u.protocol)&&!u.username&&!u.password&&!u.hash?u:null;}catch(_){return null;}
  };
  const page=value=>{
    const u=address(value);if(!u||u.protocol!=='https:'||u.port||u.hostname!=='v.youku.com')return null;
    let path;try{path=decodeURIComponent(u.pathname);}catch(_){return null;}
    const id=/^\/v_show\/id_(X[A-Za-z0-9=]{1,127})\.html$/.exec(path)?.[1];
    return id?{id}:null;
  };
  const json=text=>{
    if(typeof text!=='string'||text.length>2*1024*1024)throw new Error('Invalid metadata');
    text=text.trim();if(!text.startsWith('{')){
      const m=/^[A-Za-z_$][\w.$]{0,128}\s*\(\s*(\{[\s\S]*\})\s*\)\s*;?$/.exec(text);
      if(!m)throw new Error('Invalid metadata wrapper');text=m[1];
    }
    const raw=JSON.parse(text);if(!raw||Array.isArray(raw)||typeof raw!=='object')throw new Error('Invalid metadata object');return raw;
  };
  const duration=value=>Number.isFinite(value)&&value>0&&value<=172800;
  const revision=value=>{let h=2166136261;for(let i=0;i<value.length;i++)h=Math.imul(h^value.charCodeAt(i),16777619);return(h>>>0).toString(16);};
  const sameManifest=(declared,observed)=>{
	const a=address(declared),b=address(observed);if(!a||!b)return false;
	// UPS currently declares HTTP; Gecko's secure page upgrades that exact URL.
	// This compares observations, never constructs a request or copies credentials.
	return (a.protocol===b.protocol||a.protocol==='http:'&&b.protocol==='https:')&&a.host===b.host&&a.pathname===b.pathname&&a.search===b.search;
  };
  const normalize=(raw,document)=>{
    const p=page(document),envelope=raw?.data,data=envelope?.data,video=data?.video;
    if(!p||raw?.api!=='mtop.youku.play.ups.appinfo.get'||!Array.isArray(raw.ret)||raw.ret.length!==1||raw.ret[0]!=='SUCCESS::调用成功'||
      envelope?.e?.code!==0||envelope.enc!==0||video?.encodeid!==p.id||video.drm_type!=='default'||
      !duration(video.seconds)||!Array.isArray(data.stream)||!data.stream.length||data.stream.length>32)return null;
    const streams=[];
    for(const track of data.stream){
      const url=address(track?.m3u8_url),seconds=track?.milliseconds_video/1000;
      if(!url||track.drm_type!=='default'||!duration(seconds)||Math.abs(seconds-video.seconds)>2||
        !Number.isInteger(track.width)||!Number.isInteger(track.height)||track.width<1||track.height<1||track.width>16384||track.height>16384)continue;
      streams.push({url:url.href,width:track.width,height:track.height,duration:seconds});
    }
    if(!streams.length)return null;
    const result={id:p.id,duration:video.seconds,streams};
    return {...result,revision:revision(JSON.stringify(result))};
  };
  const visible=element=>{
    const rect=element.getBoundingClientRect?.();if(rect&&(rect.width<=0||rect.height<=0))return false;
    const style=typeof getComputedStyle==='function'?getComputedStyle(element):null;
    return !style||style.display!=='none'&&style.visibility!=='hidden'&&style.opacity!=='0';
  };
  const owner=(records,document,live)=>{
    const p=page(document);if(!p||!Array.isArray(records)||!Array.isArray(live))return null;
    const current=records.filter(r=>r?.id===p.id&&duration(r.duration)&&Array.isArray(r.streams));
    if(current.length!==1)return null;
    const mains=live.filter(v=>v.isConnected&&v.closest?.('#ykPlayer .video-layer')&&!v.closest?.('.advertise-layer')&&
      !v.mediaKeys&&v.readyState>=1&&(v.currentSrc||'').startsWith('blob:')&&v.videoWidth>0&&v.videoHeight>0&&
      duration(v.duration)&&Math.abs(v.duration-current[0].duration)<=2);
    if(mains.length!==1)return null;
    const main=mains[0],box=main.closest('#ykPlayer');if(!box)return null;
    const ads=live.some(v=>{
      if(v===main||v.closest?.('#ykPlayer')!==box)return false;
      const ad=v.closest?.('.advertise-layer');
      return (ad||v.paused===false&&!v.ended)&&visible(ad||v);
    });
    return ads?null:main;
  };
  const binding=(video,records,requests,document,live)=>{
    if(owner(records,document,live)!==video||!Array.isArray(requests))return null;
    const record=records.find(r=>r.id===page(document).id);
    const declared=record.streams.filter(s=>s.width===video.videoWidth&&s.height===video.videoHeight&&Math.abs(s.duration-video.duration)<=2);
    const matched=requests.filter(r=>r.kind==='hls'&&declared.some(s=>sameManifest(s.url,r.url)||sameManifest(s.url,r.original_url)));
    const manifests=[...new Set(matched.map(r=>r.url))];
    if(manifests.length!==1)return null;
    return {id:record.id,page:document,revision:record.revision,expected_duration:record.duration,duration:video.duration,
      width:video.videoWidth,height:video.videoHeight,manifests,declarations:declared,declared_drm:'default'};
  };
  return {address,page,json,sameManifest,normalize,owner,binding};
})();
