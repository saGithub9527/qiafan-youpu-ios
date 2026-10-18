#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct qf_llm_cancellation qf_llm_cancellation;
typedef struct { const char *role; const char *content; } qf_llm_message;
typedef void (*qf_llm_output_callback)(const char *visible_utf8, size_t count, void *context);
typedef struct {
    uint64_t phys_footprint_bytes, available_memory_bytes;
    bool phys_footprint_valid, available_memory_valid;
} qf_llm_memory_snapshot;
// Numeric diagnostics only; never contains a prompt, answer or business data.
typedef struct {
    int32_t prompt_tokens, generated_tokens, grammar_fallbacks;
    double load_ms, prompt_ms, sampling_ms, decode_ms;
    double context_ms, first_token_ms, total_ms;
    int32_t context_tokens, evaluated_prompt_tokens, reused_prompt_tokens, micro_batch_tokens;
    bool model_reused;
    bool op_offload;
    bool memory_mapped, load_mode_valid, ram_admission_refused;
    int32_t load_policy;
    bool automatic_context_mmap_fallback, memory_pressure_interrupted;
    uint64_t ram_required_available_bytes;
    // Whole-process CPU and fault deltas for diagnosis, not model-only counters.
    double process_cpu_ms;
    int64_t process_minor_faults, process_major_faults;
    // Process lifetime peak RSS; unlike CPU/faults this is not a per-call delta.
    uint64_t process_peak_rss_bytes;
    // Apple process snapshots, not system free RAM or process lifetime peaks.
    qf_llm_memory_snapshot memory_start, memory_end;
    // Before load is after releasing an incompatible cache. Extrema are samples,
    // not a guaranteed peak; progress sampling is enabled only for RAM loading.
    qf_llm_memory_snapshot memory_before_load, memory_after_load;
    uint64_t load_sampled_peak_phys_footprint_bytes, load_sampled_min_available_memory_bytes;
    uint32_t load_memory_sample_count;
    bool load_sampled_footprint_valid, load_sampled_available_valid;
    bool memory_sampled_before_context_release;
} qf_llm_metrics;
qf_llm_cancellation *qf_llm_cancel_create(void);
void qf_llm_cancel_destroy(qf_llm_cancellation *flag);
void qf_llm_cancel(qf_llm_cancellation *flag);
bool qf_llm_is_cancelled(qf_llm_cancellation *flag);
// Cancels only a request currently owning RAM weights. The flag owns its lifetime.
void qf_llm_memory_warning(qf_llm_cancellation *flag);
bool qf_llm_memory_interrupted(qf_llm_cancellation *flag);
// Any OS memory-pressure event suspends new automatic RAM loads until restart.
void qf_llm_note_memory_pressure(void);
// Releases only the idle in-memory model/context; never touches the model file.
void qf_llm_release_cache(void);
// A late cancelled request can release only the RAM cache it last owned.
void qf_llm_release_cancelled_ram_cache(qf_llm_cancellation *flag);
// 0 success, 1 cancelled, 2 load failure, 3 context failure, 4 decode failure,
// 5 input too long, 6 output incomplete at limit, 7 RAM admission refused,
// 8 RAM generation interrupted by memory pressure.
// load_policy: 0 automatic, 1 forced mmap, 2 forced RAM (no silent fallback).
int32_t qf_llm_complete(const char *model_path, const char *system,
    const qf_llm_message *messages, size_t count, int32_t threads,
    int32_t context_tokens, int32_t max_tokens, const char *output_grammar, const char *session_scope, int32_t micro_batch_tokens, bool op_offload, int32_t load_policy, qf_llm_metrics *metrics,
    qf_llm_output_callback on_output, void *output_context, qf_llm_cancellation *flag,
    char *result, size_t result_capacity, char *error, size_t error_capacity);
#ifdef __cplusplus
}
#endif
