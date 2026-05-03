import SwiftUI

struct AnalyticsV1View: View {

    @AppStorage("analytics.range.v1") private var storedRangeRaw: String = AnalyticsRange.d.rawValue
    @AppStorage("miniAppId") private var miniAppId: Int = 12

    @State private var showCustomRange = false
    @State private var suppressRangeHandler = true

    @StateObject private var vm: AnalyticsV1VM

    private let accent = Color(red: 0.50, green: 0.93, blue: 1.00)

    @MainActor
    init() {
        _vm = StateObject(wrappedValue: AnalyticsV1VM(store: DashboardStore()))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 14) {

                    // Range segmented + calendar
                    HStack(spacing: 10) {
                        rangePicker

                        Button { showCustomRange = true } label: {
                            Image(systemName: "calendar")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.85))
                                .frame(width: 44, height: 44)
                                .background(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .fill(.white.opacity(0.06))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                                .stroke(.white.opacity(0.10), lineWidth: 1)
                                        )
                                )
                        }
                        .buttonStyle(.plain)
                    }

                    // MARK: - Turnover
                    NavigationLink {
                        BottomLineDetailView(
                            reports: vm.store.reports,
                            liveToday: vm.store.liveToday,
                            accent: .blue
                        )
                    } label: {
                    GlassCard(corner: 26) {
                        VStack(alignment: .leading, spacing: 14) {
                            CardHeader(title: "Turnover", subtitle: vm.headerSubtitle())

                            let total = vm.total(miniAppId: effectiveMiniAppId)
                            let orders = vm.orders(miniAppId: effectiveMiniAppId)
                            let aov = vm.aov(total: total, orders: orders)
                            let hr = vm.ordersPerHour(orders: orders)
                            let delta = vm.deltaPct()

                            HStack(alignment: .firstTextBaseline) {
                                Text("₪\(AnalyticsFormat.int(total))")
                                    .font(.system(size: 42, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.white)
                                    .monospacedDigit()
                                    .contentTransition(.numericText())
                                    .animation(.easeInOut(duration: 0.25), value: total)

                                Spacer()

                                Text(AnalyticsFormat.delta(delta))
                                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                                    .foregroundStyle(delta >= 0 ? .green.opacity(0.85) : .red.opacity(0.85))
                                    .padding(.vertical, 8)
                                    .padding(.horizontal, 12)
                                    .background(
                                        Capsule()
                                            .fill(.white.opacity(0.06))
                                            .overlay(Capsule().stroke(.white.opacity(0.10), lineWidth: 1))
                                    )
                            }

                            NBAStatsRow(items: [
                                .init(label: "ORD", value: "\(orders)"),
                                .init(label: "AOV", value: "₪\(AnalyticsFormat.int(aov))"),
                                .init(label: "HR", value: String(format: "%.1f", hr))
                            ])

                            if vm.range == .d && !vm.useCustomRange {
                                HourlyBars(values: vm.hourlyPointsForDay(), accent: accent, accentBars: 1)
                                    .frame(height: 70)
                                    .padding(.top, 6)
                            } else {
                                SparklineBars(values: vm.sparkValuesForRange(), accent: accent, accentBars: 1)
                                    .frame(height: 56)
                                    .padding(.top, 6)
                            }

                            if let err = vm.errorText {
                                Text(err)
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.45))
                                    .lineLimit(2)
                            }
                        }
                    }
                    }
                    .buttonStyle(.plain)

                    // MARK: - Channels (outline pie + minimal table)
                    NavigationLink {
                        POSDetailsView(shopName: "", accent: .blue)
                    } label: {
                    GlassCard(corner: 26) {
                        VStack(alignment: .leading, spacing: 16) {

                            CardHeader(
                                title: "Channels",
                                subtitle: "\(vm.range.rawValue)"
                            )

                            let snap = vm.channelsSnapshot()
                            let metrics = snap.metrics
                            let totalOrders = snap.totalOrders

                            let selfOrders = metrics
                                .filter { $0.channel != .cashpoint }
                                .reduce(0) { $0 + $1.orders }

                            let selfPct = snap.selfPct
                            let restPct = max(0.0, 100.0 - selfPct)

                            let segs: [OutlinePieChart.Seg] = [
                                .init(
                                    id: "self",
                                    label: "SELF",
                                    pct: selfPct,
                                    stroke: Color(red: 0.45, green: 0.95, blue: 0.72).opacity(0.95), // same green family as delta +
                                    lineWidth: 14
                                ),
                                .init(
                                    id: "rest",
                                    label: "REST",
                                    pct: restPct,
                                    stroke: .white.opacity(0.18),
                                    lineWidth: 14
                                )
                            ]

                            ZStack {
                                OutlinePieChart(segments: segs)
                                    .frame(width: 160, height: 160)

                                VStack(spacing: 4) {
                                    Text("\(Int(selfPct.rounded()))%")
                                        .font(.system(size: 36, weight: .semibold, design: .rounded))
                                        .foregroundStyle(.white)
                                        .monospacedDigit()

                                    Text("Self Orders")
                                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                                        .foregroundStyle(.white.opacity(0.65))

                                   
                                }
                            }
                            .frame(maxWidth: .infinity)

                            Rectangle()
                                .fill(.white.opacity(0.06))
                                .frame(height: 1)
                                .padding(.vertical, 6)

                            ChannelsTable(
                                metrics: metrics,
                                totalOrders: totalOrders
                            )
                        }
                    }
                    }
                    .buttonStyle(.plain)

                    // MARK: - Top Products (Top 5)
                    NavigationLink {
                        SalesReportView(
                            title: "Items",
                            shopName: "",
                            initialRange: vm.range.asDashRange,
                            reports: vm.store.reports,
                            makeTop: { subset in vm.store.aggregatedTop(from: subset) },
                            accent: .blue
                        )
                    } label: {
                        TopProductsCardTop5(accent: accent)
                    }
                    .buttonStyle(.plain)

                    Spacer().frame(height: 10)
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 24)
            }
        }
        .navigationTitle("Analytics")
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showCustomRange) {
            CustomRangeSheet(
                isPresented: $showCustomRange,
                start: vm.customStart ?? Calendar.current.date(byAdding: .day, value: -7, to: Date())!,
                end: vm.customEnd ?? Date(),
                onApply: { s, e in
                    Task { @MainActor in
                        await Task.yield()
                        vm.applyCustom(start: s, end: e)
                        await vm.sync(miniAppId: effectiveMiniAppId)
                    }
                }
            )
            .preferredColorScheme(.dark)
        }
        .task {
            suppressRangeHandler = true
            vm.range = AnalyticsRange(rawValue: storedRangeRaw) ?? .d
            storedRangeRaw = vm.range.rawValue
            vm.loadCached()

            Task { @MainActor in
                await Task.yield()
                await vm.sync(miniAppId: effectiveMiniAppId)
                suppressRangeHandler = false
            }
        }
    }

    private var effectiveMiniAppId: Int { miniAppId > 0 ? miniAppId : 12 }

    // MARK: - iOS 16/17 compatible picker + onChange
    @ViewBuilder
    private var rangePicker: some View {
        if #available(iOS 17.0, *) {
            Picker("", selection: $vm.range) {
                ForEach(AnalyticsRange.allCases) { r in
                    Text(r.rawValue).tag(r)
                }
            }
            .pickerStyle(.segmented)
            .tint(.white.opacity(0.9))
            .onChange(of: vm.range) { _, newValue in
                handleRangeChanged(newValue)
            }
        } else {
            Picker("", selection: $vm.range) {
                ForEach(AnalyticsRange.allCases) { r in
                    Text(r.rawValue).tag(r)
                }
            }
            .pickerStyle(.segmented)
            .tint(.white.opacity(0.9))
            .onChange(of: vm.range) { newValue in
                handleRangeChanged(newValue)
            }
        }
    }

    private func handleRangeChanged(_ newValue: AnalyticsRange) {
        guard !suppressRangeHandler else { return }
        Task { @MainActor in
            await Task.yield()
            storedRangeRaw = newValue.rawValue
            vm.clearCustom()
            await vm.sync(miniAppId: effectiveMiniAppId)
        }
    }
}

