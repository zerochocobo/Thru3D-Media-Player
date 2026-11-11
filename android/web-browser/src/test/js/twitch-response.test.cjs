const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const assets=path.join(__dirname,'../../main/assets/web-browser'),page='https://clips.twitch.tv/PublicClip';
const file='https://related.example/clip.mp4?sig=exact&token=opaque';
const identity={data:{clip:{id:'12345',slug:'PublicClip',durationSeconds:32}}};
const quality={data:{clip:{id:'12345',playbackAccessToken:{signature:'exact',value:'opaque'},videoQualities:[{quality:'1080',sourceURL:'https://related.example/clip.mp4'}]}}};
function setup(early=false){
  let id=0,current,timer=0;const streams=new Map(),listeners={},timers=new Map();
  const state=(change={})=>({key:'7:0',page,document:'doc-1',privateContext:false,cookieStore:'default',twitch:true,items:new Map(),...change});
  current=early?null:state();
  const browser={webRequest:{filterResponseData(id){const stream={writes:[],write(b){this.writes.push(Buffer.from(b));},close(){this.closed=true;},disconnect(){this.disconnected=true;}};streams.set(id,stream);return stream;}}};
  for(const name of ['onBeforeRequest','onHeadersReceived','onBeforeRedirect','onErrorOccurred'])browser.webRequest[name]={addListener(cb){listeners[name]=cb;}};
  const context=vm.createContext({browser,URL,Date,TextDecoder,setTimeout(cb){timers.set(++timer,cb);return timer;},clearTimeout(id){timers.delete(id);}});
  const observer=vm.runInContext(fs.readFileSync(path.join(assets,'twitch.js'),'utf8')+'\n'+fs.readFileSync(path.join(assets,'twitch-response.js'),'utf8')+'\nThru3DTwitchResponses',context)(
    d=>current&&d.tabId===7&&d.frameId===0&&d.documentId===current.document?current:null,()=>{},()=>!!current);
  function begin(change={}){
    const d={requestId:String(++id),url:'https://actual-api.example/gql#origin=twilight',method:'POST',type:'xmlhttprequest',tabId:7,frameId:0,documentId:'doc-1',documentUrl:page,originUrl:page,incognito:false,cookieStoreId:'default',...change};
    listeners.onBeforeRequest(d);return {d,stream:streams.get(d.requestId)};
  }
  function bytes(r,body){const text=typeof body==='string'?body:JSON.stringify(body),buffer=Uint8Array.from(Buffer.from(text)).buffer;r.stream.ondata({data:buffer});assert.equal(Buffer.concat(r.stream.writes).toString(),text,'every byte forwarded immediately, before stop');}
  function headers(r,status=200){listeners.onHeadersReceived({...r.d,statusCode:status,responseHeaders:[{name:'Content-Type',value:'application/json; charset=utf-8'}]});}
  function respond(r,body){headers(r);bytes(r,body);r.stream.onstop();}
  function media(){current.items.set(file,{url:file,kind:'file',at:Date.now(),headers:{authorization:'exact-request-only'}});observer.observeMedia(current);}
  return {state,observer,begin,bytes,headers,respond,media,timers,get current(){return current;},set current(s){current=s;}};
}
test('separate current metadata responses join in either order and preserve media request credentials',()=>{
  for(const order of [[identity,quality],[quality,identity]]){
    const h=setup();h.media();const request=h.current.items.get(file);
    h.respond(h.begin(),order[0]);assert.equal(h.current.twitchData.size,0);
    h.respond(h.begin(),order[1]);assert.equal(h.current.twitchData.size,1);assert.equal(h.current.items.get(file),request);
    assert.equal(h.current.twitchData.get(file).id,'PublicClip');assert.equal(request.headers.authorization,'exact-request-only');
  }
});
test('early metadata attaches only to its exact document, page and cookie container',()=>{
  for(const change of [{},{document:'other'},{page:'https://clips.twitch.tv/OtherClip'},{privateContext:true},{cookieStore:'private'}]){
    const h=setup(true);h.respond(h.begin(),[identity,quality]);h.current=h.state(change);h.observer.attach(h.current);h.media();
    assert.equal(h.current.twitchData.size,Object.keys(change).length?0:1);
  }
});
test('frame-less/other-frame/private-container responses never enter the current graph',()=>{
  for(const change of [{frameId:-1},{frameId:1},{tabId:9},{documentId:'other'},{incognito:true},{cookieStoreId:'other'}]){
    const h=setup();assert.equal(h.begin(change).stream,undefined);
  }
});
test('cancellation prevents a late old response from repopulating the graph',()=>{
  const h=setup(),r=h.begin();h.headers(r);h.bytes(r,[identity,quality]);h.observer.cancel(h.current);r.stream.onstop();h.media();
  assert.equal(h.current.twitchData.size,0);assert.equal(r.stream.disconnected,true);
});
test('same-document clip reentry needs a fresh exact media request to reuse declarations',()=>{
  const h=setup();h.respond(h.begin(),[identity,quality]);h.media();
  assert.equal(h.current.twitchData.size,1);
  h.observer.cancel(h.current,true);h.current.items.clear();
  h.current.page='https://clips.twitch.tv/OtherClip';h.media();
  assert.equal(h.current.twitchData.size,0);
  h.current.items.clear();h.current.page=page;
  h.respond(h.begin(),quality);
  assert.equal(h.current.twitchData.size,0);
  const wrong=file.replace('sig=exact','sig=changed');
  h.current.items.set(wrong,{url:wrong,kind:'file',at:Date.now()});
  h.observer.observeMedia(h.current);
  assert.equal(h.current.twitchData.size,0);
  h.media();
  assert.equal(h.current.twitchData.size,1);
  assert.equal(h.current.twitchData.get(file).id,'PublicClip');
  assert.equal(h.current.twitchData.get(file).headers,undefined);
  h.observer.cancel(h.current);h.current.items.clear();h.media();
  assert.equal(h.current.twitchData.size,0);
});
test('oversized or invalid responses still pass through and remain unbound',()=>{
  const h=setup(),r=h.begin();h.headers(r);h.bytes(r,'x'.repeat(2*1024*1024+1));assert.equal(r.stream.disconnected,true);h.media();assert.equal(h.current.twitchData.size,0);
  const invalid=h.begin();h.respond(invalid,'not JSON');h.media();assert.equal(h.current.twitchData.size,0);
});
test('status arriving after all bytes is accepted only for a successful JSON response',()=>{
  const h=setup(),r=h.begin();h.bytes(r,[identity,quality]);r.stream.onstop();h.headers(r);h.media();assert.equal(h.current.twitchData.size,1);
  const rejected=setup(),bad=rejected.begin();rejected.bytes(bad,[identity,quality]);bad.stream.onstop();rejected.headers(bad,403);rejected.media();assert.equal(rejected.current.twitchData.size,0);
});
