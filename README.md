# PocketPlayer

PosterBoard-style **animated lockscreen wallpapers** for **iOS 15** (Dopamine /
palera1n rootless jailbreaks).

<p align="center">
  <img src="https://github.com/user-attachments/assets/d3405d66-dc54-445c-8a98-d9b808e03fd6" width="320" alt="PocketPlayer demo">
</p>


It loads `.ca` "tendies" bundles (the same format Apple uses for PosterBoard on
iOS 17+) — `main.caml` describes a `CALayer` tree, `assets/` contains the PNGs,
and `<states>` describe Locked / Unlocked snapshots. PocketPlayer interpolates
between those states based on the swipe-to-unlock progress.

```
SBCoverSheetWindow
└── CSCoverSheetView                ← we attach our layer tree here
    └── PocketPlayerLayer (z=-1)
        └── <CAML root>
            ├── Shape Layer (background)
            ├── Bottom_chest.png
            ├── Top_chest.png       ← these animate via Locked/Unlocked states
            ├── Lock.png
            └── ...
```

---

## Repo layout

| Path                      | What                                                        |
| ------------------------- | ----------------------------------------------------------- |
| `Tweak.x`                 | MobileSubstrate hooks for SpringBoard                       |
| `CAMLParser.{h,m}`        | XML parser for `.caml` (states + layer tree)                |
| `Makefile`, `control`     | Theos build config (rootless, iOS 15+, arm64 / arm64e)      |
| `PocketPlayer.plist`      | Filter — load only into `com.apple.springboard`             |
| `scripts/setup.sh`        | One-time WSL setup (Theos + iOS 15 SDK)                     |
| `scripts/deploy.sh`       | Build + scp + dpkg -i + respring                            |

---

## Quick start (WSL / Linux)

```bash
git clone https://github.com/kirayxa2/PocketPlayer.git
cd PocketPlayer

# 1) one-time: install Theos + SDK
bash scripts/setup.sh
source ~/.bashrc        # picks up THEOS env

# 2) drop a wallpaper bundle on the device:
#    /var/mobile/Library/PosterPlayer/active/versions/1/contents/<name>.wallpaper/
#       └── <name>_Floating-390w-844h@3x~iphone.ca/
#             ├── main.caml
#             └── assets/*.png

# 3) build + ship
PP_HOST=mobile@192.168.0.112 PP_KEY=~/.ssh/iphone ./scripts/deploy.sh

# 4) live-tail the on-device log while you swipe
./scripts/deploy.sh tail
```

`PP_HOST` / `PP_KEY` default to `mobile@192.168.0.112` and `~/.ssh/iphone`.

> **sudo without password** on the phone (one-time, recommended):
> `echo "mobile ALL=(ALL) NOPASSWD: ALL" | sudo tee /var/jb/etc/sudoers.d/mobile`

---

## How progress is captured (no more guessing classes)

In iOS 15.x point releases the lockscreen presentation progress is reported by
*one of* these private classes, never the same one across phones:

- `CSCoverSheetViewController _updatePresentationProgress:withOffset:presentationState:`
- `SBCoverSheetSlidingViewController` *(same selector)*
- `SBDashBoardViewController` *(same selector, older 15.0/15.1 builds)*

We hook **all three** in one `.x` file, so whichever exists at runtime gets matched
by the substrate runtime. There is **also a fallback**: if none of the three fire
within a frame, a `CADisplayLink` reads `presentationLayer.position.y` of the
cover-sheet view directly and derives progress geometrically. So the animation
will always have *some* signal driving it, and you don't need to rebuild to "try
another class".

A small red debug label in the top-left shows which path is live and the
current progress value (toggle with `kPPDebugLabel = NO` in `Tweak.x`).

---

## Wallpaper format (`.ca` bundle)

```
Foo.wallpaper/
└── Foo_Floating-390w-844h@3x~iphone.ca/
    ├── main.caml          ← CAML XML
    └── assets/
        ├── Bottom_chest.png
        ├── Top_chest.png
        └── ...
```

`main.caml` is plain XML:

```xml
<caml xmlns="http://www.apple.com/CoreAnimation/1.0">
  <CALayer id="root" name="Root Layer" bounds="0 0 390 844" position="195 422">
    <sublayers>
      <CALayer id="lid" name="Top_chest.png" bounds="0 0 390 111" position="195 334">
        <contents><CGImage src="assets/Top_chest.png"/></contents>
      </CALayer>
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

Supported attributes / keypaths: `bounds`, `position`, `anchorPoint`,
`opacity`, `hidden`, `cornerRadius`, `backgroundColor`, `geometryFlipped`,
`contentsGravity`, `transform.rotation.{x,y,z}`, `transform.scale[.x|.y]`.

Supported `<value type="...">`: `integer`, `real`, `point`, `size`, `rect`, `color`.

Animations and `<modules>` are ignored — only the discrete `Locked` / `Unlocked`
state deltas are interpolated. That's enough to reproduce 90% of community
wallpapers.

---

## Roadmap / known gaps

- [ ] Settings UI for picking a wallpaper from `~/Library/PosterPlayer/library`
- [ ] Multi-state transitions (Sleep / Charging) — currently only Locked↔Unlocked
- [ ] CAML `<animations>` block (key-frame curves)
- [ ] Text / gradient layers
- [ ] CAShapeLayer paths

PRs welcome.