// MARK: - Top Products (Top 5) Card

private struct TopProductsCardTop5: View {

    struct Item: Identifiable {
        let id = UUID()
        let name: String
        let qty: Int
        let revenue: Double
    }

    let accent: Color

    // ✅ Placeholder data (replace later with vm/store parsed top)
    private let items: [Item] = [
        .init(name: "הפוך", qty: 314, revenue: 4971),
        .init(name: "קפה קר", qty: 81, revenue: 1422),
        .init(name: "טוסט גבינות", qty: 29, revenue: 1421),
        .init(name: "סלט יווני", qty: 18, revenue: 952),
        .init(name: "באסקית", qty: 27, revenue: 884)
    ]

    var body: some View {
        GlassCard(corner: 26) {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader(title: "Top Products", subtitle: "Top 5")

                HStack(spacing: 10) {
                    Text("#").frame(width: 22, alignment: .leading)
                    Text("Product").frame(maxWidth: .infinity, alignment: .leading)
                    Text("QTY").frame(width: 54, alignment: .trailing)
                    Text("₪").frame(width: 84, alignment: .trailing)
                }
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.45))
                .padding(.top, 2)

                DividerHairline()

                ForEach(Array(items.prefix(5).enumerated()), id: \.offset) { idx, it in
                    TopProductRow(
                        rank: idx + 1,
                        name: it.name,
                        qty: it.qty,
                        revenue: it.revenue,
                        accent: accent
                    )

                    if idx != min(items.count, 5) - 1 {
                        DividerHairline()
                    }
                }
            }
        }
    }
}

