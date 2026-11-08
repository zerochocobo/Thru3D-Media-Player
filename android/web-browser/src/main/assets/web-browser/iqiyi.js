/* Website-selected SDK data. Private URLs remain inside the trusted handoff bridge. */
const Thru3DIqiyi = (() => {
  'use strict';
  const own=(o,k)=>o&&typeof o==='object'?Object.getOwnPropertyDescriptor(o,k)?.value:undefined;
  const id=v=>typeof v==='string'&&/^[A-Za-z0-9]{1,64}$/.test(v)?v:typeof v==='number'&&Number.isSafeInteger(v)&&v>=0?String(v):null;
  let cachedDeclaration=null;
  const page=value=>{try{const u=new URL(value);const id=/^\/([vw]_[A-Za-z0-9]+)\.html$/.exec(u.pathname)?.[1];return u.origin==='https://www.iqiyi.com'&&!u.username&&!u.password&&!u.hash&&id?{id}:null;}catch(_){return null;}};
  const revision=text=>{let h=2166136261;for(let i=0;i<text.length;i++)h=Math.imul(h^text.charCodeAt(i),16777619);return(h>>>0).toString(16);};
  const capture=(view,page,dom)=>{
    const fail=status=>({ready:false,status});
    try{
      const url=new URL(page);
      if(url.origin!=='https://www.iqiyi.com'||url.username||url.password||!/^\/[vw]_[A-Za-z0-9]+\.html$/.test(url.pathname))return fail('unsupported_page');
      const initial=own(view,'QiyiPlayerProphetData'),data=own(own(initial,'dashData'),'data'),program=own(data,'program'),
        playback=own(view,'playback'),active=own(playback,'playingPlayback'),info=own(active,'_info'),element=own(playback,'_element');
      if(own(info,'type')!=='Movie')return fail('not_main');
      const tvid=id(own(initial,'tvId')??own(initial,'tvid'));
      if(!tvid||tvid!==id(own(info,'id'))||tvid!==id(own(data,'tvid')))return fail('wrong_item');
      const vid=id(own(info,'vid')),bid=own(info,'_bid');
      if(!vid||!Number.isInteger(bid)||bid<0)return fail('wrong_track');
      // Quality fallback updates the current Movie's videoList while the initial
      // API retains its old _selected flag and incomplete lower-quality rows.
      const movie=own(active,'_mvInfo'),currentList=own(movie,'videoList');
      const list=id(own(movie,'tvid'))===tvid&&currentList!==undefined?currentList:own(program,'video');
      if(!Array.isArray(list)||list.length<1||list.length>24)return fail('ambiguous_track');
      const selected=[];for(let i=0;i<list.length;i++){const t=own(list,String(i));if(id(own(t,'vid'))===vid&&own(t,'bid')===bid)selected.push(t);}
      if(selected.length!==1)return fail('wrong_track');const track=selected[0];
      const videos=[...dom.querySelectorAll('video.inner-video')].filter(v=>v===element||v.wrappedJSObject===element);
      if(videos.length!==1)return fail('wrong_element');const video=videos[0];
      if(!video.isConnected||video.mediaKeys||video.readyState<2||video.seeking)return fail('not_decoded');
      const width=video.videoWidth,height=video.videoHeight,duration=video.duration;
      if(!Number.isInteger(width)||!Number.isInteger(height)||width<1||height<1||width>16384||height>16384||!Number.isFinite(duration)||duration<=0||duration>172800)return fail('invalid_video');
      const sdkDuration=own(info,'duration'),declaredDuration=own(track,'duration');
      if(own(track,'scrsz')!==width+'x'+height||!Number.isFinite(sdkDuration)||!Number.isFinite(declaredDuration)||Math.abs(sdkDuration/1000-duration)>2||Math.abs(declaredDuration-duration)>2)return fail('wrong_dimensions_or_duration');
      const playlist=own(track,'m3u8'),ff=own(track,'ff');
      if(!['ts','265ts'].includes(ff)||typeof playlist!=='string'||playlist.length>128*1024||!playlist.trim().startsWith('#EXTM3U'))return fail('unsupported_declaration');
      if(/#EXT-X-(?:SESSION-)?KEY:/i.test(playlist))return fail('protected_manifest');
      if(!cachedDeclaration||cachedDeclaration.text!==playlist||cachedDeclaration.page!==page){
        const refs=playlist.split(/\r?\n/).map(v=>v.trim()).filter(v=>v&&!v.startsWith('#')).map(v=>new URL(v,page));
        const seconds=[...playlist.matchAll(/^\s*#EXTINF:([0-9.]+)/gm)].reduce((sum,m)=>sum+Number(m[1]),0);
        cachedDeclaration={page,text:playlist,refs,seconds,revision:revision(playlist)};
      }
      const drm=own(track,'drmType');
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
            const rows=[];let chars=playlist.length+4096;
            for(let i=0;i<fragments.length;i++){
              const f=own(fragments,String(i)),raw=own(f,'dispatchUrl'),source=own(f,'sourceID'),start=own(f,'sPos'),end=own(f,'ePos');
              if(typeof raw!=='string'||raw.length>16384||typeof source!=='string'||!/^[A-Za-z0-9_-]{1,160}$/.test(source)||!Number.isSafeInteger(start)||!Number.isSafeInteger(end)||start<0||end<=start)break;
              const uri=new URL(raw,page);
              if(!/^https?:$/.test(uri.protocol)||uri.username||uri.password||uri.hash||!declared.some(v=>v.pathname===uri.pathname&&v.pathname.split('/').pop()===source+'.'+ff))break;
              chars+=uri.href.length+source.length+128;if(chars>128*1024)break;
              rows.push({url:uri.href,source_id:source,start,end});
            }
            if(rows.length===fragments.length){dispatchers=rows;dispatchStatus='selected_level';}
            else dispatchStatus='fragment_mismatch';
          }else dispatchStatus='no_fragments';
        }else dispatchStatus='no_unique_level';
      }
      return {ready:true,status:'bound',id:/\/([vw]_[A-Za-z0-9]+)\.html$/.exec(url.pathname)[1],revision:revision([page,video.currentSrc,tvid,vid,bid,width,height,cachedDeclaration.revision].join('|')),page,src:video.currentSrc,tvid,vid,bid,width,height,duration,ff,playlist,prefetch_tvid:id(own(next,'tvId')??own(next,'tvid')),
        drm_type:Number.isInteger(drm)&&drm>=0&&drm<=32?drm:'unknown',has_drm:!!own(track,'drm'),has_root_drm:!!own(data,'drm'),
        signing_data_present:!!own(track,'ms')||!!own(track,'mk'),dispatchers,dispatch_status:dispatchStatus,dispatch_duration_ms:dispatchDuration,
        sdk_duration_ms:sdkDuration,playlist_duration:cachedDeclaration.seconds,
        dispatch_shape:{movie_fields:movie&&typeof movie==='object'?Object.getOwnPropertyNames(movie).filter(k=>/^[A-Za-z_][A-Za-z0-9_]{0,63}$/.test(k)).slice(0,32):[],level_count:Array.isArray(levels)?levels.length:0},protection_unverified:true};
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
    // Android MSE can expose the complete integer HLS total, while the SDK
    // retains the exact final sd+EXTINF anchor. Require both declarations.
    Number.isInteger(data.duration)&&data.duration===Math.ceil(data.dispatch_duration_ms/1000)&&
    data.sdk_duration_ms===data.dispatch_duration_ms&&data.playlist_duration===data.duration);
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
  return {page,capture,matches,binding,restore};
})();
