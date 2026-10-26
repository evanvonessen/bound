// Disposable fixture preparation only. The caller owns a paused core or its
// completed-frame callback. Native script opcodes perform every guest effect.
#if DEBUG && TARGET_OS_SIMULATOR
namespace {
constexpr uint32_t FixtureScriptAddress=0x03004280;
constexpr size_t FixtureScriptSize=128,FixtureHostOffset=0x1FF5000,FixtureHostSize=2048;
// BoundMultiplayerSetupOptions.debug and the reviewed point01 native setup:
// common cheats enabled (byte10), nickname prompts disabled (byte11).
constexpr uint8_t FixtureSettings[]={5,1,0,0,0,0,0,0,0,0,1,0,0xC1,0xD5,0xE6,0xED,
    0xFF,0xFF,0xFF,0xFF,1,1,0,0,0,0,0,0,0,0,0,0};
enum FixtureOperation : unsigned { FixtureMankey=1,FixtureCandy=2,FixturePikachu=3 };
struct FixtureOperationOwner {
    uint8_t *cartridge=nullptr,*ram=nullptr;
    uint8_t backup[FixtureScriptSize]{},script[FixtureScriptSize]{};
    uint8_t partyBytes[600]{};
    uint32_t trainer=0;
    unsigned operation=0,completed=0,partyCountBefore=0,starterLevel=0;
    bool active=false,success=false,conflict=false;
};
FixtureOperationOwner fixtureOperation;

bool fixtureExactCartridge() {
    if(!ownsROMUI()||!workRAM||!internalRAM||romUIProfile!=&MultiRedCurrentProfile
       ||romUIProfile->uiHostOffset!=FixtureHostOffset||romUIProfile->uiHostSize!=FixtureHostSize) return false;
    // The admitted setup mailbox is the only mutable ROM data allowed here.
    // Its pristine bytes are zero in the candidate 02f97 cartridge. No executable
    // injection, other host port, or alternative cartridge is normalized.
    const uint8_t zero[FixtureHostSize]={};uint8_t digest[32];CC_SHA256_CTX context;
    CC_SHA256_Init(&context);CC_SHA256_Update(&context,rom,FixtureHostOffset);
    CC_SHA256_Update(&context,zero,sizeof(zero));
    CC_SHA256_Update(&context,rom+FixtureHostOffset+FixtureHostSize,
                     0x2000000-FixtureHostOffset-FixtureHostSize);CC_SHA256_Final(digest,&context);
    const uint8_t expected[]={0x02,0xf9,0x7f,0xfa,0x88,0xf7,0x10,0x15,0xd2,0xda,0x5d,0xf1,0x14,0xc0,0xbf,0x48,
        0xd7,0xc8,0x0f,0x37,0xf6,0x4d,0x10,0x07,0x5a,0x81,0xfe,0xf2,0xdc,0x6d,0x8a,0x79};
    return memcmp(digest,expected,sizeof(expected))==0
        &&word(rom+0x15F9B4+0x44*4)==0x0806A611
        &&word(rom+0x15F9B4+0x47*4)==0x0806A6E5
        &&word(rom+0x15F9B4+0x79*4)==0x0806BFD1;
}
bool fixtureIdleOwner() {
    if(armed||inviteActive||cooperativeCable||worldOwnsROM()||soulHooked()||!fieldInterruptionReady()) return false;
    auto &fence=soulFrameFence();std::lock_guard<std::mutex> lock(fence.lock);
    if(!fence.owner.empty()) return false;
    const auto *request=workRAM+0x800;
    return word(request)==0x31525552&&!BOUND_SDK_UNCOMMITTED_SEQUENCE(word(request+8))&&word(request+12)==0
        &&(word(request+80)&0x67)==0x61&&!half(internalRAM+0x311C)
        &&!(workRAM[0x37ABF]&0x80)&&((half(workRAM+0x37ABC)>>6)&31)<16&&!workRAM[0x3707B];
}
bool fixtureNativeTeam(unsigned count,uint32_t trainer,unsigned starterLevel) {
    if(workRAM[0x24029]!=count) return false;
    const unsigned species[]={trainer==0x12345678?4u:7u,56u,25u};
    for(unsigned index=0;index<count;index++) {
        const auto *mon=workRAM+0x24284+index*100;
        if(word(mon+4)!=trainer||half(mon+32)!=species[index]||half(mon+34)
           ||!(mon[19]&2)||(mon[19]&5)||mon[84]!=(index?8:starterLevel)
           ||!half(mon+86)||half(mon+86)!=half(mon+88)) return false;
    }
    return true;
}
NSDictionary *fixtureOperationStatus() {
    return @{@"active":@(fixtureOperation.active),@"success":@(fixtureOperation.success),
        @"conflict":@(fixtureOperation.conflict),@"operation":@(fixtureOperation.operation),
        @"completedMask":@(fixtureOperation.completed)};
}
}

