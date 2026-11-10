const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm'),path=require('node:path');
const event=()=>{const listeners=[];return {addListener:f=>listeners.push(f),fire:d=>listeners.forEach(f=>f(d))};};
test('owned Naver declarations and request scopes survive an unsupported same-document service but retire on navigation',async()=>{
 const callbacks=new Map(),streams=[],messages=[];let timer=0;
 const webRequest=Object.fromEntries(['onBeforeRequest','onSendHeaders','onHeadersReceived','onCompleted','onErrorOccurred','onBeforeRedirect'].map(k=>[k,event()]));
 webRequest.filterResponseData=()=>{const stream={write(){},close(){},disconnect(){}};streams.push(stream);return stream;};
 const browser={runtime:{id:'fixture',onConnect:event()},webRequest,cookies:{getAll:async()=>[]}};
 const context=vm.createContext({browser,URL,Uint8Array,TextDecoder,Date:{now:()=>100000},setTimeout:f=>{callbacks.set(++timer,f);return timer;},clearTimeout:id=>callbacks.delete(id)});
 const root=path.join(__dirname,'../../main/assets/web-browser/');
 for(const name of ['bilibili','douyin','plex','weibo','twitch','tiktok','archive','dailymotion','ted','naver','naver-response','network'])vm.runInContext(fs.readFileSync(root+name+'.js','utf8'),context);
 const id='A'.repeat(36),page='https://m.naver.com/shorts/?serviceType=NTV&seedMediaId='+id,file='https://related.example/current.mp4?signature=EXACT';
 const port={name:'thru3d_network',sender:{id:'fixture',tab:{id:1,url:page},frameId:0,url:page,documentId:'owned'},onMessage:event(),onDisconnect:event(),postMessage:m=>messages.push(JSON.parse(JSON.stringify(m))),disconnect(){this.disconnected=true;this.onDisconnect.fire();}};
 browser.runtime.onConnect.fire(port);port.onMessage.fire({type:'context',page,enabled:false,naver:true});
 const request=(url,mime,requestId,authorization)=>{
  const d={tabId:1,frameId:0,documentId:'owned',documentUrl:page,incognito:false,method:'GET',type:'xmlhttprequest',requestId,url,statusCode:200,
   requestHeaders:[{name:'Authorization',value:authorization}],responseHeaders:[{name:'Content-Type',value:mime}]};
  webRequest.onSendHeaders.fire(d);webRequest.onHeadersReceived.fire(d);webRequest.onCompleted.fire(d);
 };
 request('https://associated.example/api/cards?seedMediaId='+id,'application/json','card','API_ONLY');
 const card={body:{card:{cardType:'CONTENT',content:{mediaId:id,serviceType:'NTV',videoQuality:{duration:20},vod:{playable:true,playback:{MPD:[{
  '@nvod:videoId':id,'@type':'static','@mediaPresentationDuration':'PT20S',Period:[{'@id':id,'@duration':'PT20S',AdaptationSet:[{Representation:[{
   '@width':'1280','@height':'720','@mimeType':'video/mp4',BaseURL:[file]}]}]}]}]}}}}}};
 assert.equal(streams.length,1);streams[0].ondata({data:new TextEncoder().encode(JSON.stringify(card)).buffer});streams[0].onstop();
 request(file,'video/mp4','file','FILE_ONLY');
 const drain=async()=>{await new Promise(resolve=>setImmediate(resolve));const batch=[...callbacks.values()];callbacks.clear();batch.forEach(f=>f());};
 await drain();assert.equal(messages.at(-1).naver.length,1);
 for(const service of ['MOMENT','CLIP']){
  const next=page.replace('NTV',service);
  port.onMessage.fire({type:'context',page:next,enabled:false,naver:true,reset:true});await drain();
  const latest=messages.at(-1);assert.equal(latest.naver.length,1);assert.equal(latest.naver[0].id,id);
  assert.equal(latest.candidates[0].headers.authorization,'FILE_ONLY');assert.equal(JSON.stringify(latest.naver).includes('API_ONLY'),false);
 }
 webRequest.onBeforeRequest.fire({tabId:1,frameId:0,type:'main_frame',url:'https://m.naver.com/shorts/',documentId:'new-document'});
 assert.equal(port.disconnected,true);
 const replacement={...port,sender:{...port.sender,documentId:'replacement'},onMessage:event(),onDisconnect:event()};
 browser.runtime.onConnect.fire(replacement);replacement.onMessage.fire({type:'context',page,enabled:false,naver:true,reset:true});
 await drain();assert.equal(messages.at(-1).naver.length,0);
});
