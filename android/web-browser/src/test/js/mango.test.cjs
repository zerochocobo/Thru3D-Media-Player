const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');
const m=vm.runInNewContext(fs.readFileSync(path.join(__dirname,'../../main/assets/web-browser/mango.js'),'utf8')+';Thru3DMango',{URL});
const raw=()=>({code:200,data:{info:{video_id:'15588271',duration:'4026',drmFlag:'0',trialtime:'300'},drm:{licenseUrl:'',drmFirm:'',drmType:''}}});
const declared='https://dispatch.example/route?pm2=opaque-current-video&arange=0';
const actual=declared+'&did=browser-id&suuid=session-id&callback=jsonp_1';

test('current public Mango paths preserve video identity',()=>{
  for(const url of ['https://w.mgtv.com/s/15588271.html','https://www.mgtv.com/b/427837/15588271.html'])assert.equal(m.page(url).id,'15588271');
  for(const url of ['http://w.mgtv.com/s/15588271.html','https://w.mgtv.com.evil/s/15588271.html','https://name@w.mgtv.com/s/15588271.html','https://w.mgtv.com/s/0.html','https://w.mgtv.com/s/15588271.html#other'])assert.equal(m.page(url),null);
});
test('metadata requires the observed requested video and explicit clear flags',()=>{
  assert.equal(m.video(raw(),'15588271').clear,true);
  assert.equal(m.video(raw(),'15588272'),null);
  for(const change of [r=>delete r.data.info.drmFlag,r=>r.data.info.drmFlag='1',r=>r.data.drm.licenseUrl='https://license.example/',r=>delete r.data.drm.drmType]){
    const r=raw();change(r);assert.equal(m.video(r,'15588271').clear,false);
  }
  for(const change of [r=>r.code=403,r=>r.data.info.duration=Infinity,r=>r.data.info.video_id=9007199254740992]){
    const r=raw();change(r);assert.equal(m.video(r,'15588271'),null);
  }
});
test('the general trialtime field does not turn a full free episode into a trial',()=>{
  assert.equal(m.video(raw(),'15588271').duration,4026);
});
test('source URLs come from the matched metadata and preserve unknown associated hosts',()=>{
  const metadata=m.video(raw(),'15588271');
  const source={code:200,data:{stream_domain:['https://new-dispatch.example/'],stream:[{url:'/route?pm2=current'}]}};
  assert.equal(m.sources(source,'15588271',metadata)[0],'https://new-dispatch.example/route?pm2=current');
  assert.equal(m.sources(source,'15588272',metadata).length,0);
  assert.equal(m.sources(source,'15588271',{...metadata,clear:false}).length,0);
});
test('JSONP invocation can add only the observed non-media invocation fields',()=>{
  assert.equal(m.matchDispatch([declared],actual),declared);
  assert.equal(m.matchDispatch([declared],declared),declared);
  assert.equal(m.matchDispatch([declared],declared+'&callback=x%2Ecallback'),declared);
  for(const suffix of ['&vid=another','&def=720','&url=https://other.example/a','&pm2=another','&callback=first&callback=second','&callback=x();evil()','&did='])assert.equal(m.matchDispatch([declared],actual+suffix),null);
});
test('declared parameters cannot be removed or changed and ambiguous aliases are rejected',()=>{
  for(const value of [actual.replace('current-video','other-video'),actual.replace('&arange=0',''),actual.replace('dispatch.example','other.example'),actual+'#other'])assert.equal(m.matchDispatch([declared],value),null);
  assert.equal(m.matchDispatch([declared,declared+'&did=browser-id'],actual),null);
  assert.equal(m.matchDispatch([declared,declared],actual),declared);
});
test('JSONP is parsed as JSON without executing callbacks or trailing code',()=>{
  assert.equal(m.json('callback({"code":200});').code,200);
  for(const text of ['callback({});evil()','({code:200})','callback([])','callback({"x":1});globalThis.secret=1'])assert.throws(()=>m.json(text));
});
test('only the observed successful dispatch result supplies a manifest hint',()=>{
  assert.equal(m.manifest({status:'ok',info:'https://new-cdn.example/video.m3u8?ticket=current'}),'https://new-cdn.example/video.m3u8?ticket=current');
  for(const raw of [{status:'error',info:'https://cdn.example/video.m3u8'},{info:'https://cdn.example/video.m3u8'},{status:'ok',info:'http://cdn.example/video.m3u8'},{status:'ok',info:'https://secret@cdn.example/video.m3u8'}])assert.equal(m.manifest(raw),null);
});
test('the domestic SDK direct HLS needs the exact current file hash as its filename',()=>{
  const source=raw(),hash='a'.repeat(32);Object.assign(source.data,{stream_domain:['https://dispatch.example/'],
    stream:[{url:'/route?current=1',fileHash:hash},{url:'',fileHash:'b'.repeat(32)}]});
  const files=m.files(source,'15588271',m.video(source,'15588271'));
  assert.equal(files.length,2);assert.equal(m.matchFile(files,'https://new-cdn.example/'+hash+'.m3u8?ticket=current'),hash);
  assert.equal(m.matchFile(files,'https://new-cdn.example/'+hash.toUpperCase()+'.m3u8'),hash);
  assert.equal(m.matchFile(files,'https://cdn.example/'+'b'.repeat(32)+'.m3u8'),'b'.repeat(32));
  for(const url of ['https://cdn.example/'+hash+'/ad.m3u8','https://cdn.example/prefix'+hash+'.m3u8',
    'https://cdn.example/other.m3u8?hash='+hash,'https://cdn.example/'+'c'.repeat(32)+'.m3u8'])assert.equal(m.matchFile(files,url),null);
  assert.equal(m.files(source,'15588272',m.video(source,'15588271')).length,0);
  assert.equal(m.files(source,'15588271',{id:'15588271',clear:false}).length,0);
});
test('a warmed Android SDK can select the explicitly declared HEVC file instead of AVC',()=>{
  const source=raw(),avc='a'.repeat(32),hevc='b'.repeat(32);
  Object.assign(source.data,{stream_domain:['https://dispatch.example/'],stream:[{url:'/route?current=1',fileHash:avc}],
    stream_h265:[{url:'',fileHash:hevc},{url:'',fileHash:avc}]});
  const files=m.files(source,'15588271',m.video(source,'15588271'));
  assert.equal(files.length,2);assert.equal(m.matchFile(files,'https://new-cdn.example/'+hevc+'.m3u8'),hevc);
  assert.equal(m.files(source,'15588272',m.video(source,'15588271')).length,0);
  assert.equal(m.files(source,'15588271',{id:'15588271',clear:false}).length,0);
});

