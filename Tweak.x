// CamHook —— 照片/视频盖住预览，顶部停止，视频只播一遍
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <PhotosUI/PhotosUI.h>
#import <objc/runtime.h>
#import <stdio.h>
#import <time.h>
#import <stdarg.h>
#import "VCamProvider.h"

static VCamProvider *gProvider = NULL;
static NSTimeInterval gLastBanner = 0;
static BOOL gPickerShowing = NO;
static NSInteger gGen = 0;
static AVPlayer *gPlayer = NULL;
static AVPlayerLayer *gPlayerLayer = NULL;
static UIView *gOverlay = NULL;
static UIWindow *gOverlayWindow = nil;
static id gEndObserver = nil;

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

static UIWindowScene *CamHookScene(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) return (UIWindowScene *)scene;
    }
    return nil;
}

static void CamHookRestoreCameraWindow(void) {
    UIWindow *best = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (w == gOverlayWindow || w.hidden) continue;
            if (!best || w.windowLevel < best.windowLevel) best = w;
        }
    }
    if (best) [best makeKeyWindow];
}

static UIViewController *CamHookTopVC(void) {
    UIWindow *win = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (w == gOverlayWindow || w.hidden) continue;
            if (w.isKeyWindow) { win = w; break; }
            if (!win) win = w;
        }
        if (win.isKeyWindow) break;
    }
    if (!win) return nil;
    UIViewController *vc = win.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

static void CamHookShowBanner(const char *msg) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        if (now - gLastBanner < 1.2) return;
        gLastBanner = now;
        UIWindow *win = (gOverlayWindow && !gOverlayWindow.hidden) ? gOverlayWindow : nil;
        if (!win) {
            for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                if (![scene isKindOfClass:[UIWindowScene class]]) continue;
                for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                    if (!w.hidden && w != gOverlayWindow) { win = w; break; }
                }
            }
        }
        if (!win) return;
        CGFloat width = win.bounds.size.width - 24.0;
        CGFloat topY = win.safeAreaInsets.top > 20 ? win.safeAreaInsets.top + 58 : 100;
        UIView *banner = [[UIView alloc] initWithFrame:CGRectMake(12, topY, width, 52)];
        banner.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.88];
        banner.layer.cornerRadius = 12.0;
        banner.userInteractionEnabled = NO;
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(12, 0, width - 24, 52)];
        label.text = [NSString stringWithUTF8String:msg];
        label.textColor = [UIColor whiteColor];
        label.font = [UIFont boldSystemFontOfSize:14.0];
        label.numberOfLines = 2;
        [banner addSubview:label];
        [win addSubview:banner];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [banner removeFromSuperview];
        });
    });
}

static NSString *CamHookTempVideoPath(void) {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:@"camhook_selected.mp4"];
}

static void CamHookTearDownOverlay(void) {
    if (gEndObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:gEndObserver];
        gEndObserver = nil;
    }
    if (gPlayer) {
        [gPlayer pause];
        gPlayer = nil;
    }
    gPlayerLayer = nil;
    gOverlay = nil;
    UIWindow *old = gOverlayWindow;
    gOverlayWindow = nil;
    old.hidden = YES;
    CamHookRestoreCameraWindow();
}

static void CamHookStopPreview(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ CamHookStopPreview(); });
        return;
    }
    if (gProvider) {
        VCamProviderDestroy(gProvider);
        gProvider = NULL;
    }
    CamHookTearDownOverlay();
    CamLog("stopped");
}

@interface CamHookStopTarget : NSObject
@end
@implementation CamHookStopTarget
- (void)onStop:(id)sender { CamHookStopPreview(); }
@end
static CamHookStopTarget *gStopTarget = nil;

@interface CamHookOverlayView : UIView
@property (nonatomic, strong) AVPlayerLayer *playerLayer;
@end
@implementation CamHookOverlayView
- (void)layoutSubviews {
    [super layoutSubviews];
    self.playerLayer.frame = self.bounds;
}
@end

