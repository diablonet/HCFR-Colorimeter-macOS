// HCFR Colorimeter for macOS
// Copyright (C) 2026 Jorge Velázquez
//
// This program is free software; you can redistribute it and/or modify it under the terms of
// the GNU General Public License version 2 as published by the Free Software Foundation.
// It is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even
// the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See LICENSE.

import SwiftUI

/// Diagram shown in the Information panel.
enum InfoChart: String, CaseIterable, Identifiable {
    case balance = "Gray Scale Balance"
    case cieXY = "CIE xy"
    case cieUV = "CIE u'v'"
    var id: String { rawValue }
}

/// CIE 1931 2° spectral locus, 380–700 nm every 5 nm (chromaticity x, y).
private let spectralLocus: [(Double, Double)] = [
    (0.1741, 0.0050), (0.1740, 0.0050), (0.1738, 0.0049), (0.1736, 0.0049), (0.1733, 0.0048),
    (0.1730, 0.0048), (0.1726, 0.0048), (0.1721, 0.0048), (0.1714, 0.0051), (0.1703, 0.0058),
    (0.1689, 0.0069), (0.1669, 0.0086), (0.1644, 0.0109), (0.1611, 0.0138), (0.1566, 0.0177),
    (0.1510, 0.0227), (0.1440, 0.0297), (0.1355, 0.0399), (0.1241, 0.0578), (0.1096, 0.0868),
    (0.0913, 0.1327), (0.0687, 0.2007), (0.0454, 0.2950), (0.0235, 0.4127), (0.0082, 0.5384),
    (0.0039, 0.6548), (0.0139, 0.7502), (0.0389, 0.8120), (0.0743, 0.8338), (0.1142, 0.8262),
    (0.1547, 0.8059), (0.1929, 0.7816), (0.2296, 0.7543), (0.2658, 0.7243), (0.3016, 0.6923),
    (0.3373, 0.6589), (0.3731, 0.6245), (0.4087, 0.5896), (0.4441, 0.5547), (0.4788, 0.5202),
    (0.5125, 0.4866), (0.5448, 0.4544), (0.5752, 0.4242), (0.6029, 0.3965), (0.6270, 0.3725),
    (0.6482, 0.3514), (0.6658, 0.3340), (0.6801, 0.3197), (0.6915, 0.3083), (0.7006, 0.2993),
    (0.7079, 0.2920), (0.7140, 0.2859), (0.7190, 0.2809), (0.7230, 0.2770), (0.7260, 0.2740),
    (0.7283, 0.2717), (0.7300, 0.2700), (0.7311, 0.2689), (0.7320, 0.2680), (0.7327, 0.2673),
    (0.7334, 0.2666), (0.7340, 0.2660), (0.7344, 0.2656), (0.7346, 0.2654), (0.7347, 0.2653),
]

/// Point-in-polygon (ray casting) on the spectral locus, in xy chromaticity.
private func insideLocus(_ x: Double, _ y: Double) -> Bool {
    var inside = false
    var j = spectralLocus.count - 1
    for i in 0..<spectralLocus.count {
        let (xi, yi) = spectralLocus[i], (xj, yj) = spectralLocus[j]
        if (yi > y) != (yj > y), x < (xj - xi) * (y - yi) / (yj - yi) + xi { inside.toggle() }
        j = i
    }
    return inside
}

/// CIE 1976 u'v' from CIE 1931 xy.
private func uv(_ x: Double, _ y: Double) -> (Double, Double) {
    let d = -2 * x + 12 * y + 3
    return d == 0 ? (0, 0) : (4 * x / d, 9 * y / d)
}

/// Colored background of the locus (approximate sRGB colors), computed once per size and mode.
@MainActor
private enum LocusImage {
    private static var cache: [String: CGImage] = [:]

