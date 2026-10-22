/* Original Bound glue for the exact RR4.1 field ABI. No save writes.
 * Shared policy is outside save states; the ordinary game owns all progress. */
typedef unsigned char u8;
typedef unsigned short u16;
typedef unsigned int u32;
typedef signed short s16;
#define ROM_START 0x08000000u
#define ROM_END 0x0A000000u
struct Boulder { u8 id,elevation; s16 x,y; };
struct Policy { u32 magic,enabled,lease,ready; u8 group,number; u8 flags[800]; u8 count,pad; struct Boulder boulders[16]; };
#define POLICY ((volatile const struct Policy *)0x09FF7000)
#define MAGIC 0x31575042u
#define WAIT_SCRIPT ((u8 *)0x03004200)
#define IWRAM ((volatile u8 *)0x03000000)
#define OBJECTS ((const u8 *)0x02036E38)
static u32 word(const volatile u8 *p) { return p[0]|(u32)p[1]<<8|(u32)p[2]<<16|(u32)p[3]<<24; }
static u16 half(const volatile u8 *p) { return p[0]|(u16)p[1]<<8; }
static int romPointer(u32 p,u32 count) { return p>=ROM_START && p<=ROM_END-count; }
static const u8 *save(void) {
    u32 p=word(IWRAM+0x5008);
    return p>=0x02000000 && p<=0x0203F000 ? (const u8 *)p : (const u8 *)0;
}
static int enabled(void) { return POLICY->magic==MAGIC && POLICY->enabled && !(IWRAM[0x3529]&2); }
static int fresh(void) { return POLICY->ready && POLICY->lease; }
static int peerFlag(unsigned id) {
    const u8 *s=save();
    if(!fresh() || id>=0x1900) return 0;
    if(id<0x20 && (!s || s[4]!=POLICY->group || s[5]!=POLICY->number)) return 0;
    return (POLICY->flags[id>>3]>>(id&7))&1;
}
/* The displaced prologue contains no PC-relative instructions. r1 is about
 * to be overwritten by the original GetFlagAddr call. */
