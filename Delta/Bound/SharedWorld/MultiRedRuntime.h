#pragma once
#include <CommonCrypto/CommonDigest.h>
#include <array>
#include <map>
#include <memory>
#include <mutex>
#include <vector>
// The host's native link/player/save hooks operate only on this exact underlying
// native engine. Versioned restoration records permit new cartridge-owned code
// and hook targets, never an unchecked engine/address-layout substitution.
constexpr unsigned BoundRuntimeOffset=0x1FE4000,BoundRuntimeSize=0x4000;
static unsigned runtimeWord(const uint8_t *p){return p[0]|unsigned(p[1])<<8|unsigned(p[2])<<16|unsigned(p[3])<<24;}
static void runtimeRestore(uint8_t *p) {
    const auto *table=p+BoundRuntimeOffset;
    for(unsigned i=0;i<runtimeWord(table+20);i++) {
        const auto *row=table+64+i*24;
        memcpy(p+runtimeWord(row),row+8,runtimeWord(row+4));
    }
    memset(p+BoundRuntimeOffset,0xFF,BoundRuntimeSize);
}
struct BoundRuntimeStorage {
    MultiRedNativeProfile profile=MultiRedCurrentProfile;
    std::array<uint8_t,128> descriptor;
    std::array<uint8_t,32> canonical;
    std::array<uint8_t,32> tableHash;
};
static std::mutex runtimeProfilesLock;
static std::map<const uint8_t *,std::unique_ptr<BoundRuntimeStorage>> runtimeProfiles;
static const MultiRedNativeProfile *runtimeProfile(const uint8_t *p,bool revalidate=false) {
    if(!p||memcmp(p+BoundRuntimeOffset,"BRUNTIME",8))return nullptr;
    const auto *table=p+BoundRuntimeOffset;
    if(runtimeWord(table+8)!=1||runtimeWord(table+12)!=31||runtimeWord(table+16)!=GameSaveStateLayout)return nullptr;
    unsigned count=runtimeWord(table+20);
    if(count!=sizeof(GameBaseDefinitions)/sizeof(*GameBaseDefinitions)||64+24*count>BoundRuntimeSize)return nullptr;
    // Pin every host-displaced native binding, not a complete release image.
    for(unsigned i=0;i<count;i++) {
        const auto *row=table+64+i*24;const auto &known=GameBaseDefinitions[i];
        if(runtimeWord(row)!=known.offset||runtimeWord(row+4)!=known.size||known.size>16
           ||memcmp(row+8,known.bytes,known.size))return nullptr;
    }
    for(unsigned i=0;i<128;i++) {
        if(i>=20&&i<36)continue; // A new ruleset still needs identical host functions/layout.
        if(p[GameDescriptorOffset+i]!=GameDescriptor[i])return nullptr;
    }
    std::array<uint8_t,32> tableHash;CC_SHA256(table,BoundRuntimeSize,tableHash.data());
    std::lock_guard<std::mutex> lock(runtimeProfilesLock);
    auto found=runtimeProfiles.find(p);
    if(!revalidate&&found!=runtimeProfiles.end()&&found->second->tableHash==tableHash)return &found->second->profile;
    std::unique_ptr<BoundRuntimeStorage> value(new BoundRuntimeStorage());
    auto &profile=value->profile;
    memcpy(value->descriptor.data(),p+GameDescriptorOffset,128);
    profile.descriptor=value->descriptor.data();profile.ruleset=profile.descriptor+20;
    profile.restoreHooks=runtimeRestore;
    // Full reserved allocations remain stable, even as code grows within them.
    profile.linksCodeEnd=0x1FC9000;profile.eliminationCodeEnd=0x1FD0000;
    profile.cooperativeCodeEnd=0x1FD8000;profile.presenceCodeEnd=0x1FE0000;
    std::vector<uint8_t> normalized(p,p+0x2000000);profile.normalize(normalized.data());
    CC_SHA256(normalized.data(),unsigned(normalized.size()),value->canonical.data());
    profile.canonicalHash=value->canonical.data();
    memset(normalized.data()+BoundRuntimeOffset,0xFF,BoundRuntimeSize);
    uint8_t digest[32];CC_SHA256(normalized.data(),unsigned(normalized.size()),digest);
    if(memcmp(digest,table+24,32))return nullptr;
    memcpy(normalized.data()+BoundRuntimeOffset,table,BoundRuntimeSize);
    profile.restore(normalized.data());
    CC_SHA256(normalized.data(),unsigned(normalized.size()),digest);
    if(memcmp(digest,GameDescriptor+84,32))return nullptr;
    value->tableHash=tableHash;
    if(found!=runtimeProfiles.end() && found->second->tableHash==tableHash && found->second->canonical==value->canonical)return &found->second->profile;
    // Keep prior admitted profiles alive through a paused core/async callback.
    static std::vector<std::unique_ptr<BoundRuntimeStorage>> retired;
    if(found!=runtimeProfiles.end())retired.push_back(std::move(found->second));
    auto *result=&profile;runtimeProfiles[p]=std::move(value);return result;
}
