// Included once by GBA.cpp after its timing globals. Configuration and export
// happen only with the emulator paused; the CPU owner is the sole writer while
// running. The bounded host buffer is deliberately absent from save states.
#if defined(BOUND_QA_GUEST_TIMING) && BOUND_QA_GUEST_TIMING
#include "BoundQAGuestTiming.h"
#include <algorithm>
#include <vector>
static_assert(sizeof(BoundQAGuestTimingRecord) == 136, "Guest timing record ABI");
namespace {
struct BoundQATimingPoint { uint32_t pc, id, trackReturn; };
struct BoundQATimingCall { uint32_t pc, sp, mode, point; uint64_t id; };
struct BoundQATimingState {
    bool active = false;
    uint64_t clock = 0, serial = 0, video = 0, dma = 0, idle = 0;
    uint64_t dropped = 0, stackOverflows = 0, invalidated = 0;
    size_t capacity = 0, pointCount = 0, callCount = 0, irqCount = 0;
    BoundQATimingPoint points[64]{};
    BoundQATimingCall calls[256]{}, irqs[16]{};
    std::vector<BoundQAGuestTimingRecord> records;
} boundQATiming;

uint64_t boundQATimingNow() {
    // cpuTotalTicks is elapsed instruction/idle time not yet handed to the
    // hardware event loop. updateLoop consumes it exactly once in chunks.
    return boundQATiming.clock + uint64_t(cpuTotalTicks > 0 ? cpuTotalTicks : 0);
}
void boundQATimingRecord(uint64_t kind, uint64_t id = 0, uint64_t point = 0, bool eventBoundary = false) {
    auto &s = boundQATiming;
    if (s.records.size() >= s.capacity) { ++s.dropped; return; }
    BoundQAGuestTimingRecord row{{kind, eventBoundary ? s.clock : boundQATimingNow(), id, point,
        armNextPC, reg[14].I, reg[13].I, uint64_t(armMode) | (armState ? 0x100u : 0u),
        VCOUNT, DISPSTAT, uint64_t(int64_t(lcdTicks)), IE, IF, IME, s.video, s.dma, s.idle}};
    s.records.push_back(row);
}
bool boundQATimingReturned(const BoundQATimingCall &call) {
    return call.pc == armNextPC && call.sp == reg[13].I &&
        call.mode == (uint32_t(armMode) | (armState ? 0x100u : 0u));
}
}

extern "C" bool BoundQAGuestTimingStart(const uint32_t *points, const uint32_t *trackReturns, size_t count, size_t capacity) {
    // Normal CPULoop exits drain all instruction/event chunks. Reject a
    // debugger/early exit instead of inventing an origin for pending ticks.
    if (boundQATiming.active || cpuTotalTicks != 0 || !points || !trackReturns || !count || count > 64 || capacity < 1024 || capacity > 262144)
        return false;
    for (size_t i = 0; i < count; ++i) {
        if ((points[i] & 1) || points[i] < 0x08000000 || points[i] >= 0x0A000000 || trackReturns[i] > 1) return false;
        for (size_t j = 0; j < i; ++j) if (points[i] == points[j]) return false;
    }
    boundQATiming = BoundQATimingState();
    auto &s = boundQATiming;
    s.capacity = capacity; s.pointCount = count;
    s.records.reserve(capacity);
    for (size_t i = 0; i < count; ++i) s.points[i] = {points[i], uint32_t(i + 1), trackReturns[i]};
    std::sort(s.points, s.points + count, [](const BoundQATimingPoint &a, const BoundQATimingPoint &b) { return a.pc < b.pc; });
    s.active = true;
    boundQATimingRecord(6);
    return true;
}
extern "C" const BoundQAGuestTimingRecord *BoundQAGuestTimingStop(BoundQAGuestTimingSummary *summary) {
    auto &s = boundQATiming;
    if (s.active) boundQATimingRecord(7);
    s.active = false;
    if (summary) *summary = {s.records.size(), s.dropped, s.stackOverflows, s.invalidated,
        boundQATimingNow(), s.video, s.dma, s.idle, s.callCount, s.irqCount};
    return s.records.data();
}
void BoundQAGuestTimingInstruction() {
    auto &s = boundQATiming;
    if (!s.active) return;
    while (s.irqCount && boundQATimingReturned(s.irqs[s.irqCount - 1])) {
        const auto call = s.irqs[--s.irqCount]; boundQATimingRecord(4, call.id);
    }
    while (s.callCount && boundQATimingReturned(s.calls[s.callCount - 1])) {
        const auto call = s.calls[--s.callCount]; boundQATimingRecord(2, call.id, call.point);
    }
    size_t low = 0, high = s.pointCount;
    while (low < high) {
        const size_t mid = low + (high - low) / 2;
        if (s.points[mid].pc < armNextPC) low = mid + 1; else high = mid;
    }
    if (low == s.pointCount || s.points[low].pc != armNextPC) return;
    if (!s.points[low].trackReturn) { boundQATimingRecord(9, 0, s.points[low].id); return; }
    if (s.callCount == 256) { ++s.stackOverflows; return; }
    const uint64_t id = ++s.serial;
    s.calls[s.callCount++] = {reg[14].I & ~1u, reg[13].I,
        uint32_t(armMode) | ((reg[14].I & 1) ? 0u : 0x100u), s.points[low].id, id};
    boundQATimingRecord(1, id, s.points[low].id);
}
void BoundQAGuestTimingAdvance(int cycles) {
    if (boundQATiming.active && cycles > 0) boundQATiming.clock += uint64_t(cycles);
}
void BoundQAGuestTimingDMA(int cycles) {
    if (boundQATiming.active && cycles > 0) boundQATiming.dma += uint64_t(cycles);
}
void BoundQAGuestTimingIdle(int cycles) {
    if (boundQATiming.active && cycles > 0) boundQATiming.idle += uint64_t(cycles);
}
void BoundQAGuestTimingInterrupt(int remainingInstructionCycles) {
    auto &s = boundQATiming;
    if (!s.active) return;
    if (s.irqCount == 16) { ++s.stackOverflows; return; }
    const uint64_t id = ++s.serial;
    s.irqs[s.irqCount++] = {armNextPC, reg[13].I,
        uint32_t(armMode) | (armState ? 0x100u : 0u), 0, id};
    boundQATimingRecord(3, id, 0, true);
    // The interpreter already completed the interrupted instruction, but its
    // tail may still be waiting for updateLoop. Attribute that tail to the
    // interrupted code, not to the IRQ. Hardware events retain their own time.
    if (!s.records.empty() && s.records.back().words[0] == 3 && s.records.back().words[2] == id)
        s.records.back().words[1] += uint64_t(remainingInstructionCycles > 0 ? remainingInstructionCycles : 0);
}
void BoundQAGuestTimingVideo() {
    if (!boundQATiming.active) return;
    ++boundQATiming.video;
    boundQATimingRecord(5, 0, 0, true);
}
void BoundQAGuestTimingInvalidate() {
    if (!boundQATiming.active) return;
    ++boundQATiming.invalidated; boundQATimingRecord(8); boundQATiming.active = false;
}
#endif
