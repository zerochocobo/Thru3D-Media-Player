#pragma once
#include <algorithm>
#include <cstdint>
#include <string>
#include <utility>
#include <vector>

namespace comic {
inline std::vector<uint32_t> codepoints(const std::string& s){
    std::vector<uint32_t> result;
    for(size_t i=0;i<s.size();){uint32_t c=uint8_t(s[i++]);int n=0;
        if(c>=0xf0){c&=7;n=3;}else if(c>=0xe0){c&=15;n=2;}else if(c>=0xc0){c&=31;n=1;}
        while(n--&&i<s.size())c=(c<<6)|(uint8_t(s[i++])&63);result.push_back(c);}
    return result;
}
inline bool han(uint32_t c){return c>=0x3400&&c<=0x9fff;}
inline bool kana(uint32_t c){return c>=0x3040&&c<=0x30ff;}
inline bool speechMark(uint32_t c){
    switch(c){
        case ' ':case '!':case '?':case '.':case ',':case ':':case ';':case '~':
        case '(':case ')':case '\'':case '"':
        case 0x2014:case 0x2015:case 0x2018:case 0x2019:case 0x201c:case 0x201d:
        case 0x2025:case 0x2026:case 0x3000:case 0x3001:case 0x3002:
        case 0x3008:case 0x3009:case 0x300a:case 0x300b:case 0x300c:case 0x300d:
        case 0x300e:case 0x300f:case 0x3010:case 0x3011:case 0x301c:
        case 0xff01:case 0xff08:case 0xff09:case 0xff0c:case 0xff0e:
        case 0xff1a:case 0xff1b:case 0xff1f:case 0xff5e:return true;
        default:return false;
    }
}
// Preserve the decoder's mean over ALL emitted tokens. A separate CJK speech
// measure prevents a weak punctuation token from hiding certain body text.
// Digits/Latin remain on the existing whole-line verification path.
struct Reading {
    std::string text;
    double confidence=0,body_score=0,body_min=1,punctuation_score=0;
    int count=0,body_count=0,punctuation_count=0;
    bool cjk_only=true;
#ifdef COMIC_CAPTURE_CTC
    std::vector<std::pair<std::string,double>> tokens;
#endif
    void append(const std::string& token,double probability){
        text+=token;confidence+=probability;++count;
        auto cp=codepoints(token);
        bool body=!cp.empty()&&std::all_of(cp.begin(),cp.end(),[](uint32_t c){return han(c)||kana(c)||c==0x3005||c==0x303b;});
        bool mark=!cp.empty()&&std::all_of(cp.begin(),cp.end(),speechMark);
        cjk_only=cjk_only&&(body||mark);
        if(body){body_score+=probability;body_min=std::min(body_min,probability);++body_count;}
        if(mark){punctuation_score+=probability;++punctuation_count;}
#ifdef COMIC_CAPTURE_CTC
        tokens.emplace_back(token,probability);
#endif
    }
    void finish(){
        if(count)confidence/=count;
        if(body_count)body_score/=body_count;
        if(punctuation_count)punctuation_score/=punctuation_count;
    }
};
inline bool strongSpeech(const Reading& r){
    return r.cjk_only&&r.body_count>0&&r.body_min>=.96&&r.body_score>=.96
        &&(!r.punctuation_count||r.punctuation_score>=.5);
}
inline bool compatibleSpeechText(const Reading& anchor,const Reading& candidate){
    if(anchor.text==candidate.text)return true;
    if(!anchor.cjk_only||!anchor.body_count||!anchor.punctuation_count||anchor.punctuation_score>=.5
       ||!strongSpeech(candidate)||!candidate.punctuation_count)return false;
    auto body=[](const std::string& text){auto chars=codepoints(text);
        chars.erase(std::remove_if(chars.begin(),chars.end(),speechMark),chars.end());return chars;};
    // Two later crops must still agree literally. Only an uncertain initial
    // punctuation reading may differ; no lexical character is normalized.
    return body(anchor.text)==body(candidate.text);
}
inline bool speechAgreement(const Reading& a,const Reading& b){
    if(a.text.empty()||a.text!=b.text)return false;
    if(strongSpeech(a)&&strongSpeech(b))return true;
    // Detached ellipses can accompany lexical speech, but unsupported_text
    // still rejects a group made entirely of punctuation.
    return a.cjk_only&&b.cjk_only&&!a.body_count&&!b.body_count
        &&a.punctuation_count>0&&b.punctuation_count>0&&std::min(a.confidence,b.confidence)>=.8;
}
}
