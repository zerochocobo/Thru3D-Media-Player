const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const context=vm.createContext({URL,Date,innerWidth:1600,innerHeight:1000,getComputedStyle:n=>n.style||{}});
vm.runInContext(fs.readFileSync(__dirname+'/../../main/assets/web-browser/tiktok.js','utf8')+'\n'+
 fs.readFileSync(__dirname+'/../../main/assets/web-browser/reddit.js','utf8')+';globalThis.r=Thru3DReddit;',context);
const r=context.r,id='1u8wxnn',page='https://www.reddit.com/r/aww/comments/'+id+'/title/',url='https://related-cdn.example/file.mp4?token=EXACT';
function fixture(){
 const source={url,dimensions:{width:480,height:854},videoCodec:'h264'},data={playbackMp4s:{duration:10,permutations:[{source}]}};
 const post={localName:'shreddit-post',parentElement:null,getAttribute:k=>({'id':'t3_'+id,permalink:page})[k]??null};
 const player={localName:'shreddit-player',parentElement:post,getAttribute:k=>({'post-id':'t3_'+id,'packaged-media-json':JSON.stringify(data)})[k]??null};
 const video={localName:'video',parentElement:null,getRootNode:()=>({host:player}),isConnected:true,readyState:4,mediaKeys:null,seeking:false,
  currentSrc:url,videoWidth:480,videoHeight:854,duration:10.942,currentTime:2,ended:false,
  getBoundingClientRect:()=>({left:200,top:100,right:680,bottom:954,width:480,height:854})};
 const requests=[{url,kind:'file',at:Date.now(),headers:{authorization:'OWN_REQUEST'}}];
 return {video,post,player,source,data,requests,document:{location:{href:page}}};
}
test('actual packaged source crosses shadow ownership and keeps current document and signed URL exact',()=>{
 const f=fixture(),b=r.binding(f.video,f.requests,f.document,[f.video]);assert.equal(b.id,id);assert.equal(b.source,url);
 assert.equal(b.document,page);assert.equal(b.expected_duration,10);assert.equal(b.protection_unverified,true);
 assert.equal(f.requests[0].headers.authorization,'OWN_REQUEST');assert.equal(b.binding,'rendered_post');
});
test('feed uses the real post permalink while a different detail cannot borrow the same player',()=>{
 const f=fixture();f.document.location.href='https://www.reddit.com/r/aww/';
 assert.equal(r.binding(f.video,f.requests,f.document,[f.video]).page,page);
 f.document.location.href=page.replace(id,'1otherid');assert.equal(r.binding(f.video,f.requests,f.document,[f.video]),null);
 for(const bad of ['https://www.reddit.com/login','https://www.reddit.com/r/aww/#x','https://reddit.com.evil/r/aww/']){
  f.document.location.href=bad;assert.equal(r.binding(f.video,f.requests,f.document,[f.video]),null);
 }
});
test('missing or wrong owner and declared permalink cannot be replaced by the current URL',()=>{
 for(const key of ['post-id','id','permalink']){
  const f=fixture(),node=key==='post-id'?f.player:f.post,get=node.getAttribute;
  node.getAttribute=k=>k===key?null:get(k);assert.equal(r.declaration(f.video,f.document),null);
 }
 const f=fixture();f.post.getAttribute=k=>k==='id'?'t3_different':k==='permalink'?page:null;
 assert.equal(r.declaration(f.video,f.document),null);
});
test('a real alternative quality, modified query or missing/stale request cannot become the current file',()=>{
 const f=fixture();for(const request of [{...f.requests[0],url:url+'&other=1'},{...f.requests[0],at:Date.now()-1800001},{...f.requests[0],kind:'hls'}])
  assert.equal(r.binding(f.video,[request],f.document,[f.video]),null);
 f.source.url=url+'&other=1';assert.equal(r.declaration(f.video,f.document),null);
});
test('protected, promoted, hidden and undecoded media stay excluded',()=>{
 for(const mutate of [f=>f.video.mediaKeys={},f=>f.source.encrypted=true,f=>f.data.drm={},f=>f.video.seeking=true,
  f=>f.video.videoHeight=640,f=>f.video.readyState=1,f=>f.player.style={opacity:'0'},
  f=>{const get=f.post.getAttribute;f.post.getAttribute=k=>k==='is-promoted'?'':get(k);}]){
  const f=fixture();mutate(f);assert.equal(r.binding(f.video,f.requests,f.document,[f.video]),null);
 }
});
test('duplicate declarations and same-file renderers remain ambiguous; other feed posts are independent',()=>{
 const f=fixture();f.data.playbackMp4s.permutations.push({source:{...f.source}});assert.equal(r.read(f.video,f.document),null);
 f.data.playbackMp4s.permutations.pop();assert.equal(r.binding(f.video,f.requests,f.document,[f.video,{...f.video}]),null);
 const other=fixture();other.video.currentSrc=url+'&another=1';
 assert.notEqual(r.binding(f.video,f.requests,f.document,[f.video,other.video]),null);
});
test('the preview renderer cannot borrow a real player and an ended clip requests replay at zero',()=>{
 const f=fixture();f.video.ended=true;f.video.currentTime=f.video.duration;assert.equal(r.binding(f.video,f.requests,f.document,[f.video]).start_seconds,0);
 f.video.getRootNode=()=>({host:{localName:'shreddit-preview-video-lazy',parentElement:f.player}});
 assert.equal(r.binding(f.video,f.requests,f.document,[f.video]),null);
});

