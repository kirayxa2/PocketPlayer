// LFLockScreenWallpaperView - overlays the active lock-screen's custom
// wallpaper above the system's stock wallpaper.
//
// Why an overlay (vs. hooking SBWallpaperController):
//
//   The right way to swap wallpapers in iOS 15 SpringBoard is to hook
//   SBWallpaperController and intercept its image-providing methods.
//   That's clean but BRITTLE: Apple changed those private methods
//   between point releases of iOS 15 (15.0..15.8.x), so a hook that
//   compiles against 16.5 SDK headers will silently break against a
//   user on 15.4.x.
//
//   The overlay approach is dead simple, robust, and works on EVERY
//   iOS 15 point release without conditional compilation: we just
//   add a UIImageView as the bottom-most subview of the cover-sheet
//   view. The system's wallpaper draws underneath (irrelevant -- our
//   image covers it), the cover-sheet's date / time / clock overlay
//   drawn by the rest of LockForge sits on top.
//
//   Trade-off: we don't get pinch-to-crop / depth-effect from Apple's
//   wallpaper engine. Stock wallpapers (Settings -> Wallpaper) keep
//   working since we never touch them; ours is a simple full-bleed
//   image. If the user picks one wallpaper per lock-screen pre-cropped
//   to 16:9 / 19.5:9 / etc. it looks identical to the system's.
//
// One instance lives inside the cover-sheet view. It listens for
// LFActiveLockScreenChangedNotification and reloads its image to
// match the new active screen. When the active screen has no custom
// wallpaper, the view is hidden (system wallpaper shows through).

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface LFLockScreenWallpaperView : UIView

// Re-read the active lock-screen's wallpaper path from the library and
// update -hidden / -image / -frame accordingly. Called automatically
// on `LFActiveLockScreenChangedNotification`; expose for explicit
// refresh after add / delete.
- (void)refresh;

@end

NS_ASSUME_NONNULL_END