@implementation BoundVBABattleBridge (DebugFixtureOperations)
+ (NSDictionary<NSString *,id> *)qaDebugFixturePreflight {
    const bool exact=fixtureExactCartridge();
    return @{@"exactCartridge":@(exact),@"idleUnownedField":@(exact&&fixtureIdleOwner()),
        @"canonicalSettings":@(exact&&memcmp(workRAM+0x800+40,FixtureSettings,sizeof(FixtureSettings))==0),
        @"partyCount":@(workRAM?workRAM[0x24029]:0)};
}
+ (BOOL)qaResetDebugFixtureOperations {
    if(fixtureOperation.active) return NO;
    fixtureOperation=FixtureOperationOwner{};return YES;
}
+ (BOOL)qaAdmitRoute1FixtureContinuation {
    // Fresh-core restore discards host-only script bookkeeping. Reconstruct
    // that bookkeeping only for the fixed, independently audited Route1 basis.
    // This method performs no guest write and cannot grant an item or Pokémon.
    if(fixtureOperation.active||fixtureOperation.completed||!fixtureExactCartridge()||!fixtureIdleOwner()
       ||memcmp(workRAM+0x828,FixtureSettings,sizeof(FixtureSettings))) return NO;
    const uint32_t save1=word(internalRAM+0x5008),save2=word(internalRAM+0x500C);
    if(save1<0x02000000||save1>0x0203C000||save2<0x02000000||save2>0x0203F000) return NO;
    const auto *save=workRAM+save1-0x02000000;
    const uint32_t trainer=word(workRAM+save2-0x02000000+10);
    if((trainer!=0x12345678&&trainer!=0x87654321)||save[4]!=3||save[5]!=19
       ||save[0xEE0+0x820/8]||memcmp(workRAM+0x36DFC,rom+0x35082C,28)
       ||!fixtureNativeTeam(2,trainer,5)||workRAM[0x24284+69]!=157||workRAM[0x24284+100+69]!=101) return NO;
    const uint32_t items=word(workRAM+0x3988C);const unsigned count=half(workRAM+0x39890);
    if(items<0x02000000||count>1024||items+count*4>0x02040000) return NO;
    unsigned candies=0;
    for(unsigned index=0;index<count;index++) {
        const auto *item=workRAM+items-0x02000000+index*4;
        if(half(item)==68) candies+=half(item+2);
    }
    if(candies!=21) return NO;
    fixtureOperation.cartridge=rom;fixtureOperation.ram=workRAM;
    fixtureOperation.completed=(1u<<FixtureMankey)|(1u<<FixtureCandy);
    return YES;
}
+ (BOOL)qaBeginDebugFixtureOperation:(NSUInteger)operation {
    if(operation<FixtureMankey||operation>FixturePikachu||fixtureOperation.active
       ||!fixtureExactCartridge()||!fixtureIdleOwner()) return NO;
    if(fixtureOperation.cartridge&&(fixtureOperation.cartridge!=rom||fixtureOperation.ram!=workRAM)) return NO;
    const unsigned bit=1u<<operation;
    if(fixtureOperation.completed&bit) return NO;
    const uint32_t save1=word(internalRAM+0x5008),save2=word(internalRAM+0x500C);
    if(save1<0x02000000||save1>0x0203C000||save2<0x02000000||save2>0x0203F000) return NO;
    const auto *save=workRAM+save1-0x02000000;
    const uint32_t trainer=word(workRAM+save2-0x02000000+10);
    if(trainer!=0x12345678&&trainer!=0x87654321) return NO;
    if(memcmp(workRAM+0x800+40,FixtureSettings,sizeof(FixtureSettings))) return NO;
    // Verified native badge storage: all eight pre-Brock badges remain clear.
    // Fixed level-eight gifts stay below the verified stage-zero native cap15.
    if(save[0xEE0+0x820/8]||save[4]!=3||save[5]!=(operation==FixturePikachu?20:19)) return NO;
    // Save coordinates alone do not establish a loaded native map. Require
    // its exact layout/events/scripts and acquisition-area header as well.
    const size_t headerOffset=operation==FixturePikachu?0x350848:0x35082C;
    if(memcmp(workRAM+0x36DFC,rom+headerOffset,28)) return NO;
    if(operation==FixtureMankey) {
        if(fixtureOperation.completed||!fixtureNativeTeam(1,trainer,5)) return NO;
    } else if(operation==FixtureCandy) {
        if(fixtureOperation.completed!=(1u<<FixtureMankey)||!fixtureNativeTeam(2,trainer,5)) return NO;
    } else if(fixtureOperation.completed!=((1u<<FixtureMankey)|(1u<<FixtureCandy))
              ||!fixtureNativeTeam(2,trainer,8)) return NO;
    uint8_t script[FixtureScriptSize]={};size_t n=0;
    auto byte=[&](uint8_t value){script[n++]=value;};
    auto halfword=[&](unsigned value){put16(script+n,value);n+=2;};
    auto address=[&](uint32_t value){put32(script+n,value);n+=4;};
    byte(0x69); // Native lockall, including NPC motion completion.
    if(operation==FixtureCandy) {
        byte(0x47);halfword(68);halfword(1); // Native checkitem Rare Candy.
        byte(0x21);halfword(0x800D);halfword(1);
        byte(0x06);byte(1);const size_t duplicate=n;address(0);
        byte(0x44);halfword(68);halfword(21); // Three starter levels, then18 later.
        byte(0x6C);byte(0x02);
        put32(script+duplicate,FixtureScriptAddress+uint32_t(n));
        byte(0x16);halfword(0x800D);halfword(0); // Duplicate is a failed grant.
    } else {
        byte(0x79);halfword(operation==FixtureMankey?56:25);byte(8);halfword(0);
        address(0);address(0);byte(0); // Native personality, OT, moves and stats.
    }
    byte(0x6C);byte(0x02);
    if(n>sizeof(script)||word(internalRAM+0xF0C)!=0x0815F9B4||word(internalRAM+0xF10)!=0x0815FD08) return NO;
    fixtureOperation.cartridge=rom;fixtureOperation.ram=workRAM;
    fixtureOperation.operation=unsigned(operation);fixtureOperation.partyCountBefore=workRAM[0x24029];
    fixtureOperation.trainer=trainer;fixtureOperation.starterLevel=workRAM[0x24284+84];
    memcpy(fixtureOperation.partyBytes,workRAM+0x24284,sizeof(fixtureOperation.partyBytes));
    fixtureOperation.active=true;fixtureOperation.success=fixtureOperation.conflict=false;
    memcpy(fixtureOperation.backup,internalRAM+0x4280,FixtureScriptSize);
    memcpy(fixtureOperation.script,script,FixtureScriptSize);
    memcpy(internalRAM+0x4280,script,FixtureScriptSize);
    // Exact native ScriptContext setup, as used by the existing field bridge.
    // These are control/scratch bytes only; no party, story, bag or outcome write.
    memset(internalRAM+0xEB0,0,0x74);internalRAM[0xEB1]=1;
    put32(internalRAM+0xEB8,FixtureScriptAddress);
    put32(internalRAM+0xF0C,0x0815F9B4);put32(internalRAM+0xF10,0x0815FD08);
    internalRAM[0xEA8]=0;internalRAM[0xF9C]=1;
    return YES;
}
+ (NSDictionary<NSString *,id> *)qaAdvanceDebugFixtureOperation {
    if(!fixtureOperation.active) return fixtureOperationStatus();
    if(fixtureOperation.cartridge!=rom||fixtureOperation.ram!=workRAM||!ownsROMUI()||!internalRAM
       ||memcmp(internalRAM+0x4280,fixtureOperation.script,FixtureScriptSize)) {
        fixtureOperation.conflict=true;return fixtureOperationStatus();
    }
    if(!overworld()||!fieldTextIdle()||internalRAM[0xEB1]!=0) return fixtureOperationStatus();
    const unsigned operation=fixtureOperation.operation;
    const unsigned expectedCount=fixtureOperation.partyCountBefore+(operation==FixtureCandy?0:1);
    const bool success=half(workRAM+0x370D0)==(operation==FixtureCandy?1:0)
        &&fixtureNativeTeam(expectedCount,fixtureOperation.trainer,fixtureOperation.starterLevel)
        &&memcmp(workRAM+0x24284,fixtureOperation.partyBytes,fixtureOperation.partyCountBefore*100)==0;
    memcpy(internalRAM+0x4280,fixtureOperation.backup,FixtureScriptSize);
    fixtureOperation.active=false;fixtureOperation.success=success;
    if(success) fixtureOperation.completed|=1u<<operation;
    return fixtureOperationStatus();
}
@end
#endif
