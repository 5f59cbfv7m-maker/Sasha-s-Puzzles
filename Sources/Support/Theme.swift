import CoreText
import os
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The "Organic" design tokens: a cream-and-sand ground, a terracotta accent, a
/// sage second voice, Caprasimo display type and over-rounded shapes. Every
/// colour here is dynamic — the dark values are the light ramps' lighter steps,
/// so the mark and the accents do not dim at night.
///
/// `nonisolated`: SwiftUI resolves dynamic colours on its render thread, so the
/// provider closures must not be bound to the main actor.
nonisolated enum Theme {
    // Ground
    static let bg = dynamic("f5ead8", "2e2b25")
    static let surface = dynamic("ebddc5", "3d3a32")
    static let card = dynamic("f9f4ed", "474238")
    static let text = dynamic("201e1d", "f9f4ed")
    static let muted = dynamic("645c50", "c0b6a5")
    static let faint = dynamic("82796a", "a19786")
    static let track = dynamic("dcd3c4", "5b564b")
    static let chip = dynamic("ebddc5", "524d43")
    static let blob = dynamic("eee7db", "3d3a32")
    static let blob2 = dynamic("f0fae1", "3d472b")

    // Terracotta
    static let accent = dynamic("c67139", "f6a06b")
    static let accentPressed = dynamic("b2622d", "ffc6a5")
    static let accentSoft = dynamic("d67f48", "d67f48")
    static let onAccent = dynamic("f5ead8", "402310")
    /// Accent at paragraph size — the deep ramp step keeps it readable.
    static let accentDeep = dynamic("8c491a", "ffc6a5")

    // Sage
    static let sage = dynamic("7a8a5e", "aebf92")
    static let sageSoft = dynamic("8fa073", "8fa073")
    static let onSage = dynamic("f9f4ed", "272e1b")
    static let sageTint = dynamic("e1eecc", "3d472b")
    static let onSageTint = dynamic("56633f", "f0fae1")

    /// Players at a shared table, by seat: the host is terracotta. Sage stays
    /// this player's own snap flash.
    static let players = [accent, dynamic("3f7fb5", "8cc0ec"), dynamic("9a4f8c", "dba3d1"), dynamic("a8841c", "e6c565")]
    static func player(_ slot: Int) -> Color { players[((slot % players.count) + players.count) % players.count] }

    static let radiusCard: CGFloat = 24
    static let radiusPanel: CGFloat = 28

    static var hairline: Color { text.opacity(0.08) }

    // MARK: Type

    /// Caprasimo when it is bundled; SF Rounded stands in otherwise — and also
    /// for every glyph Caprasimo lacks (it has no Cyrillic), via the cascade list.
    static func display(_ size: CGFloat) -> Font {
        guard Fonts.hasCaprasimo else { return .system(size: size, weight: .bold, design: .rounded) }
        return cached("display-\(size)") { makeDisplay(size) }
    }

    static func body(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        guard Fonts.hasFigtree else { return .system(size: size, weight: weight) }
        return cached("body-\(size)-\(weight)") { makeBody(size, weight) }
    }

    /// Fonts are memoised: a fresh `CTFont` per call is a different `Font`
    /// value every time, and inside a sheet's sizing pass that becomes an
    /// endless invalidate-and-measure loop.
    private static let fontCache = OSAllocatedUnfairLock(initialState: [String: Font]())

    private static func cached(_ key: String, _ make: @Sendable () -> Font) -> Font {
        fontCache.withLock { cache in
            if let font = cache[key] { return font }
            let font = make()
            cache[key] = font
            return font
        }
    }

    private static func makeDisplay(_ size: CGFloat) -> Font {
        let base = CTFontCreateWithName("Caprasimo-Regular" as CFString, size, nil)
        let descriptor = CTFontDescriptorCreateWithAttributes(
            [kCTFontCascadeListAttribute: [systemDescriptor(size: size, weight: .heavy, rounded: true)]] as CFDictionary)
        return Font(CTFontCreateCopyWithAttributes(base, size, nil, descriptor))
    }

    /// Figtree when bundled. It ships as a variable font whose default instance
    /// is Light, so the weight is set through the `wght` axis rather than by
    /// PostScript name; Cyrillic falls through to the system face at that weight.
    private static func makeBody(_ size: CGFloat, _ weight: Font.Weight) -> Font {
        let axisWeight: CGFloat = [.medium: 500, .semibold: 600, .bold: 700, .heavy: 800][weight] ?? 400
        let base = CTFontCreateWithName("Figtree-Light" as CFString, size, nil)
        let wghtAxis = 0x77676874  // 'wght'
        let descriptor = CTFontDescriptorCreateWithAttributes([
            kCTFontVariationAttribute: [wghtAxis: axisWeight],
            kCTFontCascadeListAttribute: [systemDescriptor(size: size, weight: weight, rounded: false)],
        ] as CFDictionary)
        return Font(CTFontCreateCopyWithAttributes(base, size, nil, descriptor))
    }

    private static func systemDescriptor(size: CGFloat, weight: Font.Weight, rounded: Bool) -> CTFontDescriptor {
        #if os(macOS)
        let weights: [Font.Weight: NSFont.Weight] = [.medium: .medium, .semibold: .semibold, .bold: .bold, .heavy: .heavy]
        var descriptor = NSFont.systemFont(ofSize: size, weight: weights[weight] ?? .regular).fontDescriptor
        if rounded { descriptor = descriptor.withDesign(.rounded) ?? descriptor }
        return descriptor as CTFontDescriptor
        #else
        let weights: [Font.Weight: UIFont.Weight] = [.medium: .medium, .semibold: .semibold, .bold: .bold, .heavy: .heavy]
        var descriptor = UIFont.systemFont(ofSize: size, weight: weights[weight] ?? .regular).fontDescriptor
        if rounded { descriptor = descriptor.withDesign(.rounded) ?? descriptor }
        return descriptor as CTFontDescriptor
        #endif
    }

    // MARK: Colours

    private static func dynamic(_ light: String, _ dark: String) -> Color {
        #if os(macOS)
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(hex: dark) : NSColor(hex: light)
        })
        #else
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        })
        #endif
    }
}

