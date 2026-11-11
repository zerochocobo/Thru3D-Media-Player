/* Website-selected SDK data. Private URLs remain inside the trusted handoff bridge. */
const Thru3DIqiyi = (() => {
  'use strict';
  const own=(o,k)=>o&&typeof o==='object'?Object.getOwnPropertyDescriptor(o,k)?.value:undefined;
  const id=v=>typeof v==='string'&&/^[A-Za-z0-9]{1,64}$/.test(v)?v:typeof v==='number'&&Number.isSafeInteger(v)&&v>=0?String(v):null;
  let cachedDeclaration=null;
  const page=value=>{try{const u=new URL(value);const id=/^\/([vw]_[A-Za-z0-9]+)\.html$/.exec(u.pathname)?.[1];return u.origin==='https://www.iqiyi.com'&&!u.username&&!u.password&&!u.hash&&id?{id}:null;}catch(_){return null;}};
  const entryPage=typeof location==='undefined'?null:page(location.href)?.id;
  const documents=new WeakMap();
  const containerShape=(ff,playlist)=>{
    const format=['ts','265ts','f4v','m4s','mp4'].includes(ff)?ff:ff==null?'missing':'other';
    const prefix=typeof playlist==='string'?playlist.slice(0,64).trimStart():'';
    const declaration=typeof playlist!=='string'?'missing':!playlist.length?'empty':
      prefix.startsWith('#EXTM3U')?'hls':prefix.startsWith('{')?'json_object':prefix.startsWith('[')?'json_array':
      /^https?:\/\//i.test(prefix)?'url':'other';
    return {container:format,declaration};
  };
  const revision=text=>{let h=2166136261;for(let i=0;i<text.length;i++)h=Math.imul(h^text.charCodeAt(i),16777619);return(h>>>0).toString(16);};
  const playlistLimit=512*1024,wireLimit=128*1024;
  // Consecutive HLS segment URLs normally differ only in their byte/time
  // selectors. Copy exact UTF-16 prefixes/suffixes from the line two before;
  // never parse, reorder or regenerate signed query parameters here.
  const playlistPayload=text=>{
    if(text.length<=wireLimit)return {playlist:text};
    const lines=text.split('\n');if(lines.length>8192)return null;
    const rows=lines.map((line,i)=>{
      const previous=i>=2?lines[i-2]:'';let prefix=0,suffix=0;
      while(prefix<Math.min(line.length,previous.length)&&line[prefix]===previous[prefix])prefix++;
      while(suffix<Math.min(line.length,previous.length)-prefix&&line[line.length-1-suffix]===previous[previous.length-1-suffix])suffix++;
      return [prefix,suffix,line.slice(prefix,line.length-suffix)];
    });
    // GeckoView's native port rejects nested and mixed-type JS arrays.
    const result={playlist_delta:{version:2,chars:text.length,rows:JSON.stringify(rows)}};
    return JSON.stringify(result).length<=wireLimit?result:null;
  };
  const transport=data=>{
    if(!data?.ready||cachedDeclaration?.text!==data.playlist)return null;
    const {playlist,playlist_end_ms,...rest}=data;return {...rest,...cachedDeclaration.payload};
  };
  const fitMediaReport=report=>{
    const selected=report.videos.find(item=>item.iqiyi_ready);
    if(!selected?.network.length)return report;
    // Android bounds the entire report, including repeated headers and cookies.
    // Leave room for its JSON escaping and keep the full SDK timeline intact.
    const budget=240*1024;
    const size=value=>JSON.stringify(value).replace(/\//g,'\\/').length;
    if(size(report)<=budget)return report;
    const requests=selected.network;
    selected.network=[];
    let remaining=budget-size(report);
    for(let i=requests.length-1;i>=0&&remaining>0;i--){
      const length=size(requests[i])+(selected.network.length?1:0);
      if(length>remaining)continue;
      selected.network.unshift(requests[i]);
      remaining-=length;
    }
    return report;
  };
  const capture=(view,address,dom)=>{
    const fail=(status,shape)=>({ready:false,status,...shape});
    try{
      const pageId=page(address)?.id;
      if(!pageId)return fail('unsupported_page');
      let owner=documents.get(dom);
      if(!owner){owner={entry:entryPage||pageId,page:entryPage||pageId,entryTvid:null,bound:null,previous:null};documents.set(dom,owner);}
      if(owner.page!==pageId){
        owner.previous=owner.bound?.page===owner.page?owner.bound:null;
        owner.page=pageId;
      }
      const initial=own(view,'QiyiPlayerProphetData'),data=own(own(initial,'dashData'),'data'),program=own(data,'program'),
        playback=own(view,'playback'),active=own(playback,'playingPlayback'),info=own(active,'_info'),element=own(playback,'_element');
      if(own(info,'type')!=='Movie')return fail('not_main');
      const tvid=id(own(info,'id'));
      if(!tvid)return fail('wrong_item');
      const initialMatches=tvid===id(own(initial,'tvId')??own(initial,'tvid'))&&tvid===id(own(data,'tvid'));
      const direct=pageId===owner.entry&&initialMatches&&(!owner.entryTvid||owner.entryTvid===tvid);
      const retained=owner.bound?.page===pageId&&owner.bound.tvid===tvid;
      const previous=owner.previous;
      // An episode address can change before the site replaces the old Movie.
      // Only follow one observed transition from a previously bound programme.
      const switched=!direct&&!retained&&previous&&previous.tvid!==tvid;
      if(!direct&&!retained&&!switched)return fail('wrong_item');
      const vid=id(own(info,'vid')),bid=own(info,'_bid');
      if(!vid||!Number.isInteger(bid)||bid<0)return fail('wrong_track');
      // Quality fallback updates the current Movie's videoList while the initial
      // API retains its old _selected flag and incomplete lower-quality rows.
      const movie=own(active,'_mvInfo'),currentList=own(movie,'videoList');
      const list=id(own(movie,'tvid'))===tvid&&currentList!==undefined?currentList:direct?own(program,'video'):null;
      if(!Array.isArray(list)||list.length<1||list.length>24)return fail('ambiguous_track');
      const selected=[];for(let i=0;i<list.length;i++){const t=own(list,String(i));if(id(own(t,'vid'))===vid&&own(t,'bid')===bid)selected.push(t);}
      if(selected.length!==1)return fail('wrong_track');const track=selected[0];
      const videos=[...dom.querySelectorAll('video.inner-video')].filter(v=>v===element||v.wrappedJSObject===element);
      if(videos.length!==1)return fail('wrong_element');const video=videos[0];
      if(!video.isConnected||video.mediaKeys||video.readyState<2||video.seeking)return fail('not_decoded');
      if(switched&&(!video.currentSrc||video===previous.video&&video.currentSrc===previous.src))return fail('wrong_item');
      const width=video.videoWidth,height=video.videoHeight,duration=video.duration;
      if(!Number.isInteger(width)||!Number.isInteger(height)||width<1||height<1||width>16384||height>16384||!Number.isFinite(duration)||duration<=0||duration>172800)return fail('invalid_video');
      const sdkDuration=own(info,'duration'),declaredDuration=own(track,'duration');
      if(own(track,'scrsz')!==width+'x'+height||!Number.isFinite(sdkDuration)||!Number.isFinite(declaredDuration)||Math.abs(sdkDuration/1000-duration)>2||Math.abs(declaredDuration-duration)>2)return fail('wrong_dimensions_or_duration');
      const playlist=own(track,'m3u8'),ff=own(track,'ff');
      const drm=own(track,'drmType');
      const drmType=Number.isInteger(drm)&&drm>=0&&drm<=32?drm:'unknown';
      const trackDrm=!!own(track,'drm'),rootDrm=!!own(initialMatches?data:movie,'drm');
      if(!['ts','265ts'].includes(ff))return fail('unsupported_container',{
        ...containerShape(ff,playlist),drm_type:drmType,has_drm:trackDrm,has_root_drm:rootDrm,
        has_segment_list:Array.isArray(own(track,'fs'))
      });
      if(typeof playlist!=='string')return fail('missing_playlist');
      if(playlist.length>playlistLimit)return fail('oversize_playlist');
      if(!playlist.trim().startsWith('#EXTM3U'))return fail('non_hls_playlist');
      if(/#EXT-X-(?:SESSION-)?KEY:/i.test(playlist))return fail('protected_manifest');
      if(!cachedDeclaration||cachedDeclaration.text!==playlist||cachedDeclaration.page!==address){
        const payload=playlistPayload(playlist);if(!payload)return fail('oversize_playlist');
        const lines=playlist.split(/\r?\n/).map(v=>v.trim()).filter(Boolean);
        const refs=lines.filter(v=>!v.startsWith('#')).map(v=>new URL(v,address));
        const durations=[...playlist.matchAll(/^\s*#EXTINF:([0-9.]+)/gm)].map(m=>Number(m[1]));
        const seconds=durations.reduce((sum,duration)=>sum+duration,0);
        const tail=refs.at(-1)?.searchParams.getAll('sd');
        const tailDuration=durations.at(-1)*1000;
        const endMs=lines.at(-1)==='#EXT-X-ENDLIST'&&refs.length===durations.length&&
          tail?.length===1&&/^\d{1,15}$/.test(tail[0])&&Number.isSafeInteger(tailDuration)&&tailDuration>0?
          Number(tail[0])+tailDuration:null;
        cachedDeclaration={page:address,text:playlist,refs,seconds,endMs,revision:revision(playlist),payload,payloadChars:JSON.stringify(payload).length};
      }
      const next=own(view,'__lastAccJson');
      // The website has already parsed ms/mk into per-fragment dispatch URLs.
      // Read its selected level's data; never invoke getters or rebuild signatures.
      let dispatchers=[],dispatchStatus='unavailable',dispatchDuration=null;
      const levels=own(movie,'levelInfoArr');
      if(id(own(movie,'tvid'))===tvid&&Array.isArray(levels)&&levels.length<=24){
        const matching=[];for(let i=0;i<levels.length;i++){const level=own(levels,String(i));if(id(own(level,'vid'))===vid&&own(level,'bid')===bid)matching.push(level);}
        if(matching.length===1){
          const milliseconds=own(matching[0],'duration');
          if(Number.isFinite(milliseconds)&&milliseconds>0&&milliseconds<=172800000)dispatchDuration=milliseconds;
          const fragments=own(matching[0],'fragmentList');
          if(Array.isArray(fragments)&&fragments.length>0&&fragments.length<=2048){
            const declared=cachedDeclaration.refs;
            const rows=[];let chars=cachedDeclaration.payloadChars+4096;
            for(let i=0;i<fragments.length;i++){
              const f=own(fragments,String(i)),raw=own(f,'dispatchUrl'),source=own(f,'sourceID'),start=own(f,'sPos'),end=own(f,'ePos');
              if(typeof raw!=='string'||raw.length>16384||typeof source!=='string'||!/^[A-Za-z0-9_-]{1,160}$/.test(source)||!Number.isSafeInteger(start)||!Number.isSafeInteger(end)||start<0||end<=start)break;
              const uri=new URL(raw,address);
              if(!/^https?:$/.test(uri.protocol)||uri.username||uri.password||uri.hash||!declared.some(v=>v.pathname===uri.pathname&&v.pathname.split('/').pop()===source+'.'+ff))break;
              chars+=uri.href.length+source.length+128;if(chars>wireLimit)break;
              rows.push({url:uri.href,source_id:source,start,end});
            }
            if(rows.length===fragments.length){dispatchers=rows;dispatchStatus='selected_level';}
            else dispatchStatus='fragment_mismatch';
          }else dispatchStatus='no_fragments';
        }else dispatchStatus='no_unique_level';
      }
      const result={ready:true,status:'bound',id:pageId,revision:revision([address,video.currentSrc,tvid,vid,bid,width,height,cachedDeclaration.revision].join('|')),page:address,src:video.currentSrc,tvid,vid,bid,width,height,duration,ff,playlist,prefetch_tvid:id(own(next,'tvId')??own(next,'tvid')),
        drm_type:drmType,has_drm:trackDrm,has_root_drm:rootDrm,
        signing_data_present:!!own(track,'ms')||!!own(track,'mk'),dispatchers,dispatch_status:dispatchStatus,dispatch_duration_ms:dispatchDuration,
        sdk_duration_ms:sdkDuration,playlist_duration:cachedDeclaration.seconds,playlist_end_ms:cachedDeclaration.endMs,
        dispatch_shape:{movie_fields:movie&&typeof movie==='object'?Object.getOwnPropertyNames(movie).filter(k=>/^[A-Za-z_][A-Za-z0-9_]{0,63}$/.test(k)).slice(0,32):[],level_count:Array.isArray(levels)?levels.length:0},protection_unverified:true};
      if(JSON.stringify(transport(result)).length>132*1024)return fail('oversize_playlist');
      if(direct)owner.entryTvid=tvid;
      owner.bound={page:pageId,tvid,video,src:video.currentSrc};
      owner.previous=null;
      return result;
    }catch(_){return fail('read_error');}
  };
  const matches=(current,record)=>{
    if(!current?.ready||!['segment','file'].includes(record?.kind)||!Number.isFinite(record.at)||Date.now()-record.at<0||Date.now()-record.at>1800000)return false;
    try{
      const uri=new URL(record.url);if(!/^https?:$/.test(uri.protocol)||uri.username||uri.password||uri.hash)return false;
      const ids=uri.search.slice(1).split('&').filter(Boolean).map(v=>[decodeURIComponent(v.split('=',1)[0]),decodeURIComponent(v.slice(v.indexOf('=')+1))]).filter(v=>v[0]==='qd_tvid').map(v=>v[1]);
      if(ids.some(v=>v!==current.tvid))return false;
      return current.playlist.split(/\r?\n/).map(v=>v.trim()).filter(v=>v&&!v.startsWith('#')).some(v=>new URL(v,current.page).pathname===uri.pathname);
    }catch(_){return false;}
  };
  const timelineMatches=data=>Number.isFinite(data.dispatch_duration_ms)&&(
    Math.abs(data.dispatch_duration_ms/1000-data.duration)<=.5||
    // MSE can round an integral SDK total up by one second. Rounded EXTINF
    // totals may fall short by two seconds even with an exact final anchor.
    Number.isInteger(data.duration)&&data.sdk_duration_ms===data.dispatch_duration_ms&&(
      data.duration===Math.ceil(data.dispatch_duration_ms/1000)&&data.playlist_duration===data.duration||
      data.duration===Math.floor(data.dispatch_duration_ms/1000)+1&&data.playlist_end_ms===data.dispatch_duration_ms&&
      [data.duration,data.duration-1,data.duration-2].includes(data.playlist_duration)));
  const binding=(video,data)=>data?.ready&&data.src===video.currentSrc&&data.width===video.videoWidth&&data.height===video.videoHeight&&
    Math.abs(data.duration-video.duration)<.01&&!video.mediaKeys&&!video.seeking&&data.drm_type===1&&!data.has_drm&&
    data.dispatch_status==='selected_level'&&data.dispatchers.length>0&&timelineMatches(data)?data:null;
  // Capture remains read-only. Only an explicit retained-page return invokes the
  // website's existing playback controls; unbuffered MSE seeks need its loader.
  const restore=(view,video,data,time,play)=>{
    try{
      if(!binding(video,data)||!Number.isFinite(time)||time<0||time>data.duration)return false;
      const playback=own(view,'playback');
      const current=()=>{
        const info=own(own(playback,'playingPlayback'),'_info'),element=own(playback,'_element');
        return!!element&&video.isConnected&&(element===video||element===video.wrappedJSObject)&&own(info,'type')==='Movie'&&id(own(info,'id'))===data.tvid&&
          id(own(info,'vid'))===data.vid&&own(info,'_bid')===data.bid&&video.currentSrc===data.src&&!video.mediaKeys;
      };
      const method=name=>{for(let value=playback,depth=0;value&&depth<2;value=Object.getPrototypeOf(value),depth++){
        const d=Object.getOwnPropertyDescriptor(value,name);if(d)return typeof d.value==='function'?d.value:null;
      }return null;};
      const pause=method('pause'),seek=method('seek'),start=play===true?method('play'):null;
      if(!current()||!pause||!seek||play===true&&!start)return false;
      Reflect.apply(pause,playback,[]);if(!current())return false;
      // This exposed playback facade uses milliseconds. false retains the exact
      // requested time instead of snapping it back to the loader's keyframe.
      if(Reflect.apply(seek,playback,[time*1000,false])===-1)return false;
      Reflect.apply(play===true?start:pause,playback,[]);
      return true;
    }catch(_){return false;}
  };
  const diagnostics=(video,data)=>({
    status:data?.status||'missing',capture_ready:data?.ready===true,binding_ready:!!binding(video,data),
    ...(data?.status==='unsupported_container'?{container:data.container,declaration:data.declaration,
      drm_type:Number.isInteger(data.drm_type)?data.drm_type:-1,track_drm:!!data.has_drm,root_drm:!!data.has_root_drm,
      has_segment_list:data.has_segment_list===true}:{}),
    ...(data?.ready?{source_matches:data.src===video.currentSrc,dimensions_match:data.width===video.videoWidth&&data.height===video.videoHeight,
      duration_matches:Math.abs(data.duration-video.duration)<.01,drm_type:Number.isInteger(data.drm_type)?data.drm_type:-1,
      track_drm:!!data.has_drm,root_drm:!!data.has_root_drm,dispatch_ready:data.dispatch_status==='selected_level'&&data.dispatchers.length>0,
      dispatcher_count:data.dispatchers.length,timeline_matches:timelineMatches(data)}:{})
  });
  return {page,capture,matches,binding,restore,diagnostics,transport,fitMediaReport};
})();
