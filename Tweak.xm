#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>

static UILabel *gLabel = nil;
static NSUInteger gPeakSetCount = 0;
static NSUInteger gResSetCount = 0;
static double gLastPeakSet = -1.0;
static CGSize gLastResSet = {-1.0, -1.0};
static NSString *gSubclasses = nil;
static __weak AVAsset *gVariantsAsset = nil;

%hook AVPlayerItem

- (void)setPreferredPeakBitRate:(double)rate {
    gPeakSetCount++;
    gLastPeakSet = rate;
    NSLog(@"[KickQualityLock] setPreferredPeakBitRate: %.0f", rate);
    %orig(rate);
}

- (void)setPreferredMaximumResolution:(CGSize)size {
    gResSetCount++;
    gLastResSet = size;
    NSLog(@"[KickQualityLock] setPreferredMaximumResolution: %.0fx%.0f", size.width, size.height);
    %orig(size);
}

%end

static NSArray<UIWindow *> *KQLWindows(void) {
    NSMutableArray *list = [NSMutableArray array];
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        if (scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            [list addObject:w];
        }
    }
    return list;
}

static UIWindow *KQLKeyWindow(void) {
    for (UIWindow *w in KQLWindows()) {
        if (w.isKeyWindow) return w;
    }
    return nil;
}

static AVPlayerLayer *KQLFindPlayerLayer(CALayer *layer, int depth) {
    if (!layer || depth > 60) return nil;
    if ([layer isKindOfClass:[AVPlayerLayer class]]) {
        AVPlayerLayer *pl = (AVPlayerLayer *)layer;
        if (pl.player) return pl;
    }
    for (CALayer *sub in [layer.sublayers copy]) {
        AVPlayerLayer *found = KQLFindPlayerLayer(sub, depth + 1);
        if (found) return found;
    }
    return nil;
}

static NSString *KQLFindSubclasses(void) {
    NSMutableArray *names = [NSMutableArray array];
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    Class avPlayer = [AVPlayer class];
    Class avItem = [AVPlayerItem class];
    for (unsigned int i = 0; i < count; i++) {
        Class c = classes[i];
        if (c == avPlayer || c == avItem) continue;
        const char *cname = class_getName(c);
        if (!cname) continue;
        if (strncmp(cname, "NSKVONotifying_", 15) == 0) continue;
        Class s = class_getSuperclass(c);
        int guard = 0;
        while (s && guard < 12) {
            if (s == avPlayer || s == avItem) {
                [names addObject:[NSString stringWithUTF8String:cname]];
                break;
            }
            s = class_getSuperclass(s);
            guard++;
        }
    }
    free(classes);
    [names sortUsingSelector:@selector(compare:)];
    if (names.count == 0) return @"none";
    NSUInteger n = MIN((NSUInteger)6, names.count);
    return [[names subarrayWithRange:NSMakeRange(0, n)] componentsJoinedByString:@"\n  "];
}

static NSString *KQLShort(NSString *s, NSUInteger max) {
    if (!s) return @"nil";
    if (s.length <= max) return s;
    return [[s substringToIndex:max] stringByAppendingString:@"..."];
}

