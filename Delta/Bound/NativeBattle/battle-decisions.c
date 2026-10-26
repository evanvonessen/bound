/* Original Bound execution adapter for the exact RR 4.1 friendly battle ABI.
 * Both cartridges run their own battle script and presentation. Only confirmed
 * player decisions cross the wire. Native battle mechanics remain unchanged.
 */
#include "battle-decisions.h"
typedef void (*Callback)(void);
#define S ((volatile struct BoundDecisionState *)BOUND_DECISION_ADDRESS)
#define ROLE (*(volatile const bd_u8 *)0x09FFFCF0)
#define ACTIVE (*(volatile bd_u8 *)0x02023BC4)
#define COUNT (*(volatile bd_u8 *)0x02023BCC)
#define EXEC (*(volatile bd_u32 *)0x02023BC8)
#define RNG (*(volatile bd_u32 *)0x03005000)
#define MAIN (*(Callback volatile *)0x03004F84)
#define CONTROLLERS ((Callback volatile *)0x03004FE0)
#define BUFFER_A ((volatile bd_u8 (*)[512])0x02022BC4)
#define BUFFER_B ((volatile bd_u8 (*)[512])0x020233C4)
#define FLAGS (*(volatile bd_u32 *)0x02022B4C)

static void copy(volatile bd_u8 *out,const volatile bd_u8 *in,unsigned size) {
    while(size--) *out++=*in++;
}
static int active(void) { return S->magic==BOUND_DECISION_MAGIC && (FLAGS&2) && COUNT==2 && ROLE<2; }
static void fail(unsigned error) { if(!S->error) S->error=error; }
static int choice(unsigned command) { return command==18 || command==20 || command==22; }
static bd_u32 fingerprint(void) {
    /* Canonical battler IDs survive the two local camera orientations. Exclude
     * animation flags, menus, heap addresses and presentation RNG. */
    const volatile bd_u8 *bytes=(const volatile bd_u8 *)0x02023BE4;
    bd_u32 hash=2166136261u;
    for(unsigned bank=0;bank<2;bank++)for(unsigned i=0;i<88;i++) {
        /* The native get-mon response copies a stack struct; unused byte0x23
         * and trailing nickname/OT-name bytes need not be initialized. */
        if(i==0x23 || (i>=0x30 && i<0x44 && i!=0x3B))continue;
        hash=(hash^bytes[bank*88+i])*16777619u;
    }
    return hash;
}
static void terminal(void) {
    unsigned outcome=*(volatile bd_u8 *)0x02023E8A;
    if(!outcome || S->terminalOutcome)return;
    unsigned canonical=outcome;
    if(ROLE && ((outcome&0x7F)==1 || (outcome&0x7F)==2))canonical=outcome^3;
    S->terminalFingerprint=((fingerprint()^S->seed)*16777619u)^canonical;
    S->terminalOutcome=outcome;
}
static void queue(unsigned request,const volatile bd_u8 *response,unsigned size,unsigned parent) {
    if(size==0 || size>16 || ACTIVE!=ROLE) { fail(1);return; }
    unsigned write=S->outWrite;
    if((bd_u16)(write-S->outRead)>=BOUND_DECISION_CAPACITY || S->sentOrdinal==0xFFFFFFFFu) { fail(2);return; }
    volatile struct BoundDecisionRecord *r=&S->outgoing[write&(BOUND_DECISION_CAPACITY-1)];
    r->ordinal=++S->sentOrdinal;r->fingerprint=S->slots[ACTIVE].fingerprint;
    r->battler=ACTIVE;r->request=request;r->parentAction=parent;r->size=size;r->reserved=0;
    for(unsigned i=0;i<16;i++)r->response[i]=i<size?response[i]:0;
    S->outWrite=write+1;
}
static int validDecision(const volatile struct BoundDecisionRecord *r) {
    const volatile bd_u8 *data=r->response;
    if(r->request==18)return r->size==4 && r->parentAction==BOUND_DECISION_NONE && data[0]==33 &&
        (data[1]==0 || data[1]==3) && !data[2] && !data[3];
    if(r->request==20) {
        if((r->size!=4 && r->size!=8) || (r->parentAction!=0 && r->parentAction!=BOUND_DECISION_NONE) ||
            data[0]!=33 || data[1]!=10 || data[2]>=4 || data[3]>=2)return 0;
        const volatile bd_u16 *moves=(const volatile bd_u16 *)(0x02023BE4+88*r->battler+12);
        if(!moves[data[2]])return 0;
        if(r->size==8)for(unsigned i=4;i<8;i++)if(data[i]>1)return 0;
        return 1;
    }
    if(r->request==22) {
        if(r->size!=5 || (r->parentAction!=2 && r->parentAction!=BOUND_DECISION_NONE) || data[0]!=34 || data[1]>=6 ||
            data[1]>=*(volatile bd_u8 *)0x0202402A)return 0;
        const volatile bd_u16 *hp=(const volatile bd_u16 *)(0x0202402C+100*data[1]+86);
        const volatile bd_u16 *indices=(const volatile bd_u16 *)0x02023BCE;
        return *hp && data[1]!=indices[r->battler];
    }
    return 0; /* Bag/yes-no are not decisions supported by friendly links. */
}
static void deliverRemote(void) {
    unsigned battler=ROLE^1;
    volatile struct BoundDecisionSlot *slot=&S->slots[battler];
    if(!slot->waiting || S->inRead==S->inWrite || S->error)return;
    if((bd_u16)(S->inWrite-S->inRead)>BOUND_DECISION_CAPACITY) { fail(3);return; }
    volatile struct BoundDecisionRecord *r=&S->incoming[S->inRead&(BOUND_DECISION_CAPACITY-1)];
    if(r->ordinal<=S->receivedOrdinal) { S->inRead++;return; }
    if(r->ordinal!=S->receivedOrdinal+1 || r->battler!=battler || r->size==0 || r->size>16 || r->reserved || !validDecision(r)) { fail(4);return; }
    if(r->fingerprint!=slot->fingerprint) { fail(5);return; }
    if(slot->request==18 && r->request!=18 && (r->parentAction==0 || r->parentAction==2)) {
        BUFFER_B[battler][0]=33;BUFFER_B[battler][1]=r->parentAction;
        BUFFER_B[battler][2]=BUFFER_B[battler][3]=0;
        slot->replayStage=1;
    } else {
        if(r->request!=slot->request) { fail(6);return; }
        copy(BUFFER_B[battler],r->response,r->size);
        S->receivedOrdinal=r->ordinal;S->inRead++;slot->replayStage=0;
    }
    slot->waiting=0;EXEC&=~(1u<<battler);
}

