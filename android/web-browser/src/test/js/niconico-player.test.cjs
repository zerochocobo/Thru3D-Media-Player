const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const assets=path.join(__dirname,'../../main/assets/web-browser'),ctx=vm.createContext({URL});
vm.runInContext(fs.readFileSync(path.join(assets,'niconico.js'),'utf8')+'\n'+fs.readFileSync(path.join(assets,'niconico-player.js'),'utf8')+';globalThis.sdk=Thru3DNiconicoPlayer;',ctx);
function fixture(scale=1){
  const page='https://www.nicovideo.jp/watch/sm9',stage={parentElement:null},calls=[];let position=20;
  const video={parentElement:stage,isConnected:true,currentSrc:'blob:https://www.nicovideo.jp/current',duration:100,paused:false};
  Object.defineProperty(video,'currentTime',{get:()=>position,set(){throw new Error('Direct MSE seek must not be used');}});
  const control={stage,isDisposed:false,pause(){calls.push('pause');video.paused=true;},play(){calls.push('play');video.paused=false;},
    seek(){throw new Error('The operation-based seek API must not receive a number');},
    setCurrentTime(value){calls.push(['setCurrentTime',value]);position=value/scale;},getCurrentTime:()=>position*scale,getVideoDuration:()=>100*scale};
  stage['__reactFiber$fixture']={return:{memoizedState:{next:{next:{memoizedState:[control]}}}}};
  return {video,control,calls,dom:{location:{href:page}},data:{page,id:'sm9',duration:100}};
}
test('bound rendered SDK receives an absolute position through its own MSE loader',()=>{
  const f=fixture();assert.equal(ctx.sdk.pause(f.video,f.data,f.dom),true);f.calls.length=0;
  assert.equal(ctx.sdk.restore(f.video,f.data,f.dom,50,false),true);
  assert.deepEqual(f.calls,['pause',['setCurrentTime',50],'pause']);assert.equal(f.video.currentTime,50);assert.equal(f.video.paused,true);
});
test('milliseconds are inferred from the programme duration and failure return may resume deliberately',()=>{
  const f=fixture(1000);assert.equal(ctx.sdk.restore(f.video,f.data,f.dom,50,true),true);
  assert.deepEqual(f.calls,['pause',['setCurrentTime',50000],'play']);assert.equal(f.video.currentTime,50);assert.equal(f.video.paused,false);
});
test('unbound stage, disposed controller, mismatched programme or clock cannot operate the page',()=>{
  for(const change of [f=>{f.control.stage={};},f=>{f.control.isDisposed=true;},f=>{f.data.id='sm10';},
    f=>{f.dom.location.href+='?new';},f=>{f.control.getCurrentTime=()=>90;}]){
    const f=fixture();change(f);assert.equal(ctx.sdk.restore(f.video,f.data,f.dom,50,false),false);assert.equal(f.calls.length,0);
  }
});
test('read-only discovery never invokes an accessor and a synchronous replacement stops before seek',()=>{
  const f=fixture();let getters=0;Object.defineProperty(f.control,'stage',{get(){getters++;return f.video.parentElement;}});
  assert.equal(ctx.sdk.pause(f.video,f.data,f.dom),false);assert.equal(getters,0);
  const g=fixture();g.control.pause=()=>{g.calls.push('pause');g.video.currentSrc='blob:https://www.nicovideo.jp/replaced';};
  assert.equal(ctx.sdk.restore(g.video,g.data,g.dom,50,false),false);assert.deepEqual(g.calls,['pause']);
});

test('a numeric seek no-op cannot masquerade as the absolute position API',()=>{
  const f=fixture();delete f.control.setCurrentTime;f.control.seek=()=>undefined;
  assert.equal(ctx.sdk.restore(f.video,f.data,f.dom,50,false),false);
  assert.equal(f.video.currentTime,20);assert.deepEqual(f.calls,[]);
});

test('invalid positions, rejected operations and replacements cannot resume a stale player',()=>{
  for(const time of [NaN,Infinity,-1,101]){
    const f=fixture();assert.equal(ctx.sdk.restore(f.video,f.data,f.dom,time,true),false);assert.deepEqual(f.calls,[]);
  }
  for(const rejected of [false,-1]){
    const f=fixture();f.control.setCurrentTime=()=>rejected;
    assert.equal(ctx.sdk.restore(f.video,f.data,f.dom,50,true),false);assert.deepEqual(f.calls,['pause']);
  }
  const f=fixture();f.control.setCurrentTime=()=>{f.video.currentSrc='blob:https://www.nicovideo.jp/replaced';};
  assert.equal(ctx.sdk.restore(f.video,f.data,f.dom,50,true),false);assert.deepEqual(f.calls,['pause']);
});
