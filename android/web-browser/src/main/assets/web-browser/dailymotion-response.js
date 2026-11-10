/* Preserve only successful HLS responses in the owned official player frame.
 * Bytes are forwarded immediately and unchanged; keys and media are not read. */
const Thru3DDailymotionResponses=(stateFor,publish)=>{
  'use strict';
  const active=new Map(),filter={urls:['https://*/*'],types:['xmlhttprequest','media','other']},TTL=1800000;
  const resource=(s,url)=>[...(s.dailymotionBodies?.values()||[])].some(entry=>{
    const age=Date.now()-entry.at;
    if(entry.format!=='hls'||!Number.isFinite(age)||age<0||age>TTL||!entry.body.includes('#EXT-X-STREAM-INF:'))return false;
    const lines=entry.body.split(/\r?\n/).map(v=>v.trim());
    return lines.some((line,i)=>{
      const ref=line.startsWith('#EXT-X-STREAM-INF:')?lines[i+1]:line.startsWith('#EXT-X-MEDIA:')?/URI="([^"]+)"/.exec(line)?.[1]:null;
      try{return !!ref&&!ref.startsWith('#')&&Thru3DDailymotion.transport(new URL(ref,entry.url).href)===Thru3DDailymotion.transport(url);}catch(_){return false;}
    });
  });
  const note=(s,status)=>{const data=s.dailymotionCapture||={};data[status]=(data[status]||0)+1;};
  const owner=d=>{
    const s=stateFor(d);
    return s&&(s.enabled||s.dailymotion)&&Thru3DDailymotion.frame(s.page)&&Thru3DDailymotion.documentPage(s.parentPage)&&
      s.privateContext===d.incognito&&(!s.cookieStore||!d.cookieStoreId||s.cookieStore===d.cookieStoreId)?s:null;
  };
  const release=e=>{
    if(e.closed)return;e.closed=true;clearTimeout(e.timer);active.delete(e.id);e.chunks=[];
    try{e.stream.disconnect();}catch(_){}
  };
  const cancel=s=>{for(const e of active.values())if(e.state===s)release(e);s.dailymotionBodies?.clear();};
  browser.webRequest.onHeadersReceived.addListener(d=>{
    const mime=(d.responseHeaders||[]).find(h=>h.name.toLowerCase()==='content-type')?.value||'';
    const s=owner(d);
    if(!s)return;
    const target=Thru3DDailymotion.transport(d.url);if(!target)return;
    const related=resource(s,d.url);
    if(d.method!=='GET'||d.statusCode!==200||active.size>=8||
      !/^(?:application|audio)\/(?:x-mpegurl|vnd\.apple\.mpegurl)(?:;|$)/i.test(mime)&&!related)return;
    note(s,related?'related_headers':'manifest_headers');
    let stream;try{stream=browser.webRequest.filterResponseData(d.requestId);}catch(_){return;}
    const e={id:d.requestId,state:s,stream,chunks:[],size:0,limit:48*1024,closed:false};active.set(e.id,e);
    e.timer=setTimeout(()=>release(e),15000);
    stream.ondata=event=>{
      if(e.closed)return;
      try{stream.write(event.data);}catch(_){release(e);return;}
      if(e.size+event.data.byteLength>e.limit){note(s,'oversize');release(e);publish(s);return;}
      e.size+=event.data.byteLength;e.chunks.push(new Uint8Array(event.data).slice());
    };
    stream.onstop=()=>{
      if(e.closed)return;e.closed=true;clearTimeout(e.timer);active.delete(e.id);
      try{stream.close();}catch(_){}
      if(owner(d)!==e.state){e.chunks=[];return;}
      try{
        const bytes=new Uint8Array(e.size);let at=0;for(const c of e.chunks){bytes.set(c,at);at+=c.length;}
        const body=new TextDecoder('utf-8',{fatal:true}).decode(bytes),format='hls';
        if(!body.startsWith('#EXTM3U'))return;
        const values=s.dailymotionBodies||=new Map(),now=Date.now();
        for(const [key,v]of values)if(now-v.at>TTL)values.delete(key);
        values.delete(target);values.set(target,{url:target,request_url:d.url,body,format,request_id:d.requestId,at:now,size:bytes.length});
        const observed=s.items?.get(target);if(observed?.request_id===d.requestId)observed.kind=format;
        note(s,format);
        while(values.size>6||[...values.values()].reduce((sum,v)=>sum+v.size,0)>64*1024)values.delete(values.keys().next().value);
        publish(s);
      }catch(_){}finally{e.chunks=[];}
    };
    stream.onerror=()=>release(e);
  },filter,['blocking','responseHeaders']);
  browser.webRequest.onBeforeRedirect.addListener(d=>{const e=active.get(d.requestId);if(e)release(e);},filter);
  browser.webRequest.onErrorOccurred.addListener(d=>{const e=active.get(d.requestId);if(e)release(e);},filter);
  return {cancel,resource};
};
