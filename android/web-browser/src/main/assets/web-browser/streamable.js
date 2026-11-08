/* Current Streamable detail clip, its rendered VideoObject and exact file request. */
const Thru3DStreamable=(()=>{
  'use strict';
  const {revision,visible}=Thru3DTikTok;
  const address=value=>{try{const u=new URL(value);return typeof value==='string'&&value.length<=16384&&u.protocol==='https:'&&!u.username&&!u.password&&!u.hash?u:null;}catch(_){return null;}};
  const documentPage=value=>{const u=address(value);return !!u&&!u.port&&['streamable.com','www.streamable.com'].includes(u.hostname);};
  const page=value=>{
    const u=address(value);if(!u||!documentPage(value))return null;
    const id=/^\/([A-Za-z0-9]{3,32})\/?$/.exec(u.pathname)?.[1];return id?{id,page:value}:null;
  };
  const seconds=value=>{
    if(typeof value!=='string'||value.length>64)return 0;
    const m=/^PT(?:(\d{1,2})H)?(?:(\d{1,2})M)?(?:(\d{1,5}(?:\.\d{1,6})?)S)?$/.exec(value);
    const n=m?Number(m[1]||0)*3600+Number(m[2]||0)*60+Number(m[3]||0):0;
    return Number.isFinite(n)&&n>0&&n<=86400?n:0;
  };
  const declaration=(video,document=globalThis.document)=>{
    try{
      const current=page(document.location.href),source=address(video.currentSrc);if(!current||!source)return null;
      if(source.pathname.split('/').pop()!==current.id+'.mp4')return null;
      const canonical=[...document.querySelectorAll('link[rel="canonical"],meta[property="og:url"]')].slice(0,4)
        .map(n=>page(n.href||n.content));
      if(!canonical.length||canonical.some(p=>p?.id!==current.id))return null;
      const found=[];let budget=256*1024;
      for(const script of [...document.querySelectorAll('script[type="application/ld+json"]')].slice(0,8)){
        const text=script.textContent;if(typeof text!=='string'||text.length>64*1024||text.length>budget)continue;budget-=text.length;
        let data;try{data=JSON.parse(text);}catch(_){continue;}
        for(const item of (Array.isArray(data)?data:[data]).slice(0,16)){
          if(item?.['@type']!=='VideoObject'||item.contentUrl!==source.href)continue;
          const duration=seconds(item.duration);if(!duration)continue;
          found.push({...current,source:source.href,expected_duration:duration});
        }
      }
      const unique=[...new Map(found.map(d=>[JSON.stringify(d),d])).values()];return unique.length===1?unique[0]:null;
    }catch(_){return null;}
  };
  const read=(video,document=globalThis.document)=>{
    if(!video.isConnected||video.mediaKeys||video.seeking||video.ended||video.readyState<2||!visible(video)||
      !Number.isInteger(video.videoWidth)||!Number.isInteger(video.videoHeight)||video.videoWidth<=0||video.videoHeight<=0||video.videoWidth>16384||video.videoHeight>16384||
      !Number.isFinite(video.duration)||video.duration<=0||video.duration>86400)return null;
    const data=declaration(video,document);return data&&Math.abs(data.expected_duration-video.duration)<=.5?data:null;
  };
  const binding=(video,requests,document,live)=>{
    const data=read(video,document);if(!data||!Array.isArray(requests)||!Array.isArray(live))return null;
    if(live.some(v=>v!==video&&v.isConnected&&v.readyState>=2&&v.videoWidth>0&&visible(v)))return null;
    if(!requests.some(r=>{const age=Date.now()-r.at;return r.kind==='file'&&r.url===data.source&&Number.isFinite(age)&&age>=0&&age<=1800000;}))return null;
    return {...data,width:video.videoWidth,height:video.videoHeight,duration:video.duration,
      revision:revision(data.id+'\n'+data.source+'\n'+data.expected_duration)};
  };
  return {address,documentPage,page,seconds,declaration,read,binding};
})();
