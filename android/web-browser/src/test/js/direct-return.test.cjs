const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const script=fs.readFileSync(path.join(__dirname,'../../main/assets/web-browser/direct-return.js'),'utf8');
const settle=()=>new Promise(resolve=>setImmediate(resolve));
function fixture(){
  const created=[],events=new Map(),timers=new Map(),clock={now:1000},state={available:true,valid:true};let nextTimer=0;
  function node(tag){
    const n={tag,style:{},dataset:{},listeners:{},isConnected:false,children:[],
      append(...nodes){for(const v of nodes){v.isConnected=true;v.parentElement=this;this.children.push(v);}},
      attachShadow(){return node('shadow');},setAttribute(k,v){this[k]=v;},
      addEventListener(k,f){this.listeners[k]=f;},remove(){this.isConnected=false;},
      getBoundingClientRect(){return {left:100,top:100,right:900,bottom:600,width:800,height:500};}};
    created.push(n);return n;
  }
  const doc={documentElement:node('html'),createElement:node},video=node('video');video.isConnected=true;video.paused=true;video.currentSrc='https://cdn.test/a.mp4';video.plays=0;
  video.play=()=>{video.plays++;video.paused=false;return Promise.resolve();};
  video.pause=()=>{video.paused=true;};
  const context=vm.createContext({document:doc,navigator:{language:'en'},innerWidth:1000,innerHeight:800,Date:{now:()=>clock.now},
    addEventListener(k,f){events.set(k,f);},removeEventListener(k){events.delete(k);},
    setTimeout(f){timers.set(++nextTimer,f);return nextTimer;},clearTimeout(id){timers.delete(id);}});
  vm.runInContext(script+';globalThis.api=Thru3DDirectReturn;',context);
  const api=context.api.create({valid:s=>state.valid&&s.video.isConnected&&s.video.currentSrc===s.source,available:()=>state.available,changed(){}});
  const arm=()=>{api.restore({video,source:video.currentSrc});api.sync();};
  const button=()=>created.filter(n=>n.tag==='button').at(-1),host=()=>created.filter(n=>n.dataset.thru3dResumeWeb==='').at(-1);
  const click=(trusted=true)=>button().listeners.click({isTrusted:trusted,preventDefault(){},stopPropagation(){}});
  arm();return {api,video,state,clock,created,events,timers,arm,button,host,click};
}
test('only an explicit trusted resume click starts the original video and removes its control',async()=>{
  const f=fixture();assert(f.api.holds(f.video));assert.equal(f.video.plays,0);
  f.click(false);assert.equal(f.video.plays,0);
  f.click();assert.equal(f.video.plays,1,'play runs synchronously in user activation');
  await settle();assert.equal(f.api.holds(f.video),false);assert.equal(f.host().isConnected,false);
  assert.equal(f.events.has('scroll'),false);assert.equal(f.events.has('resize'),false);
});
test('unrelated page gestures and elapsed time cannot release delayed autoplay',()=>{
  const f=fixture();f.clock.now+=60000;f.api.gesture({isTrusted:true,clientX:10,clientY:10,composedPath:()=>[]});
  assert(f.api.holds(f.video));f.api.gesture({isTrusted:false,composedPath:()=>[f.video]});assert(f.api.holds(f.video));
  f.api.gesture({isTrusted:true,composedPath:()=>[f.video]});assert.equal(f.api.holds(f.video),false);
  f.clock.now+=2001;assert(f.api.holds(f.video),'A mute/seek click does not grant indefinite autoplay permission');
});
test('owned shadow events are reserved before site-wide gesture handlers, without swallowing page clicks',async()=>{
  const f=fixture();let stopped=0;
  const event={isTrusted:true,composedPath:()=>[f.host()],preventDefault(){},stopPropagation(){},stopImmediatePropagation(){stopped++;}};
  f.events.get('touchstart')(event);assert.equal(stopped,1);
  f.events.get('click')({...event,composedPath:()=>[{}]});assert.equal(f.video.plays,0);
  f.events.get('click')(event);await settle();assert.equal(f.video.plays,1);assert.equal(stopped,2);
});
test('native pause lease/inactivity blocks a retained button click and removes the visible control',()=>{
  const f=fixture();f.state.available=false;f.click();assert.equal(f.video.plays,0);f.api.sync();assert.equal(f.host().isConnected,false);
  f.state.available=true;f.api.sync();assert(f.host().isConnected);f.api.clear();assert.equal(f.host().isConnected,false);
});
test('replacement, navigation, encryption or a detached video invalidates the resume target',()=>{
  for(const invalidate of [f=>f.state.valid=false,f=>f.video.isConnected=false,f=>f.video.currentSrc='https://cdn.test/next.mp4']){
    const f=fixture();invalidate(f);f.click();assert.equal(f.video.plays,0);assert.equal(f.host().isConnected,false);
  }
});
test('a rejected or synchronous failing play leaves a usable retry control',async()=>{
  for(const play of [()=>Promise.reject(Error('blocked')),()=>{throw Error('blocked');}]){
    const f=fixture();f.video.play=play;f.click();await settle();
    assert(f.video.paused);assert(f.api.holds(f.video));assert(f.host().isConnected);assert.equal(f.button().disabled,false);
  }
});
test('a late completion cannot remove a newer return control or unlock its pause',async()=>{
  const f=fixture();let finish;f.video.play=()=>new Promise(resolve=>finish=resolve);f.click();f.arm();const next=f.host();
  finish();await settle();assert.equal(f.host(),next);assert(next.isConnected);assert(f.api.holds(f.video));
});
test('slow buffering keeps explicit play authorized, while a stalled attempt exposes a retry',async()=>{
  const f=fixture(),finishes=[];f.video.play=()=>new Promise(resolve=>finishes.push(resolve));f.click();
  f.clock.now+=10000;assert.equal(f.api.holds(f.video),false,'Do not cancel valid slow buffering after a short gesture deadline');
  let pauses=0;f.video.pause=()=>{pauses++;f.video.paused=true;};
  const expire=[...f.timers.values()][0];expire();assert.equal(pauses,0);assert.equal(f.api.holds(f.video),false);assert.equal(f.button().disabled,false);
  f.click();const retry=f.host();finishes[0]();await settle();assert.equal(f.host(),retry);assert(f.button().disabled,'Old completion cannot finish the retry');
  finishes[1]();await settle();
  assert(f.api.holds(f.video));assert.equal(f.button().disabled,false);
});
test('slow seek can finish after the retry deadline without another click or forced pause',async()=>{
  const f=fixture();let finish,pauses=0;f.video.pause=()=>{pauses++;f.video.paused=true;};
  f.video.play=()=>{f.video.paused=false;return new Promise(resolve=>finish=resolve);};f.click();
  assert.equal(f.button().textContent,'…');[...f.timers.values()][0]();
  assert.equal(pauses,0);assert.equal(f.api.holds(f.video),false);assert.equal(f.button().disabled,false);
  finish();await settle();assert.equal(f.host().isConnected,false);assert.equal(f.video.paused,false);
});
test('hidden canvas source uses its visible container and offscreen controls stay hidden',()=>{
  const f=fixture();f.video.getBoundingClientRect=()=>({width:0,height:0});
  f.video.parentElement={getBoundingClientRect:()=>({left:20,top:30,right:820,bottom:530,width:800,height:500})};
  f.api.sync();assert.equal(f.host().style.left,'384px');assert.equal(f.host().style.top,'244px');
  f.video.parentElement.getBoundingClientRect=()=>({left:20,top:-900,right:820,bottom:-400,width:800,height:500});
  f.api.sync();assert.equal(f.host().style.display,'none');
});
test('repeated return creates one live control and resumes only the selected video',async()=>{
  const f=fixture();const neighbour={paused:true,plays:0};
  for(let n=0;n<3;n++){
    f.video.paused=true;f.arm();f.api.sync();f.api.sync();assert.equal(f.created.filter(n=>n.dataset.thru3dResumeWeb===''&&n.isConnected).length,1);
    f.click();await settle();assert.equal(neighbour.plays,0);assert(neighbour.paused);
  }
  assert.equal(f.video.plays,3);
});
