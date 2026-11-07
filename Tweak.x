#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <math.h>
#import <YouTubeHeader/_ASCollectionViewCell.h>
#import <YouTubeHeader/ASCollectionView.h>
#import <YouTubeHeader/ELMCellNode.h>
#import <YouTubeHeader/ELMContainerNode.h>
#import <YouTubeHeader/ELMNodeFactory.h>
#import <YouTubeHeader/ELMTextNode.h>
#import <YouTubeHeader/YTLikeStatus.h>
#import <YouTubeHeader/YTILikeButtonRenderer.h>
#import <YouTubeMusicHeader/MDCButton.h>
#import <YouTubeMusicHeader/YTMActionRowView.h>
#import <YouTubeMusicHeader/YTMNowPlayingViewController.h>
#import <HBLog.h>
#import "../Return-YouTube-Dislikes/API.h"
#import "../Return-YouTube-Dislikes/Shared.h"
#import "../Return-YouTube-Dislikes/TweakSettings.h"
#import "../Return-YouTube-Dislikes/Vote.h"

// -----------------------------------------------------------------------------
// RYMD Auto Skip — private YouTube Music queue interface
//
// These declarations are based on the YTM queue interface used by NextUp 3.
// The public source was built against YTM 9.28.4; this fork is being attempted
// against 9.44, so every private access below is guarded at runtime.
// -----------------------------------------------------------------------------
@interface YTQueueController : NSObject
@property (readonly, nonatomic) unsigned long long queueCount;
@property (readonly, nonatomic) unsigned long long nowPlayingIndex;
@property (readonly, nonatomic) unsigned long long nextNavigableVideoIndex;
- (BOOL)hasNextVideo;
- (id)videoRendererAtIndex:(unsigned long long)index;
- (void)playItemAtIndex:(unsigned long long)index;
- (void)commonInit;
- (id)initWithAccountID:(id)accountID parentResponder:(id)responder;
- (id)initWithAccountID:(id)accountID restorableQueueState:(id)state parentResponder:(id)responder;
- (void)playbackControllerDidLoadPlayerWithPlaybackData:(id)data;
- (void)updateNowPlayingVideoWithPlaylistPanelVideoRenderer:(id)renderer;
- (void)advanceToNextWithAutoplay:(BOOL)autoplay
  isPlaybackControllerInternalTransition:(BOOL)transition
                    unplayableVideoID:(id)videoID;
@end

@protocol RYMDVideoIDProviding <NSObject>
@property (copy, nonatomic, readonly) NSString *videoId;
@end

static NSCache<NSString *, NSDictionary *> *cache;

__strong ELMTextNode *likeTextNode = nil;
__strong ELMTextNode *dislikeTextNode = nil;
__strong NSMutableAttributedString *mutableDislikeText = nil;

int overrideNodeCreation = 0;

// New preference keys. Settings.x must use these exact strings.
static NSString * const RYMDAutoSkipEnabledKey = @"RYMDAutoSkipEnabled";
static NSString * const RYMDMinimumDislikesKey = @"RYMDMinimumDislikes";
static NSString * const RYMDMinimumRatioKey = @"RYMDMinimumDislikeLikeRatio";

// The live controller is captured from YTM's own queue hooks.
static __weak YTQueueController *rymQueueController = nil;
static NSString *rymLastRequestedVideoID = nil;

static BOOL RYMDAutoSkipEnabled(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    id value = [defaults objectForKey:RYMDAutoSkipEnabledKey];
    return value ? [value boolValue] : NO; // deliberately OFF by default
}

