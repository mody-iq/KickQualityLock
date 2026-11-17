#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static UILabel *gLabel = nil;

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

static NSString *KQLBuildReport(void) {
    NSMutableString *out = [NSMutableString stringWithString:@"KQL v3"];
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    NSMutableArray *ivs = [NSMutableArray array];
    NSMutableArray *players = [NSMutableArray array];

    for (unsigned int i = 0; i < count; i++) {
        const char *cname = class_getName(classes[i]);
        if (!cname) continue;
        NSString *n = [NSString stringWithUTF8String:cname];
        if (!n) continue;
        if ([n hasPrefix:@"IVS"]) {
            [ivs addObject:n];
        } else if ([n rangeOfString:@"Player" options:NSCaseInsensitiveSearch].location != NSNotFound
                   && ![n hasPrefix:@"AV"] && ![n hasPrefix:@"UI"] && ![n hasPrefix:@"NS"]
                   && ![n hasPrefix:@"_"] && ![n hasPrefix:@"CA"] && ![n hasPrefix:@"MP"]) {
            [players addObject:n];
        }
    }
    free(classes);

    [ivs sortUsingSelector:@selector(compare:)];
    [players sortUsingSelector:@selector(compare:)];

    [out appendFormat:@"\nIVS classes: %lu", (unsigned long)ivs.count];
    NSUInteger maxIvs = MIN((NSUInteger)10, ivs.count);
    for (NSUInteger i = 0; i < maxIvs; i++) {
        [out appendFormat:@"\n  %@", ivs[i]];
    }

    [out appendFormat:@"\nPlayer-like classes: %lu", (unsigned long)players.count];
    NSUInteger maxPl = MIN((NSUInteger)12, players.count);
    for (NSUInteger i = 0; i < maxPl; i++) {
        [out appendFormat:@"\n  %@", players[i]];
    }

    Class ivsPlayer = NSClassFromString(@"IVSPlayer");
    if (ivsPlayer) {
        [out appendString:@"\nIVSPlayer methods:"];
        unsigned int mcount = 0;
        Method *methods = class_copyMethodList(ivsPlayer, &mcount);
        NSUInteger shown = 0;
        for (unsigned int i = 0; i < mcount && shown < 16; i++) {
            NSString *sel = NSStringFromSelector(method_getName(methods[i]));
            if ([sel rangeOfString:@"uality" options:NSCaseInsensitiveSearch].location != NSNotFound
                || [sel rangeOfString:@"auto" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                [out appendFormat:@"\n  %@", sel];
                shown++;
            }
        }
        if (methods) free(methods);
    } else {
        [out appendString:@"\nIVSPlayer: not found"];
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
        gLabel.frame = CGRectMake(8, 60, w, MIN(s.height, 520));
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
        [NSTimer scheduledTimerWithTimeInterval:4.0 repeats:YES block:^(NSTimer *t) {
            KQLUpdateOverlay();
        }];
    });
}
