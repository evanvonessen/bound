/* Bound's original ARM7TDMI enforcement shim, exact RR 4.1 ABI only.
 * Policy resides in the loaded ROM's verified unused tail, outside save states.
 * No cartridge file or Pokemon identity/checksum is modified. */
typedef unsigned char u8;
typedef unsigned short u16;
typedef unsigned int u32;
struct Identity { u32 personality, trainer; };
struct Policy { u32 magic, count; struct Identity denied[2048]; };
#define POLICY ((volatile const struct Policy *)0x09FFA000)
struct Events { u32 magic, count, overflow; struct Identity fainted[32]; };
#define EVENTS ((volatile struct Events *)0x03004500)
#define MAGIC 0x314C5342u
static u32 read32(const u8 *p) { return p[0]|(u32)p[1]<<8|(u32)p[2]<<16|(u32)p[3]<<24; }
static u16 read16(const u8 *p) { return p[0]|(u16)p[1]<<8; }
static int denied(const u8 *mon) {
    unsigned lo=0,hi=POLICY->count; u32 p,t;
    if(POLICY->magic!=MAGIC || hi>2048) return 0;
    p=read32(mon); t=read32(mon+4);
    while(lo<hi) {
        unsigned mid=(lo+hi)/2; u32 a=POLICY->denied[mid].personality,b=POLICY->denied[mid].trainer;
        if(a==p && b==t) return 1;
        if(a<p || (a==p && b<t)) lo=mid+1; else hi=mid;
    }
    return 0;
}
/* Replay the displaced instructions; both continuations overwrite r1. */
__attribute__((naked,noinline)) u32 BoundSoulOriginalGet(const u8 *mon,int field,void *data) {
    __asm__ volatile("push {r4,lr}\nmov r4,r0\nmov r3,r1\nmov r0,r3\nldr r1,=0x0803FBF1\nbx r1\n");
}
__attribute__((naked,noinline)) void BoundSoulOriginalSet(u8 *mon,int field,const void *data) {
    __asm__ volatile("push {r4,lr}\nmov r3,r0\nmov r4,r1\nmov r0,r4\nldr r1,=0x08040385\nbx r1\n");
}
u32 BoundSoulGet(const u8 *mon,int field,void *data) {
    if(field==57 && denied(mon)) return 0;
    return BoundSoulOriginalGet(mon,field,data);
}
void BoundSoulSet(u8 *mon,int field,const void *data) {
    u16 zero=0;
    if(field==57) {
        /* Native zero-HP writes are latched even if a raid/Pokemon Center heals
         * again in the same frame. Only owned identities are admitted by host. */
        if(read16(data)==0 && read16(mon+86)>0 && read16(mon+88)>0) {
            if(EVENTS->magic!=MAGIC) { EVENTS->count=EVENTS->overflow=0; EVENTS->magic=MAGIC; }
            unsigned i=EVENTS->count;
            if(i<32) { EVENTS->fainted[i].personality=read32(mon); EVENTS->fainted[i].trainer=read32(mon+4); EVENTS->count=i+1; }
            else EVENTS->overflow=1;
        }
        if(denied(mon)) data=&zero;
    }
    BoundSoulOriginalSet(mon,field,data);
}
#ifdef BOUND_SOUL_QA
/* Simulator fixture only; never compiled into the Release shim. */
void BoundSoulQA(void) {
    u8 *mon=(u8 *)0x02024284;
    volatile u32 *result=(volatile u32 *)0x03004D00;
    u16 zero=0,healthy=read16(mon+88);
    result[0]=0;
    result[1]=((u32 (*)(u8 *,int,void *))0x0803FBE9)(mon,11,0);
    ((void (*)(u8 *,int,const void *))0x0804037D)(mon,57,&zero);
    ((void (*)(u8 *,int,const void *))0x0804037D)(mon,57,&healthy);
    result[2]=((u32 (*)(u8 *,int,void *))0x0803FBE9)(mon,57,0);
    result[3]=read16(mon+86);
    result[0]=0x31415153;
}
#endif
#ifdef BOUND_SOUL_QA
void BoundSoulQACatch(void) {
    u8 *party=(u8 *)0x02024284;
    volatile u32 *result=(volatile u32 *)0x03004D00;
    unsigned mode=*(volatile u32 *)0x03004D20,i;
    u8 mon[100];
    for(i=0;i<100;i++) mon[i]=party[i];
    *(u32 *)mon=0xD00D0000u+mode;
    mon[19]=(mon[19]|2)&(u8)~4; mon[75]&=(u8)~0x40;
    if(mode==2) { mon[19]|=4; mon[75]|=0x40; mon[70]&=0x80; mon[69]=253; }
    if(mode==3) {
        for(unsigned slot=1;slot<6;slot++) for(i=0;i<100;i++) party[slot*100+i]=party[i];
        *(volatile u8 *)0x02024029=6;
        mon[69]++; // Different named area: native GiveMonToPlayer sends it to PC.
    }
    result[0]=0;
    result[1]=((u8 (*)(u8 *))0x08040B15)(mon);
    result[2]=mon[69]; result[3]=(mon[19]&4)!=0;
    result[0]=0x31415153;
}
#endif