static UIWindow *CamHookMakeOverlayWindow(void) {
    UIWindowScene *scene = CamHookScene();
    if (!scene) return nil;
    CamHookTearDownOverlay();
    if (!gStopTarget) gStopTarget = [CamHookStopTarget new];

    UIWindow *ow = [[UIWindow alloc] initWithWindowScene:scene];
    ow.frame = scene.coordinateSpace.bounds;
    ow.windowLevel = UIWindowLevelAlert + 1.0;
    ow.backgroundColor = [UIColor blackColor];
    UIViewController *root = [UIViewController new];
    root.view.backgroundColor = [UIColor blackColor];
    ow.rootViewController = root;

    UIButton *stop = [UIButton buttonWithType:UIButtonTypeSystem];
    stop.translatesAutoresizingMaskIntoConstraints = NO;
    stop.backgroundColor = [UIColor systemRedColor];
    stop.layer.cornerRadius = 22.0;
    stop.clipsToBounds = YES;
    [stop setTitle:@"停止" forState:UIControlStateNormal];
    [stop setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    stop.titleLabel.font = [UIFont boldSystemFontOfSize:18.0];
    [stop addTarget:gStopTarget action:@selector(onStop:) forControlEvents:UIControlEventTouchUpInside];
    [root.view addSubview:stop];
    [NSLayoutConstraint activateConstraints:@[
        [stop.topAnchor constraintEqualToAnchor:root.view.safeAreaLayoutGuide.topAnchor constant:8],
        [stop.centerXAnchor constraintEqualToAnchor:root.view.centerXAnchor],
        [stop.widthAnchor constraintEqualToConstant:160],
        [stop.heightAnchor constraintEqualToConstant:44],
    ]];

    ow.hidden = NO;
    gOverlayWindow = ow;
    return ow;
}

static void CamHookShowOverlay(NSString *videoPath) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (videoPath.length == 0) return;
        UIWindow *ow = CamHookMakeOverlayWindow();
        if (!ow) return;

        CamHookOverlayView *box = [[CamHookOverlayView alloc] initWithFrame:ow.bounds];
        box.backgroundColor = [UIColor blackColor];
        box.userInteractionEnabled = NO;
        box.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [ow.rootViewController.view insertSubview:box atIndex:0];

        AVPlayerItem *item = [AVPlayerItem playerItemWithURL:[NSURL fileURLWithPath:videoPath]];
        gPlayer = [AVPlayer playerWithPlayerItem:item];
        gPlayer.actionAtItemEnd = AVPlayerActionAtItemEndPause;
        gPlayer.muted = YES;
        gEndObserver = [[NSNotificationCenter defaultCenter]
            addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
                        object:item
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
            CamHookStopPreview();
        }];
        gPlayerLayer = [AVPlayerLayer playerLayerWithPlayer:gPlayer];
        gPlayerLayer.frame = box.bounds;
        gPlayerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
        [box.layer addSublayer:gPlayerLayer];
        box.playerLayer = (AVPlayerLayer *)gPlayerLayer;
        gOverlay = box;
        [gPlayer play];
        CamLog("play once: %s", videoPath.UTF8String);
    });
}

static void CamHookShowImageOverlay(UIImage *image) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!image) return;
        if (gProvider) {
            VCamProviderDestroy(gProvider);
            gProvider = NULL;
        }
        UIWindow *ow = CamHookMakeOverlayWindow();
        if (!ow) return;
        UIImageView *iv = [[UIImageView alloc] initWithFrame:ow.bounds];
        iv.image = image;
        iv.contentMode = UIViewContentModeScaleAspectFill;
        iv.clipsToBounds = YES;
        iv.userInteractionEnabled = NO;
        iv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [ow.rootViewController.view insertSubview:iv atIndex:0];
        gOverlay = iv;
        CamLog("image overlay");
    });
}

static BOOL CamHookLoadVideoAtPath(NSString *path) {
    if (gProvider) {
        VCamProviderDestroy(gProvider);
        gProvider = NULL;
    }
    gProvider = VCamProviderCreate(path.UTF8String);
    if (gProvider && VCamProviderIsReady(gProvider)) {
        CamLog("load OK: %s", path.UTF8String);
        CamHookShowOverlay(path);
        return YES;
    }
    CamLog("load FAIL: %s", path.UTF8String);
    if (gProvider) {
        VCamProviderDestroy(gProvider);
        gProvider = NULL;
    }
    return NO;
}