void BoundDecisionTransfer(bd_u8 id,const bd_u8 *data,bd_u16 size) {
    if(!active() || ACTIVE>=2 || size>512) { fail(7);return; }
    volatile struct BoundDecisionSlot *slot=&S->slots[ACTIVE];
    if(id==0) {
        if(!size) { fail(8);return; }
        unsigned command=data[0];
        /* Struggle/NoMoreMoving may finish action selection without
         * opening ChooseMove. Publish it only when native Link Standby commits
         * the action, never when Fight or Back merely changes the local menu. */
        if(ACTIVE==ROLE && command==53 && slot->pendingAction==0) {
            const bd_u8 response[]={33,0,0,0};queue(18,response,4,BOUND_DECISION_NONE);
            slot->pendingAction=BOUND_DECISION_NONE;
        }
        if(command==18) {
            slot->fingerprint=fingerprint();slot->pendingAction=BOUND_DECISION_NONE;slot->replayStage=0;
        } else if(choice(command) && slot->pendingAction==BOUND_DECISION_NONE && !slot->replayStage) {
            slot->fingerprint=fingerprint();
        }
        slot->request=command;
        slot->waiting=ACTIVE!=ROLE && choice(command);
        copy(BUFFER_A[ACTIVE],data,size);
        /* Native master always sends end at battler0. The guest's remote
         * controller reverses its result. Each new engine already computed a
         * local result, so feed that controller its expected opposite view. */
        /* The original remote handler special-cases only literal draw3, then
         * XORs3 even for the native high-bit Run outcomes81/82/83. */
        if(command==55 && size>=2 && ACTIVE!=ROLE && data[1]!=3)
            BUFFER_A[ACTIVE][1]=data[1]^3;
    } else if(id==1) {
        copy(BUFFER_B[ACTIVE],data,size);
        if(ACTIVE!=ROLE || !choice(slot->request))return;
        if(size>16) { fail(9);return; }
        if(slot->request==18 && size>=4 && data[0]==33) {
            /* RR CheckCantMoveThisTurn emits its deterministic move result
             * while still handling Fight, without a ChooseMove request.
             * Keep that result local; commit the pending Fight at standby. */
            if(data[1]==10 && size==8 && S->inSimulation && slot->pendingAction==0)return;
            slot->pendingAction=data[1];
            if(data[1]==3) { queue(18,data,size,BOUND_DECISION_NONE);slot->pendingAction=BOUND_DECISION_NONE; }
            else if(data[1]!=0 && data[1]!=1 && data[1]!=2)fail(10);
        } else if(slot->request==20 && size>=4 && data[0]==33) {
            if(data[2]==255 && data[3]==255) {slot->pendingAction=BOUND_DECISION_NONE;return;}
            queue(20,data,size,slot->pendingAction);slot->pendingAction=BOUND_DECISION_NONE;
        } else if(slot->request==22 && size>=2 && data[0]==34) {
            if(data[1]>=6) {slot->pendingAction=BOUND_DECISION_NONE;return;}
            queue(22,data,size,slot->pendingAction);slot->pendingAction=BOUND_DECISION_NONE;
        } else {
            queue(slot->request,data,size,slot->pendingAction);slot->pendingAction=BOUND_DECISION_NONE;
        }
    } else if(id==2) {
        if(!slot->waiting)EXEC&=~(1u<<ACTIVE);
    } else fail(11);
}
void BoundDecisionLinkTransfer(bd_u8 id,bd_u16 size,const bd_u8 *data) { BoundDecisionTransfer(id,data,size); }
void BoundDecisionMark(bd_u8 battler) {
    if(!active() || battler>=2) {fail(12);return;}
    EXEC|=1u<<battler;
}

