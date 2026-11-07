/* Current rendered Douyin card. Data descriptors and already issued addresses;
 * no SDK calls, account storage, signature generation or unrelated music. */
const Thru3DDouyinCurrent = (() => {
  'use strict';
  const own=(o,k)=>o&&typeof o==='object'?Object.getOwnPropertyDescriptor(o,k)?.value:undefined;
  const list=(v,max)=>Array.isArray(v)?Array.from({length:Math.min(own(v,'length'),max)},(_,i)=>own(v,String(i))):[];
  const validId=v=>typeof v==='string'&&/^[1-9][0-9]{14,19}$/.test(v);
  const ancestors=16; // The actual featured player owner was its tenth parent.
  const ownerAttributes=['data-e2e-vid','data-aweme-id','data-video-id'];
  const fields=['aweme','awemeInfo','aweme_info','awemeData','awemeDetail','item','itemInfo','itemData','data','videoInfo','videoData','config','props'];
  const marked=(o,keys)=>keys.some(k=>{const v=own(o,k);return v!==undefined&&v!==null&&v!==false&&v!==0&&v!=='0'&&v!==''&&v!=='false';});
  const addresses=value=>{
    const values=Array.isArray(value)?list(value,8).map(v=>typeof v==='string'?v:own(v,'src')):
      ['mainUrl','backupUrl','fallbackUrl','main_url','backup_url','fallback_url'].map(k=>own(value,k));
    return [...new Set(values.filter(v=>typeof v==='string'&&Thru3DDouyin.address(v)))];
  };
  const normalize=(raw,id)=>{
    if(!['awemeId','aweme_id','id'].some(k=>own(raw,k)===id))return null;
    const v=own(raw,'video'),rawDuration=own(v,'duration'),duration=typeof rawDuration==='number'?rawDuration/1000:NaN;
    if(!v||!Number.isFinite(duration)||duration<=0||duration>86400||
      marked(raw,['isAds','is_ads','isSlides','is_live','isLive','is_preview','isPreview'])||list(own(raw,'images'),1).length||
      [raw,v].some(o=>marked(o,['has_drm','is_drm','drm_type','is_encrypted','hasDrm','isDrm','drmType','isEncrypted'])))return null;
    const video=[];
    const add=(row,urls)=>{
      const width=own(row,'width'),height=own(row,'height');
      if(Number.isInteger(width)&&Number.isInteger(height)&&width>0&&height>0&&width<=8192&&height<=8192&&urls.length)
        video.push({width,height,urls});
    };
    add(v,addresses(own(v,'playAddr')));
    const rawMain=own(v,'play_addr');add(rawMain,addresses(own(rawMain,'url_list')));
    for(const row of list(own(v,'bitRateList'),32))add(row,addresses(own(row,'playAddr')));
    for(const row of list(own(v,'bit_rate'),32)){const track=own(row,'play_addr');add(track,addresses(own(track,'url_list')));}
    const audio=[];
    for(const row of [...list(own(v,'bitRateAudioList'),8),...list(own(v,'bit_rate_audio'),8).map(a=>own(a,'audio_meta'))]){
      const urls=addresses(own(row,'urlList')||own(row,'url_list')),fileId=own(row,'fileId')||own(row,'file_id');
      if(urls.length)audio.push({id:typeof fileId==='string'&&/^[A-Za-z0-9_-]{1,160}$/.test(fileId)?fileId:'',urls});
    }
    const result={id,duration,video:[...new Map(video.map(t=>[JSON.stringify(t),t])).values()],...(audio.length?{audio}:{})};
    return result.video.length&&result.video.length<=33&&JSON.stringify(result).length<=96*1024?result:null;
  };
  const declarations=(video,id)=>{
    const seen=new WeakSet(),result=[],nodes=[];let count=0;
    const walk=(o,depth)=>{
      if(!o||typeof o!=='object'||seen.has(o)||depth>3||count>=80||result.length>=8)return;
      seen.add(o);count++;
      const value=normalize(o,id);if(value)result.push(value);
      for(const key of fields)walk(own(o,key),depth+1);
    };
    for(let e=video;e&&nodes.length<ancestors;e=e.parentElement)nodes.push(e);
    nodes.sort((a,b)=>Number(ownerAttributes.some(k=>b.getAttribute?.(k)===id))-Number(ownerAttributes.some(k=>a.getAttribute?.(k)===id)));
    for(const node of nodes){
      const raw=node.wrappedJSObject||node,keys=Object.getOwnPropertyNames(raw),props=keys.find(k=>/^__reactProps\$/.test(k)),fiber=keys.find(k=>/^__reactFiber\$/.test(k));
      if(props)walk(own(raw,props),0);
      if(fiber)for(let f=own(raw,fiber),i=0;f&&i<6;f=own(f,'return'),i++)walk(own(f,'memoizedProps'),0);
    }
    // Conflicting declarations for one rendered owner require a new observation.
    const unique=[...new Map(result.map(d=>[JSON.stringify(d),d])).values()];
    return unique.length===1?unique[0]:null;
  };
  const ownerState=(video,value)=>{
    if(!Thru3DDouyin.documentPage(value))return {reason:'document'};
    const url=new URL(value),modal=url.searchParams.getAll('modal_id'),path=/^\/video\/([1-9][0-9]{14,19})\/?$/.exec(url.pathname)?.[1];
    if(!path&&!['/','/jingxuan','/recommend','/discover','/search/'].includes(url.pathname))return {reason:'path'};
    if(modal.length>1||modal.length&&!validId(modal[0])||path&&modal.length&&path!==modal[0])return {reason:'modal'};
    const ids=new Set();let active=false,detail=false,player=false;
    for(let node=video,i=0;node&&i<ancestors;node=node.parentElement,i++){
      for(const key of ownerAttributes){const id=node.getAttribute(key);if(validId(id))ids.add(id);}
      active=active||node.getAttribute('data-e2e')==='feed-active-video';
      detail=detail||node.getAttribute('data-e2e')==='video-detail';
      player=player||node.getAttribute('data-e2e')==='player-container';
    }
    // The real dedicated detail player has these markers but no public ID
    // attribute. Only its actual detail URL supplies identity in that layout;
    // its own React declaration must still independently match it below.
    if(ids.size===0&&path&&detail&&player)ids.add(path);
    if(ids.size!==1)return {reason:ids.size?'conflicting_owners':'missing_owner'};
    const id=[...ids][0];if((path||modal[0])&&(path||modal[0])!==id)return {reason:'different_page_id'};
    return {reason:'ok',id,active};
  };
  const owner=(video,value)=>{const state=ownerState(video,value);return state.reason==='ok'?{id:state.id,active:state.active}:null;};
  const read=(video,value)=>{
    try{
    const selected=owner(video,value);if(!selected||video.mediaKeys||video.seeking||video.ended||video.readyState<2)return null;
    const data=declarations(video,selected.id);
    if(!data||!Number.isFinite(video.duration)||Math.abs(video.duration-data.duration)>Math.max(.5,data.duration*.01)||
      !data.video.some(t=>t.width===video.videoWidth&&t.height===video.videoHeight))return null;
    return {data,active:selected.active};
    }catch(_){return null;}
  };
  const bind=(selected,video,requests)=>{
    if(!selected)return null;
    const data=selected.data,tracks=data.video.filter(t=>t.width===video.videoWidth&&t.height===video.videoHeight);
    const matching=tracks.filter(t=>t.urls.some(u=>Thru3DDouyin.matches(u,video.currentSrc,data.id)));
    const files=requests.filter(r=>r.kind==='file');
    const videoUrls=[...new Set(files.filter(r=>tracks.some(t=>t.urls.some(u=>Thru3DDouyin.matches(u,r.url,data.id)))).map(r=>r.url))];
    const audioUrls=[...new Set(files.filter(r=>(data.audio||[]).some(t=>t.urls.some(u=>Thru3DDouyin.matches(u,r.url,data.id)))).map(r=>r.url))];
    const mse=video.currentSrc.startsWith('blob:');
    const source=mse?videoUrls.length===1?videoUrls[0]:null:matching.length&&files.some(r=>r.url===video.currentSrc)?video.currentSrc:null;
    if(!source||mse&&audioUrls.length>1)return null;
    const sound=mse&&audioUrls[0],track=tracks.find(t=>t.urls.some(u=>Thru3DDouyin.matches(u,source,data.id)));
    const result={id:data.id,duration:data.duration,video:[{width:track.width,height:track.height,urls:track.urls.filter(u=>Thru3DDouyin.matches(u,source,data.id))}],
      ...(mse?{observed_file:source}:{}),...(sound===source?{observed_muxed:true}:sound?{observed_audio:sound}:{}),
      ...(sound&&sound!==source?{audio:data.audio.map(t=>({...t,urls:t.urls.filter(u=>Thru3DDouyin.matches(u,sound,data.id))})).filter(t=>t.urls.length)}:{})};
    return {data:result,video_requests:videoUrls.length,audio_requests:audioUrls.length};
  };
  const revision=text=>{let h=2166136261;for(let i=0;i<text.length;i++)h=Math.imul(h^text.charCodeAt(i),16777619);return(h>>>0).toString(16).padStart(8,'0');};
  const capture=(video,page,requests,selected=read(video,page))=>{
    const bound=bind(selected,video,requests);if(!bound)return null;
    const data=bound.data,src=video.currentSrc,width=video.videoWidth,height=video.videoHeight;
    return {...data,page,src,width,height,active_id:data.id,binding:'rendered_card',
      revision:revision(JSON.stringify([page,src,data.id,data.duration,width,height,data.video,data.observed_file||'',data.observed_audio||'',data.observed_muxed===true]))};
  };
  const diagnostics=(selected,video,requests)=>{
    const data=selected?.data;if(!data)return {observed_files:requests.length};
    const relationships=[];
    for(const t of [...data.video.map(t=>({...t,role:'video'})),...(data.audio||[]).map(t=>({...t,role:'audio'}))])for(const declared of t.urls)for(const request of requests){
      const a=new URL(declared),b=new URL(request.url),tail=u=>u.pathname.includes('/video/tos/')?u.pathname.slice(u.pathname.indexOf('/video/tos/')):null;
      if(a.pathname!==b.pathname&&(!tail(a)||tail(a)!==tail(b)))continue;
      const keys=u=>[...new Set([...u.searchParams.keys()])].filter(k=>/^[A-Za-z_][A-Za-z0-9_]{0,63}$/.test(k));
      const shape=u=>u.pathname.split('/').filter(Boolean).slice(0,12).map(p=>({length:p.length,kind:['video','tos','cn'].includes(p)?p:p.startsWith('tos-cn-')?'bucket':/^[a-fA-F0-9]+$/.test(p)?'hex':/^[A-Za-z0-9_-]+$/.test(p)?'key':'other'}));
      relationships.push({role:t.role,decoded_dimensions:t.width===video.videoWidth&&t.height===video.videoHeight,
        same_origin:a.origin===b.origin,same_path:a.pathname===b.pathname,same_object:!!tail(a)&&tail(a)===tail(b),
        declared_path_shape:shape(a),observed_path_shape:shape(b),
        changed_keys:keys(a).filter(k=>JSON.stringify(a.searchParams.getAll(k))!==JSON.stringify(b.searchParams.getAll(k))),
        added_keys:keys(b).filter(k=>!a.searchParams.has(k))});
      if(relationships.length>=16)return {observed_files:requests.length,relationships};
    }
    return {observed_files:requests.length,relationships};
  };
  return {read,bind,capture,owner,normalize,diagnostics,ownerReason:(video,value)=>ownerState(video,value).reason};
})();
