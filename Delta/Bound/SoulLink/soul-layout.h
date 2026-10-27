/* Shared host/ARM scratch ownership. Compile both consumers against the real
 * native decision ABI so a future queue/layout change cannot silently overlap
 * Soul Link's durable-receipt or faint staging buffers. Exact RR adapter only. */
#ifndef BOUND_SOUL_LAYOUT_H
#define BOUND_SOUL_LAYOUT_H
#include "../NativeBattle/battle-decisions.h"
#define BOUND_SOUL_FAINT_ADDRESS 0x03004500u
#define BOUND_SOUL_FAINT_BYTES 268u
#define BOUND_SOUL_ACQUISITION_ADDRESS 0x03004880u
#define BOUND_SOUL_ACQUISITION_CAPACITY 32u
#define BOUND_SOUL_ACQUISITION_BYTES 396u
#define BOUND_SOUL_ACQUISITION_OFFSET (BOUND_SOUL_ACQUISITION_ADDRESS - 0x03000000u)
#define BOUND_SOUL_QA_ADDRESS 0x03004D00u
#define BOUND_SOUL_QA_BYTES 64u
#define BOUND_SOUL_NATIVE_QUEUE_COUNT_ADDRESS 0x03004F70u
struct BoundSoulAcquisitionRecord { unsigned int personality, trainer, source; };
struct BoundSoulAcquisitionRing {
    unsigned int magic, count, overflow;
    struct BoundSoulAcquisitionRecord rows[BOUND_SOUL_ACQUISITION_CAPACITY];
};
typedef char bound_soul_acquisition_record_size[sizeof(struct BoundSoulAcquisitionRecord)==12u ? 1:-1];
typedef char bound_soul_acquisition_ring_size[sizeof(struct BoundSoulAcquisitionRing)==BOUND_SOUL_ACQUISITION_BYTES ? 1:-1];
typedef char bound_soul_faints_before_decisions[BOUND_SOUL_FAINT_ADDRESS+BOUND_SOUL_FAINT_BYTES<=BOUND_DECISION_ADDRESS ? 1:-1];
typedef char bound_soul_decisions_before_acquisitions[BOUND_DECISION_ADDRESS+sizeof(struct BoundDecisionState)<=BOUND_SOUL_ACQUISITION_ADDRESS ? 1:-1];
typedef char bound_soul_acquisitions_before_qa[BOUND_SOUL_ACQUISITION_ADDRESS+sizeof(struct BoundSoulAcquisitionRing)<=BOUND_SOUL_QA_ADDRESS ? 1:-1];
typedef char bound_soul_qa_before_native_queue[BOUND_SOUL_QA_ADDRESS+BOUND_SOUL_QA_BYTES<=BOUND_SOUL_NATIVE_QUEUE_COUNT_ADDRESS ? 1:-1];
#endif
