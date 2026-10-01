#pragma once
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct DVCDSP DVCDSP;
typedef struct {
    float pitch_semitones;
    float formant_semitones;
    float low_db, mid_db, high_db;
    float threshold_db, ratio, attack_ms, release_ms;
    float volume;
    bool pitch_enabled, preserve_vocal_shape, formant_enabled, eq_enabled, compressor_enabled;
} DVCParameters;
typedef struct {
    uint64_t frames, nonfinite_samples, protection_frames;
    float reduction_db, output_peak;
} DVCDSPStats;

DVCParameters dvc_default_parameters(void);
uint32_t dvc_dsp_expected_latency(double sample_rate);
DVCDSP *dvc_dsp_create(double sample_rate, uint32_t channels);
void dvc_dsp_destroy(DVCDSP *dsp); // The render thread must be stopped first.
void dvc_dsp_reset(DVCDSP *dsp);   // Host calls only with rendering suspended.
void dvc_dsp_set_parameters(DVCDSP *dsp, DVCParameters parameters); // Non-RT writer.
DVCDSPStats dvc_dsp_stats(const DVCDSP *dsp);
uint32_t dvc_dsp_latency_frames(const DVCDSP *dsp);
// Planar Float32, mono/stereo, any block length; storage is allocated at creation.
void dvc_dsp_process(DVCDSP *dsp, const float *const input[2], float *const output[2], uint32_t frames);
#ifdef __cplusplus
}
#endif
