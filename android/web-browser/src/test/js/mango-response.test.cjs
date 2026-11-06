const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');
const assets=path.join(__dirname,'../../main/assets/web-browser');
const page='https://w.mgtv.com/s/15588271.html';
const dispatch='https://dispatch.example/route?pm2=opaque-video&arange=0';
const invoked=dispatch+'&did=device&suuid=session&callback=jsonp_1';
const manifest='https://new-cdn.example/video.m3u8?ticket=current';
const video=(clear=true)=>({code:200,data:{info:{video_id:'15588271',duration:'4026',drmFlag:clear?'0':'1'},drm:{licenseUrl:'',drmFirm:'',drmType:''}}});
const sources=()=>({code:200,data:{stream_domain:['https://dispatch.example/'],stream:[{url:'/route?pm2=opaque-video&arange=0'}]}});

function setup(early=false){
  const listeners={},streams=new Map(),timers=new Map(),published=[];let timer=0,request=0;
  const state=()=>({key:'7:0',page,document:'doc-1',privateContext:false,cookieStore:'default',mango:true});
  let current=early?null:state();
  const browser={webRequest:{filterResponseData(id){
    const s={writes:[],closed:false,disconnected:false,
      write(bytes){this.writes.push(Buffer.from(new Uint8Array(bytes)));},
      close(){this.closed=true;this.closeHook?.();},disconnect(){this.disconnected=true;}};
    streams.set(id,s);return s;
  }}};
  for(const name of ['onBeforeRequest','onHeadersReceived','onBeforeRedirect','onErrorOccurred'])browser.webRequest[name]={addListener(cb){listeners[name]=cb;}};
  const context=vm.createContext({URL,TextDecoder,browser,setTimeout(cb){timers.set(++timer,cb);return timer;},clearTimeout(id){timers.delete(id);}});
  const factory=vm.runInContext(fs.readFileSync(path.join(assets,'mango.js'),'utf8')+'\n'+fs.readFileSync(path.join(assets,'mango-response.js'),'utf8')+'\nThru3DMangoResponses',context);
  const observer=factory(d=>current&&d.tabId===7&&d.frameId===0&&d.documentId===current.document?current:null,
    s=>published.push([...s.mangoData?.values()||[]]),d=>!!current&&d.tabId===7&&d.frameId===0);
  const begin=(url,extra={})=>{
    const d={requestId:String(++request),url,method:'GET',type:'script',tabId:7,frameId:0,documentId:'doc-1',documentUrl:page,originUrl:page,incognito:false,cookieStoreId:'default',...extra};
    listeners.onBeforeRequest(d);return {d,s:streams.get(d.requestId)};
  };
  const headers=(r,status=200,mime='application/javascript; charset=utf-8')=>listeners.onHeadersReceived({...r.d,statusCode:status,responseHeaders:[{name:'Content-Type',value:mime}]});
  const bytes=(r,text)=>r.s.ondata({data:Uint8Array.from(Buffer.from(text)).buffer});
  const respond=(r,raw)=>{headers(r);const text='jsonp_1('+JSON.stringify(raw)+');\n';bytes(r,text);r.s.onstop();assert.equal(Buffer.concat(r.s.writes).toString(),text);return r;};
  const establish=()=>{
    respond(begin('https://api.example/player/video?video_id=15588271'),video());
    respond(begin('https://api.example/player/getSource?video_id=15588271'),sources());
    respond(begin(invoked),{status:'ok',info:manifest});
  };
  return {observer,begin,headers,bytes,respond,establish,state,streams,timers,published,get current(){return current;},set current(value){current=value;}};
}

