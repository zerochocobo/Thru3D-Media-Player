const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm'),path=require('node:path');
const root=path.join(__dirname,'../../main/assets/web-browser'),id='6961737553342991651',other='6961737553342991652';
const first='https://associated.test/first.mp4?signature=synthetic',second='https://associated.test/second.mp4?signature=synthetic';
function fixture(){
 const signal=()=>({listeners:[],addListener(fn){this.listeners.push(fn)},emit(m){this.listeners.forEach(fn=>fn(m))}});
 const timers=[],ports=[],events={},buttons=[];let ownerId=id;
 const raw=(id,url)=>({awemeId:id,video:{duration:25000,width:1280,height:720,playAddr:[{src:url}]}});
 const props={awemeInfo:raw(id,first)},owner={parentElement:null,getAttribute:k=>k==='data-e2e-vid'?ownerId:k==='data-e2e'?'feed-active-video':null,'__reactProps$fixture':props};
 const listeners={},video={parentElement:owner,getAttribute:()=>null,closest:()=>null,currentSrc:'blob:https://www.douyin.com/same',isConnected:true,
   videoWidth:1280,videoHeight:720,duration:25,currentTime:3,readyState:4,paused:false,ended:false,seeking:false,
   addEventListener(n,f){(listeners[n]??=[]).push(f)},pause(){this.paused=true},play(){this.paused=false;for(const f of listeners.play||[])f();return Promise.resolve()},
   getBoundingClientRect:()=>({left:0,top:0,right:1280,bottom:720,width:1280,height:720})};
 const body={append(o){o.parentElement=this}},document={nodeType:9,body,querySelectorAll:s=>s==='video'?[video]:[],createElement:()=>({dataset:{},style:{},remove(){this.removed=true}})};
 const context={URL,document,location:{href:'https://www.douyin.com/'},navigator:{userAgent:'fixture'},setTimeout(fn){timers.push(fn)},
   addEventListener(n,f){(events[n]??=[]).push(f)},performance:{now:()=>0,getEntriesByType:()=>[]},MutationObserver:class{observe(){}disconnect(){}},
   Thru3DPlayButton:{visible:()=>true,create(doc,overlay,site,clicked){const host={dataset:{},isConnected:true,hidden:false};buttons.push({host,clicked});return {host,enabled(){},dispose(){host.isConnected=false}}}},
   browser:{runtime:{connect(){const p={onMessage:signal(),onDisconnect:signal(),postMessage(){}};ports.push(p);return p},
     connectNative(){const p={onMessage:signal(),onDisconnect:signal(),messages:[],postMessage(m){this.messages.push(m)}};ports.push(p);return p}}}};
 vm.createContext(context);for(const name of ['douyin.js','douyin-current.js','media.js'])vm.runInContext(fs.readFileSync(path.join(root,name),'utf8'),context);
 const flush=()=>{let n=0;while(timers.length){assert.ok(++n<100);timers.shift()()}};flush();
 const native=ports.find(p=>p.messages),network=ports.find(p=>!p.messages);
 native.onMessage.emit({action:'network_policy',douyin:true});flush();
 network.onMessage.emit({type:'network',page:context.location.href,candidates:[{kind:'file',url:first},{kind:'file',url:second}],douyin:[]});flush();
 const latest=()=>native.messages.at(-1).videos[0],snapshot=()=>{native.onMessage.emit({action:'snapshot'});return latest()};
 const click=(host=buttons.at(-1).host,trusted=true)=>{for(const fn of events.click||[])fn({isTrusted:trusted,composedPath:()=>[host],preventDefault(){},stopImmediatePropagation(){}});flush();return latest()};
 return {video,native,latest,snapshot,click,buttons,flush,switchOwner(update=true){ownerId=other;if(update)props.awemeInfo=raw(other,second)}};
}
test('trusted current-card click works, preloaded files and same-Blob owner switches cannot reuse an old action',()=>{
 const f=fixture(),before=f.latest();assert.equal(before.douyin_ready,true);assert.equal(before.douyin_request,0);
 assert.equal(f.click(undefined,false).douyin_request,0);assert.equal(f.click().douyin_request,1);
 const old=f.buttons.at(-1).host;f.switchOwner(false);assert.equal(f.click(old).douyin_request,1);
 // The click above cannot nominate another owner; a fresh snapshot invalidates it.
 assert.equal(f.snapshot().douyin_ready,false);f.switchOwner();const after=f.snapshot();
 assert.equal(after.douyin.id,other);assert.notEqual(after.network_epoch,before.network_epoch);assert.equal(after.douyin_request,0);
 assert.equal(f.click(old).douyin_request,0);assert.equal(f.click().douyin_request,2);
 assert.equal(f.latest().douyin.observed_file,second);
});
test('retained pause lease and return keep the bound page paused, reject stale revisions and never seek a replacement owner',()=>{
 const f=fixture(),initial=f.latest(),message={action:'restore_douyin',id:String(initial.id),epoch:initial.network_epoch,page:initial.frame,revision:initial.douyin.revision,time:20,play:false};
 f.native.onMessage.emit({action:'pause_media',token:5,playing_ids:[String(initial.id)]});f.flush();assert.equal(f.video.paused,true);
 f.native.onMessage.emit({action:'suspend',keep_pause:true,pause_token:5});f.native.onMessage.emit({action:'resume'});
 f.native.onMessage.emit({action:'release_pause_media',token:5,play:false});f.native.onMessage.emit({...message,revision:'bad'});assert.equal(f.video.currentTime,3);
 f.native.onMessage.emit(message);f.flush();assert.equal(f.video.currentTime,20);f.video.play();f.flush();assert.equal(f.video.paused,true);
 f.switchOwner();f.snapshot();f.video.currentTime=1;f.native.onMessage.emit(message);assert.equal(f.video.currentTime,1);
 f.video.play();f.flush();assert.equal(f.video.paused,false,'the return hold must not pause another programme');
});
