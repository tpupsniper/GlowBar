import SwiftUI

enum GlowRenderer {

    /// `island` is the black shape at the top centre: the real notch, the notch widened by the
    /// music player, or nil on screens without a notch when nothing is showing.
    static func draw(_ ctx: inout GraphicsContext, size: CGSize, info: ScreenInfo, style: GlowStyle, island: CGRect?,
                     events: [GlowEvent], now: Date, settings: Settings) {
        currentNotch = info.notch
        let base = basePath(style: style, info: info, island: island)
        let top: Path
        switch style {
        case .notch: top = base
        case .straight: top = straightLine(info)
        default: top = topPath(info, island: island)
        }
        let width = CGFloat(settings.thickness)
        let intensity = settings.intensity

        for ev in events {
            let elapsed = now.timeIntervalSince(ev.start)
            var alpha = envelope(elapsed: elapsed, duration: ev.duration) * intensity
            guard alpha > 0.001 else { continue }
            let p = clamp(elapsed / ev.duration)

            switch ev.animation {
            case .level:
                let f = clamp(ev.displayedLevel(at: now))
                if settings.levelFromCenter {
                    // Grows out of the top centre (under the notch) and spreads left and right.
                    // On "whole screen edge" it keeps going down the sides and meets at the bottom.
                    let track = style == .edges ? edgesFromTopCenter(info, island: island) : top
                    stroke(&ctx, track, ev.color, width * 0.7, alpha * 0.18, blur: false)
                    if style == .edges {
                        stroke(&ctx, track.trimmedPath(from: 0, to: f / 2), ev.color, width, alpha)
                        stroke(&ctx, track.trimmedPath(from: 1 - f / 2, to: 1), ev.color, width, alpha)
                    } else {
                        stroke(&ctx, track.trimmedPath(from: 0.5 - f / 2, to: 0.5 + f / 2), ev.color, width, alpha)
                    }
                } else {
                    stroke(&ctx, top, ev.color, width * 0.7, alpha * 0.18, blur: false)
                    stroke(&ctx, top.trimmedPath(from: 0, to: f), ev.color, width, alpha)
                }

            case .sweep, .sweepReverse:
                let e = easeInOut(p)
                var c = -0.15 + 1.3 * e
                if case .sweepReverse = ev.animation { c = 1 - c }
                stroke(&ctx, base, ev.color, width * 0.6, alpha * 0.25 * (1 - e), blur: false)
                stroke(&ctx, base.trimmedPath(from: clamp(c - 0.13), to: clamp(c + 0.13)), ev.color, width * 1.2, alpha)

            case .fill:
                let f = easeInOut(clamp(elapsed / (ev.duration * 0.45)))
                if style == .edges {
                    // all the way around the screen, starting at the top
                    stroke(&ctx, base.trimmedPath(from: 0, to: f), ev.color, width * 1.1, alpha)
                } else {
                    stroke(&ctx, top.trimmedPath(from: 0, to: f), ev.color, width * 1.1, alpha)
                }

            case .expand:
                let f = easeInOut(clamp(elapsed / (ev.duration * 0.5)))
                if style == .edges {
                    // out of the notch, down both sides, meeting at the bottom
                    let ring = edgesFromTopCenter(info, island: island)
                    stroke(&ctx, ring.trimmedPath(from: 0, to: f / 2), ev.color, width * 1.1, alpha)
                    stroke(&ctx, ring.trimmedPath(from: 1 - f / 2, to: 1), ev.color, width * 1.1, alpha)
                } else {
                    stroke(&ctx, base.trimmedPath(from: 0.5 - f / 2, to: 0.5 + f / 2), ev.color, width * 1.1, alpha)
                }

            case .pulse(let n):
                alpha *= 0.5 - 0.5 * cos(2 * .pi * Double(n) * p)
                stroke(&ctx, base, ev.color, width, alpha)

            case .flash:
                alpha *= max(0, 1 - p)
                stroke(&ctx, base, ev.color, width * 1.3, alpha)

            case .wave:
                let t = now.timeIntervalSinceReferenceDate * settings.speed
                let breathe = 0.75 + 0.25 * sin(t * 1.3)
                waveStroke(&ctx, base, ev.color, width, alpha * breathe, phase: t * 0.22, size: size)

            case .progress(let stored):
                var f = stored
                if ev.kind == .musicProgress && ev.duration == .infinity { f = MusicMonitor.shared.progress(at: now) }
                if ev.kind == .focusTimer && ev.duration == .infinity { f = FocusTimer.shared.progress(at: now) }
                let pf = clamp(f)
                if settings.progressFromCenter {
                    // grows out of the notch to both sides, like the brightness bar
                    if style == .edges {
                        let ring = edgesFromTopCenter(info, island: island)
                        stroke(&ctx, ring.trimmedPath(from: 0, to: pf / 2), ev.color, width * 0.55, alpha * 0.85, blur: true, soft: true)
                        stroke(&ctx, ring.trimmedPath(from: 1 - pf / 2, to: 1), ev.color, width * 0.55, alpha * 0.85, blur: true, soft: true)
                    } else {
                        stroke(&ctx, top.trimmedPath(from: 0.5 - pf / 2, to: 0.5 + pf / 2), ev.color, width * 0.55, alpha * 0.85, blur: true, soft: true)
                    }
                } else {
                    stroke(&ctx, top.trimmedPath(from: 0, to: pf), ev.color, width * 0.55, alpha * 0.85, blur: true, soft: true)
                }

            case .steady:
                let t = now.timeIntervalSinceReferenceDate
                let breathe = 0.8 + 0.2 * sin(t * 2.0)
                stroke(&ctx, base, ev.color, width * 0.9, alpha * 0.6 * breathe)

            case .screenWaves:
                // Three rings of light rolling out from the top centre and across the whole screen.
                let center = CGPoint(x: size.width / 2, y: 0)
                let maxR = Double(hypot(size.width / 2, size.height)) * 1.05
                for k in 0..<3 {
                    let start = Double(k) * 0.22
                    let q = (p - start) / 0.7
                    guard q > 0, q < 1 else { continue }
                    let r = CGFloat(easeOut(q) * maxR)
                    let ring = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
                    let a: Double = alpha * (1 - q) * (k == 0 ? 1 : 0.75)
                    stroke(&ctx, ring, ev.color, width * 2.2, a)
                }
                // the top bar lights up too
                stroke(&ctx, base, ev.color, width, alpha * 0.8 * (1 - p))

            case .keyHit(let x, let pos, let cw):
                if style == .edges {
                    // A bead of light springs along the edge and bounces to a stop.
                    let travel = 0.16
                    let spring = 1 - exp(-5 * p) * cos(9 * p)
                    let head = pos + (cw ? 1 : -1) * travel * spring
                    let tail = 0.05 * (1 - p * 0.6)
                    strokeWrapped(&ctx, base, head - tail / 2, head + tail / 2, ev.color, width * 0.9, alpha * (1 - p))
                } else {
                    let r = 0.015 + 0.06 * p
                    stroke(&ctx, straightLine(info).trimmedPath(from: clamp(x - r), to: clamp(x + r)), ev.color, width * 0.8, alpha * (1 - p))
                }

            case .ripple(let x):
                let r = 0.015 + 0.06 * p
                stroke(&ctx, straightLine(info).trimmedPath(from: clamp(x - r), to: clamp(x + r)), ev.color, width * 0.8, alpha * (1 - p))
            }
        }
    }