nonisolated private extension PlatformColor {
    convenience init(hex: String) {
        let value = UInt32(hex, radix: 16) ?? 0
        self.init(red: CGFloat((value >> 16) & 0xFF) / 255,
                  green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}

#if os(macOS)
private typealias PlatformColor = NSColor
#else
private typealias PlatformColor = UIColor
#endif

/// Registers the bundled display font once, at launch. Missing files are not
/// an error: `Theme.display` falls back to the system face.
nonisolated enum Fonts {
    nonisolated(unsafe) private(set) static var hasCaprasimo = false
    nonisolated(unsafe) private(set) static var hasFigtree = false

    static func register() {
        for url in Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? [] {
            guard CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) else { continue }
            let name = url.lastPathComponent.lowercased()
            if name.hasPrefix("caprasimo") { hasCaprasimo = true }
            if name.hasPrefix("figtree") { hasFigtree = true }
        }
    }
}

// MARK: - Environment

extension EnvironmentValues {
    /// Phone-width layouts; always false on the Mac.
    var isCompact: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact
        #else
        false
        #endif
    }
}

// MARK: - Shared components

/// A 44pt circular icon button: the design's "chip".
struct RoundIconButton: View {
    enum Style { case neutral, sage, accent, card }

    let symbol: String
    var style: Style = .neutral
    var size: CGFloat = 44
    /// Grows into a capsule as wide as its row allows.
    var stretch = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(foreground)
                .frame(minWidth: size, maxWidth: stretch ? .infinity : size, minHeight: size, maxHeight: size)
                .background(background, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
    }

    private var background: Color {
        switch style {
        case .neutral: Theme.chip
        case .sage: Theme.sageTint
        case .accent: Theme.accent
        case .card: Theme.card
        }
    }

    private var foreground: Color {
        switch style {
        case .neutral, .card: Theme.muted
        case .sage: Theme.onSageTint
        case .accent: Theme.onAccent
        }
    }
}

/// Capsule button. `.primary` is the solid terracotta fill with display type.
struct PillButton: View {
    enum Style { case primary, secondary, ghost, sage }

