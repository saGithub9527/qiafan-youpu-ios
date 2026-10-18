#include "QFLocalLLM.h"
#include "QFVisibleAnswer.h"
#include "QFInferenceReuse.h"
#include "QFLoadPolicy.h"
#include <llama.h>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <sys/resource.h>
#include <sys/stat.h>
#include <vector>
#ifdef __APPLE__
#include <TargetConditionals.h>
#include <mach/mach.h>
#if TARGET_OS_IOS
#include <os/proc.h>
#endif
#endif

static qf_llm_memory_snapshot qf_process_memory() {
    qf_llm_memory_snapshot value{};
#ifdef __APPLE__
    task_vm_info_data_t info{};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, reinterpret_cast<task_info_t>(&info), &count) == KERN_SUCCESS
        && count >= TASK_VM_INFO_REV1_COUNT) {
        value.phys_footprint_bytes = info.phys_footprint;
        value.phys_footprint_valid = true;
    }
#if TARGET_OS_IOS
    if (__builtin_available(iOS 13.0, *)) {
        // Snapshot of this app's remaining dirty-memory limit, not device free RAM.
        value.available_memory_bytes = os_proc_available_memory();
        value.available_memory_valid = true;
    }
#endif
#endif
    return value;
}

static std::atomic<bool> qf_ram_suspended{false};
static std::atomic<uint64_t> qf_request_sequence{0};
void qf_llm_note_memory_pressure() { qf_ram_suspended.store(true); }
struct qf_llm_cancellation {
    const uint64_t request_id = ++qf_request_sequence;
    std::atomic<bool> cancelled{false}, ram_active{false}, memory_interrupted{false};
};
qf_llm_cancellation *qf_llm_cancel_create() { return new qf_llm_cancellation; }
void qf_llm_cancel_destroy(qf_llm_cancellation *flag) { delete flag; }
void qf_llm_cancel(qf_llm_cancellation *flag) { if (flag) flag->cancelled.store(true); }
bool qf_llm_is_cancelled(qf_llm_cancellation *flag) { return flag && flag->cancelled.load(); }
void qf_llm_memory_warning(qf_llm_cancellation *flag) {
    if (flag && flag->ram_active.load()) {
        qf_ram_suspended.store(true); // Avoid repeated high-memory reloads in this process.
        flag->memory_interrupted.store(true);
        qf_llm_cancel(flag);
    }
}
bool qf_llm_memory_interrupted(qf_llm_cancellation *flag) { return flag && flag->memory_interrupted.load(); }

// The model retains its load params. Keep callback userdata alive with the model,
// and detach this call's cancellation pointer before the synchronous load returns.
struct qf_load_progress {
    std::mutex mutex;
    qf_llm_cancellation *flag = nullptr;
    bool sample_progress = false;
    uint64_t peak_footprint = 0, min_available = 0;
    uint32_t samples = 0;
    bool footprint_valid = false, available_valid = false;
    void sample(const qf_llm_memory_snapshot &value) {
        ++samples;
        if (value.phys_footprint_valid) {
            peak_footprint = std::max(peak_footprint, value.phys_footprint_bytes);
            footprint_valid = true;
        }
        if (value.available_memory_valid) {
            min_available = available_valid ? std::min(min_available, value.available_memory_bytes) : value.available_memory_bytes;
            available_valid = true;
        }
    }
    bool update() {
        std::lock_guard<std::mutex> lock(mutex);
        if (sample_progress) sample(qf_process_memory());
        return !qf_llm_is_cancelled(flag);
    }
    void finish(qf_llm_metrics &metrics) {
        std::lock_guard<std::mutex> lock(mutex);
        flag = nullptr;
        metrics.memory_after_load = qf_process_memory();
        sample(metrics.memory_after_load);
        metrics.load_sampled_peak_phys_footprint_bytes = peak_footprint;
        metrics.load_sampled_min_available_memory_bytes = min_available;
        metrics.load_memory_sample_count = samples;
        metrics.load_sampled_footprint_valid = footprint_valid;
        metrics.load_sampled_available_valid = available_valid;
    }
};