    // MARK: paths

    static func straightLine(_ info: ScreenInfo) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 1))
        p.addLine(to: CGPoint(x: info.size.width, y: 1))
        return p
    }

    /// Adds the part of a line along the top that dips down and around the island.
    /// The notch of the screen being drawn (set at the start of draw), so islands that are
    /// thinner than the real notch can step down around it.
    static var currentNotch: CGRect?

    /// Is the island's wing thinner than the physical notch (so the outline steps down around it)?
    static func stepped(_ rect: CGRect) -> CGRect? {
        guard let n = currentNotch, rect.height < n.height - 0.5, rect.minX < n.minX - 8, rect.maxX > n.maxX + 8 else { return nil }
        return n
    }

    /// Left half of the outline: from the top line, down the left wing (and the real notch if it's deeper), to the bottom middle.
    static func addIslandLeft(_ p: inout Path, _ rect: CGRect) {
        let r: CGFloat = min(10, rect.height / 2)
        let x0 = rect.minX, wb = rect.maxY + 1
        p.addLine(to: CGPoint(x: x0 - 6, y: 1))
        p.addQuadCurve(to: CGPoint(x: x0, y: min(7, wb - r)), control: CGPoint(x: x0, y: 1))
        p.addLine(to: CGPoint(x: x0, y: wb - r))
        p.addQuadCurve(to: CGPoint(x: x0 + r, y: wb), control: CGPoint(x: x0, y: wb))
        if let n = stepped(rect) {
            let nb = n.maxY + 1, rr: CGFloat = 8
            p.addLine(to: CGPoint(x: n.minX - 4, y: wb))
            p.addQuadCurve(to: CGPoint(x: n.minX, y: wb + 4), control: CGPoint(x: n.minX, y: wb))
            p.addLine(to: CGPoint(x: n.minX, y: nb - rr))
            p.addQuadCurve(to: CGPoint(x: n.minX + rr, y: nb), control: CGPoint(x: n.minX, y: nb))
            p.addLine(to: CGPoint(x: rect.midX, y: nb))
        } else {
            p.addLine(to: CGPoint(x: rect.midX, y: wb))
        }
    }

    /// Right half: from the bottom middle, round the right side and back up to the top line.
    static func addIslandRight(_ p: inout Path, _ rect: CGRect) {
        let r: CGFloat = min(10, rect.height / 2)
        let x1 = rect.maxX, wb = rect.maxY + 1
        if let n = stepped(rect) {
            let nb = n.maxY + 1, rr: CGFloat = 8
            p.addLine(to: CGPoint(x: n.maxX - rr, y: nb))
            p.addQuadCurve(to: CGPoint(x: n.maxX, y: nb - rr), control: CGPoint(x: n.maxX, y: nb))
            p.addLine(to: CGPoint(x: n.maxX, y: wb + 4))
            p.addQuadCurve(to: CGPoint(x: n.maxX + 4, y: wb), control: CGPoint(x: n.maxX, y: wb))
        }
        p.addLine(to: CGPoint(x: x1 - r, y: wb))
        p.addQuadCurve(to: CGPoint(x: x1, y: wb - r), control: CGPoint(x: x1, y: wb))
        p.addLine(to: CGPoint(x: x1, y: min(7, wb - r)))
        p.addQuadCurve(to: CGPoint(x: x1 + 6, y: 1), control: CGPoint(x: x1, y: 1))
    }

    /// Adds the part of a line along the top that dips down and around the island.
    static func addIsland(_ p: inout Path, _ rect: CGRect) {
        addIslandLeft(&p, rect)
        addIslandRight(&p, rect)
    }

    /// The top edge of the screen, wrapping around the notch/island if there is one.
    static func topPath(_ info: ScreenInfo, island: CGRect?) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 1))
        if let island { addIsland(&p, island) }
        p.addLine(to: CGPoint(x: info.size.width, y: 1))
        return p
    }

    /// The whole screen edge, starting at the top centre and going clockwise back to it.
    static func edgesFromTopCenter(_ info: ScreenInfo, island: CGRect?) -> Path {
        let w = info.size.width, h = info.size.height, r: CGFloat = 10, i: CGFloat = 1
        var p = Path()
        if let island {
            let bottom = (stepped(island)?.maxY ?? island.maxY) + 1
            p.move(to: CGPoint(x: island.midX, y: bottom))
            addIslandRight(&p, island)
        } else {
            p.move(to: CGPoint(x: w / 2, y: i))
        }
        p.addLine(to: CGPoint(x: w - i - r, y: i))
        p.addQuadCurve(to: CGPoint(x: w - i, y: i + r), control: CGPoint(x: w - i, y: i))
        p.addLine(to: CGPoint(x: w - i, y: h - i - r))
        p.addQuadCurve(to: CGPoint(x: w - i - r, y: h - i), control: CGPoint(x: w - i, y: h - i))
        p.addLine(to: CGPoint(x: i + r, y: h - i))
        p.addQuadCurve(to: CGPoint(x: i, y: h - i - r), control: CGPoint(x: i, y: h - i))
        p.addLine(to: CGPoint(x: i, y: i + r))
        p.addQuadCurve(to: CGPoint(x: i + r, y: i), control: CGPoint(x: i, y: i))
        if let island { addIslandLeft(&p, island) } else { p.addLine(to: CGPoint(x: w / 2, y: i)) }
        return p
    }

    static func basePath(style: GlowStyle, info: ScreenInfo, island: CGRect?) -> Path {
        switch style {
        case .topBar:
            return topPath(info, island: island)

        case .straight:
            return straightLine(info)

        case .menuBar:
            // Along the top (around the notch), down the right side, back along the bottom
            // of the menu bar, and up the left side.
            let w = info.size.width, h = max(info.menuBarHeight, island?.maxY ?? 0) + 1
            var p = Path()
            p.move(to: CGPoint(x: 1, y: 1))
            if let island { addIsland(&p, island) }
            p.addLine(to: CGPoint(x: w - 1, y: 1))
            p.addLine(to: CGPoint(x: w - 1, y: h))
            p.addLine(to: CGPoint(x: 1, y: h))
            p.closeSubpath()
            return p

        case .edges:
            // Clockwise from the top-left, wrapping the notch and following the rounded corners.
            let w = info.size.width, h = info.size.height, r: CGFloat = 10, i: CGFloat = 1
            var p = Path()
            p.move(to: CGPoint(x: i + r, y: i))
            if let island { addIsland(&p, island) }
            p.addLine(to: CGPoint(x: w - i - r, y: i))
            p.addQuadCurve(to: CGPoint(x: w - i, y: i + r), control: CGPoint(x: w - i, y: i))
            p.addLine(to: CGPoint(x: w - i, y: h - i - r))
            p.addQuadCurve(to: CGPoint(x: w - i - r, y: h - i), control: CGPoint(x: w - i, y: h - i))
            p.addLine(to: CGPoint(x: i + r, y: h - i))
            p.addQuadCurve(to: CGPoint(x: i, y: h - i - r), control: CGPoint(x: i, y: h - i))
            p.addLine(to: CGPoint(x: i, y: i + r))
            p.addQuadCurve(to: CGPoint(x: i + r, y: i), control: CGPoint(x: i, y: i))
            return p

        case .notch:
            // Only around the notch (or a notch-sized shape at the top centre of other screens).
            let rect = island ?? CGRect(x: info.size.width / 2 - 95, y: 0, width: 190, height: min(info.menuBarHeight, 30))
            var p = Path()
            p.move(to: CGPoint(x: rect.minX - 20, y: 1))
            addIsland(&p, rect)
            p.addLine(to: CGPoint(x: rect.maxX + 20, y: 1))
            return p
        }
    }

    // MARK: drawing

    /// Like trimmedPath, but positions wrap around a closed path (so a light can cross the start point).
    static func strokeWrapped(_ ctx: inout GraphicsContext, _ path: Path, _ from: Double, _ to: Double,
                              _ color: Color, _ width: CGFloat, _ alpha: Double) {
        var a = from.truncatingRemainder(dividingBy: 1); if a < 0 { a += 1 }
        let len = min(1, max(0, to - from))
        let b = a + len
        if b <= 1 {
            stroke(&ctx, path.trimmedPath(from: a, to: b), color, width, alpha)
        } else {
            stroke(&ctx, path.trimmedPath(from: a, to: 1), color, width, alpha)
            stroke(&ctx, path.trimmedPath(from: 0, to: b - 1), color, width, alpha)
        }
    }

    /// Three layers: wide soft bloom, medium glow, bright core.
    static func stroke(_ ctx: inout GraphicsContext, _ path: Path, _ color: Color, _ width: CGFloat,
                       _ alpha: Double, blur: Bool = true, soft: Bool = false) {
        guard alpha > 0.001, !path.isEmpty else { return }
        if blur {
            ctx.drawLayer { l in
                l.addFilter(.blur(radius: width * (soft ? 2.5 : 4)))
                l.stroke(path, with: .color(color.opacity(alpha * 0.7)),
                         style: StrokeStyle(lineWidth: width * 3.2, lineCap: .round, lineJoin: .round))
            }
            ctx.drawLayer { l in
                l.addFilter(.blur(radius: width * 1.2))
                l.stroke(path, with: .color(color.opacity(alpha * 0.9)),
                         style: StrokeStyle(lineWidth: width * 1.4, lineCap: .round, lineJoin: .round))
            }
        }
        ctx.stroke(path, with: .color(color.opacity(alpha)),
                   style: StrokeStyle(lineWidth: max(1, width * 0.6), lineCap: .round, lineJoin: .round))
        if !soft {
            ctx.stroke(path, with: .color(Color.white.opacity(alpha * 0.55)),
                       style: StrokeStyle(lineWidth: max(0.5, width * 0.2), lineCap: .round, lineJoin: .round))
        }
    }

    /// A gradient whose bright spots drift sideways, like a sound wave rolling across.
    static func waveStroke(_ ctx: inout GraphicsContext, _ path: Path, _ color: Color, _ width: CGFloat,
                           _ alpha: Double, phase: Double, size: CGSize) {
        let samples = 28
        var stops: [Gradient.Stop] = []
        for i in 0...samples {
            let x = Double(i) / Double(samples)
            let v = 0.5 + 0.5 * sin(2 * .pi * (x * 2.2 - phase))
            let v2 = 0.5 + 0.5 * sin(2 * .pi * (x * 3.7 + phase * 1.6))
            let o = 0.12 + 0.88 * pow(v * 0.7 + v2 * 0.3, 1.6)
            stops.append(.init(color: color.opacity(alpha * o), location: x))
        }
        let shading = GraphicsContext.Shading.linearGradient(Gradient(stops: stops),
                                                             startPoint: .zero,
                                                             endPoint: CGPoint(x: size.width, y: 0))
        ctx.drawLayer { l in
            l.addFilter(.blur(radius: width * 4))
            l.stroke(path, with: shading, style: StrokeStyle(lineWidth: width * 3.2, lineCap: .round, lineJoin: .round))
        }
        ctx.drawLayer { l in
            l.addFilter(.blur(radius: width * 1.2))
            l.stroke(path, with: shading, style: StrokeStyle(lineWidth: width * 1.4, lineCap: .round, lineJoin: .round))
        }
        ctx.stroke(path, with: shading, style: StrokeStyle(lineWidth: max(1, width * 0.6), lineCap: .round, lineJoin: .round))
    }

    // MARK: math

    static func envelope(elapsed: TimeInterval, duration: TimeInterval) -> Double {
        if duration == .infinity { return min(1, elapsed / 0.4) }
        guard elapsed >= 0, elapsed < duration else { return 0 }
        let fadeIn = min(1, elapsed / 0.12)
        let fadeOut = min(1, (duration - elapsed) / 0.45)
        return fadeIn * fadeOut
    }

    static func clamp(_ x: Double) -> Double { min(1, max(0, x)) }

    static func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 2.2) }

    static func easeInOut(_ x: Double) -> Double { x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2 }
}
