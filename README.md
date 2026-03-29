# prawdec

Transcodes Apple ProRes RAW into Cinema DNG.

This branch is the current Swift rewrite. The legacy experimental implementation has been preserved on the `deprecated` branch.

## Status

This project is still evolving, but the current codebase already includes:

- A modern SwiftUI macOS app shell
- Queue-based batch conversion flow
- Pause, resume, and cancel control
- ProRes RAW metadata parsing on macOS via AVFoundation
- Color-metadata resolution with explicit fallback behavior
- Adobe DNG SDK based writing pipeline
- Support for:
  - JPEG Lossless
  - JXL Lossless
  - JXL Lossy Mosaic
  - JPEG Lossy RGB (linear pseudo-RAW)

## Color Handling

The converter is designed around DNG's color model rather than exposing ad hoc matrix options in the UI.

- `AsShotNeutral` is derived from ProRes RAW white-balance factors when available.
- When sufficient metadata exists, the converter removes baked channel white balance and chromatic adaptation before building DNG-appropriate color transforms.
- When metadata is incomplete, the converter degrades explicitly instead of silently guessing a higher-fidelity model than the source can support.
- Unknown CFA / Bayer pattern values are rejected with an error. The app currently supports standard 2x2 Bayer patterns only.

## Repository Layout

- `/prawdec`: app source
- `/ThirdParty/DNGSDK`: vendored Adobe DNG SDK headers and static library
- `/prawdec.xcodeproj`: Xcode project

Release-excluded local content such as footage and working documentation is intentionally not part of this branch.

## Requirements

- macOS
- Xcode with Apple SDKs that include ProRes RAW decoding support

The Adobe DNG SDK dependency is already vendored into this repository.

## Build

Open `prawdec.xcodeproj` in Xcode, or build from the command line:

```bash
xcodebuild -project prawdec.xcodeproj -scheme prawdec -configuration Debug -sdk macosx build CODE_SIGNING_ALLOWED=NO
```

## Notes

- This source tree is prepared as a publishable app repository and does not include bundled footage, private working docs, or test targets.
- The legacy Objective-C prototype remains available on the `deprecated` branch for reference.
