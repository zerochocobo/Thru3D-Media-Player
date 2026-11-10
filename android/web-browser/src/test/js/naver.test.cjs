const test=require('node:test'),assert=require('node:assert/strict'),vm=require('node:vm'),fs=require('node:fs');
const context=vm.createContext({URL,Date,innerWidth:1600,innerHeight:1000});
vm.runInContext(fs.readFileSync(__dirname+'/../../main/assets/web-browser/tiktok.js','utf8')+'\n'+fs.readFileSync(__dirname+'/../../main/assets/web-browser/naver.js','utf8')+';globalThis.n=Thru3DNaver;',context);
const n=context.n,mediaId='A'.repeat(36),source='https://related.example/video.mp4?signature=EXACT&quality=hd';
function fixture(){
 const rep={'@width':'1280','@height':'548','@mimeType':'video/mp4',BaseURL:[source]};
 const period={'@id':mediaId,'@duration':'PT2118.38S',AdaptationSet:[{Representation:[rep]}]};
 const mpd={'@nvod:videoId':mediaId,'@type':'static','@mediaPresentationDuration':'PT35M18.38S',Period:[period]};
 const content={mediaId,serviceType:'NTV',videoQuality:{width:1280,height:548,duration:2118.38},vod:{playable:true,playback:{MPD:[mpd]}}};
 const card={cardType:'CONTENT',content},raw={header:{code:200},body:{card}};
 const video={isConnected:true,readyState:4,mediaKeys:null,seeking:false,currentSrc:source+'#t=0.001',videoWidth:1280,videoHeight:548,
  duration:2118.379682,currentTime:12,ended:false,getBoundingClientRect:()=>({left:100,top:100,right:1380,bottom:648,width:1280,height:548})};
 const requests=[{url:source,kind:'file',at:Date.now(),headers:{authorization:'OWN_REQUEST'}}];
 const document={location:{href:'https://m.naver.com/shorts/?serviceType=NTV&seedMediaId='+mediaId}};
 return {raw,card,content,mpd,period,rep,video,requests,document};
}
test('actual received MPD identity binds the full declared file while preserving a valid DOM time fragment',()=>{
 const f=fixture(),data=n.capture(f.raw),b=n.binding(f.video,data,f.requests,f.document,[f.video]);
 assert.equal(data.length,1);assert.equal(b.id,mediaId);assert.equal(b.source,source);assert.equal(b.current_source,source+'#t=0.001');
 assert.equal(b.fragment_start,.001);assert.equal(b.duration,2118.379682);assert.equal(b.protection_unverified,true);
 assert.equal(f.requests[0].headers.authorization,'OWN_REQUEST');
});
test('an unchanged navigation seed does not overwrite the actually decoded card identity',()=>{
 const f=fixture();f.document.location.href=f.document.location.href.replace(mediaId,'B'.repeat(36));
 assert.equal(n.binding(f.video,n.capture(f.raw),f.requests,f.document,[f.video]).id,mediaId);
 for(const page of ['https://m.naver.com/shorts/?serviceType=OTHER','https://m.naver.com.evil/shorts/?serviceType=NTV','https://tv.naver.com/v/81652']){
  f.document.location.href=page;assert.equal(n.binding(f.video,n.capture(f.raw),f.requests,f.document,[f.video]),null);
 }
});

