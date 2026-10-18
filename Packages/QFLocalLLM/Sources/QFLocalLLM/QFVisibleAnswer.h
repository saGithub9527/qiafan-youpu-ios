#pragma once
#include <string>
// The local model uses non-thinking prefill. If it nevertheless emits a
// reasoning block, withhold it and any partial delimiter from visible output.
inline std::string qf_visible_answer(const std::string &input) {
    const std::string open = "<think>", close = "</think>";
    std::string visible; bool hidden = false;
    for (size_t at = 0; at < input.size();) {
        if (input.compare(at, open.size(), open) == 0) { hidden = true; at += open.size(); continue; }
        if (input.compare(at, close.size(), close) == 0) { hidden = false; at += close.size(); continue; }
        const auto remaining = input.size() - at;
        if ((remaining < open.size() && open.compare(0, remaining, input, at, remaining) == 0)
            || (remaining < close.size() && close.compare(0, remaining, input, at, remaining) == 0)) break;
        if (!hidden) visible.push_back(input[at]);
        ++at;
    }
    return visible;
}
