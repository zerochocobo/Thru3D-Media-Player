const {test}=require('node:test');
const assert=require('node:assert/strict');
const vm=require('node:vm'),fs=require('node:fs'),path=require('node:path');
const root=path.join(__dirname,'../../main/assets/web-browser');
const c=vm.createContext({URL});vm.runInContext(fs.readFileSync(path.join(root,'douyin.js'),'utf8'),c);
const api=vm.runInContext('Thru3DDouyin',c);
const id='6961737553342991651',page=`https://www.douyin.com/video/${id}`;
const url='https://cdn.test/full.mp4?signature=synthetic&quality=720';
const raw=()=>({aweme_id:id,video:{duration:19782,play_addr:{width:576,height:1024,url_list:[url]}}});
const player=()=>({videoWidth:576,videoHeight:1024,duration:19.735,currentSrc:url+'&temp=1&__vid=synthetic'});
const request=()=>({kind:'file',url:player().currentSrc});
test('stable detail and modal identity, conflicting/duplicate/foreign IDs rejected',()=>{
 assert.equal(api.page(page).id,id);assert.equal(api.page('https://www.douyin.com/?modal_id='+id).id,id);
 for(const value of [page+'?modal_id=9999999999999999999',page+'?modal_id='+id+'&modal_id='+id,
  page.replace('.com/','.com.evil/'),page.replace('www.','user@www.'),page.replace('https:','http:'),
  'https://www.douyin.com/live/'+id,'https://www.douyin.com/?modal_id=1'])assert.equal(api.page(value),null);
});
test('numeric 64-bit IDs use the original JSON token without rounding or rewriting other numeric fields',()=>{
 const text=JSON.stringify({status_code:0,aweme_detail:raw(),other:123}).replace('"aweme_id":"'+id+'"','"aweme_id":'+id);
 const parsed=api.parse(text);assert.equal(parsed.aweme_detail.aweme_id,id);assert.equal(parsed.other,123);
 assert.equal(api.normalize(parsed.aweme_detail).id,id);
 const exponent=api.parse('{"aweme_id":6.961737553342991651e18}');assert.equal(typeof exponent.aweme_id,'number');
 assert.equal(api.normalize({...raw(),aweme_id:exponent.aweme_id}),null,'never guess an ID from an exponent or rounded value');
});
test('only observed player additions may differ; every original signature parameter stays bound',()=>{
 assert.ok(api.matches(url,player().currentSrc));assert.ok(api.matches(url,url+'&testst=0'));
 assert.ok(api.matches(url,'https://cdn.test/full.mp4?quality=720&signature=synthetic&__vid=id'));
 for(const value of [url.replace('synthetic','other'),url+'&another=1',url.replace('cdn.test','other.test'),url+'&quality=360',url+'#fragment'])
  assert.equal(api.matches(url,value),false);
 assert.equal(api.matches(url+'&temp=original',url+'&temp=changed'),false);
 const declared=url+'&cquery=old&l=old',observed=url+'&cquery=new&l=new&__vid='+id;
 assert.equal(api.matches(declared,observed),false);assert.equal(api.matches(declared,observed,id),true);
 assert.equal(api.matches(declared,observed.replace('cdn.test','new-cdn.test'),id),true,'A bound player identity can use its actual CDN alias');
 assert.equal(api.matches(declared,observed.replace(id,'7674225615168824549'),id),false);
 assert.equal(api.matches(declared,observed+'&__vid='+id,id),false);
 assert.equal(api.matches(declared,observed.replace('synthetic','changed'),id),false);
});
test('known C-type authentication rotates only around the exact declared TOS object identity',()=>{
 const suffix='/video/tos/cn/tos-cn-ve-15/object-fixture-1234567890/encoding-fixture-1234/';
 const declared='https://cdn.test/'+'a'.repeat(32)+'/65000000'+suffix+'?a=6383&mime_type=video_mp4&btag=old&dy_q=old&cquery=old&l=old';
 const observed='https://cdn.test/'+'b'.repeat(32)+'/65000001'+suffix+'?a=6383&mime_type=video_mp4&btag=new&dy_q=new&cquery=new&l=new&temp=1';
 assert.equal(api.matches(declared,observed),false,'the site content identity is required');
 assert.equal(api.matches(declared,observed,id),true);
 assert.equal(api.matches(declared,observed.replace('cdn.test','other.test'),id),true,'The exact declared object may be served by another related CDN');
 for(const value of [observed.replace('object-fixture','other-fixture'),
  observed.replace('encoding-fixture','different-fixture'),observed.replace('tos-cn-ve-15','tos-cn-ve-16'),
  observed.replace('video_mp4','audio_mp4'),observed+'&unexpected=1',observed+'&__vid='+id+'&__vid='+id,
  observed.replace('b'.repeat(32),'not-a-signature')])assert.equal(api.matches(declared,value,id),false);
});
test('bind current full video, excluding splash, silent auxiliary player and stale/preloaded content',()=>{
 const data=api.normalize(raw());assert.ok(data);
 assert.ok(api.binding(data,page,player(),[request()]));
 for(const video of [{...player(),duration:2.6},{...player(),videoWidth:0},
  {...player(),mediaKeys:{}},{...player(),currentSrc:url.replace('synthetic','other')}])assert.equal(api.binding(data,page,video,[request()]),null);
 assert.equal(api.binding(data,page.replace(id,'7674225615168824549'),player(),[request()]),null);
 assert.equal(api.binding(data,page,player(),[]),null);
});
test('MSE nominates a unique decoded owner and exactly one declared observed file',()=>{
 const data=api.normalize(raw()),video={...player(),currentSrc:'blob:page'};
 const auxiliary={videoWidth:0,videoHeight:0,duration:NaN,currentSrc:'blob:auxiliary'};
 assert.equal(api.owner([data],page,[video,auxiliary]),video);
 assert.equal(api.owner([data],page,[video,{...video}]),null);
 assert.equal(api.owner([data],page,[{...video,mediaKeys:{}}]),null);
 const bound=api.binding(data,page,video,[request()]);assert.ok(bound);
 assert.equal(bound.data.observed_file,request().url);
 assert.equal(api.binding(data,page,{...video,seeking:true},[request()]),null);
 assert.equal(api.binding(data,page,video,[{kind:'file',url:url.replace('synthetic','other')}]),null);
 const alternate=url+'&temp=second';
 assert.equal(api.binding(data,page,video,[request(),{kind:'file',url:alternate}]),null,'do not guess between observed alternatives');
 assert.equal(api.binding(data,page,video,[{kind:'dash',url:request().url}]),null,'MSE chunks are not whole files');
});
test('MSE audio comes from the current video audio metadata, never its music soundtrack',()=>{
 const sound='https://cdn.test/audio.mp4?signature=synthetic';
 const sample=raw();sample.music={play_url:{uri:'https://cdn.test/unrelated-song.mp3'}};
 sample.video.bit_rate_audio=[{audio_meta:{file_id:'current-audio',url_list:{main_url:sound,backup_url:sound}}}];
 const data=api.normalize(sample);assert.equal(data.audio.length,1);assert.deepEqual(Array.from(data.audio[0].urls),[sound]);
 const video={...player(),currentSrc:'blob:page'};
 const result=api.binding(data,page,video,[request(),{kind:'file',url:sound}]);
 assert.equal(result.data.observed_audio,sound);assert.equal(result.data.observed_file,request().url);
 assert.equal(api.binding(data,page,video,[request(),{kind:'file',url:sound},{kind:'file',url:sound+'&temp=other'}]),null);
 const noSound=api.binding(data,page,video,[request(),{kind:'file',url:sample.music.play_url.uri}]);
 assert.equal(noSound.data.observed_audio,undefined,'unrelated music cannot repair missing authorized audio');
});