/* Two independent worlds may have different rain or scripted terrain. The
 * friendly arena starts neutral; native ability/move weather remains native.
 * Preserve the original field values and restore these hooks on battle exit. */
bd_u8 BoundDecisionOverworldWeather(void) {
    if(S->magic==BOUND_DECISION_MAGIC && (FLAGS&2))return 0;
    return *(volatile bd_u8 *)0x02038604;
}
static bd_u8 __attribute__((naked)) nativeOverworldTerrain(void) {
    __asm__ volatile("mov r0,#160\npush {r4,r5,r6,lr}\nldr r3,=0x0806E569\nlsl r0,r0,#7\nldr r2,=0x0906E535\nbx r2\n.ltorg");
}
bd_u8 BoundDecisionOverworldTerrain(void) {
    if(S->magic==BOUND_DECISION_MAGIC && (FLAGS&2))return 0;
    return nativeOverworldTerrain();
}

/* RR's exact VBlank prologue, continued after the replaced eight bytes. An
 * interrupt can occur inside battle logic; its Random call must never advance
 * the deterministic battle seed. Audio/DMA interrupts are otherwise unchanged. */
static void __attribute__((naked)) nativeVBlank(void) {
    __asm__ volatile("push {r4,r5,lr}\nldr r0,=0x03003F3C\nldrb r0,[r0]\ncmp r0,#0\nldr r3,=0x0800072D\nbx r3\n.ltorg");
}
void BoundDecisionVBlank(void) {
    bd_u32 seed=RNG;
    unsigned restore=S->magic==BOUND_DECISION_MAGIC && S->inSimulation;
    nativeVBlank();
    if(restore)RNG=seed;
}
void BoundDecisionFrame(void) {
    if(!active()) {fail(13);return;}
    if(!S->started) {
        S->started=1;
        for(unsigned i=0;i<2;i++)S->slots[i].pendingAction=BOUND_DECISION_NONE;
        if((bd_u32)MAIN==0x080123BD) MAIN=(Callback)0x080123C1;
    }
    if(S->error)return;
    deliverRemote();
    if(S->error)return;
    /* Keep the interrupt fence raised before publishing the simulation seed
     * and until the presentation seed is restored. VBlank may interrupt any
     * instruction, including these boundary stores. */
    bd_u32 visual=RNG;S->inSimulation=1;RNG=S->seed;
    MAIN();
    S->seed=RNG;RNG=visual;S->inSimulation=0;
    terminal();
    if(S->error)return;
    for(ACTIVE=0;ACTIVE<COUNT;ACTIVE++)CONTROLLERS[ACTIVE]();
    S->frames++;
}
