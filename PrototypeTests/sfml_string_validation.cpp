#include <SFML/System/String.hpp>
#include <algorithm>
#include <cassert>
#include <iostream>
#include <limits>

template <typename T>
void validateTraits()
{
    typedef sf::priv::UtfCharTraits<T> Traits;
    const T source[] = {1, 0, 127, 128, std::numeric_limits<T>::max()};
    T copy[5] = {};
    assert(Traits::copy(copy, source, 5) == copy);
    assert(std::equal(copy, copy + 5, source));
    assert(Traits::length(source) == 1);
    assert(Traits::find(source, 5, T()) == source + 1);
    assert(Traits::find(source, 5, T(5)) == NULL);
    assert(Traits::compare(copy, source, 5) == 0);
    copy[2] = 126;
    assert(Traits::compare(copy, source, 5) < 0);
    assert(Traits::compare(source, copy, 5) > 0);

    T overlap[] = {1, 2, 3, 4, 5};
    Traits::move(overlap + 1, overlap, 4);
    const T shiftedRight[] = {1, 1, 2, 3, 4};
    assert(std::equal(overlap, overlap + 5, shiftedRight));
    Traits::move(overlap, overlap + 1, 4);
    const T shiftedLeft[] = {1, 2, 3, 4, 4};
    assert(std::equal(overlap, overlap + 5, shiftedLeft));
    Traits::assign(overlap, 5, T(42));
    assert(std::count(overlap, overlap + 5, T(42)) == 5);
    Traits::assign(overlap[0], T(7));
    assert(overlap[0] == 7);
    assert(Traits::move(NULL, NULL, 0) == NULL);
    assert(Traits::copy(NULL, NULL, 0) == NULL);
    assert(Traits::assign(NULL, 0, T()) == NULL);
    assert(Traits::compare(NULL, NULL, 0) == 0);
    assert(Traits::find(NULL, 0, T()) == NULL);
    for (std::size_t i = 0; i < 5; ++i)
    {
        const typename Traits::int_type integer = Traits::to_int_type(source[i]);
        assert(!Traits::eq_int_type(integer, Traits::eof()));
        assert(Traits::to_char_type(integer) == source[i]);
        assert(Traits::not_eof(integer) == integer);
    }
    assert(!Traits::eq_int_type(Traits::not_eof(Traits::eof()), Traits::eof()));
}

int main()
{
    validateTraits<sf::Uint8>();
    validateTraits<sf::Uint16>();
    validateTraits<sf::Uint32>();

    // A, embedded NUL, e-acute, CJK water, and a supplementary-plane smile.
    const sf::Uint32 utf32[] = {0x41, 0, 0xe9, 0x6c34, 0x1f642};
    const sf::Uint16 utf16[] = {0x41, 0, 0xe9, 0x6c34, 0xd83d, 0xde42};
    const sf::Uint8 utf8[] = {0x41, 0, 0xc3, 0xa9, 0xe6, 0xb0, 0xb4, 0xf0, 0x9f, 0x99, 0x82};
    const sf::String text = sf::String::fromUtf32(utf32, utf32 + 5);
    const sf::String::Utf8String bytes = text.toUtf8();
    const sf::String::Utf16String words = text.toUtf16();
    const sf::String::Utf32String points = text.toUtf32();
    assert(bytes.size() == 11 && std::equal(bytes.begin(), bytes.end(), utf8));
    assert(words.size() == 6 && std::equal(words.begin(), words.end(), utf16));
    assert(points.size() == 5 && std::equal(points.begin(), points.end(), utf32));
    assert(text == sf::String::fromUtf8(bytes.begin(), bytes.end()));
    assert(text == sf::String::fromUtf16(words.begin(), words.end()));
    assert(text == sf::String(points));
    assert(text.getSize() == 5 && text.getData()[5] == 0);
    assert(text.find(sf::String(sf::Uint32())) == 1);
    assert(text.find(sf::String(sf::Uint32(0x1f642))) == 4);
    assert(text.find(sf::String(sf::Uint32(0x42))) == sf::String::InvalidPos);
    assert(sf::String(sf::Uint32(0xe9)) < sf::String(sf::Uint32(0x6c34)));

    sf::String edited = text;
    edited.insert(1, edited); // Source aliases the destination.
    assert(edited.getSize() == 10 && edited.substring(1, 5) == text);
    edited.erase(1, 5);
    assert(edited == text);
    edited.replace(0, 1, sf::String(sf::Uint32(0x42)));
    assert(edited[0] == 0x42 && edited.substring(1) == text.substring(1));
    const sf::String empty;
    assert(empty.toUtf8().empty() && empty.toUtf16().empty() && empty.toUtf32().empty());
    std::cout << "SFML unsigned UTF string validation passed\n";
}
