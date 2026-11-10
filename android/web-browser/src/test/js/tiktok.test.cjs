const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const t=vm.runInNewContext(fs.readFileSync(path.join(__dirname,'../../main/assets/web-browser/tiktok.js'),'utf8')+'\nThru3DTikTok',
 {URL,Date,getComputedStyle:v=>v.style||{},innerWidth:1600,innerHeight:1000});
const id='6742501081818877190',page='https://www.tiktok.com/@patroxofficial/video/'+id,url='https://actual-related.example/media?sig=exact&quality=current';
function fixture(){
 const item={id,video:{width:540,height:960,duration:27}},source={id,vid:id,groupId:id,width:540,height:960,duration:27,url:[url],
  bitrateList:[{id,width:540,height:960,url:['https://other.example/alternative']}],audioBitrateList:[{url:['https://music.example/unrelated']}]};
 const card={isConnected:true,parentElement:null,__reactProps$fixture:{children:[{props:{children:[{props:{item}}]}}]},querySelectorAll:()=>[v]};
 const parent={parentElement:card,__reactProps$fixture:{children:[{props:{videoSource:source}}]}};
 const v={isConnected:true,parentElement:parent,mediaKeys:null,seeking:false,ended:false,readyState:4,currentSrc:'blob:https://www.tiktok.com/current',
  videoWidth:540,videoHeight:960,duration:27.533333,currentTime:3.5,closest:()=>card,
  getBoundingClientRect:()=>({left:100,top:20,right:640,bottom:980,width:540,height:960})};
 const requests=[{url,kind:'file',at:Date.now(),headers:{authorization:'own-request'}}];return {v,card,parent,item,source,requests};
}
test('trusted detail identity rejects other hosts, feeds, encoded IDs and credentials',()=>{
 assert.equal(t.page(page).id,id);
 for(const bad of [page.replace('https:','http:'),page.replace('www.tiktok.com','www.tiktok.com.evil'),page+'#other','https://user@www.tiktok.com/@patroxofficial/video/'+id,
  'https://www.tiktok.com/','https://www.tiktok.com/@patroxofficial','https://www.tiktok.com/@patroxofficial/video/%36'+id.slice(1)])assert.equal(t.page(bad),null,bad);
});
test('nearest rendered source, article item and exact actual request agree without API signing',()=>{
 const f=fixture(),b=t.binding(f.v,f.requests,page,[f.v]);assert.equal(b.id,id);assert.equal(b.source,url);assert.equal(b.expected_duration,27);
 assert.equal(f.requests[0].headers.authorization,'own-request');
 const raw={...f.parent};f.parent.wrappedJSObject=raw;delete f.parent.__reactProps$fixture;
 assert.equal(t.binding(f.v,f.requests,page,[f.v]).id,id,'Gecko waived React data uses the same descriptor path');
});

test('safe readiness diagnostics expose duration mismatches without relaxing the binding or copying private addresses',()=>{
 const f=fixture(),state={};f.source.duration=30;
 assert.equal(t.binding(f.v,f.requests,page,[f.v],state),null);
 assert.equal(state.status,'decoded_shape');assert.equal(state.expected_duration,30);assert.equal(state.decoded_duration,27.533333);
 assert.equal(state.public_id,id);assert.equal(JSON.stringify(state).includes('sig='),false);
 f.source.duration=27;assert.equal(t.binding(f.v,f.requests,page,[f.v],state).id,id);assert.equal(state.status,'bound');
});
test('advertising diagnostics follow the existing exclusion and never convert an advert into a playable card',()=>{
 const f=fixture(),state={};f.item.isAd=true;
 assert.equal(t.binding(f.v,f.requests,page,[f.v],state),null);
 assert.equal(state.status,'excluded_content');assert.equal(state.advertisement,true);
});

