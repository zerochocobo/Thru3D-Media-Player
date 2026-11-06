const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const context = vm.createContext({URL});
vm.runInContext(fs.readFileSync(path.join(__dirname,'../../main/assets/web-browser/weibo.js'),'utf8'),context);
const api = vm.runInContext('Thru3DWeibo',context);
const post = 'https://weibo.com/7827771738/N4xlMvjhI';
const url = 'https://arbitrary-cdn.test/current.mp4?sig=synthetic';
function fixture() {
  const card = {links:[{href:post+'?tracking=removed'}],count:1,querySelectorAll(s){return s==='video'?Array(this.count):this.links;}};
  const box = {links:[],closest(){return card;},querySelectorAll(){return this.links;}};
  const video = {currentSrc:url,readyState:2,videoWidth:1280,videoHeight:720,duration:120,closest(s){return s==='[page-info]'?box:null;}};
  const requests = [{kind:'file',url,original_url:url,at:Date.now()}];
  return {card,box,video,requests};
}
test('official pages canonicalize public identities without retaining tracking or credentials',()=>{
  assert.equal(api.page(post+'?token=private#fragment').page,post);
  for(const value of ['https://weibo.com/','https://weibo.com/u/12345','https://weibo.com.evil/1/ABCDE','https://user@weibo.com/1/ABCDE','http://weibo.com/1/ABCDE']) assert.equal(api.page(value),null);
  assert.equal(api.page('https://weibo.com/tv/show/1034:4967272104787984').id,'1034:4967272104787984');
});
test('one card binds only its exact current file and follows the verified page to any CDN',()=>{
  const f=fixture();
  assert.equal(api.binding(f.video,f.requests).page,post);
  assert.equal(api.binding(f.video,[{...f.requests[0],url:url+'other',original_url:url+'other'}]),null);
  assert.equal(api.binding(f.video,[{...f.requests[0],url:'https://other-cdn.test/redirect.mp4'}]).source,url);
  assert.equal(api.binding(f.video,[...f.requests,{...f.requests[0],url:'https://other-cdn.test/ambiguous.mp4'}]),null);
});
test('backgrounds, repost ambiguity and multiple players cannot borrow another card identity',()=>{
  const f=fixture();
  f.card.links.push({href:'https://weibo.com/1234567890/ABCDE'});
  assert.equal(api.binding(f.video,f.requests),null);
  f.box.links=[{href:'https://weibo.com/tv/show/1034:4967272104787984'}];
  assert.equal(api.binding(f.video,f.requests).id,'1034:4967272104787984');
  f.box.closest=()=>null;
  assert.equal(api.binding(f.video,f.requests),null);
});
test('lazy, Blob and zero-duration players never become ready from nearby network files',()=>{
  for(const mutation of [v=>v.readyState=0,v=>v.videoWidth=0,v=>v.duration=NaN,v=>v.duration=0,v=>v.currentSrc='blob:page',v=>v.currentSrc='https://user:secret@cdn.test/file']){
    const f=fixture();mutation(f.video);assert.equal(api.binding(f.video,f.requests),null);
  }
});
