const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');
const y=vm.runInNewContext(fs.readFileSync(path.join(__dirname,'../../main/assets/web-browser/youku.js'),'utf8')+'\nThru3DYouku',{URL,getComputedStyle:e=>e.style||{}});
const page='https://v.youku.com/v_show/id_XOTUxMzg4NDMy.html';
const manifest='https://new-related-cdn.example/hls/current.m3u8?signature=exact';
const raw=()=>({api:'mtop.youku.play.ups.appinfo.get',ret:['SUCCESS::调用成功'],data:{e:{code:0},enc:0,data:{
  preview:{thumb:['https://images.example/preview.jpg'],timespan:'1000'},
  video:{encodeid:'XOTUxMzg4NDMy',seconds:702.08,drm_type:'default'},stream:[{drm_type:'default',m3u8_url:manifest,width:960,height:540,milliseconds_video:702079}]}}});
function dom(){
  const box={},layer={},adLayer={style:{},getBoundingClientRect:()=>({width:100,height:60})};
  const main={isConnected:true,readyState:4,currentSrc:'blob:https://v.youku.com/current',duration:702.079,videoWidth:960,videoHeight:540,paused:false,
    closest:s=>s==='#ykPlayer'?box:s==='#ykPlayer .video-layer'?layer:null};
  const ad={isConnected:true,paused:false,ended:false,closest:s=>s==='#ykPlayer'?box:s==='.advertise-layer'?adLayer:null};
  return {main,ad,adLayer};
}
test('observed UPS wrapper binds the public programme ID and full declared duration',()=>{
  const r=y.normalize(y.json('mtopjsonp1('+JSON.stringify(raw())+');'),page);
  assert.equal(r.id,'XOTUxMzg4NDMy');assert.equal(r.duration,702.08);assert.equal(r.streams[0].url,manifest);
  assert.equal(r.streams[0].duration,702.079);
  assert.equal(y.page('https://v.youku.com.evil.example/v_show/id_XOTUxMzg4NDMy.html'),null);
  assert.equal(y.page(page.replace('https:','http:')),null);
});
test('wrong/current episode, encrypted/error metadata and undeclared partial previews are rejected',()=>{
  for(const mutate of [r=>r.data.data.video.encodeid='XOTHER',r=>r.data.enc=1,r=>r.data.e.code=1,
    r=>r.ret=['FAIL::error'],r=>r.data.data.video.drm_type='cbcs',r=>r.data.data.stream[0].drm_type='cbcs',
    r=>r.data.data.stream[0].milliseconds_video=60000,r=>r.data.data.stream[0].m3u8_url='https://user:secret@cdn.example/v.m3u8']){
    const r=raw();mutate(r);assert.equal(y.normalize(r,page),null);
  }
});
test('visible advertising blocks takeover even if its main programme is already loaded',()=>{
  const r=y.normalize(raw(),page),{main,ad,adLayer}=dom();
  assert.equal(y.owner([r],page,[main,ad]),null);
  ad.paused=true;assert.equal(y.owner([r],page,[main,ad]),null);
  adLayer.style.display='none';assert.equal(y.owner([r],page,[main,ad]),main);
  assert.equal(y.owner([r],page,[main,{...main}]),null);
  main.mediaKeys={};assert.equal(y.owner([r],page,[main]),null);
});
test('matches the decoded size and exact observed HLS; never borrows an ad, neighbouring or changed signed URL',()=>{
  const r=y.normalize(raw(),page),{main}=dom();
  const b=y.binding(main,[r],[{kind:'hls',url:manifest}],page,[main]);
  assert.equal(b.manifests[0],manifest);assert.equal(b.declared_drm,'default');
  for(const url of [manifest+'&other=1',manifest.replace('exact','different'),'https://ad.example/ad.m3u8'])
    assert.equal(y.binding(main,[r],[{kind:'hls',url}],page,[main]),null);
  main.videoWidth=640;assert.equal(y.binding(main,[r],[{kind:'hls',url:manifest}],page,[main]),null);
});
test('secure transport upgrade preserves every signed selector and uses only the actual request URL',()=>{
  const r=raw();r.data.data.stream[0].m3u8_url=manifest.replace('https:','http:');
  const {main}=dom(),record=y.normalize(r,page);
  const b=y.binding(main,[record],[{kind:'hls',url:manifest}],page,[main]);
  assert.equal(b.manifests[0],manifest);
  assert.equal(y.sameManifest(manifest,manifest.replace('https:','http:')),false);
  assert.equal(y.sameManifest(record.streams[0].url,manifest+'&new=selector'),false);
  assert.equal(y.sameManifest(record.streams[0].url,manifest.replace('new-related-cdn','other-cdn')),false);
});
