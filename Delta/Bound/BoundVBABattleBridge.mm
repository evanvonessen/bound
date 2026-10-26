#import "BoundVBABattleBridge.h"
#import <DeltaCore/DeltaCore.h>
#import <DeltaCore/DeltaCore-Swift.h>
#import <GBADeltaCore/GBADeltaCore.h>
#import <CommonCrypto/CommonDigest.h>
#import <objc/runtime.h>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <set>
#include <string>
#include <zlib.h>
#include "NativeBattle/BoundBattleEntryCode.h"
#include "NativeBattle/BoundBattleDecisionCode.h"

extern uint8_t *rom,*workRAM,*internalRAM,*ioMem;
extern uint8_t flashSaveMemory[0x20000];
extern int flashSize;
extern int skipSaveGameBattery,skipSaveGameCheats;
extern void flashSetSize(int size);
extern bool CPUWriteMemState(char *,int,long &);
extern bool CPUReadMemState(char *,int);
namespace {
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
    if(!fence.serverOnlyActive&&fence.stateReader) fence.stateReader(bridge,selector,url);
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
#include "SoulLink/bridge.inc"
#include "NativeBattle/invitation.inc"
namespace {
uint8_t *romUIOwner=nullptr,*cooperativeROM=nullptr;
bool romFieldRDown=false;
bool romFieldTextWasIdle=false;
bool ownsROMUI() { return romUIOwner==rom && gameDescriptorPresent(rom); }
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
static uint8_t soulQAScriptBackup[128];
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
    if(!rom||!workRAM||!internalRAM) return [NSData data];
    NSMutableData *data=[NSMutableData dataWithLength:4*1024*1024];
    long reserved=0;
    if(!CPUWriteMemState(static_cast<char *>(data.mutableBytes),int(data.length),reserved)) return [NSData data];
    const auto *bytes=static_cast<const uint8_t *>(data.bytes);
    // VBA's memory writer prepends its own eight-byte length header. Read the
    // finalized length after gzip close rather than its pre-close estimate.
    const size_t length=size_t(word(bytes+4))+8;
    if(memcmp(bytes,"VBA ",4)||length<=32||length>data.length) return [NSData data];
    data.length=length;return data;
}
+ (BOOL)restoreServerState:(NSData *)data {
    if(!rom||!workRAM||!internalRAM||data.length<=32||data.length>4*1024*1024) return NO;
    const auto *bytes=static_cast<const uint8_t *>(data.bytes);
    if(memcmp(bytes,"VBA ",4)||size_t(word(bytes+4))+8!=data.length) return NO;
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
    NSMutableData *owned=[data mutableCopy];
    // Delta's ordinary load reapplies the current cheat configuration. Keep
    // that configuration here too; only the server snapshot supplies battery.
    const int previousBattery=skipSaveGameBattery,previousCheats=skipSaveGameCheats;
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
    if(cooperativeROM==rom&&rom&&gameDescriptorPresent(rom)) return YES;
    if(!rom||!workRAM||!internalRAM||!gameDescriptorPresent(rom)
       ||GameCooperativeSnapshotAddress<0x02000000
       ||GameCooperativeSnapshotAddress+GameCooperativeSnapshotSize>0x02040000
       ||GameCooperativeHostOffset+GameCooperativeHostSize>0x2000000) return NO;
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
    if(cooperativeROM!=rom||!rom||!workRAM||!gameDescriptorPresent(rom)) return [NSData data];
    const auto *p=workRAM+GameCooperativeSnapshotAddress-0x02000000;
    const uint32_t sequence=word(p+8);
    if(word(p)!=0x31474443||half(p+4)!=1||half(p+6)!=0||!sequence||(sequence&1)) return [NSData data];
    NSData *copy=[NSData dataWithBytes:p length:GameCooperativeSnapshotSize];
    return word(p+8)==sequence ? copy:[NSData data];
#else
    return [NSData data];
#endif
}
+ (void)setCooperativeHost:(NSData *)data {
#ifdef BOUND_GAME_COOPERATIVE_DOUBLES
    if(cooperativeROM!=rom||!rom||data.length!=GameCooperativeHostSize) return;
    const auto *p=static_cast<const uint8_t *>(data.bytes);const uint32_t sequence=word(p+8);
    if(word(p)!=0x31484443||half(p+4)!=1||half(p+6)!=0||!sequence||(sequence&1)
       ||(word(p+12)&~15u)||word(p+16)>180||word(p+20)>1) return;
    auto *out=rom+GameCooperativeHostOffset;put32(out+8,sequence-1);
    memcpy(out,p,8);memcpy(out+12,p+12,GameCooperativeHostSize-12);put32(out+8,sequence);
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
+ (BOOL)installROMMultiplayer {
    if(ownsROMUI()) return YES;
    if(!rom||!workRAM||!internalRAM||!gameDescriptorPresent(rom)) return NO;
    uint8_t digest[32]; soulOriginalHash(digest);
    const uint8_t expected[32]={0x68,0x92,0x99,0x66,0x4a,0x95,0x4c,0x12,0xda,0xd6,0x6e,0x03,0xc2,0xd1,0x84,0x46,
        0xb3,0x48,0xcb,0x31,0xbd,0x98,0xb3,0x95,0xc8,0x7b,0x9b,0x51,0x4b,0x28,0x80,0x66};
    if(memcmp(digest,expected,32)) return NO;
    if(GameUIRequestAddress<0x02000000||GameUIRequestAddress+GameUIRequestSize>0x02040000
       ||GameUIHostOffset+GameUIHostSize>0x2000000) return NO;
    romUIOwner=rom;romFieldRDown=romFieldTextWasIdle=false; return YES;
}
+ (void)advanceROMFieldRecovery {
    if(!ownsROMUI()||!workRAM||!internalRAM) return;
    // Guest scripts can consume newKeys before the emulator frame callback.
    // Observe the held-key edge instead, including while an action is blocked,
    // so a held R never queues a warp after a dialogue or link operation ends.
    const bool rDown=(half(internalRAM+0x311C)&0x100)!=0;
    const bool rPressed=rDown&&!romFieldRDown;
    romFieldRDown=rDown;
    // Native R handling can close text before this completed-frame sample.
    // A message owned on the preceding frame must still veto this press.
    const bool previousTextIdle=romFieldTextWasIdle;
    romFieldTextWasIdle=fieldTextIdle();
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

    const auto *guest=workRAM+GameUIRequestAddress-0x02000000;
    const auto *host=rom+GameUIHostOffset;
    const auto flags=word(guest+80),hostFlags=word(host+12);
    // Published field/settings/checkpoint bits must all be set; setup/modal
    // bits must be clear. Pending host invitations, recovery, saves, transfers,
    // run endings and setup changes also veto a warp before their UI appears.
    if(!rPressed||!previousTextIdle||!fieldInterruptionReady()
       ||word(guest)!=0x31525552||word(guest+160)!=1||word(guest+12)||word(guest+76)
       ||(flags&(1|2|4|32|64))!=(1|32|64)
       ||word(host)!=0x31495552||!(hostFlags&1)||(hostFlags&(32|64|256|512|1024|2048|4096))
       ||workRAM[0x3707B]||(workRAM[0x37ABF]&0x80)
       ||((half(workRAM+0x37ABC)>>6)&31)>=16) return;
    // Native warp script in idle link scratch, also serialized by core saves.
    // Battle/trade/dialogue owners above exclude reuse of this region. Using
    // the native script preserves ordinary fade, map loading and field unlock.
    const uint8_t script[]={0x39,3,0,255,16,0,14,0,0x27,0x6C,0x02};
    memcpy(internalRAM+0x4280,script,sizeof(script));
    memset(internalRAM+0xEB0,0,0x74);internalRAM[0xEB1]=1;put32(internalRAM+0xEB8,0x03004280);
    put32(internalRAM+0xF0C,0x0815F9B4);put32(internalRAM+0xF10,0x0815FD08);
    internalRAM[0xEA8]=0;internalRAM[0xF9C]=1;
    internalRAM[0x311F]&=~1;
}
+ (NSData *)romMultiplayerSnapshot {
    if(!ownsROMUI()||!workRAM) return [NSData data];
    const auto *p=workRAM+GameUIRequestAddress-0x02000000;
    const uint32_t sequence=word(p+8);
    if(word(p)!=0x31525552||half(p+4)!=1||half(p+6)!=0||!sequence||(sequence&1)) return [NSData data];
    NSMutableData *copy=[NSMutableData dataWithBytes:p length:GameUIRequestSize];
    if(word(p+8)!=sequence) return [NSData data];
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
    if(!ownsROMUI()||data.length!=GameUIHostSize) return;
    const auto *source=static_cast<const uint8_t *>(data.bytes);
    const uint32_t sequence=word(source+8);
    if(word(source)!=0x31495552||half(source+4)!=1||half(source+6)!=0||!sequence||(sequence&1)
       ||word(source+24)>20||word(source+312)>180) return;
    auto *destination=rom+GameUIHostOffset;
    put32(destination+8,sequence-1);
    memcpy(destination,source,8);memcpy(destination+12,source+12,GameUIHostSize-12);
    put32(destination+8,sequence);
}
// Attaches to the game's ABI; never installs/restores gameplay instructions.
+ (BOOL)installSharedWorld {
    if(worldOwnsROM()) return YES;
    if(!rom||!workRAM||!internalRAM||armed||inviteActive||!gameDescriptorPresent(rom)) return NO;
    uint8_t digest[32];soulOriginalHash(digest);
    const uint8_t expected[32]={0x68,0x92,0x99,0x66,0x4a,0x95,0x4c,0x12,0xda,0xd6,0x6e,0x03,0xc2,0xd1,0x84,0x46,
        0xb3,0x48,0xcb,0x31,0xbd,0x98,0xb3,0x95,0xc8,0x7b,0x9b,0x51,0x4b,0x28,0x80,0x66};
    if(memcmp(digest,expected,32)) return NO;
    if(GameSnapshotAddress<0x02000000||GameSnapshotAddress+GameSnapshotRegionSize>0x02040000) return NO;
    const auto *p=workRAM+GameSnapshotAddress-0x02000000;
    if(word(p)!=0x31434D52||half(p+4)!=GameABIMajor||half(p+6)>GameABIMinor||word(p+8)!=GameSnapshotRegionSize) return NO;
    worldROM=rom;
    if(![self sharedWorldSnapshot][@"checkpoints"]) { worldROM=nullptr; return NO; }worldSequence=0;[[NSUUID UUID] getUUIDBytes:worldSession];
    worldWritePolicy(false,[NSData data],0,0,[NSData data],false);
    return YES;
}
+ (NSDictionary<NSString *,id> *)sharedWorldSnapshot {
    if(!worldOwnsROM()||!workRAM) return @{};
    const auto *control=workRAM+GameSnapshotAddress-0x02000000;
    if(word(control)!=0x31434D52||half(control+4)!=GameABIMajor||half(control+6)>GameABIMinor
       ||word(control+8)!=GameSnapshotRegionSize||word(control+16)!=GameSnapshotSize||word(control+12)>1) return @{};
    const uint32_t index=word(control+12);
    const auto *p=control+64+index*GameSnapshotSize;
    const uint32_t sequence=word(p+12);
    if(!sequence||(sequence&1)||word(p)!=0x31534D52||half(p+4)!=GameABIMajor||half(p+6)>GameABIMinor
       ||word(p+8)!=GameSnapshotSize||word(p+20)!=1||p[24]>=43||p[26]>16
       ||memcmp(p+32,GameRulesetID,16)||word(p+48)!=1||word(p+52)!=1||word(p+56)!=GameSaveStateLayout) return @{};
    NSData *checkpoints=[NSData dataWithBytes:p+64 length:800];NSData *boulders=[NSData dataWithBytes:p+864 length:p[26]*6];
    if(word(p+12)!=sequence||word(control+12)!=index) return @{};
    return @{@"checkpoints":checkpoints,@"group":@(p[24]),@"number":@(p[25]),@"boulders":boulders,@"sequence":@(sequence),@"frame":@(word(p+16))};
}
+ (void)setSharedWorldPeer:(NSData *)checkpoints group:(NSUInteger)group number:(NSUInteger)number boulders:(NSData *)boulders fresh:(BOOL)fresh {
    worldWritePolicy(true,checkpoints,unsigned(group),unsigned(number),boulders,fresh);
}
+ (void)advanceSharedWorld {
    if(worldOwnsROM()) { auto *p=rom+GameHostOffset+64;uint32_t lease=word(p+8);if(lease) put32(p+8,lease-1); }
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
    if(armed||inviteActive||!fieldInterruptionReady()) return NO;
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
+ (BOOL)verifyBattleReady {
    verifiedROM=nullptr;
    if(armed||!fieldInterruptionReady()||workRAM[0x24029]==0||workRAM[0x24029]>6) return NO;
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
        @"tradeOpened":@(tradeOpened),@"tradeCount":@(tradeCount)};
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
    memcpy(soulOriginalGet,rom+0x3FBE8,8); memcpy(soulOriginalSet,rom+0x4037C,8);
    memcpy(rom+SoulStart,BoundSoulCode,sizeof(BoundSoulCode));
    uint8_t *thunks[]={soulGetThunk,soulSetThunk};
    const uint32_t targets[]={BoundSoulGetAddress,BoundSoulSetAddress};
    const size_t offsets[]={0x3FBE8,0x4037C};
    for(unsigned i=0;i<2;i++) {
        auto *t=thunks[i]; t[0]=0; t[1]=0x4B; t[2]=0x18; t[3]=0x47; // ldr r3; bx r3 (r0-r2 arguments preserved)
        put32(t+4,targets[i]); memcpy(rom+offsets[i],t,8);
    }
    put32(rom+SoulPolicy,0x314C5342); put32(rom+SoulPolicy+4,0);
    memset(internalRAM+0x4500,0,12+32*8); soulROM=rom; return YES;
}
+ (BOOL)setSoulLinkDenied:(NSData *)identities {
    if(!soulHooked() || identities.length%8 || identities.length>2048*8) return NO;
    memcpy(rom+SoulPolicy+8,identities.bytes,identities.length);
    put32(rom+SoulPolicy+4,unsigned(identities.length/8)); return YES;
}
+ (NSDictionary<NSString *,id> *)soulLinkSnapshot {
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
    bool overflow=false;
    if(soulHooked() && word(internalRAM+0x4500)==0x314C5342) {
        unsigned count=word(internalRAM+0x4504);
        overflow=count>32 || word(internalRAM+0x4508)!=0;
        if(count<=32) [faints appendBytes:internalRAM+0x450C length:count*8];
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
             @"boxes":boxes,@"faints":faints,@"battleFaints":active,@"overflow":@(overflow)};
}
+ (void)acknowledgeSoulLinkFaints {
    if(soulHooked()&&word(internalRAM+0x4500)==0x314C5342) { put32(internalRAM+0x4504,0); put32(internalRAM+0x4508,0); }
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
        if(n<=4) for(unsigned i=0;i<n;i++) {
            auto *b=workRAM+0x23BE4+i*88;
            uint8_t identity[8]; memcpy(identity,b+0x48,4); memcpy(identity+4,b+0x54,4);
            // Native attack-canceler rejects a zero-HP attacker. Also cover
            // already-active Pokemon when the partner faints during a turn.
            if(half(b+0x2C)>0 && denied(identity)) put16(b+0x28,0);
        }
    }
}
+ (void)closeSoulLink {
    if(soulHooked()) {
        memcpy(rom+0x3FBE8,soulOriginalGet,8); memcpy(rom+0x4037C,soulOriginalSet,8);
        // A paused CPU can still have a shim return address on its stack.
        // Leave the original tiny body resident and inert until ROM unload;
        // restore entry bytes and clear policy instead of erasing live code.
        put32(rom+SoulPolicy+4,0);
    }
}

#if DEBUG && TARGET_OS_SIMULATOR
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
+ (BOOL)qaStopMapMusicRetainingTracks {
    if(!ownsROMUI()||!overworld()) return NO;
    // Reproduce the MP2K state observed in the affected Mac checkpoint.
    // The native door must handle stopped music without discarding track bits.
    const auto status=word(internalRAM+0x7304);
    if(!(status&0xFFFF)) return NO;
    put32(internalRAM+0x7304,status|0x80000000u);
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
