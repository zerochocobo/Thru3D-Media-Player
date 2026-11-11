/* Current public clips only. No channel/live/VOD inference, API replay or signing. */
const Thru3DTwitch = (() => {
  'use strict';
  const address = value => {
    try { const u=new URL(value);return typeof value==='string'&&value.length<=16384&&u.protocol==='https:'&&!u.username&&!u.password&&!u.hash&&!u.port?u:null; }
    catch(_){return null;}
  };
  const slug = value => typeof value==='string'&&/^[A-Za-z0-9_-]{1,200}$/.test(value);
  const api = value => {
    // Twitch annotates actual GraphQL requests with a URL fragment. It is not
    // transmitted to HTTP; inspect that response without rewriting/replaying it.
    try{const u=new URL(value);return typeof value==='string'&&value.length<=16384&&u.protocol==='https:'&&!u.username&&!u.password&&!u.port&&u.pathname==='/gql';}
    catch(_){return false;}
  };
  const page = value => {
    const u=address(value);if(!u)return null;
    if(u.hostname==='clips.twitch.tv'){
      const id=/^\/([A-Za-z0-9_-]{1,200})\/?$/.exec(u.pathname)?.[1];return id&&!['embed','create','manage'].includes(id)?id:null;
    }
    if(['www.twitch.tv','twitch.tv'].includes(u.hostname))return /^\/[A-Za-z0-9_]{1,25}\/clip\/([A-Za-z0-9_-]{1,200})\/?$/.exec(u.pathname)?.[1]||null;
    return null;
  };
  const canonical = value => {const id=page(value);return id?'https://clips.twitch.tv/'+id:null;};
  const revision = value => {let h=2166136261;for(let i=0;i<value.length;i++){h^=value.charCodeAt(i);h=Math.imul(h,16777619);}return (h>>>0).toString(16);};
  const metadata = (body,document) => {
    const expected=page(document);if(!expected||typeof body!=='string'||body.length>2*1024*1024)return [];
    let root;try{root=JSON.parse(body);}catch(_){return [];}
    const result=[];
    for(const part of (Array.isArray(root)?root:[root]).slice(0,64)){
      const c=part?.data?.clip;
      if(part?.errors||!c||typeof c.id!=='string'||!/^[A-Za-z0-9_-]{1,80}$/.test(c.id))continue;
      if(c.slug!==undefined&&(!slug(c.slug)||c.slug!==expected))continue;
      const duration=Number.isFinite(c.durationSeconds)&&c.durationSeconds>0&&c.durationSeconds<=3600?c.durationSeconds:0;
      const token=c.playbackAccessToken,tracks=[];
      // Current codec variants are declared under this same clip's assets.
      // Read only video qualities; downloads and arbitrary nested URLs are not
      // playback declarations. The actual signed file request still must match.
      const protectedAsset=a=>['drm','hasDrm','isDrm','encrypted','isEncrypted','isProtected','isAd','isLive'].some(k=>
        a[k]!==undefined&&a[k]!==null&&a[k]!==false&&a[k]!==0&&a[k]!==''&&a[k]!=='false'&&a[k]!=='0');
      const lists=Array.isArray(c.assets)&&c.assets.length<=8?c.assets.filter(a=>a&&typeof a==='object'&&!protectedAsset(a)).map(a=>a.videoQualities):[];
      lists.push(c.videoQualities);
      for(const list of lists)if(Array.isArray(list)&&list.length<=32)for(const q of list){
        const u=address(q?.sourceURL);if(!u||!u.pathname.endsWith('.mp4'))continue;
        const quality=typeof q.quality==='string'&&/^[0-9]{3,4}$/.test(q.quality)?Number(q.quality):0;
        const signature=typeof token?.signature==='string'&&token.signature.length<=1024?token.signature:'';
        const value=typeof token?.value==='string'&&token.value.length<=16384?token.value:'';
        tracks.push({source:u.href,quality,signature,token:value});
      }
      if(c.slug===expected&&duration>0||tracks.length)result.push({clip:c.id,id:c.slug===expected?expected:null,duration,tracks});
    }
    return result;
  };
  const merge = (store,parts) => {
    for(const part of parts){
      const prior=store.get(part.clip)||{clip:part.clip,id:null,duration:0,tracks:[]};
      const tracks=[...prior.tracks,...part.tracks].filter((t,i,a)=>a.findIndex(v=>v.source===t.source&&v.signature===t.signature&&v.token===t.token)===i).slice(-32);
      store.set(part.clip,{clip:part.clip,id:part.id||prior.id,duration:part.duration||prior.duration,tracks});
    }
    while(store.size>8)store.delete(store.keys().next().value);
  };
  const matches = (track,value) => {
    const declared=address(track.source),actual=address(value);if(!declared||!actual)return false;
    if(declared.href===actual.href)return true;
    // Verify the site's actual signed request against its declaration. Never
    // generate a signed URL, remove selectors, or transfer these API credentials.
    return !declared.search&&declared.origin===actual.origin&&declared.pathname===actual.pathname&&
      [...actual.searchParams.keys()].length===2&&actual.searchParams.getAll('sig').length===1&&actual.searchParams.getAll('token').length===1&&
      !!track.signature&&!!track.token&&actual.searchParams.get('sig')===track.signature&&actual.searchParams.get('token')===track.token;
  };
  const records = (store,requests,document) => {
    const id=page(document),current=[...store.values()].filter(m=>m.id===id&&m.duration>0);
    if(!id||current.length!==1)return [];
    const meta=current[0],result=[];
    for(const r of requests){
      const age=Date.now()-r.at;if(r.kind!=='file'||!Number.isFinite(age)||age<0||age>1800000)continue;
      const tracks=meta.tracks.filter(t=>matches(t,r.url));if(!tracks.length)continue;
      if(result.some(v=>v.source===r.url))continue;
      result.push({id,source:r.url,expected_duration:meta.duration,qualities:[...new Set(tracks.map(t=>t.quality).filter(Boolean))],
        revision:revision(id+'\n'+meta.duration+'\n'+r.url)});
    }
    return result;
  };
  const visible = video => {
    const r=video.getBoundingClientRect?.();if(r&&(!r.width||!r.height||r.bottom<=0||r.right<=0||r.top>=innerHeight||r.left>=innerWidth))return false;
    if(typeof getComputedStyle==='function')for(let n=video,depth=0;n&&depth<16;n=n.parentElement,depth++){
      const s=getComputedStyle(n);if(s&&(s.display==='none'||s.visibility==='hidden'||s.opacity==='0'))return false;
    }
    return true;
  };
  // Some clip declarations contain whole catalogue seconds. Match that exact
  // second's decoded floor while retaining the existing fractional tolerance.
  const durationMatches = (expected,actual) => Number.isFinite(expected)&&expected>0&&expected<=3600&&
    Number.isFinite(actual)&&actual>0&&actual<=3600&&
    (Math.abs(expected-actual)<=.5||Number.isInteger(expected)&&Math.floor(actual)===expected);
  const owner = (data,document,live) => {
    const id=page(document);if(!id||!Array.isArray(data)||!Array.isArray(live))return null;
    const matches=live.filter(v=>v.isConnected&&!v.mediaKeys&&v.readyState>=2&&v.videoWidth>0&&v.videoHeight>0&&visible(v)&&
      Number.isFinite(v.duration)&&v.duration>0&&data.some(d=>d.id===id&&d.source===v.currentSrc&&durationMatches(d.expected_duration,v.duration)&&
        (!d.qualities.length||d.qualities.includes(v.videoHeight))));
    // Concurrent visible players/ad overlays must never choose each other's file.
    if(matches.length!==1||live.some(v=>v!==matches[0]&&v.isConnected&&v.readyState>=2&&v.videoWidth>0&&visible(v)))return null;
    return matches[0];
  };
  const binding = (video,data,requests,document,live) => {
    if(owner(data,document,live)!==video)return null;
    const rows=data.filter(d=>d.id===page(document)&&d.source===video.currentSrc&&durationMatches(d.expected_duration,video.duration));
    const request=requests.filter(r=>r.kind==='file'&&r.url===video.currentSrc);
    if(rows.length!==1||new Set(request.map(r=>r.url)).size!==1)return null;
    const d=rows[0];return {id:d.id,page:document,source:d.source,revision:d.revision,expected_duration:d.expected_duration,
      width:video.videoWidth,height:video.videoHeight,duration:video.duration};
  };
  return {address,api,page,canonical,revision,metadata,merge,matches,records,visible,owner,binding};
})();
