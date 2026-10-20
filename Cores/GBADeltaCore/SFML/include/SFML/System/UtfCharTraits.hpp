// Bound compatibility addition: explicit traits for SFML's unsigned UTF code
// units. Standard libraries only guarantee std::char_traits specializations
// for the standard character types.

#ifndef SFML_UTFCHARTRAITS_HPP
#define SFML_UTFCHARTRAITS_HPP

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <cwchar>
#include <iosfwd>
#include <limits>
#include <type_traits>

namespace sf
{
namespace priv
{
template <typename T>
struct UtfCharTraits
{
    typedef T char_type;
    typedef std::uint_least64_t int_type;
    typedef std::streamoff off_type;
    typedef std::streampos pos_type;
    typedef std::mbstate_t state_type;

    static_assert(std::is_unsigned<T>::value &&
                  std::numeric_limits<T>::digits < std::numeric_limits<int_type>::digits,
                  "UTF code units must fit in int_type alongside a distinct EOF value");

    static void assign(char_type& destination, const char_type& source) { destination = source; }
    static bool eq(char_type left, char_type right) { return left == right; }
    static bool lt(char_type left, char_type right) { return left < right; }

    static int compare(const char_type* left, const char_type* right, std::size_t count)
    {
        for (std::size_t i = 0; i < count; ++i)
        {
            if (lt(left[i], right[i])) return -1;
            if (lt(right[i], left[i])) return 1;
        }
        return 0;
    }

    static std::size_t length(const char_type* string)
    {
        std::size_t count = 0;
        while (!eq(string[count], char_type())) ++count;
        return count;
    }

    static const char_type* find(const char_type* string, std::size_t count, const char_type& value)
    {
        for (std::size_t i = 0; i < count; ++i)
            if (eq(string[i], value)) return string + i;
        return NULL;
    }

    static char_type* move(char_type* destination, const char_type* source, std::size_t count)
    {
        if (count) std::memmove(destination, source, count * sizeof(char_type));
        return destination;
    }

    static char_type* copy(char_type* destination, const char_type* source, std::size_t count)
    {
        if (count) std::memcpy(destination, source, count * sizeof(char_type));
        return destination;
    }

    static char_type* assign(char_type* destination, std::size_t count, char_type value)
    {
        if (count) std::fill_n(destination, count, value);
        return destination;
    }

    static int_type to_int_type(char_type value) { return static_cast<int_type>(value); }
    static char_type to_char_type(int_type value) { return static_cast<char_type>(value); }
    static bool eq_int_type(int_type left, int_type right) { return left == right; }
    static int_type eof() { return std::numeric_limits<int_type>::max(); }
    static int_type not_eof(int_type value) { return eq_int_type(value, eof()) ? 0 : value; }
};
}
}

#endif