private struct TopProductRow: View {
    let rank: Int
    let name: String
    let qty: Int
    let revenue: Double
    let accent: Color

    var body: some View {
        HStack(spacing: 10) {

            ZStack(alignment: .leading) {
                if rank <= 3 {
                    Capsule()
                        .fill(accent.opacity(0.14))
                        .overlay(Capsule().stroke(accent.opacity(0.18), lineWidth: 1))
                        .frame(width: 20, height: 18)
                        .offset(x: -4)
                }

                Text("\(rank)")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 22, alignment: .leading)
            }

            Text(name)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("\(qty)")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.78))
                .monospacedDigit()
                .frame(width: 54, alignment: .trailing)

            Text(AnalyticsFormat.int(revenue))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
                .monospacedDigit()
                .frame(width: 84, alignment: .trailing)
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Jewelry UI bits

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

private struct CardHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
            Spacer()
            Text(subtitle)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.65))
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
                .padding(.leading, 2)
        }
    }
}

private struct DividerHairline: View {
    var body: some View {
        Rectangle()
            .fill(.white.opacity(0.08))
            .frame(height: 1)
            .padding(.vertical, 2)
    }
}

// MARK: - Turnover stats

private struct NBAStatsRow: View {
    struct Item: Identifiable {
        let id = UUID()
        let label: String
        let value: String
    }
    let items: [Item]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { i in
                let it = items[i]
                VStack(spacing: 6) {
                    Text(it.label)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)

                    Text(it.value)
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .frame(maxWidth: .infinity)

                if i != items.indices.last {
                    Rectangle()
                        .fill(.white.opacity(0.05))
                        .frame(width: 1, height: 36)
                }
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Channels table (pct + orders + aov)

private struct ChannelsTable: View {

    let metrics: [ChannelMetricPct]
    let totalOrders: Int

    var body: some View {

        VStack(spacing: 10) {

            HStack {
                Text("Channel")
                Spacer()
                Text("%")
                Spacer().frame(width: 30)
                Text("Orders")
                Spacer().frame(width: 30)
                Text("AOV")
            }
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.45))

            ForEach(metrics) { m in
                HStack {
                    Text(m.channel.short)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))

                    Spacer()

                    Text("\(Int(m.pct.rounded()))%")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                        .monospacedDigit()

                    Spacer().frame(width: 30)

                    Text("\(m.orders)")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                        .monospacedDigit()

                    Spacer().frame(width: 30)

                    Text("—")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .padding(.vertical, 4)

                if m.id != metrics.last?.id {
                    Rectangle()
                        .fill(.white.opacity(0.05))
                        .frame(height: 1)
                }
            }
        }
    }
}

// MARK: - Custom range sheet

private struct CustomRangeSheet: View {
    @Binding var isPresented: Bool
    @State var start: Date
    @State var end: Date
    let onApply: (Date, Date) -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 14) {
                HStack {
                    Text("Custom Range")
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))
                    Spacer()
                    Button("Close") { isPresented = false }
                        .foregroundStyle(.white.opacity(0.7))
                }

                DatePicker("Start", selection: $start, displayedComponents: [.date])
                    .datePickerStyle(.compact)
                    .tint(.white.opacity(0.9))
                    .foregroundStyle(.white.opacity(0.85))

                DatePicker("End", selection: $end, displayedComponents: [.date])
                    .datePickerStyle(.compact)
                    .tint(.white.opacity(0.9))
                    .foregroundStyle(.white.opacity(0.85))

                Button {
                    onApply(start, end)
                    isPresented = false
                } label: {
                    Text("Apply")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(.white.opacity(0.9))
                        )
                }
                .buttonStyle(.plain)

                Spacer()
            }
            .padding(16)
        }
    }
}

// MARK: - Charts

private struct HourlyBars: View {
    let values: [HourPoint]
    let accent: Color
    let accentBars: Int

