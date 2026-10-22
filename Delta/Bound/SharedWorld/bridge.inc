// Game-owned rules are compiled into the cartridge. This adapter accesses
// only the generated, versioned data interface on the completed-frame owner.
#include "BoundGameABI.h"
namespace {
uint8_t *worldROM=nullptr;
uint32_t worldSequence=0;
uint8_t worldSession[16]={};
bool gameDescriptorPresent(const uint8_t *p) {
    return p && memcmp(p+GameDescriptorOffset,GameDescriptor,sizeof(GameDescriptor))==0;
}
bool worldOwnsROM() { return worldROM==rom && gameDescriptorPresent(rom); }
void worldRestoreBase(uint8_t *p) {
    if(!gameDescriptorPresent(p)) return;
    // Hash admission strips dynamic data, then verifies the complete integrated
    // release before reconstructing the base view for the other native bridges.
    memset(p+GameHostOffset,0,GameHostSize);
    memset(p+GameUIHostOffset,0,GameUIHostSize);
    uint8_t digest[32]; CC_SHA256(p,0x2000000,digest);
    if(memcmp(digest,GameCanonicalSHA256,32)) return;
    for(const auto &entry:GameBaseDefinitions) memcpy(p+entry.offset,entry.bytes,entry.size);
    memset(p+GameCodeStart,0xFF,GameCodeEnd-GameCodeStart);
    memset(p+GameHostOffset,0xFF,GameHostSize);
    memset(p+GameUIHostOffset,0xFF,GameUIHostSize);
    memset(p+GameDescriptorOffset,0xFF,sizeof(GameDescriptor));
}
void worldWritePolicy(bool enabled,NSData *checkpoints,unsigned group,unsigned number,NSData *boulders,bool fresh) {
    if(!worldOwnsROM()) return;
    uint8_t *p=rom+GameHostOffset;
    uint32_t sequence=worldSequence+2; if(!sequence) sequence=2;
    put32(p+8,sequence-1); // An incomplete transaction always fails closed.
    memset(p,0,8); memset(p+12,0,GameHostSize-12);
    put32(p,0x31484D52); put16(p+4,GameABIMajor); put16(p+6,GameABIMinor);
    memcpy(p+16,worldSession,16); memcpy(p+32,GameRulesetID,16);
    auto *policy=p+64;
    const bool ready=enabled&&fresh&&checkpoints.length==800&&boulders.length<=96&&boulders.length%6==0;
    put32(policy,0x31575042); put32(policy+4,enabled?1:0);put32(policy+8,ready?180:0);put32(policy+12,ready?1:0);
    if(ready) {
        policy[16]=uint8_t(group);policy[17]=uint8_t(number);
        memcpy(policy+18,checkpoints.bytes,800);policy[818]=uint8_t(boulders.length/6);
        memcpy(policy+820,boulders.bytes,boulders.length);
    }
    put32(p+8,sequence);worldSequence=sequence;
}
}
