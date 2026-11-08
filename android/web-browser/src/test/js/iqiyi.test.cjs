const test=require('node:test'),assert=require('node:assert/strict'),vm=require('node:vm'),fs=require('node:fs');
const context=vm.createContext({URL});vm.runInContext(fs.readFileSync(__dirname+'/../../main/assets/web-browser/iqiyi.js','utf8')+';globalThis.capture=Thru3DIqiyi.capture;globalThis.matches=Thru3DIqiyi.matches;globalThis.bind=Thru3DIqiyi.binding;globalThis.restore=Thru3DIqiyi.restore;',context);
const page='https://www.iqiyi.com/v_current123.html';
function fixture(){
  const video={isConnected:true,readyState:4,videoWidth:1280,videoHeight:720,duration:25,currentSrc:'blob:unit-current',seeking:false};
  const track={_selected:true,vid:'currentstream',bid:500,ff:'ts',scrsz:'1280x720',duration:25,drmType:1,
    m3u8:'#EXTM3U\n#EXTINF:25,\nhttps://cdn.test/PRIVATE.ts?token=PRIVATE\n#EXT-X-ENDLIST'};
  const info={id:'42',vid:'currentstream',_bid:500,type:'Movie',duration:25000};
  const view={QiyiPlayerProphetData:{tvId:'42',dashData:{data:{tvid:'42',program:{video:[track]}}}},playback:{_element:video,playingPlayback:{_info:info}}};
  return {view,track,info,video,dom:{querySelectorAll:()=>[video]}};
}
test('captures exactly the website-selected decoded item and track, but never grants protection clearance',()=>{
  const f=fixture(),c=context.capture(f.view,page,f.dom);assert.equal(c.ready,true);assert.equal(c.vid,'currentstream');assert.equal(c.bid,500);
  assert.equal(c.protection_unverified,true);assert.equal(c.drm_type,1);
  f.view.__lastAccJson={tvId:'next'};assert.equal(context.capture(f.view,page,f.dom).tvid,'42');
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
