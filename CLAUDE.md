# TextLift

macOS menu-bar app that lifts text off the screen. Global shortcut → drag a
region → the text is on the clipboard, with a notification showing what was
copied. Built as a replacement for TRex (since removed from this machine), which
drops characters on small text and flattens tables into unusable blobs.

Bundle id **`com.dnz.lift`**. Requires **macOS 26** (the whole accuracy win
comes from a Vision API introduced in 26).

## Why it beats TRex

TRex uses `VNRecognizeTextRequest` (now `RecognizeTextRequest`) on the raw
captured pixels. Two things are wrong with that for screen text:

1. **No upscaling.** Vision's recognizer is trained on document-sized glyphs.
   11pt UI text is far below that, so characters get dropped.
2. **No document structure.** The line recognizer returns a flat list of text
   observations. A table comes back as interleaved fragments with no idea which
   number belonged to which row.

TextLift fixes both: Lanczos-upscale toward a 2200px long side (3x ceiling), then run
**`RecognizeDocumentsRequest`** (macOS 26+), which returns paragraphs, lists,
and *actual tables with rows and columns*.

### Measured (harness/, character error rate — lower is better)

| case                    | TRex-style | TextLift |
|-------------------------|-----------:|---------:|
| `table_normal`          |      58.6% |   **0%** |
| `table_norules`         |      58.6% |   **0%** |
| `table_small`           |      45.3% |   **0%** |
| `table_dark`            |      25.0% |   **0%** |
| `code_dark`             |       5.8% | **3.1%** |
| `code_scaled`           |       4.8% | **3.7%** |
| paragraphs (9 variants) |    0–0.5%  |  0–0.5%  |
| **mean over 17 cases**  |  **11.9%** | **0.7%** |

**7 wins / 10 ties / 0 losses.** Tables are where the whole difference lives; on
plain paragraphs the two are level, because Vision's line recognizer was
already good at that.

### Row integrity on real images (`harness/row_integrity.py`)

Character error rate misses the thing that actually breaks when OCR flattens a
table: the **pairing**. "Sodium 160mg" and "7%" can both be read perfectly and
still be useless if they end up on different lines. So this test asks one
question per row — did the label and its value survive on the same output line?
Images are real ones pulled from Wikimedia Commons, tested at native size and at
half size (a screenshot is smaller than a scan).

| image | rows | TRex-style | TextLift |
|---|---:|---:|---:|
| FDA nutrition label 2016 | 11 | 0/11 | **11/11** |
| …at half size | 11 | 0/11 | **11/11** |
| FDA nutrition label 2014 (% on the left) | 10 | 6/10 | **10/10** |
| …at half size | 10 | 2/10 | **10/10** |
| faded dot-matrix supermarket receipt | 14 | 0/14 | **10/14** |
| …at half size | 14 | 0/14 | **11/14** |
| **total** | **70** | **8/70 (11%)** | **63/70 (90%)** |

Re-download the images with the `curl` calls in `harness/real/` if that folder
is ever cleared.

## Things that were tried and removed

Keep these out unless there's new evidence — each was measured and hurt:

- **Contrast stretching + sharpening variants.** The idea was to rescue
  grey-on-grey and dark-mode text. Vision already normalises contrast
  internally, so pre-stretching only destroys information: the high-contrast
  variant scored **82.9%** character error on `extreme/x_dark_faint`, which the
  plain upscale read *perfectly*. Sharpening was a wash.
- **Upscaling past 3x.** A 4x or 6x ceiling scored consistently worse than 3x
  across 23 cases. Lanczos starts inventing detail Vision then has to see
  through. `targetLongSide` above ~1800 makes no measurable difference because
  the 3x cap binds first on typical selections.
- **Multi-variant scoring** (run 3 preprocessing recipes, keep the best by
  `chars × confidence`). Measured *worse* than just always using the plain
  upscale (0.9% vs 0.7% mean CER) — the score is dominated by character count,
  and the aggressive variants find slightly more junk characters. Also 3× the
  work. Removed in favour of one pass.

## Architecture

