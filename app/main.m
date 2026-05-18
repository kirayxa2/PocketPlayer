// PocketPoster app entry point. Plain UIKit, no Scenes — keeps the
// minimum-viable skeleton tiny and avoids the SceneDelegate plist plumbing.
#import <UIKit/UIKit.h>
#import "PPAppDelegate.h"

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil,
                                 NSStringFromClass([PPAppDelegate class]));
    }
}