test('MSE may demux the same observed full MP4 for its declared video and audio',()=>{
 const sample=raw();sample.video.bit_rate_audio=[{audio_meta:{file_id:'muxed-file',url_list:{main_url:url}}}];
 const data=api.normalize(sample),video={...player(),currentSrc:'blob:page'};
 const result=api.binding(data,page,video,[request()]);
 assert.ok(result);assert.equal(result.data.observed_file,request().url);
 assert.equal(result.data.observed_muxed,true);assert.equal(result.data.observed_audio,undefined);
 assert.equal(api.binding(data,page,video,[]),null);
 const counts=api.diagnostics([data],page,video,[request()]);assert.equal(counts.audio_video_overlap,1);
});

test('handoff carries only the observed declared representation instead of the whole quality catalogue',()=>{
 const sample=raw();sample.video.bit_rate=Array.from({length:32},(_,i)=>({play_addr:{width:1280+i,height:720,
  url_list:['https://provider.test/other-'+i+'.mp4?opaque='+'x'.repeat(2000)]}}));
 const data=api.normalize(sample);assert.ok(data);assert.ok(JSON.stringify(data).length>60000);
 for(const video of [player(),{...player(),currentSrc:'blob:page'}]){
  const result=api.binding(data,page,video,[request()]);assert.ok(result);
  assert.equal(result.data.video.length,1);assert.ok(JSON.stringify(result.data).length<2000);
  assert.equal(result.data.id,id);assert.equal(result.data.duration,data.duration);
 }
});
test('repeated metadata preserves each declared variant and the currently observed signed files',()=>{
 const before={id,duration:20,video:Array.from({length:12},(_,i)=>({width:720,height:1280,urls:[url+'&variant='+i]})),
  audio:[{id:'sound',urls:['https://cdn.test/audio.mp4?signature=old']}]};
 const same=api.merge(before,before);
 for(let i=0;i<before.video.length;i++)assert.ok(same.video[i].urls.includes(before.video[i].urls[0]),'Do not evict a track own URL when dimensions repeat');
 const next={...before,video:before.video.map(t=>({...t,urls:t.urls.map(u=>u+'&revision=new')})),audio:[{id:'sound',urls:['https://cdn.test/audio.mp4?signature=new']}]};
 const observed=[before.video[0].urls[0]+'&temp=1',before.audio[0].urls[0]];
 const merged=api.merge(before,next,observed);
 assert.ok(merged.video.some(t=>t.urls.includes(before.video[0].urls[0])));
 assert.ok(merged.audio[0].urls.includes(before.audio[0].urls[0]));
 assert.ok(merged.video.every(t=>t.urls.length<=8));
});
test('direct file fallback requires the exact observed source and its own unique page ID',()=>{
 const video={...player(),currentSrc:url+'&__vid='+id};const requests=[{kind:'file',url:video.currentSrc}];
 const result=api.direct([],page,video,requests);assert.ok(result);assert.equal(result.data.observed_direct,true);assert.equal(result.data.id,id);
 for(const source of [url,url+'&__vid=7674225615168824549',video.currentSrc+'&__vid='+id,video.currentSrc+'#fragment'])
  assert.equal(api.direct([],page,{...video,currentSrc:source},[{kind:'file',url:source}]),null);
 assert.equal(api.direct([],page,video,[]),null);assert.equal(api.direct([],page,{...video,mediaKeys:{}},requests),null);
 assert.equal(api.direct([],page,{...video,seeking:true},requests),null);
 assert.equal(api.direct([{id,duration:120}],page,video,requests),null,'cannot replace an explicitly known full duration with a preview');
 assert.equal(api.direct([],page,video,requests,{id_matches:1,ads:1}),null);
 assert.equal(api.direct([],page,video,requests,{id_matches:1,encrypted:1}),null);
});
test('reject DRM, ads, image albums, invalid durations and unbounded track data',()=>{
 for(const change of [{is_ads:true},{images:[{}]},{is_preview:true},{aweme_id:Number(id)}])assert.equal(api.normalize({...raw(),...change}),null);
 for(const change of [{duration:0},{has_drm:true},{is_encrypted:true},{play_addr:{width:9000,height:1024,url_list:[url]}}])
  assert.equal(api.normalize({...raw(),video:{...raw().video,...change}}),null);
});
test('content bridge exports readiness only for the bound video and invalidates SPA changes',()=>{
 const timers=[],ports=[],signal=()=>({listeners:[],addListener(fn){this.listeners.push(fn)},emit(m){this.listeners.forEach(fn=>fn(m))}});
 const owner={parentElement:null,getAttribute:k=>k==='data-e2e-vid'?id:null,'__reactProps$fixture':{awemeInfo:raw()}};
 const main={...player(),getAttribute:()=>null,parentElement:owner,currentSrc:'blob:https://www.douyin.com/synthetic',isConnected:true,readyState:4,currentTime:3,paused:false,ended:false,addEventListener(){},pause(){this.paused=true},play(){this.paused=false}};
 const splash={...main,duration:2.6,videoWidth:1080,videoHeight:1920,currentSrc:'https://static.test/splash.mp4'};
 const context={URL,location:{href:page},navigator:{userAgent:'fixture'},setTimeout(fn){timers.push(fn)},addEventListener(){},
  performance:{now(){return 0},getEntriesByType(){return [
   ...Array.from({length:600},()=>({name:'https://static.test/file'})),
   {name:'https://www.douyin.com/aweme/v1/web/aweme/detail/?aweme_id='+id+'&token=private-timing-secret',workerStart:10,initiatorType:'fetch'},
   {name:'https://www-hj.douyin.com/aweme/v1/web/aweme/detail/?aweme_id=7674225615168824549'},
   {name:'https://new-video-api.test/aweme/v1/web/aweme/detail/?aweme_id='+id},
   {name:'https://www.douyin.com/aweme/v1/web/aweme/related/?token=private-timing-secret'}]}},
  document:{nodeType:9,querySelectorAll(s){return s==='video'?[splash,main]:s==='script:not([src])'?[{id:'RENDER_DATA',textContent:id+' video_model bit_rate_audio'}]:[]}},MutationObserver:class{observe(){} disconnect(){}},
  browser:{runtime:{connect(){const p={onMessage:signal(),onDisconnect:signal(),postMessage(){},disconnect(){}};ports.push(p);return p},
   connectNative(){const p={onMessage:signal(),onDisconnect:signal(),messages:[],postMessage(m){this.messages.push(m)},disconnect(){}};ports.push(p);return p}}}};
 vm.createContext(context);vm.runInContext(fs.readFileSync(path.join(root,'douyin.js'),'utf8'),context);
 vm.runInContext(fs.readFileSync(path.join(root,'douyin-current.js'),'utf8'),context);
 vm.runInContext(fs.readFileSync(path.join(root,'media.js'),'utf8'),context);
 const flush=()=>{let n=0;while(timers.length){assert.ok(++n<100);timers.shift()()}};flush();
 const native=ports.find(p=>p.messages),network=ports.find(p=>!p.messages);
 native.onMessage.emit({action:'network_policy',douyin:true,diagnostics:true});flush();
 const counts=native.messages.at(-1).videos[1].douyin_dom;
 assert.equal(counts.resource_entries,512);assert.equal(counts.resource_api,4);assert.equal(counts.resource_detail,3);
 assert.equal(counts.resource_detail_current,2);assert.equal(counts.resource_detail_other_host,2);
 assert.equal(counts.resource_detail_worker,1);assert.equal(counts.resource_detail_fetch,1);assert.equal(counts.resource_related,1);
 assert.equal(counts.inline_model,1);assert.equal(counts.inline_audio,1);
 assert.ok(!JSON.stringify(counts).includes('private-timing-secret'));assert.ok(Object.values(counts).every(Number.isInteger));
 network.onMessage.emit({type:'network',page,candidates:[request()],douyin:[api.normalize(raw())]});flush();
 assert.equal(native.messages.at(-1).videos[0].douyin_ready,false);assert.equal(native.messages.at(-1).videos[1].douyin_ready,true);
 const shared=raw();shared.video.bit_rate_audio=[{audio_meta:{file_id:'shared-file',url_list:{main_url:url}}}];
 owner['__reactProps$fixture'].awemeInfo=shared;
 network.onMessage.emit({type:'network',page,candidates:[request()],douyin:[api.normalize(shared)]});flush();
 assert.equal(native.messages.at(-1).videos[1].douyin.observed_muxed,true);
 assert.equal(native.messages.at(-1).videos[1].douyin_ready,true);
 native.onMessage.emit({action:'pause_media',token:1});flush();assert.equal(native.messages.at(-1).videos[1].douyin_ready,true);
 context.location.href='https://www.douyin.com/video/7674225615168824549';native.onMessage.emit({action:'snapshot'});flush();
 assert.ok(native.messages.at(-1).videos.every(v=>!v.douyin_ready));
 native.onMessage.emit({action:'network_policy',douyin:false,diagnostics:false});flush();
 assert.ok(native.messages.at(-1).videos.every(v=>v.douyin_dom===null));
});
const event=()=>{const listeners=[];return {listeners,addListener(fn,filter,flags){listeners.push({fn,filter,flags})},fire(d){listeners.forEach(l=>l.fn(d))}}};
function fixture(connected=true,tabFields={}){
 const streams=new Map(),timers=new Map();let sequence=0;
 const webRequest=Object.fromEntries(['onBeforeRequest','onHeadersReceived','onSendHeaders','onBeforeRedirect','onErrorOccurred','onCompleted'].map(k=>[k,event()]));
 webRequest.filterResponseData=id=>{const s={written:[],write(b){this.written.push(Buffer.from(b))},close(){this.closed=true},disconnect(){this.disconnected=true}};streams.set(id,s);return s};
 const browser={runtime:{id:'test',onConnect:event()},webRequest,cookies:{getAll:async()=>[]}};
 const context=vm.createContext({browser,URL,TextDecoder,Uint8Array,Date,setTimeout(fn){timers.set(++sequence,fn);return sequence},clearTimeout(id){timers.delete(id)}});
 for(const name of ['douyin.js','douyin-response.js','network.js'])vm.runInContext(fs.readFileSync(path.join(root,name),'utf8'),context);
 const messages=[],port={name:'thru3d_network',sender:{id:'test',tab:{id:1,...tabFields},frameId:0,url:page,documentId:'doc'},onMessage:event(),onDisconnect:event(),postMessage(m){messages.push(m)},disconnect(){this.onDisconnect.fire()}};
 const update=(url=page,enabled=true)=>port.onMessage.fire({type:'context',page:url,enabled:false,douyin:enabled,reset:true});
 const connect=()=>{browser.runtime.onConnect.fire(port);update()};if(connected)connect();
 const begin=(extra={})=>{const d={requestId:String(++sequence),url:'https://www.douyin.com/aweme/v1/web/aweme/detail/?aweme_id='+id,method:'GET',tabId:1,frameId:0,documentId:'doc',documentUrl:page,type:'xmlhttprequest',...extra};webRequest.onBeforeRequest.fire(d);return {d,stream:streams.get(d.requestId)}};
 const header=d=>webRequest.onHeadersReceived.fire({...d,statusCode:200,responseHeaders:[{name:'Content-Type',value:'application/json'}]});
 const finish=(s,data={status_code:0,aweme_detail:raw()})=>{const body=Buffer.from(typeof data==='string'?data:JSON.stringify(data));s.ondata({data:body.buffer.slice(body.byteOffset,body.byteOffset+body.byteLength)});s.onstop();assert.deepEqual(Buffer.concat(s.written),body)};
 return {streams,timers,webRequest,browser,messages,port,update,connect,begin,header,finish,last:()=>messages.at(-1)};
}
test('a cold detail response before the content port retains metadata without borrowing request credentials',()=>{
 const f=fixture(false),e=f.begin();assert.ok(e.stream);f.header(e.d);f.finish(e.stream);
 assert.equal(f.last(),undefined);f.connect();assert.equal(f.last().douyin[0].id,id);
 assert.equal(f.last().candidates.length,0,'metadata is not a replayable request');
 const cached={...e.d,requestId:'cached',url,method:'GET',type:'media',statusCode:200,responseHeaders:[{name:'Content-Type',value:'video/mp4'}]};
 f.webRequest.onHeadersReceived.fire(cached);assert.equal(f.last().candidates.length,0,'cached headers do not invent credentials');
});
test('numeric detail IDs remain exact while the response forwarded to the website is byte-identical',()=>{
 const f=fixture(),e=f.begin();f.header(e.d);
 const body=JSON.stringify({status_code:0,aweme_detail:raw()}).replace('"aweme_id":"'+id+'"','"aweme_id":'+id);
 f.finish(e.stream,body);assert.equal(f.last().douyin[0].id,id);
 assert.equal(f.last().douyin_observation.id_matches,1);assert.equal(f.last().douyin_observation.normalized,1);
 assert.ok(!JSON.stringify(f.last().douyin_observation).includes(id));
});

