const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');const vm=require('node:vm');const path=require('node:path');
const context=vm.createContext({URL});
vm.runInContext(fs.readFileSync(path.join(__dirname,'../../main/assets/web-browser/plex.js'),'utf8'),context);
const plex=vm.runInContext('Thru3DPlex',context);
const page='https://server.test/plex/web/index.html#!/server/local/details';
const manifest='https://server.test/plex/video/:/transcode/universal/start.m3u8?path=%2Flibrary%2Fmetadata%2F4&mediaIndex=1&partIndex=0';
test('Plex HLS offset is added only when the server starts a new zero-based timeline',()=>{
  const headers={'X-Plex-Token':'synthetic'};
  assert.equal(plex.source(manifest+'&offset=90&copyts=0',page,headers).offset,90);
  assert.equal(plex.source(manifest+'&offset=90',page,headers).offset,0);
  assert.equal(plex.source(manifest+'&offset=90&copyts=1',page,headers).offset,0);
  assert.equal(plex.source(manifest+'&offset=NaN&copyts=0',page,headers),null);
});
test('Plex library parsing keeps selected versions and rejects unrelated credential scopes',()=>{
  assert.equal(plex.source(manifest,page,{'x-plex-token':'synthetic'}).key,'plex:4:1:0');
  assert.equal(plex.source('https://server.test/plex/library/parts/8/123/file.mkv?X-Plex-Token=synthetic',page).key,'plex-part:8:123');
  for(const value of [manifest,manifest.replace('server.test','foreign.test'),manifest.replace('metadata%2F4','metadata%2F4%2F..'),
    manifest+'&path=%2Flibrary%2Fmetadata%2F5',manifest.replace('mediaIndex=1','mediaIndex=128')])
    assert.equal(plex.source(value,page, value===manifest?{}:{'x-plex-token':'synthetic'}),null);
  assert.equal(plex.source(manifest+'&X-Plex-Token=query',page,{'x-plex-token':'other'}),null);
});
