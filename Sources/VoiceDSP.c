#include "VoiceDSP.h"
#include "SpeechDSP.h"
#include <stdatomic.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

// Render-owned DSP, filter states and fixed scratch arrays. Only controls and
// telemetry are shared atomics. No allocation or locks in the processing path.
enum { P_PITCH, P_FORMANT, P_LOW, P_MID, P_HIGH, P_THRESHOLD, P_RATIO, P_ATTACK,
       P_RELEASE, P_VOLUME, P_PITCH_ON, P_PRESERVE, P_FORMANT_ON, P_EQ_ON, P_COMP_ON, P_COUNT };
enum { CHUNK = 128 };
typedef struct { double b0, b1, b2, a1, a2, z1[2], z2[2]; } Biquad;
struct DVCDSP {
    double rate;
    uint32_t channels;
    uint64_t position;
    DVCSpeechDSP *speech;
    float input[2][CHUNK], shifted[2][CHUNK];
    float eq_db[3], eq_mix, comp_mix, volume;
    float detector, compressor_gain;
    Biquad eq[3];
    _Atomic uint32_t controls[P_COUNT], reduction_bits, peak_bits;
    _Atomic uint64_t frame_count, invalid_count, protected_count;
};
static uint32_t bits(float f) { uint32_t b; memcpy(&b, &f, sizeof(b)); return b; }
static float value(uint32_t b) { float f; memcpy(&f, &b, sizeof(f)); return f; }
static float bounded(float x, float low, float high, float fallback) {
    return isfinite(x) ? fminf(high, fmaxf(low, x)) : fallback;
}
DVCParameters dvc_default_parameters(void) {
    return (DVCParameters){ .threshold_db=-18, .ratio=3, .attack_ms=10, .release_ms=100, .volume=1, .preserve_vocal_shape=true };
}
uint32_t dvc_dsp_expected_latency(double rate) { return dvc_speech_expected_latency(rate); }
static void coefficients(Biquad *b, int kind, float gain, double rate) {
    // RBJ / W3C Audio EQ Cookbook: low shelf 160 Hz, bell 1 kHz Q=.8,
    // high shelf 4 kHz. Coefficients are our implementation of these formulae.
    double f = kind == 0 ? 160 : kind == 1 ? 1000 : 4000;
    f = fmin(f, rate * .40);
    double A = pow(10, gain / 40.0), w = 2 * M_PI * f / rate;
    double c = cos(w), s = sin(w), alpha, a0, a1, a2, b0, b1, b2;
    if (kind == 1) {
        alpha = s / (2 * .8);
        b0=1+alpha*A; b1=-2*c; b2=1-alpha*A;
        a0=1+alpha/A; a1=-2*c; a2=1-alpha/A;
    } else {
        alpha = s / sqrt(2.0);
        double t = 2 * sqrt(A) * alpha;
        if (kind == 0) {
            b0=A*((A+1)-(A-1)*c+t); b1=2*A*((A-1)-(A+1)*c); b2=A*((A+1)-(A-1)*c-t);
            a0=(A+1)+(A-1)*c+t; a1=-2*((A-1)+(A+1)*c); a2=(A+1)+(A-1)*c-t;
        } else {
            b0=A*((A+1)+(A-1)*c+t); b1=-2*A*((A-1)+(A+1)*c); b2=A*((A+1)+(A-1)*c-t);
            a0=(A+1)-(A-1)*c+t; a1=2*((A-1)-(A+1)*c); a2=(A+1)-(A-1)*c-t;
        }
    }
    b->b0=b0/a0; b->b1=b1/a0; b->b2=b2/a0; b->a1=a1/a0; b->a2=a2/a0;
}
void dvc_dsp_set_parameters(DVCDSP *d, DVCParameters p) {
    if (!d) return;
    float v[P_COUNT] = {
        bounded(p.pitch_semitones,-12,12,0), bounded(p.formant_semitones,-8,8,0), bounded(p.low_db,-12,12,0),
        bounded(p.mid_db,-12,12,0), bounded(p.high_db,-12,12,0),
        bounded(p.threshold_db,-48,0,-18), bounded(p.ratio,1,8,3),
        bounded(p.attack_ms,1,100,10), bounded(p.release_ms,20,1000,100),
        bounded(p.volume,0,1,1), p.pitch_enabled?1:0, p.preserve_vocal_shape?1:0, p.formant_enabled?1:0, p.eq_enabled?1:0, p.compressor_enabled?1:0
    };
    // Independent bounded parameters: a block can see adjacent revisions, but
    // never a torn float, invalid range, blocking lock, or a seqlock retry loop.
    for (unsigned i=0;i<P_COUNT;i++) atomic_store_explicit(&d->controls[i], bits(v[i]), memory_order_relaxed);
}
DVCDSP *dvc_dsp_create(double rate, uint32_t channels) {
    if (!isfinite(rate) || rate < 8000 || rate > 192000 || channels < 1 || channels > 2) return NULL;
    DVCDSP *d = calloc(1,sizeof(*d)); if (!d) return NULL;
    d->rate=rate; d->channels=channels;
    d->speech=dvc_speech_create(rate,channels);
    if (!d->speech) { dvc_dsp_destroy(d); return NULL; }
    for (unsigned i=0;i<P_COUNT;i++) atomic_init(&d->controls[i],0);
    atomic_init(&d->reduction_bits,0); atomic_init(&d->peak_bits,0);
    atomic_init(&d->frame_count,0); atomic_init(&d->invalid_count,0); atomic_init(&d->protected_count,0);
    if (!atomic_is_lock_free(&d->frame_count) || !atomic_is_lock_free(&d->controls[0])) { dvc_dsp_destroy(d); return NULL; }
    d->volume=1; d->compressor_gain=1;
    for (int i=0;i<3;i++) coefficients(&d->eq[i],i,0,rate);
    dvc_dsp_set_parameters(d,dvc_default_parameters());
    return d;
}
void dvc_dsp_destroy(DVCDSP *d) {
    if (!d) return;
    dvc_speech_destroy(d->speech); free(d);
}
void dvc_dsp_reset(DVCDSP *d) {
    if (!d) return;
    dvc_speech_reset(d->speech);
    for (int i=0;i<3;i++) { memset(d->eq[i].z1,0,sizeof(d->eq[i].z1)); memset(d->eq[i].z2,0,sizeof(d->eq[i].z2)); }
    d->position=0; d->detector=0; d->compressor_gain=1;
}
uint32_t dvc_dsp_latency_frames(const DVCDSP *d) { return d ? dvc_speech_latency_frames(d->speech) : 0; }
DVCDSPStats dvc_dsp_stats(const DVCDSP *d) {
    DVCDSPStats s={0}; if (!d) return s;
    s.frames=atomic_load_explicit(&d->frame_count,memory_order_relaxed);
    s.nonfinite_samples=atomic_load_explicit(&d->invalid_count,memory_order_relaxed);
    s.protection_frames=atomic_load_explicit(&d->protected_count,memory_order_relaxed);
    s.reduction_db=value(atomic_load_explicit(&d->reduction_bits,memory_order_relaxed));
    s.output_peak=value(atomic_load_explicit(&d->peak_bits,memory_order_relaxed)); return s;
}
static float filter(Biquad *b,float x,uint32_t c) {
    double y=b->b0*x+b->z1[c];
    b->z1[c]=b->b1*x-b->a1*y+b->z2[c]; b->z2[c]=b->b2*x-b->a2*y;
    if (fabs(b->z1[c])<1e-25) b->z1[c]=0;
    if (fabs(b->z2[c])<1e-25) b->z2[c]=0;
    return (float)y;
}
void dvc_dsp_process(DVCDSP *d,const float *const in[2],float *const out[2],uint32_t frames) {
    if (!d || !in || !out || !in[0] || !out[0] || (d->channels==2 && (!in[1] || !out[1]))) return;
    float p[P_COUNT]; for (unsigned i=0;i<P_COUNT;i++) p[i]=value(atomic_load_explicit(&d->controls[i],memory_order_relaxed));
    float attack=expf(-1.f/(float)(d->rate*p[P_ATTACK]*.001)), release=expf(-1.f/(float)(d->rate*p[P_RELEASE]*.001));
    float peak=0; uint64_t invalid=0, protected=0;
    const float *speechIn[2]={d->input[0],d->input[1]};
    float *speechOut[2]={d->shifted[0],d->shifted[1]};
    for (uint32_t base=0;base<frames;) {
        uint32_t count=frames-base < CHUNK ? frames-base : CHUNK;
        for (uint32_t c=0;c<d->channels;c++) for (uint32_t i=0;i<count;i++) {
            float sample=in[c][base+i];
            if (!isfinite(sample)) { sample=0; invalid++; }
            d->input[c][i]=sample;
        }
        bool success=dvc_speech_process(d->speech,speechIn,speechOut,count,
            p[P_PITCH_ON] ? p[P_PITCH] : 0, p[P_FORMANT_ON] ? p[P_FORMANT] : 0, p[P_PRESERVE]!=0);
        if (!success) {
            for (uint32_t c=0;c<d->channels;c++) memset(d->shifted[c],0,count*sizeof(float));
            invalid += count*d->channels;
        }
        for (uint32_t i=0;i<count;i++) {
        uint64_t t=d->position; float x[2]={0}, wet[2]={0};
        d->eq_mix += .002f*(p[P_EQ_ON]-d->eq_mix);
        d->comp_mix += .002f*(p[P_COMP_ON]-d->comp_mix);
        d->volume += .002f*(p[P_VOLUME]-d->volume);
        if ((t&63)==0) for (int k=0;k<3;k++) {
            d->eq_db[k] += .025f*(p[P_LOW+k]-d->eq_db[k]); coefficients(&d->eq[k],k,d->eq_db[k],d->rate);
        }
        for (uint32_t c=0;c<d->channels;c++) {
            x[c]=d->shifted[c][i];
            if (!isfinite(x[c])) { x[c]=0; invalid++; }
            wet[c]=x[c]; for (int k=0;k<3;k++) wet[c]=filter(&d->eq[k],wet[c],c);
            x[c] += (wet[c]-x[c])*d->eq_mix;
        }
        float level=fmaxf(fabsf(x[0]),fabsf(x[1]));
        // Stereo-linked peak detector, 6 dB soft knee, explicit ratio. No makeup gain.
        float detector_coef=level>d->detector?attack:release;
        d->detector=level+detector_coef*(d->detector-level);
        float db=20*log10f(fmaxf(d->detector,1e-9f)), above=db-p[P_THRESHOLD], knee=6;
        float reduction=above<=-knee/2 ? 0 : above>=knee/2 ? (1-1/p[P_RATIO])*above : (1-1/p[P_RATIO])*(above+knee/2)*(above+knee/2)/(2*knee);
        float target_gain=powf(10,-reduction/20), gain_coef=target_gain<d->compressor_gain?attack:release;
        d->compressor_gain=target_gain+gain_coef*(d->compressor_gain-target_gain);
        float gain=(1+(d->compressor_gain-1)*d->comp_mix)*d->volume;
        float maximum=fmaxf(fabsf(x[0]*gain),fabsf(x[1]*gain));
        if (maximum>.98f) { gain *= .98f/maximum; protected++; }
        for (uint32_t c=0;c<d->channels;c++) {
            float y=x[c]*gain;
            if (!isfinite(y)) { y=0; invalid++; }
            out[c][base+i]=y; peak=fmaxf(peak,fabsf(y));
        }
        d->position++;
        }
        base+=count;
    }
    atomic_fetch_add_explicit(&d->frame_count,frames,memory_order_relaxed);
    atomic_fetch_add_explicit(&d->invalid_count,invalid,memory_order_relaxed);
    atomic_fetch_add_explicit(&d->protected_count,protected,memory_order_relaxed);
    atomic_store_explicit(&d->reduction_bits,bits(-20*log10f(fmaxf(1+(d->compressor_gain-1)*d->comp_mix,1e-9f))),memory_order_relaxed);
    atomic_store_explicit(&d->peak_bits,bits(peak),memory_order_relaxed);
}
