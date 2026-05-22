#import "LFStocksClient.h"

static NSString *const kLFStocksCacheDir =
    @"/var/mobile/Library/LockForge";
static const NSTimeInterval kLFStocksTTL = 5.0 * 60.0;   // 5 min

@implementation LFStockQuote

// Plist round-trip. Same NSCoding-free style as LFWeatherSnapshot --
// keeps the cache human-debuggable and avoids tying the on-disk
// format to a Foundation archiver version.
+ (instancetype)fromPlist:(NSDictionary *)d {
    if (![d isKindOfClass:[NSDictionary class]]) return nil;
    LFStockQuote *q = [LFStockQuote new];
    q.symbol        = d[@"symbol"];
    q.shortName     = d[@"shortName"];
    q.currency      = d[@"currency"];
    q.price         = [d[@"price"]         doubleValue];
    q.previousClose = [d[@"previousClose"] doubleValue];
    q.changePercent = [d[@"changePercent"] doubleValue];
    q.fetchedAt     = d[@"fetchedAt"];
    return q;
}
- (NSDictionary *)toPlist {
    return @{
        @"symbol":        self.symbol        ?: @"",
        @"shortName":     self.shortName     ?: @"",
        @"currency":      self.currency      ?: @"",
        @"price":         @(self.price),
        @"previousClose": @(self.previousClose),
        @"changePercent": @(self.changePercent),
        @"fetchedAt":     self.fetchedAt     ?: [NSDate date],
    };
}
@end

@interface LFStocksClient () {
    // Per-symbol in-memory cache so multiple widgets querying the same
    // symbol on a single tick don't all hit the disk independently.
    // Symbol uppercase string -> LFStockQuote.
    NSMutableDictionary<NSString *, LFStockQuote *> *_memoryCache;

    // Per-symbol "request in flight" flags so re-entrant refresh
    // calls collapse into the original request.
    NSMutableSet<NSString *>                       *_inFlight;

    NSURLSession                                   *_session;
}
@end

@implementation LFStocksClient

+ (instancetype)shared {
    static LFStocksClient *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [LFStocksClient new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _memoryCache = [NSMutableDictionary dictionary];
        _inFlight    = [NSMutableSet set];

        // Ephemeral session so we don't share cookies / cache with
        // any other URL traffic in SpringBoard. Yahoo's chart
        // endpoint is unauthenticated; fastest-fail config is the
        // best for a lock-screen widget.
        NSURLSessionConfiguration *cfg =
            [NSURLSessionConfiguration ephemeralSessionConfiguration];
        cfg.timeoutIntervalForRequest    = 8.0;
        cfg.HTTPMaximumConnectionsPerHost = 2;
        cfg.HTTPAdditionalHeaders         = @{
            // Yahoo serves an HTML "consent" page to requests with
            // an empty / generic UA. A plain Mozilla string makes
            // them serve the JSON straight away.
            @"User-Agent": @"Mozilla/5.0 (iPhone; CPU iPhone OS 15_8 "
                            "like Mac OS X) AppleWebKit/605.1.15 "
                            "(KHTML, like Gecko) Version/15.0 Mobile/15E148 Safari/604.1",
        };
        _session = [NSURLSession sessionWithConfiguration:cfg];
    }
    return self;
}

#pragma mark - Public

+ (NSString *)normalizedSymbol:(NSString *)raw {
    if (![raw isKindOfClass:[NSString class]]) return nil;
    NSString *s = [raw stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    // Strip a leading "$" the way users sometimes write tickers.
    if ([s hasPrefix:@"$"]) s = [s substringFromIndex:1];
    s = [s uppercaseString];
    if (s.length == 0)  return nil;
    if (s.length > 12)  s = [s substringToIndex:12];   // cap length

    // Allow letters / digits / dot / hyphen / caret. Caret is used
    // by Yahoo for indices ("^GSPC"); dot for class shares
    // ("BRK.B"); hyphen for crypto / preferreds ("BTC-USD").
    NSCharacterSet *allowed = [NSCharacterSet
        characterSetWithCharactersInString:
            @"ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-^"];
    for (NSUInteger i = 0; i < s.length; i++) {
        if (![allowed characterIsMember:[s characterAtIndex:i]]) {
            return nil;
        }
    }
    return s;
}

- (LFStockQuote *)cachedQuoteForSymbol:(NSString *)symbol {
    NSString *sym = [LFStocksClient normalizedSymbol:symbol];
    if (!sym) return nil;
    LFStockQuote *q = _memoryCache[sym];
    if (q) return q;

    NSString *path = [self cachePathForSymbol:sym];
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:path];
    q = [LFStockQuote fromPlist:d];
    if (q) _memoryCache[sym] = q;
    return q;
}