__attribute__((naked,noinline)) u32 BoundWorldOriginalFlag(unsigned id) {
    __asm__ volatile("push {r4,lr}\nlsl r0,r0,#16\nlsr r4,r0,#16\nmov r0,r4\nldr r1,=0x0806E6D9\nbx r1\n.ltorg\n");
}
u32 BoundWorldFlag(unsigned id) {
    u32 value=BoundWorldOriginalFlag(id);
    /* Badges gate native HM use and badge-checking world scripts. Battle
     * boosts and all other personal flags retain their native meaning. */
    if(value && enabled() && id>=0x820 && id<=0x827) return peerFlag(id);
    return value;
}
/* Four-argument entry saves/restores r3 in the installed 12-byte thunk. */
__attribute__((naked,noinline)) u32 BoundWorldCollisionEntry(const u8 *obj,s16 x,s16 y,u8 direction) {
    __asm__ volatile("pop {r3}\nb BoundWorldCollision\n");
}
__attribute__((naked,noinline)) u32 BoundWorldOriginalCollision(const u8 *obj,s16 x,s16 y,u8 direction) {
    __asm__ volatile("push {r4,r5,r6,r7,lr}\nmov r7,r10\nmov r6,r9\nmov r5,r8\npush {r5,r6,r7}\nmov r6,r0\nldr r4,=0x080636B9\nbx r4\n.ltorg\n");
}
static const u16 bridgeTrainers[]={0x6E,0x7B,0x5C,0x7A,0x90};
static int bridgePending(unsigned i) { return !BoundWorldOriginalFlag(0x500+bridgeTrainers[i]) || !peerFlag(0x500+bridgeTrainers[i]); }
static const u8 *templates(unsigned *count) {
    const u8 *header=(const u8 *)0x02036DFC;
    u32 events=word(header+4),objects;
    if(!romPointer(events,20)) return (const u8 *)0;
    *count=*(const u8 *)events;
    if(*count>64) return (const u8 *)0;
    objects=word((const u8 *)events+4);
    return romPointer(objects,*count*24) ? (const u8 *)objects : (const u8 *)0;
}
static int tileGate(const u8 *player,s16 x,s16 y,unsigned elevation) {
    const u8 *s=save(); unsigned count=0,i,j; const u8 *objects=templates(&count);
    if(!s) return 1;
    /* Entire bridge width, including stepping around a trainer's home tile.
     * A lagging player can approach/fight that trainer normally. */
    if(s[4]==3 && s[5]==43 && (!elevation || elevation==3) && x>=10 && x<=12) {
        for(i=0;i<5;i++) if(((y==31-3*(int)i) || ((s16)half(player+18)-7>=31-3*(int)i && y<31-3*(int)i)) && BoundWorldOriginalFlag(0x500+bridgeTrainers[i]) && !peerFlag(0x500+bridgeTrainers[i])) return 1;
    }
    for(i=0;objects && i<count;i++) {
        const u8 *o=objects+i*24; unsigned flag=half(o+20),level=o[8];
        if(level && elevation && level!=elevation) continue;
        /* Before a partner has entered this map, an already moved local
         * boulder may not silently open its original blocked tile. */
        if(o[1]==97 && (s[4]!=POLICY->group || s[5]!=POLICY->number)
           && (s16)half(o+4)==x && (s16)half(o+6)==y) {
            int stillHere=0;
            for(j=0;j<16;j++) { const u8 *live=OBJECTS+j*36;
                if((live[0]&1) && live[8]==o[0] && (s16)half(live+16)-7==x && (s16)half(live+18)-7==y) stillHere=1;
            }
            if(!stillHere) return 1;
        }
        if((s16)half(o+4)==x && (s16)half(o+6)==y && flag && flag<0x1900 && BoundWorldOriginalFlag(flag) && !peerFlag(flag)) return 1;
        /* Restore the native trainer sight corridor after this player wins,
         * until the partner has won too. This never sets/clears a trainer flag. */
        if((half(o+12)==1 || half(o+12)==3) && half(o+14)<=16) {
            u32 script=word(o+16); unsigned trainer,range=half(o+14),movement=o[9];
            if(!romPointer(script,4) || *(const u8 *)script!=0x5C) continue;
            trainer=half((const u8 *)script+2);
            if(trainer>=0x4000) trainer=((u16 (*)(u16))0x0806E569)(trainer);
            if(trainer>=0x1400 || !BoundWorldOriginalFlag(0x500+trainer) || peerFlag(0x500+trainer)) continue;
            for(j=0;j<=range;j++) {
                int tx=(s16)half(o+4),ty=(s16)half(o+6);
                if(movement==7) ty-=j; else if(movement==8) ty+=j;
                else if(movement==9) tx-=j; else if(movement==10) tx+=j; else break;
                if(tx==x && ty==y) return 1;
                /* A battle can finish while the player is already on its
                 * sight line. Preserve retreat to the arrival side, and deny
                 * crossing out the opposite side without moving the avatar. */
                int cx=(s16)half(player+16)-7,cy=(s16)half(player+18)-7;
                int px=(s16)half(player+20)-7,py=(s16)half(player+22)-7;
                if((movement==9 || movement==10) && cx==tx && cy==ty && (y-ty)*(py-ty)<0) return 1;
                if((movement==7 || movement==8) && cx==tx && cy==ty && (x-tx)*(px-tx)<0) return 1;
            }
        }
    }
    /* A moved Strength boulder remains solid at the partner's location, but
     * only once it has moved away locally: the first push must stay possible. */
    if(s[4]==POLICY->group && s[5]==POLICY->number) {
        for(i=0;i<POLICY->count && i<16;i++) {
            volatile const struct Boulder *b=&POLICY->boulders[i]; int localHere=0;
            if(b->x!=x || b->y!=y || (b->elevation && elevation && b->elevation!=elevation)) continue;
            for(j=0;j<16;j++) { const u8 *o=OBJECTS+j*36;
                if((o[0]&1) && o[8]==b->id && (s16)half(o+16)-7==x && (s16)half(o+18)-7==y) localHere=1;
            }
            if(!localHere) return 1;
        }
    }
    return 0;
}
u32 BoundWorldCollision(const u8 *obj,s16 x,s16 y,u8 direction) {
    u32 native=BoundWorldOriginalCollision(obj,x,y,direction);
    if(!enabled() || obj[8]!=0xFF || !(word(obj)&0x10000)) return native;
    if(!fresh()) return 1; /* Keep menus/native battles alive during reconnect. */
    return tileGate(obj,x-7,y-7,obj[11]&15) ? 1 : native;
}
/* Original handlers stay intact. Replacing their dispatch slots avoids
 * relocating BL/PC-relative instructions or changing script opcodes. */
