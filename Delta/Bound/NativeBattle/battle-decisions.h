/* Original Bound decision-only friendly-battle ABI. Guest integers are LE. */
#ifndef BOUND_BATTLE_DECISIONS_H
#define BOUND_BATTLE_DECISIONS_H
typedef unsigned char bd_u8;
typedef unsigned short bd_u16;
typedef unsigned int bd_u32;
#define BOUND_DECISION_ADDRESS 0x03004620u
#define BOUND_DECISION_CODE_ADDRESS 0x09FE8000u
#define BOUND_DECISION_CODE_LIMIT 0x09FF0000u
#define BOUND_DECISION_MAGIC 0x31444242u /* BBD1 */
#define BOUND_DECISION_CAPACITY 8u
#define BOUND_DECISION_NONE 255u
struct BoundDecisionRecord {
    bd_u32 ordinal, fingerprint;
    bd_u8 battler, request, parentAction, size;
    bd_u8 response[16];
    bd_u32 reserved;
};
struct BoundDecisionSlot {
    bd_u32 ordinal, fingerprint;
    bd_u8 request, pendingAction, waiting, replayStage;
};
struct BoundDecisionState {
    bd_u32 magic, seed, error, started;
    bd_u16 outRead, outWrite, inRead, inWrite;
    bd_u32 sentOrdinal, receivedOrdinal, inSimulation, frames;
    struct BoundDecisionSlot slots[2];
    struct BoundDecisionRecord outgoing[BOUND_DECISION_CAPACITY];
    struct BoundDecisionRecord incoming[BOUND_DECISION_CAPACITY];
    bd_u32 terminalFingerprint, terminalOutcome;
};
/* Fixed state lives in unused virtual-cable serial storage, beyond the Soul
 * Link faint journal and below gLastRecvQueueCount. No native heap allocation. */
typedef char bound_decision_record_size[sizeof(struct BoundDecisionRecord)==32 ? 1:-1];
typedef char bound_decision_state_size[sizeof(struct BoundDecisionState)==584 ? 1:-1];
typedef char bound_decision_state_fits[BOUND_DECISION_ADDRESS+sizeof(struct BoundDecisionState)<=0x03004F70 ? 1:-1];
#endif
