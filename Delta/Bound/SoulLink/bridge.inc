// Included by BoundVBABattleBridge.mm. All calls require the frame owner or pause.
#include "BoundSoulCode.h"
namespace {
constexpr size_t SoulStart=0x1FF8000,SoulEnd=0x1FFF800,SoulPolicy=0x1FFA000;
uint8_t *soulROM=nullptr;
uint8_t soulOriginalGet[8],soulOriginalSet[8],soulGetThunk[8],soulSetThunk[8];
bool soulHooked() {
    return soulROM==rom && rom && memcmp(rom+0x3FBE8,soulGetThunk,8)==0 && memcmp(rom+0x4037C,soulSetThunk,8)==0;
}
bool soulResident() {
    return soulROM==rom && rom && memcmp(rom+SoulStart,BoundSoulCode,sizeof(BoundSoulCode))==0
        && memcmp(rom+0x3FBE8,soulOriginalGet,8)==0 && memcmp(rom+0x4037C,soulOriginalSet,8)==0;
}
bool soulOriginalHash(uint8_t digest[32]) {
    if(!rom) return false;
    if(!soulHooked()&&!soulResident()) { CC_SHA256(rom,0x2000000,digest); return true; }
    // The base ROM is verified again for native link admission without removing
    // eligibility hooks, even while the core is paused between session owners.
    NSMutableData *base=[NSMutableData dataWithBytes:rom length:0x2000000];
    auto *p=(uint8_t *)base.mutableBytes;
    memcpy(p+0x3FBE8,soulOriginalGet,8); memcpy(p+0x4037C,soulOriginalSet,8);
    memset(p+SoulStart,0xFF,SoulEnd-SoulStart);
    CC_SHA256(p,0x2000000,digest); return true;
}
}
