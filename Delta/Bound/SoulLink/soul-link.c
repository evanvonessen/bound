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
/* Per-owner durable encounter bits live outside state RAM. The receipt ring is
 * drained only after the host durably records its exact identity/source bytes.
 * 0x4620..0x47AC is disjoint from the faint ring and native link mailboxes. */
#define ACQUIRED ((volatile const u8 *)0x09FFE008)
struct Acquisition { u32 personality, trainer, source; };
struct Acquisitions { u32 magic, count, overflow; struct Acquisition rows[32]; };
#define ACQUISITIONS ((volatile struct Acquisitions *)0x03004620)
static u32 read32(const u8 *p) { return p[0]|(u32)p[1]<<8|(u32)p[2]<<16|(u32)p[3]<<24; }
static u16 read16(const u8 *p) { return p[0]|(u16)p[1]<<8; }
static unsigned encounterArea(void) { return ((u8 (*)(void))0x08056261)(); }
static unsigned ordinaryBattle(void) {
    u32 flags=*(volatile u32 *)0x02022B4C;
    /* Raids also set SCRIPTED_WILD_1. DYNAMAX wins before static exemption. */
    return (flags&0x40000000u) || !(flags&(0x2000u|0x20000u|0x40000u));
}
static unsigned spent(unsigned area) {
    if(POLICY->magic!=MAGIC || area>255) return 0;
    if(ACQUIRED[area/8]&(1u<<(area%8))) return 1;
    if(ACQUISITIONS->magic==MAGIC) {
        unsigned count=ACQUISITIONS->count;
        if(count>32 || ACQUISITIONS->overflow) return 1;
        for(unsigned i=0;i<count;i++) {
            u32 source=ACQUISITIONS->rows[i].source;
            if(((source&255)==0 && (source>>8)==area) || ((source&255)==2 && area==0)) return 1;
        }
    }
    return 0;
}
void BoundSoulPrizeCheck(void) { *(volatile u16 *)0x020370D0=(u16)spent(0); }
/* Gate the exact RR Pokémon clerk's script entry, including cached object
 * templates restored from saves. Replay its displaced lock/face/loadword before
 * checking, then continue after those bytes for the first purchase. */
static const u8 prizeText[]={0xC9,0xE2,0xD9,0,0xE4,0xE6,0xDD,0xEE,0xD9,0,0xCA,0xC9,0xC5,0xBF,0xC7,0xC9,0xC8,0xFE,
    0xE4,0xD9,0xE6,0,0xCD,0xE3,0xE9,0xE0,0,0xC6,0xDD,0xE2,0xDF,0,0xE6,0xE9,0xE2,0xAD,0xFF};
const struct __attribute__((packed)) {
    u8 lock,face,load,index;const u8 *opening;
    u8 call;void (*check)(void);u8 compare;u16 variable,value;u8 branch,condition;const u8 *original;
    u8 message;const u8 *text;u8 wait,button,release,end;
} BoundSoulPrizeScript={0x69,0x5A,0x0F,0,(const u8 *)0x09102A63,
    0x23,BoundSoulPrizeCheck,0x21,0x800D,0,0x06,1,(const u8 *)0x09045765,
    0x67,prizeText,0x66,0x6D,0x6B,0x02};
/* Exact RR CantCatchBecauseFlag entry, used by both the bag and last-ball
 * shortcut. Preserve BOTH original native flag checks before our own rule. */
u32 BoundSoulCatchBlocked(void) {
    u8 (*flag)(u16)=(u8 (*)(u16))0x0806E6D1;
    if(flag(0x902) || flag(0x904)) return 1;
    return ordinaryBattle() && spent(encounterArea());
}
u32 BoundSoulGive(u8 *mon) {
    unsigned active=POLICY->magic==MAGIC;
    unsigned area=0,kind=1;
    if(active) {
        area=encounterArea();
        if((mon[19]&4) || (mon[75]&0x40)) kind=3;
        else if((u32)mon>=0x0202402Cu && (u32)mon<0x02024284u && (*(volatile u8 *)0x03003529&2))
            kind=ordinaryBattle()?0:4;
        else {
            const u8 *save=*(const u8 * volatile *)0x03005008;
            if((u32)save>=0x02000000u && (u32)save<=0x0203D000u && save[4]==10 && save[5]==15) kind=2;
        }
        if((kind==0 && spent(area)) || (kind==2 && spent(0))) return 2;
        if(ACQUISITIONS->magic!=MAGIC) {
            ACQUISITIONS->count=ACQUISITIONS->overflow=0;ACQUISITIONS->magic=MAGIC;
        }
        /* Never create an unjournalled acquisition when receipt capacity ends. */
        if(ACQUISITIONS->count>=32 || ACQUISITIONS->overflow) { ACQUISITIONS->overflow=1;return 2; }
    }
    u32 result=((u8 (*)(u8 *))0x0907D791)(mon);
    if(active && POLICY->magic==MAGIC && result<=1) {
        unsigned n=ACQUISITIONS->count;
        ACQUISITIONS->rows[n].personality=read32(mon);
        ACQUISITIONS->rows[n].trainer=read32(mon+4);
        ACQUISITIONS->rows[n].source=kind|(area<<8);
        ACQUISITIONS->count=n+1;
    }
    return result;
}
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
        if(read16(data)==0 && read16(mon+86)>0 && read16(mon+88)>0
           && !(mon[19]&4) && !(mon[75]&0x40)) {
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
    if(mode==2) {
        u16 healthy=read16(mon+88),zero=0;
        mon[19]|=4; mon[75]|=0x40; mon[70]&=0x80; mon[69]=253;
        ((void (*)(u8 *,int,const void *))0x0804037D)(mon,57,&healthy);
        ((void (*)(u8 *,int,const void *))0x0804037D)(mon,57,&zero);
    }
    if(mode==3) {
        for(unsigned slot=1;slot<6;slot++) for(i=0;i<100;i++) party[slot*100+i]=party[i];
        *(volatile u8 *)0x02024029=6;
        mon[69]++; // Different named area: native GiveMonToPlayer sends it to PC.
    }
    result[0]=0;
    result[1]=((u8 (*)(u8 *))0x08040B15)(mon);
    result[2]=mon[69]; result[3]=mode==2 ? (EVENTS->magic==MAGIC ? EVENTS->count:0):(mon[19]&4)!=0;
    result[0]=0x31415153;
}
#endif