static double RYMDMinimumDislikes(void) {
    id value = [[NSUserDefaults standardUserDefaults] objectForKey:RYMDMinimumDislikesKey];
    double result = [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : 100000.0;
    return isfinite(result) && result >= 0.0 ? result : 100000.0;
}

static double RYMDMinimumDislikeLikeRatio(void) {
    id value = [[NSUserDefaults standardUserDefaults] objectForKey:RYMDMinimumRatioKey];
    double result = [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : 30.0;
    return isfinite(result) && result >= 0.0 ? result : 30.0;
}

static BOOL isVideoScrollableActionBar(ASCollectionView *collectionView) {
    return [collectionView.accessibilityIdentifier isEqualToString:@"id.video.scrollable_action_bar"];
}

static NSString *getVideoId(ASDisplayNode *containerNode) {
    YTMNowPlayingViewController *vc = (YTMNowPlayingViewController *)[containerNode closestViewController];
    if (![vc isKindOfClass:%c(YTMNowPlayingViewController)]) return nil;
    return vc.likeButtonRenderer.target.videoId;
}

// Reads the current item from YTQueueController. Do not infer the current item
// from a stale callback: the API response may arrive after the user changed song.
static NSString *RYMDCurrentQueueVideoID(YTQueueController *controller) {
    if (!controller) return nil;

    @try {
        if (![controller respondsToSelector:@selector(nowPlayingIndex)] ||
            ![controller respondsToSelector:@selector(queueCount)] ||
            ![controller respondsToSelector:@selector(videoRendererAtIndex:)]) {
            return nil;
        }

        unsigned long long count = controller.queueCount;
        unsigned long long index = controller.nowPlayingIndex;
        if (count == 0 || index >= count) return nil;

        id renderer = [controller videoRendererAtIndex:index];
        if (!renderer || ![renderer respondsToSelector:@selector(videoId)]) return nil;
        NSString *videoID = [(id<RYMDVideoIDProviding>)renderer videoId];
        return [videoID isKindOfClass:[NSString class]] && videoID.length ? videoID : nil;
    } @catch (NSException *exception) {
        HBLogDebug(@"RYMD Auto Skip: unable to read current queue item (%@)", exception);
        return nil;
    }
}

static void RYMDCheckCurrentTrackForAutoSkip(void);

// Runs only after YTM has had a moment to update its queue/current index.
static void RYMDQueueDidChange(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        RYMDCheckCurrentTrackForAutoSkip();
    });
}

static void RYMDPlayNextForVideoID(NSString *videoID) {
    if (videoID.length == 0) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        if (!TweakEnabled() || !RYMDAutoSkipEnabled()) return;

        YTQueueController *controller = rymQueueController;
        if (!controller) {
            HBLogDebug(@"RYMD Auto Skip: queue controller is unavailable");
            return;
        }

        // A response for an old song must never skip the song that replaced it.
        NSString *currentVideoID = RYMDCurrentQueueVideoID(controller);
        if (![currentVideoID isEqualToString:videoID]) {
            HBLogDebug(@"RYMD Auto Skip: ignored stale result for %@ (current %@)", videoID, currentVideoID);
            return;
        }

        @try {
            if (![controller respondsToSelector:@selector(hasNextVideo)] ||
                ![controller respondsToSelector:@selector(nextNavigableVideoIndex)] ||
                ![controller respondsToSelector:@selector(playItemAtIndex:)]) {
                HBLogDebug(@"RYMD Auto Skip: required queue selector is unavailable");
                return;
            }

            if (![controller hasNextVideo]) {
                HBLogDebug(@"RYMD Auto Skip: no next queue item for %@", videoID);
                return;
            }

            unsigned long long count = controller.queueCount;
            unsigned long long currentIndex = controller.nowPlayingIndex;
            unsigned long long nextIndex = controller.nextNavigableVideoIndex;

            // Refuse repeat-all wraparound (next index at/before current index).
            // Removing or jumping into the history section can corrupt YTM's queue.
            if (count == 0 || currentIndex >= count || nextIndex >= count || nextIndex <= currentIndex) {
                HBLogDebug(@"RYMD Auto Skip: refusing invalid/wrapped index (current %llu, next %llu, count %llu)",
                           currentIndex, nextIndex, count);
                return;
            }

            // NextUp 3 uses this native YTM method for "play the upcoming track now".
            // This advances playback; it does NOT remove the current song from history.
            [controller playItemAtIndex:nextIndex];
            HBLogDebug(@"RYMD Auto Skip: skipped %@ → queue index %llu", videoID, nextIndex);
        } @catch (NSException *exception) {
            HBLogDebug(@"RYMD Auto Skip: playItemAtIndex raised %@", exception);
        }
    });
}