test('records are ready before JSONP callbacks while original UTF-8 bytes remain identical',()=>{
  const h=setup(),r=h.begin('https://api.example/player/video?video_id=15588271');h.headers(r);
  const text='jsonp_1('+JSON.stringify({...video(),note:'中文 é'})+');\n';h.bytes(r,text);
  assert.equal(r.s.writes.length,0);
  r.s.closeHook=()=>assert.equal(h.current.mangoMeta.id,'15588271');r.s.onstop();
  assert.equal(Buffer.concat(r.s.writes).toString(),text);
  const source=h.begin('https://api.example/player/getSource?video_id=15588271');
  let next;source.s.closeHook=()=>{next=h.begin(invoked);assert.ok(next.s);};
  h.respond(source,sources());h.respond(next,{status:'ok',info:manifest});
  const data=h.current.mangoData.get('15588271');assert.equal(data.manifests[0],manifest);assert.equal(data.duration,4026);
});
test('wrong video, duplicate IDs and changed media parameters never enter this source graph',()=>{
  const h=setup();h.establish();
  for(const url of ['https://api.example/player/video?video_id=15588272','https://api.example/player/video?video_id=15588271&video_id=15588272',invoked+'&vid=other',invoked.replace('opaque-video','other-video')])assert.equal(h.begin(url).s,undefined);
  assert.equal(h.current.mangoData.get('15588271').manifests[0],manifest);
});
test('a new metadata request invalidates old clear results immediately, including protected responses',()=>{
  const h=setup();h.establish();const r=h.begin('https://api.example/player/video?video_id=15588271');
  assert.equal(h.current.mangoData.size,0);h.respond(r,video(false));
  h.respond(h.begin('https://api.example/player/getSource?video_id=15588271'),sources());
  assert.equal(h.begin(invoked).s,undefined);assert.equal(h.current.mangoData.size,0);
});
test('out-of-order old metadata cannot overwrite newer protected state',()=>{
  const h=setup(),first=h.begin('https://api.example/player/video?video_id=15588271'),second=h.begin('https://api.example/player/video?video_id=15588271');
  h.respond(second,video(false));h.headers(first);h.bytes(first,'jsonp_1('+JSON.stringify(video())+');');first.s.onstop();
  assert.equal(first.s.disconnected,true);assert.equal(h.current.mangoMeta.clear,false);assert.equal(h.current.mangoData.size,0);
});
test('cancel flushes held original bytes and drops the graph',()=>{
  const h=setup(),r=h.begin('https://api.example/player/video?video_id=15588271');h.headers(r);h.bytes(r,'original prefix');
  h.observer.cancel(h.current);assert.equal(Buffer.concat(r.s.writes).toString(),'original prefix');assert.equal(r.s.disconnected,true);assert.equal(h.current.mangoData.size,0);
});
test('oversize response detaches without truncating held or current original bytes',()=>{
  const h=setup(),r=h.begin('https://api.example/player/video?video_id=15588271');h.headers(r);
  const prefix='a'.repeat(2*1024*1024);h.bytes(r,prefix);h.bytes(r,'overflow');
  assert.equal(Buffer.concat(r.s.writes).toString(),prefix+'overflow');assert.equal(r.s.disconnected,true);assert.equal(h.current.mangoData.size,0);
});
test('timeouts preserve held response bytes and never expose a partial metadata result',()=>{
  const h=setup(),r=h.begin('https://api.example/player/video?video_id=15588271');h.headers(r);h.bytes(r,'partial');
  [...h.timers.values()][0]();assert.equal(Buffer.concat(r.s.writes).toString(),'partial');assert.equal(r.s.disconnected,true);assert.equal(h.current.mangoData.size,0);
});
test('HTTP failures and non-JSONP MIME detach before normalizing data',()=>{
  for(const [status,mime] of [[403,'application/json'],[200,'text/html']]){
    const h=setup(),r=h.begin('https://api.example/player/video?video_id=15588271');h.bytes(r,'original');h.headers(r,status,mime);
    assert.equal(r.s.disconnected,true);assert.equal(Buffer.concat(r.s.writes).toString(),'original');assert.equal(h.current.mangoData.size,0);
  }
});
test('early metadata restores only to the same document, cookie store and privacy context',()=>{
  const h=setup(true);h.establish();
  for(const change of [{document:'other-doc'},{privateContext:true},{cookieStore:'other-store'}]){
    h.current={...h.state(),...change};h.observer.attach(h.current);assert.equal(h.current.mangoData,undefined);
  }
  h.current=h.state();h.observer.attach(h.current);assert.equal(h.current.mangoData.get('15588271').manifests[0],manifest);
});
test('a live different document cannot receive an older response from the same public URL',()=>{
  const h=setup(),r=h.begin('https://api.example/player/video?video_id=15588271');h.current={...h.state(),document:'other-doc'};
  h.headers(r);h.bytes(r,'jsonp_1('+JSON.stringify(video())+');');r.s.onstop();
  assert.equal(r.s.disconnected,true);assert.equal(h.current.mangoMeta,undefined);assert.equal(h.current.mangoData,undefined);
});
test('navigation retires an early graph even when the following port has no document ID',()=>{
  const h=setup(true);h.establish();h.observer.navigate({tabId:7,frameId:0,type:'main_frame'});
  h.current={...h.state(),document:undefined};h.observer.attach(h.current);assert.equal(h.current.mangoData,undefined);
});
test('direct frame ownership still rejects a mismatched privacy context or cookie store',()=>{
  const h=setup();h.establish();
  for(const extra of [{incognito:true},{cookieStoreId:'other-store'}])assert.equal(h.begin('https://api.example/player/video?video_id=15588271',extra).s,undefined);
  assert.equal(h.current.mangoData.get('15588271').manifests[0],manifest);
});
test('the domestic SDK combined streamList binds metadata and sources before dispatch',()=>{
  const h=setup(),combined=video();Object.assign(combined.data,sources().data);
  h.respond(h.begin('https://api.example/video/streamList?video_id=15588271',{type:'xmlhttprequest'}),combined);
  assert.equal(h.current.mangoMeta.id,'15588271');assert.equal(h.current.mangoDeclared.length,1);
  h.respond(h.begin(invoked),{status:'ok',info:manifest});assert.equal(h.current.mangoData.get('15588271').manifests[0],manifest);
  assert.equal(h.begin('https://api.example/video/streamList?video_id=15588272').s,undefined);
});
test('successful direct HLS is linked only to current clear metadata and expires at replacement',()=>{
  const h=setup(),combined=video(),hash='a'.repeat(32);Object.assign(combined.data,sources().data);combined.data.stream[0].fileHash=hash;
  h.respond(h.begin('https://api.example/video/streamList?video_id=15588271'),combined);
  const c={kind:'hls',url:'https://cdn.example/'+hash+'.m3u8?ticket=current'};c.original_url=c.url;
  h.observer.observeMedia(h.current,{...c,kind:'file'});assert.equal(h.current.mangoData.size,0);
  h.observer.observeMedia(h.current,{...c,url:'https://cdn.example/unrelated.m3u8',original_url:''});assert.equal(h.current.mangoData.size,0);
  h.observer.observeMedia(h.current,c);assert.equal(h.current.mangoData.get('15588271').manifests[0],c.url);
  const replacement=h.begin('https://api.example/video/streamList?video_id=15588271');
  h.observer.observeMedia(h.current,c);assert.equal(h.current.mangoData.size,0);
  h.respond(replacement,video(false));h.observer.observeMedia(h.current,c);assert.equal(h.current.mangoData.size,0);
});
test('current metadata revalidates an earlier successful same-document HLS by exact file identity',()=>{
  const h=setup(),combined=video(),hash='a'.repeat(32);Object.assign(combined.data,sources().data);combined.data.stream[0].fileHash=hash;
  const c={kind:'hls',url:'https://new-cdn.example/'+hash+'.m3u8?ticket=original',at:Date.now(),headers:{authorization:'only-this-file'}};
  c.original_url=c.url;h.current.items=new Map([[c.url,c]]);
  h.observer.observeMedia(h.current,c);assert.equal(h.current.mangoData,undefined);
  h.respond(h.begin('https://api.example/video/streamList?video_id=15588271'),combined);
  assert.equal(h.current.mangoData.get('15588271').manifests[0],c.url);
  assert.equal(h.current.items.get(c.url),c,'Revalidation keeps the exact captured request and its own credentials');
  const refresh=h.begin('https://api.example/video/streamList?video_id=15588271');
  assert.equal(h.current.mangoData.size,0,'No binding survives an in-flight metadata replacement');
  h.respond(refresh,combined);assert.equal(h.current.mangoData.get('15588271').manifests[0],c.url);
});
test('metadata backfill rejects stale, future, unrelated, non-HLS and protected observations',()=>{
  for(const change of ['stale','future','unrelated','file','protected']){
    const h=setup(),combined=video(change!=='protected'),hash='a'.repeat(32);Object.assign(combined.data,sources().data);combined.data.stream[0].fileHash=hash;
    const c={kind:change==='file'?'file':'hls',url:'https://cdn.example/'+(change==='unrelated'?'b'.repeat(32):hash)+'.m3u8',
      at:Date.now()+(change==='stale'?-1800001:change==='future'?60000:0)};
    c.original_url=c.url;h.current.items=new Map([[c.url,c]]);
    h.respond(h.begin('https://api.example/video/streamList?video_id=15588271'),combined);
    assert.equal(h.current.mangoData.size,0,change);
  }
});
test('a replacement source list cannot reuse a different file from the old clear graph',()=>{
  const h=setup(),combined=video(),hash='a'.repeat(32);Object.assign(combined.data,sources().data);combined.data.stream[0].fileHash=hash;
  const c={kind:'hls',url:'https://cdn.example/'+hash+'.m3u8',at:Date.now()};c.original_url=c.url;
  h.current.items=new Map([[c.url,c]]);
  h.respond(h.begin('https://api.example/video/streamList?video_id=15588271'),combined);
  assert.equal(h.current.mangoData.size,1);
  combined.data.stream[0].fileHash='b'.repeat(32);
  h.respond(h.begin('https://api.example/video/streamList?video_id=15588271'),combined);
  assert.equal(h.current.mangoData.size,0);
});
test('separate getSource responses also declare file identities for already observed HLS',()=>{
  const h=setup(),hash='a'.repeat(32),raw=sources();raw.data.stream[0].fileHash=hash;
  const c={kind:'hls',url:'https://cdn.example/'+hash+'.m3u8',at:Date.now()};c.original_url=c.url;
  h.current.items=new Map([[c.url,c]]);
  h.respond(h.begin('https://api.example/player/video?video_id=15588271'),video());
  assert.equal(h.current.mangoData.size,0);
  h.respond(h.begin('https://api.example/player/getSource?video_id=15588271'),raw);
  assert.equal(h.current.mangoData.get('15588271').manifests[0],c.url);
});
test('same-document HEVC HLS follows its own declared file and survives metadata refresh',()=>{
  const h=setup(),combined=video(),avc='a'.repeat(32),hevc='b'.repeat(32);Object.assign(combined.data,sources().data);
  combined.data.stream[0].fileHash=avc;combined.data.stream_h265=[{fileHash:hevc,url:''}];
  const c={kind:'hls',url:'https://observed-hevc-cdn.example/'+hevc+'.m3u8?ticket=actual',at:Date.now()};c.original_url=c.url;
  h.current.items=new Map([[c.url,c]]);
  h.respond(h.begin('https://api.example/video/streamList?video_id=15588271'),combined);
  assert.equal(h.current.mangoData.get('15588271')?.manifests[0],c.url);
  const refresh=h.begin('https://api.example/video/streamList?video_id=15588271');assert.equal(h.current.mangoData.size,0);
  h.respond(refresh,combined);assert.equal(h.current.mangoData.get('15588271').manifests[0],c.url);
  combined.data.info.drmFlag='1';h.respond(h.begin('https://api.example/video/streamList?video_id=15588271'),combined);
  h.observer.observeMedia(h.current,c);assert.equal(h.current.mangoData.size,0);
});