@interface CamHookPickerDelegate : NSObject <PHPickerViewControllerDelegate>
@end
@implementation CamHookPickerDelegate
- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    gPickerShowing = NO;
    [picker dismissViewControllerAnimated:YES completion:^{
        CamHookRestoreCameraWindow();
    }];
    if (results.count == 0) {
        CamHookShowBanner("已取消");
        return;
    }
    NSItemProvider *prov = results.firstObject.itemProvider;
    if ([prov hasItemConformingToTypeIdentifier:@"public.movie"]) {
        [prov loadFileRepresentationForTypeIdentifier:@"public.movie"
                                    completionHandler:^(NSURL *url, NSError *error) {
            if (!url) {
                CamHookShowBanner("视频读取失败");
                return;
            }
            NSString *dst = CamHookTempVideoPath();
            NSFileManager *fm = [NSFileManager defaultManager];
            [fm removeItemAtPath:dst error:nil];
            if (![fm copyItemAtURL:url toURL:[NSURL fileURLWithPath:dst] error:nil]) {
                CamHookShowBanner("复制视频失败");
                return;
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                if (CamHookLoadVideoAtPath(dst)) CamHookShowBanner("只播一遍，点顶部红色停止");
                else CamHookShowBanner("视频解码失败");
            });
        }];
        return;
    }
    if ([prov canLoadObjectOfClass:[UIImage class]]) {
        [prov loadObjectOfClass:[UIImage class] completionHandler:^(id obj, NSError *error) {
            if (![obj isKindOfClass:[UIImage class]]) {
                CamHookShowBanner("照片读取失败");
                return;
            }
            CamHookShowImageOverlay((UIImage *)obj);
            CamHookShowBanner("正在显示照片，点顶部红色停止");
        }];
        return;
    }
    CamHookShowBanner("这个文件不能用");
}
@end
static CamHookPickerDelegate *gPickerDelegate = nil;

static void CamHookPresentPicker(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gPickerShowing) return;
        CamHookStopPreview();
        UIViewController *top = CamHookTopVC();
        if (!top || top.presentedViewController) {
            CamLog("present skipped top=%s presented=%s",
                   top ? NSStringFromClass(top.class).UTF8String : "nil",
                   top.presentedViewController ? NSStringFromClass(top.presentedViewController.class).UTF8String : "nil");
            return;
        }
        if (!gPickerDelegate) gPickerDelegate = [CamHookPickerDelegate new];
        PHPickerConfiguration *config = [[PHPickerConfiguration alloc] init];
        config.selectionLimit = 1;
        config.filter = nil;
        config.preferredAssetRepresentationMode = PHPickerConfigurationAssetRepresentationModeCurrent;
        PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:config];
        picker.delegate = gPickerDelegate;
        gPickerShowing = YES;
        [top presentViewController:picker animated:YES completion:nil];
        CamLog("picker presented");
    });
}

static CMSampleBufferRef CamHookCreateSampleBuffer(CVPixelBufferRef pb, CMTime pts, CMTime duration) {
    if (!pb) return NULL;
    CMVideoFormatDescriptionRef formatDesc = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pb, &formatDesc) != noErr || !formatDesc)
        return NULL;
    CMSampleTimingInfo timing = { .duration = duration, .presentationTimeStamp = pts, .decodeTimeStamp = kCMTimeInvalid };
    CMSampleBufferRef out = NULL;
    OSStatus st = CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pb, true, NULL, NULL, formatDesc, &timing, &out);
    CFRelease(formatDesc);
    return st == noErr ? out : NULL;
}

@interface CamHookProxy : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, weak) id<AVCaptureVideoDataOutputSampleBufferDelegate> realDelegate;
@end
@implementation CamHookProxy
- (void)captureOutput:(AVCaptureOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    if (!gProvider || !VCamProviderIsReady(gProvider)) {
        if ([self.realDelegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)])
            [self.realDelegate captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection];
        return;
    }
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    CMTime duration = CMSampleBufferGetDuration(sampleBuffer);
    if (CMTIME_IS_INVALID(duration) || CMTimeCompare(duration, kCMTimeZero) == 0)
        duration = CMTimeMake(1, 30);
    CVPixelBufferRef videoPB = VCamProviderCopyPixelBufferForTime(gProvider, pts);
    if (videoPB) {
        CMSampleBufferRef fake = CamHookCreateSampleBuffer(videoPB, pts, duration);
        CFRelease(videoPB);
        if (fake) {
            if ([self.realDelegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)])
                [self.realDelegate captureOutput:output didOutputSampleBuffer:fake fromConnection:connection];
            CFRelease(fake);
            return;
        }
    }
    if ([self.realDelegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)])
        [self.realDelegate captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection];
}
@end

%hook AVCaptureSession
- (void)startRunning {
    %orig;
    NSInteger gen = ++gGen;
    gPickerShowing = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        CamHookStopPreview();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (gen != gGen) return;
        gPickerShowing = NO;
        CamHookPresentPicker();
    });
}
- (void)stopRunning {
    gGen++;
    CamHookStopPreview();
    %orig;
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
    if (fp) { fprintf(fp, "=== CamHook red-stop + picker ===\n"); fclose(fp); }
    CamLog("loaded");
}
