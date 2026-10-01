#include "RealtimeBridge.h"
#include <assert.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdatomic.h>

typedef struct { UInt32 count; AudioBuffer buffer[2]; } BufferPair;
static AudioStreamBasicDescription format(double rate, unsigned channels, bool planar, unsigned bits, bool floating) {
    AudioStreamBasicDescription f = {0};
    f.mSampleRate = rate; f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kAudioFormatFlagIsPacked | (floating ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger) | (planar ? kAudioFormatFlagIsNonInterleaved : 0);
    f.mChannelsPerFrame = channels; f.mBitsPerChannel = bits; f.mFramesPerPacket = 1;
    f.mBytesPerFrame = (bits / 8) * (planar ? 1 : channels); f.mBytesPerPacket = f.mBytesPerFrame;
    return f;
}
static BufferPair output(float *l, float *r, unsigned frames) {
    BufferPair b = {2, {{1, frames * 4, l}, {1, frames * 4, r}}}; return b;
}
static void encode(uint8_t *p, unsigned bits, bool floating, float v) {
    if (floating && bits == 32) memcpy(p, &v, 4);
    else if (floating) { double d = v; memcpy(p, &d, 8); }
    else if (bits == 16) { int16_t i = (int16_t)(v * 32768); memcpy(p, &i, 2); }
    else if (bits == 24) { int32_t i = (int32_t)(v * 8388608); p[0] = i; p[1] = i >> 8; p[2] = i >> 16; }
    else { int32_t i = (int32_t)((double)v * 2147483648.0); memcpy(p, &i, 4); }
}
static void format_matrix(void) {
    unsigned cases = 0;
    const unsigned depths[] = {16, 24, 32, 32, 64};
    for (unsigned rate = 0; rate < 2; rate++) for (unsigned channels = 1; channels <= 2; channels++) for (unsigned planar = 0; planar <= 1; planar++) for (unsigned depth = 0; depth < 5; depth++) {
        double sr = rate ? 48000 : 44100;
        unsigned bits = depths[depth]; bool floating = depth >= 3;
        AudioStreamBasicDescription f = format(sr, channels, planar, bits, floating);
        CVPBridge *b = cvp_bridge_create(f, 8192, 1024, 4096); assert(b);
        unsigned n = 2048; uint8_t *left = calloc(n, f.mBytesPerFrame), *right = calloc(n, f.mBytesPerFrame);
        assert(left && right);
        for (unsigned i = 0; i < n; i++) {
            encode(left + (size_t)i * f.mBytesPerFrame, bits, floating, .25f);
            if (channels == 2) encode((planar ? right : left) + (size_t)i * f.mBytesPerFrame + (planar ? 0 : bits / 8), bits, floating, -.125f);
        }
        BufferPair in = {planar ? channels : 1, {{planar ? 1 : channels, n * f.mBytesPerFrame, left}, {1, n * f.mBytesPerFrame, right}}};
        cvp_capture_callback(0, NULL, (AudioBufferList *)&in, NULL, NULL, NULL, b);
        float l[512], r[512]; BufferPair out = output(l, r, 512); bool silent = true;
        assert(cvp_bridge_render(b, 512, (AudioBufferList *)&out, &silent) == noErr && !silent);
        for (unsigned i = 200; i < 512; i++) { assert(fabsf(l[i] - .25f) < .001f); assert(fabsf(r[i] - (channels == 2 ? -.125f : .25f)) < .001f); }
        CVPStats s = cvp_bridge_stats(b); assert(s.format_errors == 0 && s.overflows == 0 && s.underflows == 0);
        free(left); free(right); cvp_bridge_destroy(b); cases++;
    }
    printf("PASS PCM conversion: %u cases (44.1/48 kHz, mono/stereo, packed/planar, Int16/24/32, Float32/64)\n", cases);
}
static void fault_cases(void) {
    AudioStreamBasicDescription f = format(48000, 2, false, 32, true);
    CVPBridge *b = cvp_bridge_create(f, 8192, 512, 2048); assert(b);
    float l[1024], r[1024]; BufferPair out = output(l, r, 1024); bool silent = false;
    memset(l, 0x7F, sizeof(l)); assert(cvp_bridge_render(b, 1024, (AudioBufferList *)&out, &silent) == noErr && silent);
    for (unsigned i = 0; i < 1024; i++) assert(l[i] == 0 && r[i] == 0);
    float *samples = calloc(10000 * 2, 4); for (unsigned i = 0; i < 20000; i++) samples[i] = .5f;
    BufferPair in = {1, {{2, 10000 * 8, samples}, {0, 0, NULL}}};
    cvp_capture_callback(0, NULL, (AudioBufferList *)&in, NULL, NULL, NULL, b); assert(cvp_bridge_stats(b).overflows == 1);
    in.buffer[0].mDataByteSize = 4096 * 8;
    cvp_capture_callback(0, NULL, (AudioBufferList *)&in, NULL, NULL, NULL, b);
    cvp_bridge_render(b, 1024, (AudioBufferList *)&out, &silent);
    CVPStats s = cvp_bridge_stats(b); assert(s.backlog_resets == 1 && s.underflows == 0 && s.queued_frames <= 514);
    cvp_bridge_render(b, 1024, (AudioBufferList *)&out, &silent);
    assert(cvp_bridge_stats(b).underflows == 1);
    for (unsigned i = 0; i < 1024; i++) assert(isfinite(l[i]) && fabsf(l[i]) <= 1 && isfinite(r[i]) && fabsf(r[i]) <= 1);
    cvp_bridge_silence(b); silent = false; cvp_bridge_render(b, 1024, (AudioBufferList *)&out, &silent); assert(silent);
    in.count = 2; cvp_capture_callback(0, NULL, (AudioBufferList *)&in, NULL, NULL, NULL, b); assert(cvp_bridge_stats(b).format_errors == 1);
    free(samples); cvp_bridge_destroy(b);
    f.mFormatFlags |= kAudioFormatFlagIsBigEndian; assert(!cvp_bridge_create(f, 8192, 512, 2048));
    f = format(48000, 6, false, 32, true); assert(!cvp_bridge_create(f, 8192, 512, 2048));
    for (unsigned i = 0; i < 20; i++) { f = format(48000, 2, false, 32, true); b = cvp_bridge_create(f, 8192, 512, 2048); assert(b); cvp_bridge_destroy(b); }
    puts("PASS underflow silence/fade, overflow, stale backlog discard, emergency silence, malformed buffers, unsupported format, 20 allocations/teardowns (NOT HAL starts/stops)");
}