test('trusted main-site requests accept related API domains while keeping document and credential ownership',()=>{
 for(const origin of ['https://new-video-api.test','https://www-hj.douyin.com','https://video-provider.test:8443']){
 const mirror=origin+'/aweme/v1/web/aweme/detail/?aweme_id='+id;
 for(const mode of ['direct','cold','worker']){
  const f=fixture(mode!=='cold'),extra=mode==='worker'?{tabId:-1,frameId:-1,parentFrameId:-1,documentId:undefined,
   documentUrl:undefined,originUrl:page,incognito:false}:{};
  const e=f.begin({url:mirror,...extra});assert.ok(e.stream,'The trusted document owns its actual cross-domain detail request');
  f.header(e.d);f.finish(e.stream);if(mode==='cold')f.connect();
  assert.equal(f.last().douyin[0].id,id);assert.equal(f.last().candidates.length,0);
  const blocking=f.webRequest.onBeforeRequest.listeners.find(l=>l.flags?.includes('blocking'));
  assert.ok(blocking.filter.urls.includes('https://*/aweme/v1/web/aweme/detail/*'));
 }
 }
 const mirror='https://new-video-api.test/aweme/v1/web/aweme/detail/?aweme_id='+id;
 for(const extra of [{documentUrl:'https://untrusted.test/'},{documentUrl:'https://www.douyin.com.evil.test/'},
  {documentId:'different-document'},{tabId:2,documentUrl:'https://untrusted.test/'},
  {url:mirror.replace('https:','http:')},{url:mirror.replace('https://','https://user@')}]){
  const f=fixture(),e=f.begin({url:mirror,...extra});
  assert.equal(e.stream,undefined,'Related hosts do not replace trusted document ownership or transport validation');
 }
});
test('worker/prefetch metadata is usable but never gives worker media requests a parent-frame credential scope',()=>{
 const f=fixture(),e=f.begin({frameId:-1,documentId:'worker',documentUrl:undefined,originUrl:page,type:'other'});
 assert.ok(e.stream);f.header(e.d);f.finish(e.stream);
 assert.equal(f.last().douyin[0].id,id);assert.equal(f.last().douyin_observation.worker,1);assert.equal(f.last().douyin_observation.prefetch,1);
 const blocking=f.webRequest.onBeforeRequest.listeners.find(l=>l.flags?.includes('blocking'));
 assert.ok(blocking.filter.types.includes('other'));
 const resource={...e.d,requestId:'worker-file',url,statusCode:200,type:'media',requestHeaders:[{name:'Cookie',value:'must-not-transfer'}],responseHeaders:[{name:'Content-Type',value:'video/mp4'}]};
 f.webRequest.onSendHeaders.fire(resource);f.webRequest.onHeadersReceived.fire(resource);
 assert.equal(f.last().candidates.length,0);
});

