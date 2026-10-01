#import <AudioToolbox/AudioToolbox.h>
#import <AVFAudio/AVFAudio.h>
#import "VoiceDSP.h"
NS_ASSUME_NONNULL_BEGIN
// Private in-process Audio Unit. Nothing is installed into /Library/Audio/Plug-Ins.
@interface DVCEffectsAudioUnit : AUAudioUnit
- (void)applyParameters:(DVCParameters)parameters;
- (DVCDSPStats)statistics;
@end
AudioComponentDescription DVCRegisterEffectsAudioUnit(void);
NS_ASSUME_NONNULL_END