test('the Hi6 SDK inline dispatch binds its observed URL with only the SDK timing fields added',()=>{
  const source=raw(),url='https://associated-cdn.example/current-preview.m3u8?arange=0&pm=current';
  Object.assign(source.data,{stream:[{url:'',videoWidth:960,videoHeight:540,disp:{status:'ok',info:url}}]});
  const metadata=m.video(source,'15588271'),entries=m.inline(source,'15588271',metadata);
  assert.equal(entries.length,1);
  assert.equal(m.matchInline(entries,url+'&ftc=0&sftc=1').url,url);
  for(const other of [url+'&video_id=other',url.replace('pm=current','pm=other'),url+'&ftc=0&ftc=1',url.replace('associated-cdn','other-cdn')])assert.equal(m.matchInline(entries,other),null);
  assert.equal(m.inline(source,'15588272',metadata).length,0);
  assert.equal(m.inline(source,'15588271',{...metadata,clear:false}).length,0);
});

test('inline declarations stay bounded, clear, HTTPS and unambiguous',()=>{
  const source=raw(),entry={videoWidth:960,videoHeight:540,disp:{status:'ok',info:'https://cdn.example/current.m3u8'}};
  source.data.stream=[entry];const metadata=m.video(source,'15588271');
  for(const disp of [{status:'error',info:entry.disp.info},{status:'ok',info:entry.disp.info.replace('https:','http:')}]){
    source.data.stream=[{...entry,disp}];assert.equal(m.inline(source,'15588271',metadata).length,0);
  }
  source.data.stream=Array(17).fill(entry);assert.equal(m.inline(source,'15588271',metadata).length,0);
  source.data.stream=[entry,{...entry,videoWidth:1280}];
  assert.equal(m.matchInline(m.inline(source,'15588271',metadata),entry.disp.info),null);
});
test('codec file hints remain bounded and reject malformed codec families',()=>{
  const source=raw();Object.assign(source.data,{stream_domain:['https://dispatch.example/'],
    stream:[{url:'/route?current=1',fileHash:'a'.repeat(32)}]});
  for(const family of [{fileHash:'b'.repeat(32)},Array.from({length:17},(_,i)=>({fileHash:i.toString(16).padStart(32,'0')}))]){
    source.data.stream_h265=family;assert.equal(m.files(source,'15588271',m.video(source,'15588271')).length,0);
  }
  source.data.stream_h265=Array.from({length:16},(_,i)=>({fileHash:i.toString(16).padStart(32,'0')}));
  assert.equal(m.files(source,'15588271',m.video(source,'15588271')).length,0,'AVC plus HEVC cannot exceed the existing 16-file identity budget');
});
const mainBox={};
const player=(extra={})=>({isConnected:true,readyState:2,currentSrc:'blob:current',mediaKeys:null,videoWidth:704,videoHeight:396,duration:4026.56,closest:s=>s==='#mgtv-player-wrap'?mainBox:null,...extra});
const boundData=()=>[{id:'15588271',clear:true,duration:4026,revision:'a1',manifests:['https://new-cdn.example/full.m3u8']}];
const hls=()=>[{kind:'hls',url:'https://new-cdn.example/full.m3u8',original_url:'https://new-cdn.example/full.m3u8'}];
test('main player binding requires current ID, full duration and an actually observed declared HLS',()=>{
  const v=player(),url='https://w.mgtv.com/s/15588271.html';
  assert.equal(m.binding(v,boundData(),hls(),url,[v]).id,'15588271');
  assert.equal(m.binding(v,boundData(),[],url,[v]),null);
  assert.equal(m.binding(v,boundData(),hls(),'https://w.mgtv.com/s/15588272.html',[v]),null);
  for(const extra of [{duration:300},{mediaKeys:{}},{isConnected:false},{currentSrc:'https://cdn.example/file.mp4'},{closest:()=>null}]){
    const other=player(extra);assert.equal(m.binding(other,boundData(),hls(),url,[other]),null);
  }
});
test('sidebar previews do not take ownership and duplicate main players remain ambiguous',()=>{
  const v=player(),preview=player({closest:()=>null}),url='https://w.mgtv.com/s/15588271.html';
  assert.equal(m.owner(boundData(),url,[v,preview]),v);
  assert.equal(m.owner(boundData(),url,[v,player()]),null);
  const other=hls();other[0].url='https://cdn.example/unrelated.m3u8';other[0].original_url=other[0].url;
  assert.equal(m.binding(v,boundData(),other,url,[v]),null);
});