test('static feed binds the nearest rendered item and preserves its real document separately',()=>{
 const f=fixture();f.item.author='patroxofficial';
 const b=t.binding(f.v,f.requests,'https://www.tiktok.com/',[f.v]);
 assert.equal(b.id,id);assert.equal(b.page,page);assert.equal(b.document,'https://www.tiktok.com/');assert.equal(b.active_id,id);assert.equal(b.binding,'rendered_card');
 f.item.author={uniqueId:'patroxofficial'};assert.equal(t.binding(f.v,f.requests,'https://www.tiktok.com/foryou',[f.v]).page,page);
 for(const bad of [undefined,'',{},'bad/name']){f.item.author=bad;assert.equal(t.binding(f.v,f.requests,'https://www.tiktok.com/',[f.v]),null);}
 f.item.author='patroxofficial';f.source.id='6742501081818877191';assert.equal(t.binding(f.v,f.requests,'https://www.tiktok.com/',[f.v]),null);
});

test('Explore inline previews bind one real card link, item owner, nearest source and actual request',()=>{
 const f=fixture();f.item.author={uniqueId:'patroxofficial'};f.card.href=page;
 f.v.closest=selector=>selector==='a[href]'?f.card:null;
 for(const document of ['https://www.tiktok.com/explore','https://www.tiktok.com/explore/']){
  const bound=t.binding(f.v,f.requests,document,[f.v]);
  assert.equal(bound.page,page);assert.equal(bound.document,document);assert.equal(bound.binding,'rendered_card');
 }
 for(const change of [()=>f.card.href=page.replace('@patroxofficial','@another_author'),
  ()=>f.card.href=page.replace(id,'6742501081818877191'),()=>f.card.href='https://other.test/'+id,
  ()=>f.card.href=page+'#different']){
  f.card.href=page;change();assert.equal(t.binding(f.v,f.requests,'https://www.tiktok.com/explore',[f.v]),null);
 }
 f.card.href=page;f.item.author={};assert.equal(t.binding(f.v,f.requests,'https://www.tiktok.com/explore',[f.v]),null);
});

test('canonical div detail uses only its nearest single-video item owner and cannot borrow an outer item',()=>{
 const f=fixture();f.v.closest=()=>null;
 assert.equal(t.binding(f.v,f.requests,page,[f.v]).id,id);
 f.v.closest=()=>({querySelectorAll:()=>[f.v,{...f.v}]});
 assert.equal(t.binding(f.v,f.requests,page,[f.v]).id,id,'an outer feed article is not the nearer single-item owner');
 f.parent.__reactProps$fixture.children.push({props:{item:{...f.item,id:'6742501081818877191'}}});
 assert.equal(t.binding(f.v,f.requests,page,[f.v]),null,'wrong nearer owner cannot fall through to the valid outer card');
 f.parent.__reactProps$fixture.children.pop();f.card.querySelectorAll=()=>[f.v,{...f.v}];
 assert.equal(t.binding(f.v,f.requests,page,[f.v]),null,'a multi-video parent is not an item owner');
});

test('a queued offscreen next video inside the detail owner cannot remove the current action',()=>{
 const f=fixture();f.v.closest=()=>null;
 const next={...f.v,getBoundingClientRect:()=>({left:100,top:1000,right:640,bottom:1960,width:540,height:960})};
 f.card.querySelectorAll=()=>[f.v,next];
 assert.equal(t.binding(f.v,f.requests,page,[f.v,next]).id,id);
 next.getBoundingClientRect=()=>({left:700,top:20,right:1240,bottom:980,width:540,height:960});
 assert.equal(t.read(f.v,page),null,'two presented videos inside the item remain ambiguous');
});

test('preview support does not accept another card, protected or unobserved files, or unrelated grid documents',()=>{
 const f=fixture();f.item.author='patroxofficial';f.card.href=page;f.v.closest=s=>s==='a[href]'?f.card:null;
 assert.equal(t.binding(f.v,[],'https://www.tiktok.com/explore',[f.v]),null);
 for(const document of ['https://www.tiktok.com/search','https://www.tiktok.com/explore/other','https://www.tiktok.com/@patroxofficial',
  'https://www.tiktok.com/explore#other','https://other.test/explore'])assert.equal(t.binding(f.v,f.requests,document,[f.v]),null);
 f.item.isAd=true;assert.equal(t.binding(f.v,f.requests,'https://www.tiktok.com/explore',[f.v]),null);f.item.isAd=false;
 f.source.hasDrm=true;assert.equal(t.binding(f.v,f.requests,'https://www.tiktok.com/explore',[f.v]),null);f.source.hasDrm=false;
 f.card.querySelectorAll=()=>[f.v,{...f.v}];assert.equal(t.binding(f.v,f.requests,'https://www.tiktok.com/explore',[f.v]),null);
});

