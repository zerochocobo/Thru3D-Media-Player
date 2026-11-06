const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm'),path=require('node:path');
const id='q326831cny0',page=`https://v.qq.com/x/page/${id}.html`;
const raw=()=>({code:0,preview:216,vl:{vi:[{vid:id,enc:'0',drm:0,isprevid:0,vw:1280,vh:720,td:216,fn:'opaque.hash.mp4',ul:{ui:[]}}]}});
function setup(options={}){
  const events={},streams=new Map(),publications=[],state={tencent:true,page,key:'1:0',document:'doc-one',privateContext:false,cookieStore:'firefox-default'};let current=options.early?null:state;
  const webRequest={filterResponseData(k){const s={written:[],write(b){this.written.push(Buffer.from(b));},close(){this.closed=true;},disconnect(){this.disconnected=true;}};streams.set(k,s);return s;}};
  for(const k of ['onBeforeRequest','onHeadersReceived','onBeforeRedirect','onErrorOccurred'])webRequest[k]={addListener(fn,filter){events[k]=fn;assert(filter.urls.every(u=>/\/(?:getvinfo|getinfo|proxyhttp|vinfo_proxy)\*/.test(u)));assert(filter.types.includes('script'));}};
  const context=vm.createContext({URL,TextDecoder,Uint8Array,setTimeout:()=>1,clearTimeout:()=>{},browser:{webRequest}});
  for(const n of ['tencent.js','tencent-response.js'])vm.runInContext(fs.readFileSync(path.resolve(__dirname,'../../main/assets/web-browser/'+n),'utf8'),context);
  context.stateFor=()=>current;context.publish=s=>publications.push(s.tencentStatus);context.hasFrame=()=>!!current;
  vm.runInContext('globalThis.observer=Thru3DTencentResponses(stateFor,publish,hasFrame)',context);
  return {state,events,streams,publications,observer:context.observer,replace(){current=null;},connect(){current=state;context.observer.attach(state);},
    start(k='one',method='GET',extra={}){const d={requestId:k,url:'https://new-associated-api.example/getvinfo?vid='+id,method,
      tabId:1,frameId:0,documentId:'doc-one',incognito:false,cookieStoreId:'firefox-default',documentUrl:page,originUrl:page,...extra};events.onBeforeRequest(d);return {d,s:streams.get(k)};},
    headers(d,status=200,mime='application/json'){events.onHeadersReceived({...d,statusCode:status,responseHeaders:[{name:'Content-Type',value:mime}]});}};
}
test('successful current response forwards original bytes and normalizes without replay',()=>{
  const h=setup(),{d,s}=h.start();h.headers(d);const text='callback('+JSON.stringify(raw())+');';
  s.ondata({data:Buffer.from(text)});s.onstop();assert.equal(Buffer.concat(s.written).toString(),text);
  assert.equal(h.state.tencentData.size,1);assert.equal([...h.state.tencentData.values()][0].id,id);
});

test('the page vinfo_proxy POST is observed with bounded structural diagnostics and legacy wrapper validation',()=>{
  const h=setup(),{d,s}=h.start('proxy','POST',{url:'https://new-related-api.example/vinfo_proxy'});h.headers(d);
  const text=JSON.stringify({ret:0,data:{proxyhttp:{errCode:0,enc:1,vinfo:JSON.stringify(raw())},privateUrl:'https://private.example/signed'}});
  s.ondata({data:Buffer.from(text)});s.onstop();
  assert.equal(Buffer.concat(s.written).toString(),text);assert.equal(h.state.tencentData.size,1);
  assert(h.state.tencentShape.some(n=>n.path==='response.data.proxyhttp.vinfo'));assert(!JSON.stringify(h.state.tencentShape).includes('private.example'));
});

test('an opaque successful API envelope retains only its scoped flow and public ID for the processed page result',()=>{
  const h=setup(),{d,s}=h.start('proxy','POST',{url:'https://new-related-api.example/vinfo_proxy'});h.headers(d);
  const text=JSON.stringify({ret:0,data:{flowid:'synthetic-flow-00000000001',playInfo:{vid:id},videoInfo:{vid:id,duration:216},proxyhttp:{enc:1,vinfo:'opaque wire data'}}});
  s.ondata({data:Buffer.from(text)});s.onstop();
  assert.equal(Buffer.concat(s.written).toString(),text);assert.equal(h.state.tencentData,undefined);
  assert.deepEqual(JSON.parse(JSON.stringify([...h.state.tencentEnvelopes.values()])),[{id,flowid:'synthetic-flow-00000000001',duration:216}]);
});

