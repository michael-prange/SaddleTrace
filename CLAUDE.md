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

## Raw-shot archive + migration removed (2026-08-27)
- SAVE RAW SHOT: `RawShotWriter` writes photo.heic + depth.bin + confidence.bin +
  shot.json (intrinsics/imageRes/cameraTransform/depth dims) into the scan's frames/
  at single-shot capture. `extract(from:ARFrame)` on main (encodes HEIC ~200ms) →
  Sendable `RawShot` → `persist` off-main in the existing detached write Task in
  `LiDARShotCaptureView`. importFrames moves them into the scan. GOAL: re-run the
  full `DepthGridMesh` build (geometry + paint) on the WHOLE archive when code
  improves. NOTE: the reprocess PATH itself is NOT built yet — only the inputs are
  saved. `hasCapturedFrames` now true for single-shot (photo.heic present) but
  reconstruct still routes by lidar.obj first, so no photogrammetry misroute.
- REMOVED retro height-clip migration (was a no-op / marker-blocked-retry, and moot
  once we learned the real bug was flipped paint): deleted `AppModel.
  migrateHeightClipIfNeeded` + its loadResult call. `MeshHeightClip.swift` blanked —
  MICHAEL TO DELETE the file in Xcode.

## PAINT was vertically mirrored (2026-08-27) — root cause of "grass on the back"
- Michael's diagnosis (correct): geometry was horse-shaped but PAINTED with grass in
  wrong places → photo→vertex mapping flipped, not a grass-geometry problem. The
  height clip WAS removing grass geometry; the flipped paint put grass color on top.
- ROOT CAUSE: `DepthGridMesh` sampled color via `CIImage(cvPixelBuffer:)`→
  `createCGImage`→ flipped CGContext. CIImage's bottom-left origin + the manual flip
  net to a VERTICAL MIRROR vs the depth map. FIX: sample `frame.capturedImage`
  DIRECTLY (both it and the depth map are CVPixelBuffers, row 0 = top → aligned).
  Read 420 YCbCr bi-planar (luma plane 0, Cb/Cr plane 1 half-res), BT.601 → RGB,
  video/full-range aware. No CIImage/CGContext. depth (x,y)→luma (x·lumaW/w,
  y·lumaH/h). Removed CoreImage/CoreGraphics imports + ciContext.
- ⚠️ OLD single-shot scans have the wrong colors BAKED into surface.bin, and the
  source photo is NOT retained (LiDARShotCaptureView saves only lidar.obj/pointcloud/
  surface). So old scans CANNOT be re-painted — needs a NEW capture to verify. The
  retro height-clip migration is now moot for this issue (was about grass geometry).
  NOTE: consider saving the shot's HEIC so future scans could be recolored.

## Grass clip + 3D tracings (2026-08-18), NOT device-verified
- GRASS-IN-MODEL root cause: barrel→ground is a GENTLE slope (per-pixel depth steps
  < maxEdgeJump 4cm) so the mesh bridges horse→ground into ONE connected component
  (largest-component filter keeps it); maxDepth 1.5m too generous; no height clip.
  PLY confirmed green (grass) verts. FIX: `DepthGridMesh` height clip — world is
  gravity-aligned (Y up), drop verts > `dropBelowCrest` (0.35 m) below the 98th-pct
  crest Y (null their vertexIndex pre-triangulation → excluded from mesh+cloud).
- 3D TRACINGS (spine + sections as green curves on the painted model): plumbed the
  normalize transform N + a 3D spine polyline out of `ScanProcessor.process`
  (`ProcessedScan.normalizeTransform`, `.spinePolyline`). `AppModel.worldTracings`
  maps normalized spine/section points back to capture/world frame via
  `inverse(yUpToZUp)·inverse(N)` → `PolylineIO` `frames/tracings.bin`
  (`Exports.tracingsURL`). `PaintedSurface3DView` recenters surface+tracings by the
  SAME bbox center, draws green `.line` geometry (readsFromDepthBuffer=false → always
  on top). Purpose: show sections vs. coat marks she draws for bone positions.
- TODO NEXT: embed the 3D model (with tracings) in PDF page-1 bottom-center, as large
  as possible w/o overlapping the section fan / topline. Approach TBD (SceneKit
  offscreen snapshot → CGImage into PDFReportWriter, vs CG oblique projection in
  ExportKit). Front-camera one-snap still deferred.
