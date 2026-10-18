#pragma once
#include <cstdint>
#include <limits>

struct qf_cold_load_selection {
    bool memory_mapped;
    bool refused;
    uint64_t required_available_bytes;
};

// Cold-load admission only. The caller samples available memory AFTER releasing
// incompatible caches. Already loaded RAM must not pay the file-size budget twice.
// 0 automatic, 1 forced mmap, 2 forced RAM. No allocation or OS queries here.
inline qf_cold_load_selection qf_select_cold_load(int32_t policy, int64_t model_bytes,
    bool available_valid, uint64_t available, bool ram_suspended) {
    if (policy == 1) return {true, false, 0};
    if (policy != 0 && policy != 2) return {true, true, 0};
    const bool automatic = policy == 0;
    const uint64_t reserve = (automatic ? 384ULL : 256ULL) * 1024 * 1024;
    const qf_cold_load_selection invalid{true, !automatic, 0};
    // Keep the total representable in the signed file-size domain too.
    if (model_bytes <= 0
        || uint64_t(model_bytes) > uint64_t(std::numeric_limits<int64_t>::max()) - reserve)
        return invalid;
    const uint64_t required = uint64_t(model_bytes) + reserve;
    const bool ram = !ram_suspended && available_valid && available >= required;
    return {!ram, !automatic && !ram, required};
}

// qf_context_capacity has a 512-token minimum. Larger-context RAM remains an
// unverified experiment; this is a capability limit, never permission to trim input.
inline bool qf_automatic_context_uses_ram(int capacity) {
    return capacity >= 512 && capacity <= 1024;
}
