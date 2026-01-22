import SwiftUI
import UniformTypeIdentifiers

struct POSDetailsView: View {
    let shopName: String
    let accent: Color

    // Persisted
    @AppStorage("dash.range.pos.v1") private var rangeRaw: String = DashRange.w.rawValue
    @AppStorage("dash.pos.focusTs.v1") private var focusTs: Double = 0

    // Cursor + plot geometry (same pattern you already use elsewhere)
    @State private var cursorActive: Bool = false
    @State private var cursorXNorm: CGFloat = 0
    @State private var activePlotLeft: CGFloat = 0
    @State private var activePlotWidth: CGFloat = 1

    // Local UI
    @State private var range: DashRange = .w
    @State private var focusDate: Date = Date()
    @State private var pageIndex: Int = 0
    @State private var monthAnchorEndDate: Date = Date()

    // Tooltip selection
    @State private var selectedBarIndex: Int? = nil
    @State private var selectedBarX: CGFloat? = nil

    // MARK: - Calendar (ONE TZ)
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Jerusalem") ?? .current
        return c
    }
    private var today: Date { calendar.startOfDay(for: Date()) }

    // Big but finite
    private static let dayPages = 3650
    private static let weekPages = 520

    private func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int {
        guard hi >= lo else { return lo }
        return min(max(v, lo), hi)
    }

    // MARK: - Focus helpers
    private func setFocusDay(_ d: Date) {
        let dd = calendar.startOfDay(for: d)
        focusDate = dd
        focusTs = dd.timeIntervalSince1970
    }

    private func clearSelection() {
        selectedBarIndex = nil
        selectedBarX = nil
        cursorActive = false
    }

    // MARK: - Date helpers
    private func startOfMonth(_ d: Date) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: d)) ?? d
    }
    private func endOfMonth(_ d: Date) -> Date {
        let start = startOfMonth(d)
        let next = calendar.date(byAdding: .month, value: 1, to: start) ?? start
        return calendar.date(byAdding: .day, value: -1, to: next) ?? start
    }

    // MARK: - D paging (ends today)
    private func dayForDayPage(_ p: Int) -> Date {
        let newest = today
        let offsetFromNewest = (Self.dayPages - 1) - p
        return calendar.date(byAdding: .day, value: -offsetFromNewest, to: newest) ?? newest
    }
    private func pageIndexForFocusInDayPager() -> Int {
        let diff = calendar.dateComponents([.day], from: focusDate, to: today).day ?? 0
        let idx = (Self.dayPages - 1) - max(0, diff)
        return clamp(idx, 0, Self.dayPages - 1)
    }

    // MARK: - W paging (Sat→Fri)
    private func weekEndForWeekPage(_ p: Int) -> Date {
        let newestEnd = today
        let offsetFromNewest = (Self.weekPages - 1) - p
        return calendar.date(byAdding: .day, value: -offsetFromNewest * 7, to: newestEnd) ?? newestEnd
    }
    private func weekStart(forEnd end: Date) -> Date {
        calendar.date(byAdding: .day, value: -6, to: end) ?? end
    }
    private func dateForWeekIndex(_ i: Int, weekEnd: Date) -> Date {
        let start = weekStart(forEnd: weekEnd)
        return calendar.date(byAdding: .day, value: i, to: start) ?? start
    }
    private func pageIndexForFocusInWeekPager() -> Int {
        let diffDays = calendar.dateComponents([.day], from: focusDate, to: today).day ?? 0
        let weekOffset = max(0, Int(floor(Double(diffDays) / 7.0)))
        let idx = (Self.weekPages - 1) - weekOffset
        return clamp(idx, 0, Self.weekPages - 1)
    }

    // MARK: - Rolling month (anchored)
    private var monthEnd: Date { calendar.startOfDay(for: monthAnchorEndDate) }
    private var monthStart: Date { calendar.date(byAdding: .day, value: -29, to: monthEnd) ?? monthEnd }
    private func dateForMonthIndex(_ i: Int) -> Date {
        calendar.date(byAdding: .day, value: i, to: monthStart) ?? monthStart
    }

    // MARK: - 6M / Y (stable ending today)
    private func monthDateFor6mBarIndex(_ i: Int) -> Date {
        let endMonth = startOfMonth(today)
        return calendar.date(byAdding: .month, value: -(5 - i), to: endMonth) ?? endMonth
    }
    private func monthDateForYearBarIndex(_ i: Int) -> Date {
        let endMonth = startOfMonth(today)
        return calendar.date(byAdding: .month, value: -(11 - i), to: endMonth) ?? endMonth
    }

    // MARK: - POS bucket model (STACKED)
    private struct POSBucket: Identifiable {
        let id = UUID()
        var label: String
        var cashpoints: Double
        var kiosks: Double
        var minis: Double

        var total: Double { cashpoints + kiosks + minis }
    }

    // MARK: - Labels
    private func rollingWeekLabels(endingAt endDate: Date) -> [String] {
        let end = calendar.startOfDay(for: endDate)
        let fmt = DateFormatter()
        fmt.timeZone = calendar.timeZone
        fmt.locale = Locale(identifier: "en_GB")
        fmt.dateFormat = "EEE"
        return (0..<7).map { i in
            let d = calendar.date(byAdding: .day, value: i - 6, to: end) ?? end
            return fmt.string(from: d)
        }
    }

    private func monthXAxisLabels(for window: [POSBucket]) -> [String] {
        window.indices.map { i in (i % 7 == 0) ? window[i].label : "" }
    }

    // MARK: - Split model (placeholder)
    private func sourceSplit(for range: DashRange) -> (cashpoint: Double, minis: Double, kiosk: Double) {
        switch range {
        case .d:  return (0.35, 0.55, 0.10)
        case .w:  return (0.40, 0.45, 0.15)
        case .m:  return (0.45, 0.35, 0.20)
        case .m6: return (0.48, 0.30, 0.22)
        case .y:  return (0.42, 0.28, 0.30)
        }
    }

    // Small jitter so bars feel “real” but stable per bucket date
    private func jitter(_ seedDate: Date, mod: Int, amp: Double) -> Double {
        let s = (calendar.ordinality(of: .day, in: .year, for: seedDate) ?? 1) % max(1, mod)
        let t = Double(s) / Double(max(1, mod - 1)) // 0..1
        return (t - 0.5) * 2.0 * amp               // -amp..+amp
    }

    // MARK: - Build STACKED buckets per range/page
    private func makeBuckets(for page: Int) -> [POSBucket] {
        let split = sourceSplit(for: range)

        switch range {
        case .d:
            // 10 buckets 08–17 for day page
            let day = dayForDayPage(page)
            let hours = Array(8...17).map { String(format: "%02d", $0) }

            // total series (stable per day)
            let seed = Double((calendar.ordinality(of: .day, in: .year, for: day) ?? 1) % 17)
            let base = 2800.0 + seed * 100.0
            let totals: [Double] = [
                base * 0.35, base * 0.50, base * 0.60, base * 0.78, base * 0.95,
                base * 0.90, base * 1.02, base * 1.10, base * 1.28, base * 1.18
            ]

            return (0..<10).map { i in
                let t = totals[i]
                // slightly vary the mix by hour but keep stable
                let hDate = calendar.date(byAdding: .hour, value: i, to: day) ?? day
                let j = jitter(hDate, mod: 9, amp: 0.04) // -4%..+4%
                let cash = max(0.05, min(0.90, split.cashpoint + j))
                let kiosk = max(0.02, min(0.60, split.kiosk - j * 0.6))
                let minis = max(0.02, 1.0 - cash - kiosk)
                return POSBucket(
                    label: hours[i],
                    cashpoints: t * cash,
                    kiosks: t * kiosk,
                    minis: t * minis
                )
            }

        case .w:
            // 7 buckets Sat..Fri for week page
            let end = weekEndForWeekPage(page)
            let labels = rollingWeekLabels(endingAt: end)

            // stable weekly totals
            let seed = Double((calendar.ordinality(of: .day, in: .year, for: end) ?? 1) % 13)
            let base = 220_000.0 + seed * 8_000.0
            let totals = [0.72, 0.85, 0.78, 0.92, 1.05, 0.98, 1.12].map { base * $0 }

            let start = weekStart(forEnd: end)
            return (0..<7).map { i in
                let d = calendar.date(byAdding: .day, value: i, to: start) ?? start
                let t = totals[i]
                let j = jitter(d, mod: 9, amp: 0.05)
                let cash = max(0.05, min(0.90, split.cashpoint + j))
                let kiosk = max(0.02, min(0.60, split.kiosk - j * 0.6))
                let minis = max(0.02, 1.0 - cash - kiosk)
                return POSBucket(
                    label: labels[i],
                    cashpoints: t * cash,
                    kiosks: t * kiosk,
                    minis: t * minis
                )
            }

        case .m:
            // rolling 30 days ending at monthAnchorEndDate (fixed while in M)
            return (0..<30).map { i in
                let d = dateForMonthIndex(i)
                let dayNum = calendar.component(.day, from: d)

                let seed = Double((calendar.ordinality(of: .day, in: .year, for: d) ?? 1) % 9)
                let t = 180_000 + seed * 12_000

                let j = jitter(d, mod: 13, amp: 0.04)
                let cash = max(0.05, min(0.90, split.cashpoint + j))
                let kiosk = max(0.02, min(0.60, split.kiosk - j * 0.6))
                let minis = max(0.02, 1.0 - cash - kiosk)

                return POSBucket(
                    label: "\(dayNum)",
                    cashpoints: t * cash,
                    kiosks: t * kiosk,
                    minis: t * minis
                )
            }

        case .m6:
            return (0..<6).map { i in
                let d = monthDateFor6mBarIndex(i)
                let label = monthLabel(d)

                let seed = Double((calendar.component(.month, from: d) * 37) % 11)
                let t = 3_200_000 + seed * 180_000 + Double(i) * 70_000

                let j = jitter(d, mod: 11, amp: 0.03)
                let cash = max(0.05, min(0.90, split.cashpoint + j))
                let kiosk = max(0.02, min(0.60, split.kiosk - j * 0.6))
                let minis = max(0.02, 1.0 - cash - kiosk)

                return POSBucket(
                    label: label,
                    cashpoints: t * cash,
                    kiosks: t * kiosk,
                    minis: t * minis
                )
            }

        case .y:
            return (0..<12).map { i in
                let d = monthDateForYearBarIndex(i)
                let label = "\(calendar.component(.month, from: d))"

                let seed = Double((calendar.component(.month, from: d) * 19) % 13)
                let t = 2_800_000 + seed * 220_000 + Double(i) * 120_000

                let j = jitter(d, mod: 11, amp: 0.03)
                let cash = max(0.05, min(0.90, split.cashpoint + j))
                let kiosk = max(0.02, min(0.60, split.kiosk - j * 0.6))
                let minis = max(0.02, 1.0 - cash - kiosk)

                return POSBucket(
                    label: label,
                    cashpoints: t * cash,
                    kiosks: t * kiosk,
                    minis: t * minis
                )
            }
        }
    }

    // Current buckets for the current page
    private var buckets: [POSBucket] {
        makeBuckets(for: pageIndex)
    }

    // MARK: - Formatting
    private func number(_ value: Double) -> String {
        Int(value.rounded()).formatted(.number.grouping(.automatic))
    }
    private func dayMonthYear(_ d: Date) -> String {
        let f = DateFormatter()
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "d MMM yyyy"
        return f.string(from: d)
    }
    private func monthYear(_ d: Date) -> String {
        let f = DateFormatter()
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "MMM yyyy"
        return f.string(from: d)
    }
    private func monthLabel(_ d: Date) -> String {
        let f = DateFormatter()
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "MMM"
        return f.string(from: d)
    }

    private func compactRangeText(start: Date, end: Date) -> String {
        let sameMonth = calendar.component(.month, from: start) == calendar.component(.month, from: end)
        let sameYear  = calendar.component(.year, from: start) == calendar.component(.year, from: end)

        let dayFmt = DateFormatter()
        dayFmt.timeZone = calendar.timeZone
        dayFmt.locale = Locale(identifier: "en_GB")
        dayFmt.dateFormat = "d"

        let monthYearFmt = DateFormatter()
        monthYearFmt.timeZone = calendar.timeZone
        monthYearFmt.locale = Locale(identifier: "en_GB")
        monthYearFmt.dateFormat = "MMM yyyy"

        let fullFmt = DateFormatter()
        fullFmt.timeZone = calendar.timeZone
        fullFmt.locale = Locale(identifier: "en_GB")
        fullFmt.dateFormat = "d MMM yyyy"

        if sameMonth && sameYear {
            return "\(dayFmt.string(from: start))–\(dayFmt.string(from: end)) \(monthYearFmt.string(from: end))"
        } else {
            return "\(fullFmt.string(from: start)) – \(fullFmt.string(from: end))"
        }
    }

    private func sixMonthRangeText() -> String {
        let start = monthDateFor6mBarIndex(0)
        let end   = monthDateFor6mBarIndex(5)
        let sameYear = calendar.component(.year, from: start) == calendar.component(.year, from: end)
        if sameYear {
            return "\(monthLabel(start))–\(monthLabel(end)) \(calendar.component(.year, from: end))"
        } else {
            return "\(monthYear(start)) – \(monthYear(end))"
        }
    }

    // MARK: - Header
    private var headerLabel: String {
        switch range {
        case .d: return "TOTAL"
        case .w: return "AVERAGE"
        case .m, .m6, .y: return "TOTAL"
        }
    }

    private var headerValue: Double {
        let totals = buckets.map(\.total)
        guard !totals.isEmpty else { return 0 }
        switch range {
        case .d: return totals.last ?? 0
        case .w: return totals.reduce(0, +) / Double(totals.count)
        case .m, .m6, .y: return totals.last ?? 0
        }
    }

    private var periodText: String {
        switch range {
        case .d:
            let f = calendar.startOfDay(for: focusDate)
            if f == today { return "Today" }
            if f == (calendar.date(byAdding: .day, value: -1, to: today) ?? today) { return "Yesterday" }
            return dayMonthYear(focusDate)

        case .w:
            if selectedBarIndex != nil { return dayMonthYear(focusDate) }
            let end = weekEndForWeekPage(pageIndex)
            let start = weekStart(forEnd: end)
            return compactRangeText(start: start, end: end)

        case .m:
            if selectedBarIndex != nil { return dayMonthYear(focusDate) }
            return "\(dayMonthYear(monthStart)) – \(dayMonthYear(monthEnd))"

        case .m6:
            if let i = selectedBarIndex { return monthYear(monthDateFor6mBarIndex(i)) }
            return sixMonthRangeText()

        case .y:
            if let i = selectedBarIndex { return monthYear(monthDateForYearBarIndex(i)) }
            let start = monthDateForYearBarIndex(0)
            let end   = monthDateForYearBarIndex(11)
            return "\(monthYear(start)) – \(monthYear(end))"
        }
    }

    private func tooltipSubtitle(for i: Int) -> String {
        guard i >= 0, i < buckets.count else { return periodText }
        switch range {
        case .d:
            let h0 = Int(buckets[i].label) ?? 0
            let h1 = (h0 + 1) % 24
            return "\(dayMonthYear(focusDate)) \(String(format: "%02d", h0))–\(String(format: "%02d", h1))"
        case .w:
            let end = weekEndForWeekPage(pageIndex)
            return dayMonthYear(dateForWeekIndex(i, weekEnd: end))
        case .m:
            return dayMonthYear(dateForMonthIndex(i))
        case .m6:
            return monthYear(monthDateFor6mBarIndex(i))
        case .y:
            return monthYear(monthDateForYearBarIndex(i))
        }
    }

    private var selectedBucket: POSBucket? {
        guard let i = selectedBarIndex, i >= 0, i < buckets.count else { return nil }
        return buckets[i]
    }

    // Totals used for donut + rows (selected bucket if selected, else whole period)
    private var splitTotals: (cash: Double, kiosk: Double, minis: Double) {
        if let b = selectedBucket {
            return (b.cashpoints, b.kiosks, b.minis)
        }
        let cash = buckets.map(\.cashpoints).reduce(0, +)
        let kiosk = buckets.map(\.kiosks).reduce(0, +)
        let minis = buckets.map(\.minis).reduce(0, +)
        return (cash, kiosk, minis)
    }

    private var activeValue: Double {
        selectedBucket?.total ?? headerValue
    }

    // MARK: - Donut
    private struct DonutSegment { let value: Double; let color: Color }

    private struct DonutChart: View {
        let segments: [DonutSegment]
        let lineWidth: CGFloat

        var body: some View {
            GeometryReader { geo in
                let size = min(geo.size.width, geo.size.height)
                let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                let radius = size / 2 - lineWidth / 2

                ZStack {
                    Circle().stroke(Color.gray.opacity(0.12), lineWidth: lineWidth)

                    ForEach(segments.indices, id: \.self) { i in
                        let start = startAngle(i)
                        let end = endAngle(i)

                        Path { p in
                            p.addArc(center: center,
                                     radius: radius,
                                     startAngle: start,
                                     endAngle: end,
                                     clockwise: false)
                        }
                        .stroke(segments[i].color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    }
                }
            }
        }

        private func startAngle(_ i: Int) -> Angle {
            let sum = segments.prefix(i).map(\.value).reduce(0, +)
            return .degrees(-90 + 360 * sum)
        }

        private func endAngle(_ i: Int) -> Angle {
            let sum = segments.prefix(i + 1).map(\.value).reduce(0, +)
            return .degrees(-90 + 360 * sum)
        }
    }

    // MARK: - Stacked chart (best option)
    private struct HealthStackedBarChart: View {
        let buckets: [POSBucket]
        let xLabels: [String]

        // colors
        let cashColor: Color
        let kioskColor: Color
        let minisColor: Color

        // selection + cursor plumbing (same pattern)
        var selectedIndex: Binding<Int?>
        var selectedX: Binding<CGFloat?>
        var cursorActive: Binding<Bool>
        var cursorXNorm: Binding<CGFloat>
        var registerPlot: (CGFloat, CGFloat) -> Void

        @State private var isCursorMode: Bool = false

        private func labelWidth(_ s: String) -> CGFloat {
            CGFloat(max(4, s.count)) * 7.0
        }

        private func indexForX(_ x: CGFloat, leftPad: CGFloat, cellW: CGFloat, n: Int) -> Int {
            let local = max(0, x - leftPad)
            let i = Int(floor(local / max(cellW, 1)))
            return min(max(i, 0), max(0, n - 1))
        }

        var body: some View {
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height

                let leftPad: CGFloat = 10
                let topPad: CGFloat = 14
                let bottomPad: CGFloat = 15

                let totals = buckets.map(\.total)
                let maxVal = max(totals.max() ?? 1, 1)
                let midVal = maxVal / 3.0

                let maxLabel = fmt(maxVal)
                let midLabel = fmt(midVal)
                let axisWidth = max(labelWidth(maxLabel), labelWidth(midLabel)) + 18

                let plotW = max(1, w - leftPad - axisWidth)
                let plotH = max(1, h - topPad - bottomPad)

                let n = max(buckets.count, 1)
                let cellW = plotW / CGFloat(n)
                let barW = min(34, cellW * 0.55)

                // report plot for global cursor overlay
                let global = geo.frame(in: .global)

                Color.clear
                    .onAppear {
                        registerPlot(global.minX + leftPad, plotW)
                    }
                    .onChange(of: global.minX) {  _ in
                        registerPlot(global.minX + leftPad, plotW)
                    }
                    .onChange(of: plotW) { _ in
                        registerPlot(global.minX + leftPad, plotW)
                    }

                let centerX: (Int) -> CGFloat = { i in
                    leftPad + (CGFloat(i) + 0.5) * cellW
                }

                // long press -> cursor mode ON (only after selection exists)
                let longPress = LongPressGesture(minimumDuration: 0.45)
                    .onEnded { _ in
                        guard selectedIndex.wrappedValue != nil else { return }
                        isCursorMode = true
                        cursorActive.wrappedValue = true
                    }

                // local cursor drag (when long-press mode is ON)
                let dragCursor = DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        guard isCursorMode else { return }
                        let i = indexForX(g.location.x, leftPad: leftPad, cellW: cellW, n: n)
                        selectedIndex.wrappedValue = i
                        selectedX.wrappedValue = centerX(i)
                        let norm = (centerX(i) - leftPad) / max(plotW, 1)
                        cursorXNorm.wrappedValue = min(max(norm, 0), 1)
                    }
                    .onEnded { _ in
                        isCursorMode = false
                        cursorActive.wrappedValue = false
                    }

                ZStack(alignment: .topLeading) {

                    // grid
                    VStack(spacing: 0) {
                        ForEach(0..<4, id: \.self) { _ in
                            Divider().opacity(0.15)
                            Spacer()
                        }
                    }
                    .frame(width: plotW, height: plotH)
                    .offset(x: leftPad, y: topPad)

                    HStack(spacing: 0) {
                        ForEach(0..<7, id: \.self) { _ in
                            Rectangle().fill(Color.gray.opacity(0.12)).frame(width: 1)
                            Spacer()
                        }
                    }
                    .frame(width: plotW, height: plotH)
                    .offset(x: leftPad, y: topPad)
                    .opacity(0.35)

                    // bars
                    HStack(alignment: .bottom, spacing: 0) {
                        ForEach(0..<n, id: \.self) { i in
                            let b = buckets.indices.contains(i) ? buckets[i] : POSBucket(label: "", cashpoints: 0, kiosks: 0, minis: 0)
                            let total = max(b.total, 0.0001)

                            let totalH = CGFloat(total / maxVal) * plotH
                            let cashH  = totalH * CGFloat(b.cashpoints / total)
                            let kioskH = totalH * CGFloat(b.kiosks / total)
                            let minisH = totalH * CGFloat(b.minis / total)

                            VStack(spacing: 4) {
                                ZStack(alignment: .bottom) {
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color.clear)
                                        .frame(width: barW, height: max(4, totalH))

                                    VStack(spacing: 0) {
                                        Rectangle().fill(cashColor).frame(height: cashH)
                                        Rectangle().fill(kioskColor).frame(height: kioskH)
                                        Rectangle().fill(minisColor).frame(height: minisH)
                                    }
                                    .frame(width: barW, height: max(4, totalH), alignment: .bottom)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                }

                                Text(i < xLabels.count ? xLabels[i] : "")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                                    .frame(height: 14)
                            }
                            .frame(width: cellW, height: plotH + bottomPad - 8, alignment: .bottom)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if selectedIndex.wrappedValue == i {
                                    selectedIndex.wrappedValue = nil
                                    selectedX.wrappedValue = nil
                                    isCursorMode = false
                                    cursorActive.wrappedValue = false
                                } else {
                                    selectedIndex.wrappedValue = i
                                    selectedX.wrappedValue = centerX(i)
                                    isCursorMode = false
                                    cursorActive.wrappedValue = false
                                }
                            }
                        }
                    }
                    .frame(width: plotW, height: plotH + bottomPad, alignment: .bottomLeading)
                    .offset(x: leftPad, y: topPad)

                    // right axis
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(fmt(maxVal)).font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary)
                        Spacer()
                        Text(fmt(midVal)).font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary)
                        Spacer()
                        Text("0").font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary)
                    }
                    .frame(width: axisWidth - 6, height: plotH)
                    .padding(.trailing, 6)
                    .offset(x: leftPad + plotW, y: topPad)

                    // selection vertical line
                    if let idx = selectedIndex.wrappedValue, idx >= 0, idx < n {
                        Rectangle()
                            .fill(Color.gray.opacity(0.35))
                            .frame(width: 1, height: plotH)
                            .offset(x: centerX(idx), y: topPad)
                    }

                    // cursor overlay only while long-press cursor mode is on
                    if isCursorMode {
                        Color.clear
                            .contentShape(Rectangle())
                            .gesture(dragCursor)
                            .allowsHitTesting(true)
                    }
                }
                .simultaneousGesture(longPress)
            }
        }

        private func fmt(_ v: Double) -> String {
            Int(v.rounded()).formatted(.number.grouping(.automatic))
        }
    }

    // Global cursor overlay (works with stacked chart too)
    private var cursorOverlay: some View {
        Group {
            if cursorActive {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { g in
                                guard activePlotWidth > 1 else { return }
                                let x = g.location.x
                                let norm = (x - activePlotLeft) / activePlotWidth
                                cursorXNorm = min(max(norm, 0), 1)
                            }
                            .onEnded { _ in
                                cursorActive = false
                            }
                    )
            }
        }
    }

    // MARK: - Split card (donut + rows) for selected bucket or whole period
    private var splitCard: some View {
        let (cash, kiosk, minis) = splitTotals
        let total = max(cash + kiosk + minis, 1)

        let cashPct = cash / total
        let kioskPct = kiosk / total
        let minisPct = minis / total

        return VStack(alignment: .leading, spacing: 12) {

            HStack(spacing: 8) {
                Text("POS Split")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(accent)
                Spacer()
                Text(periodText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            HStack(alignment: .center, spacing: 12) {
                VStack(spacing: 0) {
                    splitRow("Cashpoints", percent: cashPct, amount: cash, color: Color.gray.opacity(0.35))
                    Divider().opacity(0.4)
                    splitRow("Kiosks", percent: kioskPct, amount: kiosk, color: Color.blue)
                    Divider().opacity(0.4)
                    splitRow("Minis", percent: minisPct, amount: minis, color: Color.teal)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                DonutChart(
                    segments: [
                        .init(value: cashPct,  color: Color.gray.opacity(0.35)),
                        .init(value: kioskPct, color: Color.blue),
                        .init(value: minisPct, color: Color.teal)
                    ],
                    lineWidth: 14
                )
                .frame(width: 86, height: 86)
            }
        }
        .padding(14)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private func splitRow(_ title: String, percent: Double, amount: Double, color: Color) -> some View {
        HStack {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Text("\(Int((percent * 100).rounded()))%")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.secondary)
                .frame(width: 44, alignment: .trailing)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(number(amount))
                    .font(.system(size: 14, weight: .semibold))
                Text("₪")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .frame(width: 120, alignment: .trailing)
        }
        .padding(.vertical, 10)
    }

    // MARK: - Header/tooltip
    private var headerOrTooltip: some View {
        ZStack(alignment: .topLeading) {

            VStack(alignment: .leading, spacing: 6) {
                Text(headerLabel)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(number(activeValue))
                        .font(.system(size: 44, weight: .bold))
                        .foregroundColor(.primary)
                    Text("₪")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.secondary)
                }

                Text(periodText)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .opacity(selectedBarIndex == nil ? 1 : 0)

            if let idx = selectedBarIndex,
               let x = selectedBarX,
               idx >= 0,
               idx < buckets.count {
                GeometryReader { geo in
                    let tooltipW: CGFloat = 250
                    let clampedX = min(max(x - tooltipW / 2, 0), max(0, geo.size.width - tooltipW))

                    let b = buckets[idx]
                    let total = max(b.total, 1)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(headerLabel)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.secondary)
                            .textCase(.uppercase)

                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(number(b.total))
                                .font(.system(size: 40, weight: .bold))
                            Text("₪")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.secondary)
                        }

                        Text(tooltipSubtitle(for: idx))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.secondary)

                        Divider().opacity(0.35)

                        HStack {
                            Text("Cashpoints").font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary)
                            Spacer()
                            Text("\(Int((b.cashpoints/total*100).rounded()))%").font(.system(size: 12, weight: .bold)).foregroundColor(.secondary)
                            Text(number(b.cashpoints)).font(.system(size: 12, weight: .semibold))
                        }
                        HStack {
                            Text("Kiosks").font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary)
                            Spacer()
                            Text("\(Int((b.kiosks/total*100).rounded()))%").font(.system(size: 12, weight: .bold)).foregroundColor(.secondary)
                            Text(number(b.kiosks)).font(.system(size: 12, weight: .semibold))
                        }
                        HStack {
                            Text("Minis").font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary)
                            Spacer()
                            Text("\(Int((b.minis/total*100).rounded()))%").font(.system(size: 12, weight: .bold)).foregroundColor(.secondary)
                            Text(number(b.minis)).font(.system(size: 12, weight: .semibold))
                        }
                    }
                    .padding(12)
                    .frame(width: tooltipW, alignment: .leading)
                    .background(Color(UIColor.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .offset(x: clampedX, y: 0)
                }
            }
        }
        .frame(height: 110)
    }

    // MARK: - Main chart
    private var chart: some View {
        Group {
            if range == .d || range == .w {
                let pageCount = (range == .d) ? Self.dayPages : Self.weekPages

                TabView(selection: $pageIndex) {
                    ForEach(0..<pageCount, id: \.self) { p in
                        let pageBuckets = makeBuckets(for: p)

                        HealthStackedBarChart(
                            buckets: pageBuckets,
                            xLabels: pageBuckets.map(\.label),
                            cashColor: Color.gray.opacity(0.35),
                            kioskColor: Color.blue,
                            minisColor: Color.teal,
                            selectedIndex: $selectedBarIndex,
                            selectedX: $selectedBarX,
                            cursorActive: $cursorActive,
                            cursorXNorm: $cursorXNorm,
                            registerPlot: { left, width in
                                activePlotLeft = left
                                activePlotWidth = max(1, width)
                            }
                        )
                        .frame(height: 260)
                        .background(Color(UIColor.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .tag(p)
                        .padding(.horizontal, 2)
                    }
                }
                .frame(height: 260)
                .tabViewStyle(.page(indexDisplayMode: .never))
                .onChange(of: pageIndex) { _ in
                    clearSelection()
                    if range == .d {
                        setFocusDay(dayForDayPage(pageIndex))
                    } else {
                        setFocusDay(weekEndForWeekPage(pageIndex))
                    }
                }

            } else {
                let pageBuckets = buckets

                HealthStackedBarChart(
                    buckets: pageBuckets,
                    xLabels: (range == .m) ? monthXAxisLabels(for: pageBuckets) : pageBuckets.map(\.label),
                    cashColor: Color.gray.opacity(0.35),
                    kioskColor: Color.blue,
                    minisColor: Color.teal,
                    selectedIndex: $selectedBarIndex,
                    selectedX: $selectedBarX,
                    cursorActive: $cursorActive,
                    cursorXNorm: $cursorXNorm,
                    registerPlot: { left, width in
                        activePlotLeft = left
                        activePlotWidth = max(1, width)
                    }
                )
                .frame(height: 260)
                .background(Color(UIColor.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 18))
            }
        }
        // keep selection tracking while global cursor drags
        .onChange(of: cursorXNorm) { newNorm in
            guard cursorActive else { return }
            let n = buckets.count
            guard n > 0 else { return }
            let idx = min(max(Int(round(newNorm * CGFloat(n - 1))), 0), n - 1)
            selectedBarIndex = idx
            selectedBarX = activePlotLeft + newNorm * activePlotWidth
        }
    }

    // MARK: Body
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {

                VStack(alignment: .leading, spacing: 4) {
                    Text("POS")
                        .font(.system(size: 34, weight: .bold))
                    Text(shopName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.secondary)
                }

                Picker("", selection: $range) {
                    ForEach(DashRange.allCases) { r in
                        Text(r.title).tag(r)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: range) { newRange in
                    clearSelection()
                    rangeRaw = newRange.rawValue

                    switch newRange {
                    case .d:
                        pageIndex = pageIndexForFocusInDayPager()
                    case .w:
                        pageIndex = pageIndexForFocusInWeekPager()
                    case .m:
                        monthAnchorEndDate = focusDate
                        pageIndex = 0
                    case .m6, .y:
                        pageIndex = 0
                    }
                }

                headerOrTooltip
                chart
                splitCard
            }
            .onChange(of: selectedBarIndex) {  sel in
                guard let i = sel else { return }

                switch range {
                case .w:
                    let end = weekEndForWeekPage(pageIndex)
                    setFocusDay(dateForWeekIndex(i, weekEnd: end))
                case .m:
                    setFocusDay(dateForMonthIndex(i))
                case .m6:
                    let m = monthDateFor6mBarIndex(i)
                    setFocusDay(min(endOfMonth(m), today))
                case .y:
                    let m = monthDateForYearBarIndex(i)
                    setFocusDay(min(endOfMonth(m), today))
                case .d:
                    // hour selection doesn’t change focus day
                    break
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 18)
        }
        .overlay { cursorOverlay }
        .background(Color(UIColor.systemGroupedBackground))
        .navigationBarTitleDisplayMode(.inline)
        .tint(accent)
        .onAppear {
            range = DashRange(rawValue: rangeRaw) ?? .w

            if focusTs > 0 {
                setFocusDay(Date(timeIntervalSince1970: focusTs))
            } else {
                setFocusDay(today)
            }

            switch range {
            case .d:
                pageIndex = pageIndexForFocusInDayPager()
            case .w:
                pageIndex = pageIndexForFocusInWeekPager()
            case .m:
                monthAnchorEndDate = focusDate
                pageIndex = 0
            case .m6, .y:
                pageIndex = 0
            }

            clearSelection()
        }
    }
}
