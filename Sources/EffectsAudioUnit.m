#import "EffectsAudioUnit.h"
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    DVCDSP *dsp;
    uint32_t maximum, channels;
    AudioBufferList *input;
    float *inputStorage[2], *outputStorage[2];
} RenderContext;
static void releaseContextResources(RenderContext *c) {
    if (!c) return;
    dvc_dsp_destroy(c->dsp); c->dsp=NULL;
    free(c->input); c->input=NULL;
    for (int i=0;i<2;i++) { free(c->inputStorage[i]); c->inputStorage[i]=NULL; free(c->outputStorage[i]); c->outputStorage[i]=NULL; }
}
@implementation DVCEffectsAudioUnit {
    AUAudioUnitBusArray *_inputs, *_outputs;
    RenderContext *_context;
    DVCParameters _requestedParameters;
}
- (instancetype)initWithComponentDescription:(AudioComponentDescription)description
                                    options:(AudioComponentInstantiationOptions)options error:(NSError **)error {
    self=[super initWithComponentDescription:description options:options error:error];
    if (!self) return nil;
    _context=calloc(1,sizeof(RenderContext));
    if (!_context) { if (error) *error=[NSError errorWithDomain:NSOSStatusErrorDomain code:kAudio_MemFullError userInfo:nil]; return nil; }
    AVAudioFormat *format=[[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32 sampleRate:48000 channels:2 interleaved:NO];
    AUAudioUnitBus *input=[[AUAudioUnitBus alloc] initWithFormat:format error:error];
    AUAudioUnitBus *output=[[AUAudioUnitBus alloc] initWithFormat:format error:error];
    if (!input || !output) return nil;
    input.maximumChannelCount=2; output.maximumChannelCount=2;
    _inputs=[[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeInput busses:@[input]];
    _outputs=[[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeOutput busses:@[output]];
    self.maximumFramesToRender=4096;
    _requestedParameters=dvc_default_parameters();
    return self;
}
- (AUAudioUnitBusArray *)inputBusses { return _inputs; }
- (AUAudioUnitBusArray *)outputBusses { return _outputs; }
- (BOOL)allocateRenderResourcesAndReturnError:(NSError **)error {
    AVAudioFormat *in=_inputs[0].format, *out=_outputs[0].format;
    if (in.commonFormat!=AVAudioPCMFormatFloat32 || out.commonFormat!=AVAudioPCMFormatFloat32 ||
        in.isInterleaved || out.isInterleaved || in.sampleRate!=out.sampleRate ||
        in.channelCount!=out.channelCount || in.channelCount<1 || in.channelCount>2) {
        if (error) *error=[NSError errorWithDomain:NSOSStatusErrorDomain code:kAudioUnitErr_FormatNotSupported userInfo:nil];
        return NO;
    }
    releaseContextResources(_context);
    _context->maximum=self.maximumFramesToRender; _context->channels=in.channelCount;
    _context->dsp=dvc_dsp_create(in.sampleRate,in.channelCount);
    _context->input=calloc(1,offsetof(AudioBufferList,mBuffers)+sizeof(AudioBuffer)*in.channelCount);
    if (_context->input) _context->input->mNumberBuffers=in.channelCount;
    BOOL success=_context->dsp && _context->input;
    for (uint32_t i=0;i<in.channelCount;i++) {
        _context->inputStorage[i]=calloc(_context->maximum,sizeof(float));
        _context->outputStorage[i]=calloc(_context->maximum,sizeof(float));
        success=success && _context->inputStorage[i] && _context->outputStorage[i];
    }
    if (!success) {
        releaseContextResources(_context);
        if (error) *error=[NSError errorWithDomain:NSOSStatusErrorDomain code:kAudio_MemFullError userInfo:nil];
        return NO;
    }
    dvc_dsp_set_parameters(_context->dsp,_requestedParameters);
    if (![super allocateRenderResourcesAndReturnError:error]) { releaseContextResources(_context); return NO; }
    return YES;
}
- (void)deallocateRenderResources { [super deallocateRenderResources]; releaseContextResources(_context); }
- (void)dealloc { releaseContextResources(_context); free(_context); }
- (void)reset { [super reset]; if (_context && _context->dsp) dvc_dsp_reset(_context->dsp); }
- (void)applyParameters:(DVCParameters)parameters {
    // Called only on the app's serialized lifecycle queue, never from a render callback.
    _requestedParameters=parameters; if (_context->dsp) dvc_dsp_set_parameters(_context->dsp,parameters);
}
- (DVCDSPStats)statistics { return dvc_dsp_stats(_context->dsp); }
- (NSTimeInterval)latency { double rate=_outputs[0].format.sampleRate; return rate>0 ? dvc_dsp_expected_latency(rate)/rate : 0; }
- (AUInternalRenderBlock)internalRenderBlock {
    RenderContext *c=_context; // Stable C owner; no Objective-C message sends in this block.
    return ^AUAudioUnitStatus(AudioUnitRenderActionFlags *flags,const AudioTimeStamp *time,
                              AUAudioFrameCount frames,NSInteger bus,AudioBufferList *output,
                              const AURenderEvent *events,AURenderPullInputBlock pull) {
        (void)events;
        if (!c || !c->dsp || !pull) return kAudioUnitErr_Uninitialized;
        if (frames>c->maximum) return kAudioUnitErr_TooManyFramesToProcess;
        if (bus!=0 || !output || output->mNumberBuffers!=c->channels) return kAudio_ParamError;
        for (uint32_t i=0;i<c->channels;i++) {
            c->input->mBuffers[i]=(AudioBuffer){1,frames*sizeof(float),c->inputStorage[i]};
        }
        OSStatus status=pull(flags,time,frames,0,c->input);
        if (status!=noErr) return status;
        const float *inputs[2]={NULL,NULL}; float *outputs[2]={NULL,NULL};
        for (uint32_t i=0;i<c->channels;i++) {
            if (!c->input->mBuffers[i].mData || c->input->mBuffers[i].mDataByteSize<frames*sizeof(float)) return kAudio_ParamError;
            if (!output->mBuffers[i].mData) { output->mBuffers[i].mData=c->outputStorage[i]; output->mBuffers[i].mDataByteSize=frames*sizeof(float); }
            if (output->mBuffers[i].mNumberChannels!=1 || output->mBuffers[i].mDataByteSize<frames*sizeof(float)) return kAudio_ParamError;
            inputs[i]=c->input->mBuffers[i].mData; outputs[i]=output->mBuffers[i].mData;
            output->mBuffers[i].mDataByteSize=frames*sizeof(float);
        }
        dvc_dsp_process(c->dsp,inputs,outputs,frames);
        *flags &= ~kAudioUnitRenderAction_OutputIsSilence; // A silent input may have a buffered tail.
        return noErr;
    };
}
@end
AudioComponentDescription DVCRegisterEffectsAudioUnit(void) {
    AudioComponentDescription d={kAudioUnitType_Effect,'DvFX','Dots',0,0};
    static dispatch_once_t once;
    dispatch_once(&once,^{ [AUAudioUnit registerSubclass:DVCEffectsAudioUnit.class asComponentDescription:d name:@"Dots: Voice Effects" version:1]; });
    return d;
}