static void mono_downmix(void) {
    for (unsigned rate = 0; rate < 3; rate++) for (unsigned channels = 1; channels <= 2; channels++) {
        double sr = rate == 0 ? 24000 : rate == 1 ? 44100 : 48000;
        CVPBridge *b = cvp_bridge_create(format(sr, channels, false, 32, true), 8192, 1024, 4096); assert(b);
        float samples[4096], mono[512];
        for (unsigned i = 0; i < 2048; i++) {
            samples[i * channels] = .75f;
            if (channels == 2) samples[i * channels + 1] = .25f;
        }
        BufferPair in = {1, {{channels, 2048 * channels * 4, samples}, {0, 0, NULL}}};
        AudioBufferList out = {1, {{1, sizeof(mono), mono}}}; bool silent = true;
        cvp_capture_callback(0, NULL, (AudioBufferList *)&in, NULL, NULL, NULL, b);
        assert(cvp_bridge_render(b, 512, &out, &silent) == noErr && !silent);
        float expected = channels == 2 ? .5f : .75f;
        for (unsigned i = 200; i < 512; i++) assert(fabsf(mono[i] - expected) < .001f);
        cvp_bridge_silence(b); assert(cvp_bridge_render(b, 512, &out, &silent) == noErr && silent);
        for (unsigned i = 0; i < 512; i++) assert(mono[i] == 0);
        CVPStats s = cvp_bridge_stats(b); assert(s.format_errors == 0 && s.underflows == 0);
        cvp_bridge_destroy(b);
    }
    puts("PASS unity mono downmix: 24/44.1/48 kHz mono/stereo inputs, no doubled duplicate channels, emergency silence");
}

