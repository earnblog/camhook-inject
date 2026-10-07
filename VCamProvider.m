#import "VCamProvider.h"
#import <os/log.h>
#import <pthread.h>
#import <sys/stat.h>

// 文件日志
static void CamLog(const char *fmt, ...) {
    FILE *fp = fopen("/var/mobile/Media/camhook.log", "a");
    if (!fp) return;
    time_t now = time(NULL);
    struct tm *t = localtime(&now);
    fprintf(fp, "[%02d:%02d:%02d] ", t->tm_hour, t->tm_min, t->tm_sec);
    va_list args;
    va_start(args, fmt);
    vfprintf(fp, fmt, args);
    va_end(args);
    fprintf(fp, "\n");
    fclose(fp);
}

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
        CamLog("AVAssetReader create failed: %s", err ? err.localizedDescription.UTF8String : "nil");
        return false;
    }

    AVAssetTrack *track = [[p->asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    if (!track) {
        CamLog("no video track");
        return false;
    }

    NSDictionary *settings = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)
    };

    AVAssetReaderTrackOutput *output =
        [[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:settings];
    output.alwaysCopiesSampleData = NO;

    if (![reader canAddOutput:output]) {
        CamLog("cannot add output");
        return false;
    }
    [reader addOutput:output];

    if (![reader startReading]) {
        CamLog("startReading failed: %s", reader.error.localizedDescription.UTF8String);
        return false;
    }

    p->reader = reader;
    p->output = output;
    return true;
}

VCamProvider *VCamProviderCreate(const char *mp4Path) {
    if (!mp4Path || strlen(mp4Path) == 0) {
        CamLog("path empty");
        return NULL;
    }

    CamLog("trying load: %s", mp4Path);

    struct stat st;
    if (stat(mp4Path, &st) != 0) {
        CamLog("file not exist or no permission: %s errno=%d", mp4Path, errno);
        return NULL;
    }
    CamLog("file size=%lld", (long long)st.st_size);

    VCamProvider *p = (VCamProvider *)calloc(1, sizeof(VCamProvider));
    if (!p) {
        CamLog("calloc failed");
        return NULL;
    }

    pthread_mutex_init(&p->lock, NULL);
    p->loop = true;
    p->path = strdup(mp4Path);

    NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:mp4Path]];
    p->asset = [AVAsset assetWithURL:url];
    if (!p->asset) {
        CamLog("AVAsset nil");
        VCamProviderDestroy(p);
        return NULL;
    }

    p->duration = p->asset.duration;
    if (CMTIME_IS_INVALID(p->duration) || CMTimeCompare(p->duration, kCMTimeZero) <= 0) {
        CamLog("invalid duration");
        VCamProviderDestroy(p);
        return NULL;
    }

    AVAssetTrack *track = [[p->asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    if (!track) {
        CamLog("no video track");
        VCamProviderDestroy(p);
        return NULL;
    }

    CGSize size = track.naturalSize;
    p->width  = (int)size.width;
    p->height = (int)size.height;

    if (!VCamProviderRestartReader(p)) {
        CamLog("RestartReader failed");
        VCamProviderDestroy(p);
        return NULL;
    }

    CamLog("VCamProvider ready: %s %dx%d duration=%.2fs", mp4Path, p->width, p->height, CMTimeGetSeconds(p->duration));
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
            CamLog("video end, restart loop");
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