test('tabless service-worker detail metadata needs one exact current owner and never lends file credentials',()=>{
 const f=fixture(),worker={tabId:-1,frameId:-1,parentFrameId:-1,documentId:undefined,documentUrl:undefined,originUrl:'https://www.douyin.com/service-worker.js',incognito:false};
 const e=f.begin(worker);assert.ok(e.stream,'A service worker has no tab ID in Firefox');f.header(e.d);f.finish(e.stream);
 assert.equal(f.last().douyin[0].id,id);assert.equal(f.last().douyin_observation.tabless_worker,1);
 const media={...e.d,requestId:'unscoped-file',url,statusCode:200,requestHeaders:[{name:'Cookie',value:'private-worker-only'}],responseHeaders:[{name:'Content-Type',value:'video/mp4'}]};
 f.webRequest.onSendHeaders.fire(media);f.webRequest.onHeadersReceived.fire(media);
 assert.equal(f.last().candidates.length,0,'Worker media retains the strict original tab/frame requirement');
 for(const extra of [{originUrl:'https://evil.test/worker.js'},{originUrl:undefined},{documentUrl:'https://evil.test/'},{incognito:true},{method:'POST'},
  {url:e.d.url+'&aweme_id='+id},{url:e.d.url.replace(id,'7674225615168824549')}])
  assert.equal(f.begin({...worker,...extra}).stream,undefined);
 const scoped=fixture(true,{cookieStoreId:'container-a'});
 assert.equal(scoped.begin({...worker,cookieStoreId:'container-b'}).stream,undefined,'Known cookie containers cannot cross');
 const other={...f.port,sender:{...f.port.sender,tab:{id:2},documentId:'other-doc'},onMessage:event(),onDisconnect:event(),postMessage(){},disconnect(){this.onDisconnect.fire()}};
 f.browser.runtime.onConnect.fire(other);other.onMessage.fire({type:'context',page,enabled:false,douyin:true});
 assert.equal(f.begin(worker).stream,undefined,'Two same-content tabs are ambiguous');
 other.disconnect();const stale=f.begin(worker);assert.ok(stale.stream);
 f.update('https://www.douyin.com/video/7674225615168824549');f.header(stale.d);
 const late=raw();late.video.play_addr.url_list=[url.replace('synthetic','late-worker')];f.finish(stale.stream,{status_code:0,aweme_detail:late});
 assert.ok(!JSON.stringify(f.last().douyin).includes('late-worker'),'A late worker response cannot bind to the new page');
 f.update(page,false);assert.equal(f.begin(worker).stream,undefined,'Disabled tabs cannot gain an implicit worker opt-in');
});
test('same-origin SPA metadata can use an older document URL when Gecko supplies no document ID',()=>{
 const f=fixture(),e=f.begin({documentId:undefined,documentUrl:'https://www.douyin.com/'});assert.ok(e.stream);f.header(e.d);f.finish(e.stream);
 assert.equal(f.last().douyin[0].id,id);
 const unrelated=f.begin({documentId:undefined,documentUrl:'https://evil.test/',originUrl:'https://evil.test/'});
 assert.equal(unrelated.stream,undefined);
});
test('response body is forwarded before parsing; late headers and SPA preserve only the original document',()=>{
 const f=fixture(),e=f.begin();f.finish(e.stream);assert.equal(e.stream.closed,true);assert.equal(f.last().douyin.length,0);
 f.header(e.d);assert.equal(f.last().douyin[0].id,id);assert.equal(f.timers.size,0);
 const next=f.begin();f.update('https://www.douyin.com/?modal_id=7674225615168824549');f.header(next.d);f.finish(next.stream);
 assert.equal(f.last().douyin[0].id,id,'metadata never relabels the current modal');
 assert.equal(f.begin({documentId:'other'}).stream,undefined);
 const active=f.begin();f.update(page,false);assert.equal(active.stream.disconnected,true);assert.equal(f.timers.size,0);
});
test('preloaded recommendations cannot evict the current video or replace its previous signed address',()=>{
 const f=fixture(),e=f.begin();f.header(e.d);f.finish(e.stream);
 const replaced=raw();replaced.video.play_addr.url_list=[url.replace('synthetic','refreshed')];
 const refresh=f.begin();f.header(refresh.d);f.finish(refresh.stream,{status_code:0,aweme_detail:replaced});
 assert.ok(f.last().douyin[0].video[0].urls.includes(url));
 const related=f.begin();f.header(related.d);f.finish(related.stream,{status_code:0,aweme_list:Array.from({length:30},(_,i)=>({...raw(),aweme_id:String(7674225615168800000n+BigInt(i))}))});
 assert.ok(f.last().douyin.some(d=>d.id===id));assert.ok(f.last().douyin.length<=16);
});
test('oversize, invalid JSON, HTTP errors and disconnect release all response filters',()=>{
 for(const action of ['oversize','invalid','http','disconnect']){
  const f=fixture(),e=f.begin();
  if(action==='oversize')e.stream.ondata({data:new ArrayBuffer(4*1024*1024+1)});
  if(action==='invalid'){f.header(e.d);e.stream.ondata({data:new TextEncoder().encode('{').buffer});e.stream.onstop();}
  if(action==='http')f.webRequest.onHeadersReceived.fire({...e.d,statusCode:403,responseHeaders:[]});
  if(action==='disconnect')f.port.disconnect();
  assert.equal(f.timers.size,0);assert.equal(f.last().douyin.length,0);
 }
});
