#pragma once
#include <algorithm>
#include <cstdint>
#include <string>
#include <vector>

// Bound allocation by the actual tokenized request without dropping any input
// or reducing the requested output allowance. Zero means the request cannot fit.
inline int qf_context_capacity(int prompt, int output, int limit) {
    limit = std::clamp(limit, 512, 4096);
    if (prompt < 0 || output < 1 || output > 512 || prompt > limit - output - 8) return 0;
    const int required = prompt + output + 8;
    int capacity = 512;
    while (capacity < required && capacity < limit) capacity = std::min(limit, capacity * 2);
    return capacity;
}

// Hybrid/recurrent models cannot safely rewind to an arbitrary shared prefix.
// Reuse only a COMPLETE, already evaluated prefix, in the identical account,
// household, language and permission scope. Every other case starts fresh.
template<class Token>
inline bool qf_can_append_context(const std::string &old_scope, const std::string &scope,
    const std::vector<Token> &evaluated, const std::vector<Token> &next,
    int capacity, int output, int old_threads, int threads) {
    return !scope.empty() && scope == old_scope && old_threads == threads
        && !evaluated.empty() && evaluated.size() < next.size()
        && next.size() + size_t(output) + 8 <= size_t(capacity)
        && std::equal(evaluated.begin(), evaluated.end(), next.begin());
}
