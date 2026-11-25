import AppKit
import SwiftUI

/// A wall-mounted bullet camera, drawn from simple shapes on a 24×24 grid (y-up) so it stays
/// crisp at menu bar size. Not the UniFi Protect logo: that belongs to Ubiquiti.
enum CameraGlyph {
    static func path(in rect: CGRect) -> (body: CGPath, lens: CGPath) {
        let scale = min(rect.width, rect.height) / 24
        let t = CGAffineTransform(translationX: rect.midX - 12 * scale, y: rect.midY - 12 * scale).scaledBy(x: scale, y: scale)

        let body = CGMutablePath()
        // Housing, tilted down toward what it watches.
        var tilt = CGAffineTransform(translationX: 12.5, y: 14.5).rotated(by: -0.32).translatedBy(x: -12.5, y: -14.5)
        tilt = tilt.concatenating(t)
        body.addRoundedRect(in: CGRect(x: 4, y: 10.5, width: 17, height: 8), cornerWidth: 2.6, cornerHeight: 2.6, transform: tilt)
        // Sun shield over the front.
        body.addRoundedRect(in: CGRect(x: 6, y: 17.5, width: 17, height: 2.6), cornerWidth: 1.3, cornerHeight: 1.3, transform: tilt)
        // Mount arm and wall plate.
        body.addRect(CGRect(x: 7.6, y: 5.2, width: 2.6, height: 7), transform: t)
        body.addRect(CGRect(x: 3.4, y: 5.2, width: 6.8, height: 2.6), transform: t)
        body.addRoundedRect(in: CGRect(x: 1.5, y: 2.5, width: 3, height: 8.2), cornerWidth: 1, cornerHeight: 1, transform: t)

        let lens = CGMutablePath()
        lens.addEllipse(in: CGRect(x: 16.6, y: 12.3, width: 3.4, height: 3.4), transform: tilt)
        return (body, lens)
    }

    /// Fills the glyph with `ink`, knocking the lens out of the housing.
    static func draw(in ctx: CGContext, rect: CGRect, ink: CGColor) {
        let (body, lens) = path(in: rect)
        ctx.saveGState()
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.addPath(body)
        ctx.setFillColor(ink)
        ctx.fillPath()
        ctx.setBlendMode(.clear)
        ctx.addPath(lens)
        ctx.fillPath()
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }
}

struct CameraGlyphView: View {
    var color: Color = .primary

