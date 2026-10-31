# SheetFeed

A native Apple silicon scanning app for the Epson ES-50 (and, likely, other scanners with a macOS Image Capture
driver). It drives the scanner through Apple's ImageCaptureCore framework and Epson's universal ES-50 driver
(`/Library/Image Capture/Devices/EPSON ES017E.app`), so it needs no Rosetta.

## Using it

1. Plug in the scanner and open **SheetFeed** (installed in `~/Applications`). The status bar turns green when it's ready.
2. Insert a page and click **Scan** (⌘↩), or press the scanner's button. Feed the next page and scan again.
   With **Auto-feed** on, each page scans as soon as you insert it.
3. Reorder pages by dragging them in the sidebar; rotate (⌘L / ⌘R) or delete (⌫) the selected page.
4. **Save…** (⌘S) to choose a name and place, **Quick Save** (⌥⌘S) to save to your Quick Save folder with a date-and-time
   name, **Share** for Mail/Messages/AirDrop, or **Print** (⌘P).

## Features

| | |
|---|---|
| Scan | 150 / 200 / 300 / 600 dpi; Color, Grayscale, Black & White; Auto, Letter, Legal, A4, A5 |
| Clean up | Trims the dark feeder backing and blank fill around narrow or short pages; straightens crooked pages; skips blank pages |
| Assemble | Multi-page documents; drag to reorder; rotate; delete |
| Save | PDF (optionally searchable, with on-device text recognition), multi-page TIFF, JPEG or PNG per page; High/Medium/Low quality |
| Send | Share sheet (Mail, Messages, AirDrop, Notes…), Print |

Grayscale and black & white are made from a color scan on the Mac rather than by the scanner, because 8-bit color is
the mode confirmed to work with this driver. Black & white pages are stored as 1-bit images, which keeps PDFs small.

## Building

Requires macOS 14+ and Xcode (Swift 6 toolchain).

```bash
swift test --scratch-path ~/Library/Caches/SheetFeed/build   # unit tests, no scanner needed
./build-app.sh                                               # builds, signs (ad hoc) and installs ~/Applications/SheetFeed.app
```

The app icon is drawn in code by `Icon/make-icon.swift`. After changing it, regenerate the PNG and rebuild:
`swift Icon/make-icon.swift Icon/AppIcon-1024.png && ./build-app.sh`.

Build output goes to `~/Library/Caches/SheetFeed` because code signing rejects the Finder metadata that an
iCloud-synced Documents folder adds to files.

`Tests/ScanKitTests/RealScanTests.swift` runs the cleanup and text recognition on a real scan when
`SHEETFEED_SAMPLE` points at one (scans are not kept in the repository).

## Layout

- `Sources/ScanKit` — scanner-independent processing: margin trimming, straightening, blank detection, color conversion,
  text recognition, PDF/TIFF/JPEG/PNG export. Unit tested.
- `Sources/SheetFeed` — the app: `ScannerController` (ImageCaptureCore), `AppModel` (pages, settings, saving),
  `ContentView` (SwiftUI).

## Status

Verified on a MacBook Pro (Apple silicon, macOS 27.0.1) with an ES-50 over USB: the app connects, scans a page and
cleans it up. Unit tests cover processing and export, including a searchable PDF.

Not yet tried with the scanner: auto-feed (it relies on the driver reporting when paper is inserted), the scanner's
button, saving, sharing and printing from the app, and multi-page sessions. Epson's driver reports two-sided scanning
for the ES-50, which only scans one side; SheetFeed turns that off.

Not included compared with Epson ScanSmart: direct upload to cloud services (use Share, or a Quick Save folder inside
iCloud Drive/Dropbox), Word/Excel conversion, and brightness/contrast controls.
