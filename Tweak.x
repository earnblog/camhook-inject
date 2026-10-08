// CamHook —— 停止后可以换一张
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
static NSInteger gReselectGen = 0;
static AVPlayer *gPlayer = NULL;
static AVPlayerLayer *gPlayerLayer = NULL;
static UIView *gOverlay = NULL;
static UIWindow *gOverlayWindow = nil;
static UIWindow *gReselectWindow = nil;
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

static void CamHookStopPreview(void);
static void CamHookShowReselectButton(void);
static void CamHookHideReselectButton(void);
static void CamHookPresentPicker(void);

static UIWindowScene *CamHookScene(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) return (UIWindowScene *)scene;
    }
    return nil;
}

static BOOL CamHookIsOurWindow(UIWindow *w) {
    return w == gOverlayWindow || w == gReselectWindow;
}

static void CamHookRestoreCameraWindow(void) {
    UIWindow *best = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (CamHookIsOurWindow(w) || w.hidden) continue;
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
            if (CamHookIsOurWindow(w) || w.hidden) continue;
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
                    if (!w.hidden && !CamHookIsOurWindow(w)) { win = w; break; }
                }
            }
        }
        if (!win) return;
        CGFloat width = win.bounds.size.width - 24.0;
        CGFloat topY = win.safeAreaInsets.top > 20 ? win.safeAreaInsets.top + 58 : 108;
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

static void CamHookHideReselectButton(void) {
    gReselectWindow.hidden = YES;
    gReselectWindow = nil;
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
- (void)onStop:(id)sender {
    CamHookStopPreview();
    CamHookShowReselectButton();
}
- (void)onReselect:(id)sender {
    NSInteger token = ++gReselectGen;
    CamHookHideReselectButton();
    CamHookStopPreview();
    gPickerShowing = NO;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (token != gReselectGen) return;
        CamHookPresentPicker();
    });
}
@end
static CamHookStopTarget *gStopTarget = nil;

