const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const assets=path.join(__dirname,'../../main/assets/web-browser');
const id='rrn:content:films:f9d7a128-fd11-4e0c-9049-77de0f9515bd',page='https://www.redbull.tv/en/page/'+id+'/anytime';
const root='https://related.example:8443/current.m3u8?signature=exact&selector=a%2Fb';
function setup(){
 const video={isConnected:true,videoWidth:1920,videoHeight:1080,duration:3945.0661,currentTime:12,readyState:4,currentSrc:'blob:https://www.redbull.tv/current',getBoundingClientRect:()=>({left:0,top:0,right:1600,bottom:900,width:1600,height:900})};
 const state={videoLoaded:true,isShowingAd:false,durationInSec:3945.066125,playbackPosInSec:12,
  playerConfiguration:{assetId:id},mediaMetaData:{videoId:id,assetId:'different-legacy-id',duration:3945,isLive:false,mediaSrc:{videoUrl:root,mediaType:'hls'}}};
 const vnode={__c:{__H:{__:[{__:[state,()=>{throw Error('dispatch must not run');}]}]}},__k:[]};
 const host={localName:'rbup-video-tv-streaming',isConnected:true,getAttribute:k=>k==='asset-id'?id:null,_root:{__k:{__k:[vnode]}}};
 const shadow={host,querySelectorAll:selector=>selector==='.rbup-video-core-container__player > video'?[video]:[video]};host.shadowRoot=shadow;video.getRootNode=()=>shadow;
 const document={location:{href:page},querySelectorAll:()=>[host]};
 const context=vm.createContext({URL,Date,innerWidth:1600,innerHeight:1000,getComputedStyle:()=>({}),document});
 for(const file of ['tiktok.js','redbull.js'])vm.runInContext(fs.readFileSync(path.join(assets,file),'utf8'),context);
 const api=vm.runInContext('Thru3DRedBull',context),requests=[{kind:'hls',url:root,at:Date.now()}];
 return {api,video,state,host,document,shadow,vnode,requests,bind:()=>api.binding(video,requests,document,[video])};
}
test('Red Bull binds the current full shadow player to its public RRN and exact requested source, ignoring a legacy asset ID',()=>{
 const f=setup(),data=f.bind();assert.equal(data.id,id);assert.equal(data.root,root);assert.equal(data.width,1920);assert.equal(data.duration,3945.0661);
 assert.equal(f.api.page('https://www.redbull.tv.evil/en/page/'+id+'/anytime'),null);
 f.requests[0].url=root.replace('selector=a%2Fb','selector=another');assert.equal(f.bind(),null);
});

test('official homepage region URLs bind the same public RRN without weakening the owner',()=>{
 for(const locale of ['en_US','en_INT','es_LAT','en-US']){
  for(const prefix of ['','page:']){
  const f=setup();f.document.location.href=page.replace('/en/','/'+locale+'/').replace('/page/','/page/'+prefix);
  assert.equal(f.api.page(f.document.location.href).id,id);assert.equal(f.bind().page,f.document.location.href);
  }
 }
 const f=setup();
 for(const value of [page.replace('/en/','/en_us/'),page.replace('/en/','/en_US_extra/'),page.replace('https://','https://user@'),
  page.replace('/page/','/page/page:page:'),page.replace('/page/','/page/other:'),
  page.replace('redbull.tv','redbull.tv:8443'),page+'#other'])assert.equal(f.api.page(value),null);
});
test('Red Bull refuses previews, ads, protection, other content, stale state and ambiguous rendered declarations',()=>{
 for(const change of [f=>f.host.getAttribute=()=>id.replace('f9d7','f9d8'),f=>f.video.getRootNode=()=>({}),
  f=>f.state.isShowingAd=true,f=>f.state.videoLoaded=false,f=>f.state.mediaMetaData.drm={license:'present'},
  f=>f.state.mediaMetaData.isLive=true,f=>f.state.mediaMetaData.videoId='different',f=>f.state.playerConfiguration.assetId='different',
  f=>f.state.durationInSec=15,f=>f.state.playbackPosInSec=50,f=>f.video.mediaKeys={},f=>f.video.currentSrc='blob:https://other.test/current',
  f=>f.requests[0].at=Date.now()-1800001,
  f=>f.host._root.__k.__k.push({__c:{__H:{__:[{__:[{...f.state,mediaMetaData:{...f.state.mediaMetaData,mediaSrc:{videoUrl:root+'&different=1'}}}]}]}}})]){
  const f=setup();change(f);assert.equal(f.bind(),null);
 }
 const f=setup(),advert={...f.video,getRootNode:()=>f.shadow};assert.equal(f.api.binding(f.video,f.requests,f.document,[f.video,advert]),null);
});
test('rendered-state reads never invoke getters, SDK functions or parent/account-store links',()=>{
 const f=setup();let invoked=0;
 Object.defineProperty(f.vnode,'props',{get(){invoked++;throw Error('getter');}});
 f.vnode.__={props:{value:{...f.state,mediaMetaData:{...f.state.mediaMetaData,mediaSrc:{videoUrl:'https://account.test/unrelated'}}}}};
 f.vnode.__c.__H.__.push({__:[{getSource(){invoked++;},storageService:{get(){invoked++;}}}]});
 assert.equal(f.bind().root,root);assert.equal(invoked,0);
});