static void RYMDCheckCurrentTrackForAutoSkip(void) {
    if (!TweakEnabled() || !RYMDAutoSkipEnabled()) return;

    YTQueueController *controller = rymQueueController;
    NSString *videoID = RYMDCurrentQueueVideoID(controller);
    if (videoID.length == 0) return;

    // Several YTM callbacks can describe the same current song. Start one API
    // lookup per consecutive play of a video, even if the UI is rebuilt.
    if ([rymLastRequestedVideoID isEqualToString:videoID]) return;
    rymLastRequestedVideoID = [videoID copy];

    HBLogDebug(@"RYMD Auto Skip: checking %@", videoID);
    getVoteFromVideoWithHandler(cache, videoID, maxRetryCount, ^(NSDictionary *data, NSString *error) {
        if (error || ![data isKindOfClass:[NSDictionary class]]) {
            HBLogDebug(@"RYMD Auto Skip: no usable API response for %@ (%@)", videoID, error);
            return;
        }

        // Always use the standard estimated counts from the API. Do not use
        // rawDislikes, even if an old preference value is still present.
        id likesObject = data[@"likes"];
        id dislikesObject = data[@"dislikes"];
        if (![likesObject isKindOfClass:[NSNumber class]] ||
            ![dislikesObject isKindOfClass:[NSNumber class]]) {
            HBLogDebug(@"RYMD Auto Skip: missing or invalid vote counts for %@", videoID);
            return;
        }

        double likes = [likesObject doubleValue];
        double dislikes = [dislikesObject doubleValue];
        if (!isfinite(likes) || !isfinite(dislikes) || likes <= 0.0 || dislikes < 0.0) {
            HBLogDebug(@"RYMD Auto Skip: invalid numeric vote counts for %@", videoID);
            return;
        }

        double minimumDislikes = RYMDMinimumDislikes();
        double minimumRatio = RYMDMinimumDislikeLikeRatio();
        double ratio = (dislikes / likes) * 100.0;

        HBLogDebug(@"RYMD Auto Skip: %@ — likes %.0f, dislikes %.0f, ratio %.2f%% (limits %.0f / %.2f%%)",
                   videoID, likes, dislikes, ratio, minimumDislikes, minimumRatio);

        // Both thresholds are required. Meeting only one is not sufficient.
        if (dislikes < minimumDislikes || ratio < minimumRatio) return;

        HBLogDebug(@"RYMD Auto Skip: %@ matched both thresholds", videoID);
        RYMDPlayNextForVideoID(videoID);
    });
}

static void getVoteAndModifyButtons(
    NSString *videoId,
    int pairMode,
    void (^likeHandler)(NSString *likeCount, NSNumber *likeNumber),
    void (^dislikeHandler)(NSString *dislikeCount, NSNumber *dislikeNumber)
) {
    getVoteFromVideoWithHandler(cache, videoId, maxRetryCount, ^(NSDictionary *data, NSString *error) {
        HBLogDebug(@"RYMD: Vote data for video %@: %@", videoId, data);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (ExactLikeNumber() && error == nil) {
                NSNumber *likeNumber = getLikeData(data);
                NSString *likeCount = formattedLongNumber(likeNumber, nil);
                if (likeCount && likeHandler) {
                    HBLogDebug(@"RYMD: Set like count for %@ to %@", videoId, likeCount);
                    likeHandler(likeCount, likeNumber);
                }
            }
            NSNumber *dislikeNumber = getDislikeData(data);
            NSString *dislikeCount = getNormalizedDislikes(dislikeNumber, error);
            if (dislikeHandler) {
                HBLogDebug(@"RYMD: Set dislike count for %@ to %@", videoId, dislikeCount);
                dislikeHandler(dislikeCount, dislikeNumber);
            }
        });
    });
}

%hook YTMActionRowView

