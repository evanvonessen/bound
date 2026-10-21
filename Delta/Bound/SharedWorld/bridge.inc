#include "BoundSharedWorldCode.h"
namespace {
constexpr size_t WorldStart=0x1FF6000,WorldEnd=0x1FF8000,WorldPolicy=0x1FF7000;
constexpr size_t WorldTrainerSlot=0x15F9B4+0x5C*4,WorldCheckSlot=0x15F9B4+0x60*4;
uint8_t *worldROM=nullptr;
uint8_t worldFlagOriginal[8],worldCollisionOriginal[12],worldFlagThunk[8],worldCollisionThunk[12];
uint32_t worldTrainerOriginal=0,worldCheckOriginal=0;
bool worldOwnsROM() {
    return rom&&worldROM==rom && memcmp(rom+WorldStart,BoundSharedWorldCode,sizeof(BoundSharedWorldCode))==0
        && memcmp(rom+0x6E6D0,worldFlagThunk,8)==0 && memcmp(rom+0x636AC,worldCollisionThunk,12)==0
        && word(rom+WorldTrainerSlot)==BoundWorldTrainerAddress && word(rom+WorldCheckSlot)==BoundWorldCheckTrainerAddress;
}
void worldRestoreBase(uint8_t *p) {
    if(!worldOwnsROM()) return;
    memcpy(p+0x6E6D0,worldFlagOriginal,8); memcpy(p+0x636AC,worldCollisionOriginal,12);
    put32(p+WorldTrainerSlot,worldTrainerOriginal); put32(p+WorldCheckSlot,worldCheckOriginal);
    memset(p+WorldStart,0xFF,WorldEnd-WorldStart);
}
uint8_t *worldSave() {
    if(!internalRAM||!workRAM) return nullptr;
    uint32_t address=word(internalRAM+0x5008);
    return address>=0x02000000&&address<=0x0203F000 ? workRAM+address-0x02000000 : nullptr;
}
}
