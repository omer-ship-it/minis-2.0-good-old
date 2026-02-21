import SwiftUI

// MARK: - Entry View (use this in your app)
struct Tesla3: View {
    var body: some View {
        RestaurantControlCenterMock()
            .preferredColorScheme(.dark)
    }
}

// MARK: - Tiny design system (tint touches only)
private enum MiniTint {
    // one accent only (ice-cyan). Use very sparingly.
    static let accent = Color(red: 0.50, green: 0.93, blue: 1.00)

    // semantic: only for meaning
    static func delta(_ text: String) -> Color {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("-") { return Color(red: 1.00, green: 0.40, blue: 0.40) }   // soft red
        if t.hasPrefix("+") { return Color(red: 0.45, green: 0.95, blue: 0.72) }   // soft green
        return .white
    }
}

struct RestaurantControlCenterMock: View {
    @State private var page: Int = 0
    @Namespace private var magic

    // ✅ Placeholder turnover values that change every 20 seconds
    @State private var turnover: Int = 18_420
    private let turnoverLoop: [Int] = [18_420, 19_060, 18_880, 19_420, 20_110, 19_780, 20_350, 19_990]
    private let timer = Timer.publish(every: 20, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            // Base background
            LinearGradient(
                colors: page == 0
                ? [Color.black.opacity(0.98), Color.black.opacity(0.92)]
                : [Color.black.opacity(0.985), Color.black.opacity(0.88)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            // Subtle vignette (Apple-ish depth)
            LinearGradient(
                colors: [Color.black.opacity(0.45), .clear],
                startPoint: .top,
                endPoint: .center
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .opacity(page == 0 ? 0.9 : 1.0)
            .animation(.easeInOut(duration: 0.45), value: page)

            TabView(selection: $page) {
                ExecutiveBriefMock(magic: magic, page: $page, turnover: $turnover)
                    .tag(0)

                LiveControlMock(page: $page, turnover: $turnover)
                    .tag(1)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(.easeInOut(duration: 0.35), value: page)

            EdgeHint(isRight: page == 0, isLeft: page == 1)
                .allowsHitTesting(false)
        }
        // ✅ Loop turnover every 20s
        .onReceive(timer) { _ in
            let idx = turnoverLoop.firstIndex(of: turnover) ?? -1
            let next = (idx + 1) % turnoverLoop.count
            withAnimation(.easeInOut(duration: 0.35)) {
                turnover = turnoverLoop[next]
            }
        }
    }
}

// MARK: - Page 1: Executive Brief (scrollable)
private struct ExecutiveBriefMock: View {
    let magic: Namespace.ID
    @Binding var page: Int
    @Binding var turnover: Int

    private let secondary = Color.white.opacity(0.86)

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 18) {
                TopBarMock(
                    title: "Beit Haam today",
                    onTapAnalytics: { print("Analytics tapped") },
                    onTapCashpoint: { print("Cashpoint tapped") }
                )

                FancyHeroHeader(
                    magic: magic,
                    turnover: turnover,
                    subtitle: "Turnover Today",
                    meta: "32 orders · Avg 575",
                    monthlyText: "Monthly 312k vs 300k",
                    deltaText: "+6%"
                )
                .padding(.top, 10)
                .padding(.bottom, 10)

                VStack(spacing: 12) {
                    GlassCard(corner: 26) { ManagerDailySummaryCard() }
                    GlassCard(corner: 26) { InsightsCard() }
                }

                Text("Swipe → for Live Control")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(secondary)
                    .padding(.top, 8)
                    .padding(.bottom, 18)
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
        }
        .opacity(page == 0 ? 1 : 0.92)
        .scaleEffect(page == 0 ? 1.0 : 0.985)
        .animation(.easeInOut(duration: 0.45), value: page)
    }
}

// MARK: - Fancy Minimal Hero Header + subtle tint touches
private struct FancyHeroHeader: View {
    let magic: Namespace.ID
    let turnover: Int
    let subtitle: String
    let meta: String
    let monthlyText: String
    let deltaText: String

    private let secondary = Color.white.opacity(0.86)
    private let bodySoft  = Color.white.opacity(0.74)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            // ✅ Subtle “clock-like” digit change (Apple)
            Text(turnover, format: .number)
                .font(.system(size: 66, weight: .regular, design: .rounded))
                .tracking(-0.9)
                .foregroundStyle(.white)
                .padding(.top, 2)
                .contentTransition(.numericText())
                .animation(.easeInOut(duration: 0.35), value: turnover)
                .matchedGeometryEffect(id: "hero.number", in: magic)
                // tiny “jewelry” glow only in accent (very subtle)
                .shadow(color: MiniTint.accent.opacity(0.10), radius: 18, x: 0, y: 0)

            // keep subtitle minimal; no extra color
            Text(meta)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(secondary)

            // ✅ semantic tint only: green for +, red for -
            Text(deltaText)
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .foregroundStyle(MiniTint.delta(deltaText))
                .matchedGeometryEffect(id: "hero.delta", in: magic)
                .padding(.top, 10)

