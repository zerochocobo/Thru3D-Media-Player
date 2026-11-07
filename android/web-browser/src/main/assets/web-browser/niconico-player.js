/* The rendered watch player's existing controls. No account/API/signature access.
 * Call only for a previously bound programme and the same DOM/stage owner. */
const Thru3DNiconicoPlayer=(()=>{
  'use strict';
  const own=(o,k)=>o&&(typeof o==='object'||typeof o==='function')?Object.getOwnPropertyDescriptor(o,k)?.value:undefined;
  const method=(o,k)=>{for(let p=o,n=0;p&&n<3;p=Object.getPrototypeOf(p),n++){const v=own(p,k);if(typeof v==='function')return v;}return null;};
  const cache=new WeakMap();
  const ancestors=video=>{
    const values=[];for(let e=video,n=0;e&&n<16;e=e.parentElement,n++)values.push(e.wrappedJSObject||e);return values;
  };
  const identify=(video,data,dom)=>{
    if(!video?.isConnected||video.mediaKeys||!data||dom.location?.href!==data.page||Thru3DNiconico.page(data.page)!==data.id||
      !video.currentSrc.startsWith('blob:https://www.nicovideo.jp/')||!Number.isFinite(video.duration)||Math.abs(video.duration-data.duration)>.5)return null;
    const parents=ancestors(video),prior=cache.get(video),matches=new Set();
    const accept=value=>{
      if(value&&own(value,'isDisposed')!==true&&parents.includes(own(value,'stage'))&&
        ['pause','setCurrentTime','play','getCurrentTime','getVideoDuration'].every(k=>!!method(value,k)))matches.add(value);
    };
    if(prior?.page===data.page&&prior.source===video.currentSrc)accept(prior.control);
    if(!matches.size)for(const el of parents){
      for(const key of Object.getOwnPropertyNames(el).filter(k=>/^__reactFiber\$/.test(k)).slice(0,1)){
        let fiber=own(el,key);
        for(let level=0;fiber&&level<12;fiber=own(fiber,'return'),level++){
          let hook=own(fiber,'memoizedState');const seen=new Set();
          for(let count=0;hook&&count<16&&!seen.has(hook);hook=own(hook,'next'),count++){
            seen.add(hook);const value=own(hook,'memoizedState');accept(value);accept(own(value,'current'));
            if(Array.isArray(value))for(let index=0;index<Math.min(value.length,8);index++){const entry=own(value,String(index));accept(entry);accept(own(entry,'current'));}
          }
        }
      }
    }
    if(matches.size!==1)return null;const control=[...matches][0];
    // These are the site's normal read-only playback APIs, not metadata scraping.
    const duration=Reflect.apply(method(control,'getVideoDuration'),control,[]),position=Reflect.apply(method(control,'getCurrentTime'),control,[]);
    const scale=Number.isFinite(duration)&&duration>0?(Math.abs(duration-video.duration)<=2?1:Math.abs(duration/1000-video.duration)<=2?1000:0):0;
    if(!scale||!Number.isFinite(position)||position<0||Math.abs(position/scale-video.currentTime)>2)return null;
    cache.set(video,{page:data.page,source:video.currentSrc,control});return {control,scale};
  };
  const pause=(video,data,dom)=>{
    try{const current=identify(video,data,dom);if(!current)return false;Reflect.apply(method(current.control,'pause'),current.control,[]);return true;}catch(_){return false;}
  };
  const restore=(video,data,dom,time,play)=>{
    try{
      if(!Number.isFinite(time)||time<0||time>video.duration)return false;
      const current=identify(video,data,dom);if(!current)return false;
      const page=data.page,source=video.currentSrc,valid=()=>video.isConnected&&video.currentSrc===source&&dom.location?.href===page&&
        ancestors(video).includes(own(current.control,'stage'))&&own(current.control,'isDisposed')!==true;
      Reflect.apply(method(current.control,'pause'),current.control,[]);if(!valid())return false;
      // Numeric seek() was a no-op on the rendered facade. Its absolute-time
      // API owns the MSE loader and playback state.
      const result=Reflect.apply(method(current.control,'setCurrentTime'),current.control,[time*current.scale]);if(result===false||result===-1||!valid())return false;
      Reflect.apply(method(current.control,play===true?'play':'pause'),current.control,[]);return true;
    }catch(_){return false;}
  };
  return {pause,restore};
})();
