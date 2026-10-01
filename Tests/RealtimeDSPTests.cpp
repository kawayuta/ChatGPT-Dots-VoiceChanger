#include "VoiceDSP.h"
#include <algorithm>
#include <atomic>
#include <cassert>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <new>
#include <thread>

// Covers C++ new/new[] (including the vendor vectors), not every allocation
// inside a system framework. C processing allocation sites are reviewed apart.
static thread_local bool inRender=false;
static thread_local uint64_t renderAllocations=0;
void *operator new(std::size_t n) {
    if (inRender) ++renderAllocations;
    if (void *p=std::malloc(n?n:1)) return p;
    throw std::bad_alloc();
}
void *operator new[](std::size_t n) { return ::operator new(n); }
void operator delete(void *p) noexcept { std::free(p); }
void operator delete[](void *p) noexcept { std::free(p); }
void operator delete(void *p,std::size_t) noexcept { std::free(p); }
void operator delete[](void *p,std::size_t) noexcept { std::free(p); }

static void exercise(double rate,uint32_t channels) {
    DVCDSP *d=dvc_dsp_create(rate,channels); assert(d);
    assert(dvc_dsp_latency_frames(d)==dvc_dsp_expected_latency(rate));
    float in[2][4096]={},out[2][4096]={};
    const float *inputs[2]={in[0],in[1]};float *outputs[2]={out[0],out[1]};
    const uint32_t sizes[]={1,37,128,211,512,1024,4096};
    uint64_t position=0;
    double leftPower=0,rightPower=0,maximumSampleDifference=0;
    auto p=dvc_default_parameters();p.pitch_enabled=p.formant_enabled=true;
    p.eq_enabled=p.compressor_enabled=true;
    for (uint32_t block=0;block<180;block++) {
        uint32_t frames=sizes[block%7];
        p.pitch_semitones=12*std::sin(block*0.07);p.formant_semitones=8*std::cos(block*0.05);
        p.preserve_vocal_shape=block%17<12;p.low_db=12*std::sin(block*0.1);
        dvc_dsp_set_parameters(d,p);
        for (uint32_t i=0;i<frames;i++) {
            // Tones, unvoiced noise, silence, and resumed voiced input.
            double t=(position+i)/rate;
            in[0][i]=block>70 && block<90 ? 0 : 0.08*std::sin(2*M_PI*120*t)+0.025*std::sin(2*M_PI*600*t);
            if (block<70) in[0][i]+=0.015*std::sin((position+i)*12.345);
            in[1][i]=in[0][i]*0.5f;
        }
        inRender=true;dvc_dsp_process(d,inputs,outputs,frames);inRender=false;
        for (uint32_t i=0;i<frames;i++) {
            assert(std::isfinite(out[0][i]) && std::abs(out[0][i])<=0.981);
            if (channels==2) {
                // A spectral pitch shifter does not promise sample-identical
                // phase predictions for noisy/automated stereo. Test audible
                // level balance; exact duplicate-tone balance is tested apart.
                maximumSampleDifference=std::max(maximumSampleDifference,double(std::abs(out[1][i]-0.5f*out[0][i])));
                leftPower+=double(out[0][i])*out[0][i];rightPower+=double(out[1][i])*out[1][i];
            }
        }
        position+=frames;
    }
    assert(dvc_dsp_stats(d).nonfinite_samples==0);
    if (channels==2) {
        double ratio=std::sqrt(rightPower/leftPower);
        assert(std::abs(ratio/0.5-1)<0.001); // 0.1% linked level balance.
        std::printf("STEREO_BALANCE rate=%.0f measured_RMS_ratio=%.8f expected=0.5 max_sample_difference=%.8f PASS\n",rate,ratio,maximumSampleDifference);
    }
    inRender=true;dvc_dsp_reset(d);inRender=false; // Suspended host reset, same capacity.
    assert(renderAllocations==0);
    dvc_dsp_destroy(d);
    std::printf("REALTIME_DSP rate=%.0f channels=%u variable_blocks=180 cpp_new_during_processing=0 finite=true stereo_linked=true suspended_reset=true PASS\n",rate,channels);
}
static void concurrentControls() {
    auto *d=dvc_dsp_create(48000,2);assert(d);
    std::atomic<bool> finished{false};
    std::thread writer([&] {
        auto p=dvc_default_parameters();p.pitch_enabled=true;p.formant_enabled=true;
        for (unsigned n=0;!finished.load();n++) {
            p.pitch_semitones=float(int(n%25)-12);p.formant_semitones=float(int(n%17)-8);
            p.preserve_vocal_shape=n%2;dvc_dsp_set_parameters(d,p);
            auto stats=dvc_dsp_stats(d);assert(std::isfinite(stats.output_peak));
        }
    });
    float in[2][128]={},out[2][128]={};
    const float *inputs[2]={in[0],in[1]};float *outputs[2]={out[0],out[1]};
    for (unsigned n=0;n<1500;n++) {
        for(unsigned i=0;i<128;i++) {in[0][i]=0.1*std::sin((n*128+i)*0.016);in[1][i]=in[0][i]*0.5;}
        inRender=true;dvc_dsp_process(d,inputs,outputs,128);inRender=false;
        for(unsigned i=0;i<128;i++) assert(std::isfinite(out[0][i]) && std::abs(out[0][i])<=0.981);
    }
    finished.store(true);writer.join();assert(renderAllocations==0);
    assert(dvc_dsp_stats(d).nonfinite_samples==0);dvc_dsp_destroy(d);
    std::puts("CONCURRENT controls and telemetry, bounded finite parameters, no render C++ new PASS (not a ThreadSanitizer substitute)");
}
int main() {
    setbuf(stdout,nullptr);
    for (double rate : {8000.,11025.,12000.,22050.,24000.,44100.,48000.,96000.,192000.})
        for (uint32_t channels : {1u,2u}) exercise(rate,channels);
    concurrentControls();
    std::puts("REALTIME_DSP_TESTS_PASS hardware_output=false cpp_new_counter_only=true");
}
