const test=require('node:test'),assert=require('node:assert/strict'),vm=require('node:vm'),fs=require('node:fs');
const ctx=vm.createContext({URL,Thru3DTikTok:{visible:v=>v.visible!==false,revision:()=> 'a1'}});
for(const name of ['streamable','odysee'])vm.runInContext(fs.readFileSync(__dirname+'/../../main/assets/web-browser/'+name+'.js','utf8'),ctx);
vm.runInContext('globalThis.O=Thru3DOdysee;',ctx);const O=ctx.O;
const page='https://odysee.com/@PublicChannel:2/PublicClip:1',claim='1'+'a'.repeat(39),source='https://related.test:8443/v6/streams/'+claim+'/abcdef.mp4?token=ACTUAL',declared='https://other-related.test/api/v3/streams/free/PublicClip/'+claim+'/abcdef.mp4';
function fixture(){
  const metadata={'@type':'VideoObject',url:page,contentUrl:declared,duration:'PT5M46S'};
  const canonical=[{href:page}],scripts=[{get textContent(){return JSON.stringify(metadata);}}];
  const video={isConnected:true,readyState:4,currentSrc:source,videoWidth:1280,videoHeight:720,duration:346.72};
  return {metadata,canonical,scripts,video,document:{location:{href:page},querySelectorAll:s=>s.startsWith('link')?canonical:scripts},requests:[{kind:'file',url:source,at:Date.now()}]};
}
test('binds the current decoded claim and exact observed URL across the actual declared/free and v6 formats',()=>{
  const f=fixture(),b=O.binding(f.video,f.requests,f.document,[f.video]);assert.equal(b.id,'@PublicChannel:2/PublicClip:1');assert.equal(b.source,source);assert.equal(b.claim_id,claim);assert.equal(b.expected_duration,346);
  f.video.currentSrc=declared;f.requests[0].url=declared;assert.equal(O.binding(f.video,f.requests,f.document,[f.video]).source,declared);
});
test('wrong item, original file, public prefix or request selector cannot bind',()=>{
  for(const mutate of [f=>f.metadata.url=page.replace('PublicClip','OtherClip'),f=>f.canonical[0].href=page.replace(':1',':3'),
    f=>f.metadata.contentUrl=declared.replace(claim,'1'+'b'.repeat(39)),f=>f.metadata.contentUrl=declared.replace('abcdef.mp4','abcdee.mp4'),
    f=>f.metadata.contentUrl=declared.replace('/free/','/paid/'),f=>f.video.currentSrc=source.replace('ACTUAL','OTHER'),
    f=>f.document.location.href=page.replace(':1',':3'),f=>f.requests=[]]){
    const f=fixture();mutate(f);assert.equal(O.binding(f.video,f.requests,f.document,[f.video]),null);
  }
});
test('whole-second metadata keeps its exact second while explicit fractional duration remains bounded',()=>{
  const f=fixture();f.video.duration=347;assert.equal(O.read(f.video,f.document),null);
  f.video.duration=345.99;assert.equal(O.read(f.video,f.document),null);
  f.video.duration=346.72;f.metadata.duration='PT5M46.72S';assert.ok(O.read(f.video,f.document));
  f.metadata.duration='PT5M48.72S';assert.equal(O.read(f.video,f.document),null);
});
test('protected, hidden, seeking, ambiguous or expired video is never an eligible player',()=>{
  for(const mutate of [f=>f.video.mediaKeys={},f=>f.video.seeking=true,f=>f.video.visible=false,f=>f.requests[0].at=Date.now()-1800001]){
    const f=fixture();mutate(f);assert.equal(O.binding(f.video,f.requests,f.document,[f.video]),null);
  }
  const f=fixture();assert.equal(O.binding(f.video,f.requests,f.document,[f.video,{...f.video}]),null);
});
test('metadata is parsed as bounded data and official document identity is required',()=>{
  for(const bad of [page.replace('https:','http:'),page.replace('odysee.com','odysee.com.evil'),page.replace('https://','https://user@'),page+'#other'])assert.equal(O.page(bad),null);
  const f=fixture();f.scripts[0]={textContent:'{"@type":"VideoObject"};execute()'};assert.equal(O.declaration(f.video,f.document),null);
  f.scripts[0]={textContent:' '.repeat(64*1024+1)};assert.equal(O.declaration(f.video,f.document),null);
});