test('unsupported timeline service retains owned-document observation without authorizing a Beta binding',()=>{
 const f=fixture();f.document.location.href=f.document.location.href.replace('NTV','MOMENT');
 assert.equal(n.documentPage(f.document.location.href),true);assert.equal(n.playbackPage(f.document.location.href),false);
 assert.equal(n.binding(f.video,n.capture(f.raw),f.requests,f.document,[f.video]),null);
 assert.equal(n.documentPage('https://m.naver.com.evil/shorts/?serviceType=NTV'),false);
});
test('only a parsed temporal fragment may leave the HTTP transport; every signed query byte remains required',()=>{
 for(const hash of ['#token=PRIVATE','#t=NaN','#t=-1','#t=0,0','#t=0&other=1','#xywh=1,2,3,4','#'])assert.equal(n.temporal(source+hash),null);
 const f=fixture();f.video.currentSrc=source+'&changed=1#t=0.001';assert.equal(n.binding(f.video,n.capture(f.raw),f.requests,f.document,[f.video]),null);
 f.video.currentSrc=source+'#t=9999';assert.equal(n.binding(f.video,n.capture(f.raw),f.requests,f.document,[f.video]),null);
 assert.equal(n.temporal(source+'#t=npt:1.5,2.5').end,2.5);
});
test('protected, segmented, unplayable, ad and contradictory media declarations are rejected',()=>{
 for(const mutate of [f=>f.mpd.ContentProtection=[{}],f=>f.rep.SegmentList=[{}],f=>f.mpd['@type']='dynamic',
  f=>f.mpd['@nvod:videoId']='B'.repeat(36),f=>f.period['@id']='B'.repeat(36),f=>f.card.cardType='AD',
  f=>f.content.vod.playable=false,f=>f.content.serviceType='OTHER',f=>f.rep['@width']='0',f=>f.period['@duration']='PT0S']){
  const f=fixture();mutate(f);assert.equal(n.capture(f.raw).length,0);
 }
});
test('missing requests, changed playback and ambiguous renderers cannot borrow a declared source',()=>{
 const f=fixture(),data=n.capture(f.raw);
 for(const requests of [[],[{...f.requests[0],url:source+'&different=1'}],[{...f.requests[0],at:Date.now()-1800001}],[{...f.requests[0],kind:'hls'}]])
  assert.equal(n.binding(f.video,data,requests,f.document,[f.video]),null);
 for(const mutate of [v=>v.mediaKeys={},v=>v.seeking=true,v=>v.videoWidth=640,v=>v.readyState=1]){
  const v={...f.video};mutate(v);assert.equal(n.binding(v,data,f.requests,f.document,[v]),null);
 }
 assert.equal(n.binding(f.video,data,f.requests,f.document,[f.video,{...f.video}]),null);
 const other={...data[0],id:'B'.repeat(36)};
 assert.equal(n.binding(f.video,[...data,other],f.requests,f.document,[f.video]),null);
});
test('a tid fragment needs the exact observed current request; unrelated server tracking is not a content identity',()=>{
 const f=fixture(),tid='T'.repeat(22);
 f.period.SupplementalProperty=[{'nvod:Trackings':[{'@tid':'SERVER_TRACKING_SEPARATE'}]}];f.video.currentSrc=source+'#tid='+tid;
 f.requests[0].request_url=f.video.currentSrc;
 const b=n.binding(f.video,n.capture(f.raw),f.requests,f.document,[f.video]);
 assert.equal(b.fragment_kind,'tracking');assert.equal(b.source,source);assert.equal(b.current_source,f.video.currentSrc);
 f.video.currentSrc=source+'#tid='+'Q'.repeat(22);assert.equal(n.binding(f.video,n.capture(f.raw),f.requests,f.document,[f.video]),null);
 assert.equal(n.resource(source+'#tid='+tid+'&extra=1'),null);
 f.video.currentSrc=source+'#tid='+tid;delete f.requests[0].request_url;
 assert.equal(n.binding(f.video,n.capture(f.raw),f.requests,f.document,[f.video]),null);
});

function clipFixture(){
 const f=fixture();f.content.serviceType='CLIP';f.content.videoQuality.duration=26.38;
 f.mpd['@mediaPresentationDuration']='PT26.333S';f.period['@duration']='PT26.333S';
 f.rep={'@id':'1080p','@width':'1080','@height':'1920','@codecs':'avc1.640028,mp4a.40.2',BaseURL:['https://segments.example/current/'],
  '@nvod:m3u':'https://manifest.example/current.m3u8?signature=DECLARED',SegmentTemplate:[{'@media':'$RepresentationID$-$Number$.ts?signature=EXACT',
    '@timescale':'1000','@startNumber':'0',SegmentTimeline:[{S:[{'@t':'0','@d':'4000','@r':'5'},{'@t':'24000','@d':'2333'}]}]}]};
 f.period.AdaptationSet=[{'@mimeType':'video/MP2T',Representation:[f.rep]}];
 f.video={...f.video,currentSrc:'blob:https://m.naver.com/rendered-current',videoWidth:1080,videoHeight:1920,duration:26.379777};
 f.document.location.href=n.page(mediaId,'CLIP');
 f.requests=[{url:'https://segments.example/current/1080p-0.ts?signature=EXACT',kind:'segment',at:Date.now()}];return f;
}

test('a current CLIP uses the received exact signed TS timeline, without fetching or calling its declared HLS observed',()=>{
 const f=clipFixture(),data=n.capture(f.raw),b=n.binding(f.video,data,f.requests,f.document,[f.video]);
 assert.equal(data.length,1);assert.equal(b.id,mediaId);assert.equal(b.format,'segment_timeline');assert.equal(b.fragment_kind,'blob');
 const parsed=n.segments(b.timeline);assert.equal(parsed.refs.length,7);assert.equal(parsed.duration,26.333);
 assert.equal(parsed.refs[0].url,f.requests[0].url);assert.equal(parsed.refs[6].duration,2.333);
 assert.equal(parsed.playlist.includes('#EXT-X-ENDLIST'),true);assert.equal(parsed.playlist.includes('signature=EXACT'),true);
 assert.equal(parsed.playlist.includes('signature=DECLARED'),false);
});