typedef struct { CVPBridge *bridge; _Atomic bool finished; } Stress;
static void *producer(void *context) {
    Stress *s = context; float samples[512];
    for (unsigned i = 0; i < 512; i++) samples[i] = .25f;
    BufferPair in = {1, {{2, sizeof(samples), samples}, {0, 0, NULL}}};
    for (unsigned i = 0; i < 50000; i++) cvp_capture_callback(0, NULL, (AudioBufferList *)&in, NULL, NULL, NULL, s->bridge);
    atomic_store_explicit(&s->finished, true, memory_order_release); return NULL;
}
static void *consumer(void *context) {
    Stress *s = context; float l[256], r[256]; BufferPair out = output(l, r, 256);
    do {
        bool silent; cvp_bridge_render(s->bridge, 256, (AudioBufferList *)&out, &silent);
        for (unsigned i = 0; i < 256; i++) assert(isfinite(l[i]) && isfinite(r[i]) && fabsf(l[i]) <= 1 && fabsf(r[i]) <= 1);
    } while (!atomic_load_explicit(&s->finished, memory_order_acquire));
    return NULL;
}
static void stress(void) {
    Stress s; s.bridge = cvp_bridge_create(format(48000, 2, false, 32, true), 8192, 1024, 4096); assert(s.bridge); atomic_init(&s.finished, false);
    pthread_t p, c; assert(!pthread_create(&p, NULL, producer, &s)); assert(!pthread_create(&c, NULL, consumer, &s));
    pthread_join(p, NULL); pthread_join(c, NULL);
    CVPStats stats = cvp_bridge_stats(s.bridge); assert(stats.capture_callbacks == 50000 && stats.render_callbacks > 0 && stats.queued_frames <= 8192 && stats.format_errors == 0);
    cvp_bridge_destroy(s.bridge); puts("PASS concurrent SPSC stress: 12.8 million generated frames, bounded storage, finite output (accelerated; NOT a 60-minute live test)");
}
static void burst_headroom(void) {
    CVPBridge *b=cvp_bridge_create(format(48000,2,false,32,true),16384,960,6000);assert(b);
    float samples[4096];for(unsigned i=0;i<4096;i++)samples[i]=.25f;
    BufferPair in={1,{{2,3072*8,samples},{0,0,NULL}}};
    // Three initial producer blocks, each within the fixed test array.
    in.buffer[0].mDataByteSize=1024*8;
    for(int i=0;i<3;i++)cvp_capture_callback(0,NULL,(AudioBufferList *)&in,NULL,NULL,NULL,b);
    float l[1536],r[1536];unsigned blocks[]={512,1024,256,1536};
    for(unsigned i=0;i<20000;i++) {
        unsigned n=blocks[i%4];in.buffer[0].mDataByteSize=n*8;
        cvp_capture_callback(0,NULL,(AudioBufferList *)&in,NULL,NULL,NULL,b);
        BufferPair out=output(l,r,n);bool silent=true;
        cvp_bridge_render(b,n,(AudioBufferList *)&out,&silent);assert(!silent);
    }
    CVPStats s=cvp_bridge_stats(b);assert(s.underflows==0 && s.overflows==0 && s.format_errors==0);
    printf("PASS variable render-burst headroom: 20,000 callbacks, no underflow/overflow (regression for short prebuffer starvation)\n");cvp_bridge_destroy(b);
}
int main(void) { setvbuf(stdout, NULL, _IONBF, 0); puts("TEST_MAIN_STARTED"); format_matrix(); fault_cases(); mono_downmix(); burst_headroom(); stress(); puts("ALL BRIDGE TESTS PASSED"); return 0; }
