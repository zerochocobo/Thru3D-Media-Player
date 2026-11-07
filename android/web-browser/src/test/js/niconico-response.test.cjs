const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const assets=path.join(__dirname,'../../main/assets/web-browser'),page='https://www.nicovideo.jp/watch/sm9';
const root='https://related.example/master.m3u8',video='https://related.example/video.m3u8',audio='https://related.example/audio.m3u8',key='https://another-related.example/current-key';
const master=`#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",DEFAULT=YES,URI="${audio}"\n#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=512x384,CODECS="avc1.64001e,mp4a.40.2",AUDIO="audio"\n${video}\n`;
const leaf=`#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="${key}"\n#EXTINF:10.1,\nsegment.ts\n#EXT-X-ENDLIST\n`;
function setup(early=false){
  const listeners={},streams=new Map(),timers=new Map();let seq=0,timer=0;
  const state=()=>({key:'7:0',page,document:'doc-1',privateContext:false,cookieStore:'default',niconico:true,items:new Map()});let current=early?null:state();
  const browser={webRequest:{filterResponseData(id){const s={writes:[],write(b){this.writes.push(Buffer.from(new Uint8Array(b)));},close(){this.closed=true;this.closeHook?.();},disconnect(){this.disconnected=true;}};streams.set(id,s);return s;}}};
  for(const event of ['onBeforeRequest','onHeadersReceived','onBeforeRedirect','onErrorOccurred'])browser.webRequest[event]={addListener(cb){listeners[event]=cb;}};
  const context=vm.createContext({browser,URL,TextDecoder,setTimeout(cb){timers.set(++timer,cb);return timer;},clearTimeout(id){timers.delete(id);}});
  const observer=vm.runInContext(fs.readFileSync(path.join(assets,'niconico.js'),'utf8')+'\n'+fs.readFileSync(path.join(assets,'niconico-response.js'),'utf8')+'\nThru3DNiconicoResponses',context)(
    d=>current&&d.tabId===7&&d.frameId===0&&d.documentId===current.document?current:null,()=>{},()=>!!current);
  const begin=(url='https://actual-api.example/v1/watch/sm9/access-rights/hls',extra={})=>{
    const d={requestId:String(++seq),url,method:url.includes('access-rights')?'POST':'GET',type:'xmlhttprequest',tabId:7,frameId:0,documentId:'doc-1',documentUrl:page,originUrl:page,incognito:false,cookieStoreId:'default',...extra};
    listeners.onBeforeRequest(d);return {d,s:streams.get(d.requestId)};
  };
  const headers=(r,status=201)=>listeners.onHeadersReceived({...r.d,statusCode:status,responseHeaders:[{name:'Content-Type',value:r.d.method==='POST'?'application/json':'application/vnd.apple.mpegurl'}]});
  const body=(r,text)=>{r.s.ondata({data:Uint8Array.from(Buffer.from(text)).buffer});r.s.onstop();};
  const api=(r=begin())=>{const text=JSON.stringify({meta:{status:201},data:{contentUrl:root,accessRightKey:'PRIVATE_KEY'}});headers(r);body(r,text);assert.equal(Buffer.concat(r.s.writes).toString(),text);return r;};
  const hls=(url,text)=>{const r=begin(url);assert.ok(r.s);headers(r,200);current.items.set(url,{kind:'hls',url,at:Date.now(),headers:{authorization:'this-request'}});observer.observeMedia(current);body(r,text);return r;};
  return {observer,listeners,timers,state,begin,api,hls,headers,body,get current(){return current;},set current(v){current=v;}};
}
test('current access declaration and master precede page delivery; only actual paired HLS completes the graph',()=>{
  const h=setup(),r=h.begin();r.s.closeHook=()=>assert.equal(h.current.niconicoMeta.root,root);h.api(r);
  assert.equal(JSON.stringify(h.current.niconicoMeta).includes('PRIVATE'),false);assert.equal(h.current.niconicoData.size,0);
  h.hls(root,master);h.hls(video,leaf);assert.equal(h.current.niconicoData.size,0);h.hls(audio,leaf);
  assert.equal(h.current.niconicoData.size,1);assert.equal(h.current.niconicoData.get('sm9').variants[0].audio,audio);
  assert.equal(h.observer.resource(h.current,key),true);assert.equal(h.begin(key).s,undefined,'The observer never reads a key response');
});
test('early document metadata attaches exactly and waits when status arrives after response bytes',()=>{
  const h=setup(true),r=h.begin();const text=JSON.stringify({meta:{status:201},data:{contentUrl:root}});h.body(r,text);
  assert.equal(r.s.closed,undefined);h.current=h.state();h.observer.attach(h.current);h.headers(r);
  assert.equal(h.current.niconicoMeta.root,root);assert.equal(Buffer.concat(r.s.writes).toString(),text);
  const other=setup(true);other.api();other.current={...other.state(),document:'replacement'};other.observer.attach(other.current);assert.equal(other.current.niconicoMeta,undefined);
});
test('foreign tab/frame/container/identity and obsolete responses cannot supply a graph',()=>{
  const h=setup();for(const change of [{tabId:-1},{frameId:1},{documentId:'other'},{incognito:true},{cookieStoreId:'other'}])assert.equal(h.begin(undefined,change).s,undefined);
  assert.equal(h.begin('https://api.example/v1/watch/sm10/access-rights/hls').s,undefined);
  const old=h.begin(),fresh=h.begin();h.api(fresh);h.api(old);assert.equal(old.s.disconnected,true);assert.equal(h.current.niconicoMeta.root,root);
});
test('protected leaves, redirects, HTTP errors, budgets and cancellation do not change original response bytes',()=>{
  const h=setup();h.api();h.hls(root,master);h.hls(video,leaf);h.hls(audio,leaf.replace('AES-128','SAMPLE-AES'));assert.equal(h.current.niconicoData.size,0);
  for(const mode of ['redirect','http','oversize','cancel','timeout']){
    const g=setup(),r=g.begin(),prefix=Uint8Array.from(Buffer.from('original-prefix')).buffer;r.s.ondata({data:prefix});
    if(mode==='redirect')g.listeners.onBeforeRedirect(r.d);
    if(mode==='http')g.headers(r,403);
    if(mode==='oversize')r.s.ondata({data:new Uint8Array(256*1024).buffer});
    if(mode==='cancel')g.observer.cancel(g.current);
    if(mode==='timeout')[...g.timers.values()][0]();
    assert.equal(r.s.disconnected,true);assert.equal(Buffer.concat(r.s.writes).subarray(0,15).toString(),'original-prefix');assert.ok(!g.current.niconicoData?.size);
  }
});
