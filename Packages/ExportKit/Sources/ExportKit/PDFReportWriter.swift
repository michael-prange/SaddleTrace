import Foundation
import CoreGraphics
import CoreText
import simd
import MeshKit

/// Renders a single-page US-Letter PDF of the back's cross-sections and topline,
/// drawn to an exact clean scale for saddle fitting (Design §11 PDF report).
///
/// Layout: the longitudinal **topline (rocker)** on top (withers labeled), then a
/// fanned stack of the transverse **sections** centered on the spine — station 0
/// is the withers ("Withers #1", with L/R), the rest numbered. A "Scale 1:N"
/// label and 2-unit scale bars make the plot measurable with a ruler.
/// Paper size for the cross-section report (drawn landscape). Tabloid (11×17)
/// and A3 give the fitter more room; Letter and A4 are the common defaults.
public enum PDFPageSize: String, CaseIterable, Sendable {
    case letter, tabloid, a4, a3

    /// Landscape dimensions in points (72 pt/in).
    public var landscapeSize: CGSize {
        switch self {
        case .letter: CGSize(width: 792, height: 612)      // 11 × 8.5 in
        case .tabloid: CGSize(width: 1224, height: 792)    // 17 × 11 in
        case .a4: CGSize(width: 841.89, height: 595.28)    // 297 × 210 mm
        case .a3: CGSize(width: 1190.55, height: 841.89)   // 420 × 297 mm
        }
    }

    public var displayName: String {
        switch self {
        case .letter: "US Letter (8.5 × 11 in)"
        case .tabloid: "Tabloid (11 × 17 in)"
        case .a4: "A4"
        case .a3: "A3 (≈ 11 × 17 in)"
        }
    }
}

public enum PDFReportWriter {

    private static let margin: CGFloat = 40
    /// Tight side margin so a full 16 in section fits at 1:1 on Tabloid; shared by
    /// the section stack and the topline bands so both use one content width.
    private static let sideMargin: CGFloat = 18
    private static let pointsPerMetre1to1: CGFloat = 39.3700787 * 72

    private static let niceScales: [CGFloat] = [1, 1.0/2, 1.0/3, 1.0/4, 1.0/5, 1.0/6, 1.0/8, 1.0/10]

    public static func pdfData(animalName: String, dateText: String,
                               sections: [CrossSection], rocker: [SIMD2<Double>],
                               imperial: Bool, pageSize: PDFPageSize = .letter) -> Data {
        let ordered = sections.sorted { $0.stationIndex < $1.stationIndex }
        let page = pageSize.landscapeSize
        let pdf = NSMutableData()
        guard let consumer = CGDataConsumer(data: pdf as CFMutableData) else { return Data() }
        var mediaBox = CGRect(origin: .zero, size: page)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return Data() }

        // One scale for the whole report: the largest clean scale whose widest
        // cross-section fits the page width. True size (1:1) on Tabloid/A3;
        // reduced (e.g. 1:2) on Letter/A4. The spine uses the SAME scale so pages
        // 1 and 2 join into one continuous back profile.
        let contentWidth = page.width - 2 * sideMargin
        let widestSection = ordered.map { extentU($0.points2D) }.max() ?? 0.001
        func sectionFits(_ f: CGFloat) -> Bool { CGFloat(widestSection) * pointsPerMetre1to1 * f <= contentWidth }
        let scale: CGFloat = sectionFits(1) ? 1 : (niceScales.first { sectionFits($0) } ?? niceScales.last!)
        let ppm = pointsPerMetre1to1 * scale

        // Page 1: cross-sections + the front run of the topline, at the shared scale.
        ctx.beginPDFPage(nil)
        drawSectionsPage(in: ctx, page: page, animalName: animalName, dateText: dateText,
                         sections: ordered, rocker: rocker, imperial: imperial, ppm: ppm, scale: scale)
        ctx.endPDFPage()

        // Page 2: the topline continued at the same scale; placed to the right of
        // page 1 (top edges level) it forms one continuous back, cut off at the edge.
        ctx.beginPDFPage(nil)
        drawToplinePage(in: ctx, page: page, animalName: animalName, dateText: dateText,
                        rocker: rocker, imperial: imperial, ppm: ppm, scale: scale)
        ctx.endPDFPage()

