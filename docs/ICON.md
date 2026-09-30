# Icon

A clean **placeholder** is shipped (vector, adaptive, monochrome) and matches the spec below. Replace it with final artwork when available.

## Spec
* Geometric **A** built from **three connected nodes**: Trigger (bottom-left) → Intelligence (apex) → Action (bottom-right).
* A subtle **orbital line** through the centre (automation loops).
* Dark base `#07090C`, electric cyan/teal `#22E3D3`, subtle violet `#8B7CFF`. No text.
* Recognisable at 24 px; works as an Android adaptive icon (keep the mark inside the central 66 dp of 108 dp) and as a monochrome/themed icon.

## Files
| File | Purpose |
|---|---|
| `android/app/src/main/res/drawable/ic_launcher_foreground.xml` | adaptive foreground |
| `…/drawable/ic_launcher_background.xml` | adaptive background |
| `…/drawable/ic_launcher_monochrome.xml` | Android 13 themed icon |
| `…/drawable/ic_notification.xml` | status-bar icon (white) |
| `…/mipmap-anydpi-v26/ic_launcher.xml`, `…/mipmap/ic_launcher.xml` | launcher entries (API 26+ / 24–25) |
| `assets/branding/autometa_icon_placeholder.svg` | source SVG |

## Using your own image
Put a 1024×1024 PNG at `assets/branding/icon.png` (plus a transparent foreground at `assets/branding/icon_foreground.png`), add `flutter_launcher_icons` as a dev dependency with `adaptive_icon_background: "#07090C"`, `adaptive_icon_foreground`, `adaptive_icon_monochrome`, and run `dart run flutter_launcher_icons`. Then delete the `mipmap/ic_launcher.xml` fallback so the generated PNGs are used.
