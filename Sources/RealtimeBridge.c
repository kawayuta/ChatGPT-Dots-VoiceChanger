#include "RealtimeBridge.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

struct CVPBridge {
    AudioStreamBasicDescription format;
    float *samples; // Interleaved stereo, fixed capacity. Producer owns write, consumer owns read.
    uint32_t capacity, target, max_backlog;
    _Atomic uint64_t write, read;
    _Atomic uint64_t captures, renders, underflows, overflows, resets, errors;
    _Atomic uint32_t gain_bits, peak_bits;
    _Atomic uint64_t ratio_bits;
    _Atomic bool silenced;
    double fraction, ratio; // Consumer-only fractional resampling for independent clock drift.
    float gain, last[2], fade;
    bool primed;
};

static uint32_t float_bits(float value) { uint32_t bits; memcpy(&bits, &value, 4); return bits; }
static float bits_float(uint32_t bits) { float value; memcpy(&value, &bits, 4); return value; }
static uint64_t double_bits(double value) { uint64_t bits; memcpy(&bits, &value, 8); return bits; }
static double bits_double(uint64_t bits) { double value; memcpy(&value, &bits, 8); return value; }

CVPBridge *cvp_bridge_create(AudioStreamBasicDescription f, uint32_t capacity, uint32_t target, uint32_t max_backlog) {
    bool pcm = f.mFormatID == kAudioFormatLinearPCM && f.mFramesPerPacket == 1;
    bool native = !(f.mFormatFlags & kAudioFormatFlagIsBigEndian);
    bool floating = f.mFormatFlags & kAudioFormatFlagIsFloat;
    bool signed_integer = f.mFormatFlags & kAudioFormatFlagIsSignedInteger;
    bool valid_bits = floating ? (f.mBitsPerChannel == 32 || f.mBitsPerChannel == 64) : (signed_integer && (f.mBitsPerChannel == 16 || f.mBitsPerChannel == 24 || f.mBitsPerChannel == 32));
    uint32_t bytes = (f.mBitsPerChannel + 7) / 8;
    uint32_t stream_channels = (f.mFormatFlags & kAudioFormatFlagIsNonInterleaved) ? 1 : f.mChannelsPerFrame;
    if (!pcm || !native || !valid_bits || f.mBytesPerFrame != bytes * stream_channels || f.mSampleRate < 8000 || f.mSampleRate > 192000 || f.mChannelsPerFrame < 1 || f.mChannelsPerFrame > 2 || target < 2 || max_backlog < target || capacity <= max_backlog) return NULL;
    CVPBridge *b = calloc(1, sizeof(*b));
    if (!b) return NULL;
    b->samples = calloc((size_t)capacity * 2, sizeof(float));
    if (!b->samples) { free(b); return NULL; }
    b->format = f; b->capacity = capacity; b->target = target; b->max_backlog = max_backlog;
    b->ratio = 1; b->gain = 1;
    atomic_init(&b->write, 0); atomic_init(&b->read, 0);
    atomic_init(&b->captures, 0); atomic_init(&b->renders, 0);
    atomic_init(&b->underflows, 0); atomic_init(&b->overflows, 0); atomic_init(&b->resets, 0); atomic_init(&b->errors, 0);
    atomic_init(&b->gain_bits, float_bits(1)); atomic_init(&b->peak_bits, 0);
    atomic_init(&b->ratio_bits, double_bits(1)); atomic_init(&b->silenced, false);
    if (!atomic_is_lock_free(&b->write) || !atomic_is_lock_free(&b->gain_bits)) { cvp_bridge_destroy(b); return NULL; }
    return b;
}
void cvp_bridge_destroy(CVPBridge *b) { if (b) { free(b->samples); free(b); } }
void cvp_bridge_set_gain(CVPBridge *b, float gain) { if (b) atomic_store_explicit(&b->gain_bits, float_bits(fminf(1, fmaxf(0, gain))), memory_order_relaxed); }
void cvp_bridge_silence(CVPBridge *b) { if (b) atomic_store_explicit(&b->silenced, true, memory_order_release); }
CVPStats cvp_bridge_stats(const CVPBridge *b) {
    CVPStats s = {0}; if (!b) return s;
    s.capture_callbacks = atomic_load_explicit(&b->captures, memory_order_relaxed);
    s.render_callbacks = atomic_load_explicit(&b->renders, memory_order_relaxed);
    s.underflows = atomic_load_explicit(&b->underflows, memory_order_relaxed);
    s.overflows = atomic_load_explicit(&b->overflows, memory_order_relaxed);
    s.backlog_resets = atomic_load_explicit(&b->resets, memory_order_relaxed);
    s.format_errors = atomic_load_explicit(&b->errors, memory_order_relaxed);
    uint64_t r = atomic_load_explicit(&b->read, memory_order_acquire), w = atomic_load_explicit(&b->write, memory_order_acquire);
    s.queued_frames = (uint32_t)(w >= r ? w - r : 0);
    s.peak = bits_float(atomic_load_explicit(&b->peak_bits, memory_order_relaxed));
    s.drift_ratio = bits_double(atomic_load_explicit(&b->ratio_bits, memory_order_relaxed));
    return s;
}

