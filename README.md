# SaddleTrace

Measure a horse's back with a single LiDAR shot.

SaddleTrace is an iPhone app for saddle fitters. You stand beside the animal, frame the
saddle area, and take one shot. From that single frame it builds a dense 3D surface of
the back at true metric scale, paints it with the photograph, finds the spine, and cuts
cross-sections you can print at true scale and lay against a tree.

**Status:** version 1.0 submitted to the App Store, awaiting review.

---

## Why one shot

An earlier version swept the phone along the animal and fused ARKit's scene mesh across
frames. It kept failing: the fused mesh is sparse, re-tessellated between frames, and
drifts over a long session, and horses do not hold still. Reconstruction from those
fragments regularly produced something unrecognisable.

The current approach throws all of that away. A single ARKit `sceneDepth` frame is
already a dense 256×192 depth map with per-pixel confidence, captured in one instant —
no fusion, no drift, no stitching. Unprojected against the camera intrinsics it gives
roughly 50,000 measured points covering the ~20 inches of back that a saddle actually
sits on. That turned out to be both more robust and more accurate than the sweep it
replaced.

Because every mesh vertex corresponds to exactly one depth pixel and one camera pixel,
colouring the surface with the photograph is a direct lookup rather than a multi-view
texture bake.

## The pipeline

```
ARFrame (sceneDepth + capturedImage)
  └─ DepthGridMesh          unproject, 3×3 median filter, drop low-confidence and
                            far samples, triangulate the pixel grid, drop quads that
                            span a depth discontinuity, keep the largest connected
                            component, clip ground below the crest, sample vertex
                            colours from the YCbCr frame
       ↓  (Y-up → Z-up)
  └─ MeshKit                LongAxisPCA        orient the back onto +X
                            SpineCurveFitter   crest per slab by maximum L/R symmetry
                            LandmarkDetector   withers and tail base
                            ROICropper         trim to the region of interest
                            CrossSectionExtractor
                            SectionMetrics     width, tree angles, rocker
       ↓
  └─ ExportKit              PDF · DXF · CSV · STL · PLY · USDZ
```

The spine is found by symmetry rather than by taking the highest vertex per slice. A
single noise spike used to hijack the crest and throw every downstream section
off-centre; searching each slab for the lateral position that minimises the squared
difference between mirrored pairs of the top envelope is far harder to fool.

## Requirements

- iPhone with a LiDAR scanner — iPhone 12 Pro or later, Pro and Pro Max models
- iOS 26.5 or later
- Xcode 26 with the iOS 26.5 SDK, Swift 6 language mode

The deployment target is deliberately current. Capture is device-only: the simulator has
no LiDAR, so a scan cannot be recorded there. Existing scans can be imported and viewed
on any iPhone, including in the simulator, because the geometry pipeline re-derives
everything from the saved depth data without touching the camera.

## Repository layout

```
SaddleTrace/            app target — capture, storage, views, processing
  Capture/              ARKit and TrueDepth capture, depth→mesh, frame writers
  Model/                animal and scan records, file store, archive import/export
  Processing/           the app-side driver over MeshKit and ExportKit
  Views/                SwiftUI screens, SceneKit viewers, charts
Packages/MeshKit/       pure geometry — Foundation + simd only, no Apple frameworks
Packages/ExportKit/     file-format writers, depends on MeshKit
SaddleTraceTests/       app-module unit tests
SaddleTraceUITests/     XCUIAutomation smoke tests
docs/                   privacy policy and support pages (GitHub Pages)
```

`MeshKit` is deliberately free of platform dependencies. It is the part where the
geometry can be wrong in ways that are hard to see on a phone screen, so it is
deterministic, runs on a synthetic back fixture, and is testable from the command line
without Xcode or a device.

## Building

Open `SaddleTrace.xcodeproj` and run. The two local packages resolve by path; there are
no external dependencies.

To build for a device from the command line:

```sh
xcodebuild -scheme SaddleTrace \
           -destination 'platform=iOS,id=<device-id>' \
           -allowProvisioningUpdates build
```

## Testing

The geometry and export packages test standalone, with no simulator or device:

```sh
cd Packages/MeshKit   && swift test    # 34 tests
cd Packages/ExportKit && swift test    # 11 tests
```

App-module tests run against a simulator through Xcode.

## Coordinate convention

`MeshKit` works in a **Z-up** frame, which is the convention DXF, CAD and Blender expect:

| Axis | Direction |
|------|-----------|
| +X | cranio-caudal, along the spine |
| +Y | lateral |
| +Z | vertical |

ARKit hands back a Y-up world, so Y and Z are swapped at the capture boundary. Inside
`MeshKit` the long-axis PCA runs in XY and the spine is the crest in Z.

## Exports

| Format | Contents |
|--------|----------|
| PDF | Cross-section fan, topline and rocker, embedded 3D model, at an exact stated scale with a printed scale bar |
| DXF | Section outlines, one layer per station, in centimetres |
| CSV | Section outlines, and every computed metric per station |
| STL | Surface geometry for CAD and 3D printing |
| PLY | Painted surface with per-vertex colour |
| USDZ | Surface for Quick Look |

Stations are numbered from the withers, which is station 0, and every distance reported
in the app and on the report is measured from there.

## Scale

Measurements are real. ARKit's world poses and LiDAR depth are metric, so distances,
widths and angles come out in true units without any calibration step. `MeshKit` treats
all coordinates as metres. The app displays inches or centimetres according to a
setting; exports are always centimetres.

## What this is not

SaddleTrace is a measuring instrument for people who already know how to fit a saddle.
It records the shape of a back accurately and repeatably so that an animal can be
compared against itself over time, or against a tree in hand. It does not recommend a
saddle, and it is not a veterinary or diagnostic tool.

## Links

- [Privacy policy](https://michael-prange.github.io/SaddleTrace/privacy.html)
- [Support](https://michael-prange.github.io/SaddleTrace/support.html)

## License

Copyright © 2026 Michael Prange. All rights reserved.

This source is published for reference. No license to use, copy, modify or distribute it
is granted.
