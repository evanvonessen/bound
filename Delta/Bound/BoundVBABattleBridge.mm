#import "BoundVBABattleBridge.h"
#import <DeltaCore/DeltaCore.h>
#import <DeltaCore/DeltaCore-Swift.h>
#import <GBADeltaCore/GBADeltaCore.h>
#import <CommonCrypto/CommonDigest.h>
#include <cstdint>
#include <cstring>
#include "NativeBattle/BoundBattleEntryCode.h"

extern uint8_t *rom,*workRAM,*internalRAM,*ioMem;
namespace {
constexpr size_t RegionOffset=0x1FFF800,RegionSize=0x800;
constexpr uint32_t ScriptAddress=0x09FFFC00,MailboxMagic=0x314D4642;
constexpr size_t Mailbox=0x4030;
struct Hook { size_t offset; uint32_t target; uint8_t original[8],thunk[8]; };
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
    {0x56854,BoundBattleTradeReturnAddress}
};
uint8_t *verifiedROM=nullptr,*patchedROM=nullptr;
bool armed=false,installed=false,failed=false,syntheticHeld=false;
unsigned role=0,preparationFrames=0,tradeCount=0;
bool tradeMode=false,tradeOpened=false,tradeScene=false;
bool usesHook(size_t index) { return tradeMode ? index>=2 : index<9; }
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
bool mailboxReady() { return installed&&internalRAM&&word(internalRAM+Mailbox)==MailboxMagic; }
NSMutableArray<NSNumber *> *partyHP(size_t offset,unsigned count) {
    NSMutableArray<NSNumber *> *values=[NSMutableArray array];
    for(unsigned i=0;i<count&&i<6;i++) [values addObject:@(half(workRAM+offset+i*100+86))];
    return values;
}
}
@implementation BoundVBABattleBridge
+ (BOOL)verifyBattleReady {
    verifiedROM=nullptr;
    if(armed||!overworld()||workRAM[0x24029]==0||workRAM[0x24029]>6) return NO;
    const uint8_t expected[32]={0x68,0x92,0x99,0x66,0x4a,0x95,0x4c,0x12,0xda,0xd6,0x6e,0x03,0xc2,0xd1,0x84,0x46,
        0xb3,0x48,0xcb,0x31,0xbd,0x98,0xb3,0x95,0xc8,0x7b,0x9b,0x51,0x4b,0x28,0x80,0x66};
    uint8_t digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(rom,0x2000000,digest);
    if(memcmp(digest,expected,32)!=0) return NO;
    for(size_t i=0;i<RegionSize;i++) if(rom[RegionOffset+i]!=0xFF) return NO;
    if(word(internalRAM+0xF0C)!=0x0815F9B4||word(internalRAM+0xF10)!=0x0815FD08) return NO;
    verifiedROM=rom; failed=false; return YES;
}
+ (BOOL)prepareBattleForPlayer:(NSUInteger)player {
    if(armed||verifiedROM!=rom||!overworld()||player>1) return NO;
    role=unsigned(player); tradeMode=false; armed=true; return YES;
}
+ (BOOL)prepareTradeForPlayer:(NSUInteger)player {
    if (![self prepareBattleForPlayer:player]) return NO;
    tradeMode=true; tradeOpened=tradeScene=false; tradeCount=0;
    return YES;
}
+ (BOOL)installBattleForPlayer:(NSUInteger)player {
    if(!armed||installed||verifiedROM!=rom||!overworld()||player!=role) { failed=true; return NO; }
    memcpy(rom+RegionOffset,BoundBattleEntryCode,sizeof(BoundBattleEntryCode));
    rom[0x1FFFBF0]=uint8_t(role);
    for(size_t index=0;index<sizeof(hooks)/sizeof(hooks[0]);index++) {
        if(!usesHook(index)) continue;
        auto &hook=hooks[index];
        memcpy(hook.original,rom+hook.offset,8);
        hook.thunk[0]=0; hook.thunk[1]=0x48; hook.thunk[2]=0; hook.thunk[3]=0x47;
        put32(hook.thunk+4,hook.target); memcpy(rom+hook.offset,hook.thunk,8);
    }
    patchedROM=rom;
    uint8_t script[128]; size_t n = 0;
    auto byte = [&](uint8_t v) { script[n++] = v; };
    auto half = [&](uint16_t v) { byte(v); byte(v >> 8); };
    auto ptr = [&](uint32_t v) { for (int i=0;i<4;i++) byte(v >> (8*i)); };
    auto setvar = [&](uint16_t var, uint16_t value) { byte(0x16); half(var); half(value); };
    auto special = [&](uint16_t id) { byte(0x25); half(id); };
    setvar(0x8004,tradeMode?3:1); setvar(0x8005,static_cast<uint16_t>(player)); setvar(0x800D,0);
    // Native trade/save confirmation precedes the exchange. We never synthesize
    // A on a save prompt or trade menu; player consent uses normal controls.
    if(tradeMode) {
        special(35); byte(0x27);
        byte(0x21); half(0x800D); half(1);
        byte(0x06); byte(1); size_t savedPointer=n; ptr(0);
        byte(0x23); ptr(BoundBattleReturnAddress); byte(0x27); byte(0x02);
        put32(script+savedPointer,ScriptAddress+static_cast<uint32_t>(n));
    }
    special(tradeMode?29:28); byte(0x27); // Exact-profile native linkup.
    byte(0x21); half(0x800D); half(1);
    byte(0x06); byte(1); size_t successPointer=n; ptr(0); // equal -> native setup
    byte(0x23); ptr(BoundBattleReturnAddress); byte(0x27); byte(0x02);
    put32(script+successPointer, ScriptAddress+static_cast<uint32_t>(n));
    if(tradeMode) { special(34); byte(0x27); byte(0x02); }
    else {
        special(0); special(39); special(331); // Heal, SavePlayerParty, LoadPlayerBag.
        byte(0x23); ptr(BoundBattleStartAddress); byte(0x27); byte(0x02);
    }
    if(n>sizeof(script)) { failed=true; return NO; }
    memcpy(rom + (ScriptAddress - 0x08000000), script, n);
    // Exact bindings verified against the profile's ScriptContext_SetupScript.
    memset(internalRAM + 0xEB0,0,0x74);
    internalRAM[0xEB1] = 1;
    put32(internalRAM + 0xEB8,ScriptAddress);
    put32(internalRAM + 0xF0C,0x0815F9B4); put32(internalRAM + 0xF10,0x0815FD08);
    internalRAM[0xEA8]=0; internalRAM[0xF9C]=1;
    internalRAM[0xF9D]=0; internalRAM[0xF9E]=0; internalRAM[0xFA0]=0;
    memset(internalRAM+Mailbox,0,1176); networkRead=0;
    put32(internalRAM+Mailbox,MailboxMagic);
    preparationFrames=0; installed=true; return YES;
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
    if(installed&&!tradeMode&&!battle&&!returned&&!failed) {
        ++preparationFrames;
        if(preparationFrames%12==1) { [[GBAEmulatorBridge sharedBridge] activateInput:1 value:1 playerIndex:0]; syntheticHeld=true; }
        else if(preparationFrames%12==3) { [[GBAEmulatorBridge sharedBridge] deactivateInput:1 playerIndex:0]; syntheticHeld=false; }
    } else if(installed&&syntheticHeld) { [[GBAEmulatorBridge sharedBridge] deactivateInput:1 playerIndex:0]; syntheticHeld=false; }
    return @{@"error":@(failed),@"connected":@(armed),@"battle":@(battle),@"returned":@(returned),
        @"outcome":@(workRAM[0x23E8A]),@"flags":@(word(workRAM+0x22B4C)),@"callback":@(callback),
        @"scriptStatus":@(internalRAM[0xEA8]),@"scriptResult":@(half(workRAM+0x370D0)),
        @"playerHP":partyHP(0x24284,workRAM[0x24029]),@"enemyHP":partyHP(0x2402C,6),
        @"tradeOpened":@(tradeOpened),@"tradeCount":@(tradeCount)};
}
+ (void)close {
    if(armed||installed||syntheticHeld) [[GBAEmulatorBridge sharedBridge] deactivateInput:1 playerIndex:0];
    if(rom&&rom==patchedROM&&memcmp(rom+RegionOffset,BoundBattleEntryCode,sizeof(BoundBattleEntryCode))==0) {
        bool allOurs=true;
        for(size_t index=0;index<sizeof(hooks)/sizeof(hooks[0]);index++)
            if(usesHook(index)&&memcmp(rom+hooks[index].offset,hooks[index].thunk,8)!=0) allOurs=false;
        if(allOurs) {
            for(size_t index=0;index<sizeof(hooks)/sizeof(hooks[0]);index++)
                if(usesHook(index)) memcpy(rom+hooks[index].offset,hooks[index].original,8);
            memset(rom+RegionOffset,0xFF,RegionSize);
        }
    }
    armed=installed=failed=syntheticHeld=tradeMode=tradeOpened=tradeScene=false;
    tradeCount=0; patchedROM=verifiedROM=nullptr;
}
#if DEBUG && TARGET_OS_SIMULATOR
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
