/* Passive Douyin adapter: public video metadata plus this document's observed
 * requests. No API replay, page-world execution or account-storage access. */
const Thru3DDouyin = (() => {
  'use strict';
  // Firefox 135+ exposes the original numeric token to JSON revivers. Never
  // reconstruct a 64-bit content ID from an already-rounded JavaScript Number.
  const parse = text => JSON.parse(text,(key,value,context)=>
    key==='aweme_id'&&typeof value==='number'&&/^[1-9][0-9]{14,19}$/.test(context?.source||'') ? context.source : value);
  const page = value => {
    try {
      const u = new URL(value);
      if (u.protocol !== 'https:' || u.hostname !== 'www.douyin.com' || u.port || u.username || u.password) return null;
      const path = /^\/video\/([1-9][0-9]{14,19})\/?$/.exec(u.pathname)?.[1];
      const ids = u.searchParams.getAll('modal_id');
      if (ids.length > 1 || path && ids.length && ids[0] !== path) return null;
      const modal = ['/', '/recommend', '/discover', '/search/'].includes(u.pathname) && ids[0];
      const id = path || modal;
      return /^[1-9][0-9]{14,19}$/.test(id || '') ? {id} : null;
    } catch (_) { return null; }
  };
  const documentPage = value => {
    try { const u = new URL(value); return u.protocol === 'https:' && u.host === 'www.douyin.com' && !u.username && !u.password; }
    catch (_) { return false; }
  };
  const address = value => {
    try { const u = new URL(value); return typeof value === 'string' && value.length <= 8192 &&
      u.protocol === 'https:' && !u.username && !u.password && !u.hash ? value : null; }
    catch (_) { return null; }
  };
  const objectPath = u => /^(?:\/(?:[a-fA-F0-9]{32}|[a-fA-F0-9]{64})\/[a-fA-F0-9]{8,16})?(\/video\/tos\/cn\/tos-cn-[a-zA-Z0-9-]{1,96}\/[A-Za-z0-9_-]{8,240}(?:\/[A-Za-z0-9_-]{8,240})?\/?)$/.exec(u.pathname)?.[1];
  const sourceId = value => {
    if(!address(value))return null;
    try {
      const ids=new URL(value).search.slice(1).split('&').filter(Boolean).map(p=>{
        const n=p.indexOf('='),decode=s=>decodeURIComponent(s.replace(/\+/g,' '));
        return [decode(n<0?p:p.slice(0,n)),decode(n<0?'':p.slice(n+1))];
      }).filter(p=>p[0]==='__vid');
      return ids.length===1&&/^[1-9][0-9]{14,19}$/.test(ids[0][1])?ids[0][1]:null;
    }catch(_){return null;}
  };
  // Compare declared media identity with the actual observed request. Replay its
  // address and its own headers verbatim; never rewrite a signature or use a backup.
  const matches = (declared, observed, contentId = '') => {
    if (!address(declared) || !address(observed)) return false;
    if (declared === observed) return true;
    try {
      const a = new URL(declared), b = new URL(observed);
      // C-type CDN authentication prefixes rotate independently of the object.
      // Compare the exact TOS bucket/object suffix, then replay the observed URL
      // untouched. This is not a signature generator or URL-renewal mechanism.
      // Gecko's isolated content world does not expose iterable URLSearchParams.
      // Compare decoded entries (including duplicate counts), without rewriting
      // the observed URL that native playback must send verbatim.
      const query = u => u.search.slice(1).split('&').filter(Boolean).map(p => {
        const n=p.indexOf('='),decode=s=>decodeURIComponent(s.replace(/\+/g,' '));
        return [decode(n<0?p:p.slice(0,n)),decode(n<0?'':p.slice(n+1))];
      });
      let original=query(a);const keys=new Set(original.map(p=>p[0]));
      // A new detail response rotates request tracing fields for the very same
      // signed file. Only the site's currentSrc __vid binding permits that case;
      // path/object, all other parameters and duplicate counts still agree.
      const ids=query(b).filter(p=>p[0]==='__vid');
      const bound=/^[1-9][0-9]{14,19}$/.test(contentId)&&ids.length===1&&ids[0][1]===contentId;
      const assetBound=/^[1-9][0-9]{14,19}$/.test(contentId)&&(!ids.length||bound)&&
        !!objectPath(a)&&objectPath(a)===objectPath(b);
      // The actual player appends browser context fields to its declared file.
      // Only additions on an already bound TOS object qualify; existing values,
      // authentication/signature parameters and every other query still agree.
      const appended=assetBound?['webid','fid']:[];
      if(appended.some(key=>!keys.has(key)&&query(b).filter(p=>p[0]===key).length>1))return false;
      const received=query(b).filter(([key])=>keys.has(key)||!['temp','__vid','testst',...appended].includes(key));
      const ignored=assetBound?['cquery','l','dy_q','btag']:bound?['cquery','l']:[];
      const stable=list=>list.filter(p=>!ignored.includes(p[0]));
      const ordered = list => list.map(p=>JSON.stringify(p)).sort();
      // A related CDN may serve the same site-declared object. Its hostname is
      // not a gate; retain the exact object or bound content ID plus query checks.
      return (a.origin===b.origin||assetBound||bound) && (a.pathname===b.pathname||assetBound) && JSON.stringify(ordered(stable(original)))===JSON.stringify(ordered(stable(received)));
    } catch (_) { return false; }
  };
  const normalize = raw => {
    const v = raw?.video, id = raw?.aweme_id;
    if (typeof id !== 'string' || !/^[1-9][0-9]{14,19}$/.test(id) || !v || raw.is_ads || raw.images?.length ||
        raw.is_live || raw.is_preview || v.has_drm || v.is_drm || v.drm_type || v.is_encrypted) return null;
    const duration = Number(v.duration) / 1000;
    if (!Number.isFinite(duration) || duration <= 0 || duration > 86400) return null;
    const tracks = [v.play_addr, ...(Array.isArray(v.bit_rate) ? v.bit_rate.slice(0,32).map(t => t?.play_addr) : [])]
      .filter(t => Number.isInteger(t?.width) && Number.isInteger(t?.height) && t.width > 0 && t.height > 0 && t.width <= 8192 && t.height <= 8192)
      .map(t => ({width:t.width,height:t.height,urls:(Array.isArray(t.url_list) ? t.url_list.slice(0,8) : []).filter(address)}))
      .filter(t => t.urls.length);
    // Only the video's own declared encoded audio, never the unrelated music URL.
    const audio = (Array.isArray(v.bit_rate_audio) ? v.bit_rate_audio.slice(0,8) : []).map(a=>a?.audio_meta).filter(Boolean)
      .map(a=>({id:typeof a.file_id==='string'&&/^[A-Za-z0-9_-]{1,160}$/.test(a.file_id)?a.file_id:'',
        urls:[...new Set(['main_url','backup_url','fallback_url'].map(k=>a.url_list?.[k]).filter(address))]})).filter(a=>a.urls.length);
    const result = {id,duration,video:tracks,...(audio.length?{audio}:{})};
    return tracks.length && JSON.stringify(result).length <= 96*1024 ? result : null;
  };
  const proof = (data, video, source, sound = '') => {
    const track = data.video.find(t => t.width === video.videoWidth && t.height === video.videoHeight && t.urls.some(u => matches(u,source,data.id)));
    if (!track) return null;
    const audio = sound ? (data.audio||[]).map(t=>({...t,urls:t.urls.filter(u=>matches(u,sound,data.id))})).filter(t=>t.urls.length) : data.audio;
    return {id:data.id,duration:data.duration,
      video:[{width:track.width,height:track.height,urls:track.urls.filter(u=>matches(u,source,data.id))}],
      ...(audio?.length?{audio}:{})};
  };
  const binding = (data, value, video, requests) => {
    const p = page(value);
    if (!p || !data || data.id !== p.id || video.mediaKeys || video.seeking || !(video.videoWidth > 0) || !(video.videoHeight > 0) ||
        !Number.isFinite(video.duration) || Math.abs(video.duration-data.duration) > Math.max(.5,data.duration*.01)) return null;
    if ((video.currentSrc || '').startsWith('blob:')) {
      const tracks = data.video.filter(t => t.width === video.videoWidth && t.height === video.videoHeight);
      const observed = requests.filter(r => r.kind === 'file' && tracks.some(t => t.urls.some(u => matches(u,r.url,data.id))));
      const unique = [...new Set(observed.map(r=>r.url))];
      const audio = [...new Set(requests.filter(r=>r.kind==='file'&&(data.audio||[]).some(t=>t.urls.some(u=>matches(u,r.url,data.id)))).map(r=>r.url))];
      // The caller nominates one decoded owner. MSE cannot identify an arbitrary
      // alternate request: require exactly one observed declared representation.
      // MSE can demux one full MP4 into both SourceBuffers. The native reader
      // still has to prove that this exact file contains real video and audio.
      const muxed = unique.length === 1 && audio.length === 1 && audio[0] === unique[0];
      const selected = unique.length === 1 && audio.length <= 1 ? proof(data,video,unique[0],audio[0]) : null;
      return selected ? {data:{...selected,observed_file:unique[0],...(muxed?{observed_muxed:true}:audio.length?{observed_audio:audio[0]}:{})},request:observed[0]} : null;
    }
    const track = data.video.find(t => t.width === video.videoWidth && t.height === video.videoHeight && t.urls.some(u => matches(u,video.currentSrc,data.id)));
    if (!track) return null;
    const request = requests.find(r => r.kind === 'file' && r.url === video.currentSrc && track.urls.some(u=>matches(u,r.url,data.id)));
    const selected = request ? proof(data,video,request.url) : null;
    return selected ? {data:selected,request} : null;
  };
  const owner = (list, value, videos) => {
    const p = page(value); if (!p) return null;
    const matching = videos.filter(v => !v.mediaKeys && !v.seeking && v.videoWidth > 0 && v.videoHeight > 0 &&
      Number.isFinite(v.duration) && list.some(d => d.id === p.id && Math.abs(d.duration-v.duration) <= Math.max(.5,d.duration*.01) &&
        d.video.some(t => t.width === v.videoWidth && t.height === v.videoHeight)));
    return matching.length === 1 ? matching[0] : null;
  };
  const merge = (old,data,observed=[]) => {
    if(!old||old.id!==data.id||old.duration!==data.duration)return data;
    const recent=values=>{const urls=new Set();for(const value of values){urls.delete(value);urls.add(value);}return [...urls].slice(-8);};
    const playing=urls=>urls.filter(u=>observed.some(value=>matches(u,value,data.id)));
    const video=data.video.map((t,i)=>{
      const previous=old.video.filter(o=>o.width===t.width&&o.height===t.height).flatMap(o=>o.urls);
      const counterpart=old.video[i];
      return {...t,urls:recent([...previous,...(counterpart?.width===t.width&&counterpart?.height===t.height?counterpart.urls:[]),...t.urls,...playing(previous)])};
    });
    const previousAudio=(old.audio||[]).flatMap(o=>o.urls);
    const audio=data.audio?.map((t,i)=>({...t,urls:recent([...(old.audio||[]).filter(o=>t.id&&o.id===t.id).flatMap(o=>o.urls),
      ...((old.audio||[])[i]?.urls||[]),...t.urls,...playing(previousAudio)])}));
    const result={...data,video,...(audio?{audio}:{})};return JSON.stringify(result).length<=96*1024?result:data;
  };
  // Direct progressive playback already has a site-supplied content identity in
  // currentSrc. It needs no API replay or guessed audio. Native container probing
  // must still prove a whole file with both tracks before publishing playback.
  const direct = (list,value,video,requests,observation={}) => {
    const p=page(value),duration=video.duration;
    if(!p||sourceId(video.currentSrc)!==p.id||video.mediaKeys||video.seeking||
      !Number.isInteger(video.videoWidth)||!Number.isInteger(video.videoHeight)||
      video.videoWidth<1||video.videoHeight<1||video.videoWidth>8192||video.videoHeight>8192||
      !Number.isFinite(duration)||duration<=0||duration>86400)return null;
    if(observation.id_matches===1&&(observation.ads||observation.images||observation.encrypted))return null;
    if(list.some(d=>d.id===p.id&&Math.abs(d.duration-duration)>Math.max(.5,d.duration*.01)))return null;
    const request=requests.find(r=>r.kind==='file'&&r.url===video.currentSrc);if(!request)return null;
    return {data:{id:p.id,duration,observed_direct:true,video:[{width:video.videoWidth,height:video.videoHeight,urls:[video.currentSrc]}]},request};
  };
  const diagnostics = (list,value,video,requests) => {
    const p=page(value),data=list.filter(d=>d.id===p?.id);
    const tracks=data.flatMap(d=>d.video.map(t=>({d,t})));
    const files=requests.filter(r=>r.kind==='file');
    return {metadata_count:list.length,page_metadata:data.length,metadata_chars:Math.max(0,...data.map(d=>JSON.stringify(d).length)),source_id_matches:p&&sourceId(video.currentSrc)===p.id?1:0,
      dimension_matches:tracks.filter(({t})=>t.width===video.videoWidth&&t.height===video.videoHeight).length,
      duration_matches:data.filter(d=>Number.isFinite(video.duration)&&Math.abs(video.duration-d.duration)<=Math.max(.5,d.duration*.01)).length,
      address_matches:tracks.filter(({d,t})=>t.urls.some(u=>matches(u,video.currentSrc,d.id))).length,
      observed_source:files.filter(r=>r.url===video.currentSrc).length,
      request_files:files.length,
      video_request_matches:files.filter(r=>tracks.some(({d,t})=>t.urls.some(u=>matches(u,r.url,d.id)))).length,
      decoded_request_matches:files.filter(r=>tracks.some(({d,t})=>t.width===video.videoWidth&&t.height===video.videoHeight&&t.urls.some(u=>matches(u,r.url,d.id)))).length,
      audio_request_matches:files.filter(r=>data.some(d=>(d.audio||[]).some(t=>t.urls.some(u=>matches(u,r.url,d.id))))).length,
      audio_video_overlap:files.filter(r=>tracks.some(({d,t})=>t.width===video.videoWidth&&t.height===video.videoHeight&&t.urls.some(u=>matches(u,r.url,d.id)))&&
        data.some(d=>(d.audio||[]).some(t=>t.urls.some(u=>matches(u,r.url,d.id))))).length,
      object_request_matches:files.filter(r=>{try{const key=objectPath(new URL(r.url));return !!key&&tracks.some(({t})=>t.urls.some(u=>objectPath(new URL(u))===key));}catch(_){return false;}}).length,
      request_id_matches:files.filter(r=>p&&sourceId(r.url)===p.id).length};
  };
  return {parse,page,documentPage,address,matches,sourceId,normalize,binding,owner,merge,direct,diagnostics};
})();