    let title: LocalizedStringKey
    var symbol: String?
    var style: Style = .primary
    var size: CGFloat = 17
    var expand = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let symbol { Image(systemName: symbol).font(.system(size: size * 0.9, weight: .bold)) }
                // CJK breaks between any two characters; a pill never wraps.
                Text(title).lineLimit(1).fixedSize()
            }
            .font(style == .primary || style == .sage ? Theme.display(size) : Theme.body(size - 2, .bold))
            .foregroundStyle(foreground)
            .padding(.horizontal, size * 1.4)
            .frame(maxWidth: expand ? .infinity : nil, minHeight: size * 2.7)
            .background(background, in: Capsule())
            .overlay(Capsule().stroke(style == .ghost ? Theme.text.opacity(0.16) : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
    }

    private var background: Color {
        switch style {
        case .primary: Theme.accent
        case .secondary: Theme.card
        case .ghost: Theme.bg
        case .sage: Theme.sage
        }
    }

    private var foreground: Color {
        switch style {
        case .primary: Theme.onAccent
        case .secondary, .ghost: Theme.text
        case .sage: Theme.onSage
        }
    }
}

/// Pressed state from the ramp: a step darker and a touch smaller.
struct PressableStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .brightness(configuration.isPressed ? -0.06 : 0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Small uppercase section label.
struct Kicker: View {
    let text: LocalizedStringKey
    var body: some View {
        Text(text)
            .font(Theme.body(12, .bold))
            .textCase(.uppercase)
            .tracking(1.2)
            .foregroundStyle(Theme.muted)
    }
}

/// Tinted capsule tag ("Daily puzzle", a category).
struct Tag: View {
    enum Style { case sage, sageTint, card }
    let text: String
    var symbol: String?
    var style: Style = .sageTint

    var body: some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .bold)) }
            Text(text)
        }
        .font(Theme.body(12, .bold))
        .foregroundStyle(style == .sage ? Theme.onSage : style == .card ? Theme.accentDeep : Theme.onSageTint)
        .padding(.horizontal, 11).padding(.vertical, 5)
        .background(style == .sage ? Theme.sage : style == .card ? Theme.card : Theme.sageTint, in: Capsule())
    }
}

/// A row of capsules, one selected — the design's segmented control.
struct PillSegments<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let title: (Option) -> String
    var expand = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { selection = option }
                } label: {
                    Text(title(option))
                        .font(Theme.body(13, selected ? .bold : .semibold))
                        .foregroundStyle(selected ? Theme.onAccent : Theme.muted)
                        .padding(.horizontal, 13).padding(.vertical, 7)
                        .frame(maxWidth: expand ? .infinity : nil)
                        .background(selected ? Theme.accent : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .padding(3)
        .background(Theme.surface, in: Capsule())
    }
}

/// Sage progress bar on a track.
struct ProgressBar: View {
    let value: Double
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { proxy in
            Capsule().fill(Theme.track)
            Capsule().fill(Theme.sage)
                .frame(width: proxy.size.width * clamp(value, 0, 1))
                .animation(.easeOut(duration: 0.4), value: value)
        }
        .frame(height: height)
    }
}

/// Faint lattice showing how a picture will be divided.
struct LatticeOverlay: View {
    let columns: Int
    let rows: Int
    var opacity: Double = 0.42

