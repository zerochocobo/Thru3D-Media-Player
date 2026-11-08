const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const frame='https://geo.dailymotion.com/player/official.html#settings=opaque',page='https://www.dailymotion.com/video/x5kesuj',root='https://related.test:8443/current.m3u8?signature=exact';
function fixture(){
 const context=vm.createContext({URL,Date,innerWidth:1600,innerHeight:1000,getComputedStyle:()=>({})});
 for(const name of ['tiktok.js','dailymotion.js'])vm.runInContext(fs.readFileSync(path.join(__dirname,'../../main/assets/web-browser',name),'utf8'),context);
 const t=vm.runInContext('Thru3DDailymotion',context),metadata={id:'x5kesuj',info:{url:page,duration:187},stream:{url:root,stream_type:'vod',content_type:'video'}};
 const document={location:{href:frame},defaultView:{wrappedJSObject:{__PLAYER_CONFIG__:{metadata}}},querySelectorAll:()=>[v]};
 const v={id:'video',currentSrc:'blob:https://geo.dailymotion.com/current',isConnected:true,videoWidth:848,videoHeight:480,duration:186.75342,readyState:4,
  closest:s=>s==='.video_player'?{}:null,getBoundingClientRect:()=>({left:100,top:100,right:948,bottom:580,width:848,height:480})};
 const request={kind:'hls',url:root,at:Date.now(),request_id:'original'};
 const bodies=[{url:root,body:'#EXTM3U\n#EXTINF:187,\nsegment.ts\n#EXT-X-ENDLIST\n',request_id:'original',at:Date.now()}];
 return {t,v,document,metadata,request,bodies};
}
test('current official player metadata binds only the exact observed root and finite decoded programme',()=>{
 const f=fixture(),b=f.t.binding(f.v,[f.request],f.document,[f.v],f.bodies);
 assert.equal(b.id,'x5kesuj');assert.equal(b.page,page);assert.equal(b.frame,frame);assert.equal(b.root,root);assert.equal(b.width,848);assert.equal(b.expected_duration,187);
 assert.equal(f.t.page(page.replace('dailymotion.com','dailymotion.com.evil')),null);
 assert.equal(f.t.frame(frame.replace('geo.dailymotion.com','other.test')),false);
 assert.equal(f.t.address(root).port,'8443');
});
test('another programme, root selector, stale request or undeclared root never borrows the active video',()=>{
 for(const change of [f=>f.metadata.id='xOther',f=>f.metadata.info.duration=30,f=>f.request.url=root+'&different=1',
  f=>f.request.at=Date.now()-1800001,f=>f.request.kind='file',f=>f.metadata.info.url='https://other.test/video/x5kesuj']){
  const f=fixture();change(f);assert.equal(f.t.binding(f.v,[f.request],f.document,[f.v],f.bodies),null);
 }
});
test('advertising, multiple visible decoded players, protected media and live declarations remain in the page',()=>{
 for(const change of [f=>f.v.closest=()=>({}),f=>f.v.mediaKeys={},f=>f.v.seeking=true,f=>f.v.currentSrc='blob:https://other.test/current',
  f=>f.metadata.stream.drm=true,f=>f.metadata.stream.stream_type='live',f=>f.document.querySelectorAll=()=>[f.v,f.v]]){
  const f=fixture();change(f);assert.equal(f.t.binding(f.v,[f.request],f.document,[f.v],f.bodies),null);
 }
 const f=fixture();assert.equal(f.t.binding(f.v,[f.request],f.document,[f.v,{...f.v}],f.bodies),null);
});
test('getters and URL credentials cannot become a current stream declaration',()=>{
 const f=fixture();let calls=0;Object.defineProperty(f.metadata.stream,'url',{get(){calls++;return root;}});
 assert.equal(f.t.binding(f.v,[f.request],f.document,[f.v],f.bodies),null);assert.equal(calls,0);
 assert.equal(f.t.address('https://user:password@related.test/current.m3u8'),null);
});
test('original HLS bodies require the same actual request and follow only the declared root graph',()=>{
 const f=fixture(),other='https://ad.test/master.m3u8',entry={url:other,body:'#EXTM3U\n',request_id:'ad',at:Date.now()};
 const requests=[f.request,{url:other,kind:'hls',request_id:'ad',at:Date.now()}];
 assert.equal(f.t.manifests(root,requests,[...f.bodies,entry]).length,1);
 for(const change of [{request_id:'changed'},{at:Date.now()-1800001},{body:'not-hls'}])
  assert.equal(f.t.manifests(root,requests,[{...f.bodies[0],...change}]),null);
 assert.equal(f.t.manifests(root,requests,[]),null);
});
test('fragmented client references retain their original body and request while linking to the HTTP resource',()=>{
 const f=fixture(),child='https://related.test/leaf?signature=a%2Fb&literal=%23value',raw=child+'#client-marker';
 const parent={...f.bodies[0],body:'#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000000\n'+raw+'\n'};
 const entry={url:child,request_url:raw,request_id:'child',at:Date.now(),body:'#EXTM3U\n#EXTINF:187,\nsegment.ts#trace\n#EXT-X-ENDLIST\n'};
 const requests=[f.request,{kind:'hls',url:child,request_url:raw,request_id:'child',at:Date.now()}];
 const graph=f.t.manifests(root,requests,[parent,entry]);assert.equal(graph.length,2);assert.equal(graph[0].body,parent.body);
 assert.equal(graph[1].url,child);assert.equal(graph[1].request_url,raw);assert.equal(graph[1].body,entry.body);
 assert.equal(f.t.transport(raw),child);assert.equal(f.t.transport('https://user:password@related.test/leaf#trace'),null);
 assert.equal(f.t.manifests(root,requests,[parent,{...entry,request_url:child+'#different'}]).length,1);
});
