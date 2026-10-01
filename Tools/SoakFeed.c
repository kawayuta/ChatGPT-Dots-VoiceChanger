#include "SoakFeed.h"
#include <stdatomic.h>
#include <pthread.h>
#include <math.h>
#include <time.h>
#include <stdlib.h>
struct DVCSoakFeed { CVPBridge *bridge; double rate; _Atomic bool stop; pthread_t thread; float samples[512]; };
static double now(void) { struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec*1e-9; }
static void *produce(void *argument) {
    DVCSoakFeed *f=argument;uint64_t frame=0;double origin=now();
    AudioBufferList input={.mNumberBuffers=1,.mBuffers={{2,sizeof(f->samples),f->samples}}};
    while (!atomic_load_explicit(&f->stop,memory_order_acquire)) {
        for(unsigned i=0;i<256;i++) {
            double t=(frame+i)/f->rate;
            // Synthetic voiced signal with a short silent gap every two seconds.
            double envelope=fmod(t,2)<1.8 ? 1 : 0;
            float v=(float)(envelope*(.06*sin(2*M_PI*120*t)+.03*sin(2*M_PI*600*t)+.02*sin(2*M_PI*1800*t)));
            f->samples[2*i]=v;f->samples[2*i+1]=v*.7f;
        }
        cvp_capture_callback(0,NULL,&input,NULL,NULL,NULL,f->bridge);frame+=256;
        // Independent simulated capture clock, +150 ppm. Never a physical device claim.
        double deadline=origin+frame/(f->rate*1.00015),remaining=deadline-now();
        if(remaining>0){struct timespec wait={(time_t)remaining,(long)((remaining-floor(remaining))*1e9)};nanosleep(&wait,NULL);}
    }
    return NULL;
}
DVCSoakFeed *dvc_soak_feed_start(CVPBridge *bridge,double rate) {
    DVCSoakFeed *f=calloc(1,sizeof(*f));if(!f)return NULL;
    f->bridge=bridge;f->rate=rate;atomic_init(&f->stop,false);
    if(pthread_create(&f->thread,NULL,produce,f)!=0){free(f);return NULL;}return f;
}
void dvc_soak_feed_stop(DVCSoakFeed *f) { if(f){atomic_store_explicit(&f->stop,true,memory_order_release);pthread_join(f->thread,NULL);free(f);} }
