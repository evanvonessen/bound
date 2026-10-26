// Game-owned rules are compiled into the cartridge. This adapter accesses
// only the generated, versioned data interface on the completed-frame owner.
#include "MultiRedProfiles.h"
namespace {
uint8_t *worldROM=nullptr;
const MultiRedNativeProfile *worldProfile=nullptr;
uint32_t worldSequence=0;
uint8_t worldSession[16]={};
bool gameDescriptorPresent(const uint8_t *p) { return multiRedProfile(p)!=nullptr; }
bool worldOwnsROM() { return worldROM==rom && worldProfile && worldProfile==multiRedProfile(rom); }
void worldRestoreBase(uint8_t *p) {
    const auto *profile=multiRedProfile(p); if(!profile) return;
    // Strip only this profile's dynamic ranges before exact full-ROM admission.
    profile->restoreCanonical(p,[](const uint8_t *bytes,unsigned size,uint8_t *digest) { CC_SHA256(bytes,size,digest); });
}
void worldWritePolicy(bool enabled,NSData *checkpoints,unsigned group,unsigned number,NSData *boulders,bool fresh) {
    if(!worldOwnsROM()) return;
    uint8_t *p=rom+worldProfile->hostOffset;
    uint32_t sequence=worldSequence+2; if(!sequence) sequence=2;
    put32(p+8,sequence-1); // An incomplete transaction always fails closed.
    memset(p,0,8); memset(p+12,0,worldProfile->hostSize-12);
    put32(p,0x31484D52); put16(p+4,worldProfile->major); put16(p+6,worldProfile->minor);
    memcpy(p+16,worldSession,16); memcpy(p+32,worldProfile->ruleset,16);
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
