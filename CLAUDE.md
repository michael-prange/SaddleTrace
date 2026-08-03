# SaddleBack — Working Agreement & Project Notes

App implements `Design.MD` (working title in doc: *EquineBackScanner*). iOS 26.x,
LiDAR + photogrammetry equine back scanner. Product name: **SaddleBack**.

## How we work together
- **Senior-dev partnership.** Guide architecture; challenge weak approaches, propose better ones.
- **NO markdown summary documents.** Never create `.md` files to summarize completed work. (This file and `Design.MD` are the only sanctioned docs.)
- **Token efficiency.** No verbose prose or restating what code already says.
- **Authorize before coding.** Analyze → propose options with tradeoffs → wait for decision → implement. Exception: illustrative snippets < 10 lines.
- **Scope discipline.** Only change what was asked.

## Code style
- Swift 6, strict concurrency. PascalCase types / camelCase members. 4-space indent.
- `@State private var` for SwiftUI state; `let` for constants. Avoid force-unwrap.
- Prefer async/await over Combine. Comment only non-obvious logic.
- Testing framework for unit tests; XCUIAutomation for UI tests.

## Xcode integration
- Use `xcode-tools` MCP (`BuildProject`, `XcodeRefreshCodeIssuesInFile`, `RunCodeSnippet`, `DocumentationSearch`) over shell.
- `DocumentationSearch` for new APIs: Liquid Glass, FoundationModels, latest SwiftUI, ARKit/RealityKit 26.

## Architecture (target)
Local SPM packages: `CaptureKit`, `ReconstructionKit`, `MeshKit`, `ExportKit` + app target.
See `Design.MD` §5, §14. `MeshKit` is pure (Foundation + simd), deterministic —
validated standalone via `swift test` in `Packages/MeshKit/`, no Xcode/device needed.

**Do NOT edit `project.pbxproj`** — Xcode is open and will crash. When a package
must be linked to a target, give Michael the Xcode UI steps to do it himself.

### Coordinate convention (deviation from Design.MD)
MeshKit works in a **Z-up** frame (CAD/DXF/Blender-friendly), *not* the doc's Y-up:
- +X cranio-caudal (long axis) · +Y lateral · +Z vertical/up.
ARKit gives Y-up; swap Y↔Z at the capture→MeshKit boundary. PCA long-axis runs in
XY; spine = max-Z per slice.

## Critical risks
- **P0 (Design §12.1):** iPhone 17 Pro `PhotogrammetrySession` regression (`cv3dapi 4004`).
  Custom sample-iterator path must be verified early on-device. Release-blocking.

## Capture (§6) — device-only
- 2026-08-01: Live capture screen built IN-APP (Capture/): `ARCaptureView`
  (RealityKit ARView, world tracking + `.meshWithClassification` scene recon,
  `.showSceneUnderstanding` for live mesh), `CaptureModel` (depth-centre sample
  ~10Hz → too close <40cm / just right 40–80 / too far >80 + haptic ticks),
  `DistanceHUD` (vertical gauge, units-aware), `CaptureView` (full-screen; on
  non-LiDAR/sim shows "LiDAR Required" + **Use Demo Scan** fallback).
  Flow: New Scan → instructions → CaptureView (fullScreenCover) → Finish → record.
  Compiles; NOT runtime-verified (sim has no LiDAR). Frame-save + reconstruction
  still TODO — Finish records a scan that still processes the SYNTHETIC mesh.
