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
        case ubuntu, debian, tux
    }

    let kind: Kind
    var size: CGFloat = 16
    var weight: CGFloat = 1.7
    var color: Color = .primary

    var body: some View {
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

    // MARK: - Geometry

    struct Geometry {
        var fills: [Path] = []
        var strokes: [Path] = []
        var weight: CGFloat?
    }

    static func geometry(_ kind: Kind) -> Geometry {
        switch kind {
        case .fin:
            return Geometry(fills: [finPath()], strokes: [wavePath()], weight: 1.8)
        case .play:
            return Geometry(fills: [path { p in
                p.move(to: .init(x: 7, y: 4.5)); p.addLine(to: .init(x: 19, y: 12))
                p.addLine(to: .init(x: 7, y: 19.5)); p.closeSubpath()
            }])
        case .stop:
            return Geometry(fills: [Path(roundedRect: CGRect(x: 6, y: 6, width: 12, height: 12), cornerRadius: 2.2)])
        case .pause:
            return Geometry(fills: [Path(roundedRect: CGRect(x: 6.5, y: 5, width: 3.6, height: 14), cornerRadius: 1.4),
                                    Path(roundedRect: CGRect(x: 13.9, y: 5, width: 3.6, height: 14), cornerRadius: 1.4)])
        case .restart, .refresh:
            return Geometry(fills: [path { p in            // arrow head
                p.move(to: .init(x: 18.2, y: 3)); p.addLine(to: .init(x: 20.5, y: 8.2))
                p.addLine(to: .init(x: 15, y: 7.6)); p.closeSubpath()
            }], strokes: [path { p in
                p.addArc(center: .init(x: 12, y: 12.6), radius: 7.4,
                         startAngle: .degrees(-58), endAngle: .degrees(250), clockwise: false)
            }])
        case .power:
            return Geometry(strokes: [path { p in
                p.addArc(center: .init(x: 12, y: 13), radius: 7,
                         startAngle: .degrees(-62), endAngle: .degrees(242), clockwise: false)
            }, path { p in
                p.move(to: .init(x: 12, y: 3.4)); p.addLine(to: .init(x: 12, y: 11))
            }])
        case .terminal:
            return Geometry(strokes: [
                Path(roundedRect: CGRect(x: 2.5, y: 4, width: 19, height: 16), cornerRadius: 3),
                path { p in
                    p.move(to: .init(x: 7, y: 10)); p.addLine(to: .init(x: 10.4, y: 13)); p.addLine(to: .init(x: 7, y: 16))
                },
                path { p in p.move(to: .init(x: 12.8, y: 16.2)); p.addLine(to: .init(x: 17, y: 16.2)) },
            ])
        case .trash:
            return Geometry(strokes: [
                path { p in p.move(to: .init(x: 3.6, y: 6.4)); p.addLine(to: .init(x: 20.4, y: 6.4)) },
                path { p in
                    p.move(to: .init(x: 9, y: 6.2)); p.addLine(to: .init(x: 9.6, y: 3.6)); p.addLine(to: .init(x: 14.4, y: 3.6))
                    p.addLine(to: .init(x: 15, y: 6.2))
                },
                path { p in
                    p.move(to: .init(x: 5.6, y: 6.6)); p.addLine(to: .init(x: 6.8, y: 20.2))
                    p.addLine(to: .init(x: 17.2, y: 20.2)); p.addLine(to: .init(x: 18.4, y: 6.6))
                },
                path { p in p.move(to: .init(x: 10.2, y: 10)); p.addLine(to: .init(x: 10.6, y: 16.8)) },
                path { p in p.move(to: .init(x: 13.8, y: 10)); p.addLine(to: .init(x: 13.4, y: 16.8)) },
            ])
        case .docker:
            // A whale carrying stacked containers.
            var boxes: [Path] = []
            for (col, row) in [(0, 0), (1, 0), (2, 0), (1, 1)] {
                boxes.append(Path(roundedRect: CGRect(x: 6.4 + Double(col) * 3.7, y: 11.4 - Double(row) * 3.4,
                                                      width: 3.1, height: 2.9), cornerRadius: 0.5))
            }
            let body = path { p in
                p.move(to: .init(x: 2.2, y: 13.4))
                p.addLine(to: .init(x: 20.4, y: 13.4))
                p.addCurve(to: .init(x: 11, y: 20.4), control1: .init(x: 20.4, y: 18.6), control2: .init(x: 16.6, y: 20.4))
                p.addCurve(to: .init(x: 2.2, y: 13.4), control1: .init(x: 6, y: 20.4), control2: .init(x: 3.2, y: 17))
                p.closeSubpath()
            }
            return Geometry(fills: boxes + [body])
        case .plus:
            return Geometry(strokes: [path { p in
                p.move(to: .init(x: 12, y: 5)); p.addLine(to: .init(x: 12, y: 19))
                p.move(to: .init(x: 5, y: 12)); p.addLine(to: .init(x: 19, y: 12))
            }], weight: 2.1)
        case .star, .starOutline:
            let star = path { p in
                for i in 0..<5 {
                    let outer = Angle.degrees(Double(i) * 72 - 90).radians
                    let inner = Angle.degrees(Double(i) * 72 - 54).radians
                    let po = CGPoint(x: 12 + cos(outer) * 8.4, y: 12 + sin(outer) * 8.4)
                    let pi = CGPoint(x: 12 + cos(inner) * 3.6, y: 12 + sin(inner) * 3.6)
                    if i == 0 { p.move(to: po) } else { p.addLine(to: po) }
                    p.addLine(to: pi)
                }
                p.closeSubpath()
            }
            return kind == .star ? Geometry(fills: [star]) : Geometry(strokes: [star], weight: 1.5)
        case .gear:
            var teeth = Path()
            for i in 0..<8 {
                let a = Angle.degrees(Double(i) * 45).radians
                let r = CGRect(x: -1.7, y: -9.6, width: 3.4, height: 4.4)
                var t = Transform2D()
                t.rotate(a); t.translate(12, 12)
                teeth.addPath(Path(roundedRect: r, cornerRadius: 0.8), transform: t.affine)
            }
            return Geometry(fills: [teeth], strokes: [
                path { p in p.addEllipse(in: CGRect(x: 4.6, y: 4.6, width: 14.8, height: 14.8)) },
                path { p in p.addEllipse(in: CGRect(x: 9, y: 9, width: 6, height: 6)) },
            ], weight: 2.0)
        case .cpu:
            var pins = Path()
            for i in 0..<3 {
                let o = 7.0 + Double(i) * 5
                pins.addRect(CGRect(x: o - 0.55, y: 1.6, width: 1.1, height: 3))
                pins.addRect(CGRect(x: o - 0.55, y: 19.4, width: 1.1, height: 3))
                pins.addRect(CGRect(x: 1.6, y: o - 0.55, width: 3, height: 1.1))
                pins.addRect(CGRect(x: 19.4, y: o - 0.55, width: 3, height: 1.1))
            }
            return Geometry(fills: [pins], strokes: [
                Path(roundedRect: CGRect(x: 4.6, y: 4.6, width: 14.8, height: 14.8), cornerRadius: 2.6),
                Path(roundedRect: CGRect(x: 9, y: 9, width: 6, height: 6), cornerRadius: 1.2),
            ])
        case .memory:
            var pins = Path()
            for i in 0..<6 { pins.addRect(CGRect(x: 5.2 + Double(i) * 2.6, y: 16.4, width: 1.5, height: 3.2)) }
            return Geometry(fills: [pins], strokes: [
                Path(roundedRect: CGRect(x: 3, y: 5, width: 18, height: 11.4), cornerRadius: 1.8),
                path { p in
                    p.addRect(CGRect(x: 6, y: 8, width: 3.4, height: 5.4))
                    p.addRect(CGRect(x: 10.6, y: 8, width: 3.4, height: 5.4))
                    p.addRect(CGRect(x: 15.2, y: 8, width: 3.4, height: 5.4))
                },
            ], weight: 1.5)
        case .disk:
            return Geometry(strokes: [
                path { p in p.addEllipse(in: CGRect(x: 3.4, y: 3.2, width: 17.2, height: 5.4)) },
                path { p in
                    p.move(to: .init(x: 3.4, y: 5.9)); p.addLine(to: .init(x: 3.4, y: 18.1))
                    p.addArc(center: .init(x: 12, y: 18.1), radius: 8.6,
                             startAngle: .degrees(180), endAngle: .degrees(0), clockwise: true)
                    p.addLine(to: .init(x: 20.6, y: 5.9))
                },
                path { p in
                    p.addArc(center: .init(x: 12, y: 12), radius: 8.6,
                             startAngle: .degrees(160), endAngle: .degrees(20), clockwise: true)
                },
            ], weight: 1.5)
        case .network:
            return Geometry(fills: [
                path { p in p.addEllipse(in: CGRect(x: 9.6, y: 2.4, width: 4.8, height: 4.8)) },
                path { p in p.addEllipse(in: CGRect(x: 2.4, y: 16.4, width: 4.8, height: 4.8)) },
                path { p in p.addEllipse(in: CGRect(x: 16.8, y: 16.4, width: 4.8, height: 4.8)) },
            ], strokes: [path { p in
                p.move(to: .init(x: 12, y: 7.6)); p.addLine(to: .init(x: 12, y: 12))
                p.move(to: .init(x: 4.8, y: 16)); p.addLine(to: .init(x: 4.8, y: 12)); p.addLine(to: .init(x: 19.2, y: 12))
                p.addLine(to: .init(x: 19.2, y: 16))
            }], weight: 1.5)
        case .folder:
            return Geometry(strokes: [path { p in
                p.move(to: .init(x: 3, y: 18.6)); p.addLine(to: .init(x: 3, y: 6))
                p.addLine(to: .init(x: 9.4, y: 6)); p.addLine(to: .init(x: 11.4, y: 8.6))
                p.addLine(to: .init(x: 21, y: 8.6)); p.addLine(to: .init(x: 21, y: 18.6))
                p.closeSubpath()
            }])
        case .key:
            return Geometry(strokes: [
                path { p in p.addEllipse(in: CGRect(x: 3.2, y: 8.4, width: 7.6, height: 7.6)) },
                path { p in
                    p.move(to: .init(x: 10.4, y: 12.2)); p.addLine(to: .init(x: 21, y: 12.2))
                    p.move(to: .init(x: 17.6, y: 12.2)); p.addLine(to: .init(x: 17.6, y: 15.8))
                    p.move(to: .init(x: 20.4, y: 12.2)); p.addLine(to: .init(x: 20.4, y: 16.4))
                },
            ])
        case .clock:
            return Geometry(strokes: [
                path { p in p.addEllipse(in: CGRect(x: 3.2, y: 3.2, width: 17.6, height: 17.6)) },
                path { p in
                    p.move(to: .init(x: 12, y: 7.4)); p.addLine(to: .init(x: 12, y: 12.4)); p.addLine(to: .init(x: 15.8, y: 14.6))
                },
            ])
        case .wrench:
            return Geometry(fills: [path { p in
                p.move(to: .init(x: 14.8, y: 2.6))
                p.addLine(to: .init(x: 11.6, y: 5.8)); p.addLine(to: .init(x: 13.2, y: 9.2)); p.addLine(to: .init(x: 16.6, y: 10.8))
                p.addLine(to: .init(x: 19.8, y: 7.6))
                p.addCurve(to: .init(x: 8.2, y: 17.4), control1: .init(x: 21.6, y: 15.2), control2: .init(x: 13.4, y: 20.2))
                p.addLine(to: .init(x: 5.2, y: 20.4)); p.addLine(to: .init(x: 3, y: 18.2)); p.addLine(to: .init(x: 6.2, y: 15.2))
                p.addCurve(to: .init(x: 14.8, y: 2.6), control1: .init(x: 3, y: 9.4), control2: .init(x: 8.2, y: 1.2))
                p.closeSubpath()
            }])
        case .download, .upload:
            let up = kind == .upload
            return Geometry(fills: [path { p in
                let y = up ? 5.0 : 15.6
                p.move(to: .init(x: 12, y: up ? 3.0 : 17.6)); p.addLine(to: .init(x: 8.2, y: y))
                p.addLine(to: .init(x: 15.8, y: y)); p.closeSubpath()
            }], strokes: [
                path { p in p.move(to: .init(x: 12, y: up ? 15.6 : 4.2)); p.addLine(to: .init(x: 12, y: up ? 4.6 : 16)) },
                path { p in
                    p.move(to: .init(x: 4.4, y: 19.8)); p.addLine(to: .init(x: 19.6, y: 19.8))
                },
            ])
        case .check:
            return Geometry(strokes: [path { p in
                p.move(to: .init(x: 4.6, y: 12.6)); p.addLine(to: .init(x: 9.8, y: 17.8)); p.addLine(to: .init(x: 19.4, y: 6.4))
            }], weight: 2.3)
        case .xmark:
            return Geometry(strokes: [path { p in
                p.move(to: .init(x: 6, y: 6)); p.addLine(to: .init(x: 18, y: 18))
                p.move(to: .init(x: 18, y: 6)); p.addLine(to: .init(x: 6, y: 18))
            }], weight: 2.1)
        case .warning:
            return Geometry(fills: [path { p in p.addEllipse(in: CGRect(x: 10.9, y: 16.4, width: 2.2, height: 2.2)) }],
                            strokes: [
                                path { p in
                                    p.move(to: .init(x: 12, y: 3.2)); p.addLine(to: .init(x: 22, y: 20.4))
                                    p.addLine(to: .init(x: 2, y: 20.4)); p.closeSubpath()
                                },
                                path { p in p.move(to: .init(x: 12, y: 9.4)); p.addLine(to: .init(x: 12, y: 14.4)) },
                            ])
        case .info:
            return Geometry(fills: [path { p in p.addEllipse(in: CGRect(x: 10.9, y: 6.2, width: 2.2, height: 2.2)) }],
                            strokes: [
                                path { p in p.addEllipse(in: CGRect(x: 3.2, y: 3.2, width: 17.6, height: 17.6)) },
                                path { p in p.move(to: .init(x: 12, y: 11)); p.addLine(to: .init(x: 12, y: 17.4)) },
                            ])
        case .ellipsis:
            return Geometry(fills: (0..<3).map { i in
                path { p in p.addEllipse(in: CGRect(x: 4.4 + Double(i) * 6.2, y: 10.9, width: 2.4, height: 2.4)) }
            })
        case .chevronRight:
            return Geometry(strokes: [path { p in
                p.move(to: .init(x: 9.5, y: 5.5)); p.addLine(to: .init(x: 16, y: 12)); p.addLine(to: .init(x: 9.5, y: 18.5))
            }], weight: 2.0)
        case .chevronDown:
            return Geometry(strokes: [path { p in
                p.move(to: .init(x: 5.5, y: 9.5)); p.addLine(to: .init(x: 12, y: 16)); p.addLine(to: .init(x: 18.5, y: 9.5))
            }], weight: 2.0)
        case .copy:
            return Geometry(strokes: [
                Path(roundedRect: CGRect(x: 8, y: 3.4, width: 12.6, height: 12.6), cornerRadius: 2.4),
                path { p in
                    p.move(to: .init(x: 16, y: 19)); p.addLine(to: .init(x: 16, y: 20.6))
                    p.addLine(to: .init(x: 3.4, y: 20.6)); p.addLine(to: .init(x: 3.4, y: 8))
                    p.addLine(to: .init(x: 5, y: 8))
                },
            ], weight: 1.6)
        case .bolt:
            return Geometry(fills: [path { p in
                p.move(to: .init(x: 13.6, y: 2)); p.addLine(to: .init(x: 5.4, y: 13.4)); p.addLine(to: .init(x: 11, y: 13.4))
                p.addLine(to: .init(x: 10, y: 22)); p.addLine(to: .init(x: 18.6, y: 10.4)); p.addLine(to: .init(x: 13, y: 10.4))
                p.closeSubpath()
            }])
        case .window:
            return Geometry(fills: [path { p in p.addRect(CGRect(x: 3, y: 4.4, width: 18, height: 3.4)) }],
                            strokes: [Path(roundedRect: CGRect(x: 3, y: 4.4, width: 18, height: 15.2), cornerRadius: 2.4)])
        case .shield:
            return Geometry(strokes: [path { p in
                p.move(to: .init(x: 12, y: 2.8)); p.addLine(to: .init(x: 20, y: 6))
                p.addCurve(to: .init(x: 12, y: 21.2), control1: .init(x: 20, y: 15), control2: .init(x: 16.4, y: 19.4))
                p.addCurve(to: .init(x: 4, y: 6), control1: .init(x: 7.6, y: 19.4), control2: .init(x: 4, y: 15))
                p.closeSubpath()
            }])
        case .image:
            return Geometry(fills: [path { p in p.addEllipse(in: CGRect(x: 7, y: 7.4, width: 3, height: 3)) }],
                            strokes: [
                                Path(roundedRect: CGRect(x: 3, y: 4.4, width: 18, height: 15.2), cornerRadius: 2.6),
                                path { p in
                                    p.move(to: .init(x: 3.6, y: 17)); p.addLine(to: .init(x: 9.4, y: 11.6))
                                    p.addLine(to: .init(x: 14, y: 15.4)); p.addLine(to: .init(x: 17.2, y: 12.8))
                                    p.addLine(to: .init(x: 20.4, y: 15.6))
                                },
                            ], weight: 1.6)
        case .list:
            var dots = Path()
            var lines = Path()
            for i in 0..<3 {
                let y = 6.6 + Double(i) * 5.4
                dots.addEllipse(in: CGRect(x: 3.4, y: y - 1.1, width: 2.2, height: 2.2))
                lines.move(to: .init(x: 8.6, y: y)); lines.addLine(to: .init(x: 20.4, y: y))
            }
            return Geometry(fills: [dots], strokes: [lines], weight: 1.7)
        case .search:
            return Geometry(strokes: [
                path { p in p.addEllipse(in: CGRect(x: 3.6, y: 3.6, width: 13, height: 13)) },
                path { p in p.move(to: .init(x: 15.8, y: 15.8)); p.addLine(to: .init(x: 20.6, y: 20.6)) },
            ])
        case .sliders:
            var knobs = Path()
            var rails = Path()
            let ys = [7.0, 12.0, 17.0]
            let xs = [15.4, 8.6, 12.8]
            for (y, x) in zip(ys, xs) {
                rails.move(to: .init(x: 3.4, y: y)); rails.addLine(to: .init(x: 20.6, y: y))
                knobs.addEllipse(in: CGRect(x: x - 2.1, y: y - 2.1, width: 4.2, height: 4.2))
            }
            return Geometry(fills: [knobs], strokes: [rails], weight: 1.6)
        case .link:
            return Geometry(strokes: [
                path { p in
                    p.move(to: .init(x: 10, y: 14)); p.addLine(to: .init(x: 14, y: 10))
                },
                path { p in
                    p.move(to: .init(x: 13.2, y: 7)); p.addLine(to: .init(x: 15.6, y: 4.6))
                    p.addArc(center: .init(x: 17.4, y: 6.6), radius: 2.8, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
                    p.addLine(to: .init(x: 17, y: 10.8))
                },
                path { p in
                    p.move(to: .init(x: 10.8, y: 17)); p.addLine(to: .init(x: 8.4, y: 19.4))
                    p.addArc(center: .init(x: 6.6, y: 17.4), radius: 2.8, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
                    p.addLine(to: .init(x: 7, y: 13.2))
                },
            ], weight: 1.7)
        case .ubuntu:
            var dots = Path()
            var spokes = Path()
            for i in 0..<3 {
                let a = Angle.degrees(Double(i) * 120 - 45).radians
                let c = CGPoint(x: 12 + cos(a) * 8.8, y: 12 + sin(a) * 8.8)
                dots.addEllipse(in: CGRect(x: c.x - 2.4, y: c.y - 2.4, width: 4.8, height: 4.8))
                spokes.move(to: CGPoint(x: 12 + cos(a) * 3.4, y: 12 + sin(a) * 3.4))
                spokes.addLine(to: CGPoint(x: 12 + cos(a) * 6.0, y: 12 + sin(a) * 6.0))
            }
            return Geometry(fills: [dots], strokes: [
                path { p in p.addEllipse(in: CGRect(x: 8.6, y: 8.6, width: 6.8, height: 6.8)) },
                spokes,
            ], weight: 1.7)
        case .debian:
            // A naruto swirl: outer ring plus the spiral cut through the middle.
            return Geometry(strokes: [
                path { p in p.addEllipse(in: CGRect(x: 2.6, y: 2.6, width: 18.8, height: 18.8)) },
                spiral(turns: 2.35, from: 1.5, to: 7.3),
            ], weight: 1.9)
        case .tux:
            return Geometry(fills: [path { p in
                p.move(to: .init(x: 12, y: 2.6))
                p.addCurve(to: .init(x: 16.6, y: 9), control1: .init(x: 15.4, y: 2.6), control2: .init(x: 16.6, y: 5.4))
                p.addCurve(to: .init(x: 19.4, y: 19), control1: .init(x: 16.6, y: 13), control2: .init(x: 19.4, y: 14.6))
                p.addCurve(to: .init(x: 12, y: 21.4), control1: .init(x: 19.4, y: 21), control2: .init(x: 15.4, y: 21.4))
                p.addCurve(to: .init(x: 4.6, y: 19), control1: .init(x: 8.6, y: 21.4), control2: .init(x: 4.6, y: 21))
                p.addCurve(to: .init(x: 7.4, y: 9), control1: .init(x: 4.6, y: 14.6), control2: .init(x: 7.4, y: 13))
                p.addCurve(to: .init(x: 12, y: 2.6), control1: .init(x: 7.4, y: 5.4), control2: .init(x: 8.6, y: 2.6))
                p.closeSubpath()
            }])
        }
    }

    // MARK: - Building blocks

    static func path(_ build: (inout Path) -> Void) -> Path {
        var p = Path()
        build(&p)
        return p
    }

    /// An Archimedean spiral, sampled — the swirl inside the naruto mark.
    static func spiral(turns: Double, from r0: Double, to r1: Double, steps: Int = 160) -> Path {
        path { p in
            for i in 0...steps {
                let t = Double(i) / Double(steps)
                let angle = t * turns * 2 * .pi - .pi / 2
                let r = r0 + t * (r1 - r0)
                let pt = CGPoint(x: 12 + cos(angle) * r, y: 12 + sin(angle) * r)
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
        }
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

    /// Tiny affine helper so the gear teeth can be rotated without pulling in Core Graphics contexts.
    struct Transform2D {
        var affine = CGAffineTransform.identity
        mutating func rotate(_ radians: Double) { affine = affine.rotated(by: radians) }
        mutating func translate(_ x: Double, _ y: Double) { affine = CGAffineTransform(translationX: x, y: y).concatenating(affine) }
    }
}

/// The distro mark for a machine, picked from its distro id.
struct DistroMark: View {
    let distro: String
    var size: CGFloat = 16
    var color: Color = .primary

    /// Distros that are represented by an emoji rather than a drawn glyph.
    private var emoji: String? {
        distro.hasPrefix("debian") ? "🍥" : nil
    }

    var body: some View {
        if let emoji {
            Image(nsImage: EmojiImage.of(emoji, size: size))
                .frame(width: size, height: size)
        } else {
            Glyph(kind: distro.hasPrefix("ubuntu") ? .ubuntu : .tux, size: size, color: color)
        }
    }
}

/// Emoji drawn into an image of exactly the requested point size, centred on its own ink rather
/// than on the font's line box. `Text` with a font size equal to the frame overflows and gets
/// clipped, because an emoji's glyph box is taller and wider than its nominal point size.
enum EmojiImage {
    private static var cache: [String: NSImage] = [:]

    static func of(_ emoji: String, size: CGFloat) -> NSImage {
        let key = "\(emoji)@\(size)"
        if let cached = cache[key] { return cached }
        // Measure at a reference size, then pick the font size whose ink exactly fills the box.
        let reference: CGFloat = 64
        let probe = NSAttributedString(string: emoji, attributes: [.font: NSFont.systemFont(ofSize: reference)])
        let probeInk = probe.boundingRect(with: NSSize(width: reference * 4, height: reference * 4),
                                          options: [.usesLineFragmentOrigin, .usesDeviceMetrics])
        let fontSize = size * reference / max(probeInk.width, probeInk.height)

        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let string = NSAttributedString(string: emoji, attributes: [.font: NSFont.systemFont(ofSize: fontSize)])
            let ink = string.boundingRect(with: NSSize(width: size * 4, height: size * 4),
                                          options: [.usesLineFragmentOrigin, .usesDeviceMetrics])
            string.draw(at: NSPoint(x: rect.midX - ink.midX, y: rect.midY - ink.midY))
            return true
        }
        image.isTemplate = false
        cache[key] = image
        return image
    }
}

/// The app mark: a fin over water in a rounded, gradient-filled tile. Used in the about box,
/// the empty state and the New Machine sheet.
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
