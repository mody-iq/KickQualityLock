#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreGraphics/CoreGraphics.h>

static double gLastPeak = 0.0;
static CGSize gLastRes = {0.0, 0.0};

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

%hook AVPlayerItem

- (void)setPreferredPeakBitRate:(double)rate {
    if (rate > 0.0) {
        gLastPeak = rate;
        NSLog(@"[KickQualityLock] app set peak bitrate: %.0f", rate);
        %orig(rate);
    } else if (gLastPeak > 0.0) {
        NSLog(@"[KickQualityLock] blocked reset of peak bitrate, keeping %.0f", gLastPeak);
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
        NSLog(@"[KickQualityLock] blocked reset of resolution, keeping %.0fx%.0f", gLastRes.width, gLastRes.height);
        %orig(gLastRes);
    } else {
        %orig(size);
    }
}

%end

%hook AVPlayer

- (void)replaceCurrentItemWithItem:(AVPlayerItem *)item {
    KQLApplyToItem(item);
    %orig(item);
}

- (instancetype)initWithPlayerItem:(AVPlayerItem *)item {
    KQLApplyToItem(item);
    return %orig(item);
}

%end

%ctor {
    @autoreleasepool {
        NSOperatingSystemVersion v = [[NSProcessInfo processInfo] operatingSystemVersion];
        NSLog(@"[KickQualityLock] loaded on iOS %ld.%ld", (long)v.majorVersion, (long)v.minorVersion);
    }
}
