/* Archive's current detail player and its observed download redirect chain. */
const Thru3DArchive=(()=>{
  'use strict';
  const {revision,visible}=Thru3DTikTok;
  const address=value=>{try{const u=new URL(value);return typeof value==='string'&&value.length<=16384&&u.protocol==='https:'&&!u.username&&!u.password&&!u.hash?u:null;}catch(_){return null;}};
  const documentPage=value=>{const u=address(value);return !!u&&!u.port&&['archive.org','www.archive.org'].includes(u.hostname);};
  const page=value=>{const u=address(value);if(!u||!documentPage(value))return null;
    const id=/^\/details\/([A-Za-z0-9_.-]{1,100})\/?$/.exec(u.pathname)?.[1];return id&&id!=='.'&&id!=='..'?{id,page:value}:null;};
  const declaration=(video,document=globalThis.document)=>{
    try{
      const current=page(document.location.href),source=address(video.currentSrc);if(!current||!source||!documentPage(video.currentSrc))return null;
      const parts=source.pathname.split('/');if(parts.length!==4||parts[1]!=='download'||parts[2]!==current.id||!parts[3]||!(/\.(?:mp4|webm)$/i.test(parts[3])))return null;
      const canonical=[...document.querySelectorAll('link[rel="canonical"],meta[property="og:url"]')].slice(0,4).map(n=>page(n.href||n.content));
      if(!canonical.length||canonical.some(p=>p?.id!==current.id))return null;
      if(![...document.querySelectorAll('a[href]')].slice(0,4096).some(a=>a.href===source.href))return null;
      return {...current,source:source.href};
    }catch(_){return null;}
  };
  const read=(video,document=globalThis.document)=>{
    if(!video.isConnected||video.mediaKeys||video.seeking||video.ended||video.readyState<2||!visible(video)||
      !Number.isInteger(video.videoWidth)||!Number.isInteger(video.videoHeight)||video.videoWidth<=0||video.videoHeight<=0||video.videoWidth>16384||video.videoHeight>16384||
      !Number.isFinite(video.duration)||video.duration<=0||video.duration>86400)return null;
    return declaration(video,document);
  };
  const binding=(video,requests,document,live)=>{
    const data=read(video,document);if(!data||!Array.isArray(requests)||!Array.isArray(live))return null;
    if(live.some(v=>v!==video&&v.isConnected&&v.readyState>=2&&v.videoWidth>0&&visible(v)))return null;
    const matching=requests.filter(r=>{const age=Date.now()-r.at;return r.kind==='file'&&address(r.url)&&(r.url===data.source||r.original_url===data.source)&&Number.isFinite(age)&&age>=0&&age<=1800000;})
      .sort((a,b)=>b.at-a.at);
    if(!matching.length)return null;
    const newest=matching.filter(r=>r.at===matching[0].at);if(new Set(newest.map(r=>r.url)).size!==1)return null;
    const file=matching[0].url;
    return {...data,file,width:video.videoWidth,height:video.videoHeight,duration:video.duration,
      revision:revision(data.id+'\n'+data.source+'\n'+file+'\n'+video.duration)};
  };
  return {address,documentPage,page,declaration,read,binding};
})();
