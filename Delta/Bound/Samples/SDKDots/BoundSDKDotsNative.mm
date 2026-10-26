#import "BoundSDKDotsNative.h"
#import <DeltaCore/DeltaCore.h>
#import <DeltaCore/DeltaCore-Swift.h>
#import <GBADeltaCore/GBADeltaCore.h>
#import <CommonCrypto/CommonDigest.h>
#import <objc/runtime.h>
#include <atomic>
#include <cstring>
#include <mutex>
#include <string>
#include "../../../../Cores/GBADeltaCore/visualboyadvance-m/src/gba/GBA.h"

extern uint8_t *rom, *workRAM;
namespace {
constexpr size_t cartridgeSize = 2602;
constexpr uint8_t digest[32] = {0x95,0x84,0x56,0xf9,0xa7,0xe0,0x88,0xeb,0x25,0x43,0xe8,0xcf,0xcc,0x0f,0xb1,0x82,0x51,0x75,0x11,0x37,0x47,0xad,0xb1,0xe9,0x35,0x13,0xb2,0x69,0x64,0x2d,0xa0,0xec};
static_assert(SAVE_GAME_VERSION == 10, "Sample state layout must be reviewed when the pinned core changes");
using Starter = void (*)(id, SEL, NSURL *);
using Stopper = void (*)(id, SEL);
struct Registry {
    std::mutex lock;
    Starter start = nullptr;
    Stopper stop = nullptr;
    uint64_t generation = 1;
    std::string loadedPath, owner;
    uint8_t *cartridge = nullptr;
    __weak id audio = nil, video = nil;
    bool exhausted = false;
};
Registry &registry() { static Registry value; return value; }
std::string path(NSURL *url) {
    if (!url.isFileURL) return {};
    const char *bytes = url.URLByStandardizingPath.URLByResolvingSymlinksInPath.path.fileSystemRepresentation;
    return bytes ? bytes : "";
}
bool exact(const void *bytes, size_t count) {
    if (!bytes || count != cartridgeSize) return false;
    uint8_t actual[32]; CC_SHA256(bytes, (CC_LONG)count, actual);
    return !memcmp(actual, digest, sizeof(digest));
}
void invalidate(Registry &state) {
    if (state.generation == UINT64_MAX) state.exhausted = true;
    else ++state.generation;
    state.owner.clear(); state.loadedPath.clear(); state.cartridge = nullptr; state.audio = nil; state.video = nil;
}
void observedStart(id bridge, SEL selector, NSURL *url) {
    auto &state = registry(); Starter original; uint64_t started;
    id<DLTAEmulatorBridging> emulator = bridge;
    id audio = emulator.audioRenderer, video = emulator.videoRenderer;
    { std::lock_guard<std::mutex> lock(state.lock); invalidate(state); original = state.start; started = state.generation; }
    // Calling outside the lock preserves any previously installed Bound fence.
    if (original) original(bridge, selector, url);
    if (!url.isFileURL) return;
    NSURL *canonical = url.URLByStandardizingPath.URLByResolvingSymlinksInPath;
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:canonical.path error:nullptr];
    if (![attributes[NSFileType] isEqual:NSFileTypeRegular] || [attributes[NSFileSize] unsignedLongLongValue] != cartridgeSize) return;
    // Ordinary cartridges stop at metadata. Inspect the tiny resident sample
    // under the lifecycle lock before reading even its bounded file bytes.
    {
        std::lock_guard<std::mutex> lock(state.lock);
        if (state.exhausted || state.generation != started || !audio || !video ||
            emulator.audioRenderer != audio || emulator.videoRenderer != video || !exact(rom, cartridgeSize)) return;
    }
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingFromURL:canonical error:nullptr];
    NSData *file = [handle readDataUpToLength:cartridgeSize + 1 error:nullptr];
    [handle closeAndReturnError:nullptr];
    const auto loaded = path(canonical);
    std::lock_guard<std::mutex> lock(state.lock);
    if (!state.exhausted && state.generation == started && emulator.audioRenderer == audio && emulator.videoRenderer == video &&
        exact(file.bytes, file.length) && exact(rom, cartridgeSize)) {
        state.loadedPath = loaded; state.cartridge = rom; state.audio = audio; state.video = video;
    }
}
void observedStop(id bridge, SEL selector) {
    auto &state = registry(); Stopper original;
    { std::lock_guard<std::mutex> lock(state.lock); invalidate(state); original = state.stop; }
    if (original) original(bridge, selector);
}
bool admits(const Registry &state, NSString *owner, uint64_t generation) {
    id<DLTAEmulatorBridging> emulator = GBAEmulatorBridge.sharedBridge;
    return !state.exhausted && generation && state.generation == generation && owner.length &&
        state.owner == owner.UTF8String && state.audio && state.video && emulator.audioRenderer == state.audio &&
        emulator.videoRenderer == state.video && state.cartridge == rom && workRAM && exact(rom, cartridgeSize);
}
uint32_t word(const uint8_t *p) { return uint32_t(p[0]) | uint32_t(p[1])<<8 | uint32_t(p[2])<<16 | uint32_t(p[3])<<24; }
void put(volatile uint8_t *p, uint32_t value) { for (int i=0;i<4;i++) p[i]=uint8_t(value>>(i*8)); }
}

