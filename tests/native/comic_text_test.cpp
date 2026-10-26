#include "comic_text.h"
#include <iostream>
#define CHECK(condition) do { if(!(condition)){std::cerr<<"FAIL line "<<__LINE__<<"\n";return 1;} } while(false)
using namespace comic;
static Reading read(std::initializer_list<std::pair<std::string,double>> tokens){
    Reading r;for(const auto& token:tokens)r.append(token.first,token.second);r.finish();return r;
}
int main(){
    auto a=read({{u8"好",.999},{u8"痛",.999},{u8"～",.6}}),b=read({{u8"好",.998},{u8"痛",.999},{u8"～",.7}});
    CHECK(a.confidence<.9&&speechAgreement(a,b));
    auto question=read({{u8"好",.999},{u8"痛",.999},{u8"？",.7}});
    CHECK(!speechAgreement(a,question));
    auto weak_letter=read({{u8"唔",.93},{u8"～",.999}});
    CHECK(!speechAgreement(weak_letter,weak_letter));
    auto wrong_glyph=read({{u8"甚",.999},{u8"麽",.65},{u8"？",.999}});
    CHECK(!speechAgreement(wrong_glyph,wrong_glyph));
    auto digits=read({{u8"第",.999},{"5",.999},{"1",.999},{u8"！",.6}}),latin=read({{"A",.999},{"!",.7}});
    CHECK(!speechAgreement(digits,digits)&&!speechAgreement(latin,latin));
    auto prolonged=read({{u8"コ",.999},{u8"ー",.7},{u8"！",.999}});
    CHECK(!speechAgreement(prolonged,prolonged));
    auto ellipsis=read({{u8"…",.9},{u8"…",.9}}),empty=read({});
    CHECK(speechAgreement(ellipsis,ellipsis)&&ellipsis.body_count==0&&!strongSpeech(ellipsis));
    CHECK(!speechAgreement(empty,empty));
    CHECK(!speechAgreement(read({{u8"好",.999},{u8"！",.3}}),read({{u8"好",.999},{u8"！",.3}})));
    auto uncertain=read({{u8"一",.999},{u8"樣",.94},{u8"：",.36}}),rechecked=read({{u8"一",.999},{u8"樣",.99},{u8"…",.8}});
    CHECK(compatibleSpeechText(uncertain,rechecked)&&!speechAgreement(uncertain,rechecked));
    CHECK(!compatibleSpeechText(uncertain,read({{u8"一",.999},{u8"樓",.999},{u8"…",.8}})));
    CHECK(!compatibleSpeechText(question,a));
    CHECK(!compatibleSpeechText(uncertain,read({{u8"一",.999},{u8"樣",.999}})));
    std::cout<<"comic_text: 10 character-confidence/punctuation cases passed\n";
}
