const test=require('node:test'),assert=require('node:assert/strict'),vm=require('node:vm'),fs=require('node:fs');
const ctx=vm.createContext({URL,Thru3DTikTok:{own:(o,k)=>o&&typeof o==='object'?Object.getOwnPropertyDescriptor(o,k)?.value:undefined,visible:v=>v.visible!==false,revision:()=> 'a1'}});
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

function hlsFixture(){
  const f=fixture(),root='https://associated-cdn.test:8443/v6/streams/'+claim+'/opaque/master.m3u8?actual=SIGNED';
  const owner={claimId:claim,uri:'lbry://@PublicChannel#2/PublicClip#1',claimValues:{video:{duration:346}},isLivestreamClaim:false,isProtectedContent:false};
  const parent={__reactProps$test:{children:{props:owner}}};
  Object.assign(f.video,{currentSrc:'blob:https://odysee.com/current',parentElement:parent,__reactProps$test:{src:root}});
  f.video._hls={_url:root,_media:f.video};f.requests=[{kind:'hls',url:root,at:Date.now()}];
  return {...f,root,owner,parent};
}
test('HLS binds the committed rendered source, attached media, full claim and actual root request',()=>{
  const f=hlsFixture(),b=O.binding(f.video,f.requests,f.document,[f.video]);
  assert.equal(b.binding,'rendered_hls');assert.equal(b.root,f.root);assert.equal(b.claim_id,claim);assert.equal(b.source,f.video.currentSrc);
  assert.equal(b.expected_duration,346);assert.equal(b.whole_seconds,true);
});
test('HLS rejects another player, uncommitted source, claim, public URI and missing or stale root observation',()=>{
  for(const change of [f=>f.video._hls._media={},f=>f.video.__reactProps$test.src+='&different=1',
    f=>f.owner.claimId='1'+'b'.repeat(39),f=>f.owner.uri=f.owner.uri.replace('PublicClip','NextClip'),
    f=>f.owner.uri='lbry://PublicClip#3',f=>f.document.location.href=page.replace('PublicClip','NextClip'),
    f=>f.video.currentSrc='blob:https://other.test/current',f=>f.requests=[],f=>f.requests[0].url+='&changed=1',
    f=>f.requests[0].kind='file',f=>f.requests[0].at=Date.now()-1800001,f=>f.owner.claimValues.video.duration=345]){
    const f=hlsFixture();change(f);assert.equal(O.binding(f.video,f.requests,f.document,[f.video]),null);
  }
});
test('HLS neither executes getters nor reads a stale alternate Fiber or page-wide declaration',()=>{
  const f=hlsFixture();f.video.__reactFiber$old={memoizedProps:{...f.owner,src:f.root}};
  delete f.parent.__reactProps$test;assert.equal(O.read(f.video,f.document),null);
  Object.defineProperty(f.parent,'__reactProps$test',{get(){throw Error('Do not execute a page getter');}});
  assert.equal(O.read(f.video,f.document),null);
  const g=hlsFixture();Object.defineProperty(g.owner,'claimId',{get(){throw Error('Do not execute a page getter');}});
  assert.equal(O.read(g.video,g.document),null);
});
test('HLS requires known free VOD state and rejects multiple presented players',()=>{
  for(const change of [f=>f.owner.isProtectedContent=true,f=>delete f.owner.isProtectedContent,
    f=>f.owner.isLivestreamClaim=true,f=>delete f.owner.isLivestreamClaim,f=>f.video.mediaKeys={},f=>f.video.seeking=true]){
    const f=hlsFixture();change(f);assert.equal(O.binding(f.video,f.requests,f.document,[f.video]),null);
  }
  const f=hlsFixture();assert.equal(O.binding(f.video,f.requests,f.document,[f.video,{...f.video}]),null);
});
test('HLS reacquires only the new committed claim after the same video changes source',()=>{
  const f=hlsFixture(),old=O.read(f.video,f.document);assert.ok(old);
  f.document.location.href=page.replace('PublicClip','NextClip');f.owner.uri=f.owner.uri.replace('PublicClip','NextClip');
  f.owner.claimId='1'+'b'.repeat(39);assert.equal(O.read(f.video,f.document),null);
  f.video._hls._url=f.root.replace(claim,f.owner.claimId);assert.equal(O.read(f.video,f.document),null);
  f.video.__reactProps$test.src=f.video._hls._url;assert.ok(O.read(f.video,f.document));
  assert.equal(O.binding(f.video,f.requests,f.document,[f.video]),null);
  f.requests[0].url=f.video._hls._url;assert.equal(O.binding(f.video,f.requests,f.document,[f.video]).claim_id,f.owner.claimId);
});

