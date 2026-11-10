/* Current Instagram detail player/inline MPD. The complete file URL comes from
 * the rendered declaration; transport query parameters are never stripped to
 * invent one, and ranged-request credentials are not copied to that new GET. */
const Thru3DInstagram=(()=>{
  'use strict';
  const {own,list,address,revision,presented}=Thru3DTikTok;
  const documentPage=value=>{const u=address(value);return !!u&&['www.instagram.com','instagram.com'].includes(u.hostname);};
  const page=value=>{const u=address(value);if(!u||!documentPage(value))return null;return /^\/(?:reels?|p|tv)\/([A-Za-z0-9_-]{5,64})\/?$/.exec(u.pathname)?.[1]||null;};
  const feed=value=>{const u=address(value);return !!u&&documentPage(value)&&/^\/reels\/?$/.test(u.pathname);};
  const range=value=>{const m=/^(0|[1-9][0-9]{0,12})-(0|[1-9][0-9]{0,12})$/.exec(value||'');return m&&+m[1]<=+m[2]?[+m[1],+m[2]]:null;};
  const children=(node,name)=>[...node.children].filter(n=>n.localName===name);
  const manifestDocument=doc=>{
    const root=doc.documentElement;
    if(root?.localName!=='MPD'||root.getAttribute('type')!=='static'||doc.getElementsByTagNameNS('*','parsererror').length||
      ['ContentProtection','SegmentTemplate','SegmentList'].some(n=>doc.getElementsByTagNameNS('*',n).length)||children(root,'Period').length!==1)return null;
    if(![null,'','PT0S','PT0.0S'].includes(children(root,'Period')[0].getAttribute('start')))return null;
    const match=/^PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+(?:\.\d+)?)S)?$/.exec(root.getAttribute('mediaPresentationDuration')||'');
    const duration=match&&+(match[1]||0)*3600+ +(match?.[2]||0)*60+ +(match?.[3]||0);
    if(!Number.isFinite(duration)||duration<=0||duration>86400)return null;
    const reps=[...doc.getElementsByTagNameNS('*','Representation')];if(!reps.length||reps.length>32)return null;
    const tracks=[];
    for(const node of reps){
      const base=children(node,'BaseURL'),segment=children(node,'SegmentBase'),id=node.getAttribute('id')||'';
      if(base.length!==1||segment.length!==1||!id||id.length>200||!address(base[0].textContent)||new URL(base[0].textContent).searchParams.has('bytestart')||new URL(base[0].textContent).searchParams.has('byteend'))return null;
      const init=children(segment[0],'Initialization'),index=range(segment[0].getAttribute('indexRange'));
      const initial=init.length===1&&range(init[0].getAttribute('range'));
      if(!index||!initial||initial[0]!==0||Math.max(index[1],initial[1])>2*1024*1024||init[0].getAttribute('sourceURL'))return null;
      const mime=node.getAttribute('mimeType')||node.parentElement?.getAttribute('mimeType'),codec=node.getAttribute('codecs')||node.parentElement?.getAttribute('codecs')||'';
      const width=+(node.getAttribute('width')||0),height=+(node.getAttribute('height')||0),bandwidth=+(node.getAttribute('bandwidth')||0);
      if(!['video/mp4','audio/mp4'].includes(mime)||!Number.isSafeInteger(bandwidth)||bandwidth<=0||bandwidth>1e9||
        mime==='video/mp4'&&(!Number.isInteger(width)||!Number.isInteger(height)||width<=0||height<=0||width>8192||height>8192))return null;
      tracks.push({id,url:base[0].textContent,kind:mime==='video/mp4'?'video':'audio',width,height,bandwidth,codec,init_range:initial,index_range:index});
    }
    return {duration,tracks};
  };
  const manifest=xml=>{
    if(typeof xml!=='string'||xml.length>96*1024||/<!DOCTYPE|<!ENTITY/i.test(xml))return null;
    try{return manifestDocument(new DOMParser().parseFromString(xml,'application/xml'));}catch(_){return null;}
  };
  const payloadRequest=(track,request)=>{
    const a=address(request.url),b=address(track.url),age=Date.now()-request.at;
    if(!a||!b||request.kind!=='file'||!Number.isFinite(age)||age<0||age>1800000||a.origin!==b.origin||a.pathname!==b.pathname)return false;
    const tokens=a.search.slice(1).split('&'),normal=tokens.filter(v=>!['bytestart','byteend'].includes(v.split('=')[0]));
    if(normal.join('&')!==b.search.slice(1)||a.searchParams.getAll('bytestart').length!==1||a.searchParams.getAll('byteend').length!==1)return false;
    const start=a.searchParams.get('bytestart'),end=a.searchParams.get('byteend');
    if(!/^(0|[1-9][0-9]{0,12})$/.test(start)||!/^(0|[1-9][0-9]{0,12})$/.test(end)||+start>+end)return false;
    return +end>Math.max(track.init_range[1],track.index_range[1]);
  };
  const choose=(graph,requests,width,height,hasAudio)=>{
    const candidates=graph.tracks.map(t=>({...t,requests:requests.filter(r=>payloadRequest(t,r)).map(r=>r.url)})).filter(t=>t.requests.length);
    const videos=candidates.filter(t=>t.kind==='video'&&t.width===width&&t.height===height).sort((a,b)=>b.bandwidth-a.bandwidth||a.url.localeCompare(b.url));
    if(!videos.length)return null;
    // Representations share this verified current post/MPD. Preserve decoded
    // resolution and use an actually requested encoding, never a preload index.
    const audios=candidates.filter(t=>t.kind==='audio');
    if(hasAudio===false&&(graph.tracks.some(t=>t.kind==='audio')||audios.length)||hasAudio===true&&audios.length!==1)return null;
    if(typeof hasAudio!=='boolean')return null;
    return {video:videos[0],audio:hasAudio?audios[0]:null};
  };
  let audioCache=null;
  const audioEvidence=(document,code)=>{
    if(audioCache?.code===code&&audioCache.script.isConnected&&revision(audioCache.script.textContent||'')===audioCache.hash)return audioCache.hasAudio;
    const found=[];let budget=0;
    const scan=(o,depth)=>{
      if(!o||typeof o!=='object'||depth>18||++budget>12000)return;
      if(Array.isArray(o)){list(o,64).forEach(v=>scan(v,depth+1));return;}
      if(own(o,'code')===code||own(o,'shortcode')===code){const value=own(o,'has_audio')??own(o,'hasAudio');if(typeof value==='boolean')found.push(value);}
      for(const k of Object.keys(o).slice(0,160))scan(own(o,k),depth+1);
    };
    for(const script of [...document.querySelectorAll('script[type="application/json"]')].slice(0,160)){
      const text=script.textContent||'';if(text.length>10*1024*1024||!text.includes(code))continue;
      try{scan(JSON.parse(text),0);}catch(_){}
      if(found.length){if(new Set(found).size!==1)return null;audioCache={code,script,hash:revision(text),hasAudio:found[0]};return found[0];}
    }
    return null;
  };
  const models=root=>{
    const found=[],seen=new WeakSet();let budget=0;
    const scan=(o,depth)=>{
      if(!o||typeof o!=='object'||depth>7||++budget>256||seen.has(o))return;seen.add(o);
      if(Array.isArray(o)){list(o,12).forEach(v=>scan(v,depth+1));return;}
      if(own(o,'coreVideoPlayerMetaData')&&typeof own(o,'manifest')==='string')found.push(o);
      scan(own(o,'props'),depth+1);scan(own(o,'children'),depth+1);
    };scan(root,0);return found;
  };
  let postCache=null;
  const currentPost=(document,mediaId,xml)=>{
    if(postCache?.mediaId===mediaId&&postCache.xml===xml&&postCache.script.isConnected&&postCache.script.textContent===postCache.text)return postCache.post;
    let budget=0;const found=[];
    const scan=(o,depth)=>{
      if(!o||typeof o!=='object'||depth>22||++budget>24000)return;
      if(own(o,'pk')===mediaId){
        const code=own(o,'code'),audio=own(o,'has_audio');
        if(typeof code==='string'&&/^[A-Za-z0-9_-]{5,64}$/.test(code)&&typeof audio==='boolean'&&own(o,'video_dash_manifest')===xml)found.push({id:code,has_audio:audio});
      }
      for(const k of Object.keys(o).slice(0,160))scan(own(o,k),depth+1);
    };
    for(const script of [...document.querySelectorAll('script[type="application/json"]')].slice(0,160)){
      const text=script.textContent||'';if(text.length>10*1024*1024||!text.includes(mediaId))continue;
      try{scan(JSON.parse(text),0);}catch(_){}
      if(found.length){if(new Set(found.map(p=>JSON.stringify(p))).size!==1)return null;postCache={mediaId,xml,script,text,post:found[0]};return found[0];}
    }
    return null;
  };
  const parsed=new WeakMap();
  const declaration=(video,url,document=globalThis.document)=>{
    try{
      let id=page(url);if(!id&&!feed(url))return null;
      const publicIds=[...document.querySelectorAll('meta[property="al:ios:url"],meta[property="al:android:url"]')].flatMap(m=>{try{const u=new URL(m.content),v=u.searchParams.get('id');return u.protocol==='instagram:'&&/^\d{5,30}$/.test(v)?[v]:[];}catch(_){return [];}});
      let data=[];
      for(let n=video,d=0;n&&d<6;n=n.parentElement,d++){
        const raw=n.wrappedJSObject||n;data=Object.getOwnPropertyNames(raw).filter(k=>/^__reactProps\$/.test(k)).slice(0,2).flatMap(k=>models(own(raw,k)));if(data.length)break;
      }
      if(new Set(data).size!==1)return null;
      const model=data[0],meta=own(model,'coreVideoPlayerMetaData'),mediaId=own(meta,'videoFBID'),xml=own(model,'manifest');
      if(typeof mediaId!=='string'||!/^[0-9]{5,30}$/.test(mediaId)||own(meta,'isLiveStreaming')===true)return null;
      const post=(!id||!publicIds.includes(mediaId))?currentPost(document,mediaId,xml):null;
      if(post&&id&&post.id!==id)return null;
      if(!post&&!publicIds.includes(mediaId))return null;
      const inFeed=!id;if(inFeed)id=post?.id;if(!id)return null;
      const hasAudio=post?post.has_audio:audioEvidence(document,id);if(typeof hasAudio!=='boolean')return null;
      let entry=parsed.get(video);
      if(!entry||entry.xml!==xml){entry={xml,graph:manifest(xml)};parsed.set(video,entry);}
      if(!entry.graph)return null;
      return {id,media_id:mediaId,xml,has_audio:hasAudio,graph:entry.graph,...(inFeed?{page:'https://www.instagram.com/reel/'+id+'/',document:url,binding:'rendered_card',active_id:id}:{})};
    }catch(_){return null;}
  };
  const read=(video,url,document=globalThis.document)=>{
    if(!video.isConnected||video.mediaKeys||video.seeking||video.readyState<2||!presented(video)||!Number.isFinite(video.duration)||video.duration<=0||
      !video.currentSrc?.startsWith('blob:https://www.instagram.com/')&&!video.currentSrc?.startsWith('blob:https://instagram.com/'))return null;
    const data=declaration(video,url,document);
    return data&&Math.abs(data.graph.duration-video.duration)<=Math.max(.25,data.graph.duration*.0001)?data:null;
  };
  const binding=(video,requests,url,live,document=globalThis.document)=>{
    const data=read(video,url,document);if(!data||!Array.isArray(requests)||!Array.isArray(live)||live.some(v=>v!==video&&v.isConnected&&v.readyState>=2&&v.videoWidth>0&&presented(v)))return null;
    const selected=choose(data.graph,requests,video.videoWidth,video.videoHeight,data.has_audio);if(!selected)return null;
    const simplify=t=>t&&({...t,requests:[...new Set(t.requests)].slice(-8)});
    return {id:data.id,page:data.page||url,...(data.binding?{document:data.document,binding:data.binding,active_id:data.active_id}:{}),media_id:data.media_id,manifest:data.xml,has_audio:data.has_audio,width:video.videoWidth,height:video.videoHeight,duration:video.duration,
      expected_duration:data.graph.duration,start_seconds:video.ended?0:video.currentTime,video:simplify(selected.video),audio:simplify(selected.audio),
      revision:revision(data.id+'\n'+data.media_id+'\n'+data.xml+'\n'+selected.video.url+'\n'+(selected.audio?.url||''))};
  };
  const identity=data=>({id:data.id,page:data.page,media_id:data.media_id,manifest:data.manifest,revision:data.revision,width:data.width,height:data.height,
    duration:data.duration,has_audio:data.has_audio,video_url:data.video.url,audio_url:data.audio?.url||''});
  const matchesIdentity=(data,expected)=>{
    if(!data||!expected)return false;
    const actual=identity(data);
    return ['id','page','media_id','manifest','revision','width','height','has_audio','video_url','audio_url'].every(k=>actual[k]===expected[k])&&Math.abs(actual.duration-expected.duration)<=.001;
  };
  return {documentPage,page,feed,range,manifestDocument,manifest,payloadRequest,choose,audioEvidence,currentPost,declaration,read,binding,identity,matchesIdentity};
})();
