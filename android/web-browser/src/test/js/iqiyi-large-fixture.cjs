// Public synthetic transport vector. No network, account, or captured URL data.
module.exports=function largeFixture(){
  const url=i=>`https://declared.test/current.ts?start=${i*188}&end=${(i+1)*188}&contentlength=188&sd=${i*1000}&qd_tvid=42&issued=UNIT%2bEXACT%3D&opaque=${'ab'.repeat(256)}`;
  const playlist='#EXTM3U\n#EXT-X-TARGETDURATION:1\n'+Array.from({length:436},(_,i)=>`#EXTINF:1,\n${url(i)}\n`).join('')+'#EXT-X-ENDLIST\n';
  const video={isConnected:true,readyState:4,videoWidth:1440,videoHeight:1080,duration:436,currentSrc:'blob:unit-large',seeking:false};
  const track={vid:'currentstream',bid:500,ff:'ts',scrsz:'1440x1080',duration:436,drmType:1,m3u8:playlist};
  const info={id:'42',vid:'currentstream',_bid:500,type:'Movie',duration:436000};
  const movie={tvid:'42',levelInfoArr:[{vid:'currentstream',bid:500,duration:436000,fragmentList:[{
    sourceID:'current',sPos:0,ePos:436*188,dispatchUrl:'https://sdk.test/current.ts?issued=SDK%2bEXACT%3D&qd_tvid=42'}]}]};
  const view={QiyiPlayerProphetData:{tvId:'42',dashData:{data:{tvid:'42',program:{video:[track]}}}},playback:{_element:video,playingPlayback:{_info:info,_mvInfo:movie}}};
  return {video,track,view,playlist,url,dom:{querySelectorAll:()=>[video]}};
};
