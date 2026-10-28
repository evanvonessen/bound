#include <fstream>
#include <iterator>
#include <cassert>
#include <cstdio>
#include "MultiRedProfiles.h"

// Compile against the production header; pass a freshly built cartridge.
int main(int argc, char **argv) {
    assert(argc == 2);
    std::ifstream stream(argv[1], std::ios::binary);
    std::vector<uint8_t> original((std::istreambuf_iterator<char>(stream)), {});
    assert(original.size() == 0x2000000);
    auto image = original;
    auto admit = [&]() { return runtimeProfile(image.data(), true); };
    auto sign = [&]() {
        auto payload = image;
        MultiRedCurrentProfile.normalize(payload.data());
        memset(payload.data()+BoundRuntimeOffset, 0xFF, BoundRuntimeSize);
        CC_SHA256(payload.data(), unsigned(payload.size()), image.data()+BoundRuntimeOffset+24);
    };
    const auto *first = admit(); assert(first);
    std::array<uint8_t,32> firstHash;
    memcpy(firstHash.data(), first->canonicalHash, 32);
    // A second release grows cartridge-owned code and changes its ruleset.
    image[0x1FC8FFE] ^= 1;
    image[GameDescriptorOffset+20] ^= 1;
    sign();
    const auto *second = admit(); assert(second);
    assert(memcmp(firstHash.data(), second->canonicalHash, 32));
    auto restored = image;
    assert(second->restoreCanonical(restored.data(), [](const uint8_t *p,unsigned n,uint8_t *d){CC_SHA256(p,n,d);}));
    uint8_t digest[32]; CC_SHA256(restored.data(), unsigned(restored.size()), digest);
    assert(!memcmp(digest, GameDescriptor+84, 32));
    // Same host compatibility does not authorize another release's raw state.
    restored = image;
    assert(!first->restoreCanonical(restored.data(), [](const uint8_t *p,unsigned n,uint8_t *d){CC_SHA256(p,n,d);}));
    for (unsigned offset : {8u,12u,16u,20u,64u,68u,72u}) {
        image = original; image[BoundRuntimeOffset+offset] ^= 0x80;
        assert(!admit());
    }
    image = original; image[0x1FC8FFE] ^= 1; assert(!admit());
    // Even a recomputed payload digest cannot substitute a different engine.
    image = original; image[0x1000] ^= 1; sign(); assert(!admit());
    image = original; image[GameDescriptorOffset+56] ^= 1; sign(); assert(!admit());
    image = original; assert(admit());
    puts("Runtime interface: compatible future release accepted; unsupported bindings, capabilities, layouts and corrupt payloads rejected.");
}
