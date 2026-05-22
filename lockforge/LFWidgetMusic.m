#import "LFWidgetMusic.h"
#import <MediaPlayer/MediaPlayer.h>

@interface LFWidgetMusic () {
    UIImageView *_artView;
    UIImageView *_placeholder;
    UILabel     *_titleLabel;
    UILabel     *_artistLabel;
    NSTimer     *_pollTimer;
}
@end

@implementation LFWidgetMusic

- (instancetype)initWithKind:(LFWidgetKind)kind
                      family:(LFWidgetFamily)family
                      config:(NSDictionary *)config {
    self = [super initWithKind:kind family:family config:config];
    if (!self) return nil;
    [self setupSubviewsForFamily:family];

    // MPNowPlayingInfoCenter doesn't post change notifications when
    // ANOTHER process changes the now-playing info (which is the
    // common case -- Music.app, Spotify, etc.). Poll cheaply every
    // 5 seconds; the dictionary access is constant-time.
    __weak typeof(self) weakSelf = self;
    _pollTimer = [NSTimer scheduledTimerWithTimeInterval:5.0
                                                 repeats:YES
                                                   block:^(NSTimer *_) {
        [weakSelf refreshContent];
    }];

    [self refreshContent];
    return self;
}

- (void)dealloc { [_pollTimer invalidate]; }

- (NSTimeInterval)preferredRefreshInterval { return 5.0; }

- (void)setupSubviewsForFamily:(LFWidgetFamily)family {
    [self installGlassBackdrop];

    _artView                   = [UIImageView new];
    _artView.contentMode       = UIViewContentModeScaleAspectFill;
    _artView.layer.masksToBounds = YES;
    _artView.layer.cornerRadius  = 6;
    [self addSubview:_artView];

    _placeholder = [UIImageView new];
    _placeholder.contentMode = UIViewContentModeScaleAspectFit;
    _placeholder.tintColor   = [UIColor whiteColor];
    [self addSubview:_placeholder];

    if (family == LFWidgetFamilyRectangular) {
        _titleLabel              = [UILabel new];
        _titleLabel.textColor    = [UIColor whiteColor];
        _titleLabel.font         = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
        _titleLabel.numberOfLines = 1;
        [self addSubview:_titleLabel];

        _artistLabel              = [UILabel new];
        _artistLabel.textColor    = [UIColor colorWithWhite:1.0 alpha:0.65];
        _artistLabel.font         = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
        _artistLabel.numberOfLines = 1;
        [self addSubview:_artistLabel];
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    if (self.family == LFWidgetFamilyCircular) {
        // Square art clipped into the circular widget area; outer view
        // is already round through the glass backdrop.
        _artView.frame = CGRectInset(b, 6, 6);
        _artView.layer.cornerRadius = (b.size.width - 12) / 2.0;
        _placeholder.frame = CGRectMake((b.size.width - 22) / 2.0,
                                        (b.size.height - 22) / 2.0,
                                        22, 22);
    } else {
        CGFloat artSize = b.size.height - 16;
        _artView.frame = CGRectMake(8, (b.size.height - artSize) / 2.0, artSize, artSize);
        _artView.layer.cornerRadius = 8;
        _placeholder.frame = CGRectMake(8 + (artSize - 22) / 2.0,
                                        (b.size.height - 22) / 2.0,
                                        22, 22);
        CGFloat textX = CGRectGetMaxX(_artView.frame) + 8;
        CGFloat textW = b.size.width - textX - 6;
        _titleLabel.frame  = CGRectMake(textX, 12, textW, 18);
        _artistLabel.frame = CGRectMake(textX, 32, textW, 14);
    }
}

- (void)refreshContent {
    NSDictionary *info = [[MPNowPlayingInfoCenter defaultCenter] nowPlayingInfo];
    NSString *title  = info[MPMediaItemPropertyTitle];
    NSString *artist = info[MPMediaItemPropertyArtist];
    UIImage  *art    = nil;
    MPMediaItemArtwork *aw = info[MPMediaItemPropertyArtwork];
    if (aw) {
        art = [aw imageWithSize:CGSizeMake(120, 120)];
    }

    _artView.image = art;
    BOOL hasArt = (art != nil);
    _artView.hidden = !hasArt;
    _placeholder.hidden = hasArt;

    // @available cannot be combined with other expressions through &&
    // in a regular if -- clang refuses to treat that form as a guard
    // for symbol-API calls. Split into nested ifs so the API is gated.
    if (!hasArt) {
        if (@available(iOS 13.0, *)) {
            UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration
                configurationWithPointSize:18 weight:UIImageSymbolWeightSemibold];
            _placeholder.image = [UIImage systemImageNamed:@"music.note"
                                         withConfiguration:cfg];
        }
    }

    if (_titleLabel) {
        _titleLabel.text  = title.length  ? title  : @"Not Playing";
        _artistLabel.text = artist.length ? artist : @"";
    }
}

@end