- ⚠️ REQUIRES build setting `INFOPLIST_KEY_NSCameraUsageDescription` (Privacy –
  Camera Usage Description) or the app crashes when the AR session starts. Michael
  must add it (auto-generated Info.plist; don't edit pbxproj).
- CONTEXT: before this, the app had NO capture at all — "New Scan" was a
  placeholder processing a synthetic mesh. Michael field-tested expecting a
  scanner; this closes that gap (live mesh + distance HUD), reconstruction next.

## Backlog / requirements
- iCloud backup via **CloudKit** (Design §10.1, decision M-9, Phase 1/v1.0):
  private DB mirror of animals + scan metadata/meshes/exports (raw frames opt-in),
  offline-first `CKSyncEngine`, local file store = source of truth. Needs iCloud
  + CloudKit capability/entitlement (manual Xcode step). Implement as `SyncKit`
  package or `CloudBackup` service beside `ScanLibrary`; mock CloudKit behind a
  protocol for tests. NOT yet built.
- Storage-pressure offload (Design §10.2, M-10, v1.1, depends on M-9): phone =
  cache over CloudKit; evict LRU heavy assets (frames→meshes) under low free
  space (`volumeAvailableCapacityForImportantUsageKey`, ~2GB threshold), keep
  small records (metadata/spine/sections/metrics) local so lists+metrics render
  offline, restore assets on demand. Per-artifact state onDevice/offloaded/
  restoring. Only evict what CloudKit confirms uploaded. NOT yet built.
- 2026-08-01: Michael added `INFOPLIST_KEY_NSCameraUsageDescription` — capture
  device path is now unblocked (pending his field test).

## Field feedback fixes (2026-08-01, from Penelope/mule scan)
- Post-capture status now `.awaitingReconstruction` (was stuck on "Capturing");
  `ScanStatus.displayName` for friendly labels.
- Processing duration recorded (`ScanRecord.processingSeconds`, timed in
  `AppModel.processScan`) + shown in scan row ("processed in Xm Ys") & detail.
- Reconstruction **Detail** now a Settings picker (Reduced/Medium/Raw, §8.2/M-3),
  @AppStorage("reconstructionDetail"), passed via startNewScan. Clarified to
  Michael: Detail = quality knob, independent of scan duration; scanning longer
  improves COVERAGE not Detail level.
- STILL: capture saves NO data; "Process Demo Mesh" = synthetic. Faint live mesh
  is Apple's `.showSceneUnderstanding` debug overlay; bold red→green COVERAGE mesh
  (§6.5) not built. NEXT (authorized): capture→reconstruction increment (save
  LiDAR-posed frames → PhotogrammetrySession → real mesh) + bold coverage mesh.

## Capture step 3a — DONE (2026-08-01), on-device, awaiting field test
- `CoverageTracker` (voxel-based, survives re-tessellation; 4/4 unit tests),
  `MeshAnchorGeometry` (ARMeshAnchor buffer extraction + Sendable `CoverageMeshData`),
  `CoverageMeshRenderer` (bold red/yellow/green via `MeshDescriptor.materials=.perFace`
  + 3 UnlitMaterials, ~0.72 alpha), `FrameSnapshotter` (posed HEIC+depth+sidecar,
  §6.2 triggers), rewired `ARCaptureView` (nonisolated coordinator: AR-queue tracker/
  snapshotter → Sendable data → MainActor renderer; removed showSceneUnderstanding).
- Flow: capture writes frames to TEMP dir; Finish → `AppModel.finishCapture` →
  `startNewScan` + `ScanLibrary.importFrames` (move temp→scan/frames); Cancel discards.
- Built for device, installed + launched on Michael's iPhone OK. Unit tests 13/13 (sim).
- FIELD-TEST TARGETS: bold live mesh visible in daylight? coverage colors advance
  red→green from 40–80cm? coverage % + frame count update? frames actually saved?
  perf ok (MeshResource rebuild @5Hz)?
- KNOWN LIMITS: (1) reconstruction (3b) NOT built — "Process Demo Mesh" still
  SYNTHETIC, so scan result still isn't Penelope (frames ARE saved now). (2) Coverage
  colors the WHOLE visible mesh incl floor/walls — no live ROI restriction (§7.5) yet.
  (3) material alpha may need daylight tuning.
- Device deploy recipe: `xcodebuild -scheme SaddleBack -destination 'platform=iOS,id=<DID>'
  -allowProvisioningUpdates -derivedDataPath /tmp/x build` then `xcrun devicectl device
  install app --device <DID> <app>` + `... process launch ... com.prange.SaddleBack`.
  DID=00008120-001445381433401E. (MCP test runner grabs the device & fails to launch
  host — use xcodebuild w/ sim id F1107CB6-4779-41CE-B9DB-D718397971B3 for tests.)

## Front TrueDepth capture (F1) — DONE 2026-08-02, on-device, awaiting field test
- Motivation: fitter has a NON-PRO iPhone (no LiDAR). Front TrueDepth works on all
  iPhone X+. Design decision (front camera): live point cloud now, Photogrammetry-
  Session for reconstruction later (F2). Front camera has NO world mesh from ARKit
  (that's LiDAR-only) — we build our own from the depth stream.
- Capture/TrueDepth/: `TrueDepthCaptureController` (AVCaptureSession front TrueDepth,
  video+depth AVCaptureDataOutputSynchronizer, CoreMotion attitude, AUTO-START when
  face-down gravity.z>0.8 + surface 25–45cm), `DepthPointCloud` (unproject depth→
  points, depth-colored), `PointCloudSceneView` (SceneKit live point cloud),
  `TrueDepthFrameWriter` (RGB HEIC+depth+attitude sidecar), `TrueDepthCaptureView`,
  `TrueDepthCaptureModel`. `CaptureCapabilities.resolvedMode` routes by device +
  Settings "Scanning camera" (auto/front/rear). Auto = LiDAR on Pro, TrueDepth else.
- CaptureMode renamed .trueDepthRaw→.trueDepth. finishCapture now takes `mode:`.
- Built + installed + launched on device OK. Sim tests 13/13.
- TO TEST FRONT ON PRO: Settings→Scanning camera→Front, then New Scan, hold screen-
  down at 25–45cm → auto-starts, live point cloud.
- KNOWN LIMITS / field-test targets: point-cloud perf (SceneKit per-frame geometry
  rebuild @12fps, ~20k pts); auto-start reliability (gravity.z>0.8, 25–45cm);
  depth format selection (picks first Float32 depth format — may need tuning);
  frames saved @3Hz while scanning; NO fusion/reconstruction yet (F2 = Photogrammetry
  on saved RGB+depth). Live view is per-frame cloud, NOT a stitched surface.
- Design.MD §6.6 still says "experimental raw capture" — NOT yet updated to reflect
  TrueDepth as primary non-Pro path (M-8 supersede pending).

## iCloud Drive offload (2026-08-02) — chosen over CloudKit for the Thu deadline
- Scan store roots in the app's iCloud Drive **ubiquity container** Documents when
  available (`StorageRoot.resolve()` off-main, one-time `setUbiquitous` migration
  of existing local scans), else local Documents. iOS auto-uploads + evicts under
  storage pressure + re-downloads on access (native offload).
- `AppModel.make()` async resolves root off-main; `SaddleBackApp` shows a loading
  view then builds the model. `AppModel.isUsingICloud` shown in Settings ▸ Storage.
  `ScanLibrary.ensureDownloaded()` re-materializes evicted files on read.
- ⚠️ DORMANT until Michael enables **iCloud → iCloud Documents** capability
  (Signing & Capabilities, container `iCloud.com.prange.SaddleBack`, automatic
  signing) — until then `url(forUbiquityContainerIdentifier:)` is nil → local.
  Can't add entitlement myself (pbxproj/entitlements).
- Connectivity: Michael has 2 bars in camp, none on trail → scans stay local on
  the trail, upload/evict overnight in camp. Phone must hold ONE day's scans.
- SUPERSEDES CloudKit design (M-9/M-10, §10.1/§10.2) for now — Design.MD not yet
  updated to reflect iCloud-Drive-first.
- Built + installed on device (iCloud dormant). Not runtime-verified.

## PDF cross-section report (2026-08-02) — built, NOT yet wired/deployed
- `ExportKit/PDFReportWriter` (CoreGraphics+CoreText, cross-platform): single-page
  LANDSCAPE US-Letter. Topline/rocker on top (withers dotted+labeled), fanned
  cross-sections centered on spine — station 0 = "Withers #1" + L/R, rest #2.. —
  at 1/2in spacing (auto-tightens to fit), exact clean scale (1:N from
  1/2,1/3,1/4,...), 2-unit scale bars (2in imperial / 5cm metric). Verified by
  rendering /tmp PDF→PNG with a shallow-arc sample (real backs = open arcs; the
  synthetic tube gives misleading closed loops). ExportKit 9/9.
- TODO (after mule test, in the hardening redeploy): wire into app — generate
  report.pdf per scan (AppModel has animal name; read unit from UserDefaults
  "measurementSystem"), add `ProcessedScan.exports.reportPDF` + a Share/View PDF
  button in ResultView. Currently NOT built into the app; phone build FROZEN for
  Michael's mule test (see below).
- Frozen test build on phone includes: see-through coverage dots, F2 reconstruction,
  iCloud Drive offload, textured 3D view + STL. PDF + wiring come next redeploy.

## Field-bug fixes + PDF wiring (2026-08-03, from 2nd mule test)
- REAR no dots: `ARCaptureView.Coordinator.renderer` was `weak` with no strong
  owner → deallocated instantly. Changed to strong `nonisolated(unsafe) var`.
- FRONT stuck "face down"/no start: face-down now from CoreMotion handler
  (motionQueue) independent of camera; depth-format pick loosened (any depth fmt,
  prefer Float32); callback now DEPTH-OPTIONAL (saves RGB-only via
  `TrueDepthFrameWriter.writeRGBOnly` if depth absent); manual `requestStart()` +
  "Start Scanning" button in TrueDepthCaptureView. gravity.z>0.7.
- Reconstruction HANG: `ReconstructionDriver` 5-min timeout via Task→session.cancel()
  + `.processingCancelled` handling. Frames always saved regardless.
- PDF wired into app: `PDFReportWriter` gains `PDFPageSize` (letter/tabloid/a4/a3,
  landscape). `AppModel.generateReportPDF` (reads UserDefaults measurementSystem +
  pdfPageSize, animal name from `animals`) writes exports/report.pdf in both
  processScan + reconstructScan; `ProcessedScan.exports.reportPDF` + in shareables.
  Settings: PDF page-size picker (@AppStorage "pdfPageSize"). ResultView: "Share
  Cross-Section PDF" button. Fitter uses Tabloid 11×17.
- Built + installed + launched on device. Unit tests: app all pass, ExportKit 9/9,
  MeshKit unchanged. Front-camera runtime STILL unverified (device-only).
- PDF report verified visually earlier (landscape, withers #1 + L/R, topline,
  1/2in fan auto-tightens, 2-unit scale bars).

## Swift 6 (2026-08-03)
- Michael flipped the app target to `SWIFT_VERSION = 6.0`. Whole project now builds
  + tests pass in Swift 6 language mode (packages were already 6.2).
- Fixes applied: `@preconcurrency import AVFoundation`; TrueDepth motion handler
  captures `model` not `self`; `TrueDepthCaptureController` & `ARCaptureView.Coordinator`
  marked `@unchecked Sendable` (queue-confined); `CrossSectionMapping` marked
  `nonisolated` (used from `Shape.path(in:)`); trackingNormal/header → `let`;
  USDZ indexType switch `default`. All code-hygiene, no behavior change.
- Sendable tightening: `ARCaptureView.Coordinator` @unchecked REMOVED (fully
  checked — Tasks capture Sendable model/renderer, no self-send). `TrueDepth‑
  CaptureController` KEEPS @unchecked Sendable — REQUIRED (it's an @objc AVF
  delegate → can't be an actor; dispatches self onto serial sessionQueue). Hot-
  path Tasks tightened to capture model/renderer so self-use is minimal/justified.

## Field-bug fixes — 3rd Penelope test (2026-08-03), NOT yet redeployed
- ROOT BUG (scans stuck "Awaiting reconstruction" forever): reconstruction was
  MANUAL-ONLY (only via ScanDetailView "Reconstruct Scan" button). `finishCapture`
  recorded the scan + imported frames then stopped. FIX: `AppModel.autoReconstruct`
  (serialized via `reconstructionTask` chain so back-to-back captures run one at a
  time) called from `ScanListView.finishCapture` after import; list reloads on
  `reconstructionProgress` nil↔non-nil transition (Reconstructing…→Complete). 5-min
  driver timeout means a scan can no longer hang indefinitely. NOTE: the 2 already-
  stuck scans won't retro-reconstruct — open each + tap Reconstruct, or rescan.
- VIEW COMPLETED SCAN w/o re-photogrammetry: `AppModel.loadResult` — reconstructed
  (hasCapturedFrames) → materialize+load model.usdz → FAST MeshKit pipeline only
  (+regen PDF); else demo → processScan. `ScanDetailView.task` loads when
  status==.complete (shows "Loading results…"). `ScanLibrary.materialize(_:)` exposes
  iCloud download. (Prior gap: reopening a complete scan re-ran full ~5-min recon.)
- FRONT auto-start loosened (fitter tilts phone over back): gravity.z>0.7→0.5,
  auto-start distance 0.25–0.45→0.20–0.60 (constants autoStartGravityZ/Near/Far in
  `TrueDepthCaptureController`). Manual "Start" stays primary reliable path.
- PDF two-page true-scale spine (fitter request): page 1 = ±8in cross-sections +
  front run of topline; page 2 = topline continued, cut off at far edge. ONE shared
  scale = largest clean scale whose widest section fits page width (1:1 on Tabloid/A3,
  reduced e.g. 1:2 on Letter/A4 — reduced still useful for a quick fitter printout,
  true-scale done at a print shop). Shared edge-referenced z→y map + ppm → pages abut
  into one continuous back. MeshKit `CrossSectionExtractor.Configuration.lateralHalfWidth`
  (=0.2032 in ScanProcessor) does the ±8in clip. MeshKit 31/31, ExportKit 9/9.
- All builds clean (Swift 6). Device redeploy PENDING (Michael does build/deploy).

## Status
- 2026-07-30: Project scaffolded. CLAUDE.md added. Decisions: 4 local SPM packages;
  MeshKit-first. Z-up convention adopted.
- 2026-07-30: MeshKit foundation done — `TriangleMesh`, `SyntheticBackMesh` (§15
  fixture), OBJ I/O.
- 2026-07-30: `LongAxisPCA` + `LongAxisNormalizer` (Z-rotation onto +X).
- 2026-07-30: `SmoothingSpline` (Green–Silverman/Reinsch, auto-λ via χ²≈n,
  Cholesky solve) + `SpineCurveFitter` (slice-and-find-peaks, per-slice
  noise-weighted) + `SpineCurve` (arc-length param). 15/15 tests pass.
- 2026-07-30: `LandmarkDetector` (§7.3, head/tail sign, 15 cm front cutoff) +
  `ROICropper` (§7.4) + `SpineCurve.closestPoint`.
- 2026-07-30: `PlaneMeshIntersector` + `CrossSectionExtractor`/`CrossSection`
  (§9.3, polyline weld+assembly, 2D u/v projection) + `SectionMetrics` (§9.4,
  full M-2 set) + `SyntheticBackMesh.straightCylinder` fixture. **25/25 pass.**
  ✅ MeshKit geometry pipeline (§7 + §9) COMPLETE.
- 2026-07-30: ExportKit package (depends on MeshKit via `../MeshKit` path) —
  `CSVWriter` (sections + metrics), `DXFWriter` (R12 POLYLINE per STATION_NNNN
  layer, cm), `OBJWriter`, `PLYWriter`, `USDZWriter` (ModelIO). 6/6 pass.
  ⚠️ USDZ round-trip test is gated `.enabled(if: canExportFileExtension)` — the
  ModelIO USD exporter isn't registered in the headless SwiftPM CLI, so USDZ
  export MUST be verified in-app/on-device.
- P0 17 Pro reconstruction harness: DEFERRED (no 17 Pro available).
- 2026-07-30: Michael linked MeshKit + ExportKit to the app target (Add Local
  Package). App builds.
- 2026-07-30: App skeleton + §10 persistence — `AnimalRecord`/`ScanRecord`
  models, `ScanLibrary` (actor, Documents/animals layout), `AppModel`
  (@MainActor @Observable), `DeviceInfo`, and nav shell (`AnimalListView` →
  `AddAnimalView`/`ScanListView`). App tests 6/6 pass (RunSomeTests). App files
  live in the synced group — no pbxproj edits.
  NOTE: "New Scan" only creates a record (no capture yet). `ContentView.swift`
  now unused (deletable).
- 2026-07-31: Michael linked MeshKit+ExportKit *products* to the app target
  (General ▸ Frameworks). MeshKit→ExportKit result flow wired: `ScanProcessor`
  (actor: normalize→spine→landmarks→ROI→sections→metrics→export OBJ/USDZ/DXF/CSV
  + spine.json), `ProcessedScan`/`SpineSummary`, `AppModel.processScan`,
  `ScanDetailView` (metrics + ShareLink). App tests 8/8.
- 2026-07-31: BUG FIXED in `SpineCurveFitter` — keyed spline knots on the picked
  vertex's grid-quantized X, so at mesh resolutions where grid spacing divides
  slice spacing (e.g. default make() 140-seg → 0.01 grid vs 0.02 slices) adjacent
  slabs produced duplicate knots → h=0 → NaN spline. Now keys on slice-centre X.
  Added regression test + NaN safety-net in `SmoothingSpline.autoFit`.
- 2026-07-31: `ResultView` visualization — cross-section `Canvas` (aspect-correct,
  v-up, spine marker) with station slider, Swift Charts for rocker/width/tree
  angles, USDZ Quick Look (`import QuickLook`), ShareLink. `ProcessedScan` now
  carries `sections` + sampled `rocker`. `ScanDetailView` shows `ResultView` once
  processed. App tests 2/2 (processor) still green; build clean.
  NOTE: keep app *test* target free of MeshKit types (not linked to it) — tests
  touch only app-module types + Foundation/simd.
- 2026-07-31: ResultView VISUALLY VERIFIED on iPhone 14 Pro (iOS 26.5) via
  `SaddleBackUITests/ResultViewUITest` (drives add-animal→scan→process, asserts
  render, captures screenshots). Charts + cross-section Canvas + ShareLink render.
  - iPhone 14 Pro sim only exists on old runtime; created one on iOS-26-5 to run
    (app min deploy 26.5). To run UI test on a specific sim, use xcodebuild
    `-destination` (MCP RunSomeTests can't pick the device).
  - USDZ "View 3D Model" button absent in SIM (ModelIO USD export plugin
    unavailable in sim, same as CLI) — will appear on device.
- 2026-07-31: SectionMetrics `isReliable` added. IMPORTANT domain correction:
  saddle cross-sections are OPEN ARCS (ROI lateral limit 0.5m < barrel, so the
  underside is cropped) — `isClosed` is the WRONG reliability test. Reliability =
  tree angles finite (section reaches ±5cm both sides). Verified: 37/63 reliable
  on synthetic (front/tail partials excluded). `reliable` column added to
  metrics.csv. ResultView filters width chart + shows reliable count; slider
  defaults to first reliable station.
- 2026-07-31: Units setting — `MeasurementSystem` (metric/imperial), `SettingsView`
  (gear in AnimalListView), @AppStorage("measurementSystem"). ResultView formats
  lengths + chart axes in cm or in. Exports stay cm. VERIFIED on iPhone 14 Pro
  (UI test switches to Imperial → "58.6 in" etc.).
- 2026-08-01: WITHERS ARTIFACT FIXED (two real bugs, not plane-tilt — the
  vertical-plane idea REGRESSED and was reverted):
  (1) section `vAxis` sign flipped where the spine tangent's z-component changes
      sign (across the withers) → inverted sections & negated tree angles. Fixed:
      force `vAxis.z >= 0` in CrossSectionExtractor.
  (2) at the withers the section self-touches; the edge-walk split it and picked
      a wrong fragment. Fixed: `stitch()` merges fragments by shared endpoints.
  Result: 11/11 reliable, proper rooftop (∩) sections incl. the withers, tree
  angles stable ~9–11°. Regression test added.
  NOTE: `width_at_spine_level` legitimately non-zero (~18cm) at the withers (broad
  apex); it's the design's acknowledged weak metric ("typically 0"). Tree angles
  are the fit-relevant metric and are correct.
- 2026-08-01: Saddle-fitter station scheme — sections start at the WITHERS and
  step caudally to the tail. `CrossSectionExtractor.extract(atArcLengths:)` added;
  `ScanProcessor` builds the withers-anchored list; rocker sampled withers→tail.
  Adjustable spacing setting (default 4in=0.1016m) in SettingsView + @AppStorage
  ("stationSpacingMeters"); ScanRecord default now 0.1016.
- 2026-08-01: Pre-scan instructions popup (`ScanInstructionsView`) shown on New
  Scan with "Don't show again" (@AppStorage "skipScanInstructions"). Wired in
  ScanListView. UI test updated to tap through it. VERIFIED on iPhone 14 Pro:
  withers section renders as a rooftop, 11/11 reliable, inches, popup works.

### SCALE (important, per Michael)
LiDAR path is METRIC automatically: ARKit world poses (m) + LiDAR depth attached
to each PhotogrammetrySample (§8.1) → reconstruction in real metres. No manual
scaling needed. MeshKit already treats coords as metres. TrueDepth raw path is
NOT posed → not scaled (diagnostic only). PROPOSED (not yet built): optional
`referenceLengthMeters` on ScanRecord + calibration in ScanProcessor using
withers→tailBase landmark distance, as a validation check / TrueDepth scale source.

Next: harden open-section metrics; optional scale-calibration feature;
`CaptureKit` (ARKit LiDAR, §6, needs device) or `ReconstructionKit`.
