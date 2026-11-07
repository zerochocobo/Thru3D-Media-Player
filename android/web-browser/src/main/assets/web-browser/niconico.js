/* Current watch access declaration and the HLS graph actually loaded by its document.
 * No API replay, signed-URL construction, account lookup or license handling. */
const Thru3DNiconico = (() => {
  'use strict';
  const address=value=>{try{if(typeof value!=='string'||value.length>16384)return null;const u=new URL(value);
    return u.protocol==='https:'&&!u.username&&!u.password&&!u.hash?u:null;}catch(_){return null;}};
  const page=value=>{const u=address(value);return u&&!u.port&&u.hostname==='www.nicovideo.jp'?
    /^\/watch\/((?:sm|nm|so)[0-9]{1,20})\/?$/.exec(u.pathname)?.[1]||null:null;};
  const access=(value,document)=>{const u=address(value),id=page(document);
    return !!u&&!!id&&/^\/v[0-9]+\/watch\/((?:sm|nm|so)[0-9]{1,20})\/access-rights\/hls$/.exec(u.pathname)?.[1]===id;};
  const revision=value=>{let h=2166136261;for(let i=0;i<value.length;i++)h=Math.imul(h^value.charCodeAt(i),16777619);return(h>>>0).toString(16);};
  const rights=(raw,document)=>{
    const id=page(document),root=address(raw?.data?.contentUrl);
    return id&&root&&[200,201].includes(raw?.meta?.status)?{id,root:root.href}:null;
  };
  const attrs=line=>{
    const result={},text=line.slice(line.indexOf(':')+1);let offset=0;
    const re=/([A-Z0-9-]+)=("[^"\r\n]*"|[^,\r\n]*)(?:,|$)/gy;
    while(offset<text.length){re.lastIndex=offset;const m=re.exec(text);if(!m||Object.hasOwn(result,m[1]))return null;
      result[m[1]]=m[2].startsWith('"')?m[2].slice(1,-1):m[2];offset=re.lastIndex;}
    return result;
  };
  const target=(base,value)=>{try{return typeof value==='string'&&value.length>0&&!/[\x00-\x20\x7f]/.test(value)?address(new URL(value,base).href)?.href||null:null;}catch(_){return null;}};
  const lines=body=>typeof body==='string'&&body.length<=160*1024?body.replace(/^\uFEFF/,'').trim().split(/\r?\n/).map(v=>v.trim()):[];
  const master=(body,base)=>{
    const l=lines(body);if(l[0]!=='#EXTM3U'||!address(base)||l.some(v=>/^#EXT-X-(?:SESSION-KEY|DEFINE):/.test(v)))return null;
    const audios=[];
    for(const v of l.filter(v=>v.startsWith('#EXT-X-MEDIA:'))){const a=attrs(v);if(!a)return null;
      if(a.TYPE==='AUDIO'){const url=target(base,a.URI);if(!url||!a['GROUP-ID'])return null;audios.push({group:a['GROUP-ID'],url});}}
    if(!audios.length||audios.length>16)return null;
    const variants=[];
    for(let i=0;i<l.length;i++)if(l[i].startsWith('#EXT-X-STREAM-INF:')){
      const a=attrs(l[i]),next=l[i+1];if(!a||!next||next.startsWith('#')||a['VIDEO-RANGE']&&a['VIDEO-RANGE']!=='SDR')return null;
      const url=target(base,next),size=/^([1-9][0-9]{0,4})x([1-9][0-9]{0,4})$/.exec(a.RESOLUTION||'');
      const codecs=(a.CODECS||'').split(','),vc=codecs.find(c=>/^(?:avc[13]|hvc1|hev1|vp09|av01)\./i.test(c)),ac=codecs.find(c=>/^(?:mp4a\.|opus$|ac-3$|ec-3$)/i.test(c));
      const group=audios.filter(v=>v.group===a.AUDIO);
      if(!url||!size||+size[1]>16384||+size[2]>16384||!vc||!ac||!group.length)return null;
      for(const audio of group)if(url!==audio.url)variants.push({video:url,audio:audio.url,width:+size[1],height:+size[2],vcodec:vc,acodec:ac});
    }
    return variants.length>0&&variants.length<=32?{variants,body}:null;
  };
  const leaf=(body,base)=>{
    const l=lines(body);if(l[0]!=='#EXTM3U'||!address(base)||!l.includes('#EXT-X-ENDLIST')||
      l.some(v=>/^#EXT-X-(?:STREAM-INF|SESSION-KEY|DEFINE):/.test(v)))return null;
    const resources=[];let duration=0,segments=0;
    for(const v of l){
      if(v.startsWith('#EXT-X-KEY:')){const a=attrs(v);if(!a||!['NONE','AES-128'].includes(a.METHOD)||a.KEYFORMAT&&a.KEYFORMAT!=='identity')return null;
        if(a.METHOD==='AES-128'){const key=target(base,a.URI);if(!key)return null;resources.push(key);}}
      if(v.startsWith('#EXT-X-MAP:')){const a=attrs(v),init=a&&target(base,a.URI);if(!init)return null;resources.push(init);}
      if(v.startsWith('#EXTINF:')){const m=/^#EXTINF:([0-9]+(?:\.[0-9]+)?),/.exec(v);if(!m||+m[1]<=0)return null;duration+=+m[1];segments++;}
    }
    return segments>0&&segments<=20000&&duration>0&&duration<=172800?{duration,resources:[...new Set(resources)]}:null;
  };
  const records=(meta,graph,leaves,requests,document)=>{
    if(!meta||meta.id!==page(document)||!graph||!Array.isArray(requests))return [];
    const observed=new Set(requests.filter(r=>r.kind==='hls'&&Number.isFinite(r.at)&&Date.now()-r.at>=0&&Date.now()-r.at<=1800000).map(r=>r.url));
    if(!observed.has(meta.root))return [];
    const variants=graph.variants.flatMap(v=>{
      const video=leaves.get(v.video),audio=leaves.get(v.audio);
      return observed.has(v.video)&&observed.has(v.audio)&&video&&audio&&Math.abs(video.duration-audio.duration)<=.5?
        [{...v,duration:video.duration,audio_duration:audio.duration,resources:[...new Set([...video.resources,...audio.resources])]}]:[];
    });
    if(!variants.length)return [];
    const record={id:meta.id,root:meta.root,master_playlist:graph.body,variants};return [{...record,revision:revision(JSON.stringify(record))}];
  };
  const visible=video=>{
    const r=video.getBoundingClientRect?.();if(r&&(!r.width||!r.height||r.bottom<=0||r.right<=0||r.top>=innerHeight||r.left>=innerWidth))return false;
    if(typeof getComputedStyle==='function')for(let node=video,depth=0;node&&depth<16;node=node.parentElement,depth++){
      const s=getComputedStyle(node);if(s&&(s.display==='none'||s.visibility==='hidden'||s.opacity==='0'))return false;
    }
    return true;
  };
  const owner=(data,document,live)=>{
    const id=page(document),current=Array.isArray(data)?data.filter(d=>d.id===id):[];
    if(!id||current.length!==1||!Array.isArray(live))return null;
    const candidates=live.filter(v=>v.isConnected&&!v.mediaKeys&&v.readyState>=2&&(v.currentSrc||'').startsWith('blob:https://www.nicovideo.jp/')&&
      Number.isFinite(v.duration)&&v.duration>0&&visible(v)&&current[0].variants.some(t=>t.width===v.videoWidth&&t.height===v.videoHeight&&Math.abs(t.duration-v.duration)<=.5));
    if(candidates.length!==1)return null;
    const main=candidates[0],r=main.getBoundingClientRect?.();
    const ad=live.some(v=>{
      if(v===main||!v.isConnected||!(v.readyState>=2&&v.videoWidth>0&&v.videoHeight>0)||!visible(v))return false;
      const b=v.getBoundingClientRect?.();return !r||!b||Math.min(r.right,b.right)>Math.max(r.left,b.left)&&Math.min(r.bottom,b.bottom)>Math.max(r.top,b.top);
    });
    return ad?null:main;
  };
  const binding=(video,data,requests,document,live)=>{
    if(owner(data,document,live)!==video)return null;
    const record=data.find(d=>d.id===page(document)),observed=new Set(requests.filter(r=>r.kind==='hls').map(r=>r.url)),resources=new Set(requests.filter(r=>r.kind==='segment').map(r=>r.url));
    const choices=record.variants.filter(t=>t.width===video.videoWidth&&t.height===video.videoHeight&&Math.abs(t.duration-video.duration)<=.5&&observed.has(record.root)&&observed.has(t.video)&&observed.has(t.audio)&&t.resources.every(url=>resources.has(url)));
    const unique=choices.filter((t,i,a)=>a.findIndex(o=>o.video===t.video&&o.audio===t.audio)===i);if(unique.length!==1)return null;
    const track=unique[0];return {id:record.id,page:document,revision:record.revision,root:record.root,master_playlist:record.master_playlist,video:track.video,audio:track.audio,
      width:video.videoWidth,height:video.videoHeight,duration:video.duration,expected_duration:track.duration,audio_duration:track.audio_duration,
      resources:track.resources,vcodec:track.vcodec,acodec:track.acodec};
  };
  return {address,page,access,rights,attrs,master,leaf,records,owner,binding,revision};
})();
