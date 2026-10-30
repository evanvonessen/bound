#import "BoundVBABattleBridge.h"
#import <DeltaCore/DeltaCore.h>
#import <DeltaCore/DeltaCore-Swift.h>
#import <GBADeltaCore/GBADeltaCore.h>
#import <CommonCrypto/CommonDigest.h>
#import <objc/runtime.h>
#import <os/signpost.h>
#include <cstdint>
#include <atomic>
#include <chrono>
#include <cstring>
#include <mutex>
#include <set>
#include <string>
#include <zlib.h>
#include "NativeBattle/BoundBattleEntryCode.h"
#include "NativeBattle/BoundBattleDecisionCode.h"
#include "SoulLink/soul-layout.h"
#include "SDK/bound_sdk.h"
#include "SDK/Generated/BoundSDKProtocol.h"

extern uint8_t *rom,*workRAM,*internalRAM,*ioMem;
extern uint8_t flashSaveMemory[0x20000];
extern int flashSize;
extern int skipSaveGameBattery,skipSaveGameCheats;
extern void flashSetSize(int size);
extern bool CPUWriteMemState(char *,int,long &);
extern bool CPUWriteMemStateUncompressed(char *,int,long &);
extern bool CPUReadMemState(char *,int);
namespace {
std::atomic<uint64_t> movementTimeline{1};
std::atomic<bool> movementRevocation{false};
std::atomic<uint64_t> movementDeadline{0};
uint64_t movementNow() {
    return std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();
}
// Bound owns this interception; upstream core sources and dependency pins stay
// unchanged. Every write, including stop() and guest save callbacks, crosses the
// same bridge selector. The lock covers the original write so a newly blocked
// path cannot race an in-flight disk write after this setter returns.
using GameSaveWriter=void (*)(id,SEL,NSURL *);
struct GameSaveFence {
    std::mutex lock;
    std::set<std::string> blockedPaths;
    std::set<std::string> cooperativeBlockedPaths;
    std::set<std::string> serverOnlyPaths;
    bool serverOnlyActive=false;
    GameSaveWriter writer=nullptr;
    GameSaveWriter reader=nullptr,stateWriter=nullptr,stateReader=nullptr;
};
GameSaveFence &gameSaveFence() { static GameSaveFence value; return value; }
using NativeFrameRunner=void (*)(id,SEL,BOOL);
using NativeStarter=void (*)(id,SEL,NSURL *);
using NativeStopper=void (*)(id,SEL);
struct SoulFrameFence {
    std::mutex lock;
    NativeFrameRunner run=nullptr;
    NativeStarter start=nullptr;
    NativeStopper stop=nullptr;
    uint64_t generation=1;
    std::string owner;
    uint8_t *cartridge=nullptr;
    bool blocked=false;
};
SoulFrameFence &soulFrameFence() { static SoulFrameFence value; return value; }
void advanceSoulFrameGeneration() {
    movementTimeline.fetch_add(1,std::memory_order_relaxed);
    [BoundVBABattleBridge setWorldMovementHost:[NSData data]];
    auto &fence=soulFrameFence();std::lock_guard<std::mutex> lock(fence.lock);
    if(++fence.generation==0) fence.generation=1;
    fence.owner.clear();fence.cartridge=nullptr;fence.blocked=false;
}
void fencedNativeFrame(id bridge,SEL selector,BOOL video) {
    auto &fence=soulFrameFence();NativeFrameRunner original;
    { std::lock_guard<std::mutex> lock(fence.lock);
      if(fence.blocked&&fence.cartridge==rom) return;
      original=fence.run; }
    const auto deadline=movementDeadline.load(std::memory_order_relaxed);
    if(movementRevocation.exchange(false,std::memory_order_relaxed)||(deadline&&movementNow()>deadline))
        [BoundVBABattleBridge setWorldMovementHost:[NSData data]];
    if(original) original(bridge,selector,video);
}
void fencedNativeStart(id bridge,SEL selector,NSURL *url) {
    advanceSoulFrameGeneration();
    if(auto original=soulFrameFence().start) original(bridge,selector,url);
}
void fencedNativeStop(id bridge,SEL selector) {
    advanceSoulFrameGeneration();
    if(auto original=soulFrameFence().stop) original(bridge,selector);
}
bool installSoulFrameFence() {
    auto &fence=soulFrameFence();std::lock_guard<std::mutex> lock(fence.lock);
    if(fence.run) return true;
    Class cls=[GBAEmulatorBridge class];
    Method run=class_getInstanceMethod(cls,@selector(runFrameAndProcessVideo:));
    Method start=class_getInstanceMethod(cls,@selector(startWithGameURL:));
    Method stop=class_getInstanceMethod(cls,@selector(stop));
    if(!run||!start||!stop) return false;
    fence.run=reinterpret_cast<NativeFrameRunner>(method_setImplementation(run,reinterpret_cast<IMP>(fencedNativeFrame)));
    fence.start=reinterpret_cast<NativeStarter>(method_setImplementation(start,reinterpret_cast<IMP>(fencedNativeStart)));
    fence.stop=reinterpret_cast<NativeStopper>(method_setImplementation(stop,reinterpret_cast<IMP>(fencedNativeStop)));
    return fence.run&&fence.start&&fence.stop;
}
std::string canonicalSavePath(NSURL *url) {
    if(!url.isFileURL) return {};
    NSString *path=url.URLByStandardizingPath.URLByResolvingSymlinksInPath.path;
    const char *bytes=path.fileSystemRepresentation;
    return bytes ? std::string(bytes):std::string();
}
void fencedGameSave(id bridge,SEL selector,NSURL *url) {
    auto &fence=gameSaveFence();
    std::lock_guard<std::mutex> lock(fence.lock);
    const auto path=canonicalSavePath(url);
    if(path.empty()||fence.serverOnlyActive||fence.serverOnlyPaths.count(path)||fence.blockedPaths.count(path)||fence.cooperativeBlockedPaths.count(path)||!fence.writer) return;
    fence.writer(bridge,selector,url);
}
void fencedGameLoad(id bridge,SEL selector,NSURL *url) {
    auto &fence=gameSaveFence();std::lock_guard<std::mutex> lock(fence.lock);
    const auto path=canonicalSavePath(url);
    if(path.empty()||fence.serverOnlyActive||fence.serverOnlyPaths.count(path)||!fence.reader) return;
    fence.reader(bridge,selector,url);
}
void fencedStateSave(id bridge,SEL selector,NSURL *url) {
    auto &fence=gameSaveFence();std::lock_guard<std::mutex> lock(fence.lock);
    if(!fence.serverOnlyActive&&fence.stateWriter) fence.stateWriter(bridge,selector,url);
}
void fencedStateLoad(id bridge,SEL selector,NSURL *url) {
    auto &fence=gameSaveFence();std::lock_guard<std::mutex> lock(fence.lock);
    if(!fence.serverOnlyActive&&fence.stateReader) {
        movementTimeline.fetch_add(1,std::memory_order_relaxed);
        [BoundVBABattleBridge setWorldMovementHost:[NSData data]];
        fence.stateReader(bridge,selector,url);
    }
}
bool installGameSaveFence() {
    auto &fence=gameSaveFence();
    if(fence.writer) return true;
    Method method=class_getInstanceMethod(NSClassFromString(@"GBAEmulatorBridge"),@selector(saveGameSaveToURL:));
    if(!method) return false;
    NSMethodSignature *signature=[NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
    if(signature.numberOfArguments!=3||strcmp(signature.methodReturnType,@encode(void))
       ||[signature getArgumentTypeAtIndex:2][0]!='@') return false;
    fence.writer=reinterpret_cast<GameSaveWriter>(method_setImplementation(method,reinterpret_cast<IMP>(fencedGameSave)));
    return fence.writer!=nullptr;
}
bool installServerSaveFence() {
    auto &fence=gameSaveFence();
    if(!installGameSaveFence()) return false;
    auto install=[](SEL selector,GameSaveWriter replacement,GameSaveWriter &original) {
        if(original) return true;
        Method method=class_getInstanceMethod(NSClassFromString(@"GBAEmulatorBridge"),selector);
        if(!method) return false;
        NSMethodSignature *signature=[NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
        if(signature.numberOfArguments!=3||strcmp(signature.methodReturnType,@encode(void))||[signature getArgumentTypeAtIndex:2][0]!='@') return false;
        original=reinterpret_cast<GameSaveWriter>(method_setImplementation(method,reinterpret_cast<IMP>(replacement)));
        return original!=nullptr;
    };
    return install(@selector(loadGameSaveFromURL:),fencedGameLoad,fence.reader)
        &&install(@selector(saveSaveStateToURL:),fencedStateSave,fence.stateWriter)
        &&install(@selector(loadSaveStateFromURL:),fencedStateLoad,fence.stateReader);
}
constexpr size_t RegionOffset=0x1FFF800,RegionSize=0x800;
constexpr uint32_t ScriptAddress=0x09FFFD00,MailboxMagic=0x314D4642;
constexpr size_t Mailbox=0x4030;
struct Hook { size_t offset; uint32_t target; uint8_t original[8],thunk[8]; bool preservesArguments; };
Hook hooks[]={
    {0x81668,BoundBattleReturnAddress},
    {0x15B58,BoundBattleReturnAddress}, // Native ReturnFromBattleToOverworld, after result/text.
    {0xB398,BoundBattleLinkMain1Address},
    {0xB718,BoundBattleLinkVSyncAddress},
    {0xA404,BoundBattleMultiplayerIdAddress},
    {0xB248,BoundBattleRecvCountAddress},
    {0x5833C,BoundBattleSendCountAddress},
    {0xB2F4,BoundBattleEnableSerialAddress},
    {0xB29C,BoundBattleDisableSerialAddress},
    // Walk-up trades save the current map, not a stale cable-room dynamic warp.
    {0x4C1C0,BoundBattleLinkVSyncAddress},
    {0x56854,BoundBattleTradeReturnAddress},
    // Original RR and the integrated ROM share this native cleanup tail. The
    // latter's co-op wrapper is saved/restored with the other temporary hooks.
    {0x1090958,BoundBattlePreserveLinkFlagsAddress},
    {0x10A9F10,BoundBattleChoiceAddress,{},{},true}, // Explicit local action selection, before waiting for the peer's move.
    {0x9AF8,BoundBattlePumpAddress}, // Receive commands before throttling only the native send callback.
    // Host monotonic liveness owns network timeouts. Retain the native task's
    // connection-complete cleanup and the linkup predicate's false epilogue.
    {0x81A98,0x08081AC3},
    {0x8103C,0x0808104D},
    // Trade-scene network time belongs to the host monotonic clock. A local
    // animation may continue through an outage without a 300-frame abort.
    {0x4FF4C,BoundBattleLinkVSyncAddress},
    {0x508F4,BoundBattleTradeSendAddress},
    {0x53E1C,BoundBattleTradeWaitAddress}
};
Hook decisionHooks[]={
    {0xD8B0,BoundDecisionTransferAddress,{},{},true},
    {0xD9EC,BoundDecisionLinkTransferAddress,{},{},true},
    {0x17248,BoundDecisionMarkAddress,{},{},true},
    {0x123E4,BoundDecisionFrameAddress,{},{},true},
    {0x724,BoundDecisionVBlankAddress,{},{},true},
    {0x7AF98,BoundDecisionOverworldWeatherAddress,{},{},true},
    {0x106E52C,BoundDecisionOverworldTerrainAddress,{},{},true}
};
constexpr size_t DecisionCodeOffset=BOUND_DECISION_CODE_ADDRESS-0x08000000;
constexpr size_t DecisionStateOffset=BOUND_DECISION_ADDRESS-0x03000000;
uint32_t decisionSeed=1;
uint8_t *verifiedROM=nullptr,*patchedROM=nullptr;
bool armed=false,installed=false,failed=false,syntheticHeld=false,cooperativeCable=false;
unsigned role=0,preparationFrames=0,tradeCount=0;
bool tradeMode=false,tradeOpened=false,tradeScene=false;
bool usesHook(size_t index) {
    if(index>=16) return tradeMode;
    return index>=13 || (cooperativeCable ? index>=2&&index<9 : tradeMode ? index>=2&&index<11 : index<9||index>=11);
}
uint16_t networkRead=0;
uint32_t word(const uint8_t *p) { return p[0]|uint32_t(p[1])<<8|uint32_t(p[2])<<16|uint32_t(p[3])<<24; }
unsigned half(const uint8_t *p) { return p[0]|unsigned(p[1])<<8; }
void put16(uint8_t *p,unsigned v) { p[0]=v; p[1]=v>>8; }
void put32(uint8_t *p,uint32_t v) { for(int i=0;i<4;i++) p[i]=uint8_t(v>>(i*8)); }
bool acknowledgeSoulRing(uint8_t *ring,NSData *identities) {
    if(!ring||word(ring)!=0x314C5342||word(ring+8)) return false;
    const unsigned count=word(ring+4);
    if(count>32||identities.length!=count*8||(identities.length&&memcmp(ring+12,identities.bytes,identities.length))) return false;
    put32(ring+4,0);put32(ring+8,0);return true;
}
// Used only by the completed-frame owner or while its core is paused. Returned
// data owns immutable bytes; a retained Swift snapshot never aliases live RAM.
struct SoulBoxSnapshotCache {
    static constexpr unsigned Count=25,Stride=30*58,Size=Count*Stride;
    NSData *bytes=nil;
    NSData *read(const uint8_t *table,const uint8_t *ram) {
        const uint8_t *blocks[Count];
        for(unsigned i=0;i<Count;i++) {
            const uint32_t address=word(table+i*4);
            if(address<0x02000000||address>0x02040000-Stride) return nil;
            blocks[i]=ram+address-0x02000000;
        }
        // Full equality also covers ROM reloads and older state restores; no
        // pointer identity or checksum can hide changed storage contents.
        bool same=bytes.length==Size;
        const auto *previous=static_cast<const uint8_t *>(bytes.bytes);
        for(unsigned i=0;same&&i<Count;i++) same=memcmp(previous+i*Stride,blocks[i],Stride)==0;
        if(same) return bytes;
        NSMutableData *copy=[NSMutableData dataWithLength:Size];
        for(unsigned i=0;i<Count;i++) memcpy(static_cast<uint8_t *>(copy.mutableBytes)+i*Stride,blocks[i],Stride);
        bytes=[copy copy];
        return bytes;
    }
};
SoulBoxSnapshotCache soulBoxCache;
bool overworld() {
    return rom&&workRAM&&internalRAM&&word(internalRAM+0x30F0)==0x08056535
        &&word(internalRAM+0x30F4)==0x080565B5&&!(internalRAM[0x3529]&2)
        &&internalRAM[0xF9C]==0&&internalRAM[0xEA8]==2;
}
#if DEBUG && TARGET_OS_SIMULATOR
bool qaLegacyFieldTextAdmission=false;
#endif
bool fieldTextIdle() {
#if DEBUG && TARGET_OS_SIMULATOR
    if(qaLegacyFieldTextAdmission) return true;
#endif
    // Script locks can already be released while window 0 still owns native
    // text, including a pending RESUME_MUSIC control. A new field message
    // replaces that printer and can permanently discard the resume command.
    // Check both the message task's mode and IsTextPrinterActive(0)'s byte.
    return workRAM&&workRAM[0x3709C]==0&&workRAM[0x20034+0x1B]==0;
}
bool fieldInterruptionReady() { return overworld()&&fieldTextIdle(); }
bool mailboxReady() { return installed&&internalRAM&&word(internalRAM+Mailbox)==MailboxMagic; }
BoundDecisionState *decisionState() {
    if(!installed||tradeMode||cooperativeCable||!internalRAM) return nullptr;
    auto *state=reinterpret_cast<BoundDecisionState *>(internalRAM+DecisionStateOffset);
    return state->magic==BOUND_DECISION_MAGIC ? state:nullptr;
}
NSMutableArray<NSNumber *> *partyHP(size_t offset,unsigned count) {
    NSMutableArray<NSNumber *> *values=[NSMutableArray array];
    for(unsigned i=0;i<count&&i<6;i++) [values addObject:@(half(workRAM+offset+i*100+86))];
    return values;
}
}
#include "SharedWorld/bridge.inc"
static_assert(GameUIHostSize==BOUND_SDK_UIHOST_BYTE_SIZE && GameUIRequestSize==BOUND_SDK_UIREQUEST_BYTE_SIZE,
              "SDK UI schema differs from cartridge ABI");
static_assert(GameHostSize==BOUND_SDK_GAME_HOST_BYTE_SIZE && GameSnapshotSize==BOUND_SDK_GAME_SNAPSHOT_BYTE_SIZE
              && GameSnapshotRegionSize==BOUND_SDK_SNAPSHOT_CONTROL_BYTE_SIZE,
              "SDK world schema differs from cartridge ABI");
#ifdef BOUND_GAME_COOPERATIVE_DOUBLES
static_assert(GameCooperativeHostSize==BOUND_SDK_COOPERATIVE_HOST_BYTE_SIZE
              && GameCooperativeSnapshotSize==BOUND_SDK_COOPERATIVE_SNAPSHOT_BYTE_SIZE,
              "SDK cooperative schema differs from cartridge ABI");
static_assert(BoundStackSafeGame::GameCooperativeSnapshotAddress==GameCooperativeSnapshotAddress
              && BoundStackSafeGame::GameCooperativeSnapshotSize==GameCooperativeSnapshotSize,
              "Historical cooperative snapshot requires a separate decoder");
static_assert(BoundDebugDefaultsGame::GameCooperativeSnapshotAddress==GameCooperativeSnapshotAddress
              && BoundDebugDefaultsGame::GameCooperativeSnapshotSize==GameCooperativeSnapshotSize,
              "Historical cooperative snapshot requires a separate decoder");
static_assert(BoundFriendsMultiviewGame::GameCooperativeSnapshotAddress==GameCooperativeSnapshotAddress
              && BoundFriendsMultiviewGame::GameCooperativeSnapshotSize==GameCooperativeSnapshotSize,
              "Historical cooperative snapshot requires a separate decoder");
#endif
#include "SoulLink/bridge.inc"
#include "NativeBattle/invitation.inc"
#include "NativeBattle/follower-berry.inc"
namespace {
uint8_t *romUIOwner=nullptr,*cooperativeROM=nullptr;
const MultiRedNativeProfile *romUIProfile=nullptr;
bool ownsROMUI() { return romUIOwner==rom && romUIProfile && romUIProfile==multiRedProfile(rom); }
bool nativeProfileVerified() {
    const uint8_t expected[32]={0x68,0x92,0x99,0x66,0x4a,0x95,0x4c,0x12,0xda,0xd6,0x6e,0x03,0xc2,0xd1,0x84,0x46,
        0xb3,0x48,0xcb,0x31,0xbd,0x98,0xb3,0x95,0xc8,0x7b,0x9b,0x51,0x4b,0x28,0x80,0x66};
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    return soulOriginalHash(digest)&&memcmp(digest,expected,32)==0;
}
NSData *nativeCodeIdentity() {
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256_CTX context;
    CC_SHA256_Init(&context);CC_SHA256_Update(&context,BoundBattleEntryCode,sizeof(BoundBattleEntryCode));
    CC_SHA256_Update(&context,BoundBattleDecisionCode,sizeof(BoundBattleDecisionCode));CC_SHA256_Final(digest,&context);
    return [NSData dataWithBytes:digest length:sizeof(digest)];
}
bool soulDenies(const uint8_t *mon) {
    if(!soulHooked()||word(rom+SoulPolicy)!=0x314C5342) return false;
    unsigned count=word(rom+SoulPolicy+4);
    if(count>2048) return true;
    for(unsigned i=0;i<count;i++) if(memcmp(mon,rom+SoulPolicy+8+i*8,8)==0) return true;
    return false;
}
// The temporary battle party contains only eligible non-eggs. Dead Soul Link
// slots remain in the prebattle snapshot and are never healed or exchanged.
bool prepareFriendlyParty() {
    uint8_t party[600]={};unsigned count=0;
    for(unsigned i=0;i<workRAM[0x24029]&&i<6;i++) {
        const auto *mon=workRAM+0x24284+i*100;
        if((mon[19]&4)||(mon[75]&0x40)||half(mon+88)==0||soulDenies(mon)) continue;
        memcpy(party+count++*100,mon,100);
    }
    if(!count) return false;
    memcpy(workRAM+0x24284,party,sizeof(party));workRAM[0x24029]=uint8_t(count);
    return true;
}
// Recreating this fixed ROM code does not execute the entry script. A resumed
// native core keeps its existing PC, script context, mailbox and party in RAM.
bool writeNativeROM() {
    if(tradeMode) {
        // These two entry points are identical in both admitted ROM profiles.
        // Never install a trade-only hook over an unexpected native routine.
        const uint8_t timeout[8]={0x30,0xB5,0x08,0x48,0x02,0x68,0x11,0x1C};
        const uint8_t send[8]={0x10,0xB5,0x04,0x4C,0x20,0x68,0x93,0x30};
        const uint8_t wait[8]={0x10,0xB5,0xFC,0xF7,0xD1,0xF8,0x04,0x1C};
        if(memcmp(rom+0x4FF4C,timeout,8)||memcmp(rom+0x508F4,send,8)||memcmp(rom+0x53E1C,wait,8)) return false;
    }
    uint8_t script[128];size_t n=0;
    auto byte=[&](uint8_t v) { script[n++]=v; };
    auto half=[&](uint16_t v) { byte(v);byte(v>>8); };
    auto ptr=[&](uint32_t v) { for(int i=0;i<4;i++) byte(v>>(8*i)); };
    auto setvar=[&](uint16_t var,uint16_t value) { byte(0x16);half(var);half(value); };
    auto special=[&](uint16_t id) { byte(0x25);half(id); };
    setvar(0x8004,tradeMode?3:1);setvar(0x8005,uint16_t(role));setvar(0x800D,0);
    if(tradeMode) {
        special(35);byte(0x27);
        byte(0x21);half(0x800D);half(1);
        byte(0x06);byte(1);size_t savedPointer=n;ptr(0);
        byte(0x23);ptr(BoundBattleReturnAddress);byte(0x27);byte(0x02);
        put32(script+savedPointer,ScriptAddress+uint32_t(n));
    } else {
        // Heal the eligible temporary copy before any peer can receive it.
        special(0);
    }
    special(tradeMode?29:28);byte(0x27);
    byte(0x21);half(0x800D);half(1);
    byte(0x06);byte(1);size_t successPointer=n;ptr(0);
    byte(0x23);ptr(BoundBattleReturnAddress);byte(0x27);byte(0x02);
    put32(script+successPointer,ScriptAddress+uint32_t(n));
    if(tradeMode) { special(34);byte(0x27);byte(0x02); }
    else {
        special(39);special(331); // Native SavePlayerParty and LoadPlayerBag.
        byte(0x23);ptr(BoundBattleStartAddress);byte(0x27);byte(0x02);
    }
    if(n>sizeof(script)) return false;
    memcpy(rom+RegionOffset,BoundBattleEntryCode,sizeof(BoundBattleEntryCode));rom[0x1FFFCF0]=uint8_t(role);
    if(!cooperativeCable) memcpy(rom+ScriptAddress-0x08000000,script,n);
    for(size_t index=0;index<sizeof(hooks)/sizeof(hooks[0]);index++) {
        if(!usesHook(index)) continue;
        auto &hook=hooks[index];memcpy(hook.original,rom+hook.offset,8);
        hook.thunk[0]=0;hook.thunk[1]=hook.preservesArguments?0x4B:0x48;
        hook.thunk[2]=hook.preservesArguments?0x18:0;hook.thunk[3]=0x47;
        put32(hook.thunk+4,hook.target);memcpy(rom+hook.offset,hook.thunk,8);
    }
    if(!tradeMode&&!cooperativeCable) {
        memcpy(rom+DecisionCodeOffset,BoundBattleDecisionCode,sizeof(BoundBattleDecisionCode));
        for(auto &hook:decisionHooks) {
            memcpy(hook.original,rom+hook.offset,8);
            hook.thunk[0]=0;hook.thunk[1]=0x4B;hook.thunk[2]=0x18;hook.thunk[3]=0x47;
            put32(hook.thunk+4,hook.target);memcpy(rom+hook.offset,hook.thunk,8);
        }
    }
    patchedROM=rom;return true;
}
}
#if DEBUG && TARGET_OS_SIMULATOR
#include "SoulLink/BoundSoulQACode.h"
#if defined(BOUND_QA_GUEST_TIMING) && BOUND_QA_GUEST_TIMING
#include "../../Cores/GBADeltaCore/visualboyadvance-m/src/gba/BoundQAGuestTiming.h"
#endif
extern uint32_t armNextPC;
static uint8_t soulQAScriptBackup[128];
namespace {
constexpr unsigned MovementEntryOffsets[]={0x4B0,0x56578};
constexpr uint8_t MovementNativeEntries[2][8]={
    {0x00,0xB5,0x0A,0xF0,0x61,0xFE,0x00,0x06},
    {0x00,0xB5,0x13,0xF0,0x95,0xFA,0x20,0xF0}
};
static __weak DLTAEmulatorCore *movementEntryCore;
static uint8_t *movementEntryROM=nullptr;
static uint8_t movementSavedEntries[2][8];
static const MultiRedNativeProfile *movementEntryProfile=nullptr;
static NSString *movementEntryNormalizedSHA=nil;
#if defined(BOUND_QA_GUEST_TIMING) && BOUND_QA_GUEST_TIMING
static __weak DLTAEmulatorCore *guestTimingCore;
static uint8_t *guestTimingROM=nullptr;
static NSDictionary<NSString *,id> *guestTimingMetadata=nil;
#endif
NSString *movementEntryHash(const void *bytes,CC_LONG count) {
    uint8_t hash[CC_SHA256_DIGEST_LENGTH];CC_SHA256(bytes,count,hash);
    NSMutableString *text=[NSMutableString stringWithCapacity:64];
    for(uint8_t byte:hash)[text appendFormat:@"%02x",byte];return text;
}
bool movementEntryPipelineClear() {
    if(armNextPC<0x08000000||armNextPC>=0x0E000000)return true;
    const unsigned offset=armNextPC&0x1FFFFFF;
    for(unsigned at:MovementEntryOffsets)if(offset>=at-4&&offset<at+12)return false;
    return true;
}
}
#endif

@implementation BoundVBABattleBridge
+ (void)load {
    // Intercept before any core can start an unguarded battery write. Paths are
    // initially allowed; protected games register their fence during binding.
    auto &fence=gameSaveFence();
    std::lock_guard<std::mutex> lock(fence.lock);
    installGameSaveFence();
}
+ (BOOL)setROMGameSaveAllowed:(BOOL)allowed forURL:(NSURL *)url {
    auto &fence=gameSaveFence();
    std::lock_guard<std::mutex> lock(fence.lock);
    const auto path=canonicalSavePath(url);
    if(path.empty()||!installGameSaveFence()) return NO;
    if(allowed) fence.blockedPaths.erase(path);
    else fence.blockedPaths.insert(path);
    return YES;
}
+ (BOOL)setServerOnlyGameSave:(BOOL)enabled forURL:(NSURL *)url {
    auto &fence=gameSaveFence();std::lock_guard<std::mutex> lock(fence.lock);
    const auto path=canonicalSavePath(url);
    if(path.empty()||!installServerSaveFence()) return NO;
    fence.serverOnlyActive=enabled;
    if(enabled) fence.serverOnlyPaths.insert(path);
    // A previously marked path remains protected even after a different game
    // binds. Its old persistent save can never be loaded by a delayed callback.
    return YES;
}
+ (NSData *)captureServerState {
    return [self captureServerStateWithCompression:YES];
}
+ (NSData *)captureUncompressedServerState {
    return [self captureServerStateWithCompression:NO];
}
+ (NSData *)captureServerStateWithCompression:(BOOL)compress {
    static os_log_t log=os_log_create("com.evanvonessen.bound","Checkpoint");
    const auto signpost=os_signpost_id_generate(log);
    os_signpost_interval_begin(log,signpost,"StateCapture","compressed=%d",compress);
    auto finish=[&] {os_signpost_interval_end(log,signpost,"StateCapture");};
    struct EndCapture { decltype(finish)& end; ~EndCapture(){end();} } end{finish};
    if(!rom||!workRAM||!internalRAM) return [NSData data];
    NSMutableData *data=[NSMutableData dataWithLength:4*1024*1024];
    long reserved=0;
    const auto writer=compress ? CPUWriteMemState:CPUWriteMemStateUncompressed;
    if(!writer(static_cast<char *>(data.mutableBytes),int(data.length),reserved)) return [NSData data];
    const auto *bytes=static_cast<const uint8_t *>(data.bytes);
    // VBA's memory writer prepends its own eight-byte length header. Read the
    // finalized length after gzip close rather than its pre-close estimate.
    const size_t length=size_t(word(bytes+4))+8;
    if(memcmp(bytes,"VBA ",4)||length<=32||length>data.length) return [NSData data];
    data.length=length;
    bytes=static_cast<const uint8_t *>(data.bytes);
    if(const auto *profile=multiRedProfile(rom)) {
        // Standard gzip FEXTRA; the pinned v10 reader already skips it. Keep
        // decompressed core bytes unchanged and bind even an empty field page
        // after native heap reset to its exact ROM/layout and compressed bytes.
        if(length<18||bytes[8]!=0x1F||bytes[9]!=0x8B||bytes[10]!=8||bytes[11]!=0||length+74>4*1024*1024) return [NSData data];
        uint8_t extra[74]={};put16(extra,72);extra[2]='B';extra[3]='R';put16(extra+4,68);
        memcpy(extra+6,profile->canonicalHash,32);put32(extra+38,profile->layout);
        CC_SHA256(bytes+18,CC_LONG(length-18),extra+42);
        NSMutableData *tagged=[NSMutableData dataWithBytes:bytes length:18];
        static_cast<uint8_t *>(tagged.mutableBytes)[11]|=4;
        [tagged appendBytes:extra length:sizeof(extra)];[tagged appendBytes:bytes+18 length:length-18];
        put32(static_cast<uint8_t *>(tagged.mutableBytes)+4,uint32_t(tagged.length-8));
        return tagged;
    }
    return data;
}
+ (NSData *)compressServerState:(NSData *)snapshot {
    static os_log_t log=os_log_create("com.evanvonessen.bound","Checkpoint");
    const auto signpost=os_signpost_id_generate(log);
    os_signpost_interval_begin(log,signpost,"StateCompression");
    auto finish=[&] {os_signpost_interval_end(log,signpost,"StateCompression");};
    struct EndCompression { decltype(finish)& end; ~EndCompression(){end();} } end{finish};
    // No ROM, RAM, utilGz* dispatch pointers or other mutable core globals here.
    // Preserve the exact decompressed serialization and capture-time binding.
    constexpr size_t limit=4*1024*1024;
    if(snapshot.length<=32||snapshot.length>limit) return [NSData data];
    const auto *bytes=static_cast<const uint8_t *>(snapshot.bytes);
    if(memcmp(bytes,"VBA ",4)||size_t(word(bytes+4))+8!=snapshot.length
       ||bytes[8]!=0x1F||bytes[9]!=0x8B||bytes[10]!=8||(bytes[11]!=0&&bytes[11]!=4)) return [NSData data];
    const bool tagged=bytes[11]==4;
    if(tagged) {
        if(snapshot.length<=92||half(bytes+18)!=72||bytes[20]!='B'||bytes[21]!='R'||half(bytes+22)!=68) return [NSData data];
        uint8_t digest[32];CC_SHA256(bytes+92,CC_LONG(snapshot.length-92),digest);
        if(memcmp(digest,bytes+60,32)) return [NSData data];
    }
    NSMutableData *raw=[NSMutableData dataWithLength:limit];
    z_stream decoder={};
    decoder.next_in=const_cast<Bytef *>(bytes+8);decoder.avail_in=uInt(snapshot.length-8);
    decoder.next_out=static_cast<Bytef *>(raw.mutableBytes);decoder.avail_out=uInt(raw.length);
    if(inflateInit2(&decoder,15+16)!=Z_OK) return [NSData data];
    const int decoded=inflate(&decoder,Z_FINISH);
    const size_t rawLength=decoder.total_out;const auto remaining=decoder.avail_in;
    inflateEnd(&decoder);
    if(decoded!=Z_STREAM_END||remaining||rawLength<700000||rawLength>limit) return [NSData data];
    NSMutableData *result=[NSMutableData dataWithLength:limit];
    memcpy(result.mutableBytes,"VBA ",4);
    z_stream encoder={};
    encoder.next_in=static_cast<Bytef *>(raw.mutableBytes);encoder.avail_in=uInt(rawLength);
    encoder.next_out=static_cast<Bytef *>(result.mutableBytes)+8;encoder.avail_out=uInt(limit-8-74);
    if(deflateInit2(&encoder,Z_DEFAULT_COMPRESSION,Z_DEFLATED,15+16,8,Z_DEFAULT_STRATEGY)!=Z_OK) return [NSData data];
    const int encoded=deflate(&encoder,Z_FINISH);const size_t size=encoder.total_out+8;
    deflateEnd(&encoder);
    if(encoded!=Z_STREAM_END) return [NSData data];
    result.length=size;
    if(tagged) {
        uint8_t extra[74];memcpy(extra,bytes+18,74);
        const auto *compressed=static_cast<const uint8_t *>(result.bytes);
        CC_SHA256(compressed+18,CC_LONG(size-18),extra+42);
        NSMutableData *bound=[NSMutableData dataWithBytes:compressed length:18];
        static_cast<uint8_t *>(bound.mutableBytes)[11]|=4;
        [bound appendBytes:extra length:74];[bound appendBytes:compressed+18 length:size-18];
        result=bound;
    }
    put32(static_cast<uint8_t *>(result.mutableBytes)+4,uint32_t(result.length-8));
    return result;
}
+ (BOOL)restoreServerState:(NSData *)data {
    if(!rom||!workRAM||!internalRAM||data.length<=32||data.length>4*1024*1024) return NO;
    const auto *bytes=static_cast<const uint8_t *>(data.bytes);
    if(memcmp(bytes,"VBA ",4)||size_t(word(bytes+4))+8!=data.length) return NO;
    const auto *profile=multiRedProfile(rom);
    bool exactCaptureIdentity=false;
    if(data.length>=24&&(bytes[11]&4)&&bytes[20]=='B'&&bytes[21]=='R') {
        if(data.length<=92||half(bytes+18)!=72||half(bytes+22)!=68||!profile
           ||memcmp(bytes+24,profile->canonicalHash,32)||word(bytes+56)!=profile->layout) return NO;
        uint8_t digest[32];CC_SHA256(bytes+92,CC_LONG(data.length-92),digest);
        if(memcmp(digest,bytes+60,32)) return NO;
        exactCaptureIdentity=true;
    }
    // The upstream memory reader trusts the embedded size and gzip stream.
    // Validate both before handing it an authenticated but possibly damaged
    // server checkpoint, bounding decompression before any core mutation.
    NSMutableData *decoded=[NSMutableData dataWithLength:4*1024*1024];
    z_stream stream={};
    stream.next_in=const_cast<Bytef *>(bytes+8);stream.avail_in=uInt(data.length-8);
    stream.next_out=static_cast<Bytef *>(decoded.mutableBytes);stream.avail_out=uInt(decoded.length);
    if(inflateInit2(&stream,15+16)!=Z_OK) return NO;
    const int result=inflate(&stream,Z_FINISH);const auto length=stream.total_out;const auto remaining=stream.avail_in;
    inflateEnd(&stream);
    if(result!=Z_STREAM_END||remaining!=0||length<700000||length>decoded.length) return NO;
    const auto *raw=static_cast<const uint8_t *>(decoded.bytes);
    if(word(raw)!=10||memcmp(raw+4,rom+0xA0,16)) return NO;
    // Pinned VBA-M v10: version/title/BIOS, 45 registers, 267 bytes of
    // saveGameStruct, stop/IRQ, IWRAM and palette precede EWRAM. The profile
    // verifier checks this offset against the pinned source. Managed snapshots
    // must carry their own committed ruleset/layout before any core mutation.
    if(profile) {
        constexpr size_t stateWorkRAMOffset=34271;
        if(length<stateWorkRAMOffset+0x40000
           ||!profile->admitsStateRAM(raw+stateWorkRAMOffset,0x40000,exactCaptureIdentity)) return NO;
    }
    NSMutableData *owned=[data mutableCopy];
    // Delta's ordinary load reapplies the current cheat configuration. Keep
    // that configuration here too; only the server snapshot supplies battery.
    const int previousBattery=skipSaveGameBattery,previousCheats=skipSaveGameCheats;
    movementTimeline.fetch_add(1,std::memory_order_relaxed);
    [self setWorldMovementHost:[NSData data]];
    skipSaveGameBattery=0;skipSaveGameCheats=1;
    const bool restored=CPUReadMemState(static_cast<char *>(owned.mutableBytes),int(owned.length));
    skipSaveGameBattery=previousBattery;skipSaveGameCheats=previousCheats;
    return restored;
}
+ (NSData *)captureServerBattery {
    if(!rom||!workRAM||!internalRAM||flashSize!=0x20000) return [NSData data];
    return [NSData dataWithBytes:flashSaveMemory length:0x20000];
}
+ (BOOL)restoreServerBattery:(NSData *)data {
    if(!rom||!workRAM||!internalRAM||data.length!=0x20000) return NO;
    flashSetSize(0x20000);memcpy(flashSaveMemory,data.bytes,0x20000);return YES;
}
+ (BOOL)setCooperativeGameSaveAllowed:(BOOL)allowed forURL:(NSURL *)url {
    auto &fence=gameSaveFence();std::lock_guard<std::mutex> lock(fence.lock);
    const auto path=canonicalSavePath(url);if(path.empty()||!installGameSaveFence()) return NO;
    if(allowed) fence.cooperativeBlockedPaths.erase(path);else fence.cooperativeBlockedPaths.insert(path);
    return YES;
}
// All new cooperative gameplay access is through the generated cartridge ABI.
+ (BOOL)installCooperativeDoubles {
#ifdef BOUND_GAME_COOPERATIVE_DOUBLES
    const auto *profile=rom ? multiRedProfile(rom):nullptr;
    if(cooperativeROM==rom&&profile&&profile->cooperative()) return YES;
    if(!rom||!workRAM||!internalRAM||!profile||!profile->cooperative()
       ||GameCooperativeSnapshotAddress<0x02000000
       ||GameCooperativeSnapshotAddress+GameCooperativeSnapshotSize>0x02040000
       ||profile->cooperativeHostSize!=BOUND_SDK_COOPERATIVE_HOST_BYTE_SIZE
       ||profile->cooperativeHostOffset+profile->cooperativeHostSize>0x2000000) return NO;
    uint8_t digest[32];soulOriginalHash(digest);
    const uint8_t expected[32]={0x68,0x92,0x99,0x66,0x4a,0x95,0x4c,0x12,0xda,0xd6,0x6e,0x03,0xc2,0xd1,0x84,0x46,
        0xb3,0x48,0xcb,0x31,0xbd,0x98,0xb3,0x95,0xc8,0x7b,0x9b,0x51,0x4b,0x28,0x80,0x66};
    if(memcmp(digest,expected,32)) return NO;
    cooperativeROM=rom;return YES;
#else
    return NO;
#endif
}
+ (NSData *)cooperativeSnapshot {
#ifdef BOUND_GAME_COOPERATIVE_DOUBLES
    const auto *profile=rom ? multiRedProfile(rom):nullptr;
    if(cooperativeROM!=rom||!rom||!workRAM||!profile||!profile->cooperative()) return [NSData data];
    const auto *p=workRAM+GameCooperativeSnapshotAddress-0x02000000;
    const uint32_t sequence=word(p+8);
    if(word(p)!=BOUND_SDK_COOPERATIVE_SNAPSHOT_MAGIC||half(p+4)!=BOUND_SDK_COOPERATIVE_SNAPSHOT_MAJOR
       ||half(p+6)!=BOUND_SDK_COOPERATIVE_SNAPSHOT_MINOR||BOUND_SDK_UNCOMMITTED_SEQUENCE(sequence)) return [NSData data];
    NSData *copy=[NSData dataWithBytes:p length:GameCooperativeSnapshotSize];
    return bound_sdk_same_committed_sequence(sequence,word(p+8)) ? copy:[NSData data];
#else
    return [NSData data];
#endif
}
+ (void)setCooperativeHost:(NSData *)data {
#ifdef BOUND_GAME_COOPERATIVE_DOUBLES
    const auto *profile=rom ? multiRedProfile(rom):nullptr;
    if(cooperativeROM!=rom||!rom||!profile||!profile->cooperative()||data.length!=profile->cooperativeHostSize) return;
    const auto *p=static_cast<const uint8_t *>(data.bytes);const uint32_t sequence=word(p+8);
    if(word(p)!=BOUND_SDK_COOPERATIVE_HOST_MAGIC||half(p+4)!=BOUND_SDK_COOPERATIVE_HOST_MAJOR
       ||half(p+6)!=BOUND_SDK_COOPERATIVE_HOST_MINOR||BOUND_SDK_UNCOMMITTED_SEQUENCE(sequence)
       ||(word(p+12)&~15u)||word(p+16)>180||word(p+20)>1) return;
    auto *out=rom+profile->cooperativeHostOffset;bound_sdk_store_le32(out+8,sequence-1);
    memcpy(out,p,8);memcpy(out+12,p+12,profile->cooperativeHostSize-12);bound_sdk_store_le32(out+8,sequence);
#endif
}
+ (BOOL)prepareCooperativeCableForPlayer:(NSUInteger)player {
    if(cooperativeCable&&installed&&patchedROM==rom) return player==role;
    if(player>1||armed||installed||![self installCooperativeDoubles]) return NO;
    for(size_t i=0;i<RegionSize;i++) if(rom[RegionOffset+i]!=0xFF) return NO;
    role=unsigned(player);cooperativeCable=true;tradeMode=false;failed=false;
    memcpy(rom+RegionOffset,BoundBattleEntryCode,sizeof(BoundBattleEntryCode));rom[0x1FFFCF0]=uint8_t(role);
    for(size_t i=2;i<9;i++) {
        auto &hook=hooks[i];memcpy(hook.original,rom+hook.offset,8);
        hook.thunk[0]=0;hook.thunk[1]=0x48;hook.thunk[2]=0;hook.thunk[3]=0x47;
        put32(hook.thunk+4,hook.target);memcpy(rom+hook.offset,hook.thunk,8);
    }
    memset(internalRAM+Mailbox,0,1176);put32(internalRAM+Mailbox,MailboxMagic);networkRead=0;
    patchedROM=rom;armed=installed=true;return YES;
}
+ (void)closeCooperativeCable {
    if(cooperativeCable) [self close];
}
+ (NSData *)cooperativeCableSnapshot {
    if(!cooperativeCable||!mailboxReady()) return [NSData data];
    return [NSData dataWithBytes:internalRAM+Mailbox length:1176];
}
+ (BOOL)resumeCooperativeCableForPlayer:(NSUInteger)player {
    if(player>1||!rom||!internalRAM) return NO;
    // The paused state includes the native ring transaction. Reinstall only
    // existing transport hooks, then replay records not consumed by the peer.
    NSData *saved=[NSData dataWithBytes:internalRAM+Mailbox length:1176];
    if(word(static_cast<const uint8_t *>(saved.bytes))!=MailboxMagic) return NO;
    if(![self prepareCooperativeCableForPlayer:player]) return NO;
    memcpy(internalRAM+Mailbox,saved.bytes,1176);networkRead=half(internalRAM+Mailbox+4);
    return YES;
}
+ (NSData *)compatibleROMDescriptor:(NSData *)image {
    if(image.length!=0x2000000)return nil;
    const auto *p=static_cast<const uint8_t *>(image.bytes);
    const auto *profile=runtimeProfile(p,true);
    if(!profile)return nil;
    return [NSData dataWithBytes:profile->descriptor length:128];
}
+ (BOOL)installROMMultiplayer {
    if(ownsROMUI()) return YES;
    const auto *profile=multiRedProfile(rom);
    if(!rom||!workRAM||!internalRAM||armed||inviteActive||!profile) return NO;
    uint8_t digest[32]; soulOriginalHash(digest);
    const uint8_t expected[32]={0x68,0x92,0x99,0x66,0x4a,0x95,0x4c,0x12,0xda,0xd6,0x6e,0x03,0xc2,0xd1,0x84,0x46,
        0xb3,0x48,0xcb,0x31,0xbd,0x98,0xb3,0x95,0xc8,0x7b,0x9b,0x51,0x4b,0x28,0x80,0x66};
    if(memcmp(digest,expected,32)) return NO;
    if(profile->uiRequestAddress<0x02000000||profile->uiRequestAddress+profile->uiRequestSize>0x02040000
       ||profile->uiHostOffset+profile->uiHostSize>0x2000000) return NO;
    romUIOwner=rom;romUIProfile=multiRedProfile(rom); return YES;
}
+ (void)advanceROMFieldRecovery {
    if(!ownsROMUI()||!workRAM||!internalRAM) return;
    if(armed||inviteActive) return;
    if(word(internalRAM+0x30F0)!=0x08056535||word(internalRAM+0x30F4)!=0x080565B5
       ||(internalRAM[0x3529]&2)) return;
    // MP2K may stop a song while retaining its low active-track bits. A fade
    // cannot advance a stopped player, but the stock IsBGMStopped checks only
    // those track bits. Normalize this already-stopped status during an actual
    // native stop request; the ordinary music/warp tasks then finish themselves.
    // This repairs interrupted checkpoints too, without changing the cartridge
    // or forcing its map, palette, script, task, or player visibility state.
    const unsigned musicState=internalRAM[0xFC4];
    const uint32_t musicStatus=word(internalRAM+0x7304);
    if(musicState>=5&&musicState<=7&&(musicStatus&0x80000000u)&&(musicStatus&0xFFFF))
        put32(internalRAM+0x7304,musicStatus&0xFFFF0000u);

    // Shoulder inputs retain their native cartridge behavior in every mode.

}
+ (NSData *)romMultiplayerSnapshot {
    if(!ownsROMUI()||!workRAM) return [NSData data];
    const auto *p=workRAM+romUIProfile->uiRequestAddress-0x02000000;
    const uint32_t sequence=word(p+8);
    if(word(p)!=BOUND_SDK_UIREQUEST_MAGIC||half(p+4)!=BOUND_SDK_UIREQUEST_MAJOR
       ||half(p+6)!=BOUND_SDK_UIREQUEST_MINOR||BOUND_SDK_UNCOMMITTED_SEQUENCE(sequence)) return [NSData data];
    NSMutableData *copy=[NSMutableData dataWithBytes:p length:romUIProfile->uiRequestSize];
    if(!bound_sdk_same_committed_sequence(sequence,word(p+8))) return [NSData data];
    // Earlier cartridges advertised idle scripts as checkpoint-safe without
    // checking their asynchronous native message owner. Withhold that claim
    // in the host snapshot until the message and printer have both finished.
    if(!fieldTextIdle()) {
        auto *bytes=static_cast<uint8_t *>(copy.mutableBytes);
        put32(bytes+80,word(bytes+80)&~64u);
    }
    return copy;
}
+ (void)setROMMultiplayerHost:(NSData *)data {
    if(!ownsROMUI()||data.length!=romUIProfile->uiHostSize) return;
    const auto *source=static_cast<const uint8_t *>(data.bytes);
    const uint32_t sequence=word(source+8);
    if(word(source)!=BOUND_SDK_UIHOST_MAGIC||half(source+4)!=BOUND_SDK_UIHOST_MAJOR
       ||half(source+6)!=BOUND_SDK_UIHOST_MINOR||BOUND_SDK_UNCOMMITTED_SEQUENCE(sequence)
       ||word(source+24)>20||word(source+312)>180) return;
    auto *destination=rom+romUIProfile->uiHostOffset;
    bound_sdk_store_le32(destination+8,sequence-1);
    memcpy(destination,source,8);memcpy(destination+12,source+12,romUIProfile->uiHostSize-12);
    bound_sdk_store_le32(destination+8,sequence);
}
+ (uint64_t)worldMovementTimeline { return movementTimeline.load(std::memory_order_relaxed); }
+ (void)requestWorldMovementRevocation { movementRevocation.store(true,std::memory_order_relaxed); }
+ (BOOL)worldMovementPublicationInProgress {
    const auto *profile=multiRedProfile(rom);
    if(!rom||!workRAM||!profile||profile->presenceOutputSize!=256
       ||profile->presenceOutputAddress<0x02000000||profile->presenceOutputAddress>0x0203FF00)return NO;
    const auto *p=workRAM+profile->presenceOutputAddress-0x02000000;
    return word(p)==0x314F5742&&word(p+4)==1&&(word(p+8)&1);
}
+ (NSData *)worldMovementSnapshot {
    const auto *profile=multiRedProfile(rom);
    if(!rom||!workRAM||!profile||profile->presenceOutputSize!=256
       ||profile->presenceOutputAddress<0x02000000||profile->presenceOutputAddress>0x0203FF00)return [NSData data];
    const auto *p=workRAM+profile->presenceOutputAddress-0x02000000;
    const uint32_t sequence=word(p+8);
    if(word(p)!=0x314F5742||word(p+4)!=1||!sequence||(sequence&1))return [NSData data];
    NSData *copy=[NSData dataWithBytes:p length:256];
    return sequence==word(p+8)?copy:[NSData data];
}
+ (NSData *)worldMovementPublicationHeader {
    const auto *profile=multiRedProfile(rom);
    if(!rom||!workRAM||!profile||profile->presenceOutputSize!=256
       ||profile->presenceOutputAddress<0x02000000||profile->presenceOutputAddress>0x0203FF00)return [NSData data];
    const auto *p=workRAM+profile->presenceOutputAddress-0x02000000;
    const uint32_t sequence=word(p+8);
    if(word(p)!=0x314F5742||word(p+4)!=1||!(sequence&1))return [NSData data];
    // This deliberately excludes every actor/request field. The frame owner
    // may use progress only to wait, never to admit an uncommitted snapshot.
    NSData *copy=[NSData dataWithBytes:p length:20];
    return sequence==word(p+8)?copy:[NSData data];
}
+ (void)setWorldMovementHost:(NSData *)data {
    if(!data.length)movementDeadline.store(0,std::memory_order_relaxed);
    const auto *profile=multiRedProfile(rom);
    if(!rom||!profile||profile->presenceHostSize!=1024)return;
    auto *out=rom+profile->presenceHostOffset;
    if(!data.length){memset(out,0,1024);return;}
    if(data.length!=1024)return;
    const auto *p=static_cast<const uint8_t *>(data.bytes);const uint32_t sequence=word(p+8);
    if(word(p)!=0x31574C42||word(p+4)!=1||!sequence||(sequence&1))return;
    // Presence can be active before a Soul Link session claims a frame owner.
    // Install the same Bound-owned native boundary before accepting any lease.
    if(!installSoulFrameFence())return;
    movementRevocation.store(false,std::memory_order_relaxed);
    put32(out+8,sequence-1);memcpy(out,p,8);memcpy(out+12,p+12,1012);put32(out+8,sequence);
    movementDeadline.store(movementNow()+150000000,std::memory_order_relaxed);
}
+ (NSData *)nativeBattleLossSnapshot {
    const auto *profile=multiRedProfile(rom);
    if(!rom||!workRAM||!profile||!profile->linksHostSize||profile->uiRequestSize!=256
       ||profile->uiRequestAddress<0x02000000||profile->uiRequestAddress>0x0203FF00)return [NSData data];
    const auto *p=workRAM+profile->uiRequestAddress-0x02000000;
    const uint32_t sequence=word(p+8);
    if(word(p)!=BOUND_SDK_UIREQUEST_MAGIC||word(p+4)!=1||!sequence||(sequence&1)
       ||word(p+168)!=0x31534C42||word(p+172)!=1)return [NSData data];
    NSData *copy=[NSData dataWithBytes:p+168 length:44];
    return sequence==word(p+8)?copy:[NSData data];
}
+ (NSInteger)linksMenuPageOffset {
    // Presentation data belongs only to the exact Links-enabled cartridge.
    // Older profiles retain their own allocations and remain untouched.
    const auto *profile=multiRedProfile(rom);
    if(!rom||!workRAM||!profile||!profile->linksHostSize) return -1;
    const auto *request=workRAM+GameLinksRequestAddress-0x02000000;
    if(word(request)==0x51524C42&&request[14]==1&&word(request+4)<=4094&&!(word(request+4)%2))return word(request+4);
    // New cartridges need presentation data before their automatic loss view
    // opens. Old cartridges keep their existing explicit Links-menu handshake.
    return [self nativeBattleLossSnapshot].length==44?0:-1;
}
+ (void)setLinksMenuHost:(NSData *)data {
    const auto *profile=multiRedProfile(rom);
    if(!rom||!profile||!profile->linksHostSize)return;
    // Paused replacement boundaries must retire presentation authority too.
    // ROM data ports deliberately survive native save-state restoration.
    if(!data.length) {memset(rom+profile->linksHostOffset,0,profile->linksHostSize);return;}
    if([self linksMenuPageOffset]<0||!profile||data.length!=profile->linksHostSize) return;
    const auto *source=static_cast<const uint8_t *>(data.bytes);
    const uint32_t sequence=word(source+8),total=word(source+12),offset=word(source+16),count=word(source+20);
    if(word(source)!=0x314E4C42||half(source+4)!=1||half(source+6)!=0||!sequence||(sequence&1)
       ||total>4096||offset!=unsigned([self linksMenuPageOffset])||count>2||count>total
       ||(count&&offset+count>total)||word(source+24)>1||word(source+28)) return;
    auto *destination=rom+profile->linksHostOffset;
    put32(destination+8,sequence-1);memcpy(destination,source,8);memcpy(destination+12,source+12,profile->linksHostSize-12);put32(destination+8,sequence);
}
// Attaches to the game's ABI; never installs/restores gameplay instructions.
+ (BOOL)installSharedWorld {
    if(worldOwnsROM()) return YES;
    const auto *profile=multiRedProfile(rom);
    if(!rom||!workRAM||!internalRAM||armed||inviteActive||!profile) return NO;
    uint8_t digest[32];soulOriginalHash(digest);
    const uint8_t expected[32]={0x68,0x92,0x99,0x66,0x4a,0x95,0x4c,0x12,0xda,0xd6,0x6e,0x03,0xc2,0xd1,0x84,0x46,
        0xb3,0x48,0xcb,0x31,0xbd,0x98,0xb3,0x95,0xc8,0x7b,0x9b,0x51,0x4b,0x28,0x80,0x66};
    if(memcmp(digest,expected,32)) return NO;
    if(profile->snapshotAddress<0x02000000||profile->snapshotAddress+profile->snapshotRegionSize>0x02040000) return NO;
    const auto *p=workRAM+profile->snapshotAddress-0x02000000;
    if(word(p)!=0x31434D52||half(p+4)!=profile->major||half(p+6)>profile->minor||word(p+8)!=profile->snapshotRegionSize) return NO;
    worldROM=rom;worldProfile=multiRedProfile(rom);
    if(![self sharedWorldSnapshot][@"checkpoints"]) { worldROM=nullptr; return NO; }worldSequence=0;[[NSUUID UUID] getUUIDBytes:worldSession];
    worldWritePolicy(false,[NSData data],0,0,[NSData data],false);
    return YES;
}
+ (NSDictionary<NSString *,id> *)sharedWorldSnapshot {
    if(!worldOwnsROM()||!workRAM) return @{};
    const auto *control=workRAM+worldProfile->snapshotAddress-0x02000000;
    if(word(control)!=0x31434D52||half(control+4)!=worldProfile->major||half(control+6)>worldProfile->minor
       ||word(control+8)!=worldProfile->snapshotRegionSize||word(control+16)!=worldProfile->snapshotSize||word(control+12)>1) return @{};
    const uint32_t index=word(control+12);
    const auto *p=control+64+index*worldProfile->snapshotSize;
    const uint32_t sequence=word(p+12);
    if(!sequence||(sequence&1)||word(p)!=0x31534D52||half(p+4)!=worldProfile->major||half(p+6)>worldProfile->minor
       ||word(p+8)!=worldProfile->snapshotSize||word(p+20)!=1||p[24]>=43||p[26]>16
       ||memcmp(p+32,worldProfile->ruleset,16)||word(p+48)!=1||word(p+52)!=1||word(p+56)!=worldProfile->layout) return @{};
    NSData *checkpoints=[NSData dataWithBytes:p+64 length:800];NSData *boulders=[NSData dataWithBytes:p+864 length:p[26]*6];
    if(!bound_sdk_same_committed_sequence(sequence,word(p+12))||word(control+12)!=index) return @{};
    return @{@"checkpoints":checkpoints,@"group":@(p[24]),@"number":@(p[25]),@"boulders":boulders,@"sequence":@(sequence),@"frame":@(word(p+16))};
}
+ (void)setSharedWorldPeer:(NSData *)checkpoints group:(NSUInteger)group number:(NSUInteger)number boulders:(NSData *)boulders fresh:(BOOL)fresh {
    worldWritePolicy(true,checkpoints,unsigned(group),unsigned(number),boulders,fresh);
}
+ (void)advanceSharedWorld {
    if(worldOwnsROM()) { auto *p=rom+worldProfile->hostOffset+64;uint32_t lease=word(p+8);if(lease) put32(p+8,lease-1); }
}
+ (void)closeSharedWorld {
    // The permanent game module and serialized guest return addresses stay valid.
    worldWritePolicy(false,[NSData data],0,0,[NSData data],false);worldROM=nullptr;
}
+ (void)resetFriendDialogueOwner {
    // A temporary detach may rebind the same loaded cartridge. Let its native
    // task close normally; a genuinely new ROM has an untouched FF tail.
    const uint8_t signature[]={0x69,0x67,0x80,0xFD,0xFF,0x09};
    if(inviteOwnsROM()&&memcmp(rom+InviteStart,signature,sizeof(signature))==0) {
        inviteCancelling=true; return;
    }
    // Never write through a stale ROM pointer from an unloaded cartridge.
    if(inviteBHeld) [[GBAEmulatorBridge sharedBridge] deactivateInput:2 playerIndex:0];
    inviteROM=nullptr; inviteActive=inviteBHeld=inviteCancelling=false; inviteResult=-1;
}
+ (BOOL)friendDialogueReady {
    if(armed||inviteActive||berryActive||!fieldInterruptionReady()) return NO;
    if(ownsROMUI()) {
        const auto *state=workRAM+GameUIRequestAddress-0x02000000;
        if(word(state)==0x31525552&&(word(state+76)||(word(state+80)&(2|4)))) return NO;
    }
    return YES;
}
+ (BOOL)beginFriendDialogue:(NSUInteger)mode text:(NSString *)text {
    if(mode>2||![self friendDialogueReady]) return NO;
    uint8_t digest[32]; soulOriginalHash(digest);
    const uint8_t expected[32]={0x68,0x92,0x99,0x66,0x4a,0x95,0x4c,0x12,0xda,0xd6,0x6e,0x03,0xc2,0xd1,0x84,0x46,
        0xb3,0x48,0xcb,0x31,0xbd,0x98,0xb3,0x95,0xc8,0x7b,0x9b,0x51,0x4b,0x28,0x80,0x66};
    if(memcmp(digest,expected,32)!=0) return NO;
    for(size_t i=0;i<InviteSize;i++) if(rom[InviteStart+i]!=0xFF) return NO;
    inviteROM=rom; inviteMode=unsigned(mode); inviteFrames=0; inviteResult=-1;
    inviteActive=true; inviteCancelling=inviteBHeld=false;
    memcpy(inviteScratchOriginal,internalRAM+InviteResult,2); put16(internalRAM+InviteResult,0xFFFF);
    inviteText(InviteStart+0x80,text);
    if(mode==0) {
        // Temporarily lend native multichoice slot zero our three labels. No
        // game script can run concurrently; restore it before native link entry.
        memcpy(inviteMenuOriginal,rom+InviteMenuSlot,8);
        NSString *labels[]={@"Battle",@"Trade",@"Cancel"};
        for(unsigned i=0;i<3;i++) {
            inviteText(InviteStart+0x140+i*16,labels[i]);
            put32(rom+InviteStart+0x120+i*8,0x08000000+InviteStart+0x140+i*16);
            put32(rom+InviteStart+0x124+i*8,0);
        }
        put32(rom+InviteMenuSlot,0x08000000+InviteStart+0x120);
        put32(rom+InviteMenuSlot+4,3);
    }
    uint8_t script[64]={0x69,0x67,0,0,0,0,0x66};
    put32(script+2,0x08000000+InviteStart+0x80);
    size_t n=7;
    if(mode==0) { script[n++]=0x6F; script[n++]=20; script[n++]=0; script[n++]=0; script[n++]=0; }
    else if(mode==1) { script[n++]=0x6E; script[n++]=0; script[n++]=0; }
    else { script[n++]=0x6D; }
    // Latch before releaseall/end: ordinary field tasks reuse VAR_RESULT as
    // soon as the script releases control. This two-byte link-queue scratch is
    // unused while !armed and is restored before any native link preparation.
    for(unsigned i=0;i<2;i++) {
        script[n++]=0x15; // native copybyte destination, source
        put32(script+n,0x03000000+InviteResult+i); n+=4;
        put32(script+n,0x020370D0+i); n+=4;
    }
    script[n++]=0x6B; script[n++]=0x02;
    memcpy(rom+InviteStart,script,n);
    memset(internalRAM+0xEB0,0,0x74); internalRAM[0xEB1]=1;
    put32(internalRAM+0xEB8,0x08000000+InviteStart);
    put32(internalRAM+0xF0C,0x0815F9B4); put32(internalRAM+0xF10,0x0815FD08);
    internalRAM[0xEA8]=0; internalRAM[0xF9C]=1;
    internalRAM[0xF9D]=0; internalRAM[0xF9E]=0; internalRAM[0xFA0]=0;
    return YES;
}
+ (void)cancelFriendDialogue { if(inviteOwnsROM()) inviteCancelling=true; }
+ (NSDictionary<NSString *,id> *)advanceFriendDialogue {
    if(inviteActive&&inviteROM!=rom) { inviteActive=inviteBHeld=false; inviteResult=-2; }
    if(inviteOwnsROM()) {
        if(overworld()) {
            inviteResult=inviteCancelling?-2:int(half(internalRAM+InviteResult));
            restoreInvite();
        } else if(inviteCancelling) {
            // Dismiss through the game's ordinary B handling, including native
            // YES/NO task/window cleanup. Never synthesize an acceptance.
            ++inviteFrames;
            bool held=inviteFrames%12<2;
            if(held!=inviteBHeld) {
                if(held) [[GBAEmulatorBridge sharedBridge] activateInput:2 value:1 playerIndex:0];
                else [[GBAEmulatorBridge sharedBridge] deactivateInput:2 playerIndex:0];
                inviteBHeld=held;
            }
        }
    }
    return @{@"active":@(inviteActive),@"ready":@([self friendDialogueReady]),
        @"menuReady":@(inviteMenuReady()),@"result":@(inviteResult),
        @"mode":@(inviteActive?int(inviteMode):-1),@"cursor":@(inviteActive&&workRAM?int(workRAM[0x3ADE6]):-1)};
}
+ (NSData *)followerBerryTarget:(uint64_t)identity {
    if(!workRAM||!internalRAM||!fieldInterruptionReady()) return [NSData data];
    const auto *p=workRAM+0x2000;
    if(word(p)!=0x314F5742||word(p+4)!=1||(word(p+8)&1)||(word(p+96)&3)!=3||word(p+104)>=workRAM[0x24029]) return [NSData data];
    const auto *mon=workRAM+0x24284+word(p+104)*100;
    if(!berryMon(mon)||((uint64_t(word(mon))<<32)|word(mon+4))!=identity||word(mon)!=word(p+108)||word(mon+4)!=word(p+112)) return [NSData data];
    return [NSData dataWithBytes:mon length:100];
}
+ (BOOL)beginFollowerBerry:(NSData *)target {
    if(target.length!=100||![self friendDialogueReady]||!berryMon((const uint8_t *)target.bytes)) return NO;
    uint8_t digest[32];soulOriginalHash(digest);
    const uint8_t expected[32]={0x68,0x92,0x99,0x66,0x4a,0x95,0x4c,0x12,0xda,0xd6,0x6e,0x03,0xc2,0xd1,0x84,0x46,
        0xb3,0x48,0xcb,0x31,0xbd,0x98,0xb3,0x95,0xc8,0x7b,0x9b,0x51,0x4b,0x28,0x80,0x66};
    if(memcmp(digest,expected,32)||word(rom+0x10996FC)!=0x02024029||word(rom+0x1099700)!=0x02024284
       ||half(rom+0x10996AC)!=0xD11D||word(rom+0x1049C81)!=0x090995D5) return NO;
    for(size_t i=0;i<BerrySize;i++) if(rom[BerryScript+i]!=0xFF) return NO;
    berryROM=rom;berryActive=true;berryCancelling=berryBHeld=false;berryFrames=0;berryConsumed=false;berryAfter=nil;
    memcpy(berryEnemy,workRAM+0x2402C,100);memcpy(berryString,workRAM+0x21CE4,20);
    berryCountOriginal=internalRAM[BerryCount];internalRAM[BerryCount]=1;
    memcpy(berryCountPointer,rom+0x10996FC,4);memcpy(berryPartyPointer,rom+0x1099700,4);
    memcpy(berrySelection,rom+0x10996AC,2);memcpy(berryAnimation,rom+0x1049C81,4);
    berryBagBefore=[NSData dataWithBytes:workRAM+0x3BB20 length:0xC00];
    memcpy(workRAM+0x2402C,target.bytes,100);
    memset(workRAM+0x21CE4,0xFF,20);memcpy(workRAM+0x21CE4,(const uint8_t *)target.bytes+8,10);
    // The native selection loop still checks living/non-Egg eligibility. Its
    // single explicit target replaces the comparison to the local follower's
    // graphics species; its actual friendship calculation is unchanged.
    put32(rom+0x10996FC,0x03000000+BerryCount);put32(rom+0x1099700,0x0202402C);
    put16(rom+0x10996AC,0x46C0);
    put16(rom+BerryScript+0x80,0x4770); // Optional local object animation: bx lr.
    put32(rom+0x1049C81,0x08000000+BerryScript+0x81);
    rom[BerryScript]=0x69;rom[BerryScript+1]=0x05;put32(rom+BerryScript+2,0x09049C30);
    memset(internalRAM+0xEB0,0,0x74);internalRAM[0xEB1]=1;
    put32(internalRAM+0xEB8,0x08000000+BerryScript);put32(internalRAM+0xF0C,0x0815F9B4);put32(internalRAM+0xF10,0x0815FD08);
    internalRAM[0xEA8]=0;internalRAM[0xF9C]=1;internalRAM[0xF9D]=internalRAM[0xF9E]=internalRAM[0xFA0]=0;
    return YES;
}
+ (NSDictionary<NSString *,id> *)advanceFollowerBerry {
    if(berryActive&&berryROM!=rom) {berryActive=false;berryAfter=nil;berryConsumed=false;}
    if(berryOwnsROM()) {
        if(overworld()) {
            berryAfter=[NSData dataWithBytes:workRAM+0x2402C length:100];
            berryConsumed=![berryBagBefore isEqualToData:[NSData dataWithBytes:workRAM+0x3BB20 length:0xC00]];
            berryRestore();
        } else if(berryCancelling) {
            bool held=++berryFrames%12<2;
            if(held!=berryBHeld) {
                if(held) [[GBAEmulatorBridge sharedBridge] activateInput:2 value:1 playerIndex:0];
                else [[GBAEmulatorBridge sharedBridge] deactivateInput:2 playerIndex:0];
                berryBHeld=held;
            }
        }
    }
    return @{ @"active":@(berryActive),@"finished":@(berryAfter!=nil),@"consumed":@(berryConsumed),@"pokemon":berryAfter?:[NSData data] };
}
+ (void)cancelFollowerBerry {if(berryOwnsROM()) berryCancelling=true;}
+ (void)closeFollowerBerry {berryRestore();berryAfter=nil;berryBagBefore=nil;berryConsumed=false;}
+ (BOOL)commitFollowerBerry:(NSData *)after replacing:(NSData *)before {
    if(after.length!=100||before.length!=100||!workRAM||!fieldInterruptionReady()) return NO;
    const auto *a=(const uint8_t *)after.bytes,*b=(const uint8_t *)before.bytes;
    if(!berryMon(a)||!berryMon(b)||memcmp(a,b,8)||half(a+32)!=half(b+32)) return NO;
    // Authenticate the result's entire mutation surface. The native routine at
    // 0x09099620 changes only friendship (MON_DATA_FRIENDSHIP, byte 41), by
    // 70/60/30 at its original 100/200 thresholds, capped at 255. This checks
    // the cartridge-produced result; it does not implement a second effect.
    const unsigned friendship=b[41],gain=friendship<100?70:friendship<200?60:30;
    if(a[41]!=std::min(255u,friendship+gain)||memcmp(a,b,41)||memcmp(a+42,b+42,58)) return NO;
    for(unsigned slot=0;slot<workRAM[0x24029]&&slot<6;slot++) {
        auto *mon=workRAM+0x24284+slot*100;
        if(!memcmp(mon,b,100)) {memcpy(mon,a,100);return YES;}
    }
    return NO;
}
+ (BOOL)verifyBattleReady {
    verifiedROM=nullptr;
    if(armed||berryActive||!fieldInterruptionReady()||workRAM[0x24029]==0||workRAM[0x24029]>6) return NO;
    const uint8_t expected[32]={0x68,0x92,0x99,0x66,0x4a,0x95,0x4c,0x12,0xda,0xd6,0x6e,0x03,0xc2,0xd1,0x84,0x46,
        0xb3,0x48,0xcb,0x31,0xbd,0x98,0xb3,0x95,0xc8,0x7b,0x9b,0x51,0x4b,0x28,0x80,0x66};
    uint8_t digest[CC_SHA256_DIGEST_LENGTH]; soulOriginalHash(digest);
    if(memcmp(digest,expected,32)!=0) return NO;
    for(size_t i=0;i<RegionSize;i++) if(rom[RegionOffset+i]!=0xFF) return NO;
    for(size_t i=0;i<sizeof(BoundBattleDecisionCode);i++) if(rom[DecisionCodeOffset+i]!=0xFF) return NO;
    if(word(internalRAM+0xF0C)!=0x0815F9B4||word(internalRAM+0xF10)!=0x0815FD08) return NO;
    verifiedROM=rom; failed=false; return YES;
}
+ (BOOL)verifyBattleEntryReady {
    if(![self verifyBattleReady]) return NO;
    if(ownsROMUI()) {
        const auto *host=rom+GameUIHostOffset;
        const auto *state=workRAM+GameUIRequestAddress-0x02000000;
        // Host save/recovery flags govern entry, not proof that rollback
        // restored the world. They intentionally survive emulator snapshots.
        if((word(host)==0x31495552 && (word(host+12)&(32|256|512)))
           || (word(state)==0x31525552 && (word(state+80)&4))) return NO;
    }
    return YES;
}
+ (BOOL)prepareBattleForPlayer:(NSUInteger)player {
    if(armed||verifiedROM!=rom||!fieldInterruptionReady()||player>1) return NO;
    role=unsigned(player); tradeMode=false; armed=true; return YES;
}
+ (BOOL)prepareTradeForPlayer:(NSUInteger)player {
    if (![self prepareBattleForPlayer:player]) return NO;
    tradeMode=true; tradeOpened=tradeScene=false; tradeCount=0;
    return YES;
}
+ (BOOL)installBattleForPlayer:(NSUInteger)player {
    if(!armed||installed||verifiedROM!=rom||!fieldInterruptionReady()||player!=role) { failed=true; return NO; }
    if(!tradeMode&&!prepareFriendlyParty()) { failed=true; return NO; }
    if(!writeNativeROM()) { failed=true; return NO; }
    // Exact bindings verified against the profile's ScriptContext_SetupScript.
    memset(internalRAM + 0xEB0,0,0x74);
    internalRAM[0xEB1] = 1;
    put32(internalRAM + 0xEB8,ScriptAddress);
    put32(internalRAM + 0xF0C,0x0815F9B4); put32(internalRAM + 0xF10,0x0815FD08);
    internalRAM[0xEA8]=0; internalRAM[0xF9C]=1;
    internalRAM[0xF9D]=0; internalRAM[0xF9E]=0; internalRAM[0xFA0]=0;
    memset(internalRAM+Mailbox,0,1176); networkRead=0;internalRAM[0x402F]=0;
    put32(internalRAM+Mailbox,MailboxMagic);
    if(!tradeMode) {
        auto *state=reinterpret_cast<BoundDecisionState *>(internalRAM+DecisionStateOffset);
        memset(state,0,sizeof(*state));state->magic=BOUND_DECISION_MAGIC;state->seed=decisionSeed;
    }
    preparationFrames=0; installed=true; return YES;
}
+ (void)configureDecisionsWithSeed:(NSUInteger)seed {
    if(armed&&!installed&&!tradeMode&&!cooperativeCable) decisionSeed=uint32_t(seed ? seed:1);
}
+ (NSData *)takeOutgoingDecisions {
    auto *state=decisionState();if(!state) return [NSData data];
    const unsigned count=uint16_t(state->outWrite-state->outRead);
    if(state->error||count>BOUND_DECISION_CAPACITY) { failed=true;return [NSData data]; }
    NSMutableData *records=[NSMutableData dataWithCapacity:count*sizeof(BoundDecisionRecord)];
    while(state->outRead!=state->outWrite) {
        [records appendBytes:&state->outgoing[state->outRead&(BOUND_DECISION_CAPACITY-1)] length:sizeof(BoundDecisionRecord)];
        state->outRead++;
    }
    return records;
}
+ (NSUInteger)receiveDecisions:(NSData *)data {
    auto *state=decisionState();if(!state) return 0;
    if(data.length%sizeof(BoundDecisionRecord)) { failed=true;return 0; }
    unsigned count=uint16_t(state->inWrite-state->inRead),consumed=0;
    if(state->error||count>BOUND_DECISION_CAPACITY) { failed=true;return 0; }
    while(consumed<data.length&&count<BOUND_DECISION_CAPACITY) {
        BoundDecisionRecord record;
        memcpy(&record,static_cast<const uint8_t *>(data.bytes)+consumed,sizeof(record));
        if(!record.ordinal||record.battler!=(role^1)||record.request<18||record.request>22||
           !record.size||record.size>16||record.reserved) { failed=true;return consumed; }
        state->incoming[state->inWrite&(BOUND_DECISION_CAPACITY-1)]=record;
        state->inWrite++;count++;consumed+=sizeof(record);
    }
    return consumed;
}
+ (NSData *)captureNativeSession { return [self captureSessionForCooperative:NO]; }
+ (NSData *)captureCooperativeSession { return [self captureSessionForCooperative:YES]; }
+ (NSData *)captureSessionForCooperative:(BOOL)cooperative {
    if(!armed||failed||cooperativeCable!=bool(cooperative)||!rom||!workRAM||!internalRAM
       ||(cooperative ? cooperativeROM!=rom||!installed : verifiedROM!=rom)) return [NSData data];
    if(installed) {
        if(!mailboxReady()||patchedROM!=rom||memcmp(rom+RegionOffset,BoundBattleEntryCode,sizeof(BoundBattleEntryCode))) return [NSData data];
        for(size_t i=0;i<sizeof(hooks)/sizeof(hooks[0]);i++)
            if(usesHook(i)&&memcmp(rom+hooks[i].offset,hooks[i].thunk,8)) return [NSData data];
        if(!tradeMode&&!cooperativeCable) {
            if(!decisionState()||memcmp(rom+DecisionCodeOffset,BoundBattleDecisionCode,sizeof(BoundBattleDecisionCode))) return [NSData data];
            for(const auto &hook:decisionHooks) if(memcmp(rom+hook.offset,hook.thunk,8)) return [NSData data];
        }
    }
    NSDictionary *value=@{@"version":@1,@"scriptVersion":@2,@"code":[nativeCodeIdentity() base64EncodedStringWithOptions:0],
        @"armed":@(armed),@"installed":@(installed),@"cooperative":@(cooperativeCable),@"role":@(role),@"tradeMode":@(tradeMode),
        @"tradeOpened":@(tradeOpened),@"tradeScene":@(tradeScene),@"tradeCount":@(tradeCount),
        @"networkRead":@(networkRead),@"preparationFrames":@(preparationFrames)};
    return [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:nil] ?: [NSData data];
}
+ (BOOL)restoreNativeSession:(NSData *)data { return [self restoreSession:data cooperative:NO]; }
+ (BOOL)restoreCooperativeSession:(NSData *)data { return [self restoreSession:data cooperative:YES]; }
+ (BOOL)restoreSession:(NSData *)data cooperative:(BOOL)cooperative {
    if(armed||installed||cooperativeCable||!rom||!workRAM||!internalRAM||data.length==0||data.length>4096) return NO;
    id raw=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if(![raw isKindOfClass:NSDictionary.class]) return NO;
    NSDictionary *value=raw;
    for(NSString *key in @[@"version",@"scriptVersion",@"armed",@"installed",@"cooperative",@"role",@"tradeMode",@"tradeOpened",@"tradeScene",@"tradeCount",@"networkRead",@"preparationFrames"])
        if(![value[key] isKindOfClass:NSNumber.class]||[value[key] doubleValue]!=[value[key] unsignedLongLongValue]) return NO;
    for(NSString *key in @[@"armed",@"installed",@"cooperative",@"tradeMode",@"tradeOpened",@"tradeScene"])
        if([value[key] unsignedLongLongValue]>1) return NO;
    if([value[@"version"] unsignedLongLongValue]!=1||[value[@"scriptVersion"] unsignedLongLongValue]!=2||![value[@"armed"] boolValue]
       ||[value[@"cooperative"] boolValue]!=cooperative
       ||[value[@"role"] unsignedLongLongValue]>1||[value[@"networkRead"] unsignedLongLongValue]>UINT16_MAX
       ||[value[@"preparationFrames"] unsignedLongLongValue]>UINT32_MAX||[value[@"tradeCount"] unsignedLongLongValue]>UINT32_MAX
       ||![value[@"code"] isKindOfClass:NSString.class]||![value[@"code"] isEqualToString:[nativeCodeIdentity() base64EncodedStringWithOptions:0]]) return NO;
    const bool resumedInstalled=[value[@"installed"] boolValue],resumedTrade=[value[@"tradeMode"] boolValue];
    if(cooperative&&(!resumedInstalled||resumedTrade)) return NO;
    if(!resumedTrade&&([value[@"tradeOpened"] boolValue]||[value[@"tradeScene"] boolValue]||[value[@"tradeCount"] unsignedIntValue])) return NO;
    if(resumedInstalled) {
        if(word(internalRAM+Mailbox)!=MailboxMagic||half(internalRAM+Mailbox+12)
           ||uint16_t(half(internalRAM+Mailbox+6)-half(internalRAM+Mailbox+4))>32
           ||uint16_t(half(internalRAM+Mailbox+10)-half(internalRAM+Mailbox+8))>32
           ||uint16_t([value[@"networkRead"] unsignedIntValue]-half(internalRAM+Mailbox+4))>
             uint16_t(half(internalRAM+Mailbox+6)-half(internalRAM+Mailbox+4))) return NO;
        if(!resumedTrade&&!cooperative) {
            const auto *state=reinterpret_cast<const BoundDecisionState *>(internalRAM+DecisionStateOffset);
            if(state->magic!=BOUND_DECISION_MAGIC||state->error||state->inSimulation||
               uint16_t(state->outWrite-state->outRead)>BOUND_DECISION_CAPACITY||
               uint16_t(state->inWrite-state->inRead)>BOUND_DECISION_CAPACITY) return NO;
        }
    } else if(!overworld()) return NO;
    if(!nativeProfileVerified()) return NO;
    for(size_t i=0;i<RegionSize;i++) if(rom[RegionOffset+i]!=0xFF) return NO;
    for(size_t i=0;i<sizeof(BoundBattleDecisionCode);i++) if(rom[DecisionCodeOffset+i]!=0xFF) return NO;
    if(cooperative&&![self installCooperativeDoubles]) return NO;
    role=[value[@"role"] unsignedIntValue];tradeMode=resumedTrade;cooperativeCable=cooperative;
    if(resumedInstalled&&!writeNativeROM()) return NO;
    verifiedROM=rom;armed=true;installed=resumedInstalled;failed=false;syntheticHeld=false;
    tradeOpened=[value[@"tradeOpened"] boolValue];tradeScene=[value[@"tradeScene"] boolValue];
    tradeCount=[value[@"tradeCount"] unsignedIntValue];networkRead=[value[@"networkRead"] unsignedIntValue];
    preparationFrames=[value[@"preparationFrames"] unsignedIntValue];
    [[GBAEmulatorBridge sharedBridge] deactivateInput:1 playerIndex:0];
    return YES;
}
+ (NSData *)takeOutgoingCommands {
    if(!mailboxReady()) return [NSData data];
    auto *m=internalRAM+Mailbox;
    unsigned read=networkRead,write=half(m+6),count=uint16_t(write-read);
    if(count>32||half(m+12)) { failed=true; return [NSData data]; }
    NSMutableData *bytes=[NSMutableData dataWithCapacity:count*16];
    for(unsigned i=0;i<count;i++) {
        [bytes appendBytes:m+1048+((read+i)&31)*2 length:2];
        uint8_t sequence[2]; put16(sequence,read+i+1); [bytes appendBytes:sequence length:2];
        [bytes appendBytes:m+24+((read+i)&31)*16 length:16];
    }
    networkRead=uint16_t(write); return bytes;
}
+ (NSData *)peerAcknowledgement {
    if(!mailboxReady()||!half(internalRAM+Mailbox+22)) return [NSData data];
    uint8_t bytes[4]; put16(bytes,half(internalRAM+Mailbox+22)); put16(bytes+2,half(internalRAM+Mailbox+20));
    return [NSData dataWithBytes:bytes length:4];
}
+ (void)acknowledgeGeneration:(NSUInteger)generation sequence:(NSUInteger)sequence {
    if(!mailboxReady()) return;
    auto *m=internalRAM+Mailbox;
    unsigned read=half(m+4),available=uint16_t(networkRead-read),delta=uint16_t(sequence-read);
    if(generation==half(m+16)&&available<=32&&delta<=available) put16(m+4,unsigned(sequence));
}
+ (void)requestPeerDisconnect { if(installed&&internalRAM) internalRAM[0x402E]=1; }
+ (NSUInteger)connectionGeneration { return mailboxReady() ? half(internalRAM+Mailbox+16):0; }
+ (void)setPeerGeneration:(NSUInteger)generation { if(mailboxReady()) put16(internalRAM+Mailbox+18,unsigned(generation)); }
+ (NSUInteger)receiveCommands:(NSData *)data {
    if(!mailboxReady()) return 0;
    if(data.length%20) { failed=true; return 0; }
    auto *m=internalRAM+Mailbox;
    unsigned read=half(m+8),write=half(m+10),count=uint16_t(write-read),generation=half(m+16);
    if(count>32||half(m+12)) { failed=true; return 0; }
    unsigned consumed=0;
    auto *source=static_cast<const uint8_t *>(data.bytes);
    while(consumed<data.length && count<32) {
        unsigned incoming=half(source+consumed);
        if(incoming>generation) break; // retain future connection commands on host
        if(incoming==generation) {
            memcpy(m+536+(write&31)*16,source+consumed+4,16);
            put16(m+1112+(write&31)*2,half(source+consumed+2)); write++; count++;
        }
        consumed+=20; // stale native connections cannot reach ProcessRecvCmds
    }
    put16(m+10,write); return consumed;
}
+ (NSArray<NSNumber *> *)playerHP { return workRAM ? partyHP(0x24284,workRAM[0x24029]) : @[]; }
+ (BOOL)isInBattle { return internalRAM&&(internalRAM[0x3529]&2); }
+ (NSDictionary<NSString *,id> *)advanceAndObserve {
    if(!rom||!workRAM||!internalRAM) return @{@"error":@YES};
    const uint32_t callback=word(internalRAM+0x30F4);
    if(installed&&!failed&&(callback==0x0800ACD5||callback==0x0800AF2D)) {
        NSLog(@"Bound native link error: status=%08x receiveQueue=%u sendQueue=%u",word(workRAM+0x22854),unsigned(workRAM[0x22858]),unsigned(workRAM[0x22859])); failed=true;
    }
    if(mailboxReady()&&half(internalRAM+Mailbox+12)) failed=true;
    const auto *decisions=decisionState();
    if(decisions&&decisions->error) failed=true;
    if(installed&&ioMem) put16(ioMem+0x128,0x2008|(role<<4)|(role?4:0));
    const bool battle=(internalRAM[0x3529]&2)!=0;
    if(installed&&tradeMode) {
        if(callback==0x0804C729 || callback==0x0804C719) {
            if(tradeScene) {
                tradeCount++;
            }
            tradeScene=false; tradeOpened=true;
        }
        if(tradeOpened && callback==0x08053E8D) tradeScene=true;
    }
    // Before an offer, native initialization/root party selection cannot have
    // exchanged a mon. Once an exchange starts or completes, never authorize
    // a battle-style rollback that could duplicate or discard a traded mon.
    bool tradeUnchanged=false;
    if(installed&&tradeMode&&tradeOpened&&!tradeScene&&!tradeCount) {
        tradeUnchanged=callback==0x0804C729||callback==0x0804C719;
        if(callback==0x0804D639) {
            const uint32_t menu=word(workRAM+0x39DA8);
            if(menu>=0x02000000&&menu<=0x02040000-128) tradeUnchanged=workRAM[menu-0x02000000+0x6F]==0;
        }
    }
    const bool returned=installed&&(callback==BoundBattleIdleAddress || (tradeMode&&tradeOpened&&overworld()));
    // Battle setup retains its verified linkup tap. Trade setup and all native
    // trade confirmations are strictly user-driven.
    if(installed&&!cooperativeCable&&!tradeMode&&!battle&&!returned&&!failed) {
        ++preparationFrames;
        if(preparationFrames%12==1) { [[GBAEmulatorBridge sharedBridge] activateInput:1 value:1 playerIndex:0]; syntheticHeld=true; }
        else if(preparationFrames%12==3) { [[GBAEmulatorBridge sharedBridge] deactivateInput:1 playerIndex:0]; syntheticHeld=false; }
    } else if(installed&&syntheticHeld) { [[GBAEmulatorBridge sharedBridge] deactivateInput:1 playerIndex:0]; syntheticHeld=false; }
    return @{@"error":@(failed),@"connected":@(armed),@"battle":@(battle),@"returned":@(returned),
        @"outcome":@(workRAM[0x23E8A]),@"flags":@(word(workRAM+0x22B4C)),@"callback":@(callback),
        @"scriptStatus":@(internalRAM[0xEA8]),@"scriptResult":@(half(workRAM+0x370D0)),
        @"playerHP":partyHP(0x24284,workRAM[0x24029]),@"enemyHP":partyHP(0x2402C,6),
        @"pendingCommands":@(mailboxReady()?uint16_t(half(internalRAM+Mailbox+6)-half(internalRAM+Mailbox+4)):0),
        @"runRequested":@(installed&&!tradeMode&&!cooperativeCable&&internalRAM[0x402F]==3),
        @"decisionError":@(decisions?decisions->error:0),@"decisionsSent":@(decisions?decisions->sentOrdinal:0),
        @"decisionsReceived":@(decisions?decisions->receivedOrdinal:0),@"decisionFrames":@(decisions?decisions->frames:0),
        @"terminalFingerprint":@(decisions?decisions->terminalFingerprint:0),
        @"tradeOpened":@(tradeOpened),@"tradeCount":@(tradeCount),@"tradeUnchanged":@(tradeUnchanged)};
}
+ (void)close {
    if(armed||installed||syntheticHeld) [[GBAEmulatorBridge sharedBridge] deactivateInput:1 playerIndex:0];
    if(rom&&rom==patchedROM&&memcmp(rom+RegionOffset,BoundBattleEntryCode,sizeof(BoundBattleEntryCode))==0) {
        bool allOurs=true;
        for(size_t index=0;index<sizeof(hooks)/sizeof(hooks[0]);index++)
            if(usesHook(index)&&memcmp(rom+hooks[index].offset,hooks[index].thunk,8)!=0) allOurs=false;
        if(!tradeMode&&!cooperativeCable) {
            if(memcmp(rom+DecisionCodeOffset,BoundBattleDecisionCode,sizeof(BoundBattleDecisionCode))) allOurs=false;
            for(const auto &hook:decisionHooks) if(memcmp(rom+hook.offset,hook.thunk,8)) allOurs=false;
        }
        if(allOurs) {
            for(size_t index=0;index<sizeof(hooks)/sizeof(hooks[0]);index++)
                if(usesHook(index)) memcpy(rom+hooks[index].offset,hooks[index].original,8);
            memset(rom+RegionOffset,0xFF,RegionSize);
            if(!tradeMode&&!cooperativeCable) {
                for(const auto &hook:decisionHooks) memcpy(rom+hook.offset,hook.original,8);
                memset(rom+DecisionCodeOffset,0xFF,sizeof(BoundBattleDecisionCode));
            }
        }
    }
    armed=installed=failed=syntheticHeld=tradeMode=tradeOpened=tradeScene=cooperativeCable=false;
    tradeCount=0; patchedROM=verifiedROM=nullptr;
}

+ (BOOL)installSoulLink {
    if(soulHooked()) return YES;
    if(armed || !rom || !workRAM || !internalRAM) return NO;
    uint8_t digest[32]; soulOriginalHash(digest);
    const uint8_t expected[32]={0x68,0x92,0x99,0x66,0x4a,0x95,0x4c,0x12,0xda,0xd6,0x6e,0x03,0xc2,0xd1,0x84,0x46,
        0xb3,0x48,0xcb,0x31,0xbd,0x98,0xb3,0x95,0xc8,0x7b,0x9b,0x51,0x4b,0x28,0x80,0x66};
    if(memcmp(digest,expected,32)!=0) return NO;
    if(!soulResident()) for(size_t i=SoulStart;i<SoulEnd;i++) if(rom[i]!=0xFF) return NO;
    const uint8_t expectedGive[8]={0x70,0xB5,4,0,0x1C,0xF0,0xFA,0xFA};
    const uint8_t expectedCatch[8]={0x10,0xB5,7,0x48,7,0x4C,0,0xF0};
    const uint8_t expectedPrize[8]={0x69,0x5A,0x0F,0,0x63,0x2A,0x10,9};
    if(memcmp(rom+0x107D790,expectedGive,8)||memcmp(rom+0x107DF6C,expectedCatch,8)||memcmp(rom+0x104575D,expectedPrize,8)) return NO;
    memcpy(soulOriginalGet,rom+0x3FBE8,8); memcpy(soulOriginalSet,rom+0x4037C,8);
    memcpy(soulOriginalGive,rom+0x107D790,8);memcpy(soulOriginalCatch,rom+0x107DF6C,8);
    memcpy(soulOriginalPrize,rom+0x104575D,8);
    memcpy(rom+SoulStart,BoundSoulCode,sizeof(BoundSoulCode));
    uint8_t *thunks[]={soulGetThunk,soulSetThunk,soulGiveThunk,soulCatchThunk};
    const uint32_t targets[]={BoundSoulGetAddress,BoundSoulSetAddress,BoundSoulGiveAddress,BoundSoulCatchBlockedAddress};
    const size_t offsets[]={0x3FBE8,0x4037C,0x107D790,0x107DF6C};
    for(unsigned i=0;i<4;i++) {
        auto *t=thunks[i]; t[0]=0; t[1]=0x4B; t[2]=0x18; t[3]=0x47; // ldr r3; bx r3 (r0-r2 arguments preserved)
        put32(t+4,targets[i]); memcpy(rom+offsets[i],t,8);
    }
    memset(soulPrizeThunk,0,8);soulPrizeThunk[0]=0x05;put32(soulPrizeThunk+1,BoundSoulPrizeScriptAddress);
    memcpy(rom+0x104575D,soulPrizeThunk,8);
    put32(rom+SoulPolicy,0x314C5342); put32(rom+SoulPolicy+4,0);
    memset(rom+0x1FFE008,0,32);
    memset(internalRAM+0x4500,0,12+32*8);
    memset(internalRAM+BOUND_SOUL_ACQUISITION_OFFSET,0,sizeof(BoundSoulAcquisitionRing));soulROM=rom; return YES;
}
+ (BOOL)setSoulLinkDenied:(NSData *)identities {
    if(!soulHooked() || identities.length%8 || identities.length>2048*8) return NO;
    const auto *profile=multiRedProfile(rom);
    if(profile&&profile->eliminationHostSize && (word(rom+SoulPolicy+4)!=identities.length/8
       ||memcmp(rom+SoulPolicy+8,identities.bytes,identities.length))) put32(rom+profile->eliminationHostOffset+16,0);
    memcpy(rom+SoulPolicy+8,identities.bytes,identities.length);
    put32(rom+SoulPolicy+4,unsigned(identities.length/8)); return YES;
}
+ (BOOL)setSoulLinkEliminated:(NSData *)bits {
    if(!soulHooked()||bits.length!=256) return NO;
    const auto *profile=multiRedProfile(rom);if(!profile)return NO;
    if(!profile->eliminationHostSize)return YES; // Frozen earlier cartridges have no elimination UI/storage ABI.
    if(profile->eliminationHostSize!=288)return NO;
    auto *out=rom+profile->eliminationHostOffset;const unsigned count=word(rom+SoulPolicy+4);
    if(count>2048)return NO;
    const auto *mask=static_cast<const uint8_t *>(bits.bytes);
    for(unsigned i=count;i<2048;i++)if(mask[i/8]&(1u<<(i%8)))return NO;
    if(word(out)==0x31584C42&&word(out+4)==1&&word(out+12)==count&&word(out+16)==1
       &&!word(out+20)&&!word(out+24)&&!word(out+28)&&word(out+8)&&!(word(out+8)&1)&&!memcmp(out+32,bits.bytes,256))return YES;
    uint32_t sequence=word(out+8);sequence=sequence>=0xFFFFFFFC?2:(sequence&~1u)+2;
    put32(out+8,sequence-1);put32(out,0x31584C42);put32(out+4,1);put32(out+12,count);put32(out+16,1);
    memset(out+20,0,12);memcpy(out+32,bits.bytes,256);put32(out+8,sequence);return YES;
}
+ (BOOL)usesAcceptedSoulFaints {
    const auto *profile=multiRedProfile(rom);return profile&&profile->eliminationHostSize;
}
+ (BOOL)setSoulLinkAcquired:(NSData *)bits {
    if(!soulHooked()||bits.length!=288) return NO;
    memcpy(rom+0x1FFE008,bits.bytes,32);return YES;
}
+ (NSDictionary<NSString *,id> *)soulLinkSnapshot {
    if(!rom||!workRAM||!internalRAM || workRAM[0x24029]>6) return @{};
    NSData *boxes=[NSData data];
    const bool ready=overworld();
    if(ready) {
        // Exact RR 4.1 table: 25 boxes, 30 slots, 58-byte compressed Pokemon.
        boxes=soulBoxCache.read(rom+0x1148930,workRAM);
        if(!boxes) return @{};
    }
    const unsigned n=workRAM[0x24029];
    NSMutableData *faints=[NSMutableData data];
    NSData *acquisitions=[NSData data];
    bool overflow=false;
    if(soulHooked() && word(internalRAM+0x4500)==0x314C5342) {
        unsigned count=word(internalRAM+0x4504);
        overflow=count>32 || word(internalRAM+0x4508)!=0;
        if(count<=32) [faints appendBytes:internalRAM+0x450C length:count*8];
    }
    if(soulHooked()&&word(internalRAM+BOUND_SOUL_ACQUISITION_OFFSET)==0x314C5342) {
        const unsigned count=word(internalRAM+(BOUND_SOUL_ACQUISITION_OFFSET+4));
        overflow=overflow||count>32||word(internalRAM+(BOUND_SOUL_ACQUISITION_OFFSET+8))!=0;
        if(count<=32) acquisitions=[NSData dataWithBytes:internalRAM+(BOUND_SOUL_ACQUISITION_OFFSET+12) length:count*12];
    }
    NSMutableData *active=[NSMutableData data];
    const auto *faintProfile=multiRedProfile(rom);
    // Current cartridges latch the native accepted-faint command after RR's
    // revival checks. Raw BattleMon zero HP is only legacy evidence.
    if((internalRAM[0x3529]&2) && !(faintProfile&&faintProfile->eliminationHostSize)) {
        unsigned count=workRAM[0x23BCC];
        if(count<=4) for(unsigned i=0;i<count;i++) {
            const auto *b=workRAM+0x23BE4+i*88;
            // Match identity, not side/index: partner and raid teams may reorder.
            if(half(b+0x2C)>0 && half(b+0x28)==0) {
                [active appendBytes:b+0x48 length:4]; [active appendBytes:b+0x54 length:4];
            }
        }
    }
    return @{@"ready":@(ready),@"battle":@((internalRAM[0x3529]&2)!=0),@"party":[NSData dataWithBytes:workRAM+0x24284 length:n*100],
             @"outcome":@(workRAM[0x23E8A]),@"battleFlags":@(word(workRAM+0x22B4C)),
             @"boxes":boxes,@"faints":faints,@"battleFaints":active,@"overflow":@(overflow),@"acquisitions":acquisitions};
}
+ (void)acknowledgeSoulLinkFaints {
    if(soulHooked()&&word(internalRAM+0x4500)==0x314C5342) { put32(internalRAM+0x4504,0); put32(internalRAM+0x4508,0); }
}
+ (BOOL)acknowledgeSoulLinkFaintsMatching:(NSData *)identities {
    return soulHooked()&&internalRAM&&acknowledgeSoulRing(internalRAM+0x4500,identities);
}
+ (BOOL)acknowledgeSoulLinkAcquisitionsMatching:(NSData *)receipts {
    if(!soulHooked()||!internalRAM) return NO;
    auto *ring=internalRAM+BOUND_SOUL_ACQUISITION_OFFSET;
    if(word(ring)!=0x314C5342) return receipts.length==0;
    const unsigned count=word(ring+4);
    if(word(ring+8)||count>32||receipts.length!=count*12
       ||(receipts.length&&memcmp(ring+12,receipts.bytes,receipts.length))) return NO;
    put32(ring+4,0);return YES;
}
+ (NSUInteger)claimSoulFrameOwner:(NSString *)owner gameURL:(NSURL *)url {
    if(!rom||!owner.length||!installSoulFrameFence()
       ||canonicalSavePath([GBAEmulatorBridge sharedBridge].gameURL)!=canonicalSavePath(url)) return 0;
    auto &fence=soulFrameFence();std::lock_guard<std::mutex> lock(fence.lock);
    const std::string identity=owner.UTF8String;
    if(fence.blocked&&fence.owner!=identity) return 0;
    fence.owner=identity;fence.cartridge=rom;
    return NSUInteger(fence.generation);
}
+ (BOOL)setSoulFrameBlocked:(BOOL)blocked owner:(NSString *)owner generation:(NSUInteger)generation {
    auto &fence=soulFrameFence();std::lock_guard<std::mutex> lock(fence.lock);
    if(!generation||generation!=fence.generation||fence.cartridge!=rom||fence.owner!=std::string(owner.UTF8String)) return NO;
    fence.blocked=blocked;return YES;
}
+ (BOOL)isSoulFrameBlockedForOwner:(NSString *)owner generation:(NSUInteger)generation {
    auto &fence=soulFrameFence();std::lock_guard<std::mutex> lock(fence.lock);
    return generation&&generation==fence.generation&&fence.cartridge==rom
        &&fence.owner==std::string(owner.UTF8String)&&fence.blocked;
}
+ (void)enforceSoulLink {
    if(!soulHooked()||!workRAM||!internalRAM) return;
    const unsigned count=word(rom+SoulPolicy+4);
    if(count>2048) return;
    auto denied=[](const uint8_t *mon) {
        unsigned low=0,high=word(rom+SoulPolicy+4);
        const auto p=word(mon),t=word(mon+4);
        while(low<high) {
            unsigned mid=(low+high)/2; const auto *id=rom+SoulPolicy+8+mid*8;
            auto a=word(id),b=word(id+4);
            if(a==p&&b==t) return true;
            if(a<p || (a==p&&b<t)) low=mid+1; else high=mid;
        }
        return false;
    };
    for(unsigned i=0;i<workRAM[0x24029]&&i<6;i++) {
        auto *mon=workRAM+0x24284+i*100;
        if(denied(mon)) put16(mon+86,0);
    }
    if(internalRAM[0x3529]&2) {
        unsigned n=workRAM[0x23BCC];
        if(n<=4) for(unsigned i=0;i<n;i+=2) {
            auto *b=workRAM+0x23BE4+i*88;
            uint8_t identity[8]; memcpy(identity,b+0x48,4); memcpy(identity+4,b+0x54,4);
            // Native attack-canceler rejects a zero-HP attacker. Also cover
            // already-active Pokemon when the partner faints during a turn.
            if(half(b+0x2C)>0 && denied(identity)) put16(b+0x28,0);
        }
    }
}
+ (void)closeSoulLink {
    soulBoxCache.bytes=nil;
    if(soulHooked()) {
        memcpy(rom+0x3FBE8,soulOriginalGet,8); memcpy(rom+0x4037C,soulOriginalSet,8);
        memcpy(rom+0x107D790,soulOriginalGive,8);memcpy(rom+0x107DF6C,soulOriginalCatch,8);
        memcpy(rom+0x104575D,soulOriginalPrize,8);
        // A paused CPU can still have a shim return address on its stack.
        // Leave the original tiny body resident and inert until ROM unload;
        // restore entry bytes and clear policy instead of erasing live code.
        put32(rom+SoulPolicy+4,0);
        put32(rom+SoulPolicy,0);memset(rom+0x1FFE008,0,32);
        const auto *profile=multiRedProfile(rom);
        if(profile&&profile->eliminationHostSize)memset(rom+profile->eliminationHostOffset,0,profile->eliminationHostSize);
    }
}

#if DEBUG && TARGET_OS_SIMULATOR
+ (NSDictionary<NSString *,id> *)qaBeginGuestTiming:(DLTAEmulatorCore *)core expectedROM:(NSData *)image points:(NSArray<NSDictionary<NSString *,id> *> *)points maximumEvents:(NSUInteger)maximumEvents {
#if defined(BOUND_QA_GUEST_TIMING) && BOUND_QA_GUEST_TIMING
    if(![NSThread isMainThread]||core.state!=StatePaused||guestTimingROM||movementEntryROM
       ||image.length!=0x2000000||!ownsROMUI()||armed||inviteActive||installed
       ||points.count<1||points.count>64||maximumEvents<1024||maximumEvents>262144)return nil;
    const auto *profile=multiRedProfile(rom);
    const auto *source=static_cast<const uint8_t *>(image.bytes);
    if(!profile||!profile->matches(source))return nil;
    // Only the existing host ABI pages are normalized. In particular, an
    // unexpected entry patch or runtime shim cannot acquire a source-ROM name.
    NSMutableData *expected=[image mutableCopy],*resident=[NSMutableData dataWithBytes:rom length:0x2000000];
    profile->normalize(static_cast<uint8_t *>(expected.mutableBytes));
    profile->normalize(static_cast<uint8_t *>(resident.mutableBytes));
    if(![expected isEqualToData:resident])return nil;
    uint32_t addresses[64]={},returns[64]={};
    NSMutableArray *verified=[NSMutableArray arrayWithCapacity:points.count];
    for(NSUInteger i=0;i<points.count;i++) {
        NSDictionary *point=points[i];
        if(![point isKindOfClass:[NSDictionary class]])return nil;
        NSString *name=point[@"name"],*encoded=point[@"bytes"];
        NSNumber *address=point[@"address"],*trackReturn=point[@"trackReturn"];
        if(![name isKindOfClass:[NSString class]]||name.length<1||name.length>128
           ||![encoded isKindOfClass:[NSString class]]||![address isKindOfClass:[NSNumber class]]
           ||![trackReturn isKindOfClass:[NSNumber class]])return nil;
        const uint64_t pc=address.unsignedLongLongValue,track=trackReturn.unsignedLongLongValue;
        if(pc<0x08000000||pc>0x09FFFFF0||(pc&1)||track>1
           ||address.doubleValue!=double(pc)||trackReturn.doubleValue!=double(track))return nil;
        NSData *bytes=[[NSData alloc] initWithBase64EncodedString:encoded options:0];
        if(bytes.length!=16||memcmp(source+pc-0x08000000,bytes.bytes,16)
           ||memcmp(rom+pc-0x08000000,bytes.bytes,16))return nil;
        addresses[i]=uint32_t(pc);returns[i]=uint32_t(track);
        [verified addObject:@{@"name":name,@"address":@(pc),@"bytes":encoded,@"trackReturn":@(track)}];
    }
    if(!BoundQAGuestTimingStart(addresses,returns,points.count,maximumEvents))return nil;
    guestTimingCore=core;guestTimingROM=rom;
    guestTimingMetadata=@{@"enabled":@YES,@"schema":@1,@"sourceROM_SHA256":movementEntryHash(source,0x2000000),
        @"points":verified,@"maximumEvents":@(maximumEvents),@"soulHooked":@(soulHooked()),@"soulResident":@(soulResident()),
        @"scope":@"Opt-in host observer of guest interpreter cycles. No guest writes or added guest cycles; wall-clock performance and physical display acceptance excluded. Hardware event rows and instruction-complete rows have distinct boundaries and need not be globally timestamp ordered."};
    return guestTimingMetadata;
#else
    return nil;
#endif
}
+ (NSDictionary<NSString *,id> *)qaEndGuestTiming:(DLTAEmulatorCore *)core {
#if defined(BOUND_QA_GUEST_TIMING) && BOUND_QA_GUEST_TIMING
    if(![NSThread isMainThread]||core.state!=StatePaused||!guestTimingROM||guestTimingCore!=core)return nil;
    BoundQAGuestTimingSummary summary{};
    const auto *records=BoundQAGuestTimingStop(&summary);
    NSMutableDictionary *result=[guestTimingMetadata mutableCopy];
    result[@"recordBytes"]=@(sizeof(BoundQAGuestTimingRecord));result[@"recordCount"]=@(summary.records);
    result[@"dropped"]=@(summary.dropped);result[@"stackOverflows"]=@(summary.stackOverflows);
    result[@"invalidated"]=@(summary.invalidated+(guestTimingROM!=rom?1:0));
    result[@"cycles"]=@(summary.cycles);result[@"videoFrames"]=@(summary.videoFrames);
    result[@"dmaCycles"]=@(summary.dmaCycles);result[@"idleCycles"]=@(summary.idleCycles);
    result[@"openCalls"]=@(summary.openCalls);result[@"openInterrupts"]=@(summary.openInterrupts);
    result[@"columns"]=@[@"kind",@"cycle",@"callID",@"pointIndex",@"pc",@"lr",@"sp",@"modeAndARM",@"vcount",@"dispstat",@"lcdTicksSigned",@"ie",@"if",@"ime",@"videoFrame",@"dmaCycles",@"idleCycles"];
    result[@"kindNames"]=@{@"1":@"call",@"2":@"return",@"3":@"irq",@"4":@"irqReturn",@"5":@"video",@"6":@"start",@"7":@"stop",@"8":@"invalidated",@"9":@"marker"};
    result[@"records"]=[NSData dataWithBytes:records length:summary.records*sizeof(BoundQAGuestTimingRecord)];
    guestTimingCore=nil;guestTimingROM=nullptr;guestTimingMetadata=nil;
    return result;
#else
    return nil;
#endif
}
+ (NSDictionary<NSString *,id> *)qaBeginNativeMovementEntries:(DLTAEmulatorCore *)core expectedROM:(NSData *)image {
    // Exact two-entry ablation, never a general ROM or RAM write API. The
    // paused core is passed explicitly so a running caller is rejected.
    if(![NSThread isMainThread]||core.state!=StatePaused||movementEntryROM||image.length!=0x2000000
       ||!ownsROMUI()||!overworld()||armed||inviteActive||installed||!movementEntryPipelineClear()) return nil;
    const auto *profile=multiRedProfile(rom);
    const auto *source=static_cast<const uint8_t *>(image.bytes);
    if(!profile||!profile->matches(source))return nil;
    NSMutableData *expected=[image mutableCopy],*resident=[NSMutableData dataWithBytes:rom length:0x2000000];
    profile->normalize(static_cast<uint8_t *>(expected.mutableBytes));
    profile->normalize(static_cast<uint8_t *>(resident.mutableBytes));
    if(![expected isEqualToData:resident])return nil;
    const uint8_t thunk[]={0x00,0x4B,0x18,0x47};
    NSMutableArray *patches=[NSMutableArray array];
    for(unsigned i=0;i<2;i++) {
        const unsigned at=MovementEntryOffsets[i];const uint32_t target=word(source+at+4);
        if(memcmp(source+at,thunk,4)||!(target&1)||target<0x08000000+profile->codeStart
           ||target>=0x08000000+profile->codeEnd||memcmp(rom+at,source+at,8))return nil;
        [patches addObject:@{@"offset":@(at),@"before":[[NSData dataWithBytes:source+at length:8] base64EncodedStringWithOptions:0],
                            @"after":[[NSData dataWithBytes:MovementNativeEntries[i] length:8] base64EncodedStringWithOptions:0]}];
    }
    NSString *before=movementEntryHash(rom,0x2000000),*sourceHash=movementEntryHash(source,0x2000000);
    movementEntryNormalizedSHA=movementEntryHash(expected.bytes,0x2000000);
    NSMutableData *diagnostic=[image mutableCopy];
    for(unsigned i=0;i<2;i++) {
        const unsigned at=MovementEntryOffsets[i];memcpy(movementSavedEntries[i],rom+at,8);
        memcpy(rom+at,MovementNativeEntries[i],8);
        memcpy(static_cast<uint8_t *>(diagnostic.mutableBytes)+at,MovementNativeEntries[i],8);
    }
    movementEntryROM=rom;movementEntryCore=core;movementEntryProfile=profile;
    return @{@"sourceROM_SHA256":sourceHash,@"diagnosticROM_SHA256":movementEntryHash(diagnostic.bytes,0x2000000),
             @"residentBeforeSHA256":before,@"residentAfterSHA256":movementEntryHash(rom,0x2000000),
             @"normalizedSourceSHA256":movementEntryNormalizedSHA,@"patches":patches,@"pausedNextPC":@(armNextPC),
             @"scope":@"Private paused same-anchor main/field entry ablation. Host ABI pages are normalized only for identity verification; no RAM/BWO writes, no diagnostic saved-state compatibility or original whole-ROM claim."};
}
+ (NSDictionary<NSString *,id> *)qaRestoreNativeMovementEntries:(DLTAEmulatorCore *)core {
    if(![NSThread isMainThread]||core.state!=StatePaused)return nil;
    if(!movementEntryROM)return @{@"restored":@YES,@"wasActive":@NO};
    if(movementEntryROM!=rom||movementEntryCore!=core||!movementEntryProfile||!movementEntryPipelineClear())return nil;
    for(unsigned i=0;i<2;i++)if(memcmp(rom+MovementEntryOffsets[i],MovementNativeEntries[i],8))return nil;
    for(unsigned i=0;i<2;i++)memcpy(rom+MovementEntryOffsets[i],movementSavedEntries[i],8);
    NSMutableData *resident=[NSMutableData dataWithBytes:rom length:0x2000000];
    movementEntryProfile->normalize(static_cast<uint8_t *>(resident.mutableBytes));
    NSString *normalized=movementEntryHash(resident.bytes,0x2000000);
    const bool exact=[normalized isEqualToString:movementEntryNormalizedSHA];
    movementEntryROM=nullptr;movementEntryCore=nil;movementEntryProfile=nullptr;movementEntryNormalizedSHA=nil;
    return @{@"restored":@YES,@"wasActive":@YES,@"normalizedIdentityRestored":@(exact),
             @"normalizedRestoredSHA256":normalized,@"residentRestoredSHA256":movementEntryHash(rom,0x2000000)};
}
// Frozen phase-5E pure observer used only as a byte/validation oracle in QA.
+ (NSDictionary<NSString *,id> *)qaSoulFaintAcknowledgementChecks {
    uint8_t ring[12+32*8]={};put32(ring,0x314C5342);put32(ring+4,1);put32(ring+12,17);put32(ring+16,42);
    NSData *first=[NSData dataWithBytes:ring+12 length:8];
    put32(ring+4,2);put32(ring+20,18);put32(ring+24,42);
    NSData *full=[NSData dataWithBytes:ring+12 length:16];
    const bool stale=!acknowledgeSoulRing(ring,first)&&word(ring+4)==2;
    const bool wrong=!acknowledgeSoulRing(ring,[NSMutableData dataWithLength:16])&&word(ring+4)==2;
    put32(ring+8,1);const bool overflow=!acknowledgeSoulRing(ring,full)&&word(ring+4)==2&&word(ring+8)==1;
    put32(ring+8,0);put32(ring+4,33);const bool count=!acknowledgeSoulRing(ring,full)&&word(ring+4)==33;
    put32(ring+4,2);const bool exact=acknowledgeSoulRing(ring,full)&&word(ring+4)==0&&word(ring+8)==0;
    return @{@"stale":@(stale),@"wrong":@(wrong),@"overflow":@(overflow),@"count":@(count),@"exact":@(exact)};
}
+ (NSDictionary<NSString *,id> *)qaSoulBoxCacheChecks {
    NSMutableData *table=[NSMutableData dataWithLength:25*4],*ram=[NSMutableData dataWithLength:0x40000];
    auto *t=static_cast<uint8_t *>(table.mutableBytes),*r=static_cast<uint8_t *>(ram.mutableBytes);
    for(unsigned i=0;i<25;i++) put32(t+i*4,0x02000000+i*30*58);
    for(unsigned i=0;i<ram.length;i++) r[i]=uint8_t(i*17+i/1740);
    // Original append/copy behavior, including every address bound.
    auto oracle=[&]()->NSData * {
        NSMutableData *value=[NSMutableData data];
        for(unsigned i=0;i<25;i++) {
            uint32_t address=word(t+i*4);
            if(address<0x02000000||address>0x02040000-30*58) return nil;
            [value appendBytes:r+address-0x02000000 length:30*58];
        }
        return value;
    };
    SoulBoxSnapshotCache cache;
    NSData *first=cache.read(t,r),*frozen=[first copy];
    bool reuse=first==cache.read(t,r),equal=[first isEqualToData:oracle()],retained=true;
    unsigned transitions=0;
    for(unsigned box=0;box<25;box++) for(unsigned offset:{0u,30u*58u-1u}) {
        NSData *old=cache.bytes,*oldCopy=[old copy];
        r[box*30*58+offset]^=0xFF;
        equal=equal&&[cache.read(t,r) isEqualToData:oracle()];
        retained=retained&&[old isEqualToData:oldCopy];transitions++;
    }
    // Valid relocation/alias, exact upper bound, invalid low/high pointers, and
    // restoring an older RAM image all retain the original acceptance rules.
    for(uint32_t address:{0x02000100u,0x02000000u,0x02040000u-30u*58u,0x01FFFFFFu,0x02040000u-30u*58u+1u}) {
        put32(t+24*4,address);
        NSData *actual=cache.read(t,r),*expected=oracle();
        equal=equal&&((!actual&&!expected)||[actual isEqualToData:expected]);transitions++;
    }
    put32(t+24*4,0x02000000+24*30*58);
    for(unsigned i=0;i<ram.length;i++) r[i]=uint8_t(i*17+i/1740);
    equal=equal&&[cache.read(t,r) isEqualToData:frozen];
    retained=retained&&[first isEqualToData:frozen];
    return @{@"equal":@(equal),@"reused":@(reuse),@"retained":@(retained),@"transitions":@(transitions+1)};
}

+ (NSData *)qaEliminationPolicy {
    const auto *profile=multiRedProfile(rom);
    return rom&&profile&&profile->eliminationHostSize==288
        ? [NSData dataWithBytes:rom+profile->eliminationHostOffset length:288] : [NSData data];
}
+ (uint64_t)qaSoulPolicyStatus {
    if(!rom)return 0;
    uint32_t flags=soulHooked()?1u:(soulResident()?2u:0u),sequence=0;
    const uint32_t count=word(rom+SoulPolicy+4);
    if(word(rom+SoulPolicy)==0x314C5342&&count<=2048)flags|=4;
    const auto *profile=multiRedProfile(rom);
    if(profile&&profile->eliminationHostSize==288) {
        const auto *in=rom+profile->eliminationHostOffset;sequence=word(in+8);
        if(word(in)==0x31584C42&&word(in+4)==1&&sequence&&!(sequence&1)
           &&word(in+12)==count&&word(in+16)==1&&!word(in+20)&&!word(in+24)&&!word(in+28))flags|=8;
    }
    return (uint64_t(sequence)<<32)|flags;
}
+ (BOOL)qaSoulFrameBlocked {
    auto &fence=soulFrameFence();std::lock_guard<std::mutex> lock(fence.lock);
    return rom&&fence.cartridge==rom&&fence.blocked;
}
+ (NSData *)qaWorldMovementHost {
    const auto *profile=multiRedProfile(rom);
    if(!rom||!profile||profile->presenceHostSize!=1024)return [NSData data];
    return [NSData dataWithBytes:rom+profile->presenceHostOffset length:1024];
}
+ (NSData *)qaLinksMenuHost {
    const auto *profile=multiRedProfile(rom);
    if(!rom||!profile||!profile->linksHostSize) return [NSData data];
    return [NSData dataWithBytes:rom+profile->linksHostOffset length:profile->linksHostSize];
}
+ (NSDictionary<NSString *,id> *)qaUncachedSoulLinkSnapshot {
    if(!rom||!workRAM||!internalRAM || workRAM[0x24029]>6) return @{};
    NSMutableData *boxes=[NSMutableData data];
    const bool ready=overworld();
    if(ready) {
        // Exact RR 4.1 table: 25 boxes, 30 slots, 58-byte compressed Pokemon.
        for(unsigned i=0;i<25;i++) {
            uint32_t address=word(rom+0x1148930+i*4);
            if(address<0x02000000 || address>0x02040000-30*58) return @{};
            [boxes appendBytes:workRAM+address-0x02000000 length:30*58];
        }
    }
    const unsigned n=workRAM[0x24029];
    NSMutableData *faints=[NSMutableData data];
    NSData *acquisitions=[NSData data];
    bool overflow=false;
    if(soulHooked() && word(internalRAM+0x4500)==0x314C5342) {
        unsigned count=word(internalRAM+0x4504);
        overflow=count>32 || word(internalRAM+0x4508)!=0;
        if(count<=32) [faints appendBytes:internalRAM+0x450C length:count*8];
    }
    if(soulHooked()&&word(internalRAM+BOUND_SOUL_ACQUISITION_OFFSET)==0x314C5342) {
        const unsigned count=word(internalRAM+(BOUND_SOUL_ACQUISITION_OFFSET+4));
        overflow=overflow||count>32||word(internalRAM+(BOUND_SOUL_ACQUISITION_OFFSET+8))!=0;
        if(count<=32) acquisitions=[NSData dataWithBytes:internalRAM+(BOUND_SOUL_ACQUISITION_OFFSET+12) length:count*12];
    }
    NSMutableData *active=[NSMutableData data];
    if(internalRAM[0x3529]&2) {
        unsigned count=workRAM[0x23BCC];
        if(count<=4) for(unsigned i=0;i<count;i++) {
            const auto *b=workRAM+0x23BE4+i*88;
            // Match identity, not side/index: partner and raid teams may reorder.
            if(half(b+0x2C)>0 && half(b+0x28)==0) {
                [active appendBytes:b+0x48 length:4]; [active appendBytes:b+0x54 length:4];
            }
        }
    }
    return @{@"ready":@(ready),@"battle":@((internalRAM[0x3529]&2)!=0),@"party":[NSData dataWithBytes:workRAM+0x24284 length:n*100],
             @"outcome":@(workRAM[0x23E8A]),@"battleFlags":@(word(workRAM+0x22B4C)),
             @"boxes":boxes,@"faints":faints,@"battleFaints":active,@"overflow":@(overflow),@"acquisitions":acquisitions};
}
+ (BOOL)qaCooperativeGameSaveBlocked:(NSURL *)url {
    auto &fence=gameSaveFence();std::lock_guard<std::mutex> lock(fence.lock);
    return fence.cooperativeBlockedPaths.count(canonicalSavePath(url))!=0;
}
+ (NSData *)qaSharedWorldImmutableDigest {
    if(!rom) return [NSData data];
    NSMutableData *copy=[NSMutableData dataWithBytes:rom length:0x2000000];
    memset((uint8_t *)copy.mutableBytes+GameHostOffset,0,GameHostSize);
    uint8_t digest[32];CC_SHA256(copy.bytes,CC_LONG(copy.length),digest);
    return [NSData dataWithBytes:digest length:32];
}
+ (BOOL)qaStartSharedWorldWait {
    if(!worldOwnsROM()||![self friendDialogueReady]) return NO;
    const uint8_t script[]={0x5C,0,0x6E,0,0,0,0,0,0,0,0,0,0,0,0x02};
    memcpy(internalRAM+0x4280,script,sizeof(script));
    memset(internalRAM+0xEB0,0,0x74); internalRAM[0xEB1]=1; put32(internalRAM+0xEB8,0x03004280);
    put32(internalRAM+0xF0C,0x0815F9B4); put32(internalRAM+0xF10,0x0815FD08);
    internalRAM[0xEA8]=0; internalRAM[0xF9C]=1;
    return YES;
}
+ (BOOL)qaStartSharedWorldSightlineWait {
    if(![self qaStartSharedWorldWait]) return NO;
    // Automatic trainer encounters bypass opcode 0x5C and launch with 0x5D.
    internalRAM[0x4280]=0x5D; internalRAM[0x4281]=0x02;
    return YES;
}
+ (BOOL)qaPrepareNuggetBridgeFixture {
    if(!worldOwnsROM()||!overworld()||workRAM[0x24029]!=1) return NO;
    const uint32_t save=word(internalRAM+0x5008);
    if(save<0x02000000||save>0x0203D000) return NO;
    auto *s=workRAM+save-0x02000000;
    // Fixture setup only: neither player starts with a bridge victory. Wins
    // thereafter must come from the real native battle/post-battle scripts.
    const unsigned flags[]={0x56e,0x57b,0x55c,0x57a,0x590};
    for(unsigned id:flags) s[0xEE0+id/8]&=uint8_t(~(1u<<(id%8)));
    auto *mon=workRAM+0x24284;
    // Keep Chikorita inside the first badge's level cap. A level-100 fixture
    // can disobey under RR rules; use boosted stats at a valid early level.
    if(half(mon+32)!=152) return NO;
    put32(mon+36,1612);mon[84]=14; // Native medium-slow level-14 experience.
    put32(mon+80,0);put16(mon+86,500);put16(mon+88,500);
    for(unsigned offset=90;offset<100;offset+=2) put16(mon+offset,500);
    return YES;
}
+ (BOOL)qaWarpNuggetBridge:(NSUInteger)y {
    if(!worldOwnsROM()||!overworld()||(y!=29&&y!=33)) return NO;
    // Use the cartridge's warp opcode, rather than replacing map/battle logic.
    const uint8_t script[]={0x39,3,43,255,11,0,uint8_t(y),0,0x02};
    memcpy(internalRAM+0x4280,script,sizeof(script));
    memset(internalRAM+0xEB0,0,0x74);internalRAM[0xEB1]=1;put32(internalRAM+0xEB8,0x03004280);
    put32(internalRAM+0xF0C,0x0815F9B4);put32(internalRAM+0xF10,0x0815FD08);
    internalRAM[0xEA8]=0;internalRAM[0xF9C]=1;
    return YES;
}
+ (BOOL)qaWarpPalletEntrance {
    if(!ownsROMUI()||!overworld()) return NO;
    // Use the cartridge's warp opcode, rather than replacing map/battle logic.
    // The disposable traversal fixture bypasses Oak's one-time stop at (12,1).
    // Native setvar changes only that story gate; map loading and movement stay native.
    const uint8_t script[]={0x16,0x50,0x40,1,0,0x29,0x2F,0x08,0x39,3,0,255,12,0,2,0,0x02};
    memcpy(internalRAM+0x4280,script,sizeof(script));
    memset(internalRAM+0xEB0,0,0x74);internalRAM[0xEB1]=1;put32(internalRAM+0xEB8,0x03004280);
    put32(internalRAM+0xF0C,0x0815F9B4);put32(internalRAM+0xF10,0x0815FD08);
    internalRAM[0xEA8]=0;internalRAM[0xF9C]=1;
    return YES;
}
+ (BOOL)qaWarpViridianMartEntrance {
    if(!ownsROMUI()||!overworld()) return NO;
    const uint8_t script[]={0x39,3,1,255,36,0,20,0,0x02};
    memcpy(internalRAM+0x4280,script,sizeof(script));
    memset(internalRAM+0xEB0,0,0x74);internalRAM[0xEB1]=1;put32(internalRAM+0xEB8,0x03004280);
    put32(internalRAM+0xF0C,0x0815F9B4);put32(internalRAM+0xF10,0x0815FD08);
    internalRAM[0xEA8]=0;internalRAM[0xF9C]=1;
    return YES;
}
+ (BOOL)qaWarpViridianFollowerService {
    if(!ownsROMUI()||!overworld()) return NO;
    // Disposable QA only: hide the map's unused flag-0x200 placeholders and
    // use native warp to face the original follower service. The native NPC
    // dialogue, party selector and follower creation still run unchanged.
    const uint8_t script[]={0x29,0x00,0x02,0x39,5,4,255,10,0,7,0,0x02};
    memcpy(internalRAM+0x4280,script,sizeof(script));
    memset(internalRAM+0xEB0,0,0x74);internalRAM[0xEB1]=1;put32(internalRAM+0xEB8,0x03004280);
    put32(internalRAM+0xF0C,0x0815F9B4);put32(internalRAM+0xF10,0x0815FD08);
    internalRAM[0xEA8]=0;internalRAM[0xF9C]=1;
    return YES;
}
+ (BOOL)qaStopMapMusicRetainingTracks {
    if(!ownsROMUI()||!overworld()) return NO;
    // Reproduce the MP2K state observed in the affected Mac checkpoint.
    // The native door must handle stopped music without discarding track bits.
    const auto status=word(internalRAM+0x7304);
    if(!(status&0xFFFF)) return NO;
    put32(internalRAM+0x7304,status|0x80000000u);
    return YES;
}
+ (BOOL)qaSetFollowerFriendship:(NSUInteger)value {
    if(!workRAM||!fieldInterruptionReady()||workRAM[0x24029]==0||value>255) return NO;
    workRAM[0x24284+41]=(uint8_t)value;return YES;
}
+ (BOOL)qaPrepareBerryFixture:(BOOL)ownInteraction {
    if(!ownsROMUI()||!fieldInterruptionReady()||workRAM[0x24029]!=1) return NO;
    // Disposable fixture only: native AddBagItem supplies two Oran Berries.
    // The own-interaction branch executes the unmodified feeding script and
    // effect helper, using the native Bulbasaur givemon fixture as its target.
    const uint8_t script[]={0x44,0x8B,0,2,0,0x16,0x30,0x51,1,0,0x23,0xF5,0x6D,9,9,0x69,0x05,0x30,0x9C,4,9};
    memcpy(internalRAM+0x4280,script,sizeof(script));
    if(!ownInteraction) internalRAM[0x4285]=0x02;
    memset(internalRAM+0xEB0,0,0x74);internalRAM[0xEB1]=1;put32(internalRAM+0xEB8,0x03004280);
    put32(internalRAM+0xF0C,0x0815F9B4);put32(internalRAM+0xF10,0x0815FD08);
    internalRAM[0xEA8]=0;internalRAM[0xF9C]=1;
    return YES;
}
+ (BOOL)qaStartMusicPauseText {
    if(!ownsROMUI()||!overworld()) return NO;
    // A native asynchronous field message: PAUSE_MUSIC, wait for A,
    // a visible character, RESUME_MUSIC, end. No audio status is fabricated.
    const uint8_t text[]={0xFC,0x17,0xFC,0x09,0xBB,0xFC,0x18,0xFF};
    const uint8_t script[]={0x67,0xB0,0x42,0,3,0x02};
    memcpy(internalRAM+0x42B0,text,sizeof(text));
    memcpy(internalRAM+0x4280,script,sizeof(script));
    memset(internalRAM+0xEB0,0,0x74);internalRAM[0xEB1]=1;put32(internalRAM+0xEB8,0x03004280);
    put32(internalRAM+0xF0C,0x0815F9B4);put32(internalRAM+0xF10,0x0815FD08);
    internalRAM[0xEA8]=0;internalRAM[0xF9C]=1;
    return YES;
}
+ (BOOL)qaHideMusicPauseText {
    if(!ownsROMUI()||!overworld()) return NO;
    // Keep a native asynchronous text owner advancing across the hide. This
    // isolates replacement of its printer from destruction of the draw task.
    // ARMv4T CreateTask(RunTextPrinters_CheckPrinter0Active, 80), then return.
    const uint8_t owner[]={0,0xB5,4,0x48,0x50,0x21,4,0x4B,0,0xF0,2,0xF8,
        1,0xBC,0,0x47,0x18,0x47,0xC0,0x46,0xBD,0x6C,0x0F,8,0x1D,0x74,7,8};
    memcpy(internalRAM+0x42D0,owner,sizeof(owner));
    const uint8_t script[]={0x23,0xF5,0x94,6,8,0x23,0xD1,0x42,0,3,0x02};
    memcpy(internalRAM+0x4280,script,sizeof(script));
    memset(internalRAM+0xEB0,0,0x74);internalRAM[0xEB1]=1;put32(internalRAM+0xEB8,0x03004280);
    put32(internalRAM+0xF0C,0x0815F9B4);put32(internalRAM+0xF10,0x0815FD08);
    internalRAM[0xEA8]=0;internalRAM[0xF9C]=1;
    return YES;
}
+ (NSDictionary<NSString *,id> *)qaFieldMusicStatus {
    if(!workRAM||!internalRAM) return @{};
    return @{@"status":@(word(internalRAM+0x7304)),@"musicState":@(internalRAM[0xFC4]),
             @"printerActive":@(workRAM[0x2004F]),@"messageMode":@(workRAM[0x3709C]),
             @"field":@(overworld())};
}
+ (void)qaSetLegacyFieldTextAdmission:(BOOL)enabled { qaLegacyFieldTextAdmission=enabled; }
+ (NSDictionary<NSString *,id> *)qaNuggetBridgeStatus {
    if(!workRAM||!internalRAM) return @{};
    const uint32_t save=word(internalRAM+0x5008);
    if(save<0x02000000||save>0x0203D000) return @{};
    const auto *s=workRAM+save-0x02000000;
    return @{@"firstWin":@((s[0xEE0+0x56e/8]>>(0x56e%8))&1),
             @"secondWin":@((s[0xEE0+0x57b/8]>>(0x57b%8))&1),
             @"opponent":@(half(workRAM+0x386AE)),@"battle":@([self isInBattle]),
             @"group":@(s[4]),@"number":@(s[5]),@"x":@(int16_t(half(s))),@"y":@(int16_t(half(s+2))),
             @"script":@(word(internalRAM+0xEB8)),@"ready":@(overworld())};
}
+ (BOOL)qaStartSoulCheck {
    if(!soulHooked() || !overworld()) return NO;
    memcpy(rom+SoulStart,BoundSoulQACode,sizeof(BoundSoulQACode));
    put32(soulPrizeThunk+1,BoundSoulQAPrizeScriptAddress);memcpy(rom+0x104575D,soulPrizeThunk,8);
    memcpy(soulQAScriptBackup,rom+ScriptAddress-0x08000000,128);
    uint8_t script[7]={0x23,0,0,0,0,0x6C,0x02};
    put32(script+1,BoundSoulQAAddress); memcpy(rom+ScriptAddress-0x08000000,script,sizeof(script));
    memset(internalRAM+0x4D00,0,16);
    memset(internalRAM+0xEB0,0,0x74); internalRAM[0xEB1]=1; put32(internalRAM+0xEB8,ScriptAddress);
    put32(internalRAM+0xF0C,0x0815F9B4); put32(internalRAM+0xF10,0x0815FD08);
    internalRAM[0xEA8]=0; internalRAM[0xF9C]=1;
    internalRAM[0xF9D]=internalRAM[0xF9E]=internalRAM[0xFA0]=0;
    return YES;
}
+ (BOOL)qaStartSoulCatch:(NSUInteger)mode {
    if(mode<1 || mode>3 || ![self qaStartSoulCheck]) return NO;
    put32(rom+ScriptAddress-0x08000000+1,BoundSoulQACatchAddress);
    put32(internalRAM+0x4D20,unsigned(mode)); return YES;
}
+ (NSArray<NSNumber *> *)qaSoulCheckResult {
    if(!internalRAM || word(internalRAM+0x4D00)!=0x31415153) return @[];
    return @[@(word(internalRAM+0x4D04)),@(word(internalRAM+0x4D08)),@(word(internalRAM+0x4D0C))];
}
+ (void)qaFinishSoulCheck {
    if(!soulHooked()) return;
    memset(rom+SoulStart,0xFF,0x2000); memcpy(rom+SoulStart,BoundSoulCode,sizeof(BoundSoulCode));
    put32(soulPrizeThunk+1,BoundSoulPrizeScriptAddress);memcpy(rom+0x104575D,soulPrizeThunk,8);
    memcpy(rom+ScriptAddress-0x08000000,soulQAScriptBackup,128);
}
+ (BOOL)qaStartNativePartyFixture {
    if(!ownsROMUI()||!overworld()||workRAM[0x24029]) return NO;
    // Same disposable starter recipe as multi_red's integrated gameplay QA:
    // native givemon creates a valid Bulbasaur, then releases the script lock.
    // Level five keeps Tackle first for the paired driver's normal A input.
    const uint8_t script[]={0x79,1,0,5,0,0,0,0,0,0,0,0,0,0,0,0x6B,0x02};
    memcpy(internalRAM+0x4280,script,sizeof(script));
    memset(internalRAM+0xEB0,0,0x74);internalRAM[0xEB1]=1;put32(internalRAM+0xEB8,0x03004280);
    put32(internalRAM+0xF0C,0x0815F9B4);put32(internalRAM+0xF10,0x0815FD08);
    internalRAM[0xEA8]=0;internalRAM[0xF9C]=1;
    return YES;
}
+ (BOOL)qaPrepareTradeFixture:(NSUInteger)marker {
    if(!overworld()||verifiedROM!=rom||(marker!=0xBB&&marker!=0xBC)) return NO;
    auto *mon=workRAM+0x24284;
    if(workRAM[0x24029]==2 && (mon[8]==0xBB || mon[8]==0xBC)) {
        memcpy(mon,mon+100,100); // Reuse only this explicit disposable fixture.
    } else if(workRAM[0x24029]!=1) return NO;
    // Two healthy Pokémon are required by the cartridge. This modifies only a
    // disposable simulator's working party, never the protected seed file.
    memcpy(mon+100,mon,100); workRAM[0x24029]=2;
    // This exact RR profile stores party substructures without vanilla's XOR
    // encryption. Only the fixture header's OT/name differ between peers.
    put32(mon+4,0xB00D0000u|uint32_t(marker));
    memset(mon+8,0xFF,10); mon[8]=uint8_t(marker);
    return YES;
}
+ (BOOL)qaConfigureBattleParty:(NSUInteger)mode {
    if(!ownsROMUI()||!overworld()||workRAM[0x24029]!=1||mode<1||mode>2) return NO;
    auto *mon=workRAM+0x24284;
    if(mode==2) {
        memcpy(mon+100,mon,100);workRAM[0x24029]=2;
        put32(mon+100,word(mon)^0x10203040);mon[169]=uint8_t(mon[69]+1);
        put16(mon+186,1); // A distinct living encounter, damaged but eligible.
    }
    put16(mon+86,0);return YES;
}
+ (NSDictionary<NSString *,id> *)qaBattleMenu {
    if(!workRAM||!internalRAM||!rom) return @{};
    for(unsigned i=0;i<4;i++) {
        const auto callback=word(internalRAM+0x4FE0+i*4);
        if(callback==0x0802E439||callback==0x090A9EA1||callback==0x0802EA11) {
            const bool move=callback==0x0802EA11;
            return @{@"battler":@(i),@"kind":move?@"move":@"action",@"cursor":@(workRAM[(move?0x23FFC:0x23FF8)+i]),
                @"playerHP":partyHP(0x24284,workRAM[0x24029]),@"enemyHP":partyHP(0x2402C,6)};
        }
    }
    return @{};
}
+ (NSDictionary<NSString *, id> *)qaTradeMenu {
    if(!workRAM||!internalRAM||!rom) return @{};
    const auto callback=word(internalRAM+0x30F4);
    const auto menu=word(workRAM+0x31DA8);
    if(callback!=0x0804D639 || menu<0x02000000 || menu>0x0203FF80) return @{};
    const auto *data=workRAM+menu-0x02000000;
    return @{@"id":@(data[0x6F]),@"cursor":@(data[0x35])};
}
+ (NSData *)qaTradeParty {
    if(!workRAM||!rom) return [NSData data];
    return [NSData dataWithBytes:workRAM+0x24284 length:600];
}
#endif
@end
#include "Debug/BoundDebugFixtureOperations.inc"
