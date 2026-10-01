#include "SpeechDSP.h"
#include "signalsmith-stretch.h"
#include <cmath>
#include <new>

struct VoicePeriod {
    // Bounded, coarse F0 estimate for the library's envelope analysis. It does
    // not change pitch, gate speech, or infer call state. Unvoiced/noisy input
    // falls back to the library's own rough estimate until confidence is high.
    float history[512] = {}, correlation[128] = {};
    uint32_t position=0, count=0, downCount=0, elapsed=0, divisor;
    float downSum=0, frequency=0;
    double rate, downRate;
    explicit VoicePeriod(double r) : divisor(uint32_t(std::ceil(r/6000))), rate(r), downRate(r/divisor) {}
    void reset() { position=count=downCount=elapsed=0; downSum=frequency=0; }
    float sample(uint32_t ago) const { return history[(position+511-ago)%512]; }
    void feed(const float *input, uint32_t frames) {
        for (uint32_t i=0;i<frames;i++) {
            downSum+=input[i];
            if (++downCount==divisor) {
                history[position]=downSum/divisor; position=(position+1)%512;
                count=std::min<uint32_t>(512,count+1); downCount=0; downSum=0;
            }
        }
        elapsed+=frames;
        if (count<384 || elapsed<uint32_t(rate*0.020)) return;
        elapsed=0;
        int first=int(downRate/500), last=int(downRate/60);
        int length=384-last-1;
        double power=0; for (int i=0;i<length;i++) {double x=sample(i);power+=x*x;}
        if (power/length<1e-8) return;
        for (int lag=first-1;lag<=last+1;lag++) {
            double dot=0, energy=0;
            for (int i=0;i<length;i++) {
                double a=sample(i), b=sample(i+lag); dot+=a*b; energy+=a*a+b*b;
            }
            correlation[lag]=float(2*dot/(energy+1e-30));
        }
        float strongest=0;
        for (int lag=first;lag<=last;lag++) strongest=std::max(strongest,correlation[lag]);
        if (strongest<0.85f) return;
        for (int lag=first;lag<=last;lag++) {
            float a=correlation[lag-1],b=correlation[lag],c=correlation[lag+1];
            if (b<a || b<c) continue;
            float denominator=a-2*b+c;
            float offset=denominator<-1e-8f ? std::clamp(0.5f*(a-c)/denominator,-0.5f,0.5f) : 0;
            // Compare interpolated peak height. A fractional fundamental period
            // can otherwise lose to an integer double period at 44.1 kHz.
            float peak=b-0.25f*(a-c)*offset;
            if (peak<strongest*0.97f) continue;
            float found=float(downRate/(lag+offset));
            if (std::isfinite(found) && found>=60 && found<=500)
                frequency=frequency>0 ? frequency+0.25f*(found-frequency) : found;
            return;
        }
    }
};

