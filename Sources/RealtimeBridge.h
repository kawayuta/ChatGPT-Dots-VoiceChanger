#pragma once
#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stdint.h>

typedef struct CVPBridge CVPBridge;
typedef struct {
    uint64_t capture_callbacks, render_callbacks, underflows, overflows, backlog_resets, format_errors;
    uint32_t queued_frames;
    double drift_ratio;
    float peak;
} CVPStats;

CVPBridge *cvp_bridge_create(AudioStreamBasicDescription format, uint32_t capacity, uint32_t target_frames, uint32_t maximum_backlog);
void cvp_bridge_destroy(CVPBridge *bridge); // Only after both callbacks have stopped.
void cvp_bridge_set_gain(CVPBridge *bridge, float gain);
void cvp_bridge_silence(CVPBridge *bridge);
CVPStats cvp_bridge_stats(const CVPBridge *bridge);
OSStatus cvp_capture_callback(AudioObjectID device, const AudioTimeStamp *now, const AudioBufferList *input, const AudioTimeStamp *input_time, AudioBufferList *output, const AudioTimeStamp *output_time, void *context);
OSStatus cvp_bridge_render(CVPBridge *bridge, uint32_t frames, AudioBufferList *output, bool *silence);