| file | role |
|---|---|
| `main.swift` | AppKit entry, `.accessory` policy (no Dock icon) |
| `AppDelegate.swift` | menu-bar item, hot key, capture→OCR→clipboard flow |
| `Capture.swift` | spawns `/usr/sbin/screencapture -i -x -o`, loads the PNG |
| `Preprocess.swift` | the Lanczos upscale (and the note on what not to add) |
| `OCREngine.swift` | `RecognizeDocumentsRequest` + line-recognizer fallback + rendering |
| `ResultWindow.swift` | editable preview, format switcher, thumbnail |
| `Notify.swift` | capture banner, `LinkPolicy`, QR link extraction |
| `SettingsView.swift` | `Settings` store + SwiftUI settings panel + `ShortcutField` |
| `HotKeyManager.swift` | Carbon `RegisterEventHotKey` (no Accessibility prompt) |
| `ShortcutSettings.swift` | `Shortcut` struct (key code + modifiers) and its `UserDefaults` store |

Copied from ClipPiP: `HotKeyManager`, `ShortcutSettings` (hot-key signature
changed to `'TXLF'`). The shortcut recorder was rewritten as `ShortcutField`
inside `SettingsView.swift` to match the Mirror / Clipboard Manager house
pattern (SwiftUI `Form` + `NSViewRepresentable` recorder).

## Menu

Deliberately minimal — **Capture Text**, the shortcut hint, **Settings…**, **Quit**.
Everything else lives in Settings. There is no "Copy Last" / "Show Last": the
result is copied automatically, so those were dead weight. Menu-bar icon is the
SF Symbol `document.viewfinder`.

## Settings

Menu-bar → **Settings…** (⌘,). One `Settings` singleton (`ObservableObject`,
`UserDefaults`-backed) is the only source of truth.

| setting | default | notes |
|---|---|---|
| Capture shortcut | ⌃⌥T | click the field, press keys. Needs ⌘/⌥/⌃. Re-registers live; alerts if the OS refuses the combo |
| Tables become | Markdown | Markdown / Tabs (Sheets) / Plain |
| Copy automatically | on | |
| Show result window | **off** | the capture is copied and a banner shows it, so the window is opt-in |
| Notification with the copied text | on | plus a **Send a Test Notification** button |
| Read QR codes and barcodes | on | costs ~0ms when there is no code |
| Links in QR codes | Ask first | Never / Ask first / Open it |
| Launch at login | off | `SMAppService.mainApp`; the toggle snaps back if registration throws |

Changing the format re-renders from the stored `DocumentObservation`s — no
re-OCR.

## QR codes and barcodes

`RecognizeDocumentsRequest.barcodeDetectionOptions` is switched on when the
setting is enabled, and payloads come back on `container.barcodes`. A decoded
payload is placed **above** the recognised text — if a QR code is in frame it is
almost always the point of the capture.

`QRLink.firstWebLink` only ever returns **http/https** URLs. A QR code is
untrusted input from whatever happened to be on screen, and handing an arbitrary
scheme to `NSWorkspace.open` would let a crafted code launch other apps or
trigger system handlers. Verified against generated codes: an https payload is
offered for opening; `WIFI:`, `mailto:` and plain-text payloads are decoded and
copied but never treated as openable.

## Icon

`make_icon.py` generates the full macOS icon set into
`TextLift/Assets.xcassets/AppIcon.appiconset`. Follows the house recipe in
`/Users/moshe/Apps/CLAUDE.md`: 1024 full bleed, vertical teal gradient (lighter
at the top), one flat centred glyph — scan-frame corner brackets around three
left-aligned amber text bars. Teal because no other app in the lineup uses it.
Re-run `python3 make_icon.py` after editing.

### Flow

1. Hot key (default **⌃⌥T**) → `Capture.selectRegion()` shells out to
   `screencapture -i`, which gives the standard macOS crosshair. Esc writes no
   file, which is how cancellation is detected.
2. `Preprocess.prepared` upscales.
3. `OCREngine.scan` runs the document request **and** the line request
   concurrently on the upscaled image. The document result wins unless it read
   under 80% as many characters as the line pass — that guard only fires when
   document segmentation fails outright, so structure is never traded away for
   a couple of stray characters.
