/* Naver's received card/JSON-MPD and the current decoded MP4 or TS representation.
 * A navigation seed alone never identifies the currently rendered content. */
const Thru3DNaver=(()=>{
  'use strict';
  const {own,revision,presented}=Thru3DTikTok;
  const id=value=>typeof value==='string'&&/^[A-F0-9]{32,64}$/.test(value)?value:null;
  const address=value=>{try{const u=new URL(value);return typeof value==='string'&&value.length<=16384&&u.protocol==='https:'&&!u.username&&!u.password&&!value.includes('#')?u.href:null;}catch(_){return null;}};
  const documentPage=value=>{try{const u=new URL(value);return value.length<=8192&&u.protocol==='https:'&&!u.username&&!u.password&&!u.port&&u.hostname==='m.naver.com'&&u.pathname==='/shorts/';}catch(_){return false;}};
  const playbackPage=value=>{try{const u=new URL(value);return documentPage(value)&&u.searchParams.getAll('serviceType').length===1&&['NTV','CLIP'].includes(u.searchParams.get('serviceType'));}catch(_){return false;}};
  const page=(mediaId,service='NTV')=>id(mediaId)&&['NTV','CLIP'].includes(service)?'https://m.naver.com/shorts/?serviceType='+service+'&seedMediaId='+mediaId:null;
  const temporal=value=>{
    if(typeof value!=='string'||value.length>16384)return null;
    const marker=value.indexOf('#');if(marker<0){const source=address(value);return source?{source,start:null,end:null}:null;}
    const m=/^#t=(?:npt:)?([0-9]+(?:\.[0-9]+)?)(?:,([0-9]+(?:\.[0-9]+)?))?$/.exec(value.slice(marker));if(!m)return null;
    const start=Number(m[1]),end=m[2]===undefined?null:Number(m[2]),source=address(value.slice(0,marker));
    return source&&Number.isFinite(start)&&start>=0&&start<=86400&&(end===null||Number.isFinite(end)&&end>start&&end<=86400)?{source,start,end}:null;
  };
  const resource=value=>{
    const time=temporal(value);if(time)return {...time,kind:time.start===null?'plain':'temporal'};
    if(typeof value!=='string'||value.length>16384)return null;
    const marker=value.indexOf('#'),m=marker>=0&&/^#tid=([A-Za-z0-9_-]{22})$/.exec(value.slice(marker)),source=marker>=0&&address(value.slice(0,marker));
    return m&&source?{source,start:null,end:null,kind:'tracking'}:null;
  };
  const seconds=value=>{
    const m=typeof value==='string'&&/^PT(?:(\d+(?:\.\d+)?)H)?(?:(\d+(?:\.\d+)?)M)?(?:(\d+(?:\.\d+)?)S)?$/.exec(value);
    if(!m||!m.slice(1).some(Boolean))return null;const n=Number(m[1]||0)*3600+Number(m[2]||0)*60+Number(m[3]||0);
    return Number.isFinite(n)&&n>0&&n<=86400?n:null;
  };
  const integer=value=>typeof value==='string'&&/^[1-9][0-9]{0,4}$/.test(value)&&Number(value)<=16384?Number(value):null;
  const clearWholeFile=(data,segmented=false)=>{
    let budget=0;const visit=(o,depth)=>{
      if(depth>20||++budget>8192)return false;if(!o||typeof o!=='object')return true;
      const keys=Object.keys(o);if(keys.length>128)return false;
      return keys.every(k=>{
        const v=own(o,k),positive=v!==null&&v!==false&&v!==0&&v!==''&&v!=='false'&&v!=='0'&&!(Array.isArray(v)&&!v.length);
        if(positive&&(/ContentProtection|drm|encrypt/i.test(k)||!segmented&&/SegmentTemplate|SegmentList|SegmentBase/i.test(k)))return false;
        return visit(v,depth+1);
      });
    };return visit(data,0);
  };
  // The received JSON-MPD describes the TS timeline the renderer actually uses.
  // This is a derived playlist, never an observed or refetched HLS response.
  const segments=(plan,diagnostic=false)=>{
    const fail=reason=>diagnostic?{valid:false,reason}:null;
    try{
      if(!plan||!address(plan.base)||!new URL(plan.base).pathname.endsWith('/')||new URL(plan.base).search)return fail('base');
      if(typeof plan.media!=='string'||plan.media.length>16384||/[\r\n]/.test(plan.media))return fail('media');
      if(typeof plan.representation!=='string'||!/^[A-Za-z0-9_.-]{1,80}$/.test(plan.representation))return fail('representation');
      if(
        !Number.isSafeInteger(plan.start)||plan.start<0||plan.start>1000000||!Number.isSafeInteger(plan.timescale)||plan.timescale<1||plan.timescale>1000000||
        !Array.isArray(plan.rows)||plan.rows.length<1||plan.rows.length>256)return fail('bounds');
      const parameters=[...plan.media.matchAll(/\$([^$]+)\$/g)].map(m=>m[1]);
      const numberToken=p=>/^Number(?:%0([1-9][0-9]?)d)?$/.exec(p);
      if(!parameters.includes('RepresentationID')||!parameters.some(numberToken)||parameters.some(p=>p!=='RepresentationID'&&(!numberToken(p)||Number(numberToken(p)[1]||0)>10)))return fail('parameters');
      let end=0,number=plan.start,bytes=0,gapTicks=0,previousCount=0;const refs=[];
      for(const row of plan.rows){
        if(!Number.isSafeInteger(row.t)||!Number.isSafeInteger(row.d)||row.d<=0||
          !Number.isSafeInteger(row.r)||row.r<0||row.r>2047||refs.length+row.r+1>2048)return fail('timeline');
        const gap=row.t-end;
        if(gap<0||gap>previousCount||gap/plan.timescale>previousCount*.001||gap&&!refs.length)return fail('timeline');
        gapTicks+=gap;if(gapTicks/plan.timescale>.1)return fail('timeline');
        // Preserve every declared anchor. Repeated S entries can accumulate one
        // tick (at most 1ms) per preceding segment; never collapse that interval.
        if(gap)refs[refs.length-1].ticks+=gap;
        end=row.t;
        for(let repeat=0;repeat<=row.r;repeat++){
          const serial=number++;
          const text=plan.media.replace(/\$(RepresentationID|Number)(?:%0([1-9][0-9]?)d)?\$/g,(_,name,padding)=>name==='RepresentationID'?plan.representation:String(serial).padStart(Number(padding||0),'0'));
          if(text.includes('$'))return fail('substitution');
          const uri=address(new URL(text,plan.base).href);if(!uri||!new URL(uri).pathname.endsWith('.ts'))return fail('segment_uri');
          bytes+=uri.length+64;if(bytes>160*1024)return fail('playlist_budget');
          refs.push({url:uri,ticks:row.d});end+=row.d;
        }
        previousCount=row.r+1;
      }
      const duration=end/plan.timescale;if(duration<=0||duration>86400||new Set(refs.map(r=>r.url)).size!==refs.length)return fail('duration_or_duplicate');
      const timed=refs.map(r=>({url:r.url,duration:r.ticks/plan.timescale})),max=Math.max(...timed.map(r=>r.duration));
      const playlist='#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:'+Math.ceil(max)+'\n#EXT-X-MEDIA-SEQUENCE:'+plan.start+'\n#EXT-X-PLAYLIST-TYPE:VOD\n'+
        timed.map(r=>'#EXTINF:'+r.duration+',\n'+r.url+'\n').join('')+'#EXT-X-ENDLIST\n';
      return diagnostic?{valid:true,reason:'valid',count:refs.length,duration,gap_ticks:gapTicks}:{refs:timed,duration,playlist};
    }catch(_){return fail('parse_error');}
  };
  const clipRepresentations=(sets,mediaId,expected)=>{
    const result=[];
    for(const set of sets)for(const rep of own(set,'Representation')||[]){
      if(String(own(rep,'@mimeType')||own(set,'@mimeType')||'').toLowerCase()!=='video/mp2t')continue;
      const codec=own(rep,'@codecs')||own(set,'@codecs')||'';
      if(!/avc/i.test(codec)||!/mp4a/i.test(codec))continue;
      const templates=own(rep,'SegmentTemplate')||own(set,'SegmentTemplate'),bases=own(rep,'BaseURL')||own(set,'BaseURL');
      const width=integer(own(rep,'@width')),height=integer(own(rep,'@height')),source=address(own(rep,'@nvod:m3u'));
      if(!source||!width||!height||!Array.isArray(templates)||templates.length!==1||!Array.isArray(bases)||bases.length!==1)continue;
      const t=templates[0],tls=own(t,'SegmentTimeline');
      if(own(t,'@initialization')||own(t,'Initialization')||own(t,'@presentationTimeOffset')||!Array.isArray(tls)||tls.length!==1)continue;
      const rows=own(tls[0],'S');if(!Array.isArray(rows)||rows.length>256)continue;
      const numeric=(o,k,fallback)=>{const v=own(o,k);return v===undefined?fallback:typeof v==='string'&&/^(?:0|[1-9][0-9]*)$/.test(v)?Number(v):NaN;};
      const timeline={base:bases[0],media:own(t,'@media'),representation:own(rep,'@id'),start:numeric(t,'@startNumber',NaN),timescale:numeric(t,'@timescale',NaN),
        rows:rows.map(r=>({t:numeric(r,'@t',NaN),d:numeric(r,'@d',NaN),r:numeric(r,'@r',0)}))};
      const parsed=segments(timeline);if(!parsed||Math.abs(parsed.duration-expected)>.5)continue;
      result.push({id:mediaId,service_type:'CLIP',format:'segment_timeline',page:page(mediaId,'CLIP'),source,width,height,expected_duration:expected,
        timeline,binding:'received_card_mpd',protection_unverified:true});
    }
    return result;
  };
  const card=value=>{
    try{
      if(own(value,'cardType')!=='CONTENT')return [];
      const c=own(value,'content'),mediaId=id(own(c,'mediaId')),vod=own(c,'vod'),quality=own(c,'videoQuality');
      const service=own(c,'serviceType'),expected=own(quality,'duration');if(!mediaId||!['NTV','CLIP'].includes(service)||own(vod,'playable')!==true||
        !Number.isFinite(expected)||expected<=0||expected>86400)return [];
      const playback=own(vod,'playback'),list=own(playback,'MPD');if(!clearWholeFile(playback,service==='CLIP')||!Array.isArray(list)||list.length!==1)return [];
      const mpd=list[0],periods=own(mpd,'Period');
      if(own(mpd,'@nvod:videoId')!==mediaId||own(mpd,'@type')!=='static'||!Array.isArray(periods)||periods.length!==1)return [];
      const period=periods[0],duration=seconds(own(mpd,'@mediaPresentationDuration')),periodDuration=seconds(own(period,'@duration'));
      if(own(period,'@id')!==mediaId||!duration||!periodDuration||Math.abs(duration-expected)>.5||Math.abs(periodDuration-expected)>.5)return [];
      const sets=own(period,'AdaptationSet');if(!Array.isArray(sets)||sets.length<1||sets.length>4)return [];
      if(service==='CLIP')return clipRepresentations(sets,mediaId,expected);
      const result=[];
      for(const set of sets){
        const reps=own(set,'Representation');if(!Array.isArray(reps)||reps.length<1||reps.length>16)return [];
        for(const rep of reps){
          const urls=own(rep,'BaseURL'),width=integer(own(rep,'@width')),height=integer(own(rep,'@height'));
          if(own(rep,'@mimeType')!=='video/mp4'||!width||!height||!Array.isArray(urls)||urls.length!==1)return [];
          const source=address(urls[0]);if(!source)return [];
          result.push({id:mediaId,service_type:'NTV',format:'file',page:page(mediaId),source,width,height,expected_duration:expected,
            binding:'received_card_mpd',protection_unverified:true});
        }
      }
      return result;
    }catch(_){return [];}
  };
  const capture=raw=>{
    try{
      if(!raw||typeof raw!=='object'||JSON.stringify(raw).length>256*1024)return [];
      const body=own(raw,'body'),single=own(body,'card'),list=own(body,'cards');
      if(single&&list)return [];
      const cards=single?[single]:Array.isArray(list)&&list.length<=16?list:[];
      return cards.flatMap(card).slice(0,64);
    }catch(_){return [];}
  };
  // Fixed diagnostic fields only. Raw templates, URLs and credentials stay private.
  const cardDiagnostics=value=>{
    try{
      const c=own(value,'content'),vod=own(c,'vod'),playback=own(vod,'playback'),mpd=own(playback,'MPD')?.[0],period=own(mpd,'Period')?.[0];
      const expected=own(own(c,'videoQuality'),'duration'),sets=own(period,'AdaptationSet'),service=own(c,'serviceType');
      const result={id:id(own(c,'mediaId')),content:own(value,'cardType')==='CONTENT',service:['NTV','CLIP','MOMENT'].includes(service)?service:'other',
        playable:own(vod,'playable')===true,expected:Number.isFinite(expected)&&expected>0&&expected<=86400?expected:null,
        protection_clear:clearWholeFile(playback,true),mpd_count:own(playback,'MPD')?.length||0,
        mpd_static:own(mpd,'@type')==='static',mpd_id_matches:own(mpd,'@nvod:videoId')===own(c,'mediaId'),
        period_count:own(mpd,'Period')?.length||0,period_id_matches:own(period,'@id')===own(c,'mediaId'),
        mpd_duration:seconds(own(mpd,'@mediaPresentationDuration')),period_duration:seconds(own(period,'@duration')),set_count:Array.isArray(sets)?sets.length:0,representations:[]};
      for(const set of Array.isArray(sets)?sets.slice(0,4):[])for(const rep of (Array.isArray(own(set,'Representation'))?own(set,'Representation'):[]).slice(0,16)){
        if(result.representations.length>=8)break;
        if(String(own(rep,'@mimeType')||own(set,'@mimeType')||'').toLowerCase()!=='video/mp2t')continue;
        const t=(own(rep,'SegmentTemplate')||own(set,'SegmentTemplate'))?.[0],rows=own(t,'SegmentTimeline')?.[0]?.S;
        const numeric=(o,k,fallback)=>{const v=own(o,k);return v===undefined?fallback:typeof v==='string'&&/^(?:0|[1-9][0-9]*)$/.test(v)?Number(v):NaN;};
        const plan={base:(own(rep,'BaseURL')||own(set,'BaseURL'))?.[0],media:own(t,'@media'),representation:own(rep,'@id'),
          start:numeric(t,'@startNumber',NaN),timescale:numeric(t,'@timescale',NaN),
          rows:Array.isArray(rows)?rows.map(r=>({t:numeric(r,'@t',NaN),d:numeric(r,'@d',NaN),r:numeric(r,'@r',0)})):[]};
        const codec=own(rep,'@codecs')||own(set,'@codecs')||'';
        result.representations.push({width:integer(own(rep,'@width')),height:integer(own(rep,'@height')),avc:/avc/i.test(codec),aac:/mp4a/i.test(codec),
          export_valid:!!address(own(rep,'@nvod:m3u')),initialization:!!own(t,'@initialization')||!!own(t,'Initialization'),offset:!!own(t,'@presentationTimeOffset'),
          timeline:segments(plan,true),timeline_rows:plan.rows.slice(0,4).map(r=>({t:Number.isSafeInteger(r.t)?r.t:null,d:Number.isSafeInteger(r.d)?r.d:null,r:Number.isSafeInteger(r.r)?r.r:null}))});
      }
      return result;
    }catch(_){return {id:null,diagnostics_available:false};}
  };
  const binding=(video,data,requests,document,live)=>{
    if(!playbackPage(document.location.href)||!video.isConnected||video.mediaKeys||video.seeking||video.readyState<2||!presented(video)||
      !Number.isFinite(video.duration)||video.duration<=0||!Array.isArray(data)||!Array.isArray(requests)||!Array.isArray(live))return null;
    if(video.currentSrc.startsWith('blob:')){
      const u=new URL(document.location.href);if(u.searchParams.get('serviceType')!=='CLIP'||new URL(video.currentSrc).origin!==u.origin||live.filter(v=>v.isConnected&&v.readyState>=2&&presented(v)).length!==1)return null;
      const active=id(u.searchParams.get('seedMediaId'));if(!active||u.searchParams.getAll('seedMediaId').length!==1)return null;
      const matches=data.filter(d=>d.format==='segment_timeline'&&d.id===active&&d.width===video.videoWidth&&d.height===video.videoHeight&&Math.abs(d.expected_duration-video.duration)<=.5)
        .filter(d=>{const parsed=segments(d.timeline);return parsed&&requests.some(r=>r.kind==='segment'&&Date.now()-r.at>=0&&Date.now()-r.at<=1800000&&parsed.refs.some(s=>s.url===r.url));});
      const unique=[...new Map(matches.map(d=>[d.id+'\n'+d.source,d])).values()];if(unique.length!==1)return null;
      const d=unique[0];return {...d,current_source:video.currentSrc,document:document.location.href,duration:video.duration,start_seconds:video.ended?0:video.currentTime,
        fragment_kind:'blob',fragment_start:null,fragment_end:null,revision:revision(d.id+'\n'+video.currentSrc+'\n'+JSON.stringify(d.timeline))};
    }
    const selected=resource(video.currentSrc);if(!selected||selected.start!==null&&selected.start>video.duration||selected.end!==null&&selected.end>video.duration+.5)return null;
    const matches=data.filter(d=>d.source===selected.source&&d.width===video.videoWidth&&d.height===video.videoHeight&&Math.abs(d.expected_duration-video.duration)<=.5);
    const unique=[...new Map(matches.map(d=>[d.id+'\n'+d.source,d])).values()];if(unique.length!==1)return null;
    if(live.some(v=>v!==video&&v.isConnected&&v.readyState>=2&&presented(v)&&resource(v.currentSrc)?.source===selected.source))return null;
    if(!requests.some(r=>{const age=Date.now()-r.at;return r.kind==='file'&&r.url===selected.source&&
      (selected.kind!=='tracking'||r.request_url===video.currentSrc)&&age>=0&&age<=1800000;}))return null;
    const d=unique[0];return {...d,current_source:video.currentSrc,document:document.location.href,duration:video.duration,
      start_seconds:video.ended?0:video.currentTime,fragment_kind:selected.kind,fragment_start:selected.start,fragment_end:selected.end,
      revision:revision(d.id+'\n'+video.currentSrc+'\n'+d.width+'x'+d.height+'\n'+d.expected_duration)};
  };
  return {id,address,documentPage,playbackPage,page,temporal,resource,seconds,clearWholeFile,segments,card,capture,cardDiagnostics,binding};
})();
