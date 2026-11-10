const test=require('node:test'),assert=require('node:assert/strict'),vm=require('node:vm'),fs=require('node:fs');
const id='A'.repeat(36),source='https://related.example/current.mp4?signature=PRIVATE';
function card(){return {body:{card:{cardType:'CONTENT',content:{mediaId:id,serviceType:'NTV',videoQuality:{duration:20},vod:{playable:true,playback:{MPD:[{
 '@nvod:videoId':id,'@type':'static','@mediaPresentationDuration':'PT20S',Period:[{'@id':id,'@duration':'PT20S',AdaptationSet:[{Representation:[{
 '@width':'1280','@height':'720','@mimeType':'video/mp4',BaseURL:[source]}]}]}]}]}}}}}};}
function fixture(){
 const handlers={},streams=[],timers=new Map(),published=[];
 const state={naver:true,page:'https://m.naver.com/shorts/?serviceType=NTV&seedMediaId='+id,privateContext:false,cookieStore:'default'};
 let current=state;
 const browser={webRequest:{onHeadersReceived:{addListener:f=>handlers.headers=f},onBeforeRedirect:{addListener:f=>handlers.redirect=f},onErrorOccurred:{addListener:f=>handlers.error=f},
  filterResponseData:()=>{const stream={chunks:[],write(b){this.chunks.push(b);},close(){this.closed=true;},disconnect(){this.disconnected=true;}};streams.push(stream);return stream;}}};
 const c=vm.createContext({URL,Date,Uint8Array,TextDecoder,browser,setTimeout:f=>{const key={};timers.set(key,f);return key;},clearTimeout:key=>timers.delete(key)});
 for(const name of ['tiktok','naver','naver-response'])vm.runInContext(fs.readFileSync(__dirname+'/../../main/assets/web-browser/'+name+'.js','utf8'),c);
 c.stateFor=()=>current;c.publish=s=>published.push(s);vm.runInContext('globalThis.adapter=Thru3DNaverResponses(stateFor,publish);',c);
 const event={requestId:'owned',tabId:7,frameId:0,documentId:'doc-a',incognito:false,cookieStoreId:'default',method:'GET',statusCode:200,
  url:'https://associated.example/api/cards/seed?seedMediaId='+id,responseHeaders:[{name:'Content-Type',value:'application/json;charset=UTF-8'}]};
 const send=(data=card())=>{const bytes=new TextEncoder().encode(JSON.stringify(data)).buffer;streams.at(-1).ondata({data:bytes});streams.at(-1).onstop();return bytes;};
 return {handlers,streams,state,published,timers,event,send,adapter:c.adapter,navigate:()=>current=null};
}
test('owned received cards are normalized with untouched bytes and no API/domain replay or request credentials',()=>{
 const f=fixture();f.handlers.headers(f.event);assert.equal(f.streams.length,1);const bytes=f.send();
 assert.equal(f.streams[0].chunks[0],bytes);assert.equal(f.state.naverData.size,1);assert.equal([...f.state.naverData.values()][0].source,source);
 assert.equal([...f.state.naverData.values()][0].id,id);assert.equal(f.state.naverCapture.normalized,1);assert.equal(f.timers.size,0);
 assert.equal([...f.state.naverData.values()][0].headers,undefined);
 assert.equal(f.state.naverCapture.last_cards[0].id,id);assert.equal(f.state.naverCapture.last_cards[0].entries,1);
 assert.equal(JSON.stringify(f.state.naverCapture).includes('signature'),false);
});

test('an actual viewer-root seedType response supplies its initial card without a preselected media ID',()=>{
 const f=fixture();f.state.page='https://m.naver.com/shorts/';
 f.handlers.headers({...f.event,url:'https://associated.example/api/cards/initial?seedType=home&deviceType=PC'});f.send();
 assert.equal(f.state.naverData.size,1);assert.equal([...f.state.naverData.values()][0].id,id);
 assert.equal(f.state.naverCapture.normalized,1);
});
test('other frames/private partitions, failed responses and unrelated requests do not attach a filter',()=>{
 for(const changes of [{frameId:1},{incognito:true},{cookieStoreId:'other'},{statusCode:403},{method:'POST'},
  {url:'https://associated.example/unrelated?seedMediaId='+id},{url:'https://associated.example/api/anything'},
  {responseHeaders:[{name:'Content-Type',value:'text/html'}]}]){
  const f=fixture();f.handlers.headers({...f.event,...changes});assert.equal(f.streams.length,0);
 }
});
test('navigation and bounded response failures cannot leave a new declaration or a live filter',()=>{
 const changed=fixture();changed.handlers.headers(changed.event);changed.navigate();changed.send();
 assert.equal(changed.state.naverData,undefined);assert.equal(changed.timers.size,0);
 const large=fixture();large.handlers.headers(large.event);const bytes=new Uint8Array(256*1024+1).buffer;
 large.streams[0].ondata({data:bytes});assert.equal(large.streams[0].chunks[0],bytes);assert.equal(large.streams[0].disconnected,true);
 assert.equal(large.state.naverData,undefined);assert.equal(large.state.naverCapture.oversize,1);assert.equal(large.timers.size,0);
 const cancelled=fixture();cancelled.handlers.headers(cancelled.event);cancelled.adapter.cancel(cancelled.state);
 assert.equal(cancelled.streams[0].disconnected,true);assert.equal(cancelled.timers.size,0);
});

test('different CLIP representations sharing one declared HLS export retain their own received TS templates',()=>{
 const f=fixture(),raw=card(),c=raw.body.card.content;c.serviceType='CLIP';
 f.state.page=f.state.page.replace('NTV','CLIP');
 const reps=[1080,720].map(width=>({'@id':String(width),'@width':String(width),'@height':String(width===1080?1920:1280),
  '@codecs':'avc1.640028,mp4a.40.2','@nvod:m3u':'https://declared.example/shared.m3u8?signature=PRIVATE',BaseURL:['https://segments.example/current/'],
  SegmentTemplate:[{'@media':'$RepresentationID$-$Number%05d$.ts?signature=PRIVATE','@startNumber':'0','@timescale':'1000',SegmentTimeline:[{S:[{'@t':'0','@d':'10000','@r':'1'}]}]}]}));
 c.vod.playback.MPD[0].Period[0].AdaptationSet=[{'@mimeType':'video/MP2T',Representation:reps}];
 f.handlers.headers(f.event);f.send(raw);
 assert.equal(f.state.naverData.size,2);assert.deepEqual([...f.state.naverData.values()].map(v=>v.width),[1080,720]);
 assert.equal([...f.state.naverData.values()][0].timeline.representation,'1080');
});

test('rejected received cards expose bounded identity and fixed reason fields, never the original private declaration',()=>{
 const f=fixture(),raw=card();raw.body.card.content.vod.playable=false;
 f.handlers.headers(f.event);f.send(raw);
 const rejected=f.state.naverCapture.rejected_cards;
 assert.equal(rejected.length,1);assert.equal(rejected[0].id,id);assert.equal(rejected[0].playable,false);
 assert.equal(JSON.stringify(rejected).includes('PRIVATE'),false);assert.equal(JSON.stringify(rejected).includes('https:'),false);
 f.adapter.cancel(f.state);assert.equal(f.state.naverRejected.size,0);
});
