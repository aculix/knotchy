import SwiftUI

/// Flared top "shoulders" like the notch's own; `rect` includes them.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { (topRadius, bottomRadius) = (newValue.first, newValue.second) }
    }

    func path(in rect: CGRect) -> Path {
        let top = max(0, min(topRadius, rect.width / 4, rect.height / 2))
        let bottom = max(0, min(bottomRadius, (rect.width - 2 * top) / 2, rect.height - top))
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + top, y: rect.minY + top),
                          control: CGPoint(x: rect.minX + top, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + top, y: rect.maxY - bottom))
        path.addQuadCurve(to: CGPoint(x: rect.minX + top + bottom, y: rect.maxY),
                          control: CGPoint(x: rect.minX + top, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - top - bottom, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom),
                          control: CGPoint(x: rect.maxX - top, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                          control: CGPoint(x: rect.maxX - top, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

struct Morph: ViewModifier, Animatable {
    var progress: CGFloat
    var smallest: CGFloat = 0.55
    var blur: CGFloat = 10
    var clearUntil: CGFloat = 0.3
    var opaqueFrom: CGFloat = 0.85

    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content
            .scaleEffect(smallest + (1 - smallest) * progress, anchor: .top)
            .blur(radius: max(0, 1 - progress) * blur)
            .opacity(Double(min(1, max(0, (progress - clearUntil) / (opaqueFrom - clearUntil)))))
    }
}

extension AnyTransition {
    /// Old content is gone early so it barely overlaps the new.
    static var island: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: Morph(progress: 0), identity: Morph(progress: 1)),
            removal: .modifier(active: Morph(progress: 0, smallest: 0.8, blur: 8, clearUntil: 0.6, opaqueFrom: 0.95),
                               identity: Morph(progress: 1, smallest: 0.8, blur: 8, clearUntil: 0.6, opaqueFrom: 0.95))
                .animation(.spring(response: 0.2, dampingFraction: 1))
        )
    }

    static var swap: AnyTransition {
        .modifier(active: Morph(progress: 0, smallest: 0.92, blur: 6, clearUntil: 0.2, opaqueFrom: 0.8),
                  identity: Morph(progress: 1, smallest: 0.92, blur: 6, clearUntil: 0.2, opaqueFrom: 0.8))
            .animation(.spring(response: 0.3, dampingFraction: 0.9))
    }
}

enum Motion {
    static let open = Animation.spring(response: 0.46, dampingFraction: 0.74)
    static let resize = Animation.spring(response: 0.42, dampingFraction: 0.8)
    static let fold = Animation.spring(response: 0.4, dampingFraction: 0.84)
    static let small = Animation.spring(response: 0.4, dampingFraction: 0.7)
    static let hide = Animation.spring(response: 0.36, dampingFraction: 0.9)
}

struct KnotMark: View {
    var size: CGFloat
    var color: Color = Palette.coral

    var body: some View {
        KnotShape()
            .stroke(color, style: StrokeStyle(lineWidth: size * 1.9 / 18, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// `KnotGlyph.strands` are in an 18-point box.
struct KnotShape: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 18
        var path = Path()
        for strand in KnotGlyph.strands {
            path.move(to: CGPoint(x: rect.minX + strand[0].x * scale, y: rect.minY + strand[0].y * scale))
            for point in strand.dropFirst() {
                path.addLine(to: CGPoint(x: rect.minX + point.x * scale, y: rect.minY + point.y * scale))
            }
        }
        return path
    }
}

struct Breathing: ViewModifier {
    func body(content: Content) -> some View {
        content.phaseAnimator([1.0, 0.55]) { view, opacity in
            view.opacity(opacity)
        } animation: { _ in .easeInOut(duration: 1.6) }
    }
}

enum Palette {
    static let coral = Color(red: 1, green: 0.54, blue: 0.36)
    static let green = Color(red: 0.25, green: 0.86, blue: 0.47)
    static let red = Color(red: 1, green: 0.38, blue: 0.36)
    static let amber = Color(red: 1, green: 0.72, blue: 0.2)
    static let surface = LinearGradient(colors: [Color(white: 0.1), Color(white: 0.055)],
                                        startPoint: .top, endPoint: .bottom)
}

struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration)
    }

    struct Styled: View {
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .foregroundStyle(.white.opacity(isEnabled ? (hovering ? 1 : 0.72) : 0.22))
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(.white.opacity(configuration.isPressed ? 0.18 : (hovering && isEnabled ? 0.1 : 0)))
                )
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

struct CapsuleButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, destructive }

    var kind: Kind = .secondary
    var small = false

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, kind: kind, small: small)
    }

    struct Styled: View {
        let configuration: Configuration
        let kind: Kind
        let small: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: small ? 11 : 12, weight: .semibold))
                .lineLimit(1)
                .padding(.horizontal, small ? 9 : 14)
                .frame(height: small ? 20 : 28)
                .foregroundStyle(foreground)
                .background(Capsule().fill(fill))
                .contentShape(Capsule())
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
        }

        private var foreground: Color {
            switch kind {
            case .primary: .black
            case .secondary: .white
            case .destructive: Palette.red
            }
        }

        private var fill: Color {
            let boost = configuration.isPressed ? 0.1 : (hovering ? 0.06 : 0)
            switch kind {
            case .primary: return .white.opacity(0.92 + boost)
            case .secondary: return .white.opacity(0.12 + boost)
            case .destructive: return Palette.red.opacity(0.16 + boost * 1.5)
            }
        }
    }
}