            HStack(spacing: 20) {
                Text("Weekly 72%")
                Text(monthlyText)
            }
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(bodySoft)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Cards
private struct ManagerDailySummaryCard: View {
    private let secondary = Color.white.opacity(0.86)
    private let titleColor = Color.white

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("SUMMARY")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(titleColor)
                Spacer()
                Text("Last 3 days")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(secondary)
            }

            VStack(spacing: 10) {
                BriefRow(
                    badge: .neutral,
                    title: "Today • 14:32",
                    message: "Lunch was slower due to rain. Dinner bookings look strong. Team morale good.",
                    rightLabel: "Read more ›"
                )
                DividerHairline()
                BriefRow(
                    badge: .neutral,
                    title: "Yesterday • 21:10",
                    message: "Great dinner flow. Two VIP tables, high dessert attach rate. Minor delay on mains.",
                    rightLabel: "Read more ›"
                )
                DividerHairline()
                BriefRow(
                    badge: .neutral,
                    title: "2 days ago • 20:55",
                    message: "Breakfast up after new combo. Coffee station needed extra help. Stock check recommended.",
                    rightLabel: "Read more ›"
                )
            }
        }
    }
}

private struct InsightsCard: View {
    private let secondary = Color.white.opacity(0.86)
    private let titleColor = Color.white

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("INSIGHTS")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(titleColor)
                Spacer()
                Text("Newest 3")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(secondary)
            }

            VStack(spacing: 10) {
                BriefRow(
                    badge: .accent,
                    title: "Pace Forecast • Now",
                    message: "If tonight matches the usual Thursday average, weekly target will be exceeded by ~6%. Consider pushing dessert upsell from 19:00.",
                    rightLabel: "Read more ›"
                )
                DividerHairline()
                BriefRow(
                    badge: .warning,
                    title: "Lunch Dip Detected • 13:40",
                    message: "Orders between 12–14 are down 18% vs last week. Weather correlation suspected. Consider a rain-day promo push.",
                    rightLabel: "Read more ›"
                )
                DividerHairline()
                BriefRow(
                    badge: .accent,
                    title: "AOV Trend • 12:58",
                    message: "Average order value is up 9% since the combo launch. Consider featuring it earlier in the flow and on signage.",
                    rightLabel: "Read more ›"
                )
            }
        }
    }
}

// MARK: - Insight row with tiny tint badge (very subtle)
private enum RowBadge {
    case neutral
    case accent
    case warning

    var color: Color {
        switch self {
        case .neutral: return .white.opacity(0.10)
        case .accent:  return MiniTint.accent.opacity(0.22)
        case .warning: return Color(red: 1.00, green: 0.75, blue: 0.30).opacity(0.22)
        }
    }

    var stroke: Color {
        switch self {
        case .neutral: return .white.opacity(0.10)
        case .accent:  return MiniTint.accent.opacity(0.30)
        case .warning: return Color(red: 1.00, green: 0.75, blue: 0.30).opacity(0.30)
        }
    }
}

private struct BriefRow: View {
    let badge: RowBadge
    let title: String
    let message: String
    let rightLabel: String

    private let secondary = Color.white.opacity(0.86)
    private let bodyColor = Color.white.opacity(0.78)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {

                // tiny tint indicator (jewelry touch)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(badge.color)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(badge.stroke, lineWidth: 1)
                    )
                    .frame(width: 18, height: 18)

                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(secondary)

                Spacer()

                Text(rightLabel)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(secondary)
            }

            Text(message)
                .font(.system(size: 13, weight: .regular, design: .rounded))
                .foregroundStyle(bodyColor)
                .lineLimit(3)
        }
    }
}

private struct DividerHairline: View {
    var body: some View {
        Rectangle()
            .fill(.white.opacity(0.10))
            .frame(height: 1)
            .padding(.vertical, 2)
    }
}

// MARK: - Page 2: Live Control (scrollable) - no hero header, tint touches in chips/pills
private struct LiveControlMock: View {
    @Binding var page: Int
    @Binding var turnover: Int

    @State private var selectedZone: String = "Dining"

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 14) {
                TopBarMock(
                    title: "Live Control",
                    onTapAnalytics: { print("Analytics tapped") },
                    onTapCashpoint: { print("Cashpoint tapped") }
                )

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        SmallStatPill(title: "Today", value: "\(String(format: "%.1f", Double(turnover) / 1000.0))k")
                        SmallStatPill(title: "Orders", value: "32")
                        SmallStatPill(title: "Load", value: "Med")
                    }
                    .padding(.vertical, 2)
                }

                ZStack {
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(.white.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 26, style: .continuous)
                                .stroke(.white.opacity(0.08), lineWidth: 1)
                        )

                    VStack(spacing: 10) {
                        Text("Restaurant Map")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.90))

                        Text("Tap tables • Pulse alerts • Live occupancy")
                            .font(.system(size: 13, weight: .regular, design: .rounded))
                            .foregroundStyle(.white.opacity(0.80))

                        MapDotsMock()
                            .frame(height: 180)
                            .padding(.top, 10)

                        HStack(spacing: 10) {
                            ZoneChip("Dining", selected: $selectedZone)
                            ZoneChip("Kitchen", selected: $selectedZone)
                            ZoneChip("Bar", selected: $selectedZone)
                            Spacer()
                        }
                        .padding(.top, 4)
                    }
                    .padding(18)
                }
                .frame(maxHeight: 360)

                ControlDockMock()

                GlassCard(corner: 22) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Cameras")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.90))
                            Text("Swipe to switch feed")
                                .font(.system(size: 12, weight: .regular, design: .rounded))
                                .foregroundStyle(.white.opacity(0.78))
                        }
                        Spacer()
                        HStack(spacing: 8) {
                            CameraThumbMock()
                            CameraThumbMock()
                            CameraThumbMock()
                        }
                    }
                }

                Text("← Swipe back to Brief")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.86))
                    .padding(.top, 8)
                    .padding(.bottom, 18)
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
        }
        .opacity(page == 1 ? 1 : 0.92)
        .scaleEffect(page == 1 ? 1.0 : 0.985)
        .animation(.easeInOut(duration: 0.45), value: page)
    }
}