    var body: some View {
        Canvas { context, size in
            var path = Path()
            for column in 1..<max(1, columns) {
                let x = size.width * CGFloat(column) / CGFloat(columns)
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }
            for row in 1..<max(1, rows) {
                let y = size.height * CGFloat(row) / CGFloat(rows)
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(path, with: .color(Theme.card.opacity(opacity)), lineWidth: 1)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Soft circular decoration behind a page.
struct Blob: View {
    var color: Color = Theme.blob
    var size: CGFloat = 280
    var body: some View {
        Circle().fill(color).frame(width: size, height: size).allowsHitTesting(false)
    }
}

/// The app mark: a 2×2 of the engine's own lock geometry, so the logo is
/// literally four pieces rather than a drawing of one.
/// The weekly gift: a puzzle piece tied up with a ribbon and a bow. Muted
/// while it is still to be earned, in full colour once it opens.
struct GiftPiece: View {
    /// Six days in a row: the gift shines, sparkles and shakes. Before that
    /// it waits, pale and still.
    var reached = false
    var size: CGFloat = 22
    /// Bright but motionless, for the secret cards' covers.
    var still = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One loop: a light sweeps across, the gift shakes, sparkles twinkle.
    private static let loop = 2.6

    var body: some View {
        let image = Image("GiftPiece").resizable().interpolation(.high)
        Group {
            if reached && !still && !reduceMotion {
                image
                    .overlay { shine.mask(image) }
                    .keyframeAnimator(initialValue: 0.0, repeating: true) { view, angle in
                        view.rotationEffect(.degrees(angle), anchor: UnitPoint(x: 0.5, y: 0.92))
                    } keyframes: { _ in
                        CubicKeyframe(0, duration: 1.5)
                        CubicKeyframe(-7, duration: 0.16)
                        CubicKeyframe(6, duration: 0.16)
                        CubicKeyframe(-4, duration: 0.16)
                        CubicKeyframe(2.5, duration: 0.15)
                        CubicKeyframe(-1, duration: 0.16)
                        CubicKeyframe(0, duration: 0.31)
                    }
                    .overlay {
                        sparkle(x: 0.97, y: 0.08, scale: 0.3, wait: 0.3)
                        sparkle(x: 0.04, y: 0.3, scale: 0.22, wait: 1.2)
                        sparkle(x: 0.96, y: 0.86, scale: 0.24, wait: 1.9)
                    }
            } else {
                image
            }
        }
        .frame(width: size, height: size)
        .saturation(reached ? 1 : 0.3)
        .opacity(reached ? 1 : 0.5)
        .animation(.easeInOut(duration: 0.4), value: reached)
        .accessibilityLabel(Text("A gift for 7 daily puzzles in a row"))
    }

    /// A band of light crossing the gift just before it shakes.
    private var shine: some View {
        LinearGradient(colors: [.clear, .white.opacity(0.8), .clear], startPoint: .leading, endPoint: .trailing)
            .frame(width: size * 0.4, height: size * 1.6)
            .rotationEffect(.degrees(20))
            .keyframeAnimator(initialValue: -1.0, repeating: true) { band, x in
                band.offset(x: x * size)
            } keyframes: { _ in
                LinearKeyframe(-1, duration: 0.7)
                CubicKeyframe(1, duration: 0.8)
                LinearKeyframe(1, duration: Self.loop - 1.5)
            }
            .frame(width: size, height: size)
    }

    private func sparkle(x: CGFloat, y: CGFloat, scale: CGFloat, wait: Double) -> some View {
        Image(systemName: "sparkle")
            .font(.system(size: size * scale, weight: .bold))
            .foregroundStyle(Color(red: 1, green: 0.78, blue: 0.25))
            .keyframeAnimator(initialValue: 0.0, repeating: true) { view, k in
                view.scaleEffect(k).opacity(k)
            } keyframes: { _ in
                LinearKeyframe(0, duration: wait)
                CubicKeyframe(1, duration: 0.25)
                CubicKeyframe(0, duration: 0.45)
                LinearKeyframe(0, duration: Self.loop - wait - 0.7)
            }
            .position(x: size * x, y: size * y)
    }
}

struct PuzzleMark: View {
    var size: CGFloat = 128
    var shadow = true

    private static let geometry = PuzzleGeometry(columns: 2, rows: 2, aspect: 1, seed: 0x5A5A)

    var body: some View {
        Canvas { context, canvasSize in
            let colors = [Theme.accent, Theme.accentSoft, Theme.sage, Theme.sageSoft]
            let scale = canvasSize.width / (PuzzleMark.geometry.boardSize.width * 1.28)
            let inset = (canvasSize.width - PuzzleMark.geometry.boardSize.width * scale) / 2
            let transform = CGAffineTransform(translationX: inset, y: inset)
                .scaledBy(x: scale, y: scale)
            for index in 0..<4 {
                let path = Path(PuzzleMark.geometry.path(of: index)).applying(transform)
                if shadow {
                    context.drawLayer { layer in
                        layer.addFilter(.shadow(color: .black.opacity(0.22), radius: 6, y: 5))
                        layer.fill(path, with: .color(colors[index]))
                    }
                } else {
                    context.fill(path, with: .color(colors[index]))
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

extension View {
    /// The design's `.washed` image treatment: desaturated, lower contrast and
    /// lifted, so a picture sits back into the warm page.
    func washed() -> some View {
        saturation(0.72).contrast(0.9).brightness(0.04)
    }

    /// Surface-filled content card.
    func card(radius: CGFloat = Theme.radiusCard, fill: Color = Theme.card) -> some View {
        background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: .black.opacity(0.10), radius: 6, y: 3)
    }
}