        ctx.closePDF()
        return pdf as Data
    }

    public static func write(animalName: String, dateText: String,
                             sections: [CrossSection], rocker: [SIMD2<Double>],
                             imperial: Bool, pageSize: PDFPageSize = .letter, to url: URL) throws {
        try pdfData(animalName: animalName, dateText: dateText,
                    sections: sections, rocker: rocker, imperial: imperial, pageSize: pageSize)
            .write(to: url, options: .atomic)
    }

    // MARK: - Drawing

    /// Page 1 — the transverse cross-sections plus the front run of the topline,
    /// both at the shared `scale` (1:1 on Tabloid/A3, reduced on Letter/A4 so the
    /// widest ±8 in section still fits). `ppm = pointsPerMetre1to1 * scale`.
    private static func drawSectionsPage(in ctx: CGContext, page: CGSize, animalName: String,
                                         dateText: String, sections: [CrossSection],
                                         rocker: [SIMD2<Double>], imperial: Bool,
                                         ppm: CGFloat, scale: CGFloat) {
        let pageWidth = page.width, pageHeight = page.height
        let contentLeft = sideMargin
        let contentWidth = pageWidth - 2 * sideMargin

        let maxSectionDepth = sections.map { extentV($0.points2D) }.max() ?? 0.001

        let targetFan: CGFloat = 60   // ~5/6-inch target vertical spacing (roomy so
                                      // the colored sections are easy to tell apart)
        let titleSpace: CGFloat = 66
        let scaleBarSpace: CGFloat = 56
        let usableHeight = pageHeight - 2 * margin - titleSpace - scaleBarSpace
        let gaps = CGFloat(max(sections.count - 1, 0))
        let heightForFan = usableHeight - CGFloat(maxSectionDepth) * ppm
        let fanOffset = gaps > 0 ? max(4, min(targetFan, heightForFan / gaps)) : targetFan

        // Title.
        let top = pageHeight - margin
        drawText(animalName, at: CGPoint(x: contentLeft, y: top - 18), size: 18, bold: true, in: ctx)
        let scaleLabel = scale == 1 ? "Scale 1:1 (true size)" : "Scale 1:\(scaleString(scale))"
        drawText("\(dateText)   ·   Cross-sections   ·   \(scaleLabel)",
                 at: CGPoint(x: contentLeft, y: top - 36), size: 11, in: ctx)

        // Section stack, centered on the spine (u = 0), fanned downward.
        let centerX = contentLeft + contentWidth / 2
        let stackTop = top - titleSpace
        for (i, section) in sections.enumerated() {
            let apexY = stackTop - CGFloat(i) * fanOffset
            let pts = section.points2D
            guard pts.count > 1 else { continue }

            var path = CGMutablePath()
            for (j, p) in pts.enumerated() {
                let pt = CGPoint(x: centerX + CGFloat(p.x) * ppm, y: apexY + CGFloat(p.y) * ppm)
                if j == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
            }
            strokeColored(path, in: ctx, width: 1.6, color: sectionColor(i))

            let minU = pts.map(\.x).min()!, maxU = pts.map(\.x).max()!
            let leftX = centerX + CGFloat(minU) * ppm
            let rightX = centerX + CGFloat(maxU) * ppm
            if i == 0 {
                // Withers: title above the apex, L/R at the ends.
                drawText("Withers #0", at: CGPoint(x: centerX - 26, y: apexY + 6), size: 10, bold: true, in: ctx)
                drawText("L", at: CGPoint(x: leftX - 14, y: apexY - 4), size: 10, bold: true, in: ctx)
                drawText("R", at: CGPoint(x: rightX + 6, y: apexY - 4), size: 10, bold: true, in: ctx)
            } else {
                drawText("#\(i)", at: CGPoint(x: rightX + 8, y: apexY - 4), size: 10, in: ctx)
            }
        }

        // Legend (top-right): section number, distance from the withers, and the
        // matching curve color.
        drawLegend(in: ctx, page: page, sections: sections, imperial: imperial)

        // Topline in the lower band — the first page-width of arc at the shared
        // scale. The z→y mapping and ppm match page 2, so placing page 2 to the
        // right of page 1 continues the spine seamlessly at the seam.
        if let split = toplineSplit(rocker, pageWidth: pageWidth, ppm: ppm) {
            drawToplineSegment(in: ctx, rocker: rocker, split: split, ppm: ppm,
                               arcLo: split.minArc, arcHi: split.page1End, originArc: split.minArc,
                               markWithers: true)
        }

        drawScaleBars(in: ctx, ppm: ppm, imperial: imperial, originX: contentLeft, originY: margin + 12)
    }

    /// Page 2 — the **topline continued**, at the shared `scale`, using the same
    /// z→y mapping and ppm as page 1. Placed to the right of page 1 (top edges
    /// level), the two pages form one continuous back; anything past this page's
    /// right edge is cut off.
    private static func drawToplinePage(in ctx: CGContext, page: CGSize, animalName: String,
                                        dateText: String, rocker: [SIMD2<Double>], imperial: Bool,
                                        ppm: CGFloat, scale: CGFloat) {
        guard let split = toplineSplit(rocker, pageWidth: page.width, ppm: ppm) else { return }
        let pageHeight = page.height
        let contentLeft = sideMargin

        // Title.
        let top = pageHeight - margin
        let scaleLabel = scale == 1 ? "Scale 1:1 (true size)" : "Scale 1:\(scaleString(scale))"
        drawText(animalName, at: CGPoint(x: contentLeft, y: top - 18), size: 18, bold: true, in: ctx)
        drawText("\(dateText)   ·   Topline — continued   ·   \(scaleLabel)",
                 at: CGPoint(x: contentLeft, y: top - 36), size: 11, in: ctx)

        if split.page1End >= split.maxArc - 1e-6 {
            drawText("The full topline fits on page 1.",
                     at: CGPoint(x: contentLeft, y: top - 52), size: 10, gray: 0.4, in: ctx)
            return
        }
        drawText("Place to the right of page 1, top edges level, to continue the spine.",
                 at: CGPoint(x: contentLeft, y: top - 52), size: 10, gray: 0.4, in: ctx)

        drawToplineSegment(in: ctx, rocker: rocker, split: split, ppm: ppm,
                           arcLo: split.page1End, arcHi: split.page2End, originArc: split.page1End,
                           markWithers: false)

        if split.page2End < split.maxArc - 1e-6 {
            drawText("(spine continues past this edge — cut off)",
                     at: CGPoint(x: contentLeft, y: toplineBaseline - 22), size: 9, gray: 0.5, in: ctx)
        }

        drawScaleBars(in: ctx, ppm: ppm, imperial: imperial, originX: contentLeft, originY: margin + 12)
    }

    /// Splits the topline into page-width strips at the shared scale: page 1 holds
    /// the arc that fills one page width, page 2 continues, and anything beyond
    /// page 2's right edge is truncated.
    private struct ToplineSplit {
        let minArc, maxArc, zmin: Double
        let pageSpan: Double   // metres of arc that fill one page width at the scale
        var page1End: Double { min(minArc + pageSpan, maxArc) }
        var page2End: Double { min(minArc + 2 * pageSpan, maxArc) }
    }

    /// Baseline (points above the page's bottom edge) at which `zmin` is drawn.
    /// Identical on both pages, so the strips register when top edges are level.
    private static let toplineBaseline: CGFloat = 64

    private static func toplineSplit(_ rocker: [SIMD2<Double>], pageWidth: CGFloat, ppm: CGFloat) -> ToplineSplit? {
        guard rocker.count > 1 else { return nil }
        let minArc = rocker.map(\.x).min()!, maxArc = rocker.map(\.x).max()!
        let zmin = rocker.map(\.y).min()!
        let contentWidth = pageWidth - 2 * sideMargin
        let pageSpan = Double(contentWidth / ppm)
        return ToplineSplit(minArc: minArc, maxArc: maxArc, zmin: zmin, pageSpan: pageSpan)
    }

    /// Draws one strip of the topline over `[arcLo, arcHi]` at `ppm`, with the
    /// left end (`originArc`) at `sideMargin`; optionally marks the withers.
    private static func drawToplineSegment(in ctx: CGContext, rocker: [SIMD2<Double>], split: ToplineSplit,
                                           ppm: CGFloat, arcLo: Double, arcHi: Double, originArc: Double,
                                           markWithers: Bool) {
        func x(_ arc: Double) -> CGFloat { sideMargin + CGFloat(arc - originArc) * ppm }
        func y(_ z: Double) -> CGFloat { toplineBaseline + CGFloat(z - split.zmin) * ppm }

        let pts = clipToArc(rocker, lo: arcLo, hi: arcHi)
        guard pts.count > 1 else { return }

        var path = CGMutablePath()
        for (i, p) in pts.enumerated() {
            let pt = CGPoint(x: x(p.x), y: y(p.y))
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        stroke(path, in: ctx, width: 1.6, gray: 0.15)

        if markWithers {
            let w = rocker[0]
            let wp = CGPoint(x: x(w.x), y: y(w.y))
            dot(at: wp, in: ctx)
            drawText("Withers", at: CGPoint(x: wp.x + 6, y: wp.y - 13), size: 10, in: ctx)
        }
    }

    /// Clips a monotonic-in-arc polyline to `[lo, hi]`, interpolating the ends.
    private static func clipToArc(_ pts: [SIMD2<Double>], lo: Double, hi: Double) -> [SIMD2<Double>] {
        var out: [SIMD2<Double>] = []
        for i in pts.indices {
            let p = pts[i]
            if i > 0 {
                let q = pts[i - 1]
                for b in [lo, hi] where (q.x - b) * (p.x - b) < 0 {
                    let t = (b - q.x) / (p.x - q.x)
                    out.append(SIMD2<Double>(b, q.y + t * (p.y - q.y)))
                }
            }
            if p.x >= lo && p.x <= hi { out.append(p) }
        }
        return out.sorted { $0.x < $1.x }
    }

    /// Draws horizontal + vertical scale bars (2 in / 5 cm) at the given origin.
    private static func drawScaleBars(in ctx: CGContext, ppm: CGFloat, imperial: Bool,
                                      originX: CGFloat, originY: CGFloat) {
        let barMetres = imperial ? 2 * 0.0254 : 0.05
        let barLen = CGFloat(barMetres) * ppm
        var bars = CGMutablePath()
        bars.move(to: CGPoint(x: originX, y: originY)); bars.addLine(to: CGPoint(x: originX + barLen, y: originY))
        bars.move(to: CGPoint(x: originX, y: originY)); bars.addLine(to: CGPoint(x: originX, y: originY + barLen))
        stroke(bars, in: ctx, width: 2, gray: 0)
        let barLabel = imperial ? "2 in" : "5 cm"
        drawText(barLabel, at: CGPoint(x: originX + barLen + 6, y: originY - 4), size: 10, in: ctx)
        drawText(barLabel, at: CGPoint(x: originX + 4, y: originY + barLen + 2), size: 10, in: ctx)
    }

    // MARK: - Helpers

    private static func extentU(_ pts: [SIMD2<Double>]) -> Double {
        guard let lo = pts.map(\.x).min(), let hi = pts.map(\.x).max() else { return 0 }
        return hi - lo
    }
    private static func extentV(_ pts: [SIMD2<Double>]) -> Double {
        guard let lo = pts.map(\.y).min(), let hi = pts.map(\.y).max() else { return 0 }
        return hi - lo
    }

    private static func scaleString(_ scale: CGFloat) -> String {
        let inv = (1 / scale).rounded()
        return String(Int(inv))
    }

    /// A well-separated color per section index. Hues step by the golden angle so
    /// adjacent sections (adjacent in the fan) land far apart on the color wheel,
    /// maximizing differentiability; brightness alternates to further separate them.
    private static func sectionColor(_ i: Int) -> CGColor {
        let hue = (Double(i) * 0.61803398875).truncatingRemainder(dividingBy: 1.0)
        let brightness = i.isMultiple(of: 2) ? 0.82 : 0.62
        return hsbColor(hue, 0.95, brightness)
    }

    /// HSB → RGB `CGColor` (device RGB), avoiding platform UIColor/NSColor.
    private static func hsbColor(_ h: Double, _ s: Double, _ v: Double) -> CGColor {
        let i = Int(h * 6), f = h * 6 - Double(Int(h * 6))
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        let (r, g, b): (Double, Double, Double)
        switch ((i % 6) + 6) % 6 {
        case 0: (r, g, b) = (v, t, p)
        case 1: (r, g, b) = (q, v, p)
        case 2: (r, g, b) = (p, v, t)
        case 3: (r, g, b) = (p, q, v)
        case 4: (r, g, b) = (t, p, v)
        default: (r, g, b) = (v, p, q)
        }
        return CGColor(red: r, green: g, blue: b, alpha: 1)
    }

    /// Draws the legend box in the top-right corner: one row per section with a
    /// color swatch, the section number, and its distance from the withers.
    private static func drawLegend(in ctx: CGContext, page: CGSize, sections: [CrossSection], imperial: Bool) {
        guard !sections.isEmpty else { return }
        let withersArc = sections.first { $0.stationIndex == 0 }?.arcLength
            ?? sections.map(\.arcLength).min() ?? 0

        let rowH: CGFloat = 14, pad: CGFloat = 8, titleH: CGFloat = 16, boxW: CGFloat = 172
        let boxH = pad * 2 + titleH + rowH * CGFloat(sections.count)
        let right = page.width - margin
        let topY = page.height - margin - 4
        let box = CGRect(x: right - boxW, y: topY - boxH, width: boxW, height: boxH)

        ctx.saveGState()
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.92))
        ctx.setStrokeColor(CGColor(gray: 0.35, alpha: 1))
        ctx.setLineWidth(0.8)
        ctx.addRect(box); ctx.drawPath(using: .fillStroke)
        ctx.restoreGState()

        drawText("Sections (from withers)", at: CGPoint(x: box.minX + pad, y: box.maxY - titleH),
                 size: 10, bold: true, in: ctx)

        for (i, section) in sections.enumerated() {
            let y = box.maxY - titleH - pad - CGFloat(i) * rowH
            let swatch = CGMutablePath()
            swatch.move(to: CGPoint(x: box.minX + pad, y: y + 4))
            swatch.addLine(to: CGPoint(x: box.minX + pad + 22, y: y + 4))
            strokeColored(swatch, in: ctx, width: 2.6, color: sectionColor(i))

            let dist = abs(section.arcLength - withersArc)
            let distStr = imperial ? String(format: "%.1f in", dist / 0.0254)
                                   : String(format: "%.1f cm", dist * 100)
            let label = i == 0 ? "#0  Withers" : "#\(i)   \(distStr)"
            drawText(label, at: CGPoint(x: box.minX + pad + 30, y: y), size: 9, in: ctx)
        }
    }

    private static func strokeColored(_ path: CGPath, in ctx: CGContext, width: CGFloat, color: CGColor) {
        ctx.saveGState()
        ctx.setStrokeColor(color)
        ctx.setLineWidth(width)
        ctx.setLineJoin(.round)
        ctx.addPath(path)
        ctx.strokePath()
        ctx.restoreGState()
    }

    private static func stroke(_ path: CGPath, in ctx: CGContext, width: CGFloat, gray: CGFloat) {
        ctx.saveGState()
        ctx.setStrokeColor(CGColor(gray: gray, alpha: 1))
        ctx.setLineWidth(width)
        ctx.setLineJoin(.round)
        ctx.addPath(path)
        ctx.strokePath()
        ctx.restoreGState()
    }

    private static func dot(at p: CGPoint, in ctx: CGContext) {
        ctx.saveGState()
        ctx.setFillColor(CGColor(red: 0.85, green: 0.1, blue: 0.1, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5))
        ctx.restoreGState()
    }

    private static func drawText(_ string: String, at point: CGPoint, size: CGFloat,
                                 bold: Bool = false, gray: CGFloat = 0, in ctx: CGContext) {
        let fontName = bold ? "Helvetica-Bold" : "Helvetica"
        let font = CTFontCreateWithName(fontName as CFString, size, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(gray: gray, alpha: 1),
        ]
        guard let attrString = CFAttributedStringCreate(nil, string as CFString, attributes as CFDictionary) else { return }
        let line = CTLineCreateWithAttributedString(attrString)
        ctx.saveGState()
        ctx.textPosition = point
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}
