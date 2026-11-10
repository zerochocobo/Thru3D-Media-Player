/* Read the current official player declaration. The parent page/frame ownership
 * is checked separately by the extension sender and native tab/session. */
const Thru3DDailymotion=(()=>{
  'use strict';
  const {own,revision,visible}=Thru3DTikTok;
  const address=(value,document=false)=>{try{const u=new URL(value);return typeof value==='string'&&value.length<=(document?8192:16384)&&u.protocol==='https:'&&!u.username&&!u.password&&(document||!u.hash)?u:null;}catch(_){return null;}};
  const transport=value=>{try{const u=new URL(value);if(typeof value!=='string'||value.length>16384||!['http:','https:'].includes(u.protocol)||u.username||u.password)return null;u.hash='';return u.href;}catch(_){return null;}};
  const documentPage=value=>{const u=address(value,true);return !!u&&!u.port&&['www.dailymotion.com','dailymotion.com'].includes(u.hostname);};
  const page=value=>{
    const u=address(value);if(!u||!['www.dailymotion.com','dailymotion.com'].includes(u.hostname)||u.port)return null;
    return /^\/video\/([A-Za-z0-9]{1,20})\/?$/.exec(u.pathname)?.[1]||null;
  };
  const frame=value=>{const u=address(value,true);return !!u&&!u.port&&u.hostname==='geo.dailymotion.com'&&/^\/player(?:\/[A-Za-z0-9]+)?\.html$/.test(u.pathname);};
  const marked=(o,fields)=>fields.some(k=>{const v=own(o,k);return v!==undefined&&v!==null&&v!==false&&v!==0&&v!==''&&v!=='0'&&v!=='false';});
  const declaration=(video,document=globalThis.document)=>{
    try{
      if(!frame(document.location.href)||video.id!=='video'||!video.closest?.('.video_player')||video.closest?.('.ad-container')||document.querySelectorAll('video#video').length!==1)return null;
      const raw=document.defaultView?.wrappedJSObject||document.defaultView;
      const config=own(raw,'__PLAYER_CONFIG__'),data=own(config,'metadata'),info=own(data,'info'),stream=own(data,'stream');
      const id=own(data,'id'),publicPage=own(info,'url'),duration=own(info,'duration'),root=own(stream,'url');
      if(typeof id!=='string'||!/^[A-Za-z0-9]{1,20}$/.test(id)||page(publicPage)!==id||!Number.isInteger(duration)||duration<=0||duration>86400||!address(root))return null;
      const protectedFields=['drm','hasDrm','isDrm','isEncrypted','encrypted','isProtected','isLive','is_live'];
      if(marked(data,protectedFields)||marked(info,protectedFields)||marked(stream,protectedFields)||
        ['stream_type','content_type'].some(k=>/live|drm|encrypted/i.test(String(own(stream,k)||''))))return null;
      return {id,page:'https://www.dailymotion.com/video/'+id,expected_duration:duration,root};
    }catch(_){return null;}
  };
  const read=(video,document=globalThis.document)=>{
    if(!video.isConnected||video.mediaKeys||video.seeking||video.ended||video.readyState<2||!visible(video)||!Number.isFinite(video.duration)||video.duration<=0||video.duration>86400||
      !Number.isInteger(video.videoWidth)||!Number.isInteger(video.videoHeight)||video.videoWidth<=0||video.videoHeight<=0||video.videoWidth>8192||video.videoHeight>8192)return null;
    if(!video.currentSrc?.startsWith('blob:https://geo.dailymotion.com/'))return null;
    const data=declaration(video,document);return data&&Math.abs(data.expected_duration-video.duration)<=1?data:null;
  };
  const manifests=(root,requests,bodies)=>{
    if(!Array.isArray(bodies)||bodies.length>6)return null;
    const entries=new Map();let size=0;
    for(const entry of bodies){
      const age=Date.now()-entry.at;
      if(typeof entry.body!=='string'||!entry.body.startsWith('#EXTM3U')||entry.body.length>48*1024||!Number.isFinite(age)||age<0||age>1800000||
        transport(entry.request_url||entry.url)!==entry.url||
        !requests.some(r=>r.kind==='hls'&&r.url===entry.url&&r.request_id===entry.request_id&&(r.request_url||r.url)===(entry.request_url||entry.url)))continue;
      if(entries.has(entry.url))return null;entries.set(entry.url,entry);
    }
    const queue=[root],result=[],seen=new Set();
    while(queue.length){
      const uri=queue.shift();if(seen.has(uri))continue;seen.add(uri);
      const entry=entries.get(uri);if(!entry)continue;
      size+=entry.body.length;if(size>64*1024||result.length>=6)return null;
      result.push({url:entry.url,body:entry.body,request_id:entry.request_id,request_url:entry.request_url||entry.url});
      const lines=entry.body.split(/\r?\n/).map(v=>v.trim());if(lines.length>4096)return null;
      for(const line of lines){
        const ref=line&&!line.startsWith('#')?line:line.startsWith('#EXT-X-MEDIA:')?/URI="([^"]+)"/.exec(line)?.[1]:null;
        if(ref){try{const url=transport(new URL(ref,uri).href);if(url&&entries.has(url))queue.push(url);}catch(_){return null;}}
      }
    }
    return result[0]?.url===root?result:null;
  };
  const binding=(video,requests,document,live,bodies=[])=>{
    const data=read(video,document);if(!data||!Array.isArray(requests)||!Array.isArray(live))return null;
    if(live.some(v=>v!==video&&v.isConnected&&v.readyState>=2&&v.videoWidth>0&&visible(v)))return null;
    if(!requests.some(r=>{const age=Date.now()-r.at;return r.kind==='hls'&&r.url===data.root&&Number.isFinite(age)&&age>=0&&age<=1800000;}))return null;
    const graph=manifests(data.root,requests,bodies);if(!graph)return null;
    return {...data,manifests:graph,frame:document.location.href,width:video.videoWidth,height:video.videoHeight,duration:video.duration,
      revision:revision(data.id+'\n'+data.root+'\n'+video.videoWidth+'x'+video.videoHeight+'\n'+data.expected_duration+'\n'+JSON.stringify(graph))};
  };
  return {address,transport,documentPage,page,frame,declaration,read,manifests,binding};
})();
