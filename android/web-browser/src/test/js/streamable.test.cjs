const test=require('node:test'),assert=require('node:assert/strict'),vm=require('node:vm'),fs=require('node:fs');
const ctx=vm.createContext({URL,Thru3DTikTok:{visible:v=>v.visible!==false,revision:()=> 'a1'}});
vm.runInContext(fs.readFileSync(__dirname+'/../../main/assets/web-browser/streamable.js','utf8')+';globalThis.S=Thru3DStreamable;',ctx);
const S=ctx.S,page='https://streamable.com/abc123',source='https://related.test:8443/video/mp4/abc123.mp4?token=ACTUAL';
function fixture(){
  const metadata={'@type':'VideoObject',contentUrl:source,duration:'PT14.4144S'};
  const video={isConnected:true,readyState:4,currentSrc:source,videoWidth:1280,videoHeight:720,duration:14.42};
  const canonical=[{href:page}],scripts=[{get textContent(){return JSON.stringify(metadata);}}];
  return {metadata,video,canonical,scripts,document:{location:{href:page},querySelectorAll:s=>s.startsWith('link')?canonical:scripts},requests:[{kind:'file',url:source,at:Date.now()}]};
}
test('binds the decoded clip to its public canonical item, exact rendered file and actual request',()=>{
  const f=fixture(),b=S.binding(f.video,f.requests,f.document,[f.video]);assert.equal(b.id,'abc123');assert.equal(b.source,source);assert.equal(b.expected_duration,14.4144);
  assert.equal(S.page('https://streamable.com.evil/abc123'),null);assert.equal(S.page('https://user@streamable.com/abc123'),null);
  assert.equal(S.page('https://streamable.com/e/abc123'),null);
});
test('another item, stale canonical declaration, substituted file, duration or protected/ambiguous player is rejected',()=>{
  for(const mutate of [f=>f.canonical[0].href='https://streamable.com/other1',f=>f.document.location.href='https://streamable.com/other1',
    f=>f.video.currentSrc=source.replace('ACTUAL','OTHER'),f=>f.metadata.contentUrl=source.replace('abc123','other1'),
    f=>f.metadata.duration='PT20S',f=>f.video.mediaKeys={},f=>f.video.visible=false,f=>f.video.seeking=true,f=>f.requests=[]]){
    const f=fixture();mutate(f);assert.equal(S.binding(f.video,f.requests,f.document,[f.video]),null);
  }
  const f=fixture();assert.equal(S.binding(f.video,f.requests,f.document,[f.video,{...f.video}]),null);
  f.requests[0].at=Date.now()-1800001;assert.equal(S.binding(f.video,f.requests,f.document,[f.video]),null);
});
test('duration parsing and rendered declaration reads are bounded and do not execute embedded code',()=>{
  assert.equal(S.seconds('PT1H2M3.25S'),3723.25);
  for(const text of ['PT','-1','PT0S','P1D','PT25H','PT14S;execute()'])assert.equal(S.seconds(text),0);
  const f=fixture();f.scripts[0]={textContent:'{"@type":"VideoObject"};execute()'};
  assert.equal(S.declaration(f.video,f.document),null);f.scripts[0]={textContent:' '.repeat(64*1024+1)};
  assert.equal(S.declaration(f.video,f.document),null);
});
