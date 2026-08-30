import Foundation
import MeshKit

/// Writes the cross-section family as a 2D DXF (Design §11): one polyline per
/// station, each on its own layer `STATION_NNNN`. Uses the widely-supported R12
/// `POLYLINE`/`VERTEX` form so it opens in QCAD, LibreCAD, and essentially any
/// CAD package. Coordinates are in centimetres.
public enum DXFWriter {

    private static let mToCm = 100.0

    public static func dxf(from sections: [CrossSection]) -> String {
        var out = ""
        // Minimal DXF: just an ENTITIES section. Layers are created implicitly
        // from the entity layer references by conforming readers.
        out += group(0, "SECTION")
        out += group(2, "ENTITIES")

        for section in sections {
            let layer = String(format: "STATION_%04d", section.stationIndex)
            var pts = section.points2D
            // A closed polyline should not repeat its first vertex; the closed
            // flag conveys the wrap-around.
            if section.isClosed, pts.count >= 2,
               abs(pts.first!.x - pts.last!.x) < 1e-9, abs(pts.first!.y - pts.last!.y) < 1e-9 {
                pts.removeLast()
            }
            guard pts.count >= 2 else { continue }

            out += group(0, "POLYLINE")
            out += group(8, layer)
            out += group(66, "1")                              // vertices follow
            // R12 requires a dummy point on the POLYLINE header; strict readers
            // reject the entity without it.
            out += group(10, "0.0"); out += group(20, "0.0"); out += group(30, "0.0")
            out += group(70, section.isClosed ? "1" : "0")     // closed flag
            for p in pts {
                out += group(0, "VERTEX")
                out += group(8, layer)
                out += group(10, fmt(p.x * mToCm))
                out += group(20, fmt(p.y * mToCm))
                out += group(30, "0.0")                        // planar sections
            }
            out += group(0, "SEQEND")
            out += group(8, layer)
        }

        out += group(0, "ENDSEC")
        out += group(0, "EOF")
        return out
    }

    public static func write(_ sections: [CrossSection], to url: URL) throws {
        try dxf(from: sections).write(to: url, atomically: true, encoding: .utf8)
    }

    /// A DXF group: a numeric code line followed by its value line.
    private static func group(_ code: Int, _ value: String) -> String {
        "\(code)\n\(value)\n"
    }

    private static func fmt(_ value: Double) -> String { String(format: "%.4f", value) }
}
