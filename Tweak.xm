#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreGraphics/CoreGraphics.h>

static double gLastPeak = 0.0;
static CGSize gLastRes = {0.0, 0.0};
static __weak AVPlayer *gPlayer = nil;
static UILabel *gLabel = nil;

static void KQLApplyToItem(AVPlayerItem *item) {
    if (!item) return;
    @try {
        if (gLastPeak > 0.0 && item.preferredPeakBitRate <= 0.0) {
            item.preferredPeakBitRate = gLastPeak;
        }
        if (gLastRes.width > 0.0 && gLastRes.height > 0.0) {
            CGSize cur = item.preferredMaximumResolution;
            if (cur.width <= 0.0 || cur.height <= 0.0) {
                item.preferredMaximumResolution = gLastRes;
            }
        }
    } @catch (NSException *e) {
        NSLog(@"[KickQualityLock] apply error: %@", e);
    }
}

static UIWindow *KQLKeyWindow(void) {
    UIWindow *result = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        if (scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (w.isKeyWindow) { result = w; break; }
        }
        if (result) break;
    }
    return result;
}

static void KQLUpdateOverlay(void) {
    @try {
        UIWindow *win = KQLKeyWindow();
        if (!win) return;
        if (!gLabel) {
            gLabel = [[UILabel alloc] initWithFrame:CGRectMake(8, 60, 300, 130)];
            gLabel.numberOfLines = 0;
            gLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightMedium];
            gLabel.textColor = [UIColor greenColor];
            gLabel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.7];
            gLabel.userInteractionEnabled = NO;
            gLabel.layer.cornerRadius = 6;
            gLabel.clipsToBounds = YES;
        }
        if (gLabel.superview != win) {
            [gLabel removeFromSuperview];
            [win addSubview:gLabel];
        }
        [win bringSubviewToFront:gLabel];

        AVPlayer *p = gPlayer;
        AVPlayerItem *item = p.currentItem;
        if (!item) {
            gLabel.text = @"KQL: no AVPlayer item";
            return;
        }
        CGSize cap = item.preferredMaximumResolution;
        CGSize pres = item.presentationSize;
        AVPlayerItemAccessLogEvent *ev = item.accessLog.events.lastObject;
        gLabel.text = [NSString stringWithFormat:
            @"KQL v2\ncap peak: %.0f\ncap res: %.0fx%.0f\nplaying res: %.0fx%.0f\nindicated: %.0f\nobserved: %.0f\nswitch: %.0f\nswitches: %ld",
            item.preferredPeakBitRate, cap.width, cap.height,
            pres.width, pres.height,
            ev ? ev.indicatedBitrate : 0.0,
            ev ? ev.observedBitrate : 0.0,
            ev ? ev.switchBitrate : 0.0,
            (long)(ev ? ev.numberOfMediaRequests : 0)];
    } @catch (NSException *e) {
        NSLog(@"[KickQualityLock] overlay error: %@", e);
    }
}

%hook AVPlayerItem

- (void)setPreferredPeakBitRate:(double)rate {
    if (rate > 0.0) {
        gLastPeak = rate;
        NSLog(@"[KickQualityLock] app set peak bitrate: %.0f", rate);
        %orig(rate);
    } else if (gLastPeak > 0.0) {
        %orig(gLastPeak);
    } else {
        %orig(rate);
    }
}

- (void)setPreferredMaximumResolution:(CGSize)size {
    if (size.width > 0.0 && size.height > 0.0) {
        gLastRes = size;
        NSLog(@"[KickQualityLock] app set max resolution: %.0fx%.0f", size.width, size.height);
        %orig(size);
    } else if (gLastRes.width > 0.0 && gLastRes.height > 0.0) {
        %orig(gLastRes);
    } else {
        %orig(size);
    }
}

%end

%hook AVPlayer

- (void)replaceCurrentItemWithItem:(AVPlayerItem *)item {
    gPlayer = self;
    KQLApplyToItem(item);
    %orig(item);
}

- (instancetype)initWithPlayerItem:(AVPlayerItem *)item {
    KQLApplyToItem(item);
    AVPlayer *p = %orig(item);
    gPlayer = p;
    return p;
}

- (instancetype)initWithURL:(NSURL *)url {
    AVPlayer *p = %orig(url);
    gPlayer = p;
    return p;
}

%end

%ctor {
    @autoreleasepool {
        NSOperatingSystemVersion v = [[NSProcessInfo processInfo] operatingSystemVersion];
        NSLog(@"[KickQualityLock] loaded on iOS %ld.%ld", (long)v.majorVersion, (long)v.minorVersion);
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
            KQLUpdateOverlay();
        }];
    });
}
