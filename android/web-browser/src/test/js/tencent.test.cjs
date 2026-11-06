const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const context=vm.createContext({URL});
vm.runInContext(fs.readFileSync(require('node:path').resolve(__dirname,'../../main/assets/web-browser/tencent.js'),'utf8')+';globalThis.adapter=Thru3DTencent;',context);
const T=context.adapter,id='q326831cny0',doc=`https://v.qq.com/x/page/${id}.html`;
const source='https://new-related-cdn.example/current/opaque.hash.mp4?signature=current';
const raw=()=>({code:0,preview:216,vl:{vi:[{vid:id,enc:'0',drm:0,isprevid:0,vw:1280,vh:720,td:216,fn:'opaque.hash.mp4',encryption:'8265898',ul:{ui:[{url:'https://new-related-cdn.example/current/'}]}}]}});
const player=()=>({closest:()=>({}),isConnected:true,mediaKeys:null,videoWidth:1280,videoHeight:720,duration:216,currentSrc:source});
const request={url:source,original_url:source,kind:'file'};
test('public clip, cover and cover root identities remain on official HTTPS pages',()=>{
  assert.equal(T.page(doc).id,id);
  assert.equal(T.page(`https://v.qq.com/x/cover/mzc00200example/${id}.html`).cover,'mzc00200example');
  assert.equal(T.page('https://v.qq.com/x/cover/mzc00200example.html').id,'');
  for(const u of ['http://v.qq.com/x/page/'+id+'.html','https://v.qq.com.evil/x/page/'+id+'.html',doc+'?vid=otherother1',doc+'?vid='+id+'&vid='+id,'https://user@v.qq.com/x/page/'+id+'.html'])assert.equal(T.page(u),null);
});
test('clear MP4 requires matching API identity, exact observed source and main-player owner',()=>{
  const d=T.normalize(raw(),id);assert(d.clear&&d.full);assert.equal(T.binding(player(),[d],[request],doc).id,id);
  assert.equal(T.normalize(raw(),'OTHEROTHER1'),null);
  assert.equal(T.binding({...player(),closest:()=>null},[d],[request],doc),null);
  assert.equal(T.binding(player(),[d],[],doc),null);
  assert.equal(T.binding({...player(),currentSrc:source.replace('opaque.hash','advertisement')},[d],[request],doc),null);
  assert.equal(T.binding({...player(),mediaKeys:{}},[d],[request],doc),null);
});
test('explicit protection, preview and duration/quality changes never become ready',()=>{
  for(const change of [v=>v.enc='1',v=>v.drm=1,v=>delete v.enc,v=>v.isprevid=1,v=>v.td=360,v=>v.vw=1920]) {
    const r=raw();change(r.vl.vi[0]);const d=T.normalize(r,id);assert.equal(T.binding(player(),d?[d]:[],[request],doc),null);
  }
  const r=raw();r.preview=60;assert.equal(T.normalize(r,id).full,false);
});
test('HLS uses exact inline timeline including inserted ads and an observed segment, with its declared base',()=>{
  const r=raw(),v=r.vl.vi[0];r.preview=216;v.fn='content.ts';v.totalduration=246000;
  v.ul={ui:[{url:'https://cdn-one.example/hls/current.m3u8'},{url:'https://cdn-two.example/hls/current.m3u8'}],m3u8:'#EXTM3U\n#EXTINF:30,\nad.ts\n#EXTINF:216,\ncontent.ts\n#EXT-X-ENDLIST\n'};
  const d=T.normalize(r,id),p={...player(),currentSrc:'blob:current',duration:246};
  assert.equal(d.duration,246);assert.equal(T.binding(p,[d],[],doc),null);
  const seg={kind:'segment',url:'https://cdn-two.example/hls/content.ts'};
  const b=T.binding(p,[d],[seg],doc);assert.equal(b.manifest_url,r.vl.vi[0].ul.ui[1].url);assert.equal(b.duration,246);
  assert.equal(T.binding(p,[d],[{...seg,url:'https://unrelated.example/hls/content.ts'}],doc),null);
  assert.equal(T.binding({...p,duration:216},[d],[seg],doc),null);
  for(const key of ['#EXT-X-KEY:METHOD=AES-128,URI="key"','#EXT-X-KEY:METHOD=SAMPLE-AES,URI="key"']) {
    v.ul.m3u8=key+'\n'+v.ul.m3u8;assert.equal(T.normalize(r,id),null);
  }
});
test('same-size prefetch metadata cannot replace the public current identity or an exact file binding',()=>{
  const a=T.normalize(raw(),id),r=raw();r.vl.vi[0].vid='x1111111111';r.vl.vi[0].fn='other.mp4';const b=T.normalize(r);
  assert.equal(T.binding(player(),[a,b],[request],doc).id,id);
  assert.equal(T.binding(player(),[b],[request],doc),null);
  assert.equal(T.binding(player(),[a,{...a,revision:'new'}],[request],doc),null);
});