@implementation BoundSDKDotsNative
+ (BOOL)installObserver {
    NSAssert(NSThread.isMainThread, @"Install sample observation on main");
    auto &state = registry(); std::lock_guard<std::mutex> lock(state.lock);
    if (state.start) return YES;
    Class cls = NSClassFromString(@"GBAEmulatorBridge");
    Method start = class_getInstanceMethod(cls, @selector(startWithGameURL:));
    Method stop = class_getInstanceMethod(cls, @selector(stop));
    if (!start || !stop) return NO;
    state.start = reinterpret_cast<Starter>(method_setImplementation(start, reinterpret_cast<IMP>(observedStart)));
    state.stop = reinterpret_cast<Stopper>(method_setImplementation(stop, reinterpret_cast<IMP>(observedStop)));
    return state.start && state.stop;
}
+ (uint64_t)claimOwner:(NSString *)owner gameURL:(NSURL *)url audioRenderer:(id)audio videoRenderer:(id)video {
    const auto requested = path(url);
    auto &state = registry(); std::lock_guard<std::mutex> lock(state.lock);
    id<DLTAEmulatorBridging> emulator = GBAEmulatorBridge.sharedBridge;
    if (!NSThread.isMainThread || !owner.length || requested.empty() || state.exhausted ||
        !audio || !video || state.audio != audio || state.video != video || emulator.audioRenderer != audio || emulator.videoRenderer != video ||
        requested != state.loadedPath || state.cartridge != rom || !workRAM || !exact(rom, cartridgeSize) ||
        (!state.owner.empty() && state.owner != owner.UTF8String)) return 0;
    state.owner = owner.UTF8String; return state.generation;
}
+ (NSData *)readSnapshotForOwner:(NSString *)owner generation:(uint64_t)generation {
    auto &state = registry(); std::lock_guard<std::mutex> lock(state.lock);
    if (!NSThread.isMainThread || !admits(state, owner, generation)) return nil;
    // Fixed homebrew EWRAM port, copied rather than exposing mutable core memory.
    return [NSData dataWithBytes:workRAM + 0x400 length:2048];
}
+ (BOOL)publishHost:(NSData *)host owner:(NSString *)owner generation:(uint64_t)generation {
    auto &state = registry(); std::lock_guard<std::mutex> lock(state.lock);
    if (!NSThread.isMainThread || !admits(state, owner, generation) || host.length != 1024) return NO;
    const auto *bytes = static_cast<const uint8_t *>(host.bytes);
    const auto sequence = word(bytes + 8);
    if (!sequence || (sequence & 1) || word(bytes) != 0x31484d52) return NO;
    put(workRAM + 8, sequence | 1);
    std::atomic_thread_fence(std::memory_order_release);
    memcpy(workRAM, bytes, 8); memcpy(workRAM + 12, bytes + 12, 1012);
    std::atomic_thread_fence(std::memory_order_release);
    put(workRAM + 8, sequence);
    return YES;
}
+ (void)releaseOwner:(NSString *)owner generation:(uint64_t)generation {
    auto &state = registry(); std::lock_guard<std::mutex> lock(state.lock);
    // Release is also safe from Swift deinit: no core/RAM access or original IMP.
    if (generation && state.generation == generation && owner.length && state.owner == owner.UTF8String) state.owner.clear();
}
@end
