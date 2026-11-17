#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>

static NSString *const kKQLSavedKey = @"KQLSavedHeight";

static UILabel *gLabel = nil;
static NSUInteger gResSetCount = 0;
static NSUInteger gResetCount = 0;
static CGSize gLastResSet = {0.0, 0.0};
static int gSavedHeight = 0;
static NSUInteger gChunkCount = 0;
static NSUInteger gMasterCount = 0;
static NSUInteger gModifiedCount = 0;
static int gKeptHeight = 0;

static int KQLHeightFromInf(NSString *line) {
    NSRange r = [line rangeOfString:@"RESOLUTION="];
    if (r.location == NSNotFound) return 0;
    NSUInteger i = r.location + r.length;
    NSUInteger n = line.length;
    while (i < n) {
        unichar c = [line characterAtIndex:i];
        if (c < '0' || c > '9') break;
        i++;
    }
    if (i >= n || [line characterAtIndex:i] != 'x') return 0;
    i++;
    int h = 0;
    while (i < n) {
        unichar c = [line characterAtIndex:i];
        if (c < '0' || c > '9') break;
        h = h * 10 + (int)(c - '0');
        i++;
    }
    return h;
}

static NSData *KQLRewriteMaster(NSData *data) {
    if (!data || data.length < 20) return data;
    gChunkCount++;

    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!text) return data;
    if (![text hasPrefix:@"#EXTM3U"]) return data;
    if ([text rangeOfString:@"#EXT-X-STREAM-INF"].location == NSNotFound) return data;
    gMasterCount++;

    int targetH = gSavedHeight;
    if (targetH <= 0) return data;

    NSArray<NSString *> *lines = [text componentsSeparatedByString:@"\n"];
    NSUInteger total = lines.count;

    NSMutableArray<NSNumber *> *infIdx = [NSMutableArray array];
    NSMutableArray<NSNumber *> *uriIdx = [NSMutableArray array];
    NSMutableArray<NSNumber *> *heights = [NSMutableArray array];

    for (NSUInteger i = 0; i < total; i++) {
        NSString *line = [lines[i] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (![line hasPrefix:@"#EXT-X-STREAM-INF:"]) continue;
        NSUInteger j = i + 1;
        NSInteger found = -1;
        while (j < total) {
            NSString *next = [lines[j] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (next.length > 0 && ![next hasPrefix:@"#"]) {
                found = (NSInteger)j;
                break;
            }
            if ([next hasPrefix:@"#EXT-X-STREAM-INF:"]) break;
            j++;
        }
        if (found < 0) continue;
        [infIdx addObject:@(i)];
        [uriIdx addObject:@(found)];
        [heights addObject:@(KQLHeightFromInf(line))];
    }

    if (infIdx.count < 2) return data;

    int best = 0;
    for (NSNumber *h in heights) {
        int v = h.intValue;
        if (v > 0 && v <= targetH && v > best) best = v;
    }
    if (best == 0) return data;

    NSMutableIndexSet *remove = [NSMutableIndexSet indexSet];
    for (NSUInteger k = 0; k < infIdx.count; k++) {
        if (heights[k].intValue != best) {
            [remove addIndex:infIdx[k].unsignedIntegerValue];
            [remove addIndex:uriIdx[k].unsignedIntegerValue];
        }
    }
    if (remove.count == 0) return data;

    NSMutableArray<NSString *> *kept = [NSMutableArray arrayWithCapacity:total];
    for (NSUInteger i = 0; i < total; i++) {
        if (![remove containsIndex:i]) [kept addObject:lines[i]];
    }
    NSString *joined = [kept componentsJoinedByString:@"\n"];
    NSMutableData *outData = [[joined dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    if (!outData || outData.length > data.length) return data;

    NSUInteger pad = data.length - outData.length;
    if (pad > 0) {
        NSMutableData *fill = [NSMutableData dataWithLength:pad];
        memset(fill.mutableBytes, '\n', pad);
        [outData appendData:fill];
    }

    gModifiedCount++;
    gKeptHeight = best;
    NSLog(@"[KickQualityLock] master playlist rewritten, kept %dp (saved %dp)", best, targetH);
    return outData;
}

%hook AVAssetResourceLoadingDataRequest

- (void)respondWithData:(NSData *)data {
    NSData *out = data;
    @try {
        out = KQLRewriteMaster(data);
    } @catch (NSException *e) {
        out = data;
    }
    %orig(out);
}

%end

%hook AVPlayerItem

- (void)setPreferredMaximumResolution:(CGSize)size {
    gResSetCount++;
    int h = (int)size.height;
    if (h >= 100 && h <= 1080) {
        gLastResSet = size;
        gSavedHeight = h;
        [[NSUserDefaults standardUserDefaults] setInteger:h forKey:kKQLSavedKey];
        NSLog(@"[KickQualityLock] saved quality %dp", h);
    } else {
        gResetCount++;
        NSLog(@"[KickQualityLock] ignored resolution cap %.0fx%.0f", size.width, size.height);
    }
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

static NSString *KQLBuildReport(void) {
    NSMutableString *out = [NSMutableString stringWithString:@"KQL v6"];
    [out appendFormat:@"\nsaved: %dp  setRes: %lu  ignored: %lu",
        gSavedHeight, (unsigned long)gResSetCount, (unsigned long)gResetCount];
    [out appendFormat:@"\nplaylist chunks: %lu master: %lu",
        (unsigned long)gChunkCount, (unsigned long)gMasterCount];
    [out appendFormat:@"\nmodified: %lu kept: %dp",
        (unsigned long)gModifiedCount, gKeptHeight];

    AVPlayerLayer *pl = nil;
    for (UIWindow *w in KQLWindows()) {
        pl = KQLFindPlayerLayer(w.layer, 0);
        if (pl) break;
    }
    if (!pl) {
        [out appendString:@"\nAVPlayerLayer: NOT FOUND"];
        return out;
    }
    AVPlayerItem *item = pl.player.currentItem;
    if (!item) {
        [out appendString:@"\nitem: nil"];
        return out;
    }
    CGSize cap = item.preferredMaximumResolution;
    CGSize pres = item.presentationSize;
    [out appendFormat:@"\ncap res: %.0fx%.0f", cap.width, cap.height];
    [out appendFormat:@"\nplaying res: %.0fx%.0f", pres.width, pres.height];
    AVPlayerItemAccessLogEvent *ev = item.accessLog.events.lastObject;
    if (ev) {
        [out appendFormat:@"\nindicated: %.0f observed: %.0f",
            ev.indicatedBitrate, ev.observedBitrate];
    } else {
        [out appendString:@"\naccessLog: empty"];
    }
    return out;
}

static void KQLUpdateOverlay(void) {
    @try {
        UIWindow *win = KQLKeyWindow();
        if (!win) return;
        CGFloat w = win.bounds.size.width - 16.0;
        if (!gLabel) {
            gLabel = [[UILabel alloc] initWithFrame:CGRectMake(8, 60, w, 150)];
            gLabel.numberOfLines = 0;
            gLabel.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightMedium];
            gLabel.textColor = [UIColor greenColor];
            gLabel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.75];
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
        CGSize s = [gLabel sizeThatFits:CGSizeMake(w, 1000)];
        gLabel.frame = CGRectMake(8, 60, w, MIN(s.height, 300));
    } @catch (NSException *e) {
        NSLog(@"[KickQualityLock] overlay error: %@", e);
    }
}

%ctor {
    @autoreleasepool {
        NSOperatingSystemVersion v = [[NSProcessInfo processInfo] operatingSystemVersion];
        NSLog(@"[KickQualityLock] loaded on iOS %ld.%ld", (long)v.majorVersion, (long)v.minorVersion);
        gSavedHeight = (int)[[NSUserDefaults standardUserDefaults] integerForKey:kKQLSavedKey];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *t) {
            KQLUpdateOverlay();
        }];
    });
}
