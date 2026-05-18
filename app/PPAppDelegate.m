#import "PPAppDelegate.h"
#import "PPRootViewController.h"
#import "PPBrowseViewController.h"
#import "PPSettingsViewController.h"

@implementation PPAppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {

    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];

    // Tab 1 — Library (local wallpapers, current screen).
    PPRootViewController *library = [[PPRootViewController alloc] init];
    UINavigationController *libraryNav = [[UINavigationController alloc]
                                         initWithRootViewController:library];
    if (@available(iOS 13.0, *)) {
        libraryNav.tabBarItem = [[UITabBarItem alloc]
            initWithTitle:@"Library"
                    image:[UIImage systemImageNamed:@"photo.stack"]
                      tag:0];
    } else {
        libraryNav.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Library" image:nil tag:0];
    }

    // Tab 2 — Browse (online catalog).
    PPBrowseViewController *browse = [[PPBrowseViewController alloc] init];
    UINavigationController *browseNav = [[UINavigationController alloc]
                                         initWithRootViewController:browse];
    if (@available(iOS 13.0, *)) {
        browseNav.tabBarItem = [[UITabBarItem alloc]
            initWithTitle:@"Browse"
                    image:[UIImage systemImageNamed:@"square.grid.2x2"]
                      tag:1];
    } else {
        browseNav.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Browse" image:nil tag:1];
    }

    UITabBarController *tabs = [UITabBarController new];

    // Tab 3 — Settings.
    PPSettingsViewController *settings = [[PPSettingsViewController alloc] init];
    UINavigationController *settingsNav = [[UINavigationController alloc]
                                           initWithRootViewController:settings];
    if (@available(iOS 13.0, *)) {
        settingsNav.tabBarItem = [[UITabBarItem alloc]
            initWithTitle:@"Settings"
                    image:[UIImage systemImageNamed:@"gearshape"]
                      tag:2];
    } else {
        settingsNav.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Settings" image:nil tag:2];
    }

    tabs.viewControllers = @[ libraryNav, browseNav, settingsNav ];

    // Subtle tint that matches Apple's stock apps.
    if (@available(iOS 13.0, *)) {
        tabs.tabBar.tintColor = [UIColor labelColor];
    }

    self.window.rootViewController = tabs;
    [self.window makeKeyAndVisible];
    return YES;
}

// Handle "Open With ... PocketPoster" from Files.app / AirDrop / Safari.
// Routes to the Library tab and triggers an import there.
- (BOOL)application:(UIApplication *)app
            openURL:(NSURL *)url
            options:(NSDictionary<UIApplicationOpenURLOptionsKey, id> *)options {
    UITabBarController *tabs = (UITabBarController *)self.window.rootViewController;
    if (![tabs isKindOfClass:[UITabBarController class]]) return NO;

    // Library tab is index 0; switch to it so the user sees the result.
    tabs.selectedIndex = 0;
    UINavigationController *nav = tabs.viewControllers.firstObject;
    if (![nav isKindOfClass:[UINavigationController class]]) return NO;
    UIViewController *top = nav.viewControllers.firstObject;
    if ([top isKindOfClass:[PPRootViewController class]]) {
        [(PPRootViewController *)top importTendiesAtURL:url];
        return YES;
    }
    return NO;
}

@end
