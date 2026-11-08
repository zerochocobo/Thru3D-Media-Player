const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const assets=path.join(__dirname,'../../main/assets/web-browser'),frame='https://geo.dailymotion.com/player/official.html#settings=opaque',parent='https://www.dailymotion.com/video/x5kesuj';
const root='https://related.example:8443/current.m3u8?signature=exact',body='#EXTM3U\n# 原字节\n#EXTINF:187,\nsegment.ts\n#EXT-X-ENDLIST\n';
function setup(){
 const listeners={},streams=new Map(),timers=new Map();let seq=0,timer=0;
 let current={key:'7:3',page:frame,parentPage:parent,document:'doc-1',privateContext:false,cookieStore:'default',enabled:true,items:new Map()};
 const browser={webRequest:{filterResponseData(id){const s={writes:[],write(b){this.writes.push(Buffer.from(new Uint8Array(b)));},close(){this.closed=true;},disconnect(){this.disconnected=true;}};streams.set(id,s);return s;}}};
 for(const name of ['onHeadersReceived','onBeforeRedirect','onErrorOccurred'])browser.webRequest[name]={addListener(cb){listeners[name]=cb;}};
 const context=vm.createContext({browser,URL,Date,TextDecoder,DOMParser:class{parseFromString(text){const valid=text==='<MPD type="static"/>';return {documentElement:{localName:valid?'MPD':'parsererror'},getElementsByTagNameNS:()=>valid?[]:[{}]};}},setTimeout(cb){timers.set(++timer,cb);return timer;},clearTimeout(id){timers.delete(id);}});
 for(const file of ['tiktok.js','dailymotion.js','dailymotion-response.js'])vm.runInContext(fs.readFileSync(path.join(assets,file),'utf8'),context);
 const observer=vm.runInContext('Thru3DDailymotionResponses',context)(d=>current&&d.tabId===7&&d.frameId===3&&d.documentId===current.document?current:null,()=>{},()=>current?[current]:[]);
 const begin=(url=root,extra={})=>{
  const d={requestId:String(++seq),url,method:'GET',type:'xmlhttprequest',tabId:7,frameId:3,documentId:'doc-1',documentUrl:frame,incognito:false,cookieStoreId:'default',statusCode:200,
   responseHeaders:[{name:'Content-Type',value:'application/vnd.apple.mpegurl; charset=utf-8'}],...extra};
  listeners.onHeadersReceived(d);current.items.set(url,{request_id:d.requestId,kind:'hls'});return {d,s:streams.get(d.requestId)};
 };
 const complete=(r,text=body)=>{r.s.ondata({data:Uint8Array.from(Buffer.from(text)).buffer});r.s.onstop();};
 return {observer,listeners,timers,begin,complete,get current(){return current;},set current(v){current=v;}};
}
test('original UTF-8 HLS bytes pass immediately unchanged and retain their own actual request ID',()=>{
 const h=setup(),r=h.begin(),bytes=Buffer.from(body);
 for(const chunk of [bytes.subarray(0,15),bytes.subarray(15)])r.s.ondata({data:Uint8Array.from(chunk).buffer});
 assert.equal(Buffer.concat(r.s.writes).toString(),body);assert.equal(h.current.dailymotionBodies,undefined);
 r.s.onstop();assert.equal(r.s.closed,true);assert.equal(h.current.dailymotionBodies.get(root).body,body);
 assert.equal(h.current.dailymotionBodies.get(root).request_id,r.d.requestId);
 const again=h.begin();h.complete(again);assert.equal(h.current.dailymotionBodies.get(root).request_id,again.d.requestId);
});
test('only successful HLS from the owned parent, frame, document and cookie container is read',()=>{
 for(const change of [{statusCode:403},{method:'POST'},{responseHeaders:[{name:'Content-Type',value:'application/json'}]},
  {tabId:8},{frameId:0},{documentId:'different'},{incognito:true},{cookieStoreId:'different'}]){
  const h=setup();assert.equal(h.begin(root,change).s,undefined);
 }
 const h=setup();h.current.parentPage='https://other.test/video/x5kesuj';assert.equal(h.begin().s,undefined);
});
test('oversize, redirects, errors, navigation and timeouts release without altering page bytes',()=>{
 for(const mode of ['oversize','redirect','error','navigation','timeout','cancel']){
  const h=setup(),r=h.begin(),prefix='original-prefix';r.s.ondata({data:Uint8Array.from(Buffer.from(prefix)).buffer});
  if(mode==='oversize')r.s.ondata({data:new Uint8Array(48*1024+1).buffer});
  if(mode==='redirect')h.listeners.onBeforeRedirect(r.d);
  if(mode==='error')h.listeners.onErrorOccurred(r.d);
  if(mode==='navigation'){h.current={...h.current,document:'doc-2'};r.s.onstop();}
  if(mode==='timeout')[...h.timers.values()][0]();
  if(mode==='cancel')h.observer.cancel(h.current);
  assert.equal(Buffer.concat(r.s.writes).subarray(0,prefix.length).toString(),prefix);
  assert.ok(r.s.disconnected||r.s.closed);assert.ok(!h.current.dailymotionBodies?.size);
 }
});
test('malformed text is passed through, retention stays bounded and cancellation discards stored bodies',()=>{
 const h=setup(),bad=h.begin();h.complete(bad,'not a playlist');assert.equal(h.current.dailymotionBodies,undefined);
 for(let i=0;i<7;i++)h.complete(h.begin(root+'&variant='+i));
 assert.equal(h.current.dailymotionBodies.size,6);h.observer.cancel(h.current);assert.equal(h.current.dailymotionBodies.size,0);
});
test('unrelated XML and DASH responses are not inspected by the HLS adapter',()=>{
 for(const mime of ['application/xml','text/xml','application/dash+xml']){
  const h=setup();assert.equal(h.begin(root,{responseHeaders:[{name:'Content-Type',value:mime}]}).s,undefined);
 }
});
test('only actual master links permit opaque child manifests; segments and keys are never filtered',()=>{
 const h=setup(),child='https://another-related.test/current',key='https://another-related.test/key';
 h.complete(h.begin(root),'#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000000\n'+child+'\n');
 assert.equal(h.observer.resource(h.current,child),true);
 const leaf=h.begin(child,{responseHeaders:[{name:'Content-Type',value:'application/octet-stream'}]});
 h.complete(leaf,'#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="'+key+'"\n#EXTINF:10,\nsegment.ts\n#EXT-X-ENDLIST\n');
 assert.equal(h.current.dailymotionBodies.get(child).format,'hls');
 assert.equal(h.observer.resource(h.current,key),false);assert.equal(h.observer.resource(h.current,'https://another-related.test/segment.ts'),false);
 const unowned=h.begin(child,{tabId:-1,frameId:-1});assert.equal(unowned.s,undefined);
 h.current.dailymotionBodies.get(root).at=Date.now()-1800001;assert.equal(h.observer.resource(h.current,child),false);
});
