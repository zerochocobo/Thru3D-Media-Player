/* Current TikTok video card. Reuses douyin-current.js's read-only React data
 * descriptors; no SDK calls, API replay, signing, account store or music lookup. */
const Thru3DTikTok=(()=>{
  'use strict';
  const own=(o,k)=>{try{return o&&typeof o==='object'?Object.getOwnPropertyDescriptor(o,k)?.value:undefined;}catch(_){return undefined;}};
  const list=(value,max=32)=>Array.isArray(value)?Array.from({length:Math.min(own(value,'length'),max)},(_,i)=>own(value,String(i))):[];
  const address=value=>{try{const u=new URL(value);return typeof value==='string'&&value.length<=16384&&u.protocol==='https:'&&!u.username&&!u.password&&!u.port&&!u.hash?u:null;}catch(_){return null;}};
  const documentPage=value=>{try{const u=new URL(value);return typeof value==='string'&&value.length<=8192&&u.protocol==='https:'&&!u.username&&!u.password&&!u.port&&['www.tiktok.com','tiktok.com'].includes(u.hostname);}catch(_){return false;}};
  const page=value=>{
    const u=address(value);if(!u||!['www.tiktok.com','tiktok.com'].includes(u.hostname))return null;
    const m=/^\/@([A-Za-z0-9_.]{1,64})\/video\/([1-9][0-9]{14,19})\/?$/.exec(u.pathname);
    return m?{id:m[2],user:m[1],page:'https://www.tiktok.com/@'+m[1]+'/video/'+m[2]}:null;
  };
  const grid=value=>{const u=address(value);return !!u&&documentPage(value)&&['/explore','/explore/'].includes(u.pathname);};
  const feed=value=>{const u=address(value);return !!u&&documentPage(value)&&['/','/foryou','/foryou/','/explore','/explore/'].includes(u.pathname);};
  const marked=(o,fields)=>fields.some(k=>{const v=own(o,k);return v!==undefined&&v!==null&&v!==false&&v!==0&&v!=='0'&&v!==''&&v!=='false';});
  const addresses=value=>{
    const values=typeof value==='string'?[value]:Array.isArray(value)?list(value,8).flatMap(v=>typeof v==='string'?[v]:[own(v,'src'),own(v,'url')]):
      ['mainUrl','backupUrl','fallbackUrl','main_url','backup_url','fallback_url','url','UrlList','urlList'].flatMap(k=>{
        const v=own(value,k);return typeof v==='string'?[v]:list(v,8);
      });
    return [...new Set(values.filter(v=>address(v)))];
  };
  const targets=(root,field)=>{
    const result=[],seen=new WeakSet();let budget=0;
    const walk=(o,depth)=>{
      if(!o||typeof o!=='object'||seen.has(o)||depth>7||++budget>256)return;
      seen.add(o);
      if(Array.isArray(o)){for(const v of list(o,12))walk(v,depth+1);return;}
      const value=own(o,field);if(value&&typeof value==='object')result.push(value);
      walk(own(o,'props'),depth+1);walk(own(o,'children'),depth+1);
    };
    walk(root,0);return result;
  };
  const props=node=>{
    const raw=node.wrappedJSObject||node;
    return Object.getOwnPropertyNames(raw).filter(k=>/^__reactProps\$/.test(k)).slice(0,2).map(k=>own(raw,k));
  };
  const declaration=(video,document,diagnostics)=>{
    const fail=status=>{if(diagnostics)diagnostics.status=status;return null;};
    try{
      let selected=page(document);const inFeed=!selected&&feed(document);if(!selected&&!inFeed)return fail('document');
      // The official detail container can acquire a queued, offscreen next
      // video after playback starts. Match the presented owner, not DOM count.
      const cardVideos=node=>[...node.querySelectorAll('video')].filter(v=>v===video||typeof v.getBoundingClientRect!=='function'||presented(v));
      let card=video.closest?.('article[data-e2e="recommend-list-item-container"]');
      // Some detail pages retain an outer feed article containing the queued
      // next clip. It is not this player's owner; resolve the nearer item below.
      if(selected&&card&&cardVideos(card).length!==1)card=null;
      const preview=!card&&grid(document);
      if(preview)card=video.closest?.('a[href]');
      // The current desktop detail layout uses divs rather than an article.
      // Stop at this player's nearest item owner; never scan another card or
      // a page-wide item queue to make the canonical detail identity fit.
      if(!card&&selected)for(let node=video,depth=0;node&&depth<12;node=node.parentElement,depth++){
        if(props(node).some(p=>targets(p,'item').length)){card=node;break;}
      }
      if(!card||cardVideos(card).length!==1)return fail('card');
      // Explore touches can start an inline preview without navigating. Its
      // nearest real link, item owner and player source must all name one clip.
      const linked=preview?page(card.href):null;
      if(preview&&!linked)return fail('owner_identity');
      const items=props(card).flatMap(p=>targets(p,'item'));
      if(inFeed){
        const owners=items.map(item=>{const id=own(item,'id'),author=own(item,'author'),user=typeof author==='string'?author:own(author,'uniqueId');
          return typeof id==='string'&&/^[1-9][0-9]{14,19}$/.test(id)&&typeof user==='string'&&/^[A-Za-z0-9_.]{1,64}$/.test(user)?page('https://www.tiktok.com/@'+user+'/video/'+id):null;});
        if(!owners.length||owners.some(o=>!o)||new Set(owners.map(o=>o.page)).size!==1)return fail('owner_identity');
        if(preview&&owners[0].page!==linked.page)return fail('owner_identity');
        selected=owners[0];
      }
      if(diagnostics)Object.assign(diagnostics,{public_id:selected.id,public_page:selected.page});
      if(!items.length||items.some(item=>own(item,'id')!==selected.id))return fail('different_item');
      const bad=['has_drm','is_drm','drm_type','is_encrypted','hasDrm','isDrm','drmType','isEncrypted'];
      if(diagnostics)diagnostics.advertisement=items.some(item=>marked(item,['isAd','isAds','is_ads']));
      if(items.some(item=>marked(item,['isAd','isAds','is_ads','isLive','is_live','isSlides','isSlideShow','imagePost',...bad])||marked(own(item,'video'),bad)))return fail('excluded_content');
      let sources=[];
      for(let n=video,depth=0;n&&depth<8;n=n.parentElement,depth++){
        sources=props(n).flatMap(p=>targets(p,'videoSource'));
        if(sources.length)break; // This rendered player's nearest owner, not a feed-wide preload queue.
      }
      const normalized=[];
      for(const source of new Set(sources)){
        if(own(source,'id')!==selected.id||['vid','groupId'].some(k=>own(source,k)!==undefined&&own(source,k)!==selected.id)||marked(source,bad))return fail('source_identity');
        const width=own(source,'width'),height=own(source,'height'),duration=own(source,'duration');
        if(!Number.isInteger(width)||!Number.isInteger(height)||width<=0||height<=0||width>8192||height>8192||
          !Number.isInteger(duration)||duration<=0||duration>86400)return fail('source_shape');
        if(diagnostics)Object.assign(diagnostics,{expected_width:width,expected_height:height,expected_duration:duration});
        // url/playAddr describe the active file; bitrateList contains alternatives.
        // audioBitrateList and the post's unrelated music are never guessed/paired.
        const urls=[...new Set([...addresses(own(source,'url')),...addresses(own(source,'playAddr'))])];
        if(!urls.length||urls.length>16)return fail('source_address');
        normalized.push({id:selected.id,width,height,duration,urls,...(inFeed?{page:selected.page,document,binding:'rendered_card',active_id:selected.id}:{})});
      }
      const unique=[...new Map(normalized.map(d=>[JSON.stringify(d),d])).values()];
      return unique.length===1?unique[0]:fail('ambiguous_declaration');
    }catch(_){return fail('declaration_error');}
  };
  const visible=video=>{
    const r=video.getBoundingClientRect?.();if(r&&(!r.width||!r.height||r.bottom<=0||r.right<=0||r.top>=innerHeight||r.left>=innerWidth))return false;
    if(typeof getComputedStyle==='function')for(let n=video,depth=0;n&&depth<16;n=n.parentElement,depth++){
      const s=getComputedStyle(n);if(s&&(s.display==='none'||s.visibility==='hidden'||s.opacity==='0'))return false;
    }
    return true;
  };
  // Feed layouts preload the next decoded video just below the current one.
  // A sliver at the viewport edge is not a second presented player.
  const presented=video=>{
    if(!visible(video))return false;
    const r=video.getBoundingClientRect?.();if(!r)return false;
    const area=Math.max(0,Math.min(r.right,innerWidth)-Math.max(r.left,0))*Math.max(0,Math.min(r.bottom,innerHeight)-Math.max(r.top,0));
    return r.width>0&&r.height>0&&area/(r.width*r.height)>.5;
  };
  const revision=value=>{let h=2166136261;for(let i=0;i<value.length;i++){h^=value.charCodeAt(i);h=Math.imul(h,16777619);}return (h>>>0).toString(16);};
  const read=(video,document,diagnostics)=>{
    const fail=status=>{if(diagnostics)diagnostics.status=status;return null;};
    if(!video.isConnected||video.mediaKeys||video.seeking||video.readyState<2||!presented(video)||
      !Number.isFinite(video.duration)||video.duration<=0||video.duration>86400)return fail('not_decoded');
    if(diagnostics)diagnostics.decoded_duration=video.duration;
    const source=video.currentSrc||'';
    if(!source.startsWith('blob:https://www.tiktok.com/')&&!source.startsWith('blob:https://tiktok.com/')&&!address(source))return fail('source_scheme');
    const d=declaration(video,document,diagnostics);
    // The site's integer duration is approximate (observed 14 vs 15.136553).
    // Reuse the existing whole-file probe budget; the current card/SDK ID,
    // exact observed source, dimensions and Native container/audio still agree.
    if(!d)return null;
    if(d.width!==video.videoWidth||d.height!==video.videoHeight||Math.abs(video.duration-d.duration)>Math.max(2,d.duration*.01))return fail('decoded_shape');
    return d;
  };
  const binding=(video,requests,document,live,diagnostics)=>{
    const fail=status=>{if(diagnostics)diagnostics.status=status;return null;};
    const d=read(video,document,diagnostics);if(!d)return null;
    if(!Array.isArray(requests)||!Array.isArray(live))return fail('observed_payload');
    if(live.some(v=>v!==video&&v.isConnected&&v.readyState>=2&&v.videoWidth>0&&presented(v)))return fail('multiple_players');
    const matched=requests.filter(r=>{const age=Date.now()-r.at;return r.kind==='file'&&d.urls.includes(r.url)&&Number.isFinite(age)&&age>=0&&age<=1800000;});
    const urls=[...new Set(matched.map(r=>r.url))];if(urls.length!==1)return fail('observed_payload');
    const source=urls[0];if(address(video.currentSrc)&&video.currentSrc!==source)return fail('direct_source');
    if(diagnostics)diagnostics.status='bound';
    return {id:d.id,page:d.page||document,...(d.binding?{document:d.document,binding:d.binding,active_id:d.active_id}:{}),source,width:d.width,height:d.height,duration:video.duration,expected_duration:d.duration,
      start_seconds:video.ended?0:video.currentTime,revision:revision(d.id+'\n'+d.width+'x'+d.height+'\n'+d.duration+'\n'+source)};
  };
  return {own,list,address,documentPage,page,feed,grid,addresses,targets,declaration,visible,presented,read,binding,revision};
})();