struct DVCSpeechDSP {
    // Construction/configuration happen off the audio thread. A fixed seed
    // avoids random-device I/O; rate-one processing does not randomize phases.
    signalsmith::stretch::SignalsmithStretch<float> stretch{100};
    double rate;
    uint32_t channels;
    VoicePeriod period;
    std::vector<float> referencePowerDelay;
    uint32_t referencePosition=0;
    double referencePower=0, outputPower=0, normalization=1;
    float pitch = 0, formant = 0, preservation = 0;
    bool initialParameters = true;
    DVCSpeechDSP(double r, uint32_t c) : rate(r), channels(c), period(r) {
        // A single 80-ms window replaces the native pitch AU plus the previous
        // separate 43-ms formant window. This is algorithmic, not device latency.
        stretch.configure(int(c), int(r*0.080), int(r*0.020), false);
        referencePowerDelay.resize(stretch.inputLatency()+stretch.outputLatency(),0);
        stretch.setFormantBase(0); // Documented rough automatic F0 estimate.
        // Exercise the preallocated FFT path before capture can begin.
        float zeros[2][128] = {}, scratch[2][128] = {};
        const float *in[2] = {zeros[0], zeros[1]};
        float *out[2] = {scratch[0], scratch[1]};
        for (int done=0; done<stretch.blockSamples()*2; done+=128)
            stretch.process(in, 128, out, 128);
        stretch.reset();
    }
};
uint32_t dvc_speech_expected_latency(double rate) {
    return std::isfinite(rate) && rate>=8000 && rate<=192000 ? uint32_t(rate*0.080) : 0;
}
DVCSpeechDSP *dvc_speech_create(double rate, uint32_t channels) {
    if (!dvc_speech_expected_latency(rate) || channels<1 || channels>2) return nullptr;
    try { return new DVCSpeechDSP(rate, channels); }
    catch (...) { return nullptr; } // Initialization fails before reading a tap.
}
void dvc_speech_destroy(DVCSpeechDSP *d) { delete d; }
void dvc_speech_reset(DVCSpeechDSP *d) {
    if (!d) return;
    d->stretch.reset(); d->period.reset(); d->initialParameters=true;
    std::fill(d->referencePowerDelay.begin(),d->referencePowerDelay.end(),0);
    d->referencePosition=0; d->referencePower=d->outputPower=0; d->normalization=1;
}
uint32_t dvc_speech_latency_frames(const DVCSpeechDSP *d) {
    return d ? uint32_t(d->stretch.inputLatency()+d->stretch.outputLatency()) : 0;
}
bool dvc_speech_process(DVCSpeechDSP *d, const float *const in[2], float *const out[2],
                        uint32_t frames, float pitch, float formant, bool preserve) {
    if (!d || !in || !out || !in[0] || !out[0] ||
        (d->channels==2 && (!in[1] || !out[1]))) return false;
    if (!frames) return true;
    d->period.feed(in[0],frames);
    d->stretch.setFormantBase(d->period.frequency/float(d->rate));
    float targetPreservation = preserve ? 1.f : 0.f;
    if (d->initialParameters) {
        d->pitch=pitch; d->formant=formant; d->preservation=targetPreservation;
        d->initialParameters=false;
    } else {
        float smoothing = float(std::exp(-double(frames)/(d->rate*0.040)));
        d->pitch=pitch+(d->pitch-pitch)*smoothing;
        d->formant=formant+(d->formant-formant)*smoothing;
        d->preservation=targetPreservation+(d->preservation-targetPreservation)*smoothing;
    }
    d->stretch.setTransposeSemitones(d->pitch);
    // For the library's linear pitch mapping this continuous relative shift is
    // equivalent to compensatePitch=true at preservation=1, without an abrupt
    // Boolean change. The user formant target remains independent of pitch.
    d->stretch.setFormantSemitones(d->formant-d->pitch*d->preservation, false);
    try {
        d->stretch.process(in, int(frames), out, int(frames)); // Exactly rate 1.
        // Spectral-envelope changes can attenuate a sparse signal sharply.
        // Bounded linked energy normalization keeps that spectral stage near
        // the delayed input level; this is separate from compressor makeup.
        // Only power estimates are delayed here, with no added audio latency.
        double powerAlpha=std::exp(-1/(d->rate*0.025)), gainAlpha=std::exp(-1/(d->rate*0.040));
        bool envelopeActive=std::abs(d->formant-d->pitch*d->preservation)>0.001f;
        for (uint32_t i=0;i<frames;i++) {
            double inputEnergy=0,outputEnergy=0;
            for (uint32_t c=0;c<d->channels;c++) {
                if (!std::isfinite(out[c][i])) return false;
                inputEnergy+=double(in[c][i])*in[c][i];
                outputEnergy+=double(out[c][i])*out[c][i];
            }
            double delayed=d->referencePowerDelay[d->referencePosition];
            d->referencePowerDelay[d->referencePosition]=float(inputEnergy/d->channels);
            d->referencePosition=(d->referencePosition+1)%d->referencePowerDelay.size();
            d->referencePower=delayed+(d->referencePower-delayed)*powerAlpha;
            outputEnergy/=d->channels;
            d->outputPower=outputEnergy+(d->outputPower-outputEnergy)*powerAlpha;
            double target=envelopeActive && d->referencePower>1e-12 && d->outputPower>1e-12 ?
                std::clamp(std::sqrt(d->referencePower/d->outputPower),0.125,8.) : 1;
            d->normalization=target+(d->normalization-target)*gainAlpha;
            for (uint32_t c=0;c<d->channels;c++) out[c][i]*=float(d->normalization);
        }
        return true;
    } catch (...) {
        // Not a recovery loop: the caller emits silence and increments the
        // invalid counter so lifecycle supervision releases capture.
        return false;
    }
}