4. `DocumentRenderer.render` walks the container, emits tables as markdown or
   TSV, and orders every block by its bounding box (Vision's normalized origin
   is **bottom-left**, so larger y is higher on screen).
   - **Row reconstruction.** When the document pass finds *no* table but the
     layout is plainly columnar, rows get rebuilt from geometry instead
     (`columnarGrid`). Receipts and nutrition labels put the label and its number
     at opposite edges of a wide gap; Vision reports those as two separate
     observations, and neither the document parser nor plain line ordering puts
     them back together — you get every label, then every number. Grouping
     observations by vertical overlap and sorting by x fixes it, and took real
     row integrity from 11% to 90%. Guarded so prose can't trip it: needs ≥6
     observations, ≥3 rows with a real horizontal gap (>4% of width), and those
     rows must be ≥25% of all rows.
   - Blank lines between blocks follow the **measured vertical gap** (>0.7× the
     typical block height), not a blanket `\n\n` — otherwise a list of short UI
     labels comes out double-spaced.
   - Table columns that are empty in every row are dropped: icons, checkboxes and
     toggles otherwise show up as empty cells.
   - `deIcon` strips a leading glyph from an **all-caps heading** (a pencil icon
     next to "SPECIFICATIONS" arrives as `@`). Kept deliberately narrow: a wider
     rule was measured and *hurt* — dropping any lone non-alphanumeric line ate
     the `}` lines out of captured code (medium suite 1.4% → 2.0% CER, 3 wins → 2
     losses), and stripping any leading glyph mangled `} else {`. Stray icon
     characters that aren't next to a heading are left in.
5. Text goes to the clipboard immediately, a banner shows what was copied, and
   the result window is for checking. Clicking the banner reopens the result.
6. If a QR code was decoded and holds an `http(s)` link, `LinkPolicy` decides
   whether to ignore it, ask, or open it.

Paragraph text is also reported *inside* table and list regions, so the
renderer drops paragraphs whose centre falls in a table/list box — otherwise a
receipt comes out twice.

## Output formats

Menu → Table Format, or the popup in the result window. Switching re-renders
from the stored observations (no re-OCR) and re-copies.

- **Markdown** — GitHub tables, first row as header.
- **Tabs (Sheets)** — TSV, pastes straight into Numbers/Excel/Sheets.
- **Plain** — every line top-to-bottom, no structure. Use when the document
  parser guesses a table that isn't one.

## Harness

Offline accuracy testing, no GUI needed. Everything compiles the *shipping*
`Preprocess.swift` / `OCREngine.swift`, so numbers reflect real behaviour.

```bash
cd "/Users/moshe/Apps/TextLift/harness"
xcrun swiftc -O -target arm64-apple-macos26.0 -parse-as-library \
  compare.swift ../TextLift/Preprocess.swift ../TextLift/OCREngine.swift -o compare

python3 gen_cases.py cases      # clean synthetic paragraphs + tables
python3 gen_hard.py  cases      # scaled-down, JPEG'd, gradient, code
python3 gen_extreme.py extreme  # faint / noisy / heavily degraded

python3 score.py  cases         # baseline vs TextLift, CER per case
python3 oracle.py cases         # + "TRex engine on our upscaled pixels" column
python3 sweep.py  cases extreme # tune targetLongSide / maxScale (slow, ~5 min)
python3 row_integrity.py        # real Wikimedia images: do table rows stay paired?
```

`compare <baseline|baseline-up|textlift> <image.png> [markdown|tsv|plain]`
prints the recognised text on stdout and `chars=/conf=/engine=/ms=` on stderr.

`Preprocess` reads `TEXTLIFT_TARGET` and `TEXTLIFT_MAXSCALE` from the
environment so the sweep can drive the real code path.

Typical scan is **~400ms** for a normal selection.

Known remaining losses, both degenerate and both accepted: `extreme/x_jpeg_bad`
(quality-14 JPEG) and one medium code case. Neither reflects a real capture.

## Redeploy

`open` on a still-running app just re-activates the **stale** instance, so a
rebuild appears to do nothing. Use `./redeploy.sh` — it quits, waits for the
process to actually die, replaces the bundle, relaunches, and verifies.

## Bugs that cost real time — don't reintroduce these

1. **Lazily-decoded CGImage + deleted temp file.** `CGImageSourceCreateImageAtIndex`
   on a *file* source returns an image that keeps reading pixels from disk on
   demand. The obvious `defer { try? FileManager.default.removeItem(at: url) }`
   after grabbing the screenshot therefore handed Vision a **blank white image**
   and zero characters — with no error logged anywhere, so it presented as
   "No text found in that selection." `Capture.selectRegion` now reads the bytes
   into `Data` first and decodes from memory.