static void CamHookShowReselectButton(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ CamHookShowReselectButton(); });
        return;
    }
    if (gOverlayWindow || gPickerShowing) return;
    CamHookHideReselectButton();
    UIWindowScene *scene = CamHookScene();
    if (!scene) return;
    if (!gStopTarget) gStopTarget = [CamHookStopTarget new];

    CGRect bounds = scene.coordinateSpace.bounds;
    CGFloat top = 48;
    for (UIWindow *w in scene.windows) {
        if (CamHookIsOurWindow(w) || w.hidden) continue;
        if (w.safeAreaInsets.top > 20) { top = w.safeAreaInsets.top; break; }
    }
    UIWindow *w = [[UIWindow alloc] initWithWindowScene:scene];
    w.frame = CGRectMake((bounds.size.width - 120.0) / 2.0, top + 8.0, 120.0, 40.0);
    w.windowLevel = UIWindowLevelAlert + 2.0;
    w.backgroundColor = [UIColor clearColor];
    UIViewController *root = [UIViewController new];
    root.view.backgroundColor = [UIColor clearColor];
    w.rootViewController = root;

    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = root.view.bounds;
    b.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    b.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.82];
    b.layer.cornerRadius = 20.0;
    b.clipsToBounds = YES;
    [b setTitle:@"换一个" forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:16.0];
    [b addTarget:gStopTarget action:@selector(onReselect:) forControlEvents:UIControlEventTouchUpInside];
    [root.view addSubview:b];
    w.hidden = NO;
    gReselectWindow = w;
    CamLog("reselect button");
}

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
    CamHookHideReselectButton();
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

    UIButton *swap = [UIButton buttonWithType:UIButtonTypeSystem];
    swap.translatesAutoresizingMaskIntoConstraints = NO;
    swap.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.82];
    swap.layer.cornerRadius = 22.0;
    swap.clipsToBounds = YES;
    [swap setTitle:@"换一个" forState:UIControlStateNormal];
    [swap setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    swap.titleLabel.font = [UIFont boldSystemFontOfSize:18.0];
    [swap addTarget:gStopTarget action:@selector(onReselect:) forControlEvents:UIControlEventTouchUpInside];

    [root.view addSubview:stop];
    [root.view addSubview:swap];
    [NSLayoutConstraint activateConstraints:@[
        [stop.topAnchor constraintEqualToAnchor:root.view.safeAreaLayoutGuide.topAnchor constant:8],
        [stop.trailingAnchor constraintEqualToAnchor:root.view.centerXAnchor constant:-6],
        [stop.widthAnchor constraintEqualToConstant:110],
        [stop.heightAnchor constraintEqualToConstant:44],
        [swap.topAnchor constraintEqualToAnchor:stop.topAnchor],
        [swap.leadingAnchor constraintEqualToAnchor:root.view.centerXAnchor constant:6],
        [swap.widthAnchor constraintEqualToConstant:110],
        [swap.heightAnchor constraintEqualToConstant:44],
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
            CamHookShowReselectButton();
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
        CamHookShowReselectButton();
        CamHookShowBanner("已取消，点「换一个」再选");
        return;
    }
    NSItemProvider *prov = results.firstObject.itemProvider;
    if ([prov hasItemConformingToTypeIdentifier:@"public.movie"]) {
        [prov loadFileRepresentationForTypeIdentifier:@"public.movie"
                                    completionHandler:^(NSURL *url, NSError *error) {
            if (!url) {
                CamHookShowBanner("视频读取失败");
                CamHookShowReselectButton();
                return;
            }
            NSString *dst = CamHookTempVideoPath();
            NSFileManager *fm = [NSFileManager defaultManager];
            [fm removeItemAtPath:dst error:nil];
            if (![fm copyItemAtURL:url toURL:[NSURL fileURLWithPath:dst] error:nil]) {
                CamHookShowBanner("复制视频失败");
                CamHookShowReselectButton();
                return;
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                if (CamHookLoadVideoAtPath(dst)) CamHookShowBanner("只播一遍，可点「换一个」");
                else {
                    CamHookShowBanner("视频解码失败");
                    CamHookShowReselectButton();
                }
            });
        }];
        return;
    }
    if ([prov canLoadObjectOfClass:[UIImage class]]) {
        [prov loadObjectOfClass:[UIImage class] completionHandler:^(id obj, NSError *error) {
            if (![obj isKindOfClass:[UIImage class]]) {
                CamHookShowBanner("照片读取失败");
                CamHookShowReselectButton();
                return;
            }
            CamHookShowImageOverlay((UIImage *)obj);
            CamHookShowBanner("正在显示照片，可点「换一个」");
        }];
        return;
    }
    CamHookShowBanner("这个文件不能用");
    CamHookShowReselectButton();
}
@end
static CamHookPickerDelegate *gPickerDelegate = nil;

static void CamHookPresentPickerAttempt(int tries) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gPickerShowing) return;
        CamHookHideReselectButton();
        CamHookStopPreview();
        UIViewController *top = CamHookTopVC();
        if ((!top || top.presentedViewController) && tries > 0) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                CamHookPresentPickerAttempt(tries - 1);
            });
            return;
        }
        if (!top || top.presentedViewController) {
            CamHookShowReselectButton();
            CamHookShowBanner("没能打开相册，点「换一个」再试");
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

static void CamHookPresentPicker(void) {
    CamHookPresentPickerAttempt(4);
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
    AVCaptureSession *session = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (gen != gGen) return;
        if (!session.isRunning) return;
        gPickerShowing = NO;
        CamHookPresentPicker();
    });
}
- (void)stopRunning {
    gGen++;
    gReselectGen++;
    CamHookHideReselectButton();
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
    if (fp) { fprintf(fp, "=== CamHook reselect ===\n"); fclose(fp); }
    CamLog("loaded");
}