    var body: some View {
        Canvas { context, size in
            context.withCGContext { ctx in
                ctx.translateBy(x: 0, y: size.height)
                ctx.scaleBy(x: 1, y: -1)
                CameraGlyph.draw(in: ctx, rect: CGRect(origin: .zero, size: size),
                                 ink: NSColor(color).usingColorSpace(.sRGB)?.cgColor ?? NSColor.labelColor.cgColor)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

// MARK: - Menu bar

struct MenuBarModel: Equatable {
    enum State: Equatable { case ok, connecting, offline, error }

    var state: State = .connecting
    var count = 0
    var color: IconColor = .monochrome
    var badge: BadgeStyle = .badge
    var snoozed = false

    @MainActor
    static func make(store: ProtectStore) -> MenuBarModel {
        var model = MenuBarModel(color: Prefs.iconColor, badge: Prefs.badgeStyle, snoozed: Prefs.snoozedUntil != nil)
        model.count = store.unseenCount
        if let error = store.error, case .network = error, store.lastFetched != nil {
            model.state = .offline
        } else if store.error != nil {
            model.state = .error
        } else if store.lastFetched == nil {
            model.state = .connecting
        } else {
            model.state = store.isLive ? .ok : .offline
        }
        return model
    }

    var countText: String { count > 99 ? "99+" : "\(count)" }
}

enum MenuBarRenderer {
    static let glyphSide: CGFloat = 19
    static let badgeOverlap: CGFloat = 5
    static let badgeFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .bold)

    static func width(for model: MenuBarModel) -> CGFloat {
        let base: CGFloat = glyphSide + 6
        guard model.count > 0, model.badge == .badge else { return base }
        return 3 + glyphSide - badgeOverlap + badgeSize(model).width + 2
    }

    private static func badgeSize(_ model: MenuBarModel) -> CGSize {
        let height: CGFloat = 12
        let text = ceil((model.countText as NSString).size(withAttributes: [.font: badgeFont]).width)
        return CGSize(width: max(height, text + 6), height: height)
    }

    /// Call with the status button's appearance so the ink color matches the menu bar.
    static func draw(_ model: MenuBarModel, in ctx: CGContext, bounds: CGRect, appearance: NSAppearance) {
        appearance.performAsCurrentDrawingAppearance {
            let ink = NSColor.labelColor.cgColor
            let mono = model.color == .monochrome
            let glyphRect = CGRect(x: 3, y: (bounds.height - glyphSide) / 2, width: glyphSide, height: glyphSide)

            var alpha: CGFloat = 1
            switch model.state {
            case .ok: alpha = model.snoozed ? 0.5 : 1
            case .connecting, .offline: alpha = 0.45
            case .error: alpha = 0.4
            }
            ctx.saveGState()
            ctx.setAlpha(alpha)
            CameraGlyph.draw(in: ctx, rect: glyphRect, ink: mono ? ink : NSColor.unifiBlue.cgColor)
            ctx.restoreGState()

            let badgeVisible = model.count > 0 && model.badge != .none
            if model.state == .error && !badgeVisible {
                drawDot(ctx, at: CGPoint(x: glyphRect.maxX - 3, y: glyphRect.minY + 4),
                        fill: mono ? ink : NSColor.systemOrange.cgColor)
            }
            guard badgeVisible else { return }
            let fill = mono ? ink : (model.state == .ok ? NSColor.systemRed.cgColor : NSColor.systemGray.cgColor)
            switch model.badge {
            case .badge:
                let size = badgeSize(model)
                let rect = CGRect(x: glyphRect.maxX - badgeOverlap, y: glyphRect.minY,
                                  width: size.width, height: size.height)
                drawBadge(ctx, rect: rect, text: model.countText, fill: fill, mono: mono)
            case .dot:
                drawDot(ctx, at: CGPoint(x: glyphRect.maxX - 3, y: glyphRect.minY + 4), fill: fill)
            case .none:
                break
            }
        }
    }

    private static func drawDot(_ ctx: CGContext, at center: CGPoint, fill: CGColor) {
        let d: CGFloat = 7
        let rect = CGRect(x: center.x - d / 2, y: center.y - d / 2, width: d, height: d)
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        ctx.fillEllipse(in: rect.insetBy(dx: -1.5, dy: -1.5))
        ctx.restoreGState()
        ctx.setFillColor(fill)
        ctx.fillEllipse(in: rect)
    }

    private static func drawBadge(_ ctx: CGContext, rect: CGRect, text: String, fill: CGColor, mono: Bool) {
        // Punch a gap around the badge so it doesn't merge with the glyph.
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        let halo = rect.insetBy(dx: -1.5, dy: -1.5)
        ctx.addPath(CGPath(roundedRect: halo, cornerWidth: halo.height / 2, cornerHeight: halo.height / 2, transform: nil))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2, transform: nil))
        ctx.setFillColor(fill)
        ctx.fillPath()
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .font: badgeFont, .foregroundColor: NSColor.white,
        ]))
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        ctx.textPosition = CGPoint(x: rect.midX - bounds.width / 2 - bounds.minX,
                                   y: rect.midY - bounds.height / 2 - bounds.minY)
        if mono { ctx.setBlendMode(.destinationOut) }   // knock the digits out of the ink pill
        CTLineDraw(line, ctx)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    static func image(for model: MenuBarModel, appearance: NSAppearance, height: CGFloat = 22) -> NSImage {
        NSImage(size: NSSize(width: width(for: model), height: height), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            draw(model, in: ctx, bounds: rect, appearance: appearance)
            return true
        }
    }
}

// MARK: - App icon

enum AppIcon {
    static func renderIconset(to directory: String) {
        let dir = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let specs: [(String, Int)] = [
            ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
            ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256),
            ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024),
        ]
        for (name, pixels) in specs {
            let rep = bitmap(side: CGFloat(pixels)) { ctx, side in draw(ctx, side: side) }
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: dir.appendingPathComponent("\(name).png"))
            }
        }
    }

    /// The camera glyph in white on a blue squircle.
    static func draw(_ ctx: CGContext, side: CGFloat) {
        let inset = side * 100 / 1024
        let rect = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
        let radius = rect.width * 0.225
        let shape = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -side * 0.012), blur: side * 0.03, color: CGColor(gray: 0, alpha: 0.3))
        ctx.addPath(shape)
        ctx.setFillColor(NSColor.unifiBlue.cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        let gradient = CGGradient(colorsSpace: srgb, colors: [
            CGColor(srgbRed: 0.22, green: 0.58, blue: 1, alpha: 1),
            CGColor(srgbRed: 0, green: 0.36, blue: 0.86, alpha: 1),
        ] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.minY), options: [])
        let glyph = rect.insetBy(dx: rect.width * 0.14, dy: rect.height * 0.14)
        CameraGlyph.draw(in: ctx, rect: glyph, ink: CGColor(gray: 1, alpha: 1))
        ctx.restoreGState()
    }

    static func bitmap(side: CGFloat, draw: (CGContext, CGFloat) -> Void) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(side), pixelsHigh: Int(side),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        draw(context.cgContext, side)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
}
