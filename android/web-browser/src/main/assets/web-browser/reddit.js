/* Current Reddit native-video/GIF owner and its actually requested MP4.
 * No API replay, URL construction, SDK calls or independent audio guesses. */
const Thru3DReddit=(()=>{
  'use strict';
  const {own,revision,presented}=Thru3DTikTok;
  const address=value=>{try{const u=new URL(value);return typeof value==='string'&&value.length<=16384&&u.protocol==='https:'&&!u.username&&!u.password&&!u.hash?u:null;}catch(_){return null;}};
  const documentPage=value=>{const u=address(value);return !!u&&!u.port&&['reddit.com','www.reddit.com'].includes(u.hostname);};
  const page=value=>{
    const u=address(value);if(!u||!documentPage(value))return null;
    const m=/^\/r\/[A-Za-z0-9_]{2,32}\/comments\/([a-z0-9]{3,10})(?:\/[A-Za-z0-9_-]{1,200})?\/?$/.exec(u.pathname);
    return m?{id:m[1],page:u.origin+u.pathname}:null;
  };
  const feed=value=>{const u=address(value);return !!u&&documentPage(value)&&/^\/(?:r\/[A-Za-z0-9_]{2,32}\/(?:hot|new|top|rising|best)?\/?)?$/.test(u.pathname);};
  const parent=node=>node.parentElement||node.getRootNode?.()?.host||null;
  const postId=value=>typeof value==='string'&&/^t3_[a-z0-9]{3,10}$/.test(value)?value.slice(3):null;
  const protectedData=o=>['hasDrm','has_drm','isDrm','is_drm','drm','drmType','drm_type','isEncrypted','is_encrypted','encrypted','encryption','contentProtection']
    .some(k=>{const v=own(o,k);return v!==undefined&&v!==null&&v!==false&&v!==0&&v!=='0'&&v!==''&&v!=='false';});
  const owners=video=>{
    let player=null,post=null;
    for(let n=video,depth=0;n&&depth<24;n=parent(n),depth++){
      if(n.localName==='shreddit-preview-video-lazy')return null;
      if(!player&&n.localName==='shreddit-player')player=n;
      if(n.localName==='shreddit-post'){post=n;break;}
    }
    return player&&post?{player,post}:null;
  };
  const declaration=(video,document=globalThis.document)=>{
    try{
      const current=page(document.location.href);if(!current&&!feed(document.location.href))return null;
      const owner=owners(video),source=address(video.currentSrc);if(!owner||!source)return null;
      const {player,post}=owner,id=postId(player.getAttribute('post-id'));
      if(!id||postId(post.getAttribute('id'))!==id||current&&current.id!==id)return null;
      const link=post.getAttribute('permalink');if(typeof link!=='string'||!link)return null;
      const canonical=page(new URL(link,document.location.href).href);if(canonical?.id!==id)return null;
      for(const n of [player,post])for(const key of ['is-promoted','is-ad','is-live']){
        const value=n.getAttribute(key);if(value!==null&&value!=='false'&&value!=='0')return null;
      }
      const text=player.getAttribute('packaged-media-json');
      if(text===null){
        // GIF posts use a direct declaration on the same rendered player,
        // rather than packaged permutations. Never downgrade malformed JSON.
        const gif=player.getAttribute('gif'),width=video.videoWidth,height=video.videoHeight,expected=video.duration;
        if(!['','true','1'].includes(gif)||player.getAttribute('post-type')!=='gif'||post.getAttribute('post-type')!=='gif'||
          player.getAttribute('src')!==video.currentSrc||!Number.isInteger(width)||!Number.isInteger(height)||
          width<1||height<1||width>16384||height>16384||!Number.isFinite(expected)||expected<=0||expected>86400)return null;
        return {id,page:canonical.page,document:document.location.href,binding:'rendered_gif',declared_gif:true,active_id:id,
          source:video.currentSrc,width,height,expected_duration:expected};
      }
      if(typeof text!=='string'||text.length>256*1024)return null;
      const data=JSON.parse(text),mp4=own(data,'playbackMp4s'),expected=own(mp4,'duration'),permutations=own(mp4,'permutations');
      if(protectedData(data)||protectedData(mp4)||!Number.isFinite(expected)||expected<=0||expected>86400||
        !Array.isArray(permutations)||permutations.length<1||permutations.length>32)return null;
      const matched=permutations.filter(p=>own(own(p,'source'),'url')===video.currentSrc);if(matched.length!==1)return null;
      const selected=matched[0],file=own(selected,'source'),dimensions=own(file,'dimensions'),width=own(dimensions,'width'),height=own(dimensions,'height');
      if(protectedData(selected)||protectedData(file)||!Number.isInteger(width)||!Number.isInteger(height)||width<1||height<1||width>16384||height>16384)return null;
      return {id,page:canonical.page,document:document.location.href,binding:'rendered_post',active_id:id,
        source:video.currentSrc,width,height,expected_duration:expected};
    }catch(_){return null;}
  };
  const visible=video=>{
    if(!presented(video))return false;
    if(typeof getComputedStyle==='function')for(let n=video,depth=0;n&&depth<24;n=parent(n),depth++){
      const s=getComputedStyle(n);if(s&&(s.display==='none'||s.visibility==='hidden'||s.opacity==='0'))return false;
    }
    return true;
  };
  const read=(video,document=globalThis.document)=>{
    if(!video.isConnected||video.mediaKeys||video.seeking||video.readyState<2||!visible(video)||
      !Number.isFinite(video.duration)||video.duration<=0||video.duration>86400)return null;
    const data=declaration(video,document);
    return data&&data.width===video.videoWidth&&data.height===video.videoHeight&&
      Math.abs(data.expected_duration-video.duration)<=Math.max(2,data.expected_duration*.01)?data:null;
  };
  const binding=(video,requests,document,live)=>{
    const data=read(video,document);if(!data||!Array.isArray(requests)||!Array.isArray(live))return null;
    // Different fully identified posts in a feed keep independent actions.
    // A duplicate presented renderer for the same current file stays ambiguous.
    if(live.some(v=>v!==video&&v.isConnected&&v.readyState>=2&&visible(v)&&
      v.currentSrc===data.source&&declaration(v,document)?.id===data.id))return null;
    if(!requests.some(r=>{const age=Date.now()-r.at;return r.kind==='file'&&r.url===data.source&&Number.isFinite(age)&&age>=0&&age<=1800000;}))return null;
    return {...data,duration:video.duration,start_seconds:video.ended?0:video.currentTime,
      protection_unverified:true,revision:revision(data.id+'\n'+data.binding+'\n'+data.source+'\n'+data.width+'x'+data.height+'\n'+data.expected_duration)};
  };
  // Same bounded per-video ownership model as Weibo, with body-mounted overlays
  // because Reddit owns the custom player's shadow tree and may replace it.
  const controls=(doc,selected,site='reddit')=>{
    const entries=new Map(),view=doc.defaultView||globalThis;
    const action=event=>event.isTrusted?[...entries.values()].find(item=>(event.composedPath?.()||[]).includes(item.host)):null;
    const reserve=event=>{if(action(event))event.stopImmediatePropagation();};
    const click=event=>{const item=action(event);if(!item)return;event.preventDefault();event.stopImmediatePropagation();if(!item.button.disabled)selected(item.target);};
    const events=['pointerdown','mousedown','touchstart','pointerup','mouseup','touchend'];
    for(const name of events)view.addEventListener(name,reserve,true);
    view.addEventListener('click',click,true);
    const sync=(targets,enabled)=>{
      const mount=doc.fullscreenElement||doc.body;
      const current=new Map((enabled&&mount?targets:[]).filter(t=>t.video.isConnected&&visible(t.video)).slice(0,32).map(t=>[t.video,t]));
      for(const [video,item] of entries)if(!current.has(video)||item.overlay.parentElement!==mount){item.dispose();entries.delete(video);}
      for(const [video,target] of current){
        let item=entries.get(video);
        if(!item){
          const overlay=doc.createElement('span');overlay.dataset.thru3dPlayOverlay=site;
          overlay.style.cssText='position:fixed;pointer-events:none;z-index:2147482990;';mount.append(overlay);
          const control=Thru3DPlayButton.create(doc,overlay,site,()=>selected(item.target));
          item={...control,overlay,target,dispose(){control.dispose();overlay.remove();}};
          item.host.dataset['thru3d'+site[0].toUpperCase()+site.slice(1)]='beta';entries.set(video,item);
        }
        item.target=target;item.host.dataset['thru3d'+site[0].toUpperCase()+site.slice(1)+'Page']=target.page;
        const r=video.getBoundingClientRect();Object.assign(item.overlay.style,{left:r.left+'px',top:r.top+'px',width:r.width+'px',height:r.height+'px'});
        item.host.hidden=false;item.enabled(true);
      }
    };
    return {sync,dispose(){sync([],false);for(const name of events)view.removeEventListener(name,reserve,true);view.removeEventListener('click',click,true);}};
  };
  return {address,documentPage,page,feed,parent,owners,declaration,visible,read,binding,controls};
})();
