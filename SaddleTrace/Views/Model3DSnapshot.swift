import SceneKit
import UIKit
import Metal
import simd

/// Renders the painted 3D model (with spine/section tracings) to a still image
/// offscreen, matching the in-app `PaintedSurface3DView`. Used to embed the model
/// in the PDF report.
@MainActor
enum Model3DSnapshot {

    /// A CGImage of the model at `size` (white background), or nil if there's no
    /// painted surface or no Metal device.
    static func render(surfaceURL: URL, tracingsURL: URL?, size: CGSize) -> CGImage? {
        guard let (scene, camera, halfExtent) = PaintedScene.make(
                surfaceURL: surfaceURL, tracingsURL: tracingsURL, tubeRadiusScale: 0.4),
              let device = MTLCreateSystemDefaultDevice()
        else { return nil }

        // Look down on the back from an elevated 3/4 angle so more of the top surface
        // is visible (vs. the app's straight-on view). Camera sits above (+Y) and in
        // front (+Z), aimed at the origin.
        let elevation: Float = 42 * .pi / 180
        let dir = simd_normalize(SIMD3<Float>(0, sinf(elevation), cosf(elevation)))
        let worldUp = SIMD3<Float>(0, 1, 0)
        let zAxis = dir
        var xAxis = simd_cross(worldUp, zAxis)
        xAxis = simd_length(xAxis) < 1e-5 ? SIMD3<Float>(1, 0, 0) : simd_normalize(xAxis)
        let yAxis = simd_cross(zAxis, xAxis)

        // Tight orthographic fit for this oblique view: project the box's half-extents
        // onto the camera's right/up axes (exact, so nothing crops), fit to aspect.
        let h = halfExtent
        let halfU = abs(h.x * xAxis.x) + abs(h.y * xAxis.y) + abs(h.z * xAxis.z)
        let halfV = abs(h.x * yAxis.x) + abs(h.y * yAxis.y) + abs(h.z * yAxis.z)
        let aspect = Float(size.width / size.height)
        let scale = max(halfV, halfU / aspect) * 1.06
        let dist = max(simd_length(h), 0.05) * 3
        if let cam = camera.camera {
            cam.orthographicScale = Double(max(scale, 0.02))
            cam.zNear = 0.001
            cam.zFar = Double(dist) * 10
        }
        camera.simdPosition = dir * dist
        camera.look(at: SCNVector3(0, 0, 0))

        scene.background.contents = UIColor.white   // blends into the white PDF page

        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = camera
        return renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X).cgImage
    }
}