test('an encoded Chinese slug matches the same decoded claim and original requests',()=>{
  const name='西港-黃澤坤-太祖拳雙肩-Kung-Fu_1080p_watermarked_trimmed',encoded=encodeURIComponent(name);
  const f=hlsFixture();f.document.location.href=page.replace('PublicClip',encoded);
  for(const variant of [name,encoded]){
    f.owner.uri='lbry://@PublicChannel#2/'+variant+'#1';
    const current=O.binding(f.video,f.requests,f.document,[f.video]);
    assert.equal(current.id,'@PublicChannel:2/'+encoded+':1');assert.equal(current.root,f.root);
  }
  f.owner.uri='lbry://@PublicChannel#2/'+name+'-別片#1';
  assert.equal(O.binding(f.video,f.requests,f.document,[f.video]),null);
  const g=fixture();g.document.location.href=g.metadata.url=g.canonical[0].href=f.document.location.href;
  g.metadata.contentUrl=declared.replace('PublicClip',encoded);
  assert.equal(O.binding(g.video,g.requests,g.document,[g.video]).source,source);
});

test('escaped separators, malformed UTF-8 and double-encoded slugs stay ineligible',()=>{
  for(const bad of ['%2FOther','%3A1','%23Other','%5COther','%2E%2E-hidden','%E8%FF','%25E8','Title%00']){
    assert.equal(O.page(page.replace('PublicClip',bad)),null);
    assert.equal(O.file(declared.replace('PublicClip',bad)),null);
  }
});

function renderedFileFixture(){
  const f=hlsFixture();f.video.currentSrc=source;delete f.video._hls;f.video.__reactProps$test.src=source;
  f.requests=[{kind:'file',url:source,at:Date.now()}];f.scripts.length=0;f.canonical.length=0;return f;
}
test('rendered MP4 requires no SSR/LDJSON and keeps the exact current file and claim',()=>{
  const f=renderedFileFixture(),b=O.binding(f.video,f.requests,f.document,[f.video]);
  assert.equal(b.binding,'rendered_file');assert.equal(b.source,source);assert.equal(b.declared_source,source);assert.equal(b.file_id,'abcdef.mp4');
  assert.equal(b.claim_id,claim);assert.equal(b.root,undefined);assert.equal(O.hlsDeclaration(f.video,f.document),null);
});
test('rendered file cannot bind old props, another claim, an unobserved signed URL or an unrelated card',()=>{
  for(const change of [f=>f.video.__reactProps$test.src+='&next=1',f=>f.owner.claimId='1'+'b'.repeat(39),
    f=>f.owner.uri=f.owner.uri.replace('PublicClip','NextClip'),f=>f.video.currentSrc=source.replace('abcdef','abcdee'),
    f=>f.requests[0].kind='hls',f=>f.requests[0].url+='&different=1',f=>f.owner.isProtectedContent=true,
    f=>delete f.owner.isLivestreamClaim,f=>f.owner.claimValues.video.duration=345,f=>delete f.parent.__reactProps$test]){
    const f=renderedFileFixture();change(f);assert.equal(O.binding(f.video,f.requests,f.document,[f.video]),null);
  }
});
test('known current protected/live renderer cannot fall back to a static free-file declaration',()=>{
  for(const flag of ['isProtectedContent','isLivestreamClaim']){
    const f=renderedFileFixture();f.scripts.push({textContent:JSON.stringify(f.metadata)});f.canonical.push({href:page});
    assert.ok(O.declaration(f.video,f.document));f.owner[flag]=true;
    assert.equal(O.read(f.video,f.document),null);
  }
});