- (void)refreshIfStaleForSymbol:(NSString *)symbol
                          force:(BOOL)force
                     completion:(void (^)(LFStockQuote *, NSError *))completion {
    NSString *sym = [LFStocksClient normalizedSymbol:symbol];
    if (!sym) {
        if (completion) {
            completion(nil, [NSError errorWithDomain:@"LFStocksClient"
                                                 code:-1
                                             userInfo:@{NSLocalizedDescriptionKey:
                                                            @"Invalid symbol"}]);
        }
        return;
    }

    LFStockQuote *cached = [self cachedQuoteForSymbol:sym];
    BOOL stale = !cached ||
        ([[NSDate date] timeIntervalSinceDate:cached.fetchedAt] > kLFStocksTTL);
    if (!force && !stale) {
        if (completion) completion(cached, nil);
        return;
    }
    if ([_inFlight containsObject:sym]) {
        // Coalesce -- caller gets the cache we have right now and the
        // already-running fetch will repopulate the disk cache for
        // the next tick.
        if (completion) completion(cached, nil);
        return;
    }
    [_inFlight addObject:sym];

    NSString *url = [NSString stringWithFormat:
        @"https://query1.finance.yahoo.com/v8/finance/chart/%@"
        @"?interval=1d&range=2d&includePrePost=false",
        [sym stringByAddingPercentEncodingWithAllowedCharacters:
            [NSCharacterSet URLPathAllowedCharacterSet]]];

    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *t = [_session dataTaskWithURL:[NSURL URLWithString:url]
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(self) self_ = weakSelf;
            if (!self_) return;
            [self_->_inFlight removeObject:sym];

            if (err || !data) {
                if (completion) completion(cached, err);
                return;
            }
            NSError *jerr = nil;
            id obj = [NSJSONSerialization JSONObjectWithData:data
                                                      options:0
                                                        error:&jerr];
            LFStockQuote *q = [self_ parseQuote:obj symbol:sym];
            if (!q) {
                if (completion) completion(cached, jerr);
                return;
            }
            self_->_memoryCache[sym] = q;
            NSDictionary *plist = [q toPlist];
            [[NSFileManager defaultManager] createDirectoryAtPath:kLFStocksCacheDir
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:NULL];
            [plist writeToFile:[self_ cachePathForSymbol:sym]
                    atomically:YES];
            if (completion) completion(q, nil);
        });
    }];
    [t resume];
}

#pragma mark - Internal

- (NSString *)cachePathForSymbol:(NSString *)sym {
    // Sanitise -- caret / dot are legal in symbols but we want a
    // filesystem-friendly cache name. We've already normalised the
    // alphabet in +normalizedSymbol: so this just collapses
    // structural characters.
    NSString *safe = [sym stringByReplacingOccurrencesOfString:@"^" withString:@"_"];
    safe = [safe stringByReplacingOccurrencesOfString:@"." withString:@"_"];
    safe = [safe stringByReplacingOccurrencesOfString:@"-" withString:@"_"];
    return [NSString stringWithFormat:@"%@/stocks.%@.cache",
            kLFStocksCacheDir, safe];
}

// Parse Yahoo's chart response. Layout:
//   {
//     "chart": {
//       "result": [{
//         "meta": {
//           "symbol": "AAPL", "currency": "USD",
//           "shortName": "Apple Inc.",
//           "regularMarketPrice": 192.42,
//           "chartPreviousClose": 195.10
//         }
//       }],
//       "error": null
//     }
//   }
- (LFStockQuote *)parseQuote:(id)obj symbol:(NSString *)sym {
    if (![obj isKindOfClass:[NSDictionary class]]) return nil;
    NSDictionary *chart = obj[@"chart"];
    if (![chart isKindOfClass:[NSDictionary class]]) return nil;
    NSArray *result = chart[@"result"];
    if (![result isKindOfClass:[NSArray class]] || result.count == 0) return nil;
    NSDictionary *meta = [result[0] isKindOfClass:[NSDictionary class]]
        ? ((NSDictionary *)result[0])[@"meta"] : nil;
    if (![meta isKindOfClass:[NSDictionary class]]) return nil;

    double price         = [meta[@"regularMarketPrice"] doubleValue];
    double previousClose = [meta[@"chartPreviousClose"] doubleValue];
    if (price <= 0) return nil;

    LFStockQuote *q = [LFStockQuote new];
    q.symbol        = [meta[@"symbol"] isKindOfClass:[NSString class]]
                          ? meta[@"symbol"] : sym;
    q.shortName     = [meta[@"shortName"] isKindOfClass:[NSString class]]
                          ? meta[@"shortName"] : sym;
    q.currency      = [meta[@"currency"] isKindOfClass:[NSString class]]
                          ? meta[@"currency"] : @"";
    q.price         = price;
    q.previousClose = previousClose;
    q.changePercent = (previousClose > 0)
        ? ((price - previousClose) / previousClose) * 100.0
        : 0.0;
    q.fetchedAt     = [NSDate date];
    return q;
}

@end
