const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');
const assets=path.join(__dirname,'../../main/assets/web-browser');
const page='https://v.youku.com/v_show/id_XOTUxMzg4NDMy.html';
const manifest='https://new-cdn.example/current.m3u8?signature=unchanged';
const raw=()=>({api:'mtop.youku.play.ups.appinfo.get',ret:['SUCCESS::调用成功'],data:{e:{code:0},enc:0,data:{video:{encodeid:'XOTUxMzg4NDMy',seconds:702.08,drm_type:'default'},stream:[{m3u8_url:manifest.replace('https:','http:'),width:960,height:540,milliseconds_video:702079,drm_type:'default'}]}}});
function setup(early=false){
  const listeners={},streams=new Map(),timers=new Map();let timer=0,id=0;
  const state=()=>({key:'7:0',page,document:'doc-1',privateContext:false,cookieStore:'default',youku:true,items:new Map()});
  let current=early?null:state();
  const browser={webRequest:{filterResponseData(id){const s={writes:[],write(b){this.writes.push(Buffer.from(new Uint8Array(b)));},close(){this.closed=true;this.closeHook?.();},disconnect(){this.disconnected=true;}};streams.set(id,s);return s;}}};
  for(const name of ['onBeforeRequest','onHeadersReceived','onBeforeRedirect','onErrorOccurred'])browser.webRequest[name]={addListener(cb){listeners[name]=cb;}};
  const context=vm.createContext({browser,URL,TextDecoder,setTimeout(cb){timers.set(++timer,cb);return timer;},clearTimeout(id){timers.delete(id);}});
  const observer=vm.runInContext(fs.readFileSync(path.join(assets,'youku.js'),'utf8')+'\n'+fs.readFileSync(path.join(assets,'youku-response.js'),'utf8')+'\nThru3DYoukuResponses',context)(d=>current&&d.tabId===7&&d.frameId===0&&d.documentId===current.document?current:null,()=>{},()=>!!current);
  const begin=(extra={})=>{const d={requestId:String(++id),url:'https://new-api.example/h5/mtop.youku.play.ups.appinfo.get/1.1/?data=opaque',method:'GET',type:'script',tabId:7,frameId:0,documentId:'doc-1',documentUrl:page,originUrl:page,incognito:false,cookieStoreId:'default',...extra};listeners.onBeforeRequest(d);return {d,s:streams.get(d.requestId)};};
  const respond=(r,data=raw())=>{listeners.onHeadersReceived({...r.d,statusCode:200,responseHeaders:[{name:'Content-Type',value:'application/javascript; charset=utf-8'}]});const text='mtopjsonp1('+JSON.stringify(data)+');';r.s.ondata({data:Uint8Array.from(Buffer.from(text)).buffer});r.s.onstop();assert.equal(Buffer.concat(r.s.writes).toString(),text);};
  const observe=(change={})=>{const c={kind:'hls',url:manifest,original_url:manifest,at:Date.now(),headers:{authorization:'own-request'},...change};current.items.set(c.url,c);observer.observeMedia(current,c);return c;};
  return {observer,begin,respond,observe,listeners,timers,state,get current(){return current;},set current(s){current=s;}};
}
test('publishes declarations before releasing JSONP and binds only the observed successful current HLS',()=>{
  const h=setup(),r=h.begin();r.s.closeHook=()=>assert.equal(h.current.youkuMeta.id,'XOTUxMzg4NDMy');h.respond(r);
  assert.equal(h.current.youkuData.size,0);
  const c=h.observe();assert.equal(h.current.youkuData.get('XOTUxMzg4NDMy').manifests[0],manifest);
  assert.equal(h.current.items.get(manifest),c);
});
test('a successful HLS before metadata/loadstart is revalidated without extending its age or borrowing credentials',()=>{
  const h=setup(),c=h.observe();h.respond(h.begin());
  assert.equal(h.current.youkuData.get('XOTUxMzg4NDMy').manifests[0],manifest);
  assert.equal(h.current.items.get(manifest),c);
  for(const change of [{at:Date.now()-1800001},{at:Date.now()+60000},{kind:'file'},{url:manifest+'&changed=1',original_url:''}]){
    const n=setup();n.observe(change);n.respond(n.begin());assert.equal(n.current.youkuData.size,0);
  }
});
test('refreshed or protected metadata invalidates old bindings and stale responses cannot restore them',()=>{
  const h=setup();h.respond(h.begin());h.observe();const older=h.begin(),newer=h.begin();
  assert.equal(h.current.youkuData.size,0);
  const protectedData=raw();protectedData.data.enc=1;h.respond(newer,protectedData);h.respond(older);
  assert.equal(h.current.youkuMeta,null);assert.equal(h.current.youkuData.size,0);assert.equal(older.s.disconnected,true);
});
test('early observations attach only to the same page/frame/document/container and survive status arriving after bytes',()=>{
  const h=setup(true);h.respond(h.begin());h.current=h.state();h.observer.attach(h.current);
  assert.equal(h.current.youkuMeta.id,'XOTUxMzg4NDMy');h.observe();assert.equal(h.current.youkuData.size,1);
  const other=setup(true);other.respond(other.begin());other.current={...other.state(),document:'new-doc'};other.observer.attach(other.current);assert.equal(other.current.youkuMeta,undefined);
  for(const change of [{tabId:-1},{frameId:-1},{incognito:true},{cookieStoreId:'other'},{documentId:'different'}])assert.equal(h.begin(change).s,undefined);
});
test('cancel, timeout, oversize and rejected status keep all original bytes flowing',()=>{
  for(const mode of ['cancel','timeout','oversize','http']){
    const h=setup(),r=h.begin(),prefix=Uint8Array.from(Buffer.from('original prefix')).buffer;r.s.ondata({data:prefix});
    if(mode==='cancel')h.observer.cancel(h.current);
    if(mode==='timeout')[...h.timers.values()][0]();
    if(mode==='oversize')r.s.ondata({data:new Uint8Array(2*1024*1024).buffer});
    if(mode==='http')h.listeners.onHeadersReceived({...r.d,statusCode:403,responseHeaders:[]});
    assert.equal(r.s.disconnected,true);assert.equal(Buffer.concat(r.s.writes).subarray(0,15).toString(),'original prefix');
    assert.ok(!h.current.youkuData?.size);
  }
});
