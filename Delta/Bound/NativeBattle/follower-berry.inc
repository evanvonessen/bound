// Exact-profile target adapter for RR's existing follower feeding branch.
// The game continues to own the Oran choice, bag check/removal, YES/NO prompt,
// messages, sound, friendship tiers/cap and script cleanup. Only the native
// effect routine's target binding and its local-object animation are scoped.
namespace {
constexpr size_t BerryScript=0x1FFFC00,BerrySize=0x100,BerryCount=0x44C4;
uint8_t *berryROM=nullptr;
bool berryActive=false,berryCancelling=false,berryBHeld=false;
unsigned berryFrames=0;
uint8_t berryEnemy[100],berryString[20],berryCountOriginal=0;
uint8_t berryCountPointer[4],berryPartyPointer[4],berrySelection[2],berryAnimation[4];
NSData *berryBagBefore=nil,*berryAfter=nil;
bool berryConsumed=false;
bool berryOwnsROM() { return berryActive&&berryROM==rom; }
void berryRestore() {
    if(berryBHeld) [[GBAEmulatorBridge sharedBridge] deactivateInput:2 playerIndex:0];
    if(berryROM==rom&&rom) {
        memcpy(rom+0x10996FC,berryCountPointer,4);memcpy(rom+0x1099700,berryPartyPointer,4);
        memcpy(rom+0x10996AC,berrySelection,2);memcpy(rom+0x1049C81,berryAnimation,4);
        memset(rom+BerryScript,0xFF,BerrySize);
        if(workRAM) {memcpy(workRAM+0x2402C,berryEnemy,100);memcpy(workRAM+0x21CE4,berryString,20);}
        if(internalRAM) internalRAM[BerryCount]=berryCountOriginal;
    }
    berryActive=berryBHeld=berryCancelling=false;berryROM=nullptr;
}
bool berryMon(const uint8_t *mon) {
    return (mon[19]&7)==2&&half(mon+32)>0&&half(mon+32)<=1381&&half(mon+86)>0;
}
}
