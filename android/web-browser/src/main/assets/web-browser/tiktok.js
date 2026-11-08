/* Current TikTok detail player. Reuses douyin-current.js's read-only React data
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
  const declaration=(video,document)=>{
    try{
      const selected=page(document);if(!selected)return null;
      const card=video.closest?.('article[data-e2e="recommend-list-item-container"]');
      if(!card||card.querySelectorAll('video').length!==1)return null;
      const items=props(card).flatMap(p=>targets(p,'item'));
      if(!items.length||items.some(item=>own(item,'id')!==selected.id))return null;
      const bad=['has_drm','is_drm','drm_type','is_encrypted','hasDrm','isDrm','drmType','isEncrypted'];
      if(items.some(item=>marked(item,['isAd','isAds','is_ads','isLive','is_live','isSlides','isSlideShow','imagePost',...bad])||marked(own(item,'video'),bad)))return null;
      let sources=[];
      for(let n=video,depth=0;n&&depth<8;n=n.parentElement,depth++){
        sources=props(n).flatMap(p=>targets(p,'videoSource'));
        if(sources.length)break; // This rendered player's nearest owner, not a feed-wide preload queue.
      }
      const normalized=[];
      for(const source of new Set(sources)){
        if(own(source,'id')!==selected.id||['vid','groupId'].some(k=>own(source,k)!==undefined&&own(source,k)!==selected.id)||marked(source,bad))return null;
        const width=own(source,'width'),height=own(source,'height'),duration=own(source,'duration');
        if(!Number.isInteger(width)||!Number.isInteger(height)||width<=0||height<=0||width>8192||height>8192||
          !Number.isInteger(duration)||duration<=0||duration>86400)return null;
        // url/playAddr describe the active file; bitrateList contains alternatives.
        // audioBitrateList and the post's unrelated music are never guessed/paired.
        const urls=[...new Set([...addresses(own(source,'url')),...addresses(own(source,'playAddr'))])];
        if(!urls.length||urls.length>16)return null;
        normalized.push({id:selected.id,width,height,duration,urls});
      }
      const unique=[...new Map(normalized.map(d=>[JSON.stringify(d),d])).values()];
      return unique.length===1?unique[0]:null;
    }catch(_){return null;}
  };
  const visible=video=>{
    const r=video.getBoundingClientRect?.();if(r&&(!r.width||!r.height||r.bottom<=0||r.right<=0||r.top>=innerHeight||r.left>=innerWidth))return false;
    if(typeof getComputedStyle==='function')for(let n=video,depth=0;n&&depth<16;n=n.parentElement,depth++){
      const s=getComputedStyle(n);if(s&&(s.display==='none'||s.visibility==='hidden'||s.opacity==='0'))return false;
    }
    return true;
  };
  const revision=value=>{let h=2166136261;for(let i=0;i<value.length;i++){h^=value.charCodeAt(i);h=Math.imul(h,16777619);}return (h>>>0).toString(16);};
  const read=(video,document)=>{
    if(!video.isConnected||video.mediaKeys||video.seeking||video.ended||video.readyState<2||!visible(video)||
      !Number.isFinite(video.duration)||video.duration<=0||video.duration>86400)return null;
    const source=video.currentSrc||'';
    if(!source.startsWith('blob:https://www.tiktok.com/')&&!source.startsWith('blob:https://tiktok.com/')&&!address(source))return null;
    const d=declaration(video,document);
    // The observed SDK stores integer whole seconds; the decoded MP4 has a
    // fractional tail. Verify that exact second instead of borrowing DOM duration.
    if(!d||d.width!==video.videoWidth||d.height!==video.videoHeight||Math.floor(video.duration)!==d.duration)return null;
    return d;
  };
  const binding=(video,requests,document,live)=>{
    const d=read(video,document);if(!d||!Array.isArray(requests)||!Array.isArray(live))return null;
    if(live.some(v=>v!==video&&v.isConnected&&v.readyState>=2&&v.videoWidth>0&&visible(v)))return null;
    const matched=requests.filter(r=>{const age=Date.now()-r.at;return r.kind==='file'&&d.urls.includes(r.url)&&Number.isFinite(age)&&age>=0&&age<=1800000;});
    const urls=[...new Set(matched.map(r=>r.url))];if(urls.length!==1)return null;
    const source=urls[0];if(address(video.currentSrc)&&video.currentSrc!==source)return null;
    return {id:d.id,page:document,source,width:d.width,height:d.height,duration:video.duration,expected_duration:d.duration,
      revision:revision(d.id+'\n'+d.width+'x'+d.height+'\n'+d.duration+'\n'+source)};
  };
  return {own,list,address,documentPage,page,addresses,targets,declaration,visible,read,binding,revision};
})();