    static func image(width: Int, height: Int, uvMode: Bool, toChart: (Double, Double) -> CGPoint,
                      fromChart: (CGPoint) -> (Double, Double)) -> CGImage? {
        let key = "\(width)x\(height)\(uvMode)"
        if let img = cache[key] { return img }
        // XYZ -> linear sRGB
        let m: [[Double]] = [[3.2406, -1.5372, -0.4986], [-0.9689, 1.8758, 0.0415], [0.0557, -0.2040, 1.0570]]
        // Half resolution (smooth background, fast when the window is resized)
        let f = 2
        let width = max(width / f, 1), height = max(height / f, 1)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for py in 0..<height {
            for px in 0..<width {
                let pt = CGPoint(x: Double(px * f) + 1, y: Double(py * f) + 1)
                var (x, y) = fromChart(pt)
                if uvMode {   // u'v' -> xy
                    let (u, v) = (x, y)
                    let d = 6 * u - 16 * v + 12
                    x = 9 * u / d; y = 4 * v / d
                }
                guard y > 0, insideLocus(x, y) else { continue }
                let X = x / y, Z = (1 - x - y) / y
                var rgb = m.map { $0[0] * X + $0[1] * 1 + $0[2] * Z }.map { max($0, 0) }
                let mx = rgb.max() ?? 1
                rgb = rgb.map { $0 / max(mx, 1e-9) }
                let enc = rgb.map { v -> UInt8 in
                    let g = v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
                    return UInt8(min(max(g * 255 * 0.85, 0), 255))
                }
                let i = (py * width + px) * 4
                pixels[i] = enc[0]; pixels[i + 1] = enc[1]; pixels[i + 2] = enc[2]; pixels[i + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let img = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        if cache.count > 8 { cache.removeAll() }
        cache[key] = img
        return img
    }
}

/// CIE chromaticity diagram (xy or u'v') with the standard's gamut, reference targets and the
/// measured primaries/secondaries and gray scale, like HCFR's CIE chart.
struct CIEChart: View {
    @ObservedObject var session: Session
    let uvMode: Bool

    private var range: (x: ClosedRange<Double>, y: ClosedRange<Double>) {
        uvMode ? (0...0.65, 0...0.62) : (0...0.8, 0...0.9)
    }

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in draw(&ctx, size) }
                .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(Color(white: 0.12))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func coords(_ x: Double, _ y: Double) -> (Double, Double) { uvMode ? uv(x, y) : (x, y) }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let pad: CGFloat = 30
        let r = range
        // Keep the aspect ratio 1:1 so the horseshoe is not distorted
        let scale = min((size.width - pad - 10) / (r.x.upperBound - r.x.lowerBound),
                        (size.height - pad - 10) / (r.y.upperBound - r.y.lowerBound))
        let origin = CGPoint(x: pad, y: size.height - pad)
        let toChart: (Double, Double) -> CGPoint = { a, b in
            CGPoint(x: origin.x + (a - r.x.lowerBound) * scale, y: origin.y - (b - r.y.lowerBound) * scale)
        }
        let toChartXY: (Double, Double) -> CGPoint = { x, y in let c = coords(x, y); return toChart(c.0, c.1) }
        let plotW = (r.x.upperBound - r.x.lowerBound) * scale, plotH = (r.y.upperBound - r.y.lowerBound) * scale

        // Grid and axis labels
        let step = 0.1
        for v in stride(from: r.x.lowerBound, through: r.x.upperBound + 1e-9, by: step) {
            let p = toChart(v, r.y.lowerBound)
            var line = Path(); line.move(to: p); line.addLine(to: CGPoint(x: p.x, y: p.y - plotH))
            ctx.stroke(line, with: .color(.teal.opacity(0.25)), lineWidth: 0.5)
            ctx.draw(Text(String(format: "%.1f", v)).font(.caption2).foregroundStyle(.white.opacity(0.8)),
                     at: CGPoint(x: p.x, y: p.y + 9))
        }
        for v in stride(from: r.y.lowerBound, through: r.y.upperBound + 1e-9, by: step) {
            let p = toChart(r.x.lowerBound, v)
            var line = Path(); line.move(to: p); line.addLine(to: CGPoint(x: p.x + plotW, y: p.y))
            ctx.stroke(line, with: .color(.teal.opacity(0.25)), lineWidth: 0.5)
            ctx.draw(Text(String(format: "%.1f", v)).font(.caption2).foregroundStyle(.white.opacity(0.8)),
                     at: CGPoint(x: p.x - 14, y: p.y))
        }
        ctx.draw(Text(uvMode ? "u'" : "x").font(.caption.bold()).foregroundStyle(.white),
                 at: CGPoint(x: origin.x + plotW - 6, y: origin.y - 10))
        ctx.draw(Text(uvMode ? "v'" : "y").font(.caption.bold()).foregroundStyle(.white),
                 at: CGPoint(x: origin.x + 10, y: origin.y - plotH + 8))

        // Colored horseshoe
        let w = Int(size.width), h = Int(size.height)
        if w > 0, h > 0, let img = LocusImage.image(
            width: w, height: h, uvMode: uvMode, toChart: toChartXY,
            fromChart: { p in ((Double(p.x) - origin.x) / scale + r.x.lowerBound, (origin.y - Double(p.y)) / scale + r.y.lowerBound) }) {
            ctx.draw(Image(decorative: img, scale: 1), in: CGRect(origin: .zero, size: size))
        }
        let locus = Path { p in
            for (i, pt) in spectralLocus.enumerated() {
                let c = toChartXY(pt.0, pt.1)
                if i == 0 { p.move(to: c) } else { p.addLine(to: c) }
            }
            p.closeSubpath()
        }
        ctx.stroke(locus, with: .color(.white.opacity(0.7)), lineWidth: 1)

        // Reference gamut of the standard and reference targets (squares)
        let ref = session.ref
        let refXYZ = PatchColor.allCases.map { p -> (PatchColor, XYZ) in
            let v = ref.rgbToXYZ.apply(p.rgb); return (p, XYZ(X: v[0], Y: v[1], Z: v[2]))
        }
        let prim = refXYZ.prefix(3).map { toChartXY($0.1.x, $0.1.y) }
        var tri = Path(); tri.move(to: prim[0]); tri.addLine(to: prim[1]); tri.addLine(to: prim[2]); tri.closeSubpath()
        ctx.stroke(tri, with: .color(.white), lineWidth: 1.5)
        for (patch, xyz) in refXYZ {
            let c = patch == .white ? toChartXY(ref.white.x, ref.white.y) : toChartXY(xyz.x, xyz.y)
            let s: CGFloat = 9
            ctx.stroke(Path(CGRect(x: c.x - s / 2, y: c.y - s / 2, width: s, height: s)),
                       with: .color(.white), lineWidth: 1.5)
        }

        // Measured gamut (dashed) and measured colors (dots)
        let measured = session.patchResults
        let mp = measured.prefix(3).compactMap { r in r.xyz.map { toChartXY($0.x, $0.y) } }
        if mp.count == 3 {
            var mt = Path(); mt.move(to: mp[0]); mt.addLine(to: mp[1]); mt.addLine(to: mp[2]); mt.closeSubpath()
            ctx.stroke(mt, with: .color(.yellow), style: StrokeStyle(lineWidth: 1.2, dash: [5, 3]))
        }
        for res in measured {
            guard let xyz = res.xyz, xyz.Y > 0 else { continue }
            let c = toChartXY(xyz.x, xyz.y)
            let selected = session.view == .primariesSecondaries && res.patch == session.selectedPatch
            let d: CGFloat = selected ? 10 : 7
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)), with: .color(.black))
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - d / 2 + 1.5, y: c.y - d / 2 + 1.5, width: d - 3, height: d - 3)),
                     with: .color(dotColor(res.patch)))
        }

        // Gray scale points
        for res in session.results where res.xyz != nil && res.level > 0 {
            guard let xyz = res.xyz, xyz.Y > 0 else { continue }
            let c = toChartXY(xyz.x, xyz.y)
            let selected = session.view == .grayScale && res.level == session.selectedLevel
            let d: CGFloat = selected ? 8 : 5
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)),
                     with: .color(selected ? .orange : Color(white: 0.85)))
        }

        // Legend
        let legend = "\(session.standard.shortName) · \(session.white.rawValue)   □ reference   ● measured"
            + (mp.count == 3 ? "   - - measured gamut" : "")
        ctx.draw(Text(legend).font(.caption2).foregroundStyle(.white.opacity(0.85)),
                 at: CGPoint(x: size.width - 8, y: 10), anchor: .topTrailing)
    }

    private func dotColor(_ p: PatchColor) -> Color {
        switch p {
        case .red: return .red
        case .green: return .green
        case .blue: return .blue
        case .yellow: return .yellow
        case .cyan: return .cyan
        case .magenta: return Color(red: 1, green: 0, blue: 1)
        case .white: return .white
        }
    }
}
