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

test('ordinary long VOD leaves above 160 KiB remain paired and original bytes are forwarded unchanged',()=>{
  const h=setup();h.api();h.hls(root,master);
  const segment='segment-'+ 'a'.repeat(600)+'.cmfv';
  const longLeaf=`#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="${key}"\n`+
    Array.from({length:500},(_,i)=>`#EXTINF:6.0,\n${segment}?part=${i}\n`).join('')+'#EXT-X-ENDLIST\n';
  assert.ok(Buffer.byteLength(longLeaf)>160*1024&&Buffer.byteLength(longLeaf)<2*1024*1024);
  for(const url of [video,audio]){
    const r=h.hls(url,longLeaf);
    assert.equal(Buffer.concat(r.s.writes).toString(),longLeaf);
    assert.equal(r.s.closed,true,'An accepted original response is delivered to the website');
  }
  assert.equal(h.current.niconicoData.size,1,'Both observed long leaves must complete the real graph');
  const variant=h.current.niconicoData.get('sm9').variants[0];
  assert.equal(variant.duration,3000);assert.equal(variant.audio_duration,3000);
  assert.equal(variant.resources.length,1,'Segment text is not added to the private descriptor');
});

test('long leaf allowance preserves smaller master budget and the native 2 MiB leaf ceiling',()=>{
  const h=setup();h.api();
  const oversizedMaster=master+'#'+ 'x'.repeat(160*1024),r=h.hls(root,oversizedMaster);
  assert.equal(r.s.disconnected,true);assert.equal(h.current.niconicoMaster,null);
  assert.equal(Buffer.concat(r.s.writes).toString(),oversizedMaster);
  const g=setup();g.api();g.hls(root,master);
  const oversizedLeaf=leaf+'#'+ 'x'.repeat(2*1024*1024),large=g.hls(video,oversizedLeaf);
  assert.equal(large.s.disconnected,true);assert.equal(g.current.niconicoLeaves.size,0);
  assert.equal(Buffer.concat(large.s.writes).toString(),oversizedLeaf);
});
test('early document metadata attaches exactly and waits when status arrives after response bytes',()=>{
  const h=setup(true),r=h.begin();const text=JSON.stringify({meta:{status:201},data:{contentUrl:root}});h.body(r,text);
  assert.equal(r.s.closed,undefined);h.current=h.state();h.observer.attach(h.current);h.headers(r);
  assert.equal(h.current.niconicoMeta.root,root);assert.equal(Buffer.concat(r.s.writes).toString(),text);
  const other=setup(true);other.api();other.current={...other.state(),document:'replacement'};other.observer.attach(other.current);assert.equal(other.current.niconicoMeta,undefined);
});
test('foreign tab/frame/container and obsolete responses cannot supply a graph',()=>{
  const h=setup();for(const change of [{tabId:-1},{frameId:1},{documentId:'other'},{incognito:true},{cookieStoreId:'other'}])assert.equal(h.begin(undefined,change).s,undefined);
  assert.equal(h.begin('https://api.example/v1/watch/invalid/access-rights/hls').s,undefined);
  const old=h.begin(),fresh=h.begin();h.api(fresh);h.api(old);assert.equal(old.s.disconnected,true);assert.equal(h.current.niconicoMeta.root,root);
});
test('same-document prefetched graph stays separate until the watch ID actually changes',()=>{
  const h=setup();h.api();h.hls(root,master);h.hls(video,leaf);h.hls(audio,leaf);
  const nextRoot='https://related.example/next-master.m3u8',nextVideo='https://related.example/next-video.m3u8',nextAudio='https://related.example/next-audio.m3u8';
  const r=h.begin('https://api.example/v1/watch/sm10/access-rights/hls');h.headers(r);
  h.body(r,JSON.stringify({meta:{status:201},data:{contentUrl:nextRoot}}));
  h.hls(nextRoot,master.replaceAll(video,nextVideo).replaceAll(audio,nextAudio));h.hls(nextVideo,leaf);h.hls(nextAudio,leaf);
  assert.deepEqual([...h.current.niconicoData.keys()],['sm9'],'Prefetch must not replace the currently selected video');
  h.current.page='https://www.nicovideo.jp/watch/sm10';h.observer.observeMedia(h.current);
  assert.deepEqual([...h.current.niconicoData.keys()],['sm10']);
  assert.equal(h.current.niconicoData.get('sm10').root,nextRoot);
  h.current.page=page;h.observer.observeMedia(h.current);
  assert.deepEqual([...h.current.niconicoData.keys()],['sm9'],'Back within the same owned document can use its exact original graph');
  h.observer.cancel(h.current);assert.equal(h.current.niconicoGraphs.size,0);assert.equal(h.current.niconicoData.size,0);
});
test('homepage prefetch waits for a watch ID and graph history is bounded without evicting current',()=>{
  const h=setup();h.current.page='https://www.nicovideo.jp/';h.api();h.hls(root,master);h.hls(video,leaf);h.hls(audio,leaf);
  assert.equal(h.current.niconicoData.size,0);
  h.current.page=page;h.observer.observeMedia(h.current);assert.equal(h.current.niconicoData.size,1);
  for(let i=10;i<18;i++)h.api(h.begin('https://api.example/v1/watch/sm'+i+'/access-rights/hls'));
  assert.equal(h.current.niconicoGraphs.size,4);assert.ok(h.current.niconicoGraphs.has('sm9'));
  assert.deepEqual([...h.current.niconicoData.keys()],['sm9']);
});
test('observed playlists without an access API wait for the exact rendered declaration',()=>{
  const h=setup();const replies=[h.hls(root,master),h.hls(video,leaf),h.hls(audio,leaf)];
  assert.equal(h.current.niconicoData.size,0,'Observed HLS alone does not identify a programme');
  h.observer.observeRendered(h.current,{id:'sm10',page,root});assert.equal(h.current.niconicoData.size,0);
  h.observer.observeRendered(h.current,{id:'sm9',page,root:root+'?different-signature'});assert.equal(h.current.niconicoData.size,0);
  h.observer.observeRendered(h.current,{id:'sm9',page,root});
  const bound=h.current.niconicoData.get('sm9');assert.equal(bound.root,root);assert.equal(bound.binding,'rendered_player');
  assert.equal(bound.variants.length,1);assert.equal(h.observer.resource(h.current,key),true);
  for(let i=0;i<replies.length;i++)assert.equal(Buffer.concat(replies[i].s.writes).toString(),[master,leaf,leaf][i]);
  h.current.page='https://www.nicovideo.jp/watch/sm10';
  h.observer.observeRendered(h.current,{id:'sm10',page:h.current.page,root});
  assert.equal(h.current.niconicoData.size,0,'A route change cannot relabel the old player root as the next video');
});
test('rendered fallback cannot borrow another API identity or accept protected/incomplete HLS',()=>{
  const h=setup();h.api();h.hls(root,master);h.hls(video,leaf);h.hls(audio,leaf);
  h.current.page='https://www.nicovideo.jp/watch/sm10';
  h.observer.observeRendered(h.current,{id:'sm10',page:h.current.page,root});assert.equal(h.current.niconicoData.size,0);
  const g=setup();g.hls(root,master);g.hls(video,leaf);g.hls(audio,leaf.replace('AES-128','SAMPLE-AES'));
  g.observer.observeRendered(g.current,{id:'sm9',page,root});assert.equal(g.current.niconicoData.size,0);
  for(let i=0;i<40;i++)g.hls('https://related.example/prefetch-'+i+'.m3u8',leaf);
  assert.ok(g.current.niconicoPlaylists.size<=32);assert.equal(g.current.niconicoData.size,0);
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