function gifFixture(){
 const f=fixture();f.video.duration=1.36;
 const values={'post-id':'t3_'+id,'src':url,'gif':'','post-type':'gif'};
 f.player.getAttribute=k=>values[k]??null;
 f.post.getAttribute=k=>({'id':'t3_'+id,permalink:page,'post-type':'gif'})[k]??null;
 return {...f,values};
}

test('direct GIF declaration stays tied to the same post, rendered source and observed file',()=>{
 const f=gifFixture(),b=r.binding(f.video,f.requests,f.document,[f.video]);
 assert.equal(b.binding,'rendered_gif');assert.equal(b.declared_gif,true);assert.equal(b.expected_duration,1.36);
 assert.equal(b.source,url);assert.equal(b.protection_unverified,true);assert.equal(b.has_audio,undefined);
 assert.equal(r.binding(f.video,[],f.document,[f.video]),null);
 assert.equal(r.binding(f.video,f.requests,f.document,[f.video,{...f.video}]),null);
});

test('GIF markers cannot bypass malformed or protected packaged JSON, another source or missing post intent',()=>{
 for(const change of [f=>f.values.gif='false',f=>f.values['post-type']='video',f=>f.values.src=url+'&other=1',
  f=>f.values['packaged-media-json']='{broken',f=>f.values['packaged-media-json']=JSON.stringify({drm:true}),
  f=>{const get=f.post.getAttribute;f.post.getAttribute=k=>k==='post-type'?'video':get(k);},
  f=>f.video.mediaKeys={},f=>f.video.videoWidth=0,f=>f.video.duration=Infinity]){
  const f=gifFixture();change(f);assert.equal(r.binding(f.video,f.requests,f.document,[f.video]),null);
 }
});

test('timeline controls keep independent current targets and remove overlays and listeners on disposal',()=>{
 const listeners=new Map(),created=[],selected=[];
 const view={addEventListener:(n,f)=>listeners.set(n,f),removeEventListener:(n,f)=>{assert.equal(listeners.get(n),f);listeners.delete(n);}};
 const mount={append(n){n.parentElement=this;}};
 const doc={defaultView:view,body:mount,createElement:()=>({dataset:{},style:{},remove(){this.parentElement=null;}})};
 context.Thru3DPlayButton={create:(_d,overlay,_site,clicked)=>{
  const control={host:{dataset:{},isConnected:true},button:{disabled:false},enabled(v){this.button.disabled=!v;},dispose(){this.host.isConnected=false;},clicked};
  created.push(control);return control;
 }};
 const a={video:fixture().video,page,source:url,epoch:1,key:'a'},b={...a,video:fixture().video,key:'b'};
 const controls=r.controls(doc,t=>selected.push(t));controls.sync([a,b],true);assert.equal(created.length,2);
 const changed={...b,key:'b2',epoch:2};controls.sync([a,changed],true);assert.equal(created.length,2);
 listeners.get('click')({isTrusted:true,composedPath:()=>[created[1].host],preventDefault(){},stopImmediatePropagation(){}});
 assert.equal(selected[0],changed);assert.equal(created[0].host.dataset.thru3dRedditPage,page);
 listeners.get('click')({isTrusted:false,composedPath:()=>[created[0].host]});assert.equal(selected.length,1);
 controls.sync([changed],true);assert.equal(created[0].host.isConnected,false);assert.equal(created[1].host.isConnected,true);
 controls.dispose();assert.equal(created[1].host.isConnected,false);assert.equal(listeners.size,0);
 const naver=r.controls(doc,t=>selected.push(t),'naver');naver.sync([changed],true);
 assert.equal(created[2].host.dataset.thru3dNaver,'beta');assert.equal(created[2].host.dataset.thru3dNaverPage,page);
 assert.equal(created[2].host.dataset.thru3dReddit,undefined);naver.dispose();assert.equal(listeners.size,0);
});
