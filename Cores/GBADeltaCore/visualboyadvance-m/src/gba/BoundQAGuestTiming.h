#ifndef BOUND_QA_GUEST_TIMING_H
#define BOUND_QA_GUEST_TIMING_H

// Opt-in host diagnostics only. No guest address, register, timing or save ABI
// is changed. Every interpreter callsite is compiled out without this macro.
#if defined(BOUND_QA_GUEST_TIMING) && BOUND_QA_GUEST_TIMING
#include <stddef.h>
#include <stdint.h>

struct BoundQAGuestTimingRecord { uint64_t words[17]; };
struct BoundQAGuestTimingSummary {
    uint64_t records, dropped, stackOverflows, invalidated, cycles;
    uint64_t videoFrames, dmaCycles, idleCycles, openCalls, openInterrupts;
};
extern "C" {
__attribute__((visibility("default"))) bool BoundQAGuestTimingStart(const uint32_t *points, const uint32_t *trackReturns, size_t count, size_t capacity);
__attribute__((visibility("default"))) const BoundQAGuestTimingRecord *BoundQAGuestTimingStop(BoundQAGuestTimingSummary *summary);
}
void BoundQAGuestTimingInstruction();
void BoundQAGuestTimingAdvance(int cycles);
void BoundQAGuestTimingDMA(int cycles);
void BoundQAGuestTimingIdle(int cycles);
void BoundQAGuestTimingInterrupt(int remainingInstructionCycles);
void BoundQAGuestTimingVideo();
void BoundQAGuestTimingInvalidate();
#endif
#endif