test('HLS readiness rejects the observed extra-ad timeline difference before native selection',()=>{
  const r=raw(),v=r.vl.vi[0];v.td=1948.31;r.preview=0;
  v.ul={ui:[{url:'https://related-cdn.example/hls/current.m3u8'}],m3u8:'#EXTM3U\n#EXTINF:23.358,\nad.ts\n#EXTINF:1948.31,\ncontent.ts\n#EXT-X-ENDLIST\n'};
  const d=T.normalize(r,id),p={...player(),currentSrc:'blob:current',duration:d.duration};
  const requests=[{kind:'segment',url:'https://related-cdn.example/hls/content.ts'}];
  assert(T.binding(p,[d],requests,doc));
  assert(T.binding({...p,duration:d.duration+.49},[d],requests,doc));
  assert.equal(T.binding({...p,duration:1986.814},[d],requests,doc),null);
  assert.equal(T.binding({...p,duration:d.duration+.51},[d],requests,doc),null);
});

test('startup diagnostics retain only bounded counts and identify metadata preceding native policy',()=>{
  const result=T.diagnostics([
    {name:'https://related-api.example/getvinfo?vid='+id+'&secret=never-report',initiatorType:'script',startTime:10},
    {name:'https://related-api.example/proxyhttp?private=never-report',initiatorType:'fetch',startTime:30},
    {name:source,initiatorType:'video',startTime:5}
  ],20);
  assert.deepEqual(JSON.parse(JSON.stringify(result)),{api_resources:2,api_before_policy:1,api_script:1,api_xhr:0,api_fetch:1});
  assert(!JSON.stringify(result).includes('never-report'));
});

test('proxy wrappers retain legacy protection and identity checks and expose structure without values',()=>{
  const r=raw();assert.equal(T.normalize({ret:0,data:{vinfo:JSON.stringify(r)}},id).id,id);
  assert.equal(T.normalize({ret:0,data:{playInfo:r}},id).id,id);
  assert.equal(T.normalize({ret:0,data:{proxyhttp:{errCode:0,enc:1,vinfo:JSON.stringify(r)},playInfo:{vid:id}}},id).id,id);
  assert.equal(T.normalize({ret:0,data:{proxyhttp:{errCode:1,vinfo:JSON.stringify(r)}}},id).id,id,'The wrapper component status cannot replace the inner video response checks');
  assert.equal(T.normalize({ret:0,data:{proxyhttp:{errCode:0,vinfo:JSON.stringify({...r,code:9})}}},id),null);
  assert.equal(T.normalize({ret:0,data:{proxyhttp:{errCode:0,vinfo:'opaque non-JSON data'}}},id),null);
  assert.equal(T.normalize({ret:1,data:{playInfo:r}},id),null);
  assert.equal(T.normalize({ret:0,data:{playInfo:r}},'x1111111111'),null);
  r.vl.vi[0].drm=1;assert.equal(T.normalize({ret:0,data:{playInfo:r}},id).clear,false);
  const shape=JSON.stringify(T.describe({ret:0,data:{url:'https://private.example/signed?secret=never',uid:123456789,width:1280,vinfo:'never'}}));
  assert(!shape.includes('https:'));assert(!shape.includes('never'));assert(!shape.includes('123456789'));assert(shape.includes('1280'));
});

