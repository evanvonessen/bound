#include <fstream>
#include <iterator>
#include <cassert>
#include <cstdio>
#include <cstring>
#include <algorithm>
#include "MultiRedProfiles.h"

// Compile against the production header; pass a freshly built cartridge.
static void verify(const char *path) {
    std::ifstream stream(path, std::ios::binary);
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
    // Every record, including canonical padding, is part of one exact set.
    // The payload hash excludes this table, so rejection must come from the
    // binding validator rather than an unrelated ROM digest mismatch.
    const unsigned count=runtimeWord(image.data()+BoundRuntimeOffset+20);
    for(unsigned i=0;i<count;i++) {
        const size_t row=BoundRuntimeOffset+64+24*i;
        for(unsigned byte : {0u,4u,8u,23u}) {
            image[row+byte]^=0x80; assert(!admit()); image[row+byte]^=0x80;
        }
    }
    auto *table=image.data()+BoundRuntimeOffset;
    for(unsigned altered : {0u,1u,count-1,count+1,0xFFFFFFFFu}) {
        for(unsigned byte=0;byte<4;byte++)table[20+byte]=uint8_t(altered>>(8*byte));
        assert(!admit());
    }
    image=original;table=image.data()+BoundRuntimeOffset;
    std::array<uint8_t,24> firstRecord;
    memcpy(firstRecord.data(),table+64,24);
    memcpy(table+64,table+64+24*(count-1),24);
    memcpy(table+64+24*(count-1),firstRecord.data(),24);
    assert(!admit());
    image=original;table=image.data()+BoundRuntimeOffset;
    memcpy(table+64+24,table+64,24);assert(!admit());
    image=original;assert(admit());
}

template<size_t Count>
static std::array<uint8_t,BoundRuntimeSize> bindingsTable(const GameBaseDefinition (&bindings)[Count]) {
    std::array<uint8_t,BoundRuntimeSize> table{};
    for(unsigned byte=0;byte<4;byte++)table[20+byte]=uint8_t(Count>>(8*byte));
    for(size_t i=0;i<Count;i++) {
        auto *row=table.data()+64+24*i;
        for(unsigned byte=0;byte<4;byte++) {
            row[byte]=uint8_t(bindings[i].offset>>(8*byte));
            row[4+byte]=uint8_t(bindings[i].size>>(8*byte));
        }
        memcpy(row+8,bindings[i].bytes,16);
    }
    return table;
}

int main(int argc,char **argv) {
    assert(argc>=2);
    auto current=bindingsTable(GameBaseDefinitions);
    auto legacy=bindingsTable(BoundLegacyRuntimeBindings);
    auto matches=[](const uint8_t *table) {
        return runtimeBindingsMatch(table,GameBaseDefinitions)
            ||runtimeBindingsMatch(table,BoundLegacyRuntimeBindings);
    };
    assert(matches(current.data())&&matches(legacy.data()));
    // Once the current ABI gains records, exercise mixed sets in both
    // directions. Identical historical records can remain shared unchanged.
    const size_t overlap=std::min(sizeof(GameBaseDefinitions)/sizeof(*GameBaseDefinitions),
                                 sizeof(BoundLegacyRuntimeBindings)/sizeof(*BoundLegacyRuntimeBindings));
    for(size_t i=0;i<overlap;i++) {
        const size_t offset=64+24*i;
        if(!memcmp(current.data()+offset,legacy.data()+offset,24))continue;
        auto mixed=current;memcpy(mixed.data()+offset,legacy.data()+offset,24);
        assert(!matches(mixed.data()));
        mixed=legacy;memcpy(mixed.data()+offset,current.data()+offset,24);
        assert(!matches(mixed.data()));
    }
    for(int i=1;i<argc;i++)verify(argv[i]);
    puts("Runtime interface: compatible future release accepted; unsupported bindings, capabilities, layouts and corrupt payloads rejected.");
}
