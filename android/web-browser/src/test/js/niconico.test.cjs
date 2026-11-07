const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const n=vm.runInNewContext(fs.readFileSync(path.join(__dirname,'../../main/assets/web-browser/niconico.js'),'utf8')+'\nThru3DNiconico',
  {URL,getComputedStyle:v=>v.style||{},innerWidth:1600,innerHeight:1000});
const page='https://www.nicovideo.jp/watch/sm9',root='https://related.example/current/master.m3u8?signature=exact';
const master='#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="main",DEFAULT=YES,URI="audio.m3u8?signature=audio"\n'+
  '#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=512x384,CODECS="avc1.64001e,mp4a.40.2",AUDIO="audio"\nvideo.m3u8?signature=video\n';
const leaf='#EXTM3U\n#EXT-X-MAP:URI="init.mp4?signature=init"\n#EXT-X-KEY:METHOD=AES-128,URI="key?signature=key"\n#EXTINF:6.0,\n1.ts\n#EXTINF:4.1,\n2.ts\n#EXT-X-ENDLIST\n';
const meta=()=>n.rights({meta:{status:201},data:{contentUrl:root,accessRightKey:'PRIVATE_KEY'}},page);
function graph(){const m=n.master(master,root),v=m.variants[0],vl=n.leaf(leaf,v.video),al=n.leaf(leaf,v.audio);return {m,v,leaves:new Map([[v.video,vl],[v.audio,al]]),
  requests:[...new Set([...vl.resources,...al.resources])].map(url=>({url,kind:'segment',at:Date.now()})).concat([root,v.video,v.audio].map(url=>({url,kind:'hls',at:Date.now()})))};}
function dom(){return {isConnected:true,readyState:4,currentSrc:'blob:https://www.nicovideo.jp/current',duration:10.1,videoWidth:512,videoHeight:384,paused:false,
  getBoundingClientRect:()=>({left:100,top:100,right:900,bottom:700,width:800,height:600})};}

test('only the current trusted watch page and its actual access response declare a root',()=>{
  assert.equal(n.page(page),'sm9');assert.equal(n.page('https://www.nicovideo.jp.evil/watch/sm9'),null);assert.equal(n.page(page.replace('https:','http:')),null);
  assert.equal(n.access('https://actual-api.example/v1/watch/sm9/access-rights/hls',page),true);
  assert.equal(n.access('https://actual-api.example/v1/watch/sm10/access-rights/hls',page),false);
  assert.equal(meta().root,root);assert.equal(JSON.stringify(meta()).includes('PRIVATE'),false);
  assert.equal(n.rights({meta:{status:403},data:{contentUrl:root}},page),null);
});
test('master resolves the declared video/audio graph without a CDN allowlist or URL edits',()=>{
  const {m,v}=graph();assert.equal(m.variants.length,1);assert.equal(v.video,'https://related.example/current/video.m3u8?signature=video');assert.equal(v.width,512);
  for(const body of [master.replace('URI="audio.m3u8?signature=audio"',''),master.replace('RESOLUTION=512x384','RESOLUTION=0x384'),
    master+'#EXT-X-DEFINE:NAME="value",VALUE="opaque"\n',master+'#EXT-X-SESSION-KEY:METHOD=SAMPLE-AES\n'])assert.equal(n.master(body,root),null);
});
test('standard identity AES is supported; DRM and incomplete/live leaves cannot form a binding',()=>{
  const result=n.leaf(leaf,root);assert.equal(result.duration,10.1);assert.equal(result.resources.length,2);
  for(const body of [leaf.replace('AES-128','SAMPLE-AES'),leaf.replace('METHOD=AES-128','METHOD=AES-128,KEYFORMAT="com.example.drm"'),
    leaf.replace(',URI="key?signature=key"',''),leaf.replace('#EXT-X-ENDLIST','')])assert.equal(n.leaf(body,root),null);
  assert.ok(n.leaf(leaf.replace('METHOD=AES-128','METHOD=AES-128,KEYFORMAT="identity"'),root));
});
test('all three exact successful observed HLS requests and both durations are required',()=>{
  const g=graph();assert.equal(n.records(meta(),g.m,g.leaves,g.requests,page).length,1);
  for(const removed of [root,g.v.video,g.v.audio])assert.equal(n.records(meta(),g.m,g.leaves,g.requests.filter(r=>r.url!==removed),page).length,0);
  assert.equal(n.records(meta(),g.m,g.leaves,g.requests.map(r=>({...r,at:Date.now()-1800001})),page).length,0);
  assert.equal(n.records(meta(),g.m,g.leaves,g.requests,page.replace('sm9','sm10')).length,0);
  g.leaves.get(g.v.audio).duration=15;assert.equal(n.records(meta(),g.m,g.leaves,g.requests,page).length,0);
});
test('visible overlapping advertising, media keys and ambiguous programme elements block takeover',()=>{
  const g=graph(),data=n.records(meta(),g.m,g.leaves,g.requests,page),main=dom(),ad={...dom(),currentSrc:'https://ads.example/advert.mp4',duration:15,videoWidth:640,videoHeight:360};
  assert.equal(n.owner(data,page,[main,ad]),null);ad.paused=true;assert.equal(n.owner(data,page,[main,ad]),null);
  ad.style={display:'none'};assert.equal(n.owner(data,page,[main,ad]),main);
  assert.equal(n.owner(data,page,[main,{...main}]),null);main.mediaKeys={};assert.equal(n.owner(data,page,[main]),null);
});
test('binding retains exact selected leaves and decoded dimensions; changed signatures cannot substitute',()=>{
  const g=graph(),data=n.records(meta(),g.m,g.leaves,g.requests,page),main=dom();
  const b=n.binding(main,data,g.requests,page,[main]);assert.equal(b.video,g.v.video);assert.equal(b.audio,g.v.audio);assert.equal(b.expected_duration,10.1);assert.equal(b.master_playlist,master);
  assert.equal(n.binding(main,data,g.requests.map(r=>({...r,url:r.url+'&changed=1'})),page,[main]),null);
  main.videoWidth=640;assert.equal(n.binding(main,data,g.requests,page,[main]),null);
});