test('legacy inner JSONP or assignment wrappers parse only a single bounded JSON object without evaluating code',()=>{
  for(const text of [JSON.stringify(raw()),JSON.stringify(raw())+';',' QZOutputJson = '+JSON.stringify(raw())+'; ', '/**/ var QZOutputJson = '+JSON.stringify(raw())+';', 'txv.callback('+JSON.stringify(raw())+');']){
    const outer={ret:0,data:{proxyhttp:{errCode:0,vinfo:text}}};assert.equal(T.normalize(outer,id).id,id);
    assert(T.describe(outer).some(n=>n.path.endsWith('.vinfo.json.vl.vi[].vid')));
  }
  for(const text of ['QZOutputJson='+JSON.stringify(raw())+';execute();','callback(alert(1));','encrypted opaque data','[]']){
    assert.throws(()=>T.json(text));assert.equal(T.normalize({ret:0,data:{proxyhttp:{vinfo:text}}},id),null);
  }
});

test('already processed page state reads primitive data only and must match an observed flow and public video',()=>{
  const flowid='synthetic-flow-00000000001',wire={ret:0,data:{flowid,playInfo:{vid:id},videoInfo:{vid:id,duration:216},proxyhttp:{enc:1,vinfo:'opaque envelope'}}};
  const hint=T.envelope(wire),view={__VINFO_DATA__:{flowid,playInfo:{vid:id},proxyhttp:{vinfo:JSON.stringify(raw())}}};assert(hint);
  const result=T.pageState(view,[hint],doc);assert.equal(result.status,4);assert.equal(result.data.id,id);
  const missing=raw();delete missing.vl.vi[0].vid;
  assert.equal(T.normalize(missing),null);
  assert.equal(T.normalize({ret:0,data:{playInfo:{vid:id},proxyhttp:{vinfo:JSON.stringify(missing)}}}).id,id,'An omitted inner ID can use the explicitly declared API playInfo ID');
  assert.equal(T.normalize({ret:0,data:{playInfo:{vid:'x1111111111'},proxyhttp:{vinfo:JSON.stringify(raw())}}}),null);
  assert.equal(T.pageState(view,[],doc).data,null);
  assert.equal(T.pageState(view,[{...hint,flowid:'synthetic-flow-00000000002'}],doc).data,null);
  assert.equal(T.pageState(view,[{...hint,id:'x1111111111'}],doc).data,null);
  assert.equal(T.envelope({...wire,ret:1}),null);
  assert.equal(T.envelope({...wire,data:{...wire.data,videoInfo:{vid:'x1111111111'}}}),null);
  let invoked=0;const hostile={};Object.defineProperty(hostile,'__VINFO_DATA__',{get(){invoked++;return view.__VINFO_DATA__;}});
  assert.equal(T.pageState(hostile,[hint],doc).data,null);assert.equal(invoked,0);
  const r=raw();r.vl.vi[0].drm=1;view.__VINFO_DATA__.proxyhttp.vinfo=JSON.stringify(r);
  assert.equal(T.pageState(view,[hint],doc).data.clear,false);
  r.vl.vi[0].drm=0;r.vl.vi[0].td=15;r.preview=0;view.__VINFO_DATA__.proxyhttp.vinfo=JSON.stringify(r);
  assert.equal(T.pageState(view,[hint],doc).data.full,false,'The observed full duration cannot be replaced by a shorter page preview');
  view.__VINFO_DATA__.proxyhttp.vinfo='still opaque';assert.equal(T.pageState(view,[hint],doc).data,null);
});