- (void)updateLikeDislikeButtonWithRenderer:(YTILikeButtonRenderer *)renderer {
    %orig;
    if (!TweakEnabled() || renderer.target.videoId == nil) return;
    MDCButton *likeButton = [self valueForKey:@"_likeButton"];
    MDCButton *dislikeButton = [self valueForKey:@"_dislikeButton"];
    [dislikeButton setTitle:FETCHING forState:UIControlStateNormal];
    [dislikeButton ytm_sizeToFitWithSize:1];
    [self setNeedsLayout];
    getVoteFromVideoWithHandler(cache, renderer.target.videoId, maxRetryCount, ^(NSDictionary *data, NSString *error) {
        if (ExactLikeNumber()) {
            NSString *likeText = getNormalizedDislikes(getLikeData(data), error);
            dispatch_async(dispatch_get_main_queue(), ^{
                [likeButton setTitle:likeText forState:UIControlStateNormal];
                [likeButton ytm_sizeToFitWithSize:1];
                [self setNeedsLayout];
            });
        }
        NSString *dislikeText = getNormalizedDislikes(getDislikeData(data), error);
        dispatch_async(dispatch_get_main_queue(), ^{
            [dislikeButton setTitle:dislikeText forState:UIControlStateNormal];
            [dislikeButton ytm_sizeToFitWithSize:1];
            [self setNeedsLayout];
        });
    });
}

%end

%hook ASCollectionView

- (ELMCellNode *)nodeForItemAtIndexPath:(NSIndexPath *)indexPath {
    ELMCellNode *node = %orig;
    if (isVideoScrollableActionBar(self) && TweakEnabled()) {
        _ASCollectionViewCell *likeDislikeCell = [self.subviews firstObject];
        ASDisplayNode *containerNode = [likeDislikeCell node];
        NSString *videoId = getVideoId(containerNode);
        if (videoId == nil) return node;
        int pairMode = -1;
        BOOL isDislikeButtonModified = NO;
        do {
            containerNode = [containerNode.yogaChildren firstObject];
            if (containerNode.yogaChildren.count == 2)
                containerNode = containerNode.yogaChildren[1];
        } while (containerNode.yogaChildren.count == 1);
        ELMContainerNode *likeNode = [containerNode.yogaChildren firstObject];
        // if (![likeNode.accessibilityIdentifier isEqualToString:@"id.video.like.button"]) {
        //     HBLogDebug(@"RYMD: Like button not found, instead found %@", likeNode.accessibilityIdentifier);
        //     return node;
        // }
        if (likeNode.yogaChildren.count == 2) {
            ELMContainerNode *dislikeNode = [containerNode.yogaChildren lastObject];
            isDislikeButtonModified = dislikeNode.yogaChildren.count == 2;
            id targetNode = likeNode.yogaChildren[1];
            likeTextNode = (ELMTextNode *)targetNode;
            if (isDislikeButtonModified)
                dislikeTextNode = dislikeNode.yogaChildren[1];
            else {
                id elementContext = [likeTextNode valueForKey:@"_context"];
                overrideNodeCreation = 2;
                dislikeTextNode = [[%c(ELMNodeFactory) sharedInstance] nodeWithElement:likeTextNode.element materializationContext:&elementContext];
                overrideNodeCreation = 0;
                mutableDislikeText = [[NSMutableAttributedString alloc] initWithAttributedString:likeTextNode.attributedText];
                dislikeTextNode.attributedText = mutableDislikeText;
                [dislikeNode addYogaChild:dislikeTextNode];
                [dislikeNode.view addSubview:dislikeTextNode.view];
                pairMode = 0;
            }
        } else {
            dislikeTextNode = likeNode.yogaChildren[1];
            if (![dislikeTextNode isKindOfClass:%c(ELMTextNode)]) return node;
            mutableDislikeText = [[NSMutableAttributedString alloc] initWithAttributedString:dislikeTextNode.attributedText];
            mutableDislikeText.mutableString.string = FETCHING;
            dislikeTextNode.attributedText = mutableDislikeText;
        }
        BOOL shouldFetchVote = ExactLikeNumber() || !isDislikeButtonModified;
        if (shouldFetchVote) {
            getVoteAndModifyButtons(
                videoId,
                pairMode,
                ^(NSString *likeCount, NSNumber *likeNumber) {
                    NSMutableAttributedString *mutableLikeText = [[NSMutableAttributedString alloc] initWithAttributedString:likeTextNode.attributedText];
                    mutableLikeText.mutableString.string = likeCount;
                    likeTextNode.attributedText = mutableLikeText;
                    likeTextNode.accessibilityLabel = likeCount;
                },
                ^(NSString *dislikeCount, NSNumber *dislikeNumber) {
                    if (isDislikeButtonModified) return;
                    NSString *dislikeString;
                    switch (pairMode) {
                        case -1:
                            dislikeString = dislikeCount;
                            break;
                        case 0:
                            dislikeString = [NSString stringWithFormat:@"  %@ ", dislikeCount];
                            break;
                    }
                    mutableDislikeText.mutableString.string = dislikeString;
                    dislikeTextNode.attributedText = mutableDislikeText;
                    dislikeTextNode.accessibilityLabel = dislikeCount;
                }
            );
        }
    }
    return node;
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    %orig;
    if (isVideoScrollableActionBar(self) && TweakEnabled() && dislikeTextNode) {
        NSString *dislikeText = dislikeTextNode.attributedText.string;
        mutableDislikeText = [[NSMutableAttributedString alloc] initWithAttributedString:likeTextNode.attributedText];
        mutableDislikeText.mutableString.string = dislikeText;
        dislikeTextNode.attributedText = mutableDislikeText;
    }
}