// MARK: - Top Bar (icons get subtle accent ring on press via hit area)
private struct TopBarMock: View {
    let title: String
    var onTapAnalytics: (() -> Void)? = nil
    var onTapCashpoint: (() -> Void)? = nil

    private let secondary = Color.white.opacity(0.86)

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(secondary)

            Spacer()

            HStack(spacing: 18) {
                Button { onTapAnalytics?() } label: {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(secondary)
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button { onTapCashpoint?() } label: {
                    Image(systemName: "hand.point.up.braille.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(secondary)
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 6)
    }
}

// MARK: - Pills with a tiny accent stroke (very subtle)
private struct SmallStatPill: View {
    let title: String
    let value: String

    private let secondary = Color.white.opacity(0.86)

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(secondary)
                .lineLimit(1)

            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(
            Capsule()
                .fill(.white.opacity(0.06))
                .overlay(
                    Capsule().stroke(MiniTint.accent.opacity(0.14), lineWidth: 1) // ✅ tint touch
                )
        )
        .frame(minWidth: 92, alignment: .leading)
    }
}

// MARK: - Reusable bits
private struct GlassCard<Content: View>: View {
    var corner: CGFloat = 24
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(.white.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: corner, style: .continuous)
                            .stroke(.white.opacity(0.08), lineWidth: 1)
                    )
            )
    }
}

private struct ZoneChip: View {
    let title: String
    @Binding var selected: String
    init(_ title: String, selected: Binding<String>) {
        self.title = title
        self._selected = selected
    }
    var isSelected: Bool { selected == title }

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(isSelected ? 1.0 : 0.78))
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(
                Capsule()
                    .fill(isSelected ? MiniTint.accent.opacity(0.14) : .white.opacity(0.06)) // ✅ tint touch
                    .overlay(
                        Capsule().stroke(isSelected ? MiniTint.accent.opacity(0.22) : .white.opacity(0.08), lineWidth: 1)
                    )
            )
            .onTapGesture { selected = title }
    }
}

private struct MapDotsMock: View {
    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(0..<16, id: \.self) { i in
                    let x = CGFloat((i * 37) % 100) / 100.0
                    let y = CGFloat((i * 53) % 100) / 100.0
                    Circle()
                        .fill(.white.opacity(0.24))
                        .frame(width: 10, height: 10)
                        .position(x: geo.size.width * x, y: geo.size.height * y)
                }

                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.white.opacity(0.08),
                            style: StrokeStyle(lineWidth: 1, dash: [6, 8]))
            }
        }
    }
}

private struct ControlDockMock: View {
    var body: some View {
        GlassCard(corner: 26) {
            HStack(spacing: 12) {
                ControlTileMock(title: "Lights", subtitle: "Scene")
                ControlTileMock(title: "Temp", subtitle: "22°")
                ControlTileMock(title: "Music", subtitle: "Chill")
                ControlTileMock(title: "Cams", subtitle: "4")
            }
        }
    }
}

private struct ControlTileMock: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.white.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(.white.opacity(0.10), lineWidth: 1)
                )
                .frame(height: 46)

            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.86))
            Text(subtitle)
                .font(.system(size: 11, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.78))
        }
        .frame(maxWidth: .infinity)
    }
}

private struct CameraThumbMock: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(.white.opacity(0.07))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.white.opacity(0.09), lineWidth: 1)
            )
            .frame(width: 54, height: 38)
    }
}

private struct EdgeHint: View {
    let isRight: Bool
    let isLeft: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if isRight {
                    LinearGradient(
                        colors: [.clear, MiniTint.accent.opacity(0.06)], // ✅ tiny tint on edge
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 26)
                    .position(x: geo.size.width - 13, y: geo.size.height / 2)
                }
                if isLeft {
                    LinearGradient(
                        colors: [MiniTint.accent.opacity(0.06), .clear], // ✅ tiny tint on edge
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 26)
                    .position(x: 13, y: geo.size.height / 2)
                }
            }
        }
        .ignoresSafeArea()
    }
}
