const test=require('node:test'),assert=require('node:assert/strict'),vm=require('node:vm'),fs=require('node:fs');
const context=vm.createContext({URL});vm.runInContext(fs.readFileSync(__dirname+'/../../main/assets/web-browser/iqiyi.js','utf8')+';globalThis.capture=Thru3DIqiyi.capture;globalThis.matches=Thru3DIqiyi.matches;globalThis.bind=Thru3DIqiyi.binding;globalThis.restore=Thru3DIqiyi.restore;',context);
const page='https://www.iqiyi.com/v_current123.html';
const largeFixture=require('./iqiyi-large-fixture.cjs');
function fixture(){
  const video={isConnected:true,readyState:4,videoWidth:1280,videoHeight:720,duration:25,currentSrc:'blob:unit-current',seeking:false};
  const track={_selected:true,vid:'currentstream',bid:500,ff:'ts',scrsz:'1280x720',duration:25,drmType:1,
    m3u8:'#EXTM3U\n#EXTINF:25,\nhttps://cdn.test/PRIVATE.ts?token=PRIVATE\n#EXT-X-ENDLIST'};
  const info={id:'42',vid:'currentstream',_bid:500,type:'Movie',duration:25000};
  const view={QiyiPlayerProphetData:{tvId:'42',dashData:{data:{tvid:'42',program:{video:[track]}}}},playback:{_element:video,playingPlayback:{_info:info}}};
  return {view,track,info,video,dom:{querySelectorAll:()=>[video]}};
}

test('large complete declarations use the checked JS-to-JVM lossless transport vector',()=>{
  const f=largeFixture(),data=context.capture(f.view,page,f.dom);
  assert.equal(data.ready,true);assert.ok(context.bind(f.video,data));
  const wire=vm.runInContext('Thru3DIqiyi.transport',context)(data);
  assert.ok(f.playlist.length>256*1024);assert.ok(f.playlist.length<512*1024);
  assert.equal(wire.playlist,undefined);assert.equal(wire.playlist_delta.chars,f.playlist.length);
  assert.ok(JSON.stringify(wire).length<128*1024);
  const vector=JSON.parse(fs.readFileSync(__dirname+'/../resources/iqiyi-large-wire.json','utf8'));
  const expected=vector.iqiyi.playlist_delta;
  vector.iqiyi.playlist_delta={...expected,version:2,rows:JSON.stringify(expected.rows)};
  assert.deepEqual(JSON.parse(JSON.stringify(wire)),vector.iqiyi);
  assert.equal(context.matches(data,{kind:'segment',url:f.url(435),at:Date.now()}),true);
  const old=wire.playlist_delta;f.track.m3u8=f.playlist.replace('UNIT%2bEXACT','CHANGED%2bEXACT');
  const next=context.capture(f.view,page,f.dom),updated=vm.runInContext('Thru3DIqiyi.transport',context)(next);
  assert.notEqual(updated.playlist_delta,old);assert.notEqual(next.revision,data.revision);
});

