// LFStocksClient - minimal stock-quote client for the Stocks inline
// widget on the LockForge date pill.
//
// Apple's iOS 26 Stocks widget pulls from their internal Stocks API
// which is gated behind device entitlements. On iOS 15 from a JB
// tweak we have to go to the public web. After surveying the field:
//
//   * Yahoo Finance v8 chart endpoint
//       https://query1.finance.yahoo.com/v8/finance/chart/<SYM>
//     returns enough metadata (regularMarketPrice, previousClose,
//     shortName, currency) in the `meta` block to render an inline
//     ticker, no API key, no signup, no rate limit for personal use.
//   * IEX Cloud, Finnhub, Alpha Vantage, etc. all require keys and
//     have free-tier rate limits that don't survive a single device
//     in real use.
//
// We hit Yahoo, parse the meta block, cache the result in
//   /var/mobile/Library/LockForge/stocks.<SYMBOL>.cache
// for 5 minutes (markets move slowly enough for a lock-screen
// widget; faster TTL would just burn battery rebroadcasting prices
// the user already saw).
//
// Graceful degradation: if the network fails or Yahoo changes the
// shape of their response, the inline widget shows the last cached
// value with a stale-indicator dot, falling back to the bare ticker
// symbol if no cache is available.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LFStockQuote : NSObject
@property (nonatomic, copy)   NSString *symbol;        // "AAPL"
@property (nonatomic, copy)   NSString *shortName;     // "Apple Inc."
@property (nonatomic, copy)   NSString *currency;      // "USD"
@property (nonatomic, assign) double    price;         // regularMarketPrice
@property (nonatomic, assign) double    previousClose; // chartPreviousClose
@property (nonatomic, assign) double    changePercent; // signed, e.g. -1.42
@property (nonatomic, copy)   NSDate   *fetchedAt;
@end

@interface LFStocksClient : NSObject

+ (instancetype)shared;

// Most recent CACHED quote for a given ticker. Returns synchronously,
// safe to call on every minute tick. Returns nil if no cache exists
// for that symbol (cold start).
- (nullable LFStockQuote *)cachedQuoteForSymbol:(NSString *)symbol;

// Async refresh. Hits the network if cache is older than 5 min,
// unless `force` is YES. Completion delivered on main queue with
// the freshest available quote (may be the stale cache if the
// request failed). Pass nil completion to seed the cache silently.
- (void)refreshIfStaleForSymbol:(NSString *)symbol
                          force:(BOOL)force
                     completion:(void (^_Nullable)(LFStockQuote *_Nullable quote,
                                                    NSError *_Nullable error))completion;

// Sanitise a raw user-typed string ("aapl ", "$AAPL", "BRK.B") into
// a Yahoo-friendly ticker uppercase string. Returns nil for blank /
// non-printable input.
+ (nullable NSString *)normalizedSymbol:(NSString *)raw;

@end

NS_ASSUME_NONNULL_END
