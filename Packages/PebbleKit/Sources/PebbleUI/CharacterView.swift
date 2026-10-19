import PebbleCore
#if canImport(SwiftUI)
import SwiftUI

/// The agent's character: a soft glowing stone with a friendly face.
///
/// It breathes slowly and blinks now and then. While a reply is on its way
/// it thinks: its glow breathes quicker and brighter and its eyes glance up.
/// With Reduce Motion on, or `holdsStill` for the screenshots, it holds
/// still, and thinking shows only as the glance and a brighter glow.
public struct CharacterView: View {
    let look: AgentLook
    let size: CGFloat
    var isCheerful: Bool
    /// True while a reply is on its way. Only how it looks changes.
    var isThinking: Bool

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.holdsStill) private var holdsStill

    private var reduceMotion: Bool { systemReduceMotion || holdsStill }

    public init(look: AgentLook, size: CGFloat = 120, isCheerful: Bool = false, isThinking: Bool = false) {
        self.look = look
        self.size = size
        self.isCheerful = isCheerful
        self.isThinking = isThinking
    }

    public var body: some View {
        let colors = Theme.colors(for: look)
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let breath = Breath.look(at: time, thinking: isThinking, reduceMotion: reduceMotion)
            ZStack {
                Circle()
                    .fill(colors[0].opacity(breath.glowOpacity))
                    .frame(width: size * 1.35, height: size * 1.35)
                    .blur(radius: size * 0.18)
                    .scaleEffect(breath.glow)
                RoundedRectangle(cornerRadius: size * 0.46, style: .continuous)
                    .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: size, height: size * 0.94)
                    .overlay(alignment: .topLeading) {
                        Ellipse()
                            .fill(.white.opacity(0.35))
                            .frame(width: size * 0.34, height: size * 0.18)
                            .rotationEffect(.degrees(-24))
                            .offset(x: size * 0.16, y: size * 0.12)
                    }
                    .shadow(color: colors[1].opacity(0.35), radius: size * 0.12, y: size * 0.08)
                    .scaleEffect(breath.body)
                face(at: time)
                    .scaleEffect(breath.body)
            }
        }
        .frame(width: size * 1.4, height: size * 1.4)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: isThinking)
        .accessibilityHidden(true)
    }

    private func face(at time: TimeInterval) -> some View {
        let phase = time.truncatingRemainder(dividingBy: 4.2)
        let blink = !reduceMotion && phase < 0.16
        // Thinking, the eyes glance up and aside, as if mulling it over.
        let glance = isThinking ? CGSize(width: size * 0.03, height: -size * 0.04) : .zero
        return VStack(spacing: size * 0.08) {
            HStack(spacing: size * 0.22) {
                eye(closed: blink)
                eye(closed: blink)
            }
            .offset(glance)
            Smile(depth: isCheerful ? 0.7 : isThinking ? 0.3 : 0.45)
                .stroke(.white, style: StrokeStyle(lineWidth: size * 0.045, lineCap: .round))
                .frame(width: size * 0.26, height: size * 0.1)
        }
        .offset(y: size * 0.04)
        .animation(.easeInOut(duration: 0.12), value: blink)
    }

    private func eye(closed: Bool) -> some View {
        Capsule()
            .fill(.white)
            .frame(width: size * 0.085, height: closed ? size * 0.02 : size * 0.12)
    }
}

struct Smile: Shape {
    var depth: CGFloat
    var animatableData: CGFloat {
        get { depth }
        set { depth = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.midX, y: rect.minY + rect.height * depth * 2)
        )
        return path
    }
}

#Preview {
    HStack { ForEach(AgentLook.allCases, id: \.self) { CharacterView(look: $0, size: 80) } }
}
#endif
