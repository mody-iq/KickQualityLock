#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

static NSString *const kKQLModeKey = @"KQLModeIndex";
static const int kKQLHeights[4] = {1080, 720, 480, 0};
static NSString *const kKQLTitles[4] = {@"1080p", @"720p", @"480p", @"OFF"};

static NSInteger gModeIndex = 0;
static UIButton *gButton = nil;
static id gHelper = nil;

static void KQLRefreshTitle(void) {
    if (!gButton) return;
    NSInteger i = gModeIndex;
    if (i < 0 || i > 3) i = 0;
    [gButton setTitle:kKQLTitles[i] forState:UIControlStateNormal];
    UIColor *c = (kKQLHeights[i] == 0) ? [UIColor lightGrayColor] : [UIColor greenColor];
    [gButton setTitleColor:c forState:UIControlStateNormal];
    gButton.layer.borderColor = c.CGColor;
}

@interface KQLHelper : NSObject
- (void)onTap:(UIButton *)sender;
- (void)onPan:(UIPanGestureRecognizer *)pan;
@end

@implementation KQLHelper

- (void)onTap:(UIButton *)sender {
    gModeIndex = (gModeIndex + 1) % 4;
    [[NSUserDefaults standardUserDefaults] setInteger:gModeIndex forKey:kKQLModeKey];
    KQLRefreshTitle();
    NSLog(@"[KickQualityLock] mode changed to %@", kKQLTitles[gModeIndex]);
}

- (void)onPan:(UIPanGestureRecognizer *)pan {
    UIView *v = pan.view;
    UIView *sup = v.superview;
    if (!v || !sup) return;
    CGPoint t = [pan translationInView:sup];
    CGFloat hw = v.bounds.size.width / 2.0;
    CGFloat hh = v.bounds.size.height / 2.0;
    CGPoint c = CGPointMake(v.center.x + t.x, v.center.y + t.y);
    c.x = MAX(hw, MIN(sup.bounds.size.width - hw, c.x));
    c.y = MAX(hh + 40.0, MIN(sup.bounds.size.height - hh, c.y));
    v.center = c;
    [pan setTranslation:CGPointZero inView:sup];
}

@end

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

    NSInteger mode = gModeIndex;
    if (mode < 0 || mode > 3) mode = 0;
    int targetH = kKQLHeights[mode];
    if (targetH <= 0) return data;

    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!text) return data;
    if (![text hasPrefix:@"#EXTM3U"]) return data;
    if ([text rangeOfString:@"#EXT-X-STREAM-INF"].location == NSNotFound) return data;

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

    NSLog(@"[KickQualityLock] master playlist rewritten, kept %dp (target %dp)", best, targetH);
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

static UIWindow *KQLKeyWindow(void) {
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        if (scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (w.isKeyWindow) return w;
        }
    }
    return nil;
}

static void KQLTick(void) {
    @try {
        UIWindow *win = KQLKeyWindow();
        if (!win) return;
        if (!gHelper) gHelper = [[KQLHelper alloc] init];
        if (!gButton) {
            gButton = [UIButton buttonWithType:UIButtonTypeCustom];
            gButton.frame = CGRectMake(8.0, 275.0, 56.0, 26.0);
            gButton.titleLabel.font = [UIFont boldSystemFontOfSize:12.0];
            gButton.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.6];
            gButton.layer.cornerRadius = 8.0;
            gButton.layer.borderWidth = 1.0;
            gButton.clipsToBounds = YES;
            [gButton addTarget:gHelper action:@selector(onTap:) forControlEvents:UIControlEventTouchUpInside];
            UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:gHelper action:@selector(onPan:)];
            [gButton addGestureRecognizer:pan];
        }
        if (gButton.superview != win) {
            [gButton removeFromSuperview];
            [win addSubview:gButton];
        }
        [win bringSubviewToFront:gButton];
        KQLRefreshTitle();
    } @catch (NSException *e) {
        NSLog(@"[KickQualityLock] button error: %@", e);
    }
}

%ctor {
    @autoreleasepool {
        NSOperatingSystemVersion v = [[NSProcessInfo processInfo] operatingSystemVersion];
        gModeIndex = [[NSUserDefaults standardUserDefaults] integerForKey:kKQLModeKey];
        if (gModeIndex < 0 || gModeIndex > 3) gModeIndex = 0;
        NSLog(@"[KickQualityLock] loaded on iOS %ld.%ld, mode %@",
              (long)v.majorVersion, (long)v.minorVersion, kKQLTitles[gModeIndex]);
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *t) {
            KQLTick();
        }];
    });
}
