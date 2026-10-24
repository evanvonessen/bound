// Exact-profile field scripts. Native windows/tasks own drawing and selection;
// the host reads a result only after releaseall/end restores the overworld.
namespace {
constexpr size_t InviteStart=0x1FFFD00,InviteSize=0x300,InviteMenuSlot=0x3E04B0,InviteResult=0x44C6;
uint8_t *inviteROM=nullptr;
bool inviteActive=false,inviteCancelling=false,inviteBHeld=false;
unsigned inviteMode=0,inviteFrames=0;
uint8_t inviteMenuOriginal[8],inviteScratchOriginal[2];
int inviteResult=-1;
bool inviteOwnsROM() { return inviteActive&&inviteROM==rom; }
void restoreInvite() {
    if(inviteBHeld) [[GBAEmulatorBridge sharedBridge] deactivateInput:2 playerIndex:0];
    if(inviteROM==rom&&rom) {
        if(inviteMode==0) memcpy(rom+InviteMenuSlot,inviteMenuOriginal,8);
        memset(rom+InviteStart,0xFF,InviteSize);
        if(internalRAM) memcpy(internalRAM+InviteResult,inviteScratchOriginal,2);
    }
    inviteActive=inviteBHeld=false;
}
bool inviteMenuReady() {
    if(!inviteOwnsROM()||!internalRAM) return false;
    for(unsigned i=0;i<16;i++) {
        auto *task=internalRAM+0x5090+i*40;
        if(task[4]&&word(task)==(inviteMode==0?0x0809CC99:0x0809CE55)) return true;
    }
    // Both waitmessage and waitbuttonpress use native-script mode. Only the
    // latter has advanced past byte 7; reporting readiness while text is still
    // printing consumes the first A/B press without closing the prompt.
    return inviteMode==2&&internalRAM[0xEB1]==2&&word(internalRAM+0xEB8)==0x08000000+InviteStart+8;
}
uint8_t inviteCharacter(unichar c) {
    if(c>='A'&&c<='Z') return 0xBB+c-'A';
    if(c>='a'&&c<='z') return 0xD5+c-'a';
    if(c>='0'&&c<='9') return 0xA1+c-'0';
    switch(c) {
        case '\n':return 0xFE; case '.':return 0xAD; case ',':return 0xB8;
        case '?':return 0xAC; case '!':return 0xAB; case ':':return 0xF0;
        case 0xE9:return 0x1B; case '/':return 0xBA; case '-':return 0xAE; case '\'':return 0xB4;
        default:return 0;
    }
}
void inviteText(size_t offset,NSString *text) {
    NSUInteger count=MIN(text.length,127);
    for(NSUInteger i=0;i<count;i++) rom[offset+i]=inviteCharacter([text characterAtIndex:i]);
    rom[offset+count]=0xFF;
}
}
