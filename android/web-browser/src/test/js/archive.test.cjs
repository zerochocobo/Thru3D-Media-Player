const test=require('node:test'),assert=require('node:assert/strict'),vm=require('node:vm'),fs=require('node:fs');
const ctx=vm.createContext({URL,Thru3DTikTok:{visible:v=>v.visible!==false,revision:()=> 'a1'}});
vm.runInContext(fs.readFileSync(__dirname+'/../../main/assets/web-browser/archive.js','utf8')+';globalThis.A=Thru3DArchive;',ctx);
const A=ctx.A,page='https://archive.org/details/PublicFilm',source='https://archive.org/download/PublicFilm/current.mp4',file='https://related.test:8443/observed-file?token=ACTUAL';
function fixture(){
  const video={isConnected:true,readyState:4,currentSrc:source,videoWidth:426,videoHeight:240,duration:596.416666};
  const canonical=[{href:page}],links=[{href:source}];
  return {video,canonical,links,document:{location:{href:page},querySelectorAll:s=>s.startsWith('link')?canonical:links},
    requests:[{kind:'file',url:file,original_url:source,at:Date.now()-10}]};
}
test('current decoded item binds through the observed download redirect without rewriting its URL',()=>{
  const f=fixture(),b=A.binding(f.video,f.requests,f.document,[f.video]);assert.equal(b.id,'PublicFilm');assert.equal(b.file,file);assert.equal(b.source,source);
  f.requests=[{kind:'file',url:source,at:Date.now()-10}];assert.equal(A.binding(f.video,f.requests,f.document,[f.video]).file,source);
});
test('unrelated file, request chain, item, protection and ambiguous players cannot bind',()=>{
  for(const change of [f=>f.links.length=0,f=>f.links[0].href=source+'?different=1',f=>f.canonical[0].href=page+'Other',
    f=>f.document.location.href=page+'Other',f=>f.requests[0].original_url=source+'?different=1',
    f=>f.requests[0].url='http://related.test/file',f=>f.requests[0].at=Date.now()-1800001,
    f=>f.video.mediaKeys={},f=>f.video.seeking=true,f=>f.video.visible=false]){
    const f=fixture();change(f);assert.equal(A.binding(f.video,f.requests,f.document,[f.video]),null);
  }
  const f=fixture();assert.equal(A.binding(f.video,f.requests,f.document,[f.video,{...f.video}]),null);
});
test('only the newest exact download chain is selected; simultaneous conflicting results reject',()=>{
  const f=fixture(),old=f.requests[0];f.requests.push({...old,url:file+'&rotation=2',at:old.at+1});
  assert.equal(A.binding(f.video,f.requests,f.document,[f.video]).file,file+'&rotation=2');
  f.requests.push({...old,url:file+'&rotation=3',at:old.at+1});assert.equal(A.binding(f.video,f.requests,f.document,[f.video]),null);
});
test('official detail pages and current item download paths are required',()=>{
  for(const bad of [page.replace('https:','http:'),page.replace('archive.org','archive.org.evil'),page.replace('https://','https://user@'),page+'#other','https://archive.org/details/..'])assert.equal(A.page(bad),null);
  for(const bad of [source.replace('PublicFilm','OtherItem'),source.replace('/current.mp4','/folder/current.mp4'),source.replace('archive.org','other.test')]){
    const f=fixture();f.video.currentSrc=bad;f.links[0].href=bad;assert.equal(A.declaration(f.video,f.document),null);
  }
});