test('inline dispatch results associate only the successful actual main request, including HLS before metadata',()=>{
  for(const before of [true,false]){
    const h=setup(),combined=video(),root='https://associated.example/preview.m3u8?pm=api-current',actual=root+'&ftc=0&sftc=1';
    combined.data.info.trialtime='300';combined.data.stream=[{url:'',fileHash:'a'.repeat(32),videoWidth:960,videoHeight:540,disp:{status:'ok',info:root}}];
    const c={kind:'hls',url:actual,original_url:actual,at:Date.now(),headers:{cookie:'media-own-scope'}};
    h.current.items=new Map(before?[[actual,c]]:[]);
    h.respond(h.begin('https://api.example/video/streamList?video_id=15588271'),combined);
    if(!before){assert.equal(h.current.mangoData.size,0);h.current.items.set(actual,c);h.observer.observeMedia(h.current,c);}
    const data=h.current.mangoData.get('15588271');
    assert.equal(data.manifests[0],actual);assert.equal(data.inline_manifests[0].width,960);assert.equal(data.trial_duration,300);
    assert.equal(c.headers.cookie,'media-own-scope');
    combined.data.info.drmFlag='1';h.respond(h.begin('https://api.example/video/streamList?video_id=15588271'),combined);
    h.observer.observeMedia(h.current,c);assert.equal(h.current.mangoData.size,0);
  }
});

test('early inline declarations restore to their exact document and replacement metadata invalidates old media',()=>{
  const h=setup(true),combined=video(),root='https://cdn.example/inline.m3u8?pm=current';
  combined.data.info.trialtime=300;combined.data.stream=[{videoWidth:960,videoHeight:540,disp:{status:'ok',info:root}}];
  h.respond(h.begin('https://api.example/video/streamList?video_id=15588271'),combined);
  h.current={...h.state(),document:'wrong-document'};h.observer.attach(h.current);assert.equal(h.current.mangoInline,undefined);
  h.current=h.state();h.observer.attach(h.current);assert.equal(h.current.mangoInline[0].url,root);
  const c={kind:'hls',url:root+'&ftc=1&sftc=2',original_url:root+'&ftc=1&sftc=2',at:Date.now()};
  h.current.items=new Map([[c.url,c]]);h.observer.observeMedia(h.current,c);assert.equal(h.current.mangoData.size,1);
  combined.data.stream[0].disp.info='https://cdn.example/next.m3u8?pm=current';
  h.respond(h.begin('https://api.example/video/streamList?video_id=15588271'),combined);
  assert.equal(h.current.mangoData.size,0);
});
