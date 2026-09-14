import SwiftUI
import AppKit

/// Hand-drawn vector icons. Everything is described on a 24×24 grid and scaled at draw time, so a
/// glyph is crisp at 11 pt in a menu and at 96 pt in the about box, and none of it depends on the
/// SF Symbols catalogue of whatever macOS the app happens to run on.
struct Glyph: View {
    enum Kind {
        case fin, play, stop, pause, restart, terminal, trash, docker, plus, star, starOutline
        case gear, cpu, memory, disk, network, folder, key, clock, wrench, download, upload
        case check, xmark, warning, info, ellipsis, chevronRight, chevronDown, copy, bolt
        case window, shield, image, list, search, sliders, link, power, refresh
    }

    let kind: Kind
    var size: CGFloat = 16
    var weight: CGFloat = 1.7
    var color: Color = .primary

    var body: some View {
        if let name = Glyph.symbol(kind) {
            // Interface icons come from SF Symbols so they carry the system's optical sizing and
            // weight, and sit correctly on the text baseline next to native controls. Hand-drawn
            // equivalents were subtly the wrong weight everywhere and read as foreign on macOS.
            Image(systemName: name)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(color)
                .accessibilityHidden(true)
        } else {
            Canvas(rendersAsynchronously: false) { ctx, _ in
                ctx.scaleBy(x: size / 24, y: size / 24)
                let g = Glyph.geometry(kind)
                for p in g.fills { ctx.fill(p, with: .color(color)) }
                for p in g.strokes {
                    ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: g.weight ?? weight, lineCap: .round, lineJoin: .round))
                }
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
        }
    }

    // MARK: - Geometry

    struct Geometry {
        var fills: [Path] = []
        var strokes: [Path] = []
        var weight: CGFloat?
    }

    /// SF Symbol for each interface icon. `nil` means the mark is drawn by hand below, which is
    /// reserved for brand shapes SF Symbols has no equivalent for: the Sharkbox fin and the distro
    /// logos.
    static func symbol(_ kind: Kind) -> String? {
        switch kind {
        case .fin: return nil
        case .play:         return "play.fill"
        case .stop:         return "stop.fill"
        case .pause:        return "pause.fill"
        case .restart:      return "arrow.clockwise"
        case .refresh:      return "arrow.clockwise"
        case .terminal:     return "terminal"
        case .trash:        return "trash"
        case .docker:       return "shippingbox"
        case .plus:         return "plus"
        case .star:         return "star.fill"
        case .starOutline:  return "star"
        case .gear:         return "gearshape"
        case .cpu:          return "cpu"
        case .memory:       return "memorychip"
        case .disk:         return "internaldrive"
        case .network:      return "network"
        case .folder:       return "folder"
        case .key:          return "key"
        case .clock:        return "clock"
        case .wrench:       return "wrench.and.screwdriver"
        case .download:     return "arrow.down.circle"
        case .upload:       return "arrow.up.circle"
        case .check:        return "checkmark"
        case .xmark:        return "xmark"
        case .warning:      return "exclamationmark.triangle.fill"
        case .info:         return "info.circle"
        case .ellipsis:     return "ellipsis"
        case .chevronRight: return "chevron.right"
        case .chevronDown:  return "chevron.down"
        case .copy:         return "doc.on.doc"
        case .bolt:         return "bolt.fill"
        case .window:       return "macwindow"
        case .shield:       return "lock.shield"
        case .image:        return "opticaldisc"
        case .list:         return "list.bullet"
        case .search:       return "magnifyingglass"
        case .sliders:      return "slider.horizontal.3"
        case .link:         return "link"
        case .power:        return "power"
        }
    }

    static func geometry(_ kind: Kind) -> Geometry {
        guard kind == .fin else { return Geometry() }
        return Geometry(fills: [finPath()], strokes: [wavePath()], weight: 1.8)
    }

    static func finPath() -> Path {
        path { p in
            p.move(to: .init(x: 3.6, y: 18.4))
            p.addCurve(to: .init(x: 13.2, y: 3.4), control1: .init(x: 8.2, y: 15.2), control2: .init(x: 11, y: 9.6))
            p.addCurve(to: .init(x: 19.4, y: 18.4), control1: .init(x: 15, y: 9.2), control2: .init(x: 17.2, y: 14.6))
            p.closeSubpath()
        }
    }

    static func wavePath() -> Path {
        path { p in
            p.move(to: .init(x: 1.8, y: 21))
            p.addQuadCurve(to: .init(x: 8, y: 21), control: .init(x: 4.9, y: 18.4))
            p.addQuadCurve(to: .init(x: 14.2, y: 21), control: .init(x: 11.1, y: 23.6))
            p.addQuadCurve(to: .init(x: 20.4, y: 21), control: .init(x: 17.3, y: 18.4))
        }
    }

    static func path(_ build: (inout Path) -> Void) -> Path {
        var p = Path()
        build(&p)
        return p
    }
}

