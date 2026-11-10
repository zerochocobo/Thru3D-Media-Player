/* Current Red Bull TV player. Reuse the project's existing shadow-video discovery
 * and read only this custom element's rendered Preact data descriptors. */
const Thru3DRedBull=(()=>{
  'use strict';
  const {own,list,revision,visible}=Thru3DTikTok;
  const address=value=>{try{const u=new URL(value);return typeof value==='string'&&value.length<=16384&&u.protocol==='https:'&&!u.username&&!u.password&&!u.hash?u:null;}catch(_){return null;}};
  const page=value=>{
    const u=address(value);if(!u||value.length>8192||!['www.redbull.tv','redbull.tv'].includes(u.hostname)||u.port)return null;
    const match=/^\/([a-z]{2}(?:-[A-Z]{2}|_[A-Z]{2,3})?)\/page\/(?:page:)?(rrn:content:(?:films|videos|episodes):[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})(?:\/[a-z0-9-]+)?\/?$/.exec(u.pathname);
    return match?{id:match[2],page:value}:null;
  };
  const documentPage=value=>{try{const u=new URL(value);return typeof value==='string'&&value.length<=8192&&u.protocol==='https:'&&!u.username&&!u.password&&!u.port&&['www.redbull.tv','redbull.tv'].includes(u.hostname);}catch(_){return false;}};
  const owner=(video,document)=>{
    const current=page(document.location.href);if(!current)return null;
    const root=video.getRootNode?.(),host=root?.host;
    if(!host||host.localName!=='rbup-video-tv-streaming'||host.shadowRoot!==root||host.getAttribute('asset-id')!==current.id)return null;
    const hosts=[...document.querySelectorAll('rbup-video-tv-streaming')].filter(h=>h.isConnected);
    const mains=[...root.querySelectorAll('.rbup-video-core-container__player > video')];
    return hosts.length===1&&hosts[0]===host&&mains.length===1&&mains[0]===video?{host,root,current}:null;
  };
  const states=host=>{
    const result=[],rendered=new WeakSet(),data=new WeakSet();let nodes=0,values=0;
    const walk=(value,depth)=>{
      if(!value||typeof value!=='object'||data.has(value)||depth>7||++values>320)return;data.add(value);
      if(Array.isArray(value)){for(const item of list(value,16))walk(item,depth+1);return;}
      if(own(value,'mediaMetaData')&&own(value,'playerConfiguration'))result.push(value);
      // Local providers/hooks only. Do not follow coordinator services, parent
      // links, global context, storage or anything callable.
      for(const key of ['value','current','playerState','state'])walk(own(value,key),depth+1);
    };
    const visit=(node,depth)=>{
      if(!node||typeof node!=='object'||rendered.has(node)||depth>20||++nodes>320)return;rendered.add(node);
      walk(own(node,'props'),0);
      const component=own(node,'__c');walk(own(component,'state'),0);
      for(const hook of list(own(own(component,'__H'),'__'),32))walk(own(hook,'__'),0);
      const children=own(node,'__k');if(Array.isArray(children))for(const child of list(children,32))visit(child,depth+1);
      else if(children&&typeof children==='object')visit(children,depth+1);
    };
    const raw=host.wrappedJSObject||host;visit(own(raw,'_root'),0);return result;
  };
  const declaration=(video,document=globalThis.document)=>{
    try{
      const target=owner(video,document);if(!target)return null;
      const matches=[];
      for(const state of states(target.host)){
        const media=own(state,'mediaMetaData'),config=own(state,'playerConfiguration'),src=own(media,'mediaSrc');
        const root=own(src,'videoUrl'),duration=own(media,'duration'),drm=own(media,'drm');
        if(own(config,'assetId')!==target.current.id||own(media,'videoId')!==target.current.id||!address(root)||
          own(state,'videoLoaded')!==true||own(state,'isShowingAd')!==false||own(media,'isLive')!==false||own(media,'isLinearStream')===true||
          drm!==undefined&&drm!==null&&drm!==false||!Number.isInteger(duration)||duration<=0||duration>86400)continue;
        const actual=own(state,'durationInSec'),position=own(state,'playbackPosInSec');
        if(!Number.isFinite(actual)||Math.abs(actual-video.duration)>.25||Math.abs(actual-duration)>1||
          !Number.isFinite(position)||Math.abs(position-video.currentTime)>2)continue;
        matches.push({...target.current,root,expected_duration:duration});
      }
      const unique=[...new Map(matches.map(m=>[JSON.stringify(m),m])).values()];return unique.length===1?unique[0]:null;
    }catch(_){return null;}
  };
  const read=(video,document=globalThis.document)=>{
    if(!video.isConnected||video.mediaKeys||video.ended||video.seeking||video.readyState<2||!visible(video)||
      !Number.isInteger(video.videoWidth)||!Number.isInteger(video.videoHeight)||video.videoWidth<=0||video.videoHeight<=0||video.videoWidth>8192||video.videoHeight>8192||
      !Number.isFinite(video.duration)||video.duration<=0||video.duration>86400||!video.currentSrc?.startsWith('blob:'+new URL(document.location.href).origin+'/'))return null;
    return declaration(video,document);
  };
  const binding=(video,requests,document,live)=>{
    const data=read(video,document);if(!data||!Array.isArray(requests)||!Array.isArray(live))return null;
    const root=video.getRootNode();
    if(live.some(v=>v!==video&&v.getRootNode?.()===root&&v.isConnected&&v.readyState>=2&&v.videoWidth>0&&visible(v)))return null;
    if(!requests.some(r=>{const age=Date.now()-r.at;return r.kind==='hls'&&r.url===data.root&&Number.isFinite(age)&&age>=0&&age<=1800000;}))return null;
    return {...data,width:video.videoWidth,height:video.videoHeight,duration:video.duration,
      revision:revision(data.id+'\n'+data.root+'\n'+video.videoWidth+'x'+video.videoHeight+'\n'+data.expected_duration)};
  };
  return {address,page,documentPage,owner,states,declaration,read,binding};
})();