static int trainerPending(unsigned trainer) {
    const u8 *s=save(); unsigned i,j;
    if(!enabled()) return 0;
    if(!fresh()) return 1;
    if(s && s[4]==3 && s[5]==43) {
        for(i=0;i<5;i++) if(trainer==bridgeTrainers[i])
            for(j=0;j<i;j++) if(bridgePending(j)) return 1;
    }
    return 0;
}
static u32 waitForPeer(u8 *ctx) {
    /* Native RAM script survives save-state restoration and releases the
     * trainer approach lock without awarding a win or starting a battle. */
    static const u8 script[]={0x69,0x67,0x20,0x42,0x00,0x03,0x66,0x6D,0x6B,0x02};
    static const u8 text[]="Wait for your friend\nto reach this point.";
    unsigned i;
    for(i=0;i<sizeof(script);i++) WAIT_SCRIPT[i]=script[i];
    for(i=0;i<sizeof(text)-1;i++) {
        unsigned c=text[i];
        WAIT_SCRIPT[32+i]= c>='A'&&c<='Z' ? c-'A'+0xBB : c>='a'&&c<='z' ? c-'a'+0xD5 : c=='\n' ? 0xFE : c=='.' ? 0xAD : 0;
    }
    WAIT_SCRIPT[32+sizeof(text)-1]=0xFF;
    *(const u8 **)(ctx+8)=WAIT_SCRIPT; return 0;
}
u32 BoundWorldTrainer(u8 *ctx) {
    const u8 *script=(const u8 *)word(ctx+8); unsigned trainer=0;
    if(romPointer((u32)script,5)) {
        trainer=half(script+1);
        if(trainer>=0x4000) trainer=((u16 (*)(u16))0x0806E569)(trainer);
    }
    if(trainerPending(trainer)) return waitForPeer(ctx);
    return ((u32 (*)(u8 *))0x0806C2C5)(ctx);
}
u32 BoundWorldDoTrainer(u8 *ctx) {
    /* Automatic sightline encounters configure the trainer directly and bypass
     * opcode 0x5C. The native 0x5D launch consumes gTrainerBattleOpponent_A;
     * recheck here as well, including peer expiry during the intro dialogue. */
    if(trainerPending(half((const u8 *)0x020386AE))) return waitForPeer(ctx);
    return ((u32 (*)(u8 *))0x0806C2D9)(ctx);
}
u32 BoundWorldCheckTrainer(u8 *ctx) {
    const u8 *script=(const u8 *)word(ctx+8); unsigned trainer=half(script);
    u32 result=((u32 (*)(u8 *))0x0806C30D)(ctx);
    if(enabled() && ctx[2]) {
        if(trainer>=0x4000) trainer=((u16 (*)(u16))0x0806E569)(trainer);
        if(trainer>=0x1400 || !peerFlag(0x500+trainer)) ctx[2]=0;
    }
    return result;
}
