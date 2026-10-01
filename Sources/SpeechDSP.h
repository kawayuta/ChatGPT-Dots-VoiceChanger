#pragma once
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif
typedef struct DVCSpeechDSP DVCSpeechDSP;
DVCSpeechDSP *dvc_speech_create(double sample_rate, uint32_t channels);
void dvc_speech_destroy(DVCSpeechDSP *dsp); // Only after rendering stops.
void dvc_speech_reset(DVCSpeechDSP *dsp);   // Only with rendering suspended.
uint32_t dvc_speech_latency_frames(const DVCSpeechDSP *dsp);
uint32_t dvc_speech_expected_latency(double sample_rate);
// Render-thread owner. Parameters are bounded snapshots read by VoiceDSP.c.
// Input and output must be separate planar Float32 buffers, one or two channels.
bool dvc_speech_process(DVCSpeechDSP *dsp, const float *const input[2],
                        float *const output[2], uint32_t frames,
                        float pitch, float formant, bool preserve_vocal_shape);
#ifdef __cplusplus
}
#endif
