// CamHook 注入换帧版 —— 失败原因直接显示在横幅
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <os/log.h>
#import <objc/runtime.h>
#import "VCamProvider.h"

static VCamProvider *gProvider = NULL;
static NSTimeInterval gLastBanner = 0;

// 自动尝试的路径列表
static const char *kVideoPaths[] = {
    "/var/mobile/Media/test.mp4",
    "/var/mobile/Documents/test.mp4",
    "/var/tmp/test.mp4",
    "/private/var/mobile/Media/test.mp4",
    NULL
};

// 简易文件日志（写到更稳的位置）
static void CamLog(const char *fmt, ...) {
    FILE *fp = fopen("/var/tmp/camhook.log", "a");
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

// ===================== 安全横幅 =====================
static void CamHookShowBanner(const char *msg) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        if (now - gLastBanner < 3.0) return;
        gLastBanner = now;

        UIWindow *win = nil;
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                    if (w.isKeyWindow) {
                        win = w;
                        break;
                    }
                }
            }
            if (win) break;
        }
        if (!win) return;

        CGFloat width = win.bounds.size.width - 24.0;
        CGFloat topY = win.safeAreaInsets.top > 0 ? win.safeAreaInsets.top : 44.0;

        UIView *banner = [[UIView alloc] initWithFrame:CGRectMake(12, topY + 8, width, 70)];
        banner.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.88];
        banner.layer.cornerRadius = 14.0;
        banner.clipsToBounds = YES;
        banner.userInteractionEnabled = NO;
        banner.alpha = 0.0;

        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(14, 0, width - 28, 70)];
        label.text = [NSString stringWithUTF8String:msg];
        label.textColor = [UIColor whiteColor];
        label.font = [UIFont boldSystemFontOfSize:14.0];
        label.numberOfLines = 3;
        [banner addSubview:label];
        [win addSubview:banner];

        [UIView animateWithDuration:0.3 animations:^{
            banner.alpha = 1.0;
        }];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [banner removeFromSuperview];
        });
    });
}

// ===================== 创建新的 CMSampleBuffer =====================
static CMSampleBufferRef CamHookCreateSampleBuffer(CVPixelBufferRef pixelBuffer,
                                                   CMTime pts,
                                                   CMTime duration) {
    if (!pixelBuffer) return NULL;

    CMVideoFormatDescriptionRef formatDesc = NULL;
    OSStatus status = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault,
                                                                    pixelBuffer,
                                                                    &formatDesc);
    if (status != noErr || !formatDesc) return NULL;

    CMSampleTimingInfo timing = {
        .duration = duration,
        .presentationTimeStamp = pts,
        .decodeTimeStamp = kCMTimeInvalid
    };

    CMSampleBufferRef newBuffer = NULL;
    status = CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault,
                                                pixelBuffer,
                                                true, NULL, NULL,
                                                formatDesc, &timing, &newBuffer);
    CFRelease(formatDesc);
    return (status == noErr) ? newBuffer : NULL;
}

// ===================== Proxy =====================
@interface CamHookProxy : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, weak) id<AVCaptureVideoDataOutputSampleBufferDelegate> realDelegate;
@end

@implementation CamHookProxy
- (void)captureOutput:(AVCaptureOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection
{
    if (!gProvider || !VCamProviderIsReady(gProvider)) {
        if ([self.realDelegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
            [self.realDelegate captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection];
        }
        return;
    }

    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    CMTime duration = CMSampleBufferGetDuration(sampleBuffer);
    if (CMTIME_IS_INVALID(duration) || CMTimeCompare(duration, kCMTimeZero) == 0) {
        duration = CMTimeMake(1, 30);
    }

    CVPixelBufferRef videoPB = VCamProviderCopyPixelBufferForTime(gProvider, pts);
    if (videoPB) {
        CMSampleBufferRef fake = CamHookCreateSampleBuffer(videoPB, pts, duration);
        CFRelease(videoPB);
        if (fake) {
            if ([self.realDelegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
                [self.realDelegate captureOutput:output didOutputSampleBuffer:fake fromConnection:connection];
            }
            CFRelease(fake);
            return;
        }
    }

    if ([self.realDelegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
        [self.realDelegate captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection];
    }
}
@end

// ===================== Hooks =====================
%hook AVCaptureSession
- (void)startRunning {
    %orig;

    CamLog("startRunning");

    if (gProvider) {
        VCamProviderDestroy(gProvider);
        gProvider = NULL;
    }

    // 自动尝试多个路径
    const char *usedPath = NULL;
    for (int i = 0; kVideoPaths[i] != NULL; i++) {
        CamLog("try path: %s", kVideoPaths[i]);
        gProvider = VCamProviderCreate(kVideoPaths[i]);
        if (gProvider && VCamProviderIsReady(gProvider)) {
            usedPath = kVideoPaths[i];
            break;
        }
        if (gProvider) {
            VCamProviderDestroy(gProvider);
            gProvider = NULL;
        }
    }

    if (gProvider && usedPath) {
        char msg[256];
        snprintf(msg, sizeof(msg), "✓ CamHook 换帧已启用\n%s", usedPath);
        CamHookShowBanner(msg);
        CamLog("SUCCESS: %s", usedPath);
    } else {
        CamHookShowBanner("✓ CamHook 已加载\n无可用视频\n请把 test.mp4 放到 Media 或 Documents");
        CamLog("ALL PATHS FAILED");
    }
}
%end

%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id)sampleBufferDelegate queue:(dispatch_queue_t)queue {
    if (sampleBufferDelegate && queue) {
        CamHookProxy *proxy = [CamHookProxy new];
        proxy.realDelegate = sampleBufferDelegate;
        objc_setAssociatedObject(self, "camhook_proxy", proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        %orig(proxy, queue);
    } else {
        %orig;
    }
}
%end

%ctor {
    FILE *fp = fopen("/var/tmp/camhook.log", "w");
    if (fp) {
        fprintf(fp, "=== CamHook started ===\n");
        fclose(fp);
    }
    CamLog("loaded");
}