test('CLIP cannot borrow another card, signature, representation, document or preloaded renderer',()=>{
 for(const change of [f=>f.document.location.href=n.page('B'.repeat(36),'CLIP'),f=>f.requests[0].url+='&changed=1',
  f=>f.requests[0].url=f.requests[0].url.replace('1080p','720p'),f=>f.requests[0].kind='file',
  f=>f.video.currentSrc='blob:https://unrelated.example/current',f=>f.video.videoWidth=720]){
  const f=clipFixture();change(f);assert.equal(n.binding(f.video,n.capture(f.raw),f.requests,f.document,[f.video]),null);
 }
 const f=clipFixture();assert.equal(n.binding(f.video,n.capture(f.raw),f.requests,f.document,[f.video,{...f.video}]),null);
});

test('declared segment timelines reject encryption, holes, overlap, unsupported templates and unbounded repeats',()=>{
 for(const change of [f=>f.mpd.ContentProtection=[{}],f=>f.rep.SegmentTemplate[0]['@initialization']='init.mp4',
  f=>f.rep.SegmentTemplate[0]['@media']='$Time$.ts',f=>f.rep.SegmentTemplate[0].SegmentTimeline[0].S[0]['@r']='-1',
  f=>f.rep.SegmentTemplate[0].SegmentTimeline[0].S[0]['@r']='2048',f=>f.rep.SegmentTemplate[0].SegmentTimeline[0].S[1]['@t']='23999',
  f=>f.rep.SegmentTemplate[0]['@timescale']='0',f=>f.rep['@codecs']='avc1.640028']){
  const f=clipFixture();change(f);assert.equal(n.capture(f.raw).length,0);
 }
});

test('DASH Number zero padding retains every signed byte and the complete declared timeline',()=>{
 const f=clipFixture();f.rep.SegmentTemplate[0]['@media']='$RepresentationID$-$Number%05d$.ts?signature=EXACT';
 f.requests[0].url='https://segments.example/current/1080p-00000.ts?signature=EXACT';
 const b=n.binding(f.video,n.capture(f.raw),f.requests,f.document,[f.video]);assert.ok(b);
 assert.equal(n.segments(b.timeline).refs[6].url,'https://segments.example/current/1080p-00006.ts?signature=EXACT');
 f.rep.SegmentTemplate[0]['@media']='$RepresentationID$-$Number%099d$.ts';assert.equal(n.capture(f.raw).length,0);
});

test('observed one-millisecond segment gaps retain the original presentation anchors in the derived playlist',()=>{
 const f=clipFixture(),t=f.rep.SegmentTemplate[0];
 f.content.videoQuality.duration=12.331;f.mpd['@mediaPresentationDuration']=f.period['@duration']='PT12.331S';f.video.duration=12.330687;
 t.SegmentTimeline=[{S:[{'@t':'0','@d':'4003'},{'@t':'4003','@d':'4004'},{'@t':'8008','@d':'4003'},{'@t':'12012','@d':'266'}]}];
 const b=n.binding(f.video,n.capture(f.raw),f.requests,f.document,[f.video]);assert.ok(b);
 const parsed=n.segments(b.timeline);assert.deepEqual(Array.from(parsed.refs,r=>r.duration),[4.003,4.005,4.004,.266]);assert.equal(parsed.duration,12.278);
 assert.equal(n.segments(b.timeline,true).gap_ticks,2);
 for(const bad of [8006,8009]){t.SegmentTimeline[0].S[2]['@t']=String(bad);assert.equal(n.capture(f.raw).length,0);}
});

test('a received repeated timeline row retains its accumulated one-tick-per-segment anchors',()=>{
 const f=clipFixture();f.content.videoQuality.duration=16.335;f.mpd['@mediaPresentationDuration']=f.period['@duration']='PT16.335S';f.video.duration=16.335;
 f.rep.SegmentTemplate[0].SegmentTimeline=[{S:[{'@t':'0','@d':'4003'},{'@t':'4003','@d':'4004'},{'@t':'8008','@d':'4003','@r':'1'},{'@t':'16016','@d':'266'}]}];
 const b=n.binding(f.video,n.capture(f.raw),f.requests,f.document,[f.video]);assert.ok(b);
 const parsed=n.segments(b.timeline);assert.deepEqual(Array.from(parsed.refs,r=>r.duration),[4.003,4.005,4.003,4.005,.266]);assert.equal(parsed.duration,16.282);
 f.rep.SegmentTemplate[0].SegmentTimeline[0].S[3]['@t']='16017';assert.equal(n.capture(f.raw).length,0);
});
