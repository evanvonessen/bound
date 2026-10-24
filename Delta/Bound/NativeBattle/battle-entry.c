/* Original Bound guest code for the exact RR 4.1 native link ABI.
 * The cartridge retains its command processing, party exchange and battle logic.
 * This replaces physical serial timing with two reliable native command queues.
 */
typedef unsigned char u8;
typedef unsigned short u16;
typedef unsigned int u32;
typedef void (*Task)(u8);
#define MAILBOX ((volatile struct Mailbox *)0x03004030)
#define ROLE (*(volatile const u8 *)0x09FFFBF0)
#define MAGIC 0x314D4642u
struct Mailbox { u32 magic; u16 outRead,outWrite,inRead,inWrite,error,localRead,generation,peerGeneration,peerConsumed,peerAckGeneration; u16 out[32][8]; u16 in[32][8]; u16 outGeneration[32]; u16 inSequence[32]; };

__attribute__((section(".text.start"))) void BoundBattleStart(void)
{
    ((void (*)(u8))0x080096F9)(ROLE);
    *(volatile u16 *)0x0202271A=0x2211;
    ((u8 (*)(Task,u8))0x0807741D)((Task)0x08081319,80);
    ((void (*)(void))0x08069B29)();
}
__attribute__((noinline)) void BoundBattleIdle(void) { ((void (*)(void))0x08077579)(); }
void BoundBattleReturn(void) { *(volatile u32 *)0x030030F4=(u32)BoundBattleIdle; }

u32 BoundBattleLinkMain1(u8 *advance,u16 *send,u16 recv[5][8])
{
    volatile struct Mailbox *m=MAILBOX;
    volatile u8 *link=(volatile u8 *)0x03003FB0;
    unsigned i,j,role=ROLE&1;
    if (link[0x7E]) { link[0x7E]=0; ((void (*)(void))0x080098B9)(); }
    if (m->magic!=MAGIC) {
        m->outRead=m->outWrite=m->inRead=m->inWrite=m->error=m->localRead=m->generation=m->peerGeneration=m->peerConsumed=m->peerAckGeneration=0;
        m->magic=MAGIC;
    }
    /* Preserve VBlank/sound interrupts; physical serial and its Timer3 are idle. */
    *(volatile u16 *)0x04000200 &= (u16)~0xC0;
    *(volatile u16 *)0x0400010E=0;
    *(volatile u16 *)0x04000202=0xC0;
    for (i=0;i<5;i++) for (j=0;j<8;j++) recv[i][j]=0;
    if (!link[1]) { *advance=0; return 0; }
    if (link[1]!=4 && m->peerGeneration!=m->generation) { *advance=0; return role; }
    link[0]=role ? 0:8; link[1]=4; link[2]=role; link[3]=2;
    for (i=16;i<20;i++) link[i]=0;
    if (send[0] && send[0]!=0xEFFF) {
        u16 write=m->outWrite;
        if ((u16)(write-m->outRead)>=32 || (u16)(write-m->localRead)>=32) m->error=1;
        else {
            for (i=0;i<8;i++) m->out[write&31][i]=send[i];
            m->outGeneration[write&31]=m->generation;
            m->outWrite=write+1;
        }
    }
    /* Loop back only commands acknowledged as consumed by the peer game.
     * Native CloseLink may run immediately after observing our close command. */
    if (m->localRead!=m->outRead) {
        u16 read=m->localRead;
        for (i=0;i<8;i++) recv[role][i]=m->out[read&31][i];
        m->localRead=read+1;
    }
    if (m->inRead!=m->inWrite) {
        u16 read=m->inRead;
        for (i=0;i<8;i++) recv[role^1][i]=m->in[read&31][i];
        m->peerConsumed=m->inSequence[read&31]; m->peerAckGeneration=m->generation;
        m->inRead=read+1;
    }
    for (i=0;i<8;i++) send[i]=0;
    *advance=0;
    link[12]=(recv[0][0]|recv[1][0])==0;
    *(volatile u8 *)0x03003FA0=(u8)(m->outWrite-m->outRead);
    *(volatile u8 *)0x03004F70=(u8)(m->inWrite-m->inRead);
    return 0x48u|role|(role ? 0:0x20u)|(link[12] ? 0x100u:0);
}
void BoundBattleLinkVSync(void) { }
u8 BoundBattleMultiplayerId(void) { return ROLE&1; }
u8 BoundBattleRecvCount(void) { return (u8)(MAILBOX->inWrite-MAILBOX->inRead); }
u8 BoundBattleSendCount(void) { return (u8)(MAILBOX->outWrite-MAILBOX->outRead); }

/* Native close/reopen brackets setup and battle. Keep in-flight commands while
 * preserving the native logical-open flag owned by InitLink/CloseLink. */
static void SetVirtualSerial(u8 state)
{
    volatile u8 *link=(volatile u8 *)0x03003FB0;
    unsigned i;
    for (i=0;i<0x80;i++) link[i]=0;
    link[1]=state;
    *(volatile u16 *)0x04000200 &= (u16)~0xC0;
    *(volatile u16 *)0x0400010E=0;
    *(volatile u16 *)0x04000202=0xC0;
}
void BoundBattleEnableSerial(void) { MAILBOX->generation++; MAILBOX->inRead=MAILBOX->inWrite; MAILBOX->localRead=MAILBOX->outRead=MAILBOX->outWrite; SetVirtualSerial(1); }
void BoundBattleDisableSerial(void) { SetVirtualSerial(0); }

/* A walk-up trade exits to this local map, not a synchronized cable room.
 * Party, Dex and the native linked save are retained by these native routines. */
void BoundBattleTradeReturn(void)
{
    ((void (*)(void))0x080578D9)();
    ((void (*)(u32))0x080565E1)(0x08056535);
    ((void (*)(void))0x08069A81)();
    ((void (*)(void))0x0806994D)();
    ((void (*)(void))0x080568FD)();
}

/* RR's loss cleanup clears the link flag before the native terminal controller
 * command is emitted. Keep that command on the cable, so the guest receives its
 * native outcome. Installed only for a friendly battle; no outcome is invented.
 * r7 still points to the native flags, and the native epilogue restores r0-r2,
 * r4-r7 and PC. Non-link cleanup retains its original flag-clear decision. */
void __attribute__((naked)) BoundBattlePreserveLinkFlags(void)
{
    __asm__ volatile("ldr r3,[r7]\nmovs r2,#2\ntst r3,r2\nbne 1f\n"
        "movs r2,#128\nlsl r2,r2,#3\nand r3,r2\nldr r2,=0x09090961\nbx r2\n"
        "1: ldr r2,=0x09090967\nbx r2\n.ltorg");
}