/// Distro marks: the real logos — Canonical's Circle of Friends and Debian's swirl — in white on a
/// disc of the distro's own brand colour. These are shapes people already recognise, so a hand-drawn
/// approximation of one reads as a mistake rather than as an icon; the SVGs in Resources/ are the
/// official files, bundled unchanged into Contents/Resources by the Makefile.
struct DistroArt {
    var tint: Color
    /// The brand mark, drawn as a template image (white) over the disc.
    var logo: NSImage? = nil
    /// Padding around the mark as a fraction of the mark's frame. The swirl is portrait, so it gets
    /// less than the near-square Circle of Friends and still ends up narrower.
    var inset: CGFloat = 0.17
    /// Fallback line art in the 24-pt Glyph grid, used when there is no logo.
    var strokes: [Path] = []
    var strokeWidth: CGFloat = 1.9

    static let ubuntuOrange = Color(red: 0.914, green: 0.329, blue: 0.125)   // #E95420
    static let debianRed = Color(red: 0.843, green: 0.039, blue: 0.325)      // #D70A53

    static func forDistro(_ distro: String) -> DistroArt {
        if distro.hasPrefix("ubuntu"), let logo = ubuntuLogo {
            return DistroArt(tint: ubuntuOrange, logo: logo, inset: 0.17)
        }
        if distro.hasPrefix("debian"), let logo = debianLogo {
            return DistroArt(tint: debianRed, logo: logo, inset: 0.13)
        }
        return generic
    }

    static let ubuntuLogo = bundled("ubuntu-cof")
    static let debianLogo = bundled("debian-swirl")

    /// Loaded once from Contents/Resources. NSImage decodes SVG natively on macOS 11+, so the marks
    /// stay vector at every size. Nil when the binary runs outside its bundle (a bare build from the
    /// Makefile's swiftc line), in which case the distro gets the generic mark instead of nothing.
    static func bundled(_ name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "svg"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        return image
    }

    /// Anything else: a neutral slate disc with a shell prompt. A vaguely penguin-shaped blob read
    /// as a lightbulb at 17 pt, which is worse than not being a penguin at all.
    static var generic: DistroArt {
        DistroArt(tint: Color(red: 0.24, green: 0.26, blue: 0.29), strokes: [
            Glyph.path { p in
                p.move(to: .init(x: 8.0, y: 8.6))
                p.addLine(to: .init(x: 11.8, y: 12.0))
                p.addLine(to: .init(x: 8.0, y: 15.4))
            },
            Glyph.path { p in
                p.move(to: .init(x: 13.4, y: 15.6))
                p.addLine(to: .init(x: 16.6, y: 15.6))
            },
        ])
    }
}

struct DistroMark: View {
    let distro: String
    var size: CGFloat = 16

    var body: some View {
        let art = DistroArt.forDistro(distro)
        ZStack {
            Circle().fill(art.tint).padding(size / 24)
            if let logo = art.logo {
                Image(nsImage: logo)
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(.white)
                    .padding(size * art.inset)
            } else {
                Canvas(rendersAsynchronously: false) { ctx, _ in
                    ctx.scaleBy(x: size / 24, y: size / 24)
                    for p in art.strokes {
                        ctx.stroke(p, with: .color(.white),
                                   style: StrokeStyle(lineWidth: art.strokeWidth, lineCap: .round))
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Indeterminate ring: a faint full track with a rotating arc. Deliberately stateless —
/// `TimelineView(.animation)` derives the angle from the clock, because this target has no `@State`
/// (see MainView.swift:5) and therefore nothing to hang a `withAnimation` on. The stock macOS
/// ProgressView is a segmented barber-pole that reads as a smudge below ~16 pt.
struct RingSpinner: View {
    var size: CGFloat = 18
    var lineWidth: CGFloat = 2.5
    var color: Color = .accentColor

    var body: some View {
        TimelineView(.animation) { ctx in
            let turn = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)
            ZStack {
                Circle().stroke(color.opacity(0.18), lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(turn * 360))
            }
            .frame(width: size, height: size)
        }
        .accessibilityHidden(true)
    }
}

struct AppMark: View {
    var size: CGFloat = 64

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.16, green: 0.58, blue: 0.96),
                                              Color(red: 0.03, green: 0.26, blue: 0.63)],
                                     startPoint: .top, endPoint: .bottom))
            Glyph(kind: .fin, size: size * 0.66, weight: size * 0.055, color: .white)
                .offset(y: -size * 0.02)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.18), radius: size * 0.04, y: size * 0.02)
    }
}

enum MenuBarIcon {
    /// The status-bar image, rendered from the same fin geometry and marked as a template so macOS
    /// tints it for light/dark menu bars.
    static let image: NSImage = {
        let size = NSSize(width: 18, height: 16)
        let img = NSImage(size: size, flipped: true) { _ in
            let scale = 15.0 / 24.0
            var t = CGAffineTransform(scaleX: scale, y: scale)
            t = t.concatenating(CGAffineTransform(translationX: 1.5, y: 0.6))
            let fin = Glyph.finPath().cgPath.copy(using: &t)!
            let wave = Glyph.wavePath().cgPath.copy(using: &t)!
            guard let ctx = NSGraphicsContext.current?.cgContext else { return true }
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.addPath(fin)
            ctx.fillPath()
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setLineWidth(1.6)
            ctx.setLineCap(.round)
            ctx.addPath(wave)
            ctx.strokePath()
            return true
        }
        img.isTemplate = true
        return img
    }()
}
