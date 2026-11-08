/* The rendered TED player owns its current talk/root. Read-only React descriptor
 * helpers reuse the verified TikTok/Douyin path; no SSR-wide/preload guessing. */
const Thru3DTed=(()=>{
  'use strict';
  const {own,targets,address,revision,visible}=Thru3DTikTok;
  const documentPage=value=>{const u=address(value);return !!u&&['www.ted.com','ted.com'].includes(u.hostname);};
  const page=value=>{
    const u=address(value);if(!u||!documentPage(value))return null;
    const m=/^\/talks\/([a-z0-9_-]{1,180})\/?$/.exec(u.pathname);return m?m[1]:null;
  };
  const marked=(o,keys)=>keys.some(k=>{const v=own(o,k);return v!==undefined&&v!==null&&v!==false&&v!==0&&v!==''&&v!=='false'&&v!=='0';});
  const declaration=(video,document)=>{
    try{
      const slug=page(document),container=video.closest?.('#video-player-container');
      if(!slug||video.id!=='video'||!container||container.querySelectorAll('video#video').length!==1||video.closest?.('#ad-container'))return null;
      let models=[];
      for(let n=video,d=0;n&&d<6;n=n.parentElement,d++){
        const raw=n.wrappedJSObject||n;
        models=Object.getOwnPropertyNames(raw).filter(k=>/^__reactProps\$/.test(k)).slice(0,2).flatMap(k=>targets(own(raw,k),'video'));
        if(models.length)break;
      }
      const data=[];
      for(const model of new Set(models)){
        const player=own(model,'videoPlayerData'),id=own(model,'id'),playerId=own(player,'id'),duration=own(model,'duration'),root=own(model,'hlsUrl');
        const protection=['isAd','isLive','drm','hasDrm','isDrm','isEncrypted','encrypted','isProtected'];
        if(own(model,'slug')!==slug||!/^\d{1,20}$/.test(id)||!/^\d{1,20}$/.test(playerId)||marked(model,protection)||marked(player,protection))return null;
        // TED also declares an external alternative on talks playing native HLS.
        // Only this rendered hlsUrl and its actual request are used; no external
        // service/code/URL is followed or treated as a protection decision.
        if(!Number.isInteger(duration)||duration<=0||duration>86400||!address(root)||!new URL(root).pathname.endsWith('.m3u8'))return null;
        data.push({id:slug,talk_id:String(id),player_id:String(playerId),duration,root});
      }
      const unique=[...new Map(data.map(d=>[JSON.stringify(d),d])).values()];return unique.length===1?unique[0]:null;
    }catch(_){return null;}
  };
  const read=(video,document)=>{
    if(!video.isConnected||video.mediaKeys||video.seeking||video.ended||video.readyState<2||!visible(video)||!Number.isFinite(video.duration)||video.duration<=0||video.duration>86400||
      !Number.isInteger(video.videoWidth)||!Number.isInteger(video.videoHeight)||video.videoWidth<=0||video.videoHeight<=0||video.videoWidth>8192||video.videoHeight>8192)return null;
    const source=video.currentSrc||'';
    if(!source.startsWith('blob:https://www.ted.com/')&&!source.startsWith('blob:https://ted.com/'))return null;
    const data=declaration(video,document);return data&&Math.floor(video.duration)===data.duration?data:null;
  };
  const binding=(video,requests,document,live)=>{
    const data=read(video,document);if(!data||!Array.isArray(requests)||!Array.isArray(live))return null;
    if(live.some(v=>v!==video&&v.isConnected&&v.readyState>=2&&v.videoWidth>0&&visible(v)))return null;
    if(!requests.some(r=>{const age=Date.now()-r.at;return r.kind==='hls'&&r.url===data.root&&Number.isFinite(age)&&age>=0&&age<=1800000;}))return null;
    return {...data,page:document,width:video.videoWidth,height:video.videoHeight,duration:video.duration,expected_duration:data.duration,
      revision:revision(data.id+'\n'+data.talk_id+'\n'+data.player_id+'\n'+data.root+'\n'+video.videoWidth+'x'+video.videoHeight+'\n'+data.duration)};
  };
  return {documentPage,page,declaration,read,binding};
})();
