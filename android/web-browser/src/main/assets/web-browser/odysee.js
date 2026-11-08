/* Current Odysee detail claim: actual v3/v4 declaration and observed v6/file request.
 * URL formats are interpreted, never generated, rewritten or replayed. */
const Thru3DOdysee=(()=>{
  'use strict';
  const {revision,visible}=Thru3DTikTok;
  const {address,seconds}=Thru3DStreamable;
  const documentPage=value=>{const u=address(value);return !!u&&value.length<=8192&&!u.port&&['odysee.com','www.odysee.com'].includes(u.hostname);};
  const page=value=>{
    const u=address(value);if(!u||!documentPage(value)||u.pathname.includes('..'))return null;
    const m=/^\/(?:@[A-Za-z0-9_.-]+(?::[a-fA-F0-9]{1,40})?\/)?([A-Za-z0-9_.-]+):([a-fA-F0-9]{1,40})\/?$/.exec(u.pathname);
    return m?{id:u.pathname.replace(/^\/|\/$/g,''),slug:m[1],prefix:m[2].toLowerCase(),page:value}:null;
  };
  const file=value=>{
    const u=address(value);if(!u)return null;
    const legacy=/^\/api\/v[34]\/streams\/free\/([A-Za-z0-9_.-]+)\/([a-fA-F0-9]{40})\/([a-fA-F0-9]{6}\.mp4)$/.exec(u.pathname);
    if(legacy)return {slug:legacy[1],claim:legacy[2].toLowerCase(),file:legacy[3].toLowerCase(),free:true};
    const current=/^\/v6\/streams\/([a-fA-F0-9]{40})\/([a-fA-F0-9]{6}\.mp4)$/.exec(u.pathname);
    return current?{claim:current[1].toLowerCase(),file:current[2].toLowerCase(),free:false}:null;
  };
  const declaration=(video,document=globalThis.document)=>{
    try{
      const current=page(document.location.href),actual=file(video.currentSrc);if(!current||!actual)return null;
      if(!actual.claim.startsWith(current.prefix)||actual.slug&&actual.slug!==current.slug)return null;
      const canonical=[...document.querySelectorAll('link[rel="canonical"],meta[property="og:url"]')].slice(0,4).map(n=>page(n.href||n.content));
      if(!canonical.length||canonical.some(p=>p?.id!==current.id))return null;
      const found=[];let budget=256*1024;
      for(const script of [...document.querySelectorAll('script[type="application/ld+json"]')].slice(0,8)){
        const text=script.textContent;if(typeof text!=='string'||text.length>64*1024||text.length>budget)continue;budget-=text.length;
        let values;try{const data=JSON.parse(text);values=Array.isArray(data)?data:[data];}catch(_){continue;}
        for(const data of values.slice(0,16)){
          if(data?.['@type']!=='VideoObject'||page(data.url)?.id!==current.id)continue;
          const declared=file(data.contentUrl),duration=seconds(data.duration);
          if(!declared?.free||declared.slug!==current.slug||declared.claim!==actual.claim||declared.file!==actual.file||!duration)continue;
          found.push({...current,source:video.currentSrc,declared_source:data.contentUrl,claim_id:actual.claim,file_id:actual.file,
            expected_duration:duration,whole_seconds:!data.duration.includes('.')});
        }
      }
      const unique=[...new Map(found.map(d=>[JSON.stringify(d),d])).values()];return unique.length===1?unique[0]:null;
    }catch(_){return null;}
  };
  const read=(video,document=globalThis.document)=>{
    if(!video.isConnected||video.mediaKeys||video.seeking||video.ended||video.readyState<2||!visible(video)||
      !Number.isInteger(video.videoWidth)||!Number.isInteger(video.videoHeight)||video.videoWidth<=0||video.videoHeight<=0||video.videoWidth>16384||video.videoHeight>16384||
      !Number.isFinite(video.duration)||video.duration<=0||video.duration>86400)return null;
    const data=declaration(video,document);
    return data&&(data.whole_seconds?Math.floor(video.duration)===data.expected_duration:Math.abs(video.duration-data.expected_duration)<=.5)?data:null;
  };
  const binding=(video,requests,document,live)=>{
    const data=read(video,document);if(!data||!Array.isArray(requests)||!Array.isArray(live))return null;
    if(live.some(v=>v!==video&&v.isConnected&&v.readyState>=2&&v.videoWidth>0&&visible(v)))return null;
    if(!requests.some(r=>{const age=Date.now()-r.at;return r.kind==='file'&&r.url===data.source&&Number.isFinite(age)&&age>=0&&age<=1800000;}))return null;
    return {...data,width:video.videoWidth,height:video.videoHeight,duration:video.duration,
      revision:revision(data.id+'\n'+data.source+'\n'+data.declared_source+'\n'+data.expected_duration+'\n'+video.videoWidth+'x'+video.videoHeight)};
  };
  return {address,documentPage,page,file,declaration,read,binding};
})();
