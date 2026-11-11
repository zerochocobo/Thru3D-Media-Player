/* Current Odysee claim: rendered hls.js owner or declared/observed complete file.
 * URL formats are interpreted, never generated, rewritten or replayed. */
const Thru3DOdysee=(()=>{
  'use strict';
  const {own,revision,visible}=Thru3DTikTok;
  const {address,seconds}=Thru3DStreamable;
  const slug=value=>{
    try{
      const decoded=decodeURIComponent(value);
      return /^[\p{L}\p{M}\p{N}_.-]+$/u.test(decoded)&&!decoded.includes('..')?decoded:null;
    }catch(_){return null;}
  };
  const documentPage=value=>{const u=address(value);return !!u&&value.length<=8192&&!u.port&&['odysee.com','www.odysee.com'].includes(u.hostname);};
  const page=value=>{
    const u=address(value);if(!u||!documentPage(value)||u.pathname.includes('..'))return null;
    const m=/^\/(?:@[A-Za-z0-9_.-]+(?::[a-fA-F0-9]{1,40})?\/)?([^/:]+):([a-fA-F0-9]{1,40})\/?$/.exec(u.pathname);
    const name=m&&slug(m[1]);
    return name?{id:u.pathname.replace(/^\/|\/$/g,''),slug:name,prefix:m[2].toLowerCase(),page:value}:null;
  };
  const file=value=>{
    const u=address(value);if(!u)return null;
    const legacy=/^\/api\/v[34]\/streams\/free\/([^/]+)\/([a-fA-F0-9]{40})\/([a-fA-F0-9]{6}\.mp4)$/.exec(u.pathname);
    if(legacy){
      const name=slug(legacy[1]);
      return name?{slug:name,claim:legacy[2].toLowerCase(),file:legacy[3].toLowerCase(),free:true}:null;
    }
    const current=/^\/v6\/streams\/([a-fA-F0-9]{40})\/([a-fA-F0-9]{6}\.mp4)$/.exec(u.pathname);
    return current?{claim:current[1].toLowerCase(),file:current[2].toLowerCase(),free:false}:null;
  };
  // Match the rendered file or attached hls.js source to committed Video props
  // and the current full claim,
  // rather than using an SSR/preload declaration from a different page.
  const renderedDeclaration=(video,document,diagnostics)=>{
    try{
      const current=page(document.location.href),native=video.wrappedJSObject||video;
      if(!current)return null;
      const blob=video.currentSrc.startsWith('blob:'),actual=blob?null:file(video.currentSrc),hls=blob?own(native,'_hls'):null;
      const root=blob?own(hls,'_url'):video.currentSrc;
      if(blob?(!video.currentSrc.startsWith('blob:'+new URL(document.location.href).origin+'/')||
        own(hls,'_media')!==native&&own(hls,'_media')!==video||!address(root)):!actual)return null;
      const props=node=>Object.getOwnPropertyNames(node).filter(k=>k.startsWith('__reactProps$')).slice(0,2).map(k=>own(node,k));
      // DOM React props describe the committed tree. Fiber memoizedProps can
      // belong to an old alternate after the same video element changes source.
      if(!props(native).some(p=>own(p,'src')===root))return null;
      const models=[];
      for(let node=video,depth=0;node&&depth<12;node=node.parentElement,depth++){
        const seen=new Set();let budget=0;
        const walk=(p,level)=>{
          if(!p||typeof p!=='object'||seen.has(p)||level>8||++budget>256)return;seen.add(p);
          const claim=own(p,'claimId'),uri=own(p,'uri'),values=own(p,'claimValues'),info=own(values,'video'),expected=own(info,'duration');
          if(typeof claim==='string'&&/^[a-fA-F0-9]{40}$/.test(claim)&&typeof uri==='string'&&uri.length<=8192&&
            typeof expected==='number'&&Number.isFinite(expected)&&expected>0&&expected<=86400){
            const id=claim.toLowerCase(),identity=/^lbry:\/\/(?:@[A-Za-z0-9_.-]+[#:]([a-fA-F0-9]{1,40})\/)?([^/#:]+)[#:]([a-fA-F0-9]{1,40})\/?$/.exec(uri);
            if(identity&&slug(identity[2])===current.slug&&id.startsWith(identity[3].toLowerCase())&&id.startsWith(current.prefix)&&
              new URL(root).pathname.split('/').some(p=>p.toLowerCase()===id)&&(!actual||actual.claim===id&&(!actual.slug||actual.slug===current.slug))){
              if(own(p,'isLivestreamClaim')===true||own(p,'isProtectedContent')===true){if(diagnostics)diagnostics.denied=true;return;}
              if(own(p,'isLivestreamClaim')===false&&own(p,'isProtectedContent')===false)models.push({...current,
                  binding:blob?'rendered_hls':'rendered_file',source:video.currentSrc,...(blob?{root}:{file_id:actual.file}),declared_source:root,
                  claim_id:id,claim_uri:uri,expected_duration:expected,whole_seconds:Number.isInteger(expected)});
            }
          }
          if(Array.isArray(p)){for(let i=0;i<Math.min(16,p.length);i++)walk(own(p,String(i)),level+1);}
          else{walk(own(p,'props'),level+1);walk(own(p,'children'),level+1);}
        };
        for(const p of props(node.wrappedJSObject||node))walk(p,0);
        if(models.length||diagnostics?.denied)break;
      }
      const unique=[...new Map(models.map(v=>[JSON.stringify(v),v])).values()];return unique.length===1?unique[0]:null;
    }catch(_){return null;}
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
    const diagnostics={},rendered=renderedDeclaration(video,document,diagnostics);
    if(diagnostics.denied)return null;
    const data=rendered||declaration(video,document);
    return data&&(data.whole_seconds?Math.floor(video.duration)===data.expected_duration:Math.abs(video.duration-data.expected_duration)<=.5)?data:null;
  };
  const binding=(video,requests,document,live)=>{
    const data=read(video,document);if(!data||!Array.isArray(requests)||!Array.isArray(live))return null;
    if(live.some(v=>v!==video&&v.isConnected&&v.readyState>=2&&v.videoWidth>0&&visible(v)))return null;
    if(!requests.some(r=>{const age=Date.now()-r.at;return r.kind===(data.binding==='rendered_hls'?'hls':'file')&&r.url===(data.root||data.source)&&Number.isFinite(age)&&age>=0&&age<=1800000;}))return null;
    return {...data,width:video.videoWidth,height:video.videoHeight,duration:video.duration,
      revision:revision((data.binding?data.binding+'\n'+data.claim_id+'\n':'')+data.id+'\n'+data.source+'\n'+data.declared_source+'\n'+data.expected_duration+'\n'+video.videoWidth+'x'+video.videoHeight)};
  };
  const hlsDeclaration=(video,document)=>video.currentSrc?.startsWith('blob:')?renderedDeclaration(video,document):null;
  return {address,documentPage,page,file,declaration,hlsDeclaration,renderedDeclaration,read,binding};
})();
