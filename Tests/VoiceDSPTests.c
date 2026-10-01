#include "VoiceDSP.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <assert.h>
#include <string.h>

static void process(DVCDSP *d,float *in,float *out,uint32_t count) {
    const uint32_t blocks[]={1,17,257,4096,511}; uint32_t position=0,index=0;
    while (position<count) {
        uint32_t n=blocks[index++%5]; if (n>count-position) n=count-position;
        const float *inputs[2]={in+position,NULL}; float *outputs[2]={out+position,NULL};
        dvc_dsp_process(d,inputs,outputs,n); position+=n;
    }
}
static double rms(const float *p,uint32_t n) { double sum=0; for (uint32_t i=0;i<n;i++) sum+=p[i]*p[i]; return sqrt(sum/n); }
static double amplitude(const float *p,uint32_t n,double rate,double f) {
    double c=2*cos(2*M_PI*f/rate), a=0,b=0;
    for (uint32_t i=0;i<n;i++) { double v=p[i]+c*a-b; b=a; a=v; }
    return 2*sqrt(fmax(0,a*a+b*b-c*a*b))/n;
}
static double envelope_peak(const float *p,uint32_t n,double rate,double center) {
    double peak=-1; int bin=0; int lo=(int)ceil(center*.85/120),hi=(int)floor(center*1.15/120);
    for (int k=lo;k<=hi;k++) { double a=amplitude(p,n,rate,120*k); if (a>peak) { peak=a; bin=k; } }
    double l=log(fmax(amplitude(p,n,rate,120*(bin-1)),1e-12)),m=log(fmax(peak,1e-12)),r=log(fmax(amplitude(p,n,rate,120*(bin+1)),1e-12));
    double offset=.5*(l-r)/(l-2*m+r); offset=fmin(.5,fmax(-.5,offset)); return 120*(bin+offset);
}
static double period_frequency(const float *p,uint32_t n,double rate) {
    int lo=(int)(rate/120*.98),hi=(int)(rate/120*1.02); double peak=-1; int best=0;
    for (int lag=lo;lag<=hi;lag++) {
        double dot=0,a=0,b=0;
        for (uint32_t i=0;i<n-(uint32_t)hi;i++) { dot+=p[i]*p[i+lag];a+=p[i]*p[i];b+=p[i+lag]*p[i+lag]; }
        double correlation=dot/sqrt(a*b); if(correlation>peak) {peak=correlation;best=lag;}
    }
    return rate/best;
}
static void test_bypass(double rate) {
    uint32_t count=(uint32_t)(rate*2); float *in=calloc(count,sizeof(float)),*out=calloc(count,sizeof(float));
    for(uint32_t i=0;i<count;i++) in[i]=.1f*sin(2*M_PI*440*i/rate);
    DVCDSP *d=dvc_dsp_create(rate,1);assert(d);process(d,in,out,count);
    uint32_t delay=dvc_dsp_latency_frames(d);double maximum=0;
    for (uint32_t i=delay;i<count;i++) maximum=fmax(maximum,fabs(out[i]-in[i-delay]));
    assert(maximum<1e-6);assert(dvc_dsp_stats(d).nonfinite_samples==0);
    printf("BYPASS rate=%.0f delay_frames=%u maximum_error=%.9f PASS\n",rate,delay,maximum);
    dvc_dsp_destroy(d);free(in);free(out);
}
static void test_formant(double rate,float semitones) {
    uint32_t count=(uint32_t)(rate*6),one=(uint32_t)rate; float *in=calloc(count,sizeof(float)),*out=calloc(count,sizeof(float));
    for (uint32_t i=0;i<count;i++) {
        double sum=0;
        for(int h=1;h<=60 && h*120<rate/2;h++) {
            double f=h*120,env=.02+4*exp(-.5*pow((f-600)/130,2))+3*exp(-.5*pow((f-1800)/210,2))+2*exp(-.5*pow((f-3000)/250,2));
            sum+=.004*env/sqrt(h)*sin(2*M_PI*f*i/rate);
        }
        in[i]=(float)sum;
    }
    DVCDSP *d=dvc_dsp_create(rate,1);assert(d);DVCParameters p=dvc_default_parameters();p.formant_enabled=true;p.formant_semitones=semitones;dvc_dsp_set_parameters(d,p);
    process(d,in,out,count);double ratio=exp2(semitones/12.0),f0=period_frequency(out+4*one,10000,rate);
    assert(fabs(f0/120-1)<.01);
    for(int k=0;k<3;k++) {
        double nominal=k==0?600:k==1?1800:3000;
        double before=envelope_peak(in+one,one,rate,nominal),after=envelope_peak(out+4*one,one,rate,nominal*ratio),error=fabs(after/(before*ratio)-1);
        printf("FORMANT rate=%.0f shift=%.1f band=%d before=%.2f after=%.2f expected=%.2f error=%.4f f0=%.3f\n",rate,semitones,k+1,before,after,before*ratio,error,f0);
        fflush(stdout);assert(error<.10);
    }
    assert(dvc_dsp_stats(d).nonfinite_samples==0);assert(dvc_dsp_stats(d).protection_frames==0);
    dvc_dsp_destroy(d);free(in);free(out);
}
static void test_eq(double rate,int band,double f) {
    uint32_t count=(uint32_t)(rate*3),one=(uint32_t)rate;float *in=calloc(count,sizeof(float)),*out=calloc(count,sizeof(float));
    for(uint32_t i=0;i<count;i++)in[i]=.02f*sin(2*M_PI*f*i/rate);
    DVCDSP *d=dvc_dsp_create(rate,1);DVCParameters p=dvc_default_parameters();p.eq_enabled=true;
    if (band==0)p.low_db=6;else if(band==1)p.mid_db=6;else p.high_db=6;
    dvc_dsp_set_parameters(d,p);process(d,in,out,count);
    double db=20*log10(rms(out+2*one,one)/rms(in+one,one));
    printf("EQ rate=%.0f band=%d f=%.0f measured_db=%.3f PASS\n",rate,band,f,db);assert(fabs(db-6)<.3);
    dvc_dsp_destroy(d);free(in);free(out);
}
static void test_compressor(double rate) {
    uint32_t count=(uint32_t)(rate*3),one=(uint32_t)rate;float *in=calloc(count,sizeof(float)),*out=calloc(count,sizeof(float));
    for(uint32_t i=0;i<count;i++)in[i]=.5;
    DVCDSP *d=dvc_dsp_create(rate,1);DVCParameters p=dvc_default_parameters();p.compressor_enabled=true;dvc_dsp_set_parameters(d,p);process(d,in,out,count);
    double reduction=-20*log10(rms(out+2*one,one)/.5),expected=(20*log10(.5)+18)*(1-1.0/3);
    printf("COMPRESSOR rate=%.0f reduction_db=%.3f expected_db=%.3f PASS\n",rate,reduction,expected);assert(fabs(reduction-expected)<.1);
    p.volume=NAN;p.ratio=INFINITY;p.formant_semitones=100;p.eq_enabled=true;p.low_db=100;dvc_dsp_set_parameters(d,p);process(d,in,out,count);
    for(uint32_t i=0;i<count;i++)assert(isfinite(out[i]) && fabs(out[i])<=.981);
    in[0]=NAN;process(d,in,out,count);assert(dvc_dsp_stats(d).nonfinite_samples>0);
    dvc_dsp_destroy(d);free(in);free(out);
}
static void test_stereo_and_parameters(void) {
    DVCDSP *d=dvc_dsp_create(48000,2);assert(d);float in[2][4096],out[2][4096];
    DVCParameters p=dvc_default_parameters();p.formant_enabled=p.eq_enabled=p.compressor_enabled=true;
    for(unsigned block=0;block<500;block++) {
        p.formant_semitones=8*sin(block*.1);p.low_db=12*cos(block*.2);p.mid_db=-p.low_db;p.high_db=p.low_db;
        p.threshold_db=-48+48*(block%10)/9.0;p.volume=(block%5)/4.f;dvc_dsp_set_parameters(d,p);
        for(unsigned i=0;i<4096;i++){in[0][i]=.2*sin((block*4096+i)*.05);in[1][i]=in[0][i]*.5;}
        const float *inputs[2]={in[0],in[1]};float *outputs[2]={out[0],out[1]};dvc_dsp_process(d,inputs,outputs,4096);
        for(unsigned i=0;i<4096;i++){assert(isfinite(out[0][i]) && fabs(out[0][i])<=.981);assert(fabs(out[1][i]-.5*out[0][i])<1e-5);}
    }
    assert(dvc_dsp_stats(d).nonfinite_samples==0);dvc_dsp_destroy(d);
    assert(!dvc_dsp_create(0,1));assert(!dvc_dsp_create(48000,3));puts("STEREO linked balance / live parameter changes PASS");
}
int main(void) {
    setbuf(stdout,NULL);puts("TEST_MAIN_STARTED");
    double rates[]={24000,44100,48000};
    for (int i=0;i<3;i++){test_bypass(rates[i]);test_formant(rates[i],-4);test_formant(rates[i],4);test_eq(rates[i],0,40);test_eq(rates[i],1,1000);test_eq(rates[i],2,rates[i]==24000?8000:10000);test_compressor(rates[i]);}
    test_stereo_and_parameters();puts("VOICE_DSP_TESTS_PASS");return 0;
}
