const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const context=vm.createContext({URL,Date,getComputedStyle:v=>v.style||{},innerWidth:1600,innerHeight:1000});
for(const name of ['tiktok.js','ted.js'])vm.runInContext(fs.readFileSync(path.join(__dirname,'../../main/assets/web-browser',name),'utf8'),context);
const t=vm.runInContext('Thru3DTed',context),page='https://www.ted.com/talks/current_talk',root='https://new-related.example/root.m3u8?exact=selection';
function fixture(){
 const model={id:'86532',slug:'current_talk',duration:679,hlsUrl:root,videoPlayerData:{id:'416668',duration:676,external:null}};
 const container={parentElement:null,querySelectorAll:()=>[v],__reactProps$fixture:{children:{props:{video:model}}}};
 const v={id:'video',parentElement:container,isConnected:true,currentSrc:'blob:https://www.ted.com/current',videoWidth:1280,videoHeight:720,duration:679.973,readyState:4,
  closest:s=>s==='#video-player-container'?container:null,getBoundingClientRect:()=>({left:100,top:100,right:900,bottom:700,width:800,height:600})};
 const requests=[{kind:'hls',url:root,at:Date.now()}];return {v,model,container,requests};
}
test('rendered talk/root uses the actual top-level duration without equating distinct player IDs',()=>{
 const f=fixture(),b=t.binding(f.v,f.requests,page,[f.v]);assert.equal(b.id,'current_talk');assert.equal(b.talk_id,'86532');assert.equal(b.player_id,'416668');assert.equal(b.expected_duration,679);
 assert.equal(b.root,root);f.v.paused=true;assert.equal(t.binding(f.v,f.requests,page,[f.v]).revision,b.revision);
 f.model.videoPlayerData.external={service:'external-alternative',code:'unrelated'};
 assert.equal(t.binding(f.v,f.requests,page,[f.v]).root,root);
});
test('wrong talk, source, protection, ad and replacement cannot borrow the HLS request',()=>{
 for(const change of [f=>f.model.slug='next_talk',f=>f.model.duration=676,f=>f.model.hlsUrl=root+'&changed=1',f=>f.model.isAd=true,
  f=>{f.model.videoPlayerData.external={service:'external-alternative'};delete f.model.hlsUrl;},f=>f.v.mediaKeys={},f=>f.v.currentSrc='blob:https://other.example/video',
  f=>f.v.seeking=true,f=>f.v.ended=true,f=>f.v.id='ad-video',f=>f.v.style={visibility:'hidden'}]){
  const f=fixture();change(f);assert.equal(t.binding(f.v,f.requests,page,[f.v]),null);
 }
});
test('unobserved roots, changed signed selectors and another visible video stay in the page',()=>{
 const f=fixture();for(const r of [{url:root+'&different=1'},{kind:'file'},{at:Date.now()-1800001},{at:Date.now()+1000}])
  assert.equal(t.binding(f.v,[{...f.requests[0],...r}],page,[f.v]),null);
 assert.equal(t.binding(f.v,f.requests,page,[f.v,{...f.v}]),null);
 assert.equal(t.page('https://www.ted.com.evil/talks/current_talk'),null);assert.equal(t.page(page+'#different'),null);
});
test('nearest rendered model and data properties reject conflicting metadata or invoked getters',()=>{
 const f=fixture();let calls=0;Object.defineProperty(f.model,'hlsUrl',{get(){calls++;return root;}});
 assert.equal(t.binding(f.v,f.requests,page,[f.v]),null);assert.equal(calls,0);
});
