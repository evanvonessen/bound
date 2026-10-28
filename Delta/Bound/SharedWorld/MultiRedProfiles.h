#pragma once
#include <cstdint>
#include <cstring>
#include "BoundGameABI.h"
namespace BoundOriginalGame {
#include "BoundOriginalGameABI.h"
}
namespace BoundLinksMenuGame {
#include "BoundLinksMenuGameABI.h"
}
namespace BoundPreLinksMenuGame {
#include "BoundPreLinksMenuGameABI.h"
}
namespace BoundPreShinyMagikarpGame {
#include "BoundPreShinyMagikarpGameABI.h"
}
namespace BoundFriendsMultiviewGame {
#include "BoundFriendsMultiviewGameABI.h"
}
namespace BoundDebugDefaultsGame {
#include "BoundDebugDefaultsGameABI.h"
}
namespace BoundStackSafeGame {
#include "BoundStackSafeGameABI.h"
}

// Each admitted cartridge keeps its complete descriptor, dynamic ranges, and
// base hook restoration table. No profile is inferred from ABI versions alone.
struct MultiRedNativeProfile {
    const uint8_t *descriptor, *canonicalHash, *ruleset;
    unsigned descriptorOffset, descriptorSize, hostOffset, hostSize;
    unsigned snapshotAddress, snapshotSize, snapshotRegionSize;
    unsigned major, minor, layout, uiHostOffset, uiHostSize, uiRequestAddress, uiRequestSize;
    unsigned codeStart, codeEnd, cooperativeHostOffset, cooperativeHostSize, cooperativeCodeStart, cooperativeCodeEnd;
    void (*restoreHooks)(uint8_t *);
    unsigned linksHostOffset, linksHostSize, linksCodeStart, linksCodeEnd;
    unsigned eliminationHostOffset, eliminationHostSize, eliminationCodeStart, eliminationCodeEnd;
    bool cooperative() const { return cooperativeHostSize != 0; }
    bool matches(const uint8_t *p) const { return p && !memcmp(p+descriptorOffset,descriptor,descriptorSize); }
    bool admitsStateRAM(const uint8_t *ram, size_t count, bool exactCaptureIdentity=false) const {
        auto word=[](const uint8_t *p) { return uint32_t(p[0])|(uint32_t(p[1])<<8)|(uint32_t(p[2])<<16)|(uint32_t(p[3])<<24); };
        auto half=[](const uint8_t *p) { return unsigned(p[0])|(unsigned(p[1])<<8); };
        const size_t offset=snapshotAddress-0x02000000;
        if(offset>count||snapshotRegionSize>count-offset) return false;
        const auto *control=ram+offset;
        if(word(control)!=0x31434D52||half(control+4)!=major||half(control+6)>minor
           ||word(control+8)!=snapshotRegionSize||word(control+12)>1||word(control+16)!=snapshotSize) return false;
        // Native battle/trade heap reset clears both published field pages.
        // Only a capture carrying this exact profile and compressed-state hash
        // may resume that boundary. Untagged historical states still need the
        // original complete ruleset/layout page below.
        if(exactCaptureIdentity && word(control+12)==0) {
            bool empty=true;
            for(size_t i=64;i<64+2*snapshotSize;i++) if(control[i]) { empty=false;break; }
            if(empty) return true;
        }
        const auto *p=control+64+word(control+12)*snapshotSize;
        return word(p)==0x31534D52&&half(p+4)==major&&half(p+6)<=minor&&word(p+8)==snapshotSize
            &&word(p+12)&&!(word(p+12)&1)&&!memcmp(p+32,ruleset,16)
            &&word(p+48)==1&&word(p+52)==1&&word(p+56)==layout;
    }
    void normalize(uint8_t *p) const {
        memset(p+hostOffset,0,hostSize); memset(p+uiHostOffset,0,uiHostSize);
        if(cooperative()) memset(p+cooperativeHostOffset,0,cooperativeHostSize);
        if(linksHostSize) memset(p+linksHostOffset,0,linksHostSize);
        if(eliminationHostSize) memset(p+eliminationHostOffset,0,eliminationHostSize);
    }
    void restore(uint8_t *p) const {
        restoreHooks(p);
        if(linksHostSize) memset(p+linksHostOffset,0xFF,linksHostSize);
        if(linksCodeEnd>linksCodeStart) memset(p+linksCodeStart,0xFF,linksCodeEnd-linksCodeStart);
        if(eliminationHostSize) memset(p+eliminationHostOffset,0xFF,eliminationHostSize);
        if(eliminationCodeEnd>eliminationCodeStart) memset(p+eliminationCodeStart,0xFF,eliminationCodeEnd-eliminationCodeStart);
        memset(p+codeStart,0xFF,codeEnd-codeStart);
        memset(p+hostOffset,0xFF,hostSize); memset(p+uiHostOffset,0xFF,uiHostSize);
        memset(p+descriptorOffset,0xFF,descriptorSize);
        if(cooperative()) {
            memset(p+cooperativeCodeStart,0xFF,cooperativeCodeEnd-cooperativeCodeStart);
            memset(p+cooperativeHostOffset,0xFF,cooperativeHostSize);
        }
    }
    template<typename Hash> bool restoreCanonical(uint8_t *p, Hash hash) const {
        if(!matches(p)) return false;
        normalize(p);
        uint8_t digest[32]; hash(p,0x2000000,digest);
        if(memcmp(digest,canonicalHash,32)) return false;
        restore(p); return true;
    }
};
static_assert(GameLinksHostOffset+GameLinksHostSize<=GameLinksCodeStart
              && GameLinksCodeStart<GameLinksCodeEnd && GameLinksCodeEnd<=GameCooperativeCodeStart,
              "Links memory must stay inside its audited region");
