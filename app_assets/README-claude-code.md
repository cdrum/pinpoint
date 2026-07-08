# Pinpoint — App Assets (for Claude Code)

Custom art + asset-catalog config for the Pinpoint macOS app. Everything here is drop-in for
`Assets.xcassets`.

## What's in this folder
```
app_assets/
├─ AppIcon.appiconset/          ← full macOS app icon set (drop into Assets.xcassets)
│  ├─ Contents.json
│  ├─ icon_16.png   (16pt @1x)
│  ├─ icon_32.png   (16@2x / 32@1x)
│  ├─ icon_64.png   (32@2x)
│  ├─ icon_128.png  (128@1x)
│  ├─ icon_256.png  (128@2x / 256@1x)
│  ├─ icon_512.png  (256@2x / 512@1x)
│  └─ icon_1024.png (512@2x)
├─ AccentColor.colorset/        ← system-blue accent (light 007AFF / dark 0A84FF)
│  └─ Contents.json
└─ AppIcon-AppStore-1024.png    ← flattened, full-bleed 1024 for App Store Connect (NOT in the app bundle)
```

## Design tokens
- **Accent (light):** `#007AFF`   **Accent (dark):** `#0A84FF`
- **Icon gradient:** top `#3D93FF` → bottom `#0A63DB`, white location pin
- App uses SF Symbols for all UI glyphs (no other custom art required).

---

## Instructions to give Claude Code

Paste something like this into your Claude Code session (adjust the repo/target names):

> I've added a folder `app_assets/` to the repo with the app icon and accent color for our macOS
> app "Pinpoint". Please wire them into the Xcode project:
>
> 1. **App icon.** Replace the existing `AppIcon.appiconset` inside `Assets.xcassets` with the one
>    in `app_assets/AppIcon.appiconset/` (copy the PNGs *and* its `Contents.json`). It's a macOS
>    icon set (mac idiom, 16→512 @1x/@2x). Confirm the target's
>    `ASSETCATALOG_COMPILER_APPICON_NAME` build setting is `AppIcon`.
> 2. **Accent color.** Copy `app_assets/AccentColor.colorset/` into `Assets.xcassets`. Set the
>    target's `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME` to `AccentColor` so SwiftUI's
>    `.tint`/controls pick it up automatically. In SwiftUI, reference it as `Color("AccentColor")`
>    (or `Color.accentColor`).
> 3. **App Store icon.** Don't bundle `AppIcon-AppStore-1024.png` in the app — keep it for
>    App Store Connect's 1024×1024 marketing icon slot when we submit.
> 4. Build and run; verify the Dock/Finder icon and control tints look right in both light and
>    dark mode.

### Notes / gotchas
- The macOS icons already include the rounded-rectangle shape, margin, and drop shadow baked in —
  macOS does **not** mask macOS-idiom icons, so do not add rounding in code.
- The App Store 1024 is the opposite: full-bleed, opaque, no transparency — required by App Store
  Connect (it masks corners itself). Don't swap the two.
- If Xcode complains about "unassigned children" after import, it usually means a filename in
  `Contents.json` doesn't match a PNG in the folder — they're matched here, so a clean copy of the
  whole `.appiconset` folder avoids it.
- Regenerating: the icon is drawn programmatically (blue squircle + white map pin). If you want a
  tweak (different blue, bigger pin, no gradient), ask and I'll regenerate all sizes.
