#import "VCamProvider.h"
#import <os/log.h>
#import <pthread.h>
#import <sys/stat.h>

struct VCamProvider {
    AVAsset                    *asset;
    AVAssetReader              *reader;
    AVAssetReaderTrackOutput   *output;
    CMTime                      duration;
    CMTime                      firstCameraPts;
    bool                        hasFirstPts;
    bool                        loop;
    char                       *path;
    pthread_mutex_t             lock;
    int                         width;
    int                         height;
};

static bool VCamProviderRestartReader(VCamProvider *p) {
    if (!p || !p->asset) return false;

    NSError *err = nil;
    AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:p->asset error:&err];
    if (!reader || err) {
        os_log(OS_LOG_DEFAULT, "[CamHook] AVAssetReader create failed: %{public}@", err);
        return false;
    }

    AVAssetTrack *track = [[p->asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    if (!track) {
        os_log(OS_LOG_DEFAULT, "[CamHook] no video track");
        return false;
    }

    // 和你跑通的 main.m 保持一致，用 32BGRA
    NSDictionary *settings = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)
    };

    AVAssetReaderTrackOutput *output =
        [[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:settings];
    output.alwaysCopiesSampleData = NO;

    if (![reader canAddOutput:output]) {
        os_log(OS_LOG_DEFAULT, "[CamHook] cannot add output");
        return false;
    }
    [reader addOutput:output];

    if (![reader startReading]) {
        os_log(OS_LOG_DEFAULT, "[CamHook] startReading failed: %{public}@", reader.error);
        return false;
    }

    p->reader = reader;
    p->output = output;
    return true;
}

VCamProvider *VCamProviderCreate(const char *mp4Path) {
    if (!mp4Path || strlen(mp4Path) == 0) {
        os_log(OS_LOG_DEFAULT, "[CamHook] path empty");
        return NULL;
    }

    os_log(OS_LOG_DEFAULT, "[CamHook] trying load: %s", mp4Path);

    struct stat st;
    if (stat(mp4Path, &st) != 0) {
        os_log(OS_LOG_DEFAULT, "[CamHook] file not exist or no permission: %s errno=%d", mp4Path, errno);
        return NULL;
    }
    os_log(OS_LOG_DEFAULT, "[CamHook] file size=%lld", (long long)st.st_size);

    VCamProvider *p = (VCamProvider *)calloc(1, sizeof(VCamProvider));
    if (!p) return NULL;

    pthread_mutex_init(&p->lock, NULL);
    p->loop = true;
    p->path = strdup(mp4Path);

    NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:mp4Path]];
    p->asset = [AVAsset assetWithURL:url];
    if (!p->asset) {
        os_log(OS_LOG_DEFAULT, "[CamHook] AVAsset nil");
        VCamProviderDestroy(p);
        return NULL;
    }

    p->duration = p->asset.duration;
    if (CMTIME_IS_INVALID(p->duration) || CMTimeCompare(p->duration, kCMTimeZero) <= 0) {
        os_log(OS_LOG_DEFAULT, "[CamHook] invalid duration");
        VCamProviderDestroy(p);
        return NULL;
    }

    AVAssetTrack *track = [[p->asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    if (!track) {
        os_log(OS_LOG_DEFAULT, "[CamHook] no video track");
        VCamProviderDestroy(p);
        return NULL;
    }

    CGSize size = track.naturalSize;
    p->width  = (int)size.width;
    p->height = (int)size.height;

    if (!VCamProviderRestartReader(p)) {
        VCamProviderDestroy(p);
        return NULL;
    }

    os_log(OS_LOG_DEFAULT, "[CamHook] VCamProvider ready: %s %dx%d duration=%.2fs",
           mp4Path, p->width, p->height, CMTimeGetSeconds(p->duration));
    return p;
}

void VCamProviderDestroy(VCamProvider *p) {
    if (!p) return;
    pthread_mutex_lock(&p->lock);
    p->reader = nil;
    p->output = nil;
    p->asset = nil;
    free(p->path);
    pthread_mutex_unlock(&p->lock);
    pthread_mutex_destroy(&p->lock);
    free(p);
}

void VCamProviderReset(VCamProvider *p) {
    if (!p) return;
    pthread_mutex_lock(&p->lock);
    p->hasFirstPts = false;
    VCamProviderRestartReader(p);
    pthread_mutex_unlock(&p->lock);
}

bool VCamProviderIsReady(VCamProvider *p) {
    return p && p->reader && p->output;
}

CVPixelBufferRef VCamProviderCopyPixelBufferForTime(VCamProvider *p, CMTime cameraPts) {
    if (!p) return NULL;

    pthread_mutex_lock(&p->lock);

    if (!p->hasFirstPts) {
        p->firstCameraPts = cameraPts;
        p->hasFirstPts = true;
    }

    CMSampleBufferRef sb = [p->output copyNextSampleBuffer];
    if (!sb) {
        if (p->loop) {
            os_log(OS_LOG_DEFAULT, "[CamHook] video end, restart loop");
            VCamProviderRestartReader(p);
            sb = [p->output copyNextSampleBuffer];
        }
    }

    CVPixelBufferRef pb = NULL;
    if (sb) {
        pb = CMSampleBufferGetImageBuffer(sb);
        if (pb) CFRetain(pb);
        CFRelease(sb);
    }

    pthread_mutex_unlock(&p->lock);
    return pb;
}