    var body: some View {
        GeometryReader { geo in
            let maxV = max(values.map(\.v).max() ?? 1, 1)
            let gap: CGFloat = 6
            let count = max(values.count, 1)
            let barW = max((geo.size.width - gap * CGFloat(count - 1)) / CGFloat(count), 2)

            let last = values.indices.last ?? 0
            let accentFrom = max(0, last - (accentBars - 1))

            VStack(spacing: 8) {
                HStack(alignment: .bottom, spacing: gap) {
                    ForEach(values.indices, id: \.self) { i in
                        let p = values[i]
                        let height = CGFloat(p.v / maxV) * (geo.size.height - 18)
                        let isAccent = i >= accentFrom

                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isAccent ? accent.opacity(0.22) : .white.opacity(0.18))
                            .frame(width: barW, height: max(6, height))
                    }
                }
                .frame(height: geo.size.height - 18, alignment: .bottom)

                HStack(spacing: gap) {
                    ForEach(values.indices, id: \.self) { i in
                        let p = values[i]
                        let show = (p.h == 8 || p.h == 12 || p.h == 16 || p.h == 20)
                        Text(show ? "\(p.h)" : "")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.40))
                            .frame(width: barW)
                    }
                }
                .frame(height: 14)
            }
        }
    }
}

private struct SparklineBars: View {
    let values: [Double]
    let accent: Color
    let accentBars: Int

    var body: some View {
        GeometryReader { geo in
            let maxV = max(values.max() ?? 1, 1)
            let count = max(values.count, 1)
            let gap: CGFloat = 6
            let barW = max((geo.size.width - gap * CGFloat(count - 1)) / CGFloat(count), 2)

            let last = values.indices.last ?? 0
            let accentFrom = max(0, last - (accentBars - 1))

            HStack(alignment: .bottom, spacing: gap) {
                ForEach(values.indices, id: \.self) { i in
                    let height = CGFloat(values[i] / maxV) * geo.size.height
                    let isAccent = i >= accentFrom

                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isAccent ? accent.opacity(0.22) : .white.opacity(0.18))
                        .frame(width: barW, height: max(6, height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }
}

// MARK: - Outline pie chart

struct OutlinePieChart: View {
    struct Seg: Identifiable {
        let id: String
        let label: String
        let pct: Double
        let stroke: Color
        let lineWidth: CGFloat
    }

    let segments: [Seg]
    let gapDegrees: Double = 2.0
    let startAtTop: Double = -90.0

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let safe = normalize(segments)

            ZStack {
                Circle()
                    .stroke(.white.opacity(0.10), lineWidth: max(10, safe.map(\.lineWidth).max() ?? 12))
                    .frame(width: size, height: size)

                ForEach(safe) { s in
                    Circle()
                        .trim(from: s.from, to: s.to)
                        .stroke(s.stroke, style: StrokeStyle(lineWidth: s.lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(startAtTop))
                        .frame(width: size, height: size)
                }

                Circle()
                    .fill(.black.opacity(0.001))
                    .frame(width: size * 0.62, height: size * 0.62)
            }
            .frame(width: size, height: size)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private struct TrimSeg: Identifiable {
        let id: String
        let from: CGFloat
        let to: CGFloat
        let stroke: Color
        let lineWidth: CGFloat
        let label: String
        let pct: Double
    }

    private func normalize(_ input: [Seg]) -> [TrimSeg] {
        let order = ["COUNTER", "SELF", "MINI", "APP"]
        let sorted = input.sorted {
            (order.firstIndex(of: $0.label) ?? 999) < (order.firstIndex(of: $1.label) ?? 999)
        }

        let total = sorted.reduce(0.0) { $0 + max(0, $1.pct) }
        guard total > 0.0001 else { return [] }

        var cur: Double = 0.0
        var out: [TrimSeg] = []

        for s in sorted {
            let pct = max(0, s.pct)
            if pct <= 0 { continue }

            let sweep = (pct / total) * 360.0
            let gap = min(gapDegrees, max(0, sweep - 0.5))
            let sweepEffective = max(0, sweep - gap)

            let fromDeg = cur + gap / 2
            let toDeg = fromDeg + sweepEffective

            out.append(
                TrimSeg(
                    id: s.id,
                    from: CGFloat(fromDeg / 360.0),
                    to: CGFloat(toDeg / 360.0),
                    stroke: s.stroke,
                    lineWidth: s.lineWidth,
                    label: s.label,
                    pct: s.pct
                )
            )

            cur += sweep
        }

        return out
    }
}

// MARK: - AnalyticsRange ↔ DashRange bridge

extension AnalyticsRange {
    var asDashRange: DashRange {
        switch self {
        case .d:  return .d
        case .w:  return .w
        case .m:  return .m
        case .m6: return .m6
        case .y:  return .y
        }
    }
}
