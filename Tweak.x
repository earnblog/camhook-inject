// CamHook —— 打开相机后从相册选择视频
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <Photos/Photos.h>
#import <MobileCoreServices/MobileCoreServices.h>
#import <objc/runtime.h>
#import "VCamProvider.h"

static VCamProvider *gProvider = NULL;
static NSTimeInterval gLastBanner = 0;
static BOOL gPickerShowing = NO;

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

static void CamHookShowBanner(const char *msg) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        if (now - gLastBanner < 2.5) return;
        gLastBanner = now;

        UIWindow *win = nil;
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                    if (w.isKeyWindow) { win = w; break; }
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

        [UIView animateWithDuration:0.3 animations:^{ banner.alpha = 1.0; }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [banner removeFromSuperview];
        });
    });
}

static NSString *CamHookTempVideoPath(void) {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:@"camhook_selected.mp4"];
}

static BOOL CamHookLoadVideoAtPath(NSString *path) {
    if (gProvider) {
        VCamProviderDestroy(gProvider);
        gProvider = NULL;
    }
    gProvider = VCamProviderCreate(path.UTF8String);
    if (gProvider && VCamProviderIsReady(gProvider)) {
        CamLog("load OK: %s", path.UTF8String);
        return YES;
    }
    CamLog("load FAIL: %s", path.UTF8String);
    if (gProvider) {
        VCamProviderDestroy(gProvider);
        gProvider = NULL;
    }
    return NO;
}

// ===================== 相册选择器 =====================
@interface CamHookPickerDelegate : NSObject <UIImagePickerControllerDelegate, UINavigationControllerDelegate>
@end

@implementation CamHookPickerDelegate

- (void)imagePickerController:(UIImagePickerController *)picker
didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey,id> *)info {
    gPickerShowing = NO;
    NSURL *url = info[UIImagePickerControllerMediaURL];
    [picker dismissViewControllerAnimated:YES completion:^{
        if (!url) {
            CamHookShowBanner("✓ CamHook\n未获取到视频");
            return;
        }
        CamLog("picked: %s", url.path.UTF8String);

        NSString *dst = CamHookTempVideoPath();
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm removeItemAtPath:dst error:nil];

        NSError *err = nil;
        BOOL ok = [fm copyItemAtPath:url.path toPath:dst error:&err];
        if (!ok) {
            // 有些相册视频是 file:// 临时文件，再试 data 方式
            NSData *data = [NSData dataWithContentsOfURL:url];
            ok = [data writeToFile:dst atomically:YES];
            CamLog("copy via data: %d", ok);
        }

        if (!ok) {
            CamHookShowBanner("✓ CamHook\n复制视频失败");
            CamLog("copy failed: %s", err.localizedDescription.UTF8String ?: "");
            return;
        }

        if (CamHookLoadVideoAtPath(dst)) {
            CamHookShowBanner("✓ CamHook 换帧已启用\n已选择相册视频");
        } else {
            CamHookShowBanner("✓ CamHook\n视频解码失败");
        }
    }];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    gPickerShowing = NO;
    [picker dismissViewControllerAnimated:YES completion:nil];
    CamHookShowBanner("✓ CamHook\n已取消选择");
}

@end

static CamHookPickerDelegate *gPickerDelegate = nil;

static UIViewController *CamHookTopVC(void) {
    UIWindow *win = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (w.isKeyWindow) { win = w; break; }
            }
        }
        if (win) break;
    }
    if (!win) return nil;
    UIViewController *vc = win.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

static void CamHookPresentPicker(void) {
    if (gPickerShowing) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = CamHookTopVC();
        if (!top) {
            CamLog("no top VC");
            CamHookShowBanner("✓ CamHook\n无法弹出选择器");
            return;
        }

        // 先请求相册权限
        PHAuthorizationStatus status = [PHPhotoLibrary authorizationStatus];
        if (status == PHAuthorizationStatusNotDetermined) {
            [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus s) {
                if (s == PHAuthorizationStatusAuthorized || s == PHAuthorizationStatusLimited) {
                    CamHookPresentPicker();
                } else {
                    CamHookShowBanner("✓ CamHook\n需要相册权限");
                }
            }];
            return;
        }
        if (status != PHAuthorizationStatusAuthorized && status != PHAuthorizationStatusLimited) {
            CamHookShowBanner("✓ CamHook\n请到设置打开相册权限");
            return;
        }

        if (!gPickerDelegate) gPickerDelegate = [CamHookPickerDelegate new];

        UIImagePickerController *picker = [[UIImagePickerController alloc] init];
        picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
        picker.mediaTypes = @[(NSString *)kUTTypeMovie];
        picker.delegate = gPickerDelegate;
        picker.videoQuality = UIImagePickerControllerQualityTypeHigh;
        gPickerShowing = YES;
        [top presentViewController:picker animated:YES completion:nil];
        CamLog("picker presented");
    });
}

// ===================== SampleBuffer =====================
static CMSampleBufferRef CamHookCreateSampleBuffer(CVPixelBufferRef pixelBuffer,
                                                   CMTime pts,
                                                   CMTime duration) {
    if (!pixelBuffer) return NULL;
    CMVideoFormatDescriptionRef formatDesc = NULL;
    OSStatus status = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &formatDesc);
    if (status != noErr || !formatDesc) return NULL;

    CMSampleTimingInfo timing = {
        .duration = duration,
        .presentationTimeStamp = pts,
        .decodeTimeStamp = kCMTimeInvalid
    };
    CMSampleBufferRef newBuffer = NULL;
    status = CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, true, NULL, NULL,
                                                formatDesc, &timing, &newBuffer);
    CFRelease(formatDesc);
    return (status == noErr) ? newBuffer : NULL;
}

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

    // 若已有选好的视频就直接用，否则弹出相册
    NSString *temp = CamHookTempVideoPath();
    if ([[NSFileManager defaultManager] fileExistsAtPath:temp] && CamHookLoadVideoAtPath(temp)) {
        CamHookShowBanner("✓ CamHook 换帧已启用\n使用上次选择的视频");
    } else {
        CamHookShowBanner("✓ CamHook\n请选择视频…");
        // 稍延迟，等界面起来再弹
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            CamHookPresentPicker();
        });
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
        fprintf(fp, "=== CamHook picker version ===\n");
        fclose(fp);
    }
    CamLog("loaded");
}