2. **Ad-hoc code signing breaks Screen Recording on every rebuild.** macOS ties
   the TCC grant to the app's code identity; `CODE_SIGN_IDENTITY="-"` changes it
   each build, so permission silently lapses and `screencapture` starts returning
   wallpaper-only images. `redeploy.sh` signs with **Developer ID Application**
   (team `VWR39LZW5M`) so the grant survives. If permission is ever lost, the app
   is added back via System Settings → Privacy & Security → Screen & System Audio
   Recording → **+** → `/Applications/TextLift.app`.
3. **`redeploy.sh` used to install a stale binary after a failed build** — the
   `-x` existence check passes on the previous build's product. It now greps the
   build log for `BUILD SUCCEEDED` before installing.
4. **A dismissed notification prompt poisons the bundle id, permanently.**
   Pressing Esc while the "would like to send you notifications" prompt is up
   records a **denial**, and from then on `requestAuthorization` returns
   `"Notifications are not allowed for this application"` *instantly, with no
   prompt, forever*. The app never appears in System Settings → Notifications, so
   there is nothing to switch back on. Deleting the row from usernoted's db,
   restarting `usernoted`, and re-signing all fail to clear it.

   The denial is keyed to the **lower-cased** id, so `com.DNZ.textlift` and
   `com.dnz.textlift` are the same record — renaming between those cases changes
   nothing. The only fix found was a genuinely new identifier.

6. **A renamed bundle id leaves a TCC row that hijacks the new one.** After
   renaming, System Settings' **+** picker appeared to add the app but the grant
   never took: `tccd` wrote it against the *old* client key while the row's code
   requirement had been rewritten to point at the *new* identifier. So the app
   asked "am I allowed?" under its own id, found no row, and got denied — with
   the settings list showing it as enabled. Visible in
   `log show --predicate 'process == "tccd"'` as a `client=` / `CodeReq …
   identifier` mismatch.

   `tccutil reset` can't clear it (it refuses ids no installed app claims) and
   `TCC.db` is read-only under SIP. The only way out is *another* fresh
   identifier that no stale row's requirement matches — hence `com.dnz.lift`.
   The dead `com.DNZ.textlift` / `com.dnz.textlift` rows are harmless leftovers.

   **Lesson: don't rename a shipped bundle id casually.** Each rename costs both
   Screen Recording and Notifications, and can strand permissions permanently.

   **Never drive the keyboard while a permission prompt could be open.** Probe
   the state read-only instead — `getNotificationSettings` reports the status and
   can never pop a prompt:

   ```
   0 = notDetermined (would prompt)   1 = DENIED (poisoned)   2 = authorized
   ```

   Changing the bundle id also resets **Screen Recording**, since TCC keys on it.
5. **Two bundles with the same id confuse Launch Services.** The build product
   and the installed copy were both registered, so `TextLift.app` appeared twice
   in file pickers and Spotlight. Derived data now goes to **`build.noindex/`** —
   a `.noindex` suffix keeps Spotlight and Launch Services out of it — and
   `redeploy.sh` also `lsregister -u`s the build copy explicitly. Verify with
   `lsregister -dump | grep -oE '/[^ ]*TextLift\.app' | sort -u`; it should print
   exactly one path.
6. **CoreImage's Lanczos resize rendered blank inside the app bundle** while
   working in the harness (the grab carries a Display P3 profile and alpha, and
   `CIContext.createCGImage` produced empty RGB). Replaced with a plain
   CoreGraphics redraw into an explicit sRGB no-alpha bitmap; accuracy went
   *up*, not down.

## Notes / gotchas

- `project.pbxproj` is hand-written. **No xcodegen.**
- Diagnostics: `log show --predicate 'subsystem == "com.DNZ.textlift"' --last 10m --info --style compact`.
  **`--info` is required** — the Logger calls are info-level and are invisible
  without it, which looks exactly like "the code never ran".
- The last capture is kept at `$TMPDIR/textlift-last-capture.png` for inspection.
- Deployment target is **26.0** — `RecognizeDocumentsRequest` does not exist
  before that, and it is the entire point of the app.
- Screen Recording permission is required. TCC attributes the spawned
  `screencapture` to TextLift, so the prompt names TextLift. Checked via
  `CGPreflightScreenCaptureAccess()` on launch and before every capture.
- The result window is ordered out before the crosshair appears; leaving it key
  swallows the selection drag.
- Confidence numbers from `RecognizeDocumentsRequest` run much lower (~55-60%)
  than `RecognizeTextRequest` (~95%+) on identical input. They are **not**
  comparable across the two request types — don't use confidence to choose
  between engines.
