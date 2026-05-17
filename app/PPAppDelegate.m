#import "PPAppDelegate.h"
#import "PPRootViewController.h"

@implementation PPAppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {

    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];

    PPRootViewController *root = [[PPRootViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc]
                                   initWithRootViewController:root];

    self.window.rootViewController = nav;
    [self.window makeKeyAndVisible];
    return YES;
}

// Handle "Open With ... PocketPoster" from Files.app / AirDrop / Safari.
// We just hand the URL to the root VC and let it deal with the import.
- (BOOL)application:(UIApplication *)app
            openURL:(NSURL *)url
            options:(NSDictionary<UIApplicationOpenURLOptionsKey, id> *)options {
    UINavigationController *nav = (UINavigationController *)self.window.rootViewController;
    if ([nav isKindOfClass:[UINavigationController class]]) {
        UIViewController *top = nav.viewControllers.firstObject;
        if ([top isKindOfClass:[PPRootViewController class]]) {
            [(PPRootViewController *)top importTendiesAtURL:url];
            return YES;
        }
    }
    return NO;
}

@end
