const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const code='Chunk8-jurw',page='https://www.instagram.com/reel/'+code+'/',url='https://related.example/current.mp4?selector=exact%2Fvalue';
function element(name,attrs={},children=[],text=''){
 const n={localName:name,children,textContent:text,getAttribute:k=>attrs[k]||null};for(const c of children)c.parentElement=n;return n;
}
function mpd(options={}){
 const rep=element('Representation',{id:'v1',width:'720',height:'1280',bandwidth:'1000000',mimeType:'video/mp4',codecs:'avc1.64001F'},[
  element('BaseURL',{},[],url),element('SegmentBase',{indexRange:'845-900'},[element('Initialization',{range:'0-844'})])]);
 const period=element('Period',{},[element('AdaptationSet',{},[rep])]),root=element('MPD',{type:options.live?'dynamic':'static',mediaPresentationDuration:'PT0H0M4.967S'},[period]);
 const walk=n=>[n,...n.children.flatMap(walk)];
 return {documentElement:root,getElementsByTagNameNS:(_,name)=>options.protected&&name==='ContentProtection'?[element('ContentProtection')]:walk(root).filter(n=>n.localName===name)};
}
function fixture(){
 const xmlDoc=mpd(),context=vm.createContext({URL,Date,innerWidth:1600,innerHeight:1000,getComputedStyle:()=>({}),DOMParser:class{parseFromString(){return xmlDoc;}}});
 for(const name of ['tiktok.js','instagram.js'])vm.runInContext(fs.readFileSync(path.join(__dirname,'../../main/assets/web-browser',name),'utf8'),context);
 const t=vm.runInContext('Thru3DInstagram',context),script={isConnected:true,textContent:JSON.stringify({code,has_audio:false})};
 const document={querySelectorAll:s=>s.startsWith('meta')?[{content:'instagram://media?id=12345678901234567'}]:[script]};
 const model={coreVideoPlayerMetaData:{videoFBID:'12345678901234567'},manifest:'<MPD>synthetic DOM fixture</MPD>'};
 const parent={parentElement:null,__reactProps$fixture:{children:{props:model}}};
 const v={currentSrc:'blob:https://www.instagram.com/current',parentElement:parent,isConnected:true,videoWidth:720,videoHeight:1280,duration:4.966666,readyState:4,ended:true,
  getBoundingClientRect:()=>({left:100,top:100,right:437,bottom:699,width:337,height:599})};
 const request={kind:'file',url:url+'&bytestart=901&byteend=718220',at:Date.now(),headers:{authorization:'only-this-range'}};
 return {t,v,document,model,script,request,xmlDoc};
}
test('current rendered post and explicit silent declaration bind an actual payload while preserving the declared file URL',()=>{
 const f=fixture(),b=f.t.binding(f.v,[f.request],page,[f.v],f.document);assert.equal(b.id,code);assert.equal(b.has_audio,false);assert.equal(b.video.url,url);assert.equal(b.audio,null);
 assert.equal(b.video.requests[0],f.request.url);assert.equal(f.request.headers.authorization,'only-this-range');assert.equal(f.v.ended,true);
});
test('indexes, changed selectors, expired evidence and another post cannot borrow the payload',()=>{
 const f=fixture(),graph=f.t.manifestDocument(f.xmlDoc),track=graph.tracks[0];
 for(const change of [{url:url+'&bytestart=845&byteend=900'},{url:url.replace('exact','other')+'&bytestart=901&byteend=999'},
  {url:url+'&bytestart=901&bytestart=902&byteend=999'},{at:Date.now()-1800001},{at:Date.now()+1000}])assert.equal(f.t.payloadRequest(track,{...f.request,...change}),false);
 f.model.coreVideoPlayerMetaData.videoFBID='12345678901234568';assert.equal(f.t.binding(f.v,[f.request],page,[f.v],f.document),null);
});
test('missing or changed explicit audio metadata, EME and a visible neighbour stay in the page',()=>{
 for(const change of [f=>f.script.textContent=JSON.stringify({code:'other_post',has_audio:false}),f=>f.script.textContent=JSON.stringify({code,has_audio:true}),
  f=>f.v.mediaKeys={},f=>f.v.seeking=true,f=>f.v.currentSrc='blob:https://different.example/video']){
  const f=fixture();change(f);assert.equal(f.t.binding(f.v,[f.request],page,[f.v],f.document),null);
 }
 const f=fixture();assert.equal(f.t.binding(f.v,[f.request],page,[f.v,{...f.v}],f.document),null);
 assert.equal(f.t.audioEvidence(f.document,code),false);f.script.textContent=JSON.stringify({code,has_audio:true});assert.equal(f.t.audioEvidence(f.document,code),true);
});
test('static finite clear SegmentBase manifests are required; silence cannot hide a missing real audio track',()=>{
 const f=fixture(),graph=f.t.manifestDocument(f.xmlDoc);assert(Math.abs(graph.duration-4.967)<1e-9);
 assert.equal(f.t.manifestDocument(mpd({protected:true})),null);assert.equal(f.t.manifestDocument(mpd({live:true})),null);
 assert.equal(f.t.manifest('<!DOCTYPE MPD><MPD/>'),null);
 assert.equal(f.t.choose(graph,[f.request],720,1280,true),null);
 assert.equal(f.t.choose(graph,[f.request],472,840,false),null);
 for(const bad of ['https://www.instagram.com.evil/reel/'+code+'/',page+'#other','http://www.instagram.com/reel/'+code+'/'])assert.equal(f.t.page(bad),null);
});
test('observed same-post payloads preserve decoded size while index preloads never become selected files',()=>{
 const f=fixture(),graph=f.t.manifestDocument(f.xmlDoc),second={...graph.tracks[0],id:'v2',url:url+'&quality=second',bandwidth:2000000};graph.tracks.push(second);
 const index={...f.request,url:second.url+'&bytestart=845&byteend=900'},payload={...f.request,url:second.url+'&bytestart=901&byteend=999'};
 assert.equal(f.t.choose(graph,[f.request,index],720,1280,false).video.id,'v1');assert.equal(f.t.choose(graph,[f.request,payload],720,1280,false).video.id,'v2');
});
test('a remounted return element must match the complete original content identity',()=>{
 const f=fixture(),before=f.t.binding(f.v,[f.request],page,[f.v],f.document),identity=f.t.identity(before);
 f.v.currentSrc='blob:https://www.instagram.com/remounted';
 const after=f.t.binding(f.v,[f.request],page,[f.v],f.document);assert.equal(f.t.matchesIdentity(after,identity),true);
 for(const key of ['id','page','media_id','manifest','revision','width','height','duration','has_audio','video_url','audio_url'])
  assert.equal(f.t.matchesIdentity(after,{...identity,[key]:typeof identity[key]==='number'?identity[key]+1:String(identity[key])+'changed'}),false,key);
 assert.equal(f.t.matchesIdentity(null,identity),false);assert.equal('headers' in identity,false);
});