- RETRO-FIX for OLD scans (2026-08-27): grass clip is capture-time, so pre-fix scans
  keep grass in their SAVED artifacts. `MeshHeightClip` (pure arrays) + `AppModel.
  migrateHeightClipIfNeeded` (called at top of loadResult): one-time, marker-gated
  (`frames/.heightclipped`) rewrite of lidar.obj + surface.bin + pointcloud.bin with
  the same 0.35 m below-crest clip → process/PDF/both viewers all see clean data.
  Only rewrites files with geometry below the crest. Does NOT re-run largest-
  component, so grass remnants within 0.35 m of the crest could survive (rare).

## Ortho viewers + colored PLY export (2026-08-04), NOT device-verified
- Perceived VERTICAL EXAGGERATION: geometry is isometric (viewers push world coords
  straight to SCNVector3, no per-axis scale; unprojection is metric). Cause = default
  PERSPECTIVE camera foreshortening. Fix: all 3 viewers (Painted/PointCloud/Model3D)
  now `usesOrthographicProjection=true`, `orthographicScale≈model half-extent` → true
  proportions. If exaggeration persists on-device after this, it'd be real (it isn't
  expected to).
- COLORED PLY export: `PLYWriter.coloredPLY/writeColored(positions:colors:indices:)`
  (ASCII, uchar RGB). `makeResult` reads `surface.bin` → writes `exports/surface.ply`
  → `Exports.paintedPLY`, added to `shareables` (STL stays uncolored geometry).
  ResultView share label → "PDF · PLY · STL · DXF · CSV". ExportKit 9/9.
- FRONT one-snap: FEASIBLE — same DepthGridMesh math on a single `AVDepthData` frame
  (front TrueDepth), no streaming/photogrammetry, no world pose. Coarser/shorter-range
  than LiDAR. Deferred (trip = Pro/LiDAR); offered to build post-trip.

## Photo-painted surface (2026-08-04), NOT device-verified
- Single-shot makes painting TRIVIAL: each mesh vertex = one depth pixel = one photo
  pixel. `DepthGridMesh` renders `frame.capturedImage` (CIImage→CGImage→top-row RGBA8
  bitmap, Y-flipped so row0=top to match depth) and samples per-vertex `photoColors`.
  Result gains `photoColors` (parallel to points; kept through largest-component
  compaction). Confidence colors STILL kept for the point-cloud diagnostic.
- `PaintedMeshIO` (positions+colors+indices binary) → `frames/surface.bin` written at
  capture. `Exports.paintedSurfaceURL` set in makeResult (materialize). New
  `PaintedSurface3DView` builds a colored SCNGeometry (triangles, `.color` source,
  lightingModel `.constant` = unlit so the photo reads as-is), recenter+framed+target.
  ResultView "View 3D Model" prefers painted surface, else gray Model3DView.
- STL stays UNCOLORED (geometry-only, correct for CAD). Colored PLY export = easy
  future add if wanted.
- DEVICE-ONLY checks: photo not mirrored/upside-down on the surface (the RGB Y-flip +
  depth CV→ARKit flip must agree); colors look right (CIContext YCbCr→RGB).
- TEST FILE TO DELETE (Michael, in Xcode): `SaddleBackUITests/ResultViewUITest.swift`
  (obsolete demo-driven flow). `ScanProcessorTests.swift` repurposed → KEEP.

## Spine-by-symmetry + demo removal + 3D rotation fix (2026-08-04), NOT device-verified
- SPINE now by MAX SYMMETRY (Michael's method, replaces "highest vertex per slice"
  which let a noise spike hijack the crest → mis-centred sections). `SpineCurveFitter`:
  per slab build top-envelope profile (max Z per 5 mm lateral bin), among bins within
  3 cm of the slab top pick the centre minimizing Σ(zL−zR)² over mirrored pairs to
  ±8 cm (`crestBySymmetry`); fallback to max-Z vertex if sparse. Lateral spline now
  tightly weighted (centre is stable). MeshKit 31/31, ExportKit 9/9 still pass
  (symmetric synthetic back → y≈0, height peaks at withers — unaffected).
- DEMO MESH REMOVED (Michael): deleted `AppModel.processScan` + SyntheticBackMesh app
  usage + loadResult demo fallback + ScanDetailView "Process Demo Mesh" branch (now
  shows "No captured data") + "Use Demo Scan" buttons (LiDARShot/TrueDepth views).
  Repurposed the two demo-dependent tests (ScanProcessorTests → record plumbing;
  ResultViewUITest → add-animal/settings smoke) — files kept (pbxproj refs).
  SyntheticBackMesh STAYS in MeshKit (package test fixture).