// One foreground inference at a time. No model, prompts or KV state go to disk.
struct qf_runtime_cache {
    // Declared first so model destruction precedes callback userdata destruction.
    std::unique_ptr<qf_load_progress> load_progress;
    std::unique_ptr<llama_model, decltype(&llama_model_free)> model{nullptr, llama_model_free};
    std::unique_ptr<llama_context, decltype(&llama_free)> context{nullptr, llama_free};
    std::string path, scope;
    struct stat identity{};
    std::vector<llama_token> evaluated;
    int threads = 0;
    int micro_batch_tokens = 0;
    bool op_offload = true;
    bool memory_mapped = true;
    uint64_t last_request_id = 0;
    void clear_context() { context.reset(); evaluated.clear(); scope.clear(); }
    void clear() { clear_context(); model.reset(); load_progress.reset(); path.clear(); last_request_id = 0; }
};
static std::mutex qf_runtime_mutex;
static qf_runtime_cache qf_runtime;
void qf_llm_release_cache() {
    std::lock_guard<std::mutex> lock(qf_runtime_mutex);
    qf_runtime.clear();
}
void qf_llm_release_cancelled_ram_cache(qf_llm_cancellation *flag) {
    std::lock_guard<std::mutex> lock(qf_runtime_mutex);
    if (flag && qf_runtime.last_request_id == flag->request_id && !qf_runtime.memory_mapped) qf_runtime.clear();
}

static std::string safe_text(const char *text) {
    std::string value = text ? text : "";
    for (const char *marker : {"<|im_start|>", "<|im_end|>", "<|endoftext|>"}) {
        size_t at;
        while ((at = value.find(marker)) != std::string::npos) value.replace(at, strlen(marker), " ");
    }
    return value;
}

struct qf_elapsed {
    double &milliseconds;
    std::chrono::steady_clock::time_point start = std::chrono::steady_clock::now();
    ~qf_elapsed() { milliseconds += std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count(); }
};

// Follows the pinned llama.cpp common/sampling.cpp grammar rejection path (MIT).
// Restore raw logits before fallback; rejected proposals must never be accepted.
static llama_token sample_with_grammar(llama_sampler *chain, llama_sampler *grammar,
    llama_context *context, int vocab_size, std::vector<llama_token_data> &storage,
    qf_llm_metrics &metrics) {
    llama_synchronize(context);
    qf_elapsed timing{metrics.sampling_ms};
    const float *logits = llama_get_logits_ith(context, -1);
    if (!logits || vocab_size <= 0) return LLAMA_TOKEN_NULL;
    storage.resize(vocab_size);
    auto reset = [&] {
        for (llama_token id = 0; id < vocab_size; ++id) storage[id] = {id, logits[id], 0.0f};
        return llama_token_data_array{storage.data(), storage.size(), -1, false};
    };
    auto candidates = reset();
    llama_sampler_apply(chain, &candidates);
    auto selected = [&] {
        return candidates.selected >= 0 && size_t(candidates.selected) < candidates.size
            && std::isfinite(candidates.data[candidates.selected].logit);
    };
    if (!selected()) return LLAMA_TOKEN_NULL;
    llama_token token = candidates.data[candidates.selected].id;
    llama_token_data single{token, 1.0f, 0.0f};
    llama_token_data_array probe{&single, 1, -1, false};
    llama_sampler_apply(grammar, &probe);
    if (!std::isfinite(single.logit)) {
        ++metrics.grammar_fallbacks;
        candidates = reset();
        llama_sampler_apply(grammar, &candidates);
        llama_sampler_apply(chain, &candidates);
        if (!selected()) return LLAMA_TOKEN_NULL;
        token = candidates.data[candidates.selected].id;
    }
    llama_sampler_accept(grammar, token);
    llama_sampler_accept(chain, token);
    return token;
}