test('a programme trial needs its declared inline source, actual size and duration, rather than trialtime alone',()=>{
  const url='https://www.mgtv.com/b/822501/15588271.html',v=player({duration:300.08,videoWidth:960,videoHeight:540});
  const data=boundData();data[0].trial_duration=300;
  assert.equal(m.binding(v,data,hls(),url,[v]),null);
  data[0].inline_manifests=[{url:hls()[0].url,width:960,height:540}];
  const bound=m.binding(v,data,hls(),url,[v]);
  assert.equal(bound.expected_duration,300);assert.equal(bound.program_duration,4026);assert.equal(bound.preview,true);
  assert.equal(m.binding(v,data,[],url,[v]),null);
  for(const change of [{duration:290},{videoWidth:1280},{mediaKeys:{}}]){
    const other=player({...v,...change});assert.equal(m.binding(other,data,hls(),url,[other]),null);
  }
  const full=player();assert.equal(m.binding(full,data,hls(),url,[full]).expected_duration,4026);
});
test('a separate on-air ad blocks the preloaded main, while an outside preview does not',()=>{
  const v=player({paused:true}),ad=player({duration:15,paused:false,currentSrc:'https://cdn.example/ad.mp4'}),url='https://www.mgtv.com/s/15588271.html';
  assert.equal(m.owner(boundData(),url,[v,ad]),null);
  ad.paused=true;assert.equal(m.owner(boundData(),url,[v,ad]),v);
  ad.paused=false;ad.closest=()=>null;assert.equal(m.owner(boundData(),url,[v,ad]),v);
});
test('a visible paused ad also blocks the parked programme',()=>{
  const v=player({paused:true}),adLayer={},ad=player({paused:true,duration:15,currentSrc:'https://cdn.example/ad.mp4',
    closest:s=>s==='#mgtv-player-wrap'?mainBox:s==='mango-ad-layer, .mango-ad-layer'?adLayer:null});
  assert.equal(m.owner(boundData(),'https://www.mgtv.com/s/15588271.html',[v,ad]),null);
});
