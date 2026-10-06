#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <AVFoundation/AVFoundation.h>
#import <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct VCamProvider VCamProvider;

VCamProvider *VCamProviderCreate(const char *mp4Path);
void          VCamProviderDestroy(VCamProvider *p);
CVPixelBufferRef VCamProviderCopyPixelBufferForTime(VCamProvider *p, CMTime cameraPts);
void          VCamProviderReset(VCamProvider *p);
bool          VCamProviderIsReady(VCamProvider *p);

#ifdef __cplusplus
}
#endif