int32_t qf_llm_complete(const char *path, const char *system,
    const qf_llm_message *messages, size_t count, int32_t threads,
    int32_t context_tokens, int32_t max_tokens, const char *output_grammar, const char *session_scope, int32_t micro_batch_tokens, bool op_offload, int32_t load_policy, qf_llm_metrics *metrics_out,
    qf_llm_output_callback on_output, void *output_context, qf_llm_cancellation *flag,
    char *result, size_t result_capacity, char *error, size_t error_capacity) {
    auto fail = [&](int code, const char *why) {
        if (code == 1 && qf_llm_memory_interrupted(flag)) { code = 8; why = "RAM inference interrupted by memory pressure"; }
        if (error && error_capacity) snprintf(error, error_capacity, "%s", why); return code;
    };
    if (!path || !result || !result_capacity || count > 32 || !messages) return fail(2, "Invalid input");
    if (micro_batch_tokens != 16 && micro_batch_tokens != 32 && micro_batch_tokens != 64 && micro_batch_tokens != 128)
        return fail(2, "Invalid micro batch size");
    if (load_policy < 0 || load_policy > 2) return fail(2, "Invalid load policy");
    std::lock_guard<std::mutex> lock(qf_runtime_mutex);
    result[0] = 0;
    qf_llm_metrics metrics{};
    metrics.load_policy = load_policy;
    struct metrics_receipt {
        qf_llm_metrics *out; qf_llm_metrics &value;
        rusage before{};
        std::chrono::steady_clock::time_point began = std::chrono::steady_clock::now();
        metrics_receipt(qf_llm_metrics *out, qf_llm_metrics &value) : out(out), value(value) {
            getrusage(RUSAGE_SELF, &before);
            value.memory_start = qf_process_memory();
        }
        ~metrics_receipt() {
            rusage after{}; getrusage(RUSAGE_SELF, &after);
            auto cpu_ms = [](const rusage &r) {
                return (r.ru_utime.tv_sec + r.ru_stime.tv_sec) * 1000.0
                    + (r.ru_utime.tv_usec + r.ru_stime.tv_usec) / 1000.0;
            };
            value.process_cpu_ms = cpu_ms(after) - cpu_ms(before);
            value.process_minor_faults = after.ru_minflt - before.ru_minflt;
            value.process_major_faults = after.ru_majflt - before.ru_majflt;
            value.total_ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - began).count();
            if (!value.memory_sampled_before_context_release) value.memory_end = qf_process_memory();
#ifdef __APPLE__
            value.process_peak_rss_bytes = uint64_t(after.ru_maxrss); // Darwin reports bytes.
#else
            value.process_peak_rss_bytes = uint64_t(after.ru_maxrss) * 1024;
#endif
            if (out) *out = value;
        }
    } receipt{metrics_out, metrics};
    if (qf_llm_is_cancelled(flag)) return fail(1, "Cancelled");
    try {
        static std::once_flag once;
        std::call_once(once, [] { llama_backend_init(); });
        auto &cache = qf_runtime;
        struct pressure_receipt {
            qf_runtime_cache &cache; qf_llm_cancellation *flag; qf_llm_metrics &metrics;
            bool completed = false;
            ~pressure_receipt() {
                if (flag) flag->ram_active.store(false);
                metrics.memory_pressure_interrupted = qf_llm_memory_interrupted(flag);
                if (metrics.memory_pressure_interrupted || (!completed && !cache.memory_mapped)) cache.clear();
                else if (completed && cache.model) cache.last_request_id = flag ? flag->request_id : 0;
            }
        } pressure_receipt{cache, flag, metrics};
        struct stat identity{};
        if (stat(path, &identity) != 0) return fail(2, "Model file unavailable");
        if (cache.path != path || cache.identity.st_ino != identity.st_ino || cache.identity.st_size != identity.st_size
            || cache.identity.st_mtime != identity.st_mtime) cache.clear();
        if (cache.model && ((load_policy == 1 && !cache.memory_mapped) || (load_policy == 2 && cache.memory_mapped)
            || (load_policy == 0 && qf_ram_suspended.load() && !cache.memory_mapped))) cache.clear();
        metrics.model_reused = bool(cache.model);
        bool memory_mapped = cache.model ? cache.memory_mapped : true;
        auto load_model = [&](int32_t policy) -> int {
            metrics.memory_before_load = qf_process_memory();
            const auto selected = qf_select_cold_load(policy, identity.st_size,
                metrics.memory_before_load.available_memory_valid, metrics.memory_before_load.available_memory_bytes,
                qf_ram_suspended.load());
            memory_mapped = selected.memory_mapped;
            metrics.ram_required_available_bytes = selected.required_available_bytes;
            metrics.ram_admission_refused = selected.refused;
            if (selected.refused) return fail(7, "RAM load refused: unavailable or insufficient process memory headroom");
            if (qf_llm_is_cancelled(flag)) return fail(1, "Cancelled");
            if (flag) flag->ram_active.store(!memory_mapped);
            auto mp = llama_model_default_params(); mp.n_gpu_layers = 0;
            mp.load_mode = memory_mapped ? LLAMA_LOAD_MODE_MMAP : LLAMA_LOAD_MODE_NONE;
            if (!memory_mapped) mp.lazy_mode = LLAMA_LAZY_MODE_OFF;
            mp.use_extra_bufts = false;
            cache.load_progress = std::make_unique<qf_load_progress>();
            cache.load_progress->flag = flag;
            cache.load_progress->sample_progress = !memory_mapped;
            cache.load_progress->sample(metrics.memory_before_load);
            mp.progress_callback_user_data = cache.load_progress.get();
            mp.progress_callback = [](float, void *data) { return static_cast<qf_load_progress *>(data)->update(); };
            {
                struct progress_receipt {
                    qf_load_progress &progress; qf_llm_metrics &metrics;
                    ~progress_receipt() { progress.finish(metrics); }
                } progress_receipt{*cache.load_progress, metrics};
                qf_elapsed timing{metrics.load_ms};
                cache.model.reset(llama_model_load_from_file(path, mp));
            }
            cache.path = path; cache.identity = identity; cache.memory_mapped = memory_mapped;
            return 0;
        };
        if (!cache.model) {
            const int loaded = load_model(load_policy);
            if (loaded) return loaded;
            if (!cache.model && load_policy == 0 && !memory_mapped && !qf_llm_is_cancelled(flag)) {
                cache.clear();
                const int fallback = load_model(1);
                if (fallback) return fallback;
            }
        }
        if (flag) flag->ram_active.store(!memory_mapped);
        metrics.memory_mapped = memory_mapped;
        metrics.load_mode_valid = bool(cache.model);
        if (qf_llm_is_cancelled(flag)) return fail(1, "Cancelled");
        if (!cache.model) return fail(2, "Model loading failed");
        // A cancelled or failed graph is never reused. Abort userdata must not
        // outlive this request's Swift cancellation object.
        struct context_receipt {
            qf_runtime_cache &cache;
            qf_llm_metrics &metrics;
            bool keep = false;
            ~context_receipt() {
                // Capture while the context (and any BLAS workspace) still exists.
                metrics.memory_end = qf_process_memory();
                metrics.memory_sampled_before_context_release = true;
                if (cache.context) llama_set_abort_callback(cache.context.get(), nullptr, nullptr);
                if (!keep) cache.clear_context();
            }
        } context_receipt{cache, metrics};
        auto cp = llama_context_default_params();
        cp.n_batch = 128; cp.n_ubatch = micro_batch_tokens;
        metrics.micro_batch_tokens = micro_batch_tokens;
        cp.n_outputs_max = 1;
        cp.n_threads = cp.n_threads_batch = std::clamp(threads, 1, 4);
        cp.offload_kqv = false;
        // No GPU backend is built. The Swift default remains true, allowing
        // the existing Accelerate BLAS backend for prompt matrices >=32 rows.
        cp.op_offload = op_offload;
        cp.abort_callback = [](void *data) { return qf_llm_is_cancelled(static_cast<qf_llm_cancellation *>(data)); };
        cp.abort_callback_data = flag;
        const auto *vocab = llama_model_get_vocab(cache.model.get());
        std::vector<std::string> roles{"system"}, contents{safe_text(system)};
        for (size_t i = 0; i < count; ++i) {
            std::string role = messages[i].role ? messages[i].role : "";
            if (role != "user" && role != "assistant") return fail(2, "Unsupported role");
            auto text = safe_text(messages[i].content);
            if (text.size() > 32768) return fail(5, "Message too long");
            // Match the same non-thinking assistant prefill used at generation.
            // Exact token comparison below rejects any mismatch or hidden output.
            if (role == "assistant") text = "<think>\n\n</think>\n\n" + text;
            roles.push_back(role); contents.push_back(std::move(text));
        }
        std::vector<llama_token> tokens;
        for (;;) {
            std::vector<llama_chat_message> chat;
            for (size_t i = 0; i < roles.size(); ++i) chat.push_back({roles[i].c_str(), contents[i].c_str()});
            int length = llama_chat_apply_template("chatml", chat.data(), chat.size(), true, nullptr, 0);
            if (length <= 0 || length > 262144) return fail(5, "Invalid chat length");
            std::vector<char> buffer(length + 1);
            llama_chat_apply_template("chatml", chat.data(), chat.size(), true, buffer.data(), buffer.size());
            std::string prompt(buffer.data(), length);
            // Qwen's official enable_thinking=false assistant prefill.
            prompt += "<think>\n\n</think>\n\n";
            tokens.resize(prompt.size() + 16);
            int n = llama_tokenize(vocab, prompt.c_str(), int32_t(prompt.size()), tokens.data(), int32_t(tokens.size()), true, true);
            if (n < 0) return fail(5, "Tokenization failed");
            tokens.resize(n);
            cp.n_ctx = qf_context_capacity(n, max_tokens, context_tokens);
            if (cp.n_ctx != 0) break;
            // Do not silently discard earlier user constraints (e.g. allergies).
            // The caller supplies the bounded recent conversation explicitly.
            return fail(5, "Context too long");
        }
        // Automatic RAM is promoted only for the actually validated small contexts.
        // Keep all original tokens and output allowance for larger requests; reload
        // mmap before allocating that context rather than truncating the question.
        if (load_policy == 0 && !memory_mapped && !qf_automatic_context_uses_ram(cp.n_ctx)) {
            if (flag) flag->ram_active.store(false);
            cache.clear(); metrics.model_reused = false;
            const int loaded = load_model(1);
            if (loaded) return loaded;
            metrics.automatic_context_mmap_fallback = true;
            metrics.memory_mapped = memory_mapped;
            metrics.load_mode_valid = bool(cache.model);
            if (qf_llm_is_cancelled(flag)) return fail(1, "Cancelled");
            if (!cache.model) return fail(2, "Model loading failed");
            vocab = llama_model_get_vocab(cache.model.get());
        }
        const std::string scope = session_scope ? session_scope : "";
        // A context owns scheduler/workspace configuration; never append with a changed flag.
        const bool reuse = cache.context && cache.micro_batch_tokens == micro_batch_tokens && cache.op_offload == op_offload
            && (load_policy != 0 || memory_mapped || llama_n_ctx(cache.context.get()) <= 1024)
            && !(output_grammar && *output_grammar)
            && qf_can_append_context(cache.scope, scope, cache.evaluated, tokens,
                int(llama_n_ctx(cache.context.get())), max_tokens, cache.threads, int(cp.n_threads));
        const size_t reused = reuse ? cache.evaluated.size() : 0;
        if (!reuse) {
            cache.clear_context();
            qf_elapsed timing{metrics.context_ms};
            cache.context.reset(llama_init_from_model(cache.model.get(), cp));
        }
        if (qf_llm_is_cancelled(flag)) return fail(1, "Cancelled");
        if (!cache.context) return fail(3, "Context creation failed");
        auto *context = cache.context.get();
        llama_set_abort_callback(context, [](void *data) { return qf_llm_is_cancelled(static_cast<qf_llm_cancellation *>(data)); }, flag);
        metrics.context_tokens = int32_t(llama_n_ctx(context));
        metrics.op_offload = cp.op_offload;
        metrics.prompt_tokens = int32_t(tokens.size());
        metrics.reused_prompt_tokens = int32_t(reused);
        for (size_t offset = reused; offset < tokens.size();) {
            if (qf_llm_is_cancelled(flag)) return fail(1, "Cancelled");
            int n = int(std::min<size_t>(cp.n_batch, tokens.size() - offset));
            int decoded;
            { qf_elapsed timing{metrics.prompt_ms}; decoded = llama_decode(context, llama_batch_get_one(tokens.data() + offset, n)); }
            if (decoded != 0) return fail(qf_llm_is_cancelled(flag) ? 1 : 4, "Prompt decoding failed");
            metrics.evaluated_prompt_tokens += n;
            offset += n;
        }
        cache.evaluated = tokens; cache.scope = scope; cache.threads = int(cp.n_threads);
        cache.micro_batch_tokens = micro_batch_tokens;
        cache.op_offload = op_offload;
        std::unique_ptr<llama_sampler, decltype(&llama_sampler_free)> sampler(llama_sampler_chain_init(llama_sampler_chain_default_params()), llama_sampler_free);
        std::unique_ptr<llama_sampler, decltype(&llama_sampler_free)> grammar(nullptr, llama_sampler_free);
        if (output_grammar && *output_grammar) {
            grammar.reset(llama_sampler_init_grammar(vocab, output_grammar, "root"));
            if (!grammar) return fail(4, "Invalid output grammar");
        }
        // Preserve upstream top-k/presence protection, with a lower app-specific
        // temperature for concise factual replies. The prior low-temperature
        // chain omitted presence penalties and could enter repeated-word loops.
        // Constrained tool selection keeps its existing 0.2 temperature.
        llama_sampler_chain_add(sampler.get(), llama_sampler_init_top_k(20));
        if (!grammar) llama_sampler_chain_add(sampler.get(),
            llama_sampler_init_penalties(llama_vocab_n_tokens(vocab), 256, 1.0f, 0.0f, 2.0f));
        llama_sampler_chain_add(sampler.get(), llama_sampler_init_top_p(1.0f, 1));
        llama_sampler_chain_add(sampler.get(), llama_sampler_init_temp(0.2f));
        llama_sampler_chain_add(sampler.get(), llama_sampler_init_dist(LLAMA_DEFAULT_SEED));
        std::string output;
        bool reached_end = false;
        std::vector<llama_token_data> candidates;
        for (int i = 0; i < std::clamp(max_tokens, 1, 512); ++i) {
            if (qf_llm_is_cancelled(flag)) return fail(1, "Cancelled");
            llama_token token;
            if (grammar) token = sample_with_grammar(sampler.get(), grammar.get(), context, llama_vocab_n_tokens(vocab), candidates, metrics);
            else { qf_elapsed timing{metrics.sampling_ms}; token = llama_sampler_sample(sampler.get(), context, -1); }
            if (token == LLAMA_TOKEN_NULL) return fail(4, "No valid output token");
            if (llama_vocab_is_eog(vocab, token)) { reached_end = true; break; }
            ++metrics.generated_tokens;
            if (metrics.generated_tokens == 1) metrics.first_token_ms = std::chrono::duration<double, std::milli>(
                std::chrono::steady_clock::now() - receipt.began).count();
            char piece[512]; int n = llama_token_to_piece(vocab, token, piece, sizeof(piece), 0, false);
            if (n < 0) return fail(4, "Output token too large");
            if (output.size() + n >= result_capacity) break;
            output.append(piece, n);
            if (on_output && !grammar && !qf_llm_is_cancelled(flag)) {
                const auto visible = qf_visible_answer(output);
                on_output(visible.data(), visible.size(), output_context);
            }
            if (i + 1 >= std::clamp(max_tokens, 1, 512)) break; // No next sample needs logits.
            int decoded;
            { qf_elapsed timing{metrics.decode_ms}; decoded = llama_decode(context, llama_batch_get_one(&token, 1)); }
            if (decoded != 0) return fail(qf_llm_is_cancelled(flag) ? 1 : 4, "Generation failed");
            cache.evaluated.push_back(token);
        }
        // Never expose an unexpected reasoning block from the model.
        output = qf_visible_answer(output);
        if (qf_llm_is_cancelled(flag)) return fail(1, "Cancelled");
        if (output.empty()) return fail(4, "Empty answer");
        memcpy(result, output.data(), output.size()); result[output.size()] = 0;
        if (!reached_end) return fail(6, "Output limit reached");
        context_receipt.keep = !scope.empty() && !grammar;
        pressure_receipt.completed = true;
        return 0;
    } catch (...) { return fail(4, "Native inference failure"); }
}