test('a feed cannot borrow the next card or a profile, search, photo or foreign document',()=>{
 const f=fixture();f.item.author='patroxofficial';
 for(const bad of ['https://www.tiktok.com/@patroxofficial','https://www.tiktok.com/search','https://www.tiktok.com/@patroxofficial/photo/'+id,'https://tiktok.example/','https://www.tiktok.com/#other'])
  assert.equal(t.binding(f.v,f.requests,bad,[f.v]),null,bad);
 assert.equal(t.binding(f.v,f.requests,'https://www.tiktok.com/',[f.v,{...f.v}]),null);
 f.item.isAd=true;assert.equal(t.binding(f.v,f.requests,'https://www.tiktok.com/',[f.v]),null);
});
test('other clip, advert, protected media and stale runtime source cannot borrow the active file',()=>{
 const changes=[f=>f.item.id='6742501081818877191',f=>f.source.id='6742501081818877191',f=>f.source.groupId='other',f=>f.item.isAd=true,
  f=>f.source.hasDrm=true,f=>f.v.mediaKeys={},f=>f.v.seeking=true,f=>f.v.videoHeight=720,f=>f.v.style={visibility:'hidden'}];
 for(const change of changes){const f=fixture();change(f);assert.equal(t.binding(f.v,f.requests,page,[f.v]),null);}
});

test('an ended short clip keeps its own Beta replay action and starts at zero',()=>{
 const f=fixture();assert.equal(t.binding(f.v,f.requests,page,[f.v]).start_seconds,3.5);
 f.v.ended=true;f.v.currentTime=f.v.duration;assert.equal(t.binding(f.v,f.requests,page,[f.v]).start_seconds,0);
});

test('a decoded next-card sliver cannot hide the current player or acquire its button',()=>{
 const f=fixture(),next={...f.v,getBoundingClientRect:()=>({left:100,top:990,right:640,bottom:1950,width:540,height:960})};
 assert.notEqual(t.binding(f.v,f.requests,page,[f.v,next]),null);assert.equal(t.read(next,page),null);
 next.getBoundingClientRect=()=>({left:700,top:20,right:1240,bottom:980,width:540,height:960});
 assert.equal(t.binding(f.v,f.requests,page,[f.v,next]),null,'two substantially presented players remain ambiguous');
});
test('alternative qualities and unrelated audio are never selected for the active video',()=>{
 const f=fixture();for(const value of ['https://other.example/alternative','https://music.example/unrelated',url+'&extra=1'])
  assert.equal(t.binding(f.v,[{url:value,kind:'file',at:Date.now()}],page,[f.v]),null);
 for(const change of [{kind:'hls'},{at:Date.now()-1800001},{at:Date.now()+1000}])assert.equal(t.binding(f.v,[{...f.requests[0],...change}],page,[f.v]),null);
});
test('approximate integer SDK time uses the existing bounded file budget without admitting invalid durations',()=>{
 const f=fixture();assert.notEqual(t.read(f.v,page),null);
 for(const seconds of [25,26.99,28,29]){f.v.duration=seconds;assert.notEqual(t.read(f.v,page),null);}
 for(const seconds of [24.999,29.001,0,Infinity]){f.v.duration=seconds;assert.equal(t.read(f.v,page),null);}
 f.source.duration=14;f.v.duration=15.136553;assert.notEqual(t.read(f.v,page),null);
 f.source.duration=6;f.v.duration=5.783;assert.notEqual(t.read(f.v,page),null);
 f.source.duration=5.5;assert.equal(t.read(f.v,page),null);
});
test('ambiguous cards or visible second players stay unbound and getters are not invoked',()=>{
 const f=fixture();assert.equal(t.binding(f.v,f.requests,page,[f.v,{...f.v}]),null);
 f.card.querySelectorAll=()=>[f.v,{}];assert.equal(t.read(f.v,page),null);
 f.card.querySelectorAll=()=>[f.v];let called=0;Object.defineProperty(f.source,'url',{get(){called++;throw Error('not data');}});
 assert.equal(t.read(f.v,page),null);assert.equal(called,0);
});