test('a long declaration and scoped request history fit in the same Android media report',()=>{
  const f=largeFixture();let segment=0;
  f.track.m3u8=f.playlist.replace(/&opaque=(?:ab){90}/g,()=>`&opaque=${(segment++%2?'x':'y').repeat(180)}`);
  const data=context.capture(f.view,page,f.dom);
  assert.equal(data.ready,true);
  const {transport,fitMediaReport}=vm.runInContext('Thru3DIqiyi',context);
  const declaration=transport(data);
  const requests=Array.from({length:24},(_,i)=>({kind:'segment',url:f.url(i),original_url:f.url(i),at:i,headers:{cookie:'session='+'x'.repeat(6500)}}));
  const preview={id:1,width:0,network:[]};
  const owner={id:2,iqiyi:declaration,iqiyi_ready:true,iqiyi_request:3,network:requests};
  const report={type:'media',videos:[preview,owner],pause_token:8,pause_held:true};
  const androidSize=value=>JSON.stringify(value).replace(/\//g,'\\/').length;
  assert.ok(JSON.stringify(requests).length<=192*1024);
  assert.ok(androidSize(report)>256*1024);

  assert.equal(fitMediaReport(report),report);
  assert.ok(androidSize(report)<=240*1024);
  assert.equal(owner.iqiyi,declaration);
  assert.equal(owner.iqiyi_request,3);
  assert.equal(report.pause_token,8);
  assert.equal(report.pause_held,true);
  assert.equal(report.videos[0],preview);
  assert.ok(owner.network.length>0&&owner.network.length<requests.length);
  assert.deepEqual(Array.from(owner.network),requests.slice(-owner.network.length));
  const trimmed=owner.network;
  fitMediaReport(report);
  assert.equal(owner.network,trimmed);
});

test('packing never truncates an oversized declaration or hides a protected tail',()=>{
  const f=largeFixture();f.track.m3u8=f.playlist+'#EXT-X-KEY:METHOD=SAMPLE-AES,URI="PRIVATE"\n';
  assert.equal(context.capture(f.view,page,f.dom).status,'protected_manifest');
  f.track.m3u8='#EXTM3U\n#'+'x'.repeat(512*1024);
  assert.equal(context.capture(f.view,page,f.dom).status,'oversize_playlist');
});
test('captures exactly the website-selected decoded item and track, but never grants protection clearance',()=>{
  const f=fixture(),c=context.capture(f.view,page,f.dom);assert.equal(c.ready,true);assert.equal(c.vid,'currentstream');assert.equal(c.bid,500);
  assert.equal(c.protection_unverified,true);assert.equal(c.drm_type,1);
  f.view.__lastAccJson={tvId:'next'};assert.equal(context.capture(f.view,page,f.dom).tvid,'42');
});

function changeEpisode(f){
  const active=f.view.playback.playingPlayback;
  active._info={...active._info,id:'43',vid:'nextstream'};
  const track={...f.track,vid:'nextstream',m3u8:f.playlist.replaceAll('qd_tvid=42','qd_tvid=43')};
  active._mvInfo={...active._mvInfo,tvid:'43',videoList:[track],levelInfoArr:active._mvInfo.levelInfoArr.map(level=>({
    ...level,vid:'nextstream',fragmentList:level.fragmentList.map(fragment=>({...fragment,dispatchUrl:fragment.dispatchUrl.replace('qd_tvid=42','qd_tvid=43')}))
  }))};
}

test('same-document episodes wait for a different decoded programme and bind its active SDK track',()=>{
  const f=largeFixture(),next='https://www.iqiyi.com/v_next.html';
  const first=context.capture(f.view,page,f.dom);
  assert.ok(context.bind(f.video,first));
  assert.equal(context.capture(f.view,next,f.dom).status,'wrong_item');
  changeEpisode(f);
  assert.equal(context.capture(f.view,next,f.dom).status,'wrong_item');
  f.video.currentSrc='blob:unit-next';
  const selected=context.capture(f.view,next,f.dom);
  assert.ok(context.bind(f.video,selected));
  assert.equal(selected.page,next);
  assert.equal(selected.tvid,'43');
  assert.equal(selected.vid,'nextstream');
  assert.notEqual(selected.revision,first.revision);
  assert.ok(context.bind(f.video,context.capture(f.view,next,f.dom)));
});

test('rapid unverified episode navigation and stale startup metadata cannot claim a new address',()=>{
  const f=largeFixture();
  assert.equal(context.capture(f.view,page,f.dom).ready,true);
  assert.equal(context.capture(f.view,'https://www.iqiyi.com/v_intermediate.html',f.dom).status,'wrong_item');
  changeEpisode(f);
  f.video.currentSrc='blob:unit-next';
  assert.equal(context.capture(f.view,'https://www.iqiyi.com/v_final.html',f.dom).status,'wrong_item');
  const second=largeFixture();
  assert.equal(context.capture(second.view,'https://www.iqiyi.com/v_final.html',second.dom).ready,true);
});

test('the document entry address anchors startup metadata before the first video report',()=>{
  const f=largeFixture(),local=vm.createContext({URL,location:{href:page}});
  vm.runInContext(fs.readFileSync(__dirname+'/../../main/assets/web-browser/iqiyi.js','utf8')+';globalThis.capture=Thru3DIqiyi.capture;',local);
  assert.equal(local.capture(f.view,'https://www.iqiyi.com/v_next.html',f.dom).status,'wrong_item');
  assert.equal(local.capture(f.view,page,f.dom).ready,true);
});

test('readiness diagnostics separate a current SDK declaration from the unchanged dispatch and timeline gates',()=>{
  const f=fixture(),inspect=vm.runInContext('Thru3DIqiyi.diagnostics',context);
  const data={ready:true,status:'bound',src:f.video.currentSrc,width:1280,height:720,duration:25,drm_type:1,
    has_drm:false,has_root_drm:false,dispatch_status:'selected_level',dispatchers:[{}],dispatch_duration_ms:31000,
    playlist:'PRIVATE_URL_OR_TOKEN'};
  let d=inspect(f.video,data);assert.equal(d.capture_ready,true);assert.equal(d.binding_ready,false);assert.equal(d.timeline_matches,false);
  assert.equal(d.dispatch_ready,true);assert.equal(d.dispatcher_count,1);assert.equal(JSON.stringify(d).includes('PRIVATE'),false);
  data.dispatch_duration_ms=25000;d=inspect(f.video,data);assert.equal(d.binding_ready,true);assert.equal(d.timeline_matches,true);
  data.drm_type=2;assert.equal(inspect(f.video,data).binding_ready,false);
  assert.equal(inspect(f.video,{ready:false,status:'wrong_track'}).status,'wrong_track');
});
test('ads, replacement items, tracks, elements and dimensions cannot borrow the current declaration',()=>{
  for(const mutate of [f=>f.info.type='Ad',f=>f.info.id='43',f=>f.info.vid='next',f=>f.info._bid=100,
    f=>f.view.playback._element={},f=>f.video.videoHeight=544,f=>f.info.duration=600000,
    f=>f.video.mediaKeys={},f=>f.video.seeking=true,f=>delete f.track.vid]){
    const f=fixture();mutate(f);assert.equal(context.capture(f.view,page,f.dom).ready,false);
  }
});
test('quality fallback uses the current Movie declaration rather than a stale initial selection',()=>{
  const f=fixture(),old=f.track,track={...old,vid:'currentlow',bid:300,scrsz:'896x376',_selected:false};
  f.info.vid=track.vid;f.info._bid=300;f.video.videoWidth=896;f.video.videoHeight=376;
  f.view.QiyiPlayerProphetData.dashData.data.program.video=[old,{vid:track.vid,bid:300}];
  f.view.__lastAccJson={tvId:'99',dashData:{data:{tvid:'99',program:{video:[track]}}}};
  const movie=f.view.playback.playingPlayback._mvInfo={tvid:'42',videoList:[old,track]};
  const c=context.capture(f.view,page,f.dom);assert.equal(c.ready,true);assert.equal(c.bid,300);assert.equal(c.width,896);
  movie.videoList.push({...track});assert.equal(context.capture(f.view,page,f.dom).ready,false);
  movie.videoList=[{...track,vid:'anotherstream'}];assert.equal(context.capture(f.view,page,f.dom).ready,false);
  movie.videoList=[track];movie.tvid='99';assert.equal(context.capture(f.view,page,f.dom).ready,false);
  movie.tvid='42';track.m3u8='#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI="PRIVATE"';
  assert.equal(context.capture(f.view,page,f.dom).status,'protected_manifest');
});
test('protected manifests and page getters do not become private capture input',()=>{
  const f=fixture();f.track.m3u8='#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI="PRIVATE_KEY"';
  const c=context.capture(f.view,page,f.dom);assert.equal(c.ready,false);assert.equal(JSON.stringify(c).includes('PRIVATE'),false);
  let calls=0;Object.defineProperty(f.view,'QiyiPlayerProphetData',{get(){calls++;throw Error();}});
  assert.equal(context.capture(f.view,page,f.dom).ready,false);assert.equal(calls,0);
  assert.equal(context.capture(f.view,'https://evil.test/v_current123.html',f.dom).ready,false);
});

test('reports only the current rejected container and declaration shape',()=>{
  const f=fixture(),inspect=vm.runInContext('Thru3DIqiyi.diagnostics',context);
  f.track.ff='m4s';f.track.m3u8='{"video":["https://private.test/SIGNED"]}';f.track.fs=[{}];
  const data=context.capture(f.view,page,f.dom),diagnostics=inspect(f.video,data);
  assert.equal(data.ready,false);
  assert.equal(diagnostics.status,'unsupported_container');
  assert.equal(diagnostics.container,'m4s');assert.equal(diagnostics.declaration,'json_object');
  assert.equal(diagnostics.drm_type,1);assert.equal(diagnostics.has_segment_list,true);
  assert.doesNotMatch(JSON.stringify(diagnostics),/private|SIGNED/);
  f.track.ff='PRIVATE_FORMAT';
  assert.equal(inspect(f.video,context.capture(f.view,page,f.dom)).container,'other');
  delete f.track.ff;
  assert.equal(inspect(f.video,context.capture(f.view,page,f.dom)).container,'missing');
});

test('unsupported declarations keep the same rejection gates with fixed nonprivate reasons',()=>{
  const inspect=vm.runInContext('Thru3DIqiyi.diagnostics',context);
  for(const [change,status] of [
    [{ff:'PRIVATE_FORMAT'},'unsupported_container'],
    [{m3u8:{private:'PRIVATE_DECLARATION'}},'missing_playlist'],
    [{m3u8:'#EXTM3U\n#'+'x'.repeat(128*1024)},'oversize_playlist'],
    [{m3u8:'{"private":"PRIVATE_DECLARATION"}'},'non_hls_playlist']]){
    const f=fixture();Object.assign(f.track,change);
    const captured=context.capture(f.view,page,f.dom),d=inspect(f.video,captured);
    assert.equal(captured.ready,false);assert.equal(captured.status,status);
    const fields=status==='unsupported_container'?
      'container,declaration,drm_type,has_drm,has_root_drm,has_segment_list,ready,status':'ready,status';
    assert.equal(Object.keys(captured).sort().join(','),fields);
    assert.equal(d.capture_ready,false);assert.equal(d.binding_ready,false);
    assert.equal(JSON.stringify(d).includes('PRIVATE'),false);
  }
  const f=fixture(),base=f.track.m3u8;
  f.track.m3u8=base+'\n#'+'x'.repeat(128*1024-base.length-2);
  assert.equal(f.track.m3u8.length,128*1024);
  assert.equal(context.capture(f.view,page,f.dom).ready,true);
  f.track.m3u8+='x';assert.equal(context.capture(f.view,page,f.dom).status,'oversize_playlist');
});
test('actual current-file observations keep their signed URL and reject other files, items and stale requests',()=>{
  const f=fixture(),current=context.capture(f.view,page,f.dom);
  const record={kind:'segment',url:'https://another-cdn.test/PRIVATE.ts?qd_tvid=42&sign=ACTUAL',at:Date.now()};
  assert.equal(context.matches(current,record),true);assert.equal(record.url.includes('ACTUAL'),true);
  for(const change of [{url:record.url.replace('42','43')},{url:record.url.replace('PRIVATE.ts','OTHER.ts')},{at:Date.now()-1800001},{kind:'hls'}])assert.equal(context.matches(current,{...record,...change}),false);
});
test('reads only the SDK current level dispatch data without rebuilding ms/mk or executing accessors',()=>{
  const f=fixture();f.track.m3u8='#EXTM3U\n#EXTINF:25,\nhttps://declared.test/currentfile.ts?start=0&end=188&contentlength=188&sd=0\n#EXT-X-ENDLIST';
  const fragment={sourceID:'currentfile',sPos:0,ePos:188,dispatchUrl:'//dispatch.test/currentfile.ts?website_issued=PRIVATE'};
  const level={vid:'currentstream',bid:500,fragmentList:[fragment]};
  f.view.playback.playingPlayback._mvInfo={tvid:'42',levelInfoArr:[level]};
  let result=context.capture(f.view,page,f.dom);assert.equal(result.dispatch_status,'selected_level');assert.equal(result.dispatchers.length,1);
  assert.equal(result.dispatchers[0].url,'https://dispatch.test/currentfile.ts?website_issued=PRIVATE');
  for(const change of [()=>level.vid='other',()=>level.fragmentList=[{...fragment,sourceID:'other'}]]){
    level.vid='currentstream';level.fragmentList=[fragment];change();assert.equal(context.capture(f.view,page,f.dom).dispatchers.length,0);
  }
  let calls=0;level.fragmentList=[fragment];Object.defineProperty(level,'fragmentList',{get(){calls++;throw Error();}});
  result=context.capture(f.view,page,f.dom);assert.equal(result.dispatchers.length,0);assert.equal(calls,0);
});

test('the visible action needs the same decoded SDK element, a clear track and complete dispatch data',()=>{
  const f=fixture();f.track.m3u8='#EXTM3U\n#EXTINF:25,\nhttps://declared.test/currentfile.ts?start=0&end=188&contentlength=188&sd=0\n#EXT-X-ENDLIST';
  f.view.playback.playingPlayback._mvInfo={tvid:'42',levelInfoArr:[{vid:'currentstream',bid:500,duration:25000,fragmentList:[{sourceID:'currentfile',sPos:0,ePos:188,dispatchUrl:'//dispatch.test/currentfile.ts?issued=private'}]}]};
  const data=context.capture(f.view,page,f.dom);assert.equal(data.id,'v_current123');assert.match(data.revision,/^[a-f0-9]{1,8}$/);
  assert.ok(context.bind(f.video,data));
  for(const update of [{has_drm:true},{drm_type:2},{dispatchers:[]},{dispatch_duration_ms:null},{dispatch_duration_ms:24480},{src:'blob:other'}])assert.equal(context.bind(f.video,{...data,...update}),null);
});
test('integer MSE duration needs both the complete playlist total and matching SDK end anchor',()=>{
  const f=fixture();f.track.m3u8='#EXTM3U\n#EXTINF:25,\nhttps://declared.test/currentfile.ts?start=0&end=188&contentlength=188&sd=0\n#EXT-X-ENDLIST';
  f.info.duration=24480;
  f.view.playback.playingPlayback._mvInfo={tvid:'42',levelInfoArr:[{vid:'currentstream',bid:500,duration:24480,
    fragmentList:[{sourceID:'currentfile',sPos:0,ePos:188,dispatchUrl:'//dispatch.test/currentfile.ts?issued=private'}]}]};
  const data=context.capture(f.view,page,f.dom);assert.ok(context.bind(f.video,data));
  for(const update of [{sdk_duration_ms:24000},{playlist_duration:24},{dispatch_duration_ms:23000},
    {duration:25.2},{sdk_duration_ms:null}])assert.equal(context.bind({...f.video,duration:update.duration??25},{...data,...update}),null);
});

test('rounded playlist totals can differ when the last declared segment ends at the SDK duration',()=>{
  for(const {dispatchMs,tailStart,headDuration} of [
    {dispatchMs:24000,tailStart:20000,headDuration:21},
    {dispatchMs:24120,tailStart:20120,headDuration:20},
    {dispatchMs:24160,tailStart:20160,headDuration:19}
  ]){
    const f=fixture();f.info.duration=dispatchMs;f.track.duration=24;
    f.track.m3u8=`#EXTM3U\n#EXTINF:${headDuration},\nhttps://declared.test/currentfile.ts?start=0&end=188&contentlength=188&sd=0\n`+
      `#EXTINF:4,\nhttps://declared.test/currentfile.ts?start=188&end=376&contentlength=188&sd=${tailStart}\n#EXT-X-ENDLIST`;
    f.view.playback.playingPlayback._mvInfo={tvid:'42',levelInfoArr:[{vid:'currentstream',bid:500,duration:dispatchMs,
      fragmentList:[{sourceID:'currentfile',sPos:0,ePos:376,dispatchUrl:'//dispatch.test/currentfile.ts?issued=private'}]}]};
    const data=context.capture(f.view,page,f.dom);
    assert.equal(data.playlist_end_ms,dispatchMs);
    assert.ok(context.bind(f.video,data));
    const playlist=f.track.m3u8;
    for(const invalid of [playlist.replace(`sd=${tailStart}`,`sd=${tailStart+1}`),
      playlist.replace(`sd=${tailStart}`,`sd=${tailStart}&sd=${tailStart}`),
      playlist.replace('#EXT-X-ENDLIST',''),playlist.replace(`#EXTINF:${headDuration},`,'#EXTINF:18,')]){
      f.track.m3u8=invalid;
      assert.equal(context.bind(f.video,context.capture(f.view,page,f.dom)),null);
    }
  }
});

function controllable(){
  const f=fixture();f.track.m3u8='#EXTM3U\n#EXTINF:25,\nhttps://declared.test/currentfile.ts?start=0&end=188&contentlength=188&sd=0\n#EXT-X-ENDLIST';
  const playback=f.view.playback;
  playback.playingPlayback._mvInfo={tvid:'42',levelInfoArr:[{vid:'currentstream',bid:500,duration:25000,fragmentList:[{sourceID:'currentfile',sPos:0,ePos:188,dispatchUrl:'//dispatch.test/currentfile.ts?issued=private'}]}]};
  const calls=[];Object.setPrototypeOf(playback,{pause(){calls.push('pause');f.video.paused=true;},seek(ms,adjust){calls.push(['seek',ms,adjust]);f.video.currentTime=ms/1000;return ms;},play(){calls.push('play');f.video.paused=false;}});
  return {...f,calls,data:context.capture(f.view,page,f.dom)};
}
test('retained return uses the bound SDK seek in milliseconds without keyframe snapping and preserves pause intent',()=>{
  const f=controllable();assert.equal(context.restore(f.view,f.video,f.data,20,false),true);
  assert.deepEqual(f.calls,['pause',['seek',20000,false],'pause']);assert.equal(f.video.currentTime,20);assert.equal(f.video.paused,true);
  f.calls.length=0;assert.equal(context.restore(f.view,f.video,f.data,12,true),true);
  assert.deepEqual(f.calls,['pause',['seek',12000,false],'play']);assert.equal(f.video.paused,false);
});
test('SDK return cannot invoke getters, another programme or detached/replaced media',()=>{
  for(const mutate of [f=>{f.info.id='next';},f=>{f.info.type='Ad';},f=>{delete f.view.playback._element;},f=>{f.video.isConnected=false;},f=>{f.video.currentSrc='blob:other';}]){
    const f=controllable();mutate(f);assert.equal(context.restore(f.view,f.video,f.data,20,false),false);assert.deepEqual(f.calls,[]);
  }
  for(const value of [NaN,Infinity,-1,26]){const f=controllable();assert.equal(context.restore(f.view,f.video,f.data,value,false),false);assert.deepEqual(f.calls,[]);}
  const f=controllable();let getters=0;Object.defineProperty(f.view.playback,'seek',{get(){getters++;return ()=>{};}});
  assert.equal(context.restore(f.view,f.video,f.data,20,false),false);assert.equal(getters,0);assert.deepEqual(f.calls,[]);
});