%end

%hook ELMNodeFactory

- (Class)classForElement:(id)element materializationContext:(const void *)context {
    switch (overrideNodeCreation) {
        case 2:
            return %c(ELMTextNode);
        default:
            return %orig;
    }
}

%end

// -----------------------------------------------------------------------------
// YTQueueController hooks — capture the live YTM queue and re-check the active
// track after every relevant playback transition / explicit queue navigation.
// -----------------------------------------------------------------------------
%hook YTQueueController

- (void)commonInit {
    %orig;
    rymQueueController = self;
    RYMDQueueDidChange();
}

- (id)initWithAccountID:(id)accountID parentResponder:(id)responder {
    id result = %orig;
    rymQueueController = self;
    RYMDQueueDidChange();
    return result;
}

- (id)initWithAccountID:(id)accountID restorableQueueState:(id)state parentResponder:(id)responder {
    id result = %orig;
    rymQueueController = self;
    RYMDQueueDidChange();
    return result;
}

- (void)playbackControllerDidLoadPlayerWithPlaybackData:(id)data {
    %orig;
    rymQueueController = self;
    RYMDQueueDidChange();
}

- (void)updateNowPlayingVideoWithPlaylistPanelVideoRenderer:(id)renderer {
    %orig;
    rymQueueController = self;
    RYMDQueueDidChange();
}

- (void)playItemAtIndex:(unsigned long long)index {
    %orig;
    rymQueueController = self;
    RYMDQueueDidChange();
}

- (void)advanceToNextWithAutoplay:(BOOL)autoplay
  isPlaybackControllerInternalTransition:(BOOL)transition
                    unplayableVideoID:(id)videoID {
    %orig;
    rymQueueController = self;
    RYMDQueueDidChange();
}

%end

%hook YTLikeService

- (void)makeRequestWithStatus:(YTLikeStatus)likeStatus target:(YTILikeTarget *)target clickTrackingParams:(id)arg3 requestParams:(id)arg4 responseBlock:(id)arg5 errorBlock:(id)arg6 {
    if (TweakEnabled() && VoteSubmissionEnabled())
        sendVote(target.videoId, likeStatus);
    %orig;
}

- (void)makeRequestWithStatus:(YTLikeStatus)likeStatus target:(YTILikeTarget *)target clickTrackingParams:(id)arg3 queueContextParams:(id)arg4 requestParams:(id)arg5 responseBlock:(id)arg6 errorBlock:(id)arg7 {
    if (TweakEnabled() && VoteSubmissionEnabled())
        sendVote(target.videoId, likeStatus);
    %orig;
}

%end

%hook YTLikeServiceImpl

- (void)makeRequestWithStatus:(YTLikeStatus)likeStatus target:(YTILikeTarget *)target clickTrackingParams:(id)arg3 queueContextParams:(id)arg4 requestParams:(id)arg5 responseBlock:(id)arg6 errorBlock:(id)arg7 {
    if (TweakEnabled() && VoteSubmissionEnabled())
        sendVote(target.videoId, likeStatus);
    %orig;
}

%end

%ctor {
    cache = [NSCache new];
    %init;
}
