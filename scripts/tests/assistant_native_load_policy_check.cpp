#include "QFLoadPolicy.h"
#include <cassert>
#include <cstdint>
#include <initializer_list>
#include <iostream>
#include <limits>

int main() {
    constexpr int64_t model = 1396198496;
    constexpr uint64_t automatic = uint64_t(model) + 384ULL * 1024 * 1024;
    constexpr uint64_t forced = uint64_t(model) + 256ULL * 1024 * 1024;
    auto check = [](int32_t policy, int64_t bytes, bool valid, uint64_t available, bool suspended,
                    bool mapped, bool refused, uint64_t required) {
        const auto result = qf_select_cold_load(policy, bytes, valid, available, suspended);
        assert(result.memory_mapped == mapped);
        assert(result.refused == refused);
        assert(result.required_available_bytes == required);
    };
    // Equality admits RAM; one byte short must not allocate it.
    check(0, model, true, automatic, false, false, false, automatic);
    check(0, model, true, automatic - 1, false, true, false, automatic);
    check(0, model, true, forced, false, true, false, automatic);
    check(2, model, true, forced, false, false, false, forced);
    check(2, model, true, forced - 1, false, true, true, forced);
    for (bool valid : {false, true}) {
        check(0, model, valid, 0, false, true, false, automatic);
        check(2, model, valid, 0, false, true, true, forced);
    }
    check(0, model, false, UINT64_MAX, false, true, false, automatic);
    check(2, model, false, UINT64_MAX, false, true, true, forced);
    check(0, model, true, UINT64_MAX, true, true, false, automatic);
    check(2, model, true, UINT64_MAX, true, true, true, forced);
    // Forced mmap needs neither a RAM admission snapshot nor a RAM-sized model.
    check(1, model, false, 0, true, true, false, 0);
    check(1, -1, false, 0, true, true, false, 0);
    for (int64_t invalid : {int64_t(-1), int64_t(0), std::numeric_limits<int64_t>::max()}) {
        check(0, invalid, true, UINT64_MAX, false, true, false, 0);
        check(2, invalid, true, UINT64_MAX, false, true, true, 0);
    }
    for (int32_t invalid : {-1, 3, std::numeric_limits<int32_t>::max()})
        check(invalid, model, true, UINT64_MAX, false, true, true, 0);
    const int64_t largest = std::numeric_limits<int64_t>::max() - 384LL * 1024 * 1024;
    check(0, largest, true, uint64_t(std::numeric_limits<int64_t>::max()), false,
          false, false, uint64_t(std::numeric_limits<int64_t>::max()));
    check(0, largest + 1, true, UINT64_MAX, false, true, false, 0);
    for (int capacity : {-1, 0, 1, 511, 1025, 1536, 2048, 4096})
        assert(!qf_automatic_context_uses_ram(capacity));
    for (int capacity : {512, 768, 1024}) assert(qf_automatic_context_uses_ram(capacity));
    std::cout << "PASS cold load policies, admission boundaries, suspension and context cap\n";
}
