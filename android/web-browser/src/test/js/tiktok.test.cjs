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
  videoWidth:540,videoHeight:960,duration:27.533333,closest:()=>card,
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
test('other clip, advert, protected media and stale runtime source cannot borrow the active file',()=>{
 const changes=[f=>f.item.id='6742501081818877191',f=>f.source.id='6742501081818877191',f=>f.source.groupId='other',f=>f.item.isAd=true,
  f=>f.source.hasDrm=true,f=>f.v.mediaKeys={},f=>f.v.seeking=true,f=>f.v.ended=true,f=>f.v.videoHeight=720,f=>f.v.style={visibility:'hidden'}];
 for(const change of changes){const f=fixture();change(f);assert.equal(t.binding(f.v,f.requests,page,[f.v]),null);}
});
test('alternative qualities and unrelated audio are never selected for the active video',()=>{
 const f=fixture();for(const value of ['https://other.example/alternative','https://music.example/unrelated',url+'&extra=1'])
  assert.equal(t.binding(f.v,[{url:value,kind:'file',at:Date.now()}],page,[f.v]),null);
 for(const change of [{kind:'hls'},{at:Date.now()-1800001},{at:Date.now()+1000}])assert.equal(t.binding(f.v,[{...f.requests[0],...change}],page,[f.v]),null);
});
test('integer SDK duration must be the actual decoded whole second and cannot cover a different clip',()=>{
 const f=fixture();assert.notEqual(t.read(f.v,page),null);
 for(const seconds of [26.99,28,0,Infinity]){f.v.duration=seconds;assert.equal(t.read(f.v,page),null);}
});
test('ambiguous cards or visible second players stay unbound and getters are not invoked',()=>{
 const f=fixture();assert.equal(t.binding(f.v,f.requests,page,[f.v,{...f.v}]),null);
 f.card.querySelectorAll=()=>[f.v,{}];assert.equal(t.read(f.v,page),null);
 f.card.querySelectorAll=()=>[f.v];let called=0;Object.defineProperty(f.source,'url',{get(){called++;throw Error('not data');}});
 assert.equal(t.read(f.v,page),null);assert.equal(called,0);
});
