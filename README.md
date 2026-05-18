# PocketPlayer

PosterBoard-style **animated wallpapers** for **iOS 15** — the way Lemin's
[Pocket Poster](https://github.com/leminlimez/Pocket-Poster) does it for iOS 17,
but built from scratch so it runs on devices Apple stranded on iOS 15
(iPhone 6s/7, plus anyone on Dopamine / palera1n rootless).

It loads `.tendies` wallpaper bundles (the same format the iOS 17 PosterBoard
ecosystem uses), parses the `main.caml` scene and animates between the
`Locked` / `Unlocked` states based on the swipe-to-unlock gesture. Particle
emitters, multi-state transitions, multi-bundle (`Background.ca` + `Floating.ca`
+ `Foreground.ca`) layouts and `<animations>` keyframes are all supported.

## What's in this repo

Two pieces, distributed as separate `.deb`s so you can run them
independently:

| Component         | What it does                                                    | Package id                       |
| ----------------- | --------------------------------------------------------------- | -------------------------------- |
| **PocketPlayer**  | The tweak. Hooks SpringBoard, parses the active CAML wallpaper, draws it on the lockscreen *and* home screen, animates with the unlock gesture. | `com.vortex.pocketplayer`        |
| **PocketPoster**  | Companion iOS app. Import `.tendies` files (Files / AirDrop / Telegram), browse the online catalog, apply with one tap, optional respring. | `com.vortex.pocketposter`        |

```
SBCoverSheetWindow                           SBHomeScreenWindow
└── PocketPlayerLayer (z=-1)                 └── PocketPlayerHomeLayer (z=-1000)
    ├── Background.ca  (CAML root)               ├── Background.ca  (frozen at Unlock)
    ├── Floating.ca    (chest, particles)        ├── Floating.ca
    └── Foreground.ca                            └── Foreground.ca
                ↑                                            ↑
   driven by swipe progress                  static (already-open chest)
```

## Highlights

- **Real CAML rendering** — full XML parser (~1300 lines) covering CALayer /
  CATransformLayer / CAShapeLayer / CAEmitterLayer / CAEmitterCell, `<states>`,
  `<animations>` (CABasicAnimation / CAKeyframeAnimation), color decay,
  `transform="scale(...) rotate(...) translate(...)"` shorthand, WebP textures.
- **Particle emitters that actually emit** — CAEmitterLayer rebuilt from scratch
  on the cover-sheet *view* (not the frozen window) so iOS 15's `speed=0`
  cascade doesn't kill them.
- **Two posters in sync** — lockscreen poster animates with the gesture,
  home-screen poster sits frozen at the final pose so the chest under the
  dock matches the moment the cover sheet slides away.
- **System wallpaper hidden** automatically while the tweak is active — no
  ghosting of your previous wallpaper through the bottom of the scene.
- **Panic recovery** — if SpringBoard crashes twice in 30s with our wallpaper
  active, the bundle is auto-quarantined and SB boots empty. Bad `.tendies`
  can never trap you in safe mode.
- **Companion app** — UIDocumentPicker import, `.tendies` open-with handler,
  per-import auto-resize to your screen, online catalog (SerStars/Nugget-Wallpapers),
  optional GitHub token in Settings to lift the rate limit.

## Quick start

### Prerequisites

- iOS 15.0 - 16.6.x device, jailbroken with Dopamine 2 (rootless)
  or palera1n
- WSL / Linux / macOS host with [Theos](https://theos.dev) installed

### Install

```bash
git clone https://github.com/kirayxa2/PocketPlayer.git
cd PocketPlayer

# One-time: install Theos + iOS 15 SDK
bash scripts/setup.sh
source ~/.bashrc

# Build + ship the tweak
PP_HOST=mobile@192.168.0.112 PP_KEY=~/.ssh/iphone PP_PASS=vortex \
  ./scripts/deploy.sh

# Build + ship the companion app
PP_PASS=vortex make app-deploy
```

After SpringBoard respawns:

1. Launch **PocketPoster** from the home screen.
2. Tap the `+` and pick any `.tendies` (Telegram saves them as
   "Document"; AirDrop and Files.app work too).
3. Watch the import card walk through Importing → Resizing → Done.
4. Tap the new tile, then **Apply**. Lockscreen overlay updates
   instantly. Tap **Respring** for the change to take over the home
   screen and the system wallpaper too.

> **sudo without password** on the phone (one-time, recommended):
> ```
> echo "mobile ALL=(ALL) NOPASSWD: ALL" | sudo tee /var/jb/etc/sudoers.d/mobile
> sudo chmod 440 /var/jb/etc/sudoers.d/mobile
> ```

### Open `.tendies` straight from Telegram / Files

PocketPoster registers as a handler for the `.tendies` extension, so tap
"Open With → PocketPoster" from any sharing UI and the import flow
starts inside the app — no manual save step.

## Repo layout

| Path                  | What                                                            |
| --------------------- | --------------------------------------------------------------- |
| `Tweak.x`             | MobileSubstrate hooks for SpringBoard                           |
| `CAMLParser.{h,m}`    | XML parser — CALayer / states / animations / emitters           |
| `Makefile`, `control` | Theos build config for the tweak (rootless, iOS 15+, arm64/e)   |
| `PocketPlayer.plist`  | Substrate filter — load only into `com.apple.springboard`       |
| `app/`                | PocketPoster companion app (separate Theos target)              |
| `scripts/setup.sh`    | One-time WSL setup (Theos + iOS 15 SDK)                         |
| `scripts/deploy.sh`   | Build + scp + dpkg -i + respring (tweak)                        |
| `scripts/deploy-app.sh` | Build + scp + dpkg -i + uicache (app)                         |
| `scripts/gen-icons.sh` | Resize the master `posterPlayer.png` into iOS icon variants    |

## How progress is captured

In iOS 15.x the lockscreen presentation progress is reported by **one of**
these private classes, and the choice differs across point releases:

- `CSCoverSheetViewController -_updatePresentationProgress:withOffset:presentationState:`
- `SBCoverSheetSlidingViewController` (same selector)
- `SBDashBoardViewController` (older 15.0 / 15.1 builds)

We hook all three. The hook that exists at runtime gets matched by Substrate;
the others are silent no-ops. As a final fallback, a `CADisplayLink` reads the
cover-sheet view's window-space `y` directly and derives progress geometrically,
so the animation always has *some* signal even if Apple renames everything in
a future patch.

## Wallpaper format

```
Foo.wallpaper/
├── Foo_Background-390w-844h@3x~iphone.ca/
│   ├── main.caml
│   └── assets/*.png
├── Foo_Floating-390w-844h@3x~iphone.ca/
│   ├── main.caml
│   └── assets/*.png
└── Foo_Foreground-390w-844h@3x~iphone.ca/  (optional)
    └── ...
```

Each `.ca` is parsed into its own scaled `CALayer` subtree and stacked back-
to-front. Empty `Floating.ca` bundles are common — the visible content lives
entirely in `Background.ca`. PocketPlayer handles that gracefully.

`main.caml` example:

```xml
<caml xmlns="http://www.apple.com/CoreAnimation/1.0">
  <CALayer name="Root" bounds="0 0 390 844" position="195 422">
    <sublayers>
      <CALayer id="lid" name="Top_chest" bounds="0 0 390 111" position="195 334">
        <contents><CGImage src="assets/Top_chest.png"/></contents>
      </CALayer>
      <CAEmitterLayer name="StarBits" position="290 700"
                      emitterShape="point" renderMode="unordered">
        <emitterCells>
          <CAEmitterCell birthRate="20" lifetime="100" velocity="114"
                         emissionLongitude="-1.57" emissionRange="0.5">
            <contents><CGImage src="assets/starbit.webp"/></contents>
          </CAEmitterCell>
        </emitterCells>
      </CAEmitterLayer>
    </sublayers>
    <states>
      <LKState name="Locked">
        <elements>
          <LKStateSetValue targetId="lid" keyPath="position.y">
            <value type="integer" value="334"/>
          </LKStateSetValue>
        </elements>
      </LKState>
      <LKState name="Unlocked">
        <elements>
          <LKStateSetValue targetId="lid" keyPath="position.y">
            <value type="integer" value="100"/>
          </LKStateSetValue>
        </elements>
      </LKState>
    </states>
  </CALayer>
</caml>
```

Supported keypaths: `bounds`, `position`, `position.{x,y}`, `anchorPoint`,
`opacity`, `hidden`, `cornerRadius`, `backgroundColor`, `geometryFlipped`,
`contentsGravity`, `transform`, `transform.rotation.{x,y,z}`,
`transform.scale[.x|.y]`. Anything unknown is gracefully skipped — KVC errors
are caught so a single weird state value can't kill SpringBoard.

`<value type="...">`: `integer`, `real`, `point`, `size`, `rect`, `color`,
`transform`.

## Roadmap

- [ ] Smart-resize: anchor-aware so off-center wallpapers don't push content
  off the edge of small screens
- [ ] Long-press tile menu (rename / duplicate / delete)
- [ ] Live preview rendering for the gallery thumbnails (currently uses one
  state snapshot)
- [ ] Better empty-state for Browse when GitHub is unreachable
- [ ] Liquid-Glass / SnowBoard / FloatingDock compatibility shims

PRs welcome.

## Credits

- Wallpaper format and CAML decoding is reverse-engineered from Apple's
  PosterBoard / PosterKit on iOS 17.
- The `.tendies` ecosystem is built around tools by
  [@leminlimez](https://github.com/leminlimez) and friends — Pocket Poster,
  Nugget. PocketPoster is a 15-compatible cousin, not a fork.
- Online catalog source repo: [SerStars/Nugget-Wallpapers](https://github.com/SerStars/Nugget-Wallpapers).
