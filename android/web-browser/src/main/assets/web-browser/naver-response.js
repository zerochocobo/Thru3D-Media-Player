/* Capture only JSON the owned NTV document actually received. No API replay. */
const Thru3DNaverResponses=(stateFor,publish)=>{
  'use strict';
  const active=new Map(),filter={urls:['https://*/*'],types:['xmlhttprequest']},TTL=1800000;
  const owner=d=>{
    const s=stateFor(d);return s&&s.naver&&d.frameId===0&&Thru3DNaver.documentPage(s.page)&&
      s.privateContext===d.incognito&&(!s.cookieStore||!d.cookieStoreId||s.cookieStore===d.cookieStoreId)?s:null;
  };
  const note=(s,key)=>{s.naverCapture||={};s.naverCapture[key]=(s.naverCapture[key]||0)+1;};
  const release=e=>{if(e.closed)return;e.closed=true;clearTimeout(e.timer);active.delete(e.id);e.chunks=[];try{e.stream.disconnect();}catch(_){}};
  const cancel=s=>{for(const e of active.values())if(e.state===s)release(e);s.naverData?.clear();s.naverRejected?.clear();s.naverCapture={};};
  browser.webRequest.onHeadersReceived.addListener(d=>{
    const s=owner(d);if(!s||d.method!=='GET'||d.statusCode!==200||active.size>=8)return;
    let u;try{u=new URL(d.url);}catch(_){return;}
    if(!u.pathname.startsWith('/api/')||!u.searchParams.has('seedMediaId')&&!u.searchParams.has('feedBlock')&&!u.searchParams.has('seedType'))return;
    const mime=(d.responseHeaders||[]).find(h=>h.name.toLowerCase()==='content-type')?.value||'';
    if(!/^application\/json(?:;|$)/i.test(mime))return;
    let stream;try{stream=browser.webRequest.filterResponseData(d.requestId);}catch(_){return;}
    const e={id:d.requestId,state:s,stream,chunks:[],size:0,closed:false};active.set(e.id,e);note(s,'responses');
    e.timer=setTimeout(()=>release(e),15000);
    stream.ondata=event=>{
      if(e.closed)return;
      try{stream.write(event.data);}catch(_){release(e);return;}
      if(e.size+event.data.byteLength>256*1024){note(s,'oversize');release(e);publish(s);return;}
      e.size+=event.data.byteLength;e.chunks.push(new Uint8Array(event.data).slice());
    };
    stream.onstop=()=>{
      if(e.closed)return;e.closed=true;clearTimeout(e.timer);active.delete(e.id);try{stream.close();}catch(_){}
      if(owner(d)!==s){e.chunks=[];return;}
      try{
        const bytes=new Uint8Array(e.size);let offset=0;for(const chunk of e.chunks){bytes.set(chunk,offset);offset+=chunk.length;}
        const raw=JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(bytes)),entries=Thru3DNaver.capture(raw),now=Date.now();
        const cards=raw?.body?.card?[raw.body.card]:Array.isArray(raw?.body?.cards)?raw.body.cards.slice(0,16):[];
        s.naverCapture||={};s.naverCapture.last_cards=cards.map(c=>{const id=Thru3DNaver.id(c?.content?.mediaId);return {id,entries:entries.filter(e=>e.id===id).length};});
        const rejected=s.naverRejected||=new Map();
        for(const c of cards){const id=Thru3DNaver.id(c?.content?.mediaId);if(!id)continue;
          if(entries.some(e=>e.id===id)){rejected.delete(id);continue;}
          rejected.delete(id);rejected.set(id,Thru3DNaver.cardDiagnostics(c));
        }
        while(rejected.size>8)rejected.delete(rejected.keys().next().value);
        s.naverCapture.rejected_cards=[...rejected.values()];
        const values=s.naverData||=new Map();for(const [key,value]of values)if(now-value.at>TTL)values.delete(key);
        for(const item of entries){const key=item.id+'\n'+item.source+'\n'+item.width+'x'+item.height+'\n'+(item.timeline?.representation||'');values.delete(key);values.set(key,{...item,at:now});}
        while(values.size>64||JSON.stringify([...values.values()]).length>96*1024)values.delete(values.keys().next().value);
        note(s,entries.length?'normalized':'unsupported');publish(s);
      }catch(_){note(s,'invalid');publish(s);}finally{e.chunks=[];}
    };
    stream.onerror=()=>release(e);
  },filter,['blocking','responseHeaders']);
  browser.webRequest.onBeforeRedirect.addListener(d=>{const e=active.get(d.requestId);if(e)release(e);},filter);
  browser.webRequest.onErrorOccurred.addListener(d=>{const e=active.get(d.requestId);if(e)release(e);},filter);
  return {cancel};
};
