// CamHook —— 选视频或照片盖住预览，可停止，视频不循环
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <Photos/Photos.h>
#import <objc/runtime.h>
#import <stdio.h>
#import <time.h>
#import <stdarg.h>
#import "VCamProvider.h"

static VCamProvider *gProvider = NULL;
static NSTimeInterval gLastBanner = 0;
static BOOL gPickerShowing = NO;
static AVPlayer *gPlayer = NULL;
static AVPlayerLayer *gPlayerLayer = NULL;
static UIView *gOverlay = NULL;
static UIWindow *gOverlayWindow = nil;
static UIButton *gStopButton = nil;
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

static UIWindow *CamHookKeyWindow(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (w.isKeyWindow) return w;
            }
        }
    }
    return nil;
}

static void CamHookShowBanner(const char *msg) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        if (now - gLastBanner < 2.5) return;
        gLastBanner = now;
        UIWindow *win = (gOverlayWindow && !gOverlayWindow.hidden) ? gOverlayWindow : CamHookKeyWindow();
        if (!win) return;
        CGFloat width = win.bounds.size.width - 24.0;
        CGFloat topY = win.safeAreaInsets.top > 0 ? win.safeAreaInsets.top : 44.0;
        UIView *banner = [[UIView alloc] initWithFrame:CGRectMake(12, topY + 8, width, 60)];
        banner.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.88];
        banner.layer.cornerRadius = 14.0;
        banner.clipsToBounds = YES;
        banner.userInteractionEnabled = NO;
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(14, 0, width - 28, 60)];
        label.text = [NSString stringWithUTF8String:msg];
        label.textColor = [UIColor whiteColor];
        label.font = [UIFont boldSystemFontOfSize:14.0];
        label.numberOfLines = 2;
        [banner addSubview:label];
        [win addSubview:banner];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [banner removeFromSuperview];
        });
    });
}

static NSString *CamHookTempVideoPath(void) {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:@"camhook_selected.mp4"];
}

static UIViewController *CamHookTopVC(void) {
    UIWindow *win = CamHookKeyWindow();
    if (!win) return nil;
    UIViewController *vc = win.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

@interface CamHookPassWindow : UIWindow
@end
@implementation CamHookPassWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *target = gStopButton;
    if (!target || target.hidden) return nil;
    CGPoint p = [target convertPoint:point fromView:self];
    if (![target pointInside:p withEvent:event]) return nil;
    return [target hitTest:p withEvent:event] ?: target;
}
@end

@interface CamHookOverlayView : UIView
@property (nonatomic, strong) AVPlayerLayer *playerLayer;
@end
@implementation CamHookOverlayView
- (void)layoutSubviews {
    [super layoutSubviews];
    self.playerLayer.frame = self.bounds;
}
@end

static void CamHookTearDownOverlay(void) {
    if (gEndObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:gEndObserver];
        gEndObserver = nil;
    }
    if (gPlayer) { [gPlayer pause]; gPlayer = nil; }
    gPlayerLayer = nil;
    gOverlay = nil;
    gStopButton = nil;
    gOverlayWindow.hidden = YES;
    gOverlayWindow = nil;
}

static void CamHookStopPreview(void) {
    if (gProvider) {
        VCamProviderDestroy(gProvider);
        gProvider = NULL;
    }
    if ([NSThread isMainThread]) CamHookTearDownOverlay();
    else dispatch_async(dispatch_get_main_queue(), ^{ CamHookTearDownOverlay(); });
}

static void CamHookRemoveOverlay(void) {
    CamHookStopPreview();
}

static CamHookPassWindow *CamHookMakeOverlayWindow(void) {
    UIWindow *key = CamHookKeyWindow();
    if (!key) return nil;
    CamHookTearDownOverlay();

    CamHookPassWindow *ow = [[CamHookPassWindow alloc] initWithWindowScene:key.windowScene];
    ow.frame = key.bounds;
    ow.windowLevel = UIWindowLevelAlert + 1.0;
    ow.backgroundColor = [UIColor blackColor];
    UIViewController *root = [UIViewController new];
    root.view.backgroundColor = [UIColor blackColor];
    ow.rootViewController = root;
    ow.hidden = NO;

    CGFloat bottom = key.safeAreaInsets.bottom > 0 ? key.safeAreaInsets.bottom : 20.0;
    UIButton *stop = [UIButton buttonWithType:UIButtonTypeSystem];
    stop.frame = CGRectMake((key.bounds.size.width - 120.0) / 2.0,
                            key.bounds.size.height - bottom - 64.0,
                            120.0, 44.0);
    stop.autoresizingMask = UIViewAutoresizingFlexibleTopMargin |
                            UIViewAutoresizingFlexibleLeftMargin |
                            UIViewAutoresizingFlexibleRightMargin;
    stop.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.72];
    stop.layer.cornerRadius = 22.0;
    stop.clipsToBounds = YES;
    [stop setTitle:@"停止" forState:UIControlStateNormal];
    [stop setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    stop.titleLabel.font = [UIFont boldSystemFontOfSize:17.0];
    [stop addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
        CamHookStopPreview();
    }] forControlEvents:UIControlEventTouchUpInside];
    [root.view addSubview:stop];
    gStopButton = stop;
    gOverlayWindow = ow;
    return ow;
}