static const MultiRedNativeProfile MultiRedCurrentProfile={
    GameDescriptor,GameCanonicalSHA256,GameRulesetID,GameDescriptorOffset,sizeof(GameDescriptor),GameHostOffset,GameHostSize,
    GameSnapshotAddress,GameSnapshotSize,GameSnapshotRegionSize,GameABIMajor,GameABIMinor,GameSaveStateLayout,
    GameUIHostOffset,GameUIHostSize,GameUIRequestAddress,GameUIRequestSize,GameCodeStart,GameCodeEnd,
    GameCooperativeHostOffset,GameCooperativeHostSize,GameCooperativeCodeStart,GameCooperativeCodeEnd,
    [](uint8_t *p) { for(const auto &entry:GameBaseDefinitions) memcpy(p+entry.offset,entry.bytes,entry.size); },
    GameLinksHostOffset,GameLinksHostSize,GameLinksCodeStart,GameLinksCodeEnd,GameEliminationHostOffset,GameEliminationHostSize,GameEliminationCodeStart,GameEliminationCodeEnd
};
static const MultiRedNativeProfile MultiRedLinksMenuProfile={
    BoundLinksMenuGame::GameDescriptor,BoundLinksMenuGame::GameCanonicalSHA256,BoundLinksMenuGame::GameRulesetID,BoundLinksMenuGame::GameDescriptorOffset,sizeof(BoundLinksMenuGame::GameDescriptor),BoundLinksMenuGame::GameHostOffset,BoundLinksMenuGame::GameHostSize,
    BoundLinksMenuGame::GameSnapshotAddress,BoundLinksMenuGame::GameSnapshotSize,BoundLinksMenuGame::GameSnapshotRegionSize,BoundLinksMenuGame::GameABIMajor,BoundLinksMenuGame::GameABIMinor,BoundLinksMenuGame::GameSaveStateLayout,
    BoundLinksMenuGame::GameUIHostOffset,BoundLinksMenuGame::GameUIHostSize,BoundLinksMenuGame::GameUIRequestAddress,BoundLinksMenuGame::GameUIRequestSize,BoundLinksMenuGame::GameCodeStart,BoundLinksMenuGame::GameCodeEnd,
    BoundLinksMenuGame::GameCooperativeHostOffset,BoundLinksMenuGame::GameCooperativeHostSize,BoundLinksMenuGame::GameCooperativeCodeStart,BoundLinksMenuGame::GameCooperativeCodeEnd,
    [](uint8_t *p) { for(const auto &entry:BoundLinksMenuGame::GameBaseDefinitions) memcpy(p+entry.offset,entry.bytes,entry.size); },
    BoundLinksMenuGame::GameLinksHostOffset,BoundLinksMenuGame::GameLinksHostSize,BoundLinksMenuGame::GameLinksCodeStart,BoundLinksMenuGame::GameLinksCodeEnd,0,0,0,0
};
static const MultiRedNativeProfile MultiRedOriginalProfile=[] {
    return MultiRedNativeProfile{
        BoundOriginalGame::GameDescriptor,BoundOriginalGame::GameCanonicalSHA256,BoundOriginalGame::GameRulesetID,
        BoundOriginalGame::GameDescriptorOffset,sizeof(BoundOriginalGame::GameDescriptor),BoundOriginalGame::GameHostOffset,BoundOriginalGame::GameHostSize,
        BoundOriginalGame::GameSnapshotAddress,BoundOriginalGame::GameSnapshotSize,BoundOriginalGame::GameSnapshotRegionSize,
        BoundOriginalGame::GameABIMajor,BoundOriginalGame::GameABIMinor,BoundOriginalGame::GameSaveStateLayout,
        BoundOriginalGame::GameUIHostOffset,BoundOriginalGame::GameUIHostSize,BoundOriginalGame::GameUIRequestAddress,BoundOriginalGame::GameUIRequestSize,
        BoundOriginalGame::GameCodeStart,BoundOriginalGame::GameCodeEnd,0,0,0,0,
        [](uint8_t *p) { for(const auto &entry:BoundOriginalGame::GameBaseDefinitions) memcpy(p+entry.offset,entry.bytes,entry.size); },0,0,0,0,0,0,0,0
    };
}();
static const MultiRedNativeProfile MultiRedStackSafeProfile={
    BoundStackSafeGame::GameDescriptor,BoundStackSafeGame::GameCanonicalSHA256,BoundStackSafeGame::GameRulesetID,
    BoundStackSafeGame::GameDescriptorOffset,sizeof(BoundStackSafeGame::GameDescriptor),BoundStackSafeGame::GameHostOffset,BoundStackSafeGame::GameHostSize,
    BoundStackSafeGame::GameSnapshotAddress,BoundStackSafeGame::GameSnapshotSize,BoundStackSafeGame::GameSnapshotRegionSize,
    BoundStackSafeGame::GameABIMajor,BoundStackSafeGame::GameABIMinor,BoundStackSafeGame::GameSaveStateLayout,
    BoundStackSafeGame::GameUIHostOffset,BoundStackSafeGame::GameUIHostSize,BoundStackSafeGame::GameUIRequestAddress,BoundStackSafeGame::GameUIRequestSize,
    BoundStackSafeGame::GameCodeStart,BoundStackSafeGame::GameCodeEnd,
    BoundStackSafeGame::GameCooperativeHostOffset,BoundStackSafeGame::GameCooperativeHostSize,
    BoundStackSafeGame::GameCooperativeCodeStart,BoundStackSafeGame::GameCooperativeCodeEnd,
    [](uint8_t *p) { for(const auto &entry:BoundStackSafeGame::GameBaseDefinitions) memcpy(p+entry.offset,entry.bytes,entry.size); },0,0,0,0,0,0,0,0
};
static const MultiRedNativeProfile MultiRedDebugDefaultsProfile={
    BoundDebugDefaultsGame::GameDescriptor,BoundDebugDefaultsGame::GameCanonicalSHA256,BoundDebugDefaultsGame::GameRulesetID,
    BoundDebugDefaultsGame::GameDescriptorOffset,sizeof(BoundDebugDefaultsGame::GameDescriptor),BoundDebugDefaultsGame::GameHostOffset,BoundDebugDefaultsGame::GameHostSize,
    BoundDebugDefaultsGame::GameSnapshotAddress,BoundDebugDefaultsGame::GameSnapshotSize,BoundDebugDefaultsGame::GameSnapshotRegionSize,
    BoundDebugDefaultsGame::GameABIMajor,BoundDebugDefaultsGame::GameABIMinor,BoundDebugDefaultsGame::GameSaveStateLayout,
    BoundDebugDefaultsGame::GameUIHostOffset,BoundDebugDefaultsGame::GameUIHostSize,BoundDebugDefaultsGame::GameUIRequestAddress,BoundDebugDefaultsGame::GameUIRequestSize,
    BoundDebugDefaultsGame::GameCodeStart,BoundDebugDefaultsGame::GameCodeEnd,
    BoundDebugDefaultsGame::GameCooperativeHostOffset,BoundDebugDefaultsGame::GameCooperativeHostSize,
    BoundDebugDefaultsGame::GameCooperativeCodeStart,BoundDebugDefaultsGame::GameCooperativeCodeEnd,
    [](uint8_t *p) { for(const auto &entry:BoundDebugDefaultsGame::GameBaseDefinitions) memcpy(p+entry.offset,entry.bytes,entry.size); },0,0,0,0,0,0,0,0
};
static const MultiRedNativeProfile MultiRedFriendsMultiviewProfile={
    BoundFriendsMultiviewGame::GameDescriptor,BoundFriendsMultiviewGame::GameCanonicalSHA256,BoundFriendsMultiviewGame::GameRulesetID,
    BoundFriendsMultiviewGame::GameDescriptorOffset,sizeof(BoundFriendsMultiviewGame::GameDescriptor),BoundFriendsMultiviewGame::GameHostOffset,BoundFriendsMultiviewGame::GameHostSize,
    BoundFriendsMultiviewGame::GameSnapshotAddress,BoundFriendsMultiviewGame::GameSnapshotSize,BoundFriendsMultiviewGame::GameSnapshotRegionSize,
    BoundFriendsMultiviewGame::GameABIMajor,BoundFriendsMultiviewGame::GameABIMinor,BoundFriendsMultiviewGame::GameSaveStateLayout,
    BoundFriendsMultiviewGame::GameUIHostOffset,BoundFriendsMultiviewGame::GameUIHostSize,BoundFriendsMultiviewGame::GameUIRequestAddress,BoundFriendsMultiviewGame::GameUIRequestSize,
    BoundFriendsMultiviewGame::GameCodeStart,BoundFriendsMultiviewGame::GameCodeEnd,
    BoundFriendsMultiviewGame::GameCooperativeHostOffset,BoundFriendsMultiviewGame::GameCooperativeHostSize,
    BoundFriendsMultiviewGame::GameCooperativeCodeStart,BoundFriendsMultiviewGame::GameCooperativeCodeEnd,
    [](uint8_t *p) { for(const auto &entry:BoundFriendsMultiviewGame::GameBaseDefinitions) memcpy(p+entry.offset,entry.bytes,entry.size); },0,0,0,0,0,0,0,0
};
static const MultiRedNativeProfile MultiRedPreShinyMagikarpProfile={
    BoundPreShinyMagikarpGame::GameDescriptor,BoundPreShinyMagikarpGame::GameCanonicalSHA256,BoundPreShinyMagikarpGame::GameRulesetID,
    BoundPreShinyMagikarpGame::GameDescriptorOffset,sizeof(BoundPreShinyMagikarpGame::GameDescriptor),BoundPreShinyMagikarpGame::GameHostOffset,BoundPreShinyMagikarpGame::GameHostSize,
    BoundPreShinyMagikarpGame::GameSnapshotAddress,BoundPreShinyMagikarpGame::GameSnapshotSize,BoundPreShinyMagikarpGame::GameSnapshotRegionSize,
    BoundPreShinyMagikarpGame::GameABIMajor,BoundPreShinyMagikarpGame::GameABIMinor,BoundPreShinyMagikarpGame::GameSaveStateLayout,
    BoundPreShinyMagikarpGame::GameUIHostOffset,BoundPreShinyMagikarpGame::GameUIHostSize,BoundPreShinyMagikarpGame::GameUIRequestAddress,BoundPreShinyMagikarpGame::GameUIRequestSize,
    BoundPreShinyMagikarpGame::GameCodeStart,BoundPreShinyMagikarpGame::GameCodeEnd,
    BoundPreShinyMagikarpGame::GameCooperativeHostOffset,BoundPreShinyMagikarpGame::GameCooperativeHostSize,
    BoundPreShinyMagikarpGame::GameCooperativeCodeStart,BoundPreShinyMagikarpGame::GameCooperativeCodeEnd,
    [](uint8_t *p) { for(const auto &entry:BoundPreShinyMagikarpGame::GameBaseDefinitions) memcpy(p+entry.offset,entry.bytes,entry.size); },0,0,0,0,0,0,0,0
};
static const MultiRedNativeProfile MultiRedPreLinksMenuProfile={
    BoundPreLinksMenuGame::GameDescriptor,BoundPreLinksMenuGame::GameCanonicalSHA256,BoundPreLinksMenuGame::GameRulesetID,
    BoundPreLinksMenuGame::GameDescriptorOffset,sizeof(BoundPreLinksMenuGame::GameDescriptor),BoundPreLinksMenuGame::GameHostOffset,BoundPreLinksMenuGame::GameHostSize,
    BoundPreLinksMenuGame::GameSnapshotAddress,BoundPreLinksMenuGame::GameSnapshotSize,BoundPreLinksMenuGame::GameSnapshotRegionSize,
    BoundPreLinksMenuGame::GameABIMajor,BoundPreLinksMenuGame::GameABIMinor,BoundPreLinksMenuGame::GameSaveStateLayout,
    BoundPreLinksMenuGame::GameUIHostOffset,BoundPreLinksMenuGame::GameUIHostSize,BoundPreLinksMenuGame::GameUIRequestAddress,BoundPreLinksMenuGame::GameUIRequestSize,
    BoundPreLinksMenuGame::GameCodeStart,BoundPreLinksMenuGame::GameCodeEnd,
    BoundPreLinksMenuGame::GameCooperativeHostOffset,BoundPreLinksMenuGame::GameCooperativeHostSize,
    BoundPreLinksMenuGame::GameCooperativeCodeStart,BoundPreLinksMenuGame::GameCooperativeCodeEnd,
    [](uint8_t *p) { for(const auto &entry:BoundPreLinksMenuGame::GameBaseDefinitions) memcpy(p+entry.offset,entry.bytes,entry.size); },0,0,0,0,0,0,0,0
};
static const MultiRedNativeProfile *multiRedProfile(const uint8_t *p) {
    if(MultiRedCurrentProfile.matches(p)) return &MultiRedCurrentProfile;
    if(MultiRedLinksMenuProfile.matches(p)) return &MultiRedLinksMenuProfile;
    if(MultiRedPreLinksMenuProfile.matches(p)) return &MultiRedPreLinksMenuProfile;
    if(MultiRedPreShinyMagikarpProfile.matches(p)) return &MultiRedPreShinyMagikarpProfile;
    if(MultiRedFriendsMultiviewProfile.matches(p)) return &MultiRedFriendsMultiviewProfile;
    if(MultiRedDebugDefaultsProfile.matches(p)) return &MultiRedDebugDefaultsProfile;
    if(MultiRedStackSafeProfile.matches(p)) return &MultiRedStackSafeProfile;
    if(MultiRedOriginalProfile.matches(p)) return &MultiRedOriginalProfile;
    return nullptr;
}