static float decode_sample(const uint8_t *p, const AudioStreamBasicDescription *f) {
    float v = 0;
    if (f->mFormatFlags & kAudioFormatFlagIsFloat) {
        if (f->mBitsPerChannel == 32) memcpy(&v, p, 4);
        else { double d; memcpy(&d, p, 8); v = (float)d; }
    } else if (f->mBitsPerChannel == 16) { int16_t i; memcpy(&i, p, 2); v = (float)i / 32768.f; }
    else if (f->mBitsPerChannel == 24) {
        int32_t i = (int32_t)((uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16);
        if (i & 0x800000) i |= (int32_t)0xFF000000; v = (float)i / 8388608.f;
    } else { int32_t i; memcpy(&i, p, 4); v = (float)((double)i / 2147483648.0); }
    return isfinite(v) ? v : 0;
}

OSStatus cvp_capture_callback(AudioObjectID device, const AudioTimeStamp *now, const AudioBufferList *input, const AudioTimeStamp *input_time, AudioBufferList *output, const AudioTimeStamp *output_time, void *context) {
    (void)device; (void)now; (void)input_time; (void)output; (void)output_time;
    CVPBridge *b = context; if (!b) return noErr;
    atomic_fetch_add_explicit(&b->captures, 1, memory_order_relaxed);
    bool planar = b->format.mFormatFlags & kAudioFormatFlagIsNonInterleaved;
    uint32_t channels = b->format.mChannelsPerFrame;
    uint32_t expected_buffers = planar ? channels : 1;
    if (!input || input->mNumberBuffers != expected_buffers) { atomic_fetch_add_explicit(&b->errors, 1, memory_order_relaxed); return noErr; }
    uint32_t frames = input->mBuffers[0].mDataByteSize / b->format.mBytesPerFrame;
    for (uint32_t i = 0; i < expected_buffers; i++) {
        const AudioBuffer *a = &input->mBuffers[i];
        if (!a->mData || a->mNumberChannels != (planar ? 1 : channels) || a->mDataByteSize != frames * b->format.mBytesPerFrame) { atomic_fetch_add_explicit(&b->errors, 1, memory_order_relaxed); return noErr; }
    }
    uint64_t w = atomic_load_explicit(&b->write, memory_order_relaxed), r = atomic_load_explicit(&b->read, memory_order_acquire);
    if (frames > b->capacity - (w - r)) { atomic_fetch_add_explicit(&b->overflows, 1, memory_order_relaxed); return noErr; }
    const uint8_t *left = input->mBuffers[0].mData;
    const uint8_t *right = planar && channels == 2 ? input->mBuffers[1].mData : left;
    uint32_t bytes = b->format.mBitsPerChannel / 8;
    float peak = 0;
    for (uint32_t i = 0; i < frames; i++) {
        float l = decode_sample(left + (size_t)i * b->format.mBytesPerFrame, &b->format);
        float rr = channels == 1 ? l : decode_sample(right + (size_t)i * b->format.mBytesPerFrame + (planar ? 0 : bytes), &b->format);
        size_t slot = (size_t)((w + i) % b->capacity) * 2;
        b->samples[slot] = l; b->samples[slot + 1] = rr;
        peak = fmaxf(peak, fmaxf(fabsf(l), fabsf(rr)));
    }
    atomic_store_explicit(&b->peak_bits, float_bits(peak), memory_order_relaxed);
    atomic_store_explicit(&b->write, w + frames, memory_order_release);
    return noErr;
}

OSStatus cvp_bridge_render(CVPBridge *b, uint32_t frames, AudioBufferList *output, bool *silence) {
    if (silence) *silence = true;
    if (!b || !output) return kAudio_ParamError;
    atomic_fetch_add_explicit(&b->renders, 1, memory_order_relaxed);
    for (uint32_t i = 0; i < output->mNumberBuffers; i++) if (output->mBuffers[i].mData) memset(output->mBuffers[i].mData, 0, output->mBuffers[i].mDataByteSize);
    bool mono = output->mNumberBuffers == 1;
    if ((!mono && output->mNumberBuffers != 2) || output->mBuffers[0].mNumberChannels != 1 || !output->mBuffers[0].mData || output->mBuffers[0].mDataByteSize < (size_t)frames * 4 || (!mono && (output->mBuffers[1].mNumberChannels != 1 || !output->mBuffers[1].mData || output->mBuffers[1].mDataByteSize < (size_t)frames * 4))) {
        atomic_fetch_add_explicit(&b->errors, 1, memory_order_relaxed); return kAudio_ParamError;
    }
    if (atomic_load_explicit(&b->silenced, memory_order_acquire)) return noErr;
    uint64_t r = atomic_load_explicit(&b->read, memory_order_relaxed), w = atomic_load_explicit(&b->write, memory_order_acquire);
    uint64_t available = w - r;
    // The target is headroom AFTER the requested render quantum. A pre-render
    // target smaller than a burst (or missing the interpolation look-ahead)
    // periodically starves even two perfectly matched clocks.
    uint64_t reserve = (uint64_t)b->target + frames + 2;
    if (reserve >= b->capacity) { atomic_fetch_add_explicit(&b->errors, 1, memory_order_relaxed); return kAudio_ParamError; }
    uint64_t maximum = b->max_backlog > reserve * 2 ? b->max_backlog : reserve * 2;
    if (maximum >= b->capacity) maximum = b->capacity - 1;
    if (available > maximum && available > reserve) {
        r = w - reserve; available = reserve; b->fraction = 0; b->fade = 0;
        atomic_fetch_add_explicit(&b->resets, 1, memory_order_relaxed);
    }
    if (!b->primed) { if (available < reserve) { atomic_store_explicit(&b->read, r, memory_order_release); return noErr; } b->primed = true; b->fade = 0; }
    // Bounded clock servo. At most +/-0.05% speed correction; no growing backlog.
    // AVAudioEngine separately performs nominal sample-rate conversion to the output device.
    double error = (double)available - reserve;
    double desired = 1 + fmax(-0.0005, fmin(0.0005, error / b->format.mSampleRate * 0.01));
    b->ratio += 0.02 * (desired - b->ratio);
    atomic_store_explicit(&b->ratio_bits, double_bits(b->ratio), memory_order_relaxed);
    float *out[2] = {output->mBuffers[0].mData, mono ? NULL : output->mBuffers[1].mData};
    float gain = bits_float(atomic_load_explicit(&b->gain_bits, memory_order_relaxed));
    uint32_t i = 0;
    for (; i < frames && r + 1 < w; i++) {
        b->gain += 0.004f * (gain - b->gain);
        b->fade = fminf(1, b->fade + 1.f / 128.f);
        for (uint32_t c = 0; c < 2; c++) {
            float a = b->samples[(r % b->capacity) * 2 + c], next = b->samples[((r + 1) % b->capacity) * 2 + c];
            float v = (a + (next - a) * (float)b->fraction) * b->gain * b->fade;
            v = fminf(1, fmaxf(-1, v)); b->last[c] = v;
            if (!mono) out[c][i] = v;
        }
        if (mono) out[0][i] = .5f * (b->last[0] + b->last[1]); // Explicit unity mono downmix; never sum duplicate stereo at +6 dB.
        b->fraction += b->ratio;
        uint64_t consumed = (uint64_t)b->fraction; r += consumed; b->fraction -= consumed;
        if (silence) *silence = false;
    }
    if (i < frames) {
        atomic_fetch_add_explicit(&b->underflows, 1, memory_order_relaxed);
        // Fade any remainder to zero; re-prime, so repeated starvation cannot buzz.
        uint32_t remaining = frames - i;
        uint32_t fade = remaining < 128 ? remaining : 128;
        if (silence && (b->last[0] != 0 || b->last[1] != 0)) *silence = false;
        for (uint32_t k = 0; k < fade; k++) {
            float factor = 1.f - (float)(k + 1) / fade;
            if (mono) out[0][i+k] = .5f * (b->last[0]+b->last[1]) * factor;
            else for (uint32_t c = 0; c < 2; c++) out[c][i+k] = b->last[c] * factor;
        }
        b->last[0] = b->last[1] = 0; b->fade = 0; b->primed = false; b->fraction = 0;
    }
    atomic_store_explicit(&b->read, r, memory_order_release);
    return noErr;
}