test('an opaque early envelope is restored only to the same eventual document',()=>{
  const h=setup({early:true}),{d,s}=h.start('early-proxy','POST',{url:'https://new-related-api.example/vinfo_proxy'});h.headers(d);
  s.ondata({data:Buffer.from(JSON.stringify({ret:0,data:{flowid:'synthetic-flow-00000000001',playInfo:{vid:id},proxyhttp:{vinfo:'opaque'}}}))});s.onstop();h.connect();
  assert.equal(h.state.tencentEnvelopes.size,1);assert.equal(h.state.tencentData,undefined);
});
test('headers may follow stream stop without dropping a valid body',()=>{
  const h=setup(),{d,s}=h.start();s.ondata({data:Buffer.from(JSON.stringify(raw()))});s.onstop();assert.equal(h.state.tencentData,undefined);
  h.headers(d,200,'application/javascript; charset=UTF-8');assert.equal(h.state.tencentData.size,1);
});
test('failed status, unrelated response and changed document never publish a candidate',()=>{
  for(const variant of ['status','html','id','context']){
    const h=setup(),{d,s}=h.start(),r=raw();if(variant==='id')r.vl.vi[0].vid='x1111111111';
    s.ondata({data:Buffer.from(JSON.stringify(r))});if(variant==='context')h.replace();s.onstop();
    h.headers(d,variant==='status'?403:200,variant==='html'?'text/html':'application/json');assert.equal(h.state.tencentData,undefined);
  }
});
test('metadata budgets disconnect the filter after forwarding the oversized chunk',()=>{
  const h=setup(),{s}=h.start(),bytes=Buffer.alloc(2*1024*1024+1);s.ondata({data:bytes});
  assert(s.disconnected);assert.equal(s.written[0].length,bytes.length);assert.equal(h.state.tencentData,undefined);
});
test('redirected responses cannot later restore a stale identity',()=>{
  const h=setup(),{d,s}=h.start();h.events.onBeforeRedirect(d);h.headers(d);s.ondata({data:Buffer.from(JSON.stringify(raw()))});s.onstop();
  assert(s.disconnected);assert.equal(h.state.tencentData,undefined);
});
test('a rejected filter still forwards when disconnect is unavailable before stream start',()=>{
  const h=setup(),{d,s}=h.start();s.disconnect=()=>{throw new Error('uninitialized');};
  h.headers(d,200,'application/octet-stream');const bytes=Buffer.from(JSON.stringify(raw()));s.ondata({data:bytes});s.onstop();
  assert.deepEqual(Buffer.concat(s.written),bytes);assert(s.closed);assert.equal(h.state.tencentData,undefined);
});

test('early head response attaches only to its eventual exact document, before or after completion',()=>{
  for(const finishFirst of [true,false]){
    const h=setup({early:true}),{d,s}=h.start();h.headers(d);
    if(!finishFirst)h.connect();s.ondata({data:Buffer.from(JSON.stringify(raw()))});s.onstop();
    if(finishFirst){assert.equal(h.publications.length,0);h.connect();}
    assert.equal(h.state.tencentData.size,1);assert.equal(h.state.tencentCapture.early_responses,1);assert(s.closed);
  }
});

test('early metadata cannot cross document, tab, frame, private context or container',()=>{
  for(const extra of [{documentId:'other'},{tabId:2},{frameId:1},{incognito:true},{cookieStoreId:'other-container'}]){
    const h=setup({early:true}),{d,s}=h.start('one','GET',extra);h.headers(d);s.ondata({data:Buffer.from(JSON.stringify(raw()))});s.onstop();h.connect();
    assert.equal(h.state.tencentData,undefined);
  }
  for(const extra of [{documentUrl:'https://untrusted.example/watch',originUrl:'https://untrusted.example/watch'},{originUrl:'https://untrusted.example'},{tabId:-1,frameId:-1}]){
    const h=setup({early:true});assert.equal(h.start('one','GET',extra).s,undefined);
  }
});

test('navigation clears an early response even when Gecko has no documentId',()=>{
  const h=setup({early:true}),{d,s}=h.start('one','GET',{documentId:undefined});h.headers(d);
  h.observer.navigate({tabId:1,frameId:0,type:'main_frame'});s.ondata({data:Buffer.from(JSON.stringify(raw()))});s.onstop();h.connect();
  assert.equal(h.state.tencentData,undefined);assert(s.disconnected);
});
