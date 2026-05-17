#import <UIKit/UIKit.h>

@interface PPRootViewController : UIViewController

// Called by AppDelegate when the user taps a .tendies file in Files.app
// and chooses "Open With ... PocketPoster". Forwards to the same import
// path as the in-app + button.
- (void)importTendiesAtURL:(NSURL *)url;

@end
