import SwiftUI

/// The app icon's palette: deep navy, an off-white bubble, a cyan → violet waveform.
enum Theme {
    static let navyTop = Color(red: 0x2A / 255, green: 0x27 / 255, blue: 0x58 / 255)
    static let navyBottom = Color(red: 0x13 / 255, green: 0x11 / 255, blue: 0x26 / 255)
    static let ink = Color(red: 0xF3 / 255, green: 0xF4 / 255, blue: 0xFA / 255)
    static let cyan = Color(red: 0x38 / 255, green: 0xBD / 255, blue: 0xF8 / 255)
    static let violet = Color(red: 0x8B / 255, green: 0x5C / 255, blue: 0xF6 / 255)
    static let record = Color(red: 0xFF / 255, green: 0x4D / 255, blue: 0x6D / 255)
    static let card = Color.white.opacity(0.06)
    static let cardStroke = Color.white.opacity(0.09)
    static let dim = ink.opacity(0.55)

    static let wave = LinearGradient(colors: [cyan, violet], startPoint: .leading, endPoint: .trailing)
    static let background = LinearGradient(colors: [navyTop, navyBottom], startPoint: .top, endPoint: .bottom)
}

struct ThemedBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .toolbarBackground(.hidden, for: .navigationBar)
    }
}

extension View {
    func themed() -> some View { modifier(ThemedBackground()) }

    func card(padding: CGFloat = 16, radius: CGFloat = 18) -> some View {
        self.padding(padding)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(Theme.cardStroke))
    }
}

/// The icon's nine bars. Idle they breathe; recording they follow the mic.
struct WaveBars: View {
    var level: Float = 0
    var live = false
    var barWidth: CGFloat = 6
    var height: CGFloat = 44
    private let shape: [CGFloat] = [0.25, 0.45, 0.75, 1.0, 0.7, 0.95, 0.6, 0.4, 0.22]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: !live)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            // One gradient across the whole row, like the icon, masked by the bars.
            Theme.wave.mask {
                HStack(alignment: .center, spacing: barWidth * 0.8) {
                    ForEach(shape.indices, id: \.self) { i in
                        let wobble = live ? 0.55 + 0.45 * sin(t * 7 + Double(i) * 1.3) : 1
                        let amp = live ? max(0.12, CGFloat(level) * CGFloat(wobble)) : 1
                        Capsule().frame(width: barWidth, height: max(barWidth, height * shape[i] * amp))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: CGFloat(shape.count) * barWidth * 1.8, height: height)
            .animation(.easeOut(duration: 0.12), value: level)
        }
    }
}

struct GradientButtonStyle: ButtonStyle {
    var color: AnyShapeStyle = AnyShapeStyle(Theme.wave)
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.headline, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 22).padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(color, in: Capsule())
            .shadow(color: Theme.violet.opacity(0.35), radius: 14, y: 6)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}
