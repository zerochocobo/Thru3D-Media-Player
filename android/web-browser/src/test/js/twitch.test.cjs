const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const t=vm.runInNewContext(fs.readFileSync(path.join(__dirname,'../../main/assets/web-browser/twitch.js'),'utf8')+'\nThru3DTwitch',
  {URL,Date,getComputedStyle:v=>v.style||{},innerWidth:1600,innerHeight:1000});
const page='https://clips.twitch.tv/PublicClip',source='https://actual-related.example/clip.mp4',signed=source+'?token=opaque%20value&sig=exact';
function parts(){return [{data:{clip:{id:'12345',playbackAccessToken:{signature:'exact',value:'opaque value'},videoQualities:[{quality:'1080',sourceURL:source}]}}},
  {data:{clip:{id:'12345',slug:'PublicClip',durationSeconds:32}}}];}
const request=(change={})=>({kind:'file',url:signed,at:Date.now(),...change});
function data(body=parts(),requests=[request()]){const store=new Map();t.merge(store,t.metadata(JSON.stringify(body),page));return t.records(store,requests,page);}
function video(change={}){return {isConnected:true,mediaKeys:null,readyState:4,currentSrc:signed,videoWidth:1920,videoHeight:1080,duration:32.099,
  getBoundingClientRect:()=>({left:100,top:100,right:1100,bottom:700,width:1000,height:600}),...change};}

test('only official clip pages have a public identity; no live/VOD or embedded page inference',()=>{
  assert.equal(t.page(page),'PublicClip');assert.equal(t.page('https://www.twitch.tv/ea/clip/PublicClip?tt_medium=clips_api'),'PublicClip');
  for(const u of ['http://clips.twitch.tv/PublicClip',page+'#fragment','https://clips.twitch.tv.evil/PublicClip','https://evil@clips.twitch.tv/PublicClip',
    'https://www.twitch.tv/ea','https://www.twitch.tv/videos/123','https://player.twitch.tv/?video=v123','https://clips.twitch.tv/embed?clip=PublicClip',
    'https://clips.twitch.tv/Bad%2FClip'])assert.equal(t.page(u),null,u);
});
test('actual API fragments do not disable metadata observation or change signed media handling',()=>{
  assert.equal(t.api('https://actual-api.example/gql#origin=twilight'),true);
  for(const u of ['http://actual-api.example/gql','https://user:secret@actual-api.example/gql','https://actual-api.example/other'])assert.equal(t.api(u),false);
  assert.equal(t.address(signed+'#origin=twilight'),null);
});
test('current slug/duration join a separately observed quality response only by the same clip ID',()=>{
  assert.equal(data().length,1);const reversed=parts().reverse();assert.equal(data(reversed).length,1);
  const wrong=parts();wrong[1].data.clip.id='54321';assert.equal(data(wrong).length,0);
  wrong[1].data.clip.id='12345';wrong[1].data.clip.slug='OtherClip';assert.equal(data(wrong).length,0);
});
test('actual signed request must match every declared authentication field without inventing a URL',()=>{
  for(const url of [signed+'&quality=720',signed.replace('exact','other'),signed.replace('opaque%20value','other'),signed+'&sig=exact',signed.replace('clip.mp4','ad.mp4'),signed.replace('actual-related','other')])
    assert.equal(data(parts(),[request({url})]).length,0,url);
  assert.equal(data(parts(),[request({url:source+'?sig=exact&token=opaque+value'})]).length,1);
});
test('no API credentials or token declaration are exported with the normalized file',()=>{
  const result=data()[0];assert.deepEqual(Object.keys(result).sort(),['expected_duration','id','qualities','revision','source']);
  assert.equal(result.source,signed);assert.equal(result.expected_duration,32);
  assert.equal(t.binding(video(),data(),[request()],page,[video()]),null,'the selected element itself must own the binding');
});
test('fresh successful file observations are required; no playlist, stale request or future timestamp',()=>{
  for(const change of [{kind:'hls'},{at:Date.now()-1800001},{at:Date.now()+60000}])assert.equal(data(parts(),[request(change)]).length,0);
});
test('ready current element, dimensions, main duration and exact source must agree',()=>{
  const good=video();assert.equal(t.binding(good,data(),[request()],page,[good]).id,'PublicClip');
  for(const change of [{mediaKeys:{}},{duration:10},{videoHeight:720},{currentSrc:signed+'&changed=1'},{readyState:0},{isConnected:false},{style:{display:'none'}}]){
    const v=video(change);assert.equal(t.binding(v,data(),[request()],page,[v]),null);
  }
});
test('visible second players and ads cannot borrow the current clip declaration',()=>{
  const v=video(),ad=video({currentSrc:'https://ad.example/ad.mp4',duration:6});assert.equal(t.binding(v,data(),[request()],page,[v,ad]),null);
  ad.style={display:'none'};assert.equal(t.binding(v,data(),[request()],page,[v,ad]).id,'PublicClip');
});
test('GraphQL errors, oversize input and conflicting current clip identities stay unbound',()=>{
  const broken=parts();broken[0].errors=[{message:'restricted'}];assert.equal(data(broken).length,0);
  assert.equal(t.metadata(' '.repeat(2*1024*1024+1),page).length,0);
  const ambiguous=parts();ambiguous.push({data:{clip:{id:'999',slug:'PublicClip',durationSeconds:32}}});assert.equal(data(ambiguous).length,0);
});