static void CamHookShowOverlay(NSString *videoPath) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (videoPath.length == 0) return;
        CamHookPassWindow *ow = CamHookMakeOverlayWindow();
        if (!ow) return;

        CamHookOverlayView *box = [[CamHookOverlayView alloc] initWithFrame:ow.bounds];
        box.backgroundColor = [UIColor blackColor];
        box.userInteractionEnabled = NO;
        box.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [ow.rootViewController.view insertSubview:box atIndex:0];

        AVPlayerItem *item = [AVPlayerItem playerItemWithURL:[NSURL fileURLWithPath:videoPath]];
        gPlayer = [AVPlayer playerWithPlayerItem:item];
        gPlayer.muted = YES;
        gPlayer.actionAtItemEnd = AVPlayerActionAtItemEndPause;
        gEndObserver = [[NSNotificationCenter defaultCenter]
            addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
                        object:item
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
            dispatch_async(dispatch_get_main_queue(), ^{
                CamHookStopPreview();
            });
        }];
        gPlayerLayer = [AVPlayerLayer playerLayerWithPlayer:gPlayer];
        gPlayerLayer.frame = box.bounds;
        gPlayerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
        [box.layer addSublayer:gPlayerLayer];
        box.playerLayer = (AVPlayerLayer *)gPlayerLayer;
        gOverlay = box;
        [gPlayer play];
        CamLog("overlay window up: %s", videoPath.UTF8String);
    });
}

static void CamHookShowImageOverlay(UIImage *image) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!image) return;
        if (gProvider) {
            VCamProviderDestroy(gProvider);
            gProvider = NULL;
        }
        CamHookPassWindow *ow = CamHookMakeOverlayWindow();
        if (!ow) return;
        UIImageView *iv = [[UIImageView alloc] initWithFrame:ow.bounds];
        iv.image = image;
        iv.contentMode = UIViewContentModeScaleAspectFill;
        iv.clipsToBounds = YES;
        iv.userInteractionEnabled = NO;
        iv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [ow.rootViewController.view insertSubview:iv atIndex:0];
        gOverlay = iv;
        CamLog("image overlay up");
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

@interface CamHookPickerDelegate : NSObject <UIImagePickerControllerDelegate, UINavigationControllerDelegate>
@end
@implementation CamHookPickerDelegate
- (void)imagePickerController:(UIImagePickerController *)picker
didFinishPickingMediaWithInfo:(NSDictionary *)info {
    gPickerShowing = NO;
    NSString *type = info[UIImagePickerControllerMediaType];
    UIImage *image = nil;
    NSURL *url = info[UIImagePickerControllerMediaURL];
    if ([type isEqualToString:@"public.image"]) {
        image = info[UIImagePickerControllerOriginalImage];
        if (!image) {
            NSURL *imageURL = info[UIImagePickerControllerImageURL];
            if (imageURL) image = [UIImage imageWithContentsOfFile:imageURL.path];
        }
    }
    [picker dismissViewControllerAnimated:YES completion:^{
        if (image) {
            CamHookShowImageOverlay(image);
            CamHookShowBanner("✓ CamHook 预览已切换\n正在显示所选照片");
            return;
        }
        if (!url) {
            CamHookShowBanner("✓ CamHook\n未获取到文件");
            return;
        }
        NSString *dst = CamHookTempVideoPath();
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm removeItemAtPath:dst error:nil];
        NSError *err = nil;
        BOOL ok = [fm copyItemAtPath:url.path toPath:dst error:&err];
        if (!ok) {
            NSData *data = [NSData dataWithContentsOfURL:url];
            ok = [data writeToFile:dst atomically:YES];
        }
        if (!ok) {
            CamHookShowBanner("✓ CamHook\n复制视频失败");
            return;
        }
        if (CamHookLoadVideoAtPath(dst)) {
            CamHookShowBanner("✓ CamHook 预览已切换\n播放中，点停止可结束");
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

static void CamHookPresentPicker(void) {
    if (gPickerShowing) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = CamHookTopVC();
        if (!top) {
            CamHookShowBanner("✓ CamHook\n无法弹出选择器");
            return;
        }
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
        picker.mediaTypes = @[@"public.movie", @"public.image"];
        picker.delegate = gPickerDelegate;
        gPickerShowing = YES;
        [top presentViewController:picker animated:YES completion:nil];
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
    CamLog("startRunning");
    CamHookShowBanner("✓ CamHook\n请选择视频或照片…");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        CamHookPresentPicker();
    });
}
- (void)stopRunning {
    CamHookRemoveOverlay();
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
    if (fp) { fprintf(fp, "=== CamHook stop + photo ===\n"); fclose(fp); }
    CamLog("loaded");
}