static NSString *KQLBuildReport(void) {
    NSMutableString *out = [NSMutableString stringWithString:@"KQL v4"];

    if (!gSubclasses) gSubclasses = KQLFindSubclasses();

    AVPlayerLayer *pl = nil;
    for (UIWindow *w in KQLWindows()) {
        pl = KQLFindPlayerLayer(w.layer, 0);
        if (pl) break;
    }

    [out appendFormat:@"\nsetPeak calls: %lu last: %.0f", (unsigned long)gPeakSetCount, gLastPeakSet];
    [out appendFormat:@"\nsetRes calls: %lu last: %.0fx%.0f", (unsigned long)gResSetCount, gLastResSet.width, gLastResSet.height];
    [out appendFormat:@"\nAV subclasses:\n  %@", gSubclasses];

    if (!pl) {
        [out appendString:@"\nAVPlayerLayer: NOT FOUND"];
        return out;
    }

    AVPlayer *player = pl.player;
    AVPlayerItem *item = player.currentItem;
    [out appendFormat:@"\nplayer: %s rate: %.1f", class_getName([player class]), player.rate];

    if (!item) {
        [out appendString:@"\nitem: nil"];
        return out;
    }

    [out appendFormat:@"\nitem: %s", class_getName([item class])];

    AVAsset *asset = item.asset;
    if ([asset isKindOfClass:[AVURLAsset class]]) {
        NSString *u = ((AVURLAsset *)asset).URL.absoluteString;
        [out appendFormat:@"\nurl: %@", KQLShort(u, 90)];
    }

    CGSize cap = item.preferredMaximumResolution;
    CGSize pres = item.presentationSize;
    [out appendFormat:@"\ncap peak: %.0f  cap res: %.0fx%.0f", item.preferredPeakBitRate, cap.width, cap.height];
    [out appendFormat:@"\nplaying res: %.0fx%.0f", pres.width, pres.height];

    AVPlayerItemAccessLogEvent *ev = item.accessLog.events.lastObject;
    if (ev) {
        [out appendFormat:@"\nindicated: %.0f observed: %.0f switch: %.0f",
            ev.indicatedBitrate, ev.observedBitrate, ev.switchBitrate];
    } else {
        [out appendString:@"\naccessLog: empty"];
    }

    if (asset) {
        NSError *err = nil;
        AVKeyValueStatus st = [asset statusOfValueForKey:@"variants" error:&err];
        if (st == AVKeyValueStatusLoaded) {
            NSArray *vs = nil;
            @try {
                vs = [asset valueForKey:@"variants"];
            } @catch (NSException *e) {
                vs = nil;
            }
            [out appendFormat:@"\nvariants: %lu", (unsigned long)vs.count];
            NSUInteger shown = 0;
            for (id v in vs) {
                if (shown >= 8) break;
                double peak = 0.0;
                CGSize s = CGSizeZero;
                @try {
                    id va = [v valueForKey:@"videoAttributes"];
                    if (va) {
                        id sv = [va valueForKey:@"presentationSize"];
                        if ([sv isKindOfClass:[NSValue class]]) {
                            s = [(NSValue *)sv CGSizeValue];
                        }
                    }
                    peak = [[v valueForKey:@"peakBitRate"] doubleValue];
                } @catch (NSException *e) {
                }
                [out appendFormat:@"\n  %.0fx%.0f @ %.0f", s.width, s.height, peak];
                shown++;
            }
        } else if (gVariantsAsset != asset) {
            gVariantsAsset = asset;
            [asset loadValuesAsynchronouslyForKeys:@[@"variants"] completionHandler:^{}];
            [out appendString:@"\nvariants: loading"];
        } else {
            [out appendFormat:@"\nvariants status: %ld", (long)st];
        }
    }
    return out;
}

static void KQLUpdateOverlay(void) {
    @try {
        UIWindow *win = KQLKeyWindow();
        if (!win) return;
        CGFloat w = win.bounds.size.width - 16.0;
        if (!gLabel) {
            gLabel = [[UILabel alloc] initWithFrame:CGRectMake(8, 60, w, 300)];
            gLabel.numberOfLines = 0;
            gLabel.font = [UIFont monospacedSystemFontOfSize:9 weight:UIFontWeightMedium];
            gLabel.textColor = [UIColor greenColor];
            gLabel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.8];
            gLabel.userInteractionEnabled = NO;
            gLabel.layer.cornerRadius = 6;
            gLabel.clipsToBounds = YES;
        }
        if (gLabel.superview != win) {
            [gLabel removeFromSuperview];
            [win addSubview:gLabel];
        }
        [win bringSubviewToFront:gLabel];
        gLabel.text = KQLBuildReport();
        CGSize s = [gLabel sizeThatFits:CGSizeMake(w, 2000)];
        gLabel.frame = CGRectMake(8, 60, w, MIN(s.height, 560));
    } @catch (NSException *e) {
        NSLog(@"[KickQualityLock] overlay error: %@", e);
    }
}

%ctor {
    @autoreleasepool {
        NSOperatingSystemVersion v = [[NSProcessInfo processInfo] operatingSystemVersion];
        NSLog(@"[KickQualityLock] loaded on iOS %ld.%ld", (long)v.majorVersion, (long)v.minorVersion);
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *t) {
            KQLUpdateOverlay();
        }];
    });
}