- 3D ROTATION FIX: Model3DView + PointCloud3DView set
  `defaultCameraController.target = SCNVector3Zero` so orbit pivots on the model
  (already recentered to origin) instead of a default point.
- STILL TODO: paint surface w/ photo (trivial for single-shot — vertex=pixel).

## Single-shot WORKS (2026-08-04) — cleanup pass + remaining asks
- 1st single-shot on Penelope: recognizable back surface + point cloud. GOOD. Issues:
  (1) point-cloud OUTLIERS (disconnected arm/ground/floaters); (2) cross-sections
  ROUGH + not nesting (spine picked as noisy max-Z, mis-centers sections);
  (3) instructions metric while units=inches; (4) "Start Scan" btn misleading.
- DONE this turn (capture-side, no MeshKit change): `DepthGridMesh` now (a) 3×3
  MEDIAN filter on depth pre-unproject (smoother sections/surface), (b) keeps only
  the LARGEST connected component via union-find (drops all disconnected outliers
  from mesh AND cloud). Instructions unit-aware (@AppStorage measurementSystem);
  button → "OK".
- STILL TO DO (Michael's asks, bigger, own verification each):
  (A) SPINE by MAX SYMMETRY (his method): fit low-order spline, per slice pick the
  lateral center of best L/R mirror symmetry instead of max-Z peak — noise-robust,
  fixes section centering/alignment. MeshKit change (SpineCurveFitter), has tests.
  (B) PAINT SURFACE w/ PHOTO: TRIVIAL for single-shot — each mesh vertex = one depth
  pixel = one RGB pixel (no multi-view baking). Sample frame.capturedImage per
  vertex → vertex colors; render colored surface (needs colored-geometry path or
  colored PLY; Model3DView loads URL via SCNScene). Recommend do after seeing if
  cleanup alone improved sections.

## PIVOT: single-shot LiDAR "depth photograph" (2026-08-04), NOT device-verified
- 3 sweeps in a row FAILED to process → abandoned the sweep+fuse+crop approach.
  ROOT CAUSE of all rear failures: reconstructing from ARKit's FUSED SCENE MESH
  (ARMeshAnchors) — sparse, re-tessellated, drift-prone; MeshKit spine fit throws on
  the fragmented result. NEW primitive: a SINGLE ARKit `sceneDepth` frame → dense
  grid mesh. One instant, no sweep, no fusion, no drift. Michael's idea; correct.
- `DepthGridMesh.build(from: ARFrame)`: unproject sceneDepth (256×192) with
  intrinsics scaled to depth res, CV→ARKit cam flip (x, −y, −z), world = cam*p;
  keep conf ≥ medium, depth ≤1.5 m; triangulate the pixel grid, DROP quads whose
  corner-depth spread >4 cm (no bridging back→ground). Returns dense TriangleMesh
  (world Y-up) + point cloud (+conf colors green/yellow). ~50k verts.
- `LiDARShotCaptureView` + `LiDARShotModel`: ARSCNView preview (sceneDepth, no mesh
  recon), dashed 4:5 FRAMING BOX ("fill with ~20 in of back"), DistanceHUD band
  0.50–0.70 m (~20 in footprint), single shutter → build mesh on main, write
  lidar.obj + pointcloud.bin off-main → "Use This Shot"/Retake. Routed as the rear
  default in ScanListView (was CaptureView sweep, kept for reference).
- GOAL is just the ~20 in SADDLE region (not withers→tail); 1 m too high to hold —
  ~0.6 m gives ~20 in. Hold low + angle forward is fine (depth is 3D). Ultra-wide
  NOT usable (ARKit LiDAR locked to wide cam).
- Reuses existing recon path: frames/lidar.obj → yUpToZUp → MeshKit process
  (dense mesh → spine fit SHOULD succeed). Both viewers already wired: "View 3D
  Model" (surface=lidar.obj) + "View Point Cloud" (pointcloud.bin). Instructions
  rewritten for single-shot.
- WHY confident: LandmarkDetector never throws (withers=max height, tail=curve end);
  failures were spine-fit on fragmented mesh — dense single-shot mesh fixes that.
- DEVICE-ONLY unverified: check the CV→ARKit unprojection convention (mesh not
  mirrored/inverted), footprint size vs distance band, spine fit succeeds on a 20 in
  mid-back segment (withers-anchoring may pick an arbitrary high point — acceptable).

## 5th test — "more passes = WORSE" + point-cloud viewer (2026-08-03), NOT redeployed
- Michael scanned spine + 2× each side, repeated → MORE holes, unrecognizable.
  Counterintuitive (more coverage should = fewer dropped faces). Leading causes to
  disambiguate: (a) ARKit world drift/relocalization over long session → ghosted/
  doubled shells; (b) coverage-voxel vs final re-tessellated-mesh mismatch → crop
  drops good faces as "uncovered". Did NOT change crop (Michael keeps strict).
- Added DIAGNOSTIC POINT-CLOUD VIEWER (his request): at Finish, besides cropped
  `lidar.obj`, write `frames/pointcloud.bin` = ALL mesh-anchor verts (UNCROPPED),
  coverage-colored r/y/g (`MeshAnchorGeometry.fusedPointCloud`, `PointCloudIO`
  UInt32 count + 6×Float32/pt). `ProcessedScan.Exports.pointCloudURL` set in
  makeResult (materialize). `PointCloud3DView` (SceneKit points via existing
  `SceneKitPointCloud.geometry`, recenter+framed cam). ResultView "View Point Cloud".
- READS: if cloud looks GOOD but mesh has holes → crop/voxel mismatch is the bug
  (fix crop). If cloud itself sparse/holey/ghosted → capture/drift problem. Green =
  what the crop keeps; lots of red on the back = coverage crediting under-firing.

## 4th Penelope test — LiDAR mesh WORKS; fixes (2026-08-03), NOT yet redeployed
- LiDAR fused-mesh rear path CONFIRMED on device: gray mesh is recognizably the
  back, coverage crop excluded grass. Holes + a bit of the operator present.
  Michael's call: KEEP strict crop (faces seen ≥2×), rely on MULTI-PASS technique
  (with LiDAR fusion, multiple slow overlapping passes now HELP — reversal of the
  old photogrammetry advice). No crop code change.
- FIX 3D-viewer-absent: for LiDAR, `texturedModelURL` nil → viewer fell back to
  `roiUSDZ` (ModelIO USD exporter, unreliable on device) → nil → no button. Added
  `ProcessedScan.Exports.fusedModelURL` (the full `lidar.obj`); `viewableModelURL =
  textured ?? fused ?? roiUSDZ`. Threaded through loadReconstructedMesh/makeResult/
  reconstructScan. `Model3DView` now flattens+recenters the loaded model and adds an
  explicit framed camera (fused mesh sits far from ARKit world origin → default cam
  couldn't see it). Shows the full back; OBJ loads in SceneKit w/o ModelIO USD.
- FIX front no-haptic: `TrueDepthCaptureModel.apply(distance:scanning:savedFrames:)`
  emits a light tick per NEWLY-saved frame while scanning (honest: no ticks = not
  saving). Controller routes its sample through it.
- Instructions (`ScanInstructionsView`): slow overlapping passes + "keep yourself
  out of frame" + green-is-kept.
- OPEN (front, device-only, NOT trip-critical — trip = Michael's Pro/LiDAR): front
  scan saved ZERO real frames → fell back to synthetic demo (2 s, arcs-of-circles
  STL, no 3D, distance bar stuck). The AVCaptureDataOutputSynchronizer delegate
  isn't delivering synced frames on device. Next test tells via haptic ticks: no
  ticks after Start = pipeline dead (need on-device logs); ticks = saving now.

## REAR path → LiDAR fused mesh (2026-08-03, NOT device-verified)
- WHY: rear reconstruction used PhotogrammetrySession (image SfM) over saved HEICs,
  IGNORING LiDAR depth → warped/holed mesh + fused-in grass on Penelope (3-pass
  sweep = drift/low-overlap/low-texture). Now the rear/LiDAR path builds the model
  DIRECTLY from ARKit's fused scene mesh (`ARMeshAnchor`s) — movement-tolerant,
  metric, no texture needed. TrueDepth/front path KEEPS photogrammetry.
- HOW: at Finish, `MeshAnchorGeometry.fusedScannedMesh(anchors:tracker:)` combines
  all mesh anchors into ONE world-space (ARKit Y-up) mesh, keeping only faces whose
  centroid the `CoverageTracker` marks ≥ .partial (state != .uncovered). That crops
  ground/surroundings for free: tracker only credits faces seen at 0.30–1.00 m +
  ≤45° — the back scanned up-close qualifies, ground (~1.2 m below phone) doesn't.
  Vertices compacted (no unreferenced pts to bias PCA). Written as `frames/lidar.obj`.
- BRIDGE: `CaptureModel.requestMeshExport`/`meshExportFinished`; `CaptureView` Finish
  → `beginFinish()` sets `Coordinator.pendingExportURL` (nonisolated(unsafe), one-shot),
  consumed on next AR frame in `didUpdate frame` (tracker read on AR queue = safe),
  writes OBJ via `MeshIO.writeOBJ`, notifies model → `completeFinish()` (3 s timeout
  fallback). "Finishing…" spinner on the button.
- RECON: `AppModel.reconstructScan` branches — `lidar.obj` present → `MeshIO.readOBJ`
  → yUpToZUp → MeshKit pipeline (topRegionMinHeight −1e6, no floor strip); no
  PhotogrammetrySession. Else TrueDepth → photogrammetry as before. Shared
  `makeResult()` + `loadReconstructedMesh()` (lidar.obj preferred, else model.usdz)
  used by reconstruct AND loadResult. `autoReconstruct` fires on lidar mesh OR
  frames+support. LiDAR result is UNTEXTURED → 3D view falls back to roi.usdz
  (cropped back). OLD stuck scans have no lidar.obj → rescan for the new path.
- Builds clean (Swift 6). DEVICE-ONLY verification (sim has no LiDAR): fused mesh
  crops to back? PCA/spine lock on? result looks "amazing"? Suggest updating
  ScanInstructions to "one slow pass down the spine" (FOV @40–60cm covers ±8").

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

## Coverage viz + share/reimport (2026-08-28), NOT device-verified
- 3D viewers: spine + 4" section curves now render as BOLD tubes (green spine,
  cyan sections) via shared `TracingTubes` (Views/), used by BOTH `PaintedSurface3D‑
  View` and `PointCloud3DView`. Tubes ignore depth (no read/write) + renderingOrder
  10 → always on top, no z-fight/flicker. The earlier translucent section PLANES in
  the point cloud were REMOVED (deleted `SectionPlaneIO`, `Exports.sectionPlanesURL`,
  `worldSectionPlanes`) — replaced by the curves. Point cloud viewer takes
  `tracingsURL` now.
- Charts/PDF: distance is measured FROM THE WITHERS (0) everywhere — ResultView
  rocker/width/tree-angle + station label subtract `spine.withersArcLength`; slider
  starts at Section 0 (withers). Added `.chartXAxisLabel`/`.chartYAxisLabel` (were
  missing). (i) popovers on Width + Tree-angle explain the metrics. PDF sections are
  colored (golden-angle hue palette) with a top-right legend (swatch · #n · distance
  from withers), numbering 0-based (#0 = withers), fan spacing bumped ½"→~⅚".
- PDF now EMBEDS the painted 3D model (with tracings) in the whitespace beneath the
  section-fan center: `Model3DSnapshot` (Views/) renders `PaintedScene` (shared
  builder factored out of `PaintedSurface3DView`) offscreen via `SCNRenderer` →
  CGImage → `PDFReportWriter` (new `modelImage:` param). Placement fits the LARGEST
  centered box of the image's aspect under the sections' lower ENVELOPE (a funnel:
  clear under the spine centerline, arcs only dip at the sides) and above the topline
  peak. `drawImage` uses `ctx.draw` with NO flip (UIImage.cgImage draws upright in
  the y-up PDF ctx — verified). NOTE: the synthetic tube fixture is CLOSED loops so
  the funnel ceiling is negative → image correctly omitted there; real OPEN arcs
  have room. Device/real-data visual check pending.
- SHARE / REIMPORT (Apple Archive, chosen over .zip — native, no dep): `ScanArchive`
  (Model/) LZFSE-archives/extracts a dir tree (AppleArchive+System). `ScanLibrary.
  exportScan/exportAll` stage a mirror of the store layout (+manifest.json) →
  `.saddleback` file in tmp; `importArchive` extracts + MERGES (new animal copied
  whole; existing animal keeps its info.json, scans merged; scan-id COLLISION →
  fresh UUID via `reidScan` rewriting metadata.json so nothing clobbers). `AppModel.
  exportScanArchive/exportAllArchive/importArchive`. UI: AnimalList ▸ ⋯ menu =
  Import (fileImporter, security-scoped) + Share All; ScanDetail toolbar = Share Scan.
  Share via `ActivityView` (UIActivityViewController; ShareLink can't take an
  on-demand URL). Round-trip verified via RunCodeSnippet. Imported scans re-derive
  results on open (loadResult from lidar.obj/surface.bin).

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
