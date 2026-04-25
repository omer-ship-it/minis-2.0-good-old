import SwiftUI
import UniformTypeIdentifiers
import Foundation
import Combine

// MARK: - Time Range

enum DashRange: String, CaseIterable, Identifiable {
    case d  = "יום"
    case w  = "שבוע"
    case m  = "חודש"
    case m6 = "6 חודשים"
    case y  = "שנה"

    var id: String { rawValue }
    var title: String { rawValue }
}

// MARK: - CSV Export Sheet (current vs custom)


// MARK: - Models (minimal)

struct SalesLine: Identifiable {
    let id = UUID()
    var name: String
    var amount: Double
    var qty: Int
    var category: String? = nil
}



// MARK: - Date utils for ZReport

private enum ZDateUtil {
    static func parseDate(_ s: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }

        let iso2 = ISO8601DateFormatter()
        iso2.formatOptions = [.withInternetDateTime]
        if let d = iso2.date(from: s) { return d }

        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: String(s.prefix(10)))
    }

    static func dayKey(_ d: Date, cal: Calendar) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = cal.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: cal.startOfDay(for: d))
    }
}

private extension ZReportDashboard {
    var rangeFromDate: Date? { ZDateUtil.parseDate(rangeFrom) }
}

 extension Array where Element == ZReportDashboard {
    func dailyPaidMap(cal: Calendar) -> [String: Double] {
        var out: [String: Double] = [:]
        for r in self {
            guard let d = r.rangeFromDate else { continue }
            let k = ZDateUtil.dayKey(d, cal: cal)
            out[k, default: 0] += (r.cashTotal + r.cardTotal)   // ✅ paid only
        }
        return out
    }

    func sumPaid(in interval: DateInterval, cal: Calendar) -> Double {
        let s = cal.startOfDay(for: interval.start)
        let e = cal.startOfDay(for: interval.end)
        var total: Double = 0
        for r in self {
            guard let d = r.rangeFromDate else { continue }
            let day = cal.startOfDay(for: d)
            if day >= s && day < e {
                total += (r.cashTotal + r.cardTotal)            // ✅ paid only
            }
        }
        return total
    }
}

// MARK: - The small dashboard: Income + Items only

struct DashboardView: View {
    @AppStorage("dash.range.income.v1") private var rangeRaw: String = DashRange.w.rawValue
    @AppStorage("miniAppId") private var miniAppId: Int = 12

    @StateObject private var store = DashboardStore()

    @State private var showExportSheet = false
    @State private var refreshToken = UUID()
    @State private var showCashpoint = false
    
    private var rangeBinding: Binding<DashRange> {
        Binding(
            get: { DashRange(rawValue: rangeRaw) ?? .w },
            set: { rangeRaw = $0.rawValue }
        )
    }
    private var range: DashRange { rangeBinding.wrappedValue }
    
    private func grossForDay(_ d: Date) -> Double {
        let key = ZDateUtil.dayKey(d, cal: calendarIL)

        // ✅ if date is today and liveToday exists -> use it
        if key == ZDateUtil.dayKey(today, cal: calendarIL),
           let live = store.liveToday {
            // ✅ income should NOT include team tables
            return max(0, live.gross - (live.teamTotal ?? 0))
        }

        return dailyGross[key] ?? 0
    }
    private var liveTeamTotalToday: Double {
        store.liveToday?.teamTotal ?? 0
    }
    
    private var todayKey: String {
        ZDateUtil.dayKey(today, cal: calendarIL)
    }

    private func sumGrossIncludingLive(_ interval: DateInterval) -> Double {
        let cal = calendarIL
        let start = cal.startOfDay(for: interval.start)
        let end = cal.startOfDay(for: interval.end)

        var total = store.reports.sumGross(in: interval, cal: cal)

        // If interval includes today, add liveToday.gross (because it is NOT in ZReports)
        if let live = store.liveToday,
           let liveDate = ZDateUtil.parseDate(live.date) {
            let ld = cal.startOfDay(for: liveDate)
            if ld >= start && ld < end {
                total += max(0, live.gross - (live.teamTotal ?? 0))
            }
        }
        return total
    }
    
    private func hourlyForToday08to17() -> [Double] {
        guard let live = store.liveToday else { return Array(repeating: 0, count: 10) }

        var byHour: [Int: Double] = [:]
        for b in live.hourly?.buckets ?? [] { byHour[b.h] = b.gross }

        return Array(8...17).map { byHour[$0] ?? 0 }
    }
    private var calendarIL: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Jerusalem") ?? .current
        return c
    }
    private var today: Date { calendarIL.startOfDay(for: Date()) }

    // ---- REAL Income aggregates from store.reports ----

    private var dailyGross: [String: Double] {
        store.reports.dailyGrossMap(cal: calendarIL)
    }


    private func currentInterval(for range: DashRange) -> DateInterval {
        let cal = calendarIL
        let endDay = cal.startOfDay(for: Date())

        switch range {
        case .d:
            return DateInterval(start: endDay, end: cal.date(byAdding: .day, value: 1, to: endDay) ?? endDay)

        case .w:
            let start = cal.date(byAdding: .day, value: -6, to: endDay) ?? endDay
            let end = cal.date(byAdding: .day, value: 1, to: endDay) ?? endDay
            return DateInterval(start: start, end: end)

        case .m:
            let start = cal.date(byAdding: .day, value: -29, to: endDay) ?? endDay
            let end = cal.date(byAdding: .day, value: 1, to: endDay) ?? endDay
            return DateInterval(start: start, end: end)

        case .m6:
            let start = cal.date(byAdding: .month, value: -6, to: endDay) ?? endDay
            let end = cal.date(byAdding: .day, value: 1, to: endDay) ?? endDay
            return DateInterval(start: start, end: end)

        case .y:
            let start = cal.date(byAdding: .year, value: -1, to: endDay) ?? endDay
            let end = cal.date(byAdding: .day, value: 1, to: endDay) ?? endDay
            return DateInterval(start: start, end: end)
        }
    }

    private func sumPaidIncludingLive(_ interval: DateInterval) -> Double {
        let cal = calendarIL
        let start = cal.startOfDay(for: interval.start)
        let end = cal.startOfDay(for: interval.end)

        var total = store.reports.sumPaid(in: interval, cal: cal)

        if let live = store.liveToday,
           let liveDate = ZDateUtil.parseDate(live.date) {
            let ld = cal.startOfDay(for: liveDate)
            if ld >= start && ld < end {
                total += (live.cash + live.card)   // ✅ paid only (today not in ZReports)
            }
        }
        return total
    }
    
    private var baseIncomeForPeriod: Double {
        sumPaidIncludingLive(currentInterval(for: range))
    }
    
    private var reductionsForRange: (discounts: Double, cancellations: Double, other: Double, team: Double) {
        var discounts = 0.0
        var cancellations = 0.0
        var other = 0.0
        var team = 0.0

        // sums from ZReports in range (team is NOT in ZReports)
        for r in zReportsInCurrentRange {
            let rr = parseReductions(from: r)
            discounts += rr.discounts
            cancellations += rr.cancellations
            other += rr.other
        }

        // ✅ add LIVE today if the range includes today
        let interval = currentInterval(for: range)
        let s = calendarIL.startOfDay(for: interval.start)
        let e = calendarIL.startOfDay(for: interval.end)
        let td = calendarIL.startOfDay(for: today)

        if td >= s && td < e {
            let live = liveReductionsForToday
            discounts += live.discounts
            cancellations += live.cancellations
            other += live.other

            // ✅ TEAM TABLES total (from live "today" payload)
            team += liveTeamTablesTotal
        }

        return (discounts, cancellations, other, team)
    }

    private var reductionsTotal: Double {
        let r = reductionsForRange
        return r.discounts + r.cancellations + r.other + r.team
    }
    
    private var currentHourIndex08to17: Int? {
        let h = calendarIL.component(.hour, from: Date())
        guard (8...17).contains(h) else { return nil }
        return h - 8   // 08 → 0, 09 → 1, … 17 → 9
    }
    
    private func hourlySeriesForDay(_ day: Date) -> [Double] {
        // ✅ If we have no real money for the day, don't draw fake bars
        let dayTotal = grossForDay(day)
        guard dayTotal > 0 else {
            return Array(repeating: 0, count: 10) // 08–17
        }

        // Otherwise, distribute the day total across 10 hours with a stable shape.
        // (Later you’ll replace this with real HourBucket parsing.)
        let seed = Double((calendarIL.ordinality(of: .day, in: .year, for: day) ?? 1) % 17)
        let shape = [
            0.40, 0.55, 0.65, 0.80, 0.95,
            0.90, 1.05, 1.10, 1.30, 1.20
        ]

        // normalize shape to sum=1
        let sum = shape.reduce(0, +)
        let weights = shape.map { $0 / sum }

        // allocate totals by weight
        // (so the 10 bars add up to dayTotal)
        let base = dayTotal
        return weights.map { base * $0 }
    }

    private func incomeSeries(for range: DashRange) -> [Double] {
        let cal = calendarIL

        switch range {

        case .d:
            // ✅ Use LIVE hourly buckets for today (08–17)
            // If liveToday not available yet, return zeros (honest) or fallback weights.
            if store.liveToday != nil {
                return hourlyForToday08to17()
            } else {
                return Array(repeating: 0, count: 10) // 08–17
            }

        case .w:
            let start = cal.date(byAdding: .day, value: -6, to: today) ?? today
            return (0..<7).map { i in
                let d = cal.date(byAdding: .day, value: i, to: start) ?? start
                return grossForDay(d)
            }

        case .m:
            let start = cal.date(byAdding: .day, value: -27, to: today) ?? today
            return (0..<4).map { w in
                let weekStart = cal.date(byAdding: .day, value: w * 7, to: start) ?? start
                return (0..<7).reduce(0.0) { acc, i in
                    let d = cal.date(byAdding: .day, value: i, to: weekStart) ?? weekStart
                    return acc + grossForDay(d)
                }
            }

        case .m6:
            let endMonth = cal.date(from: cal.dateComponents([.year, .month], from: today)) ?? today
            return (0..<6).map { i in
                let mStart = cal.date(byAdding: .month, value: -(5 - i), to: endMonth) ?? endMonth
                let next   = cal.date(byAdding: .month, value: 1, to: mStart) ?? mStart

                return sumGrossIncludingLive(DateInterval(start: mStart, end: next))
            }

        case .y:
            let endMonth = cal.date(from: cal.dateComponents([.year, .month], from: today)) ?? today
            return (0..<12).map { i in
                let mStart = cal.date(byAdding: .month, value: -(11 - i), to: endMonth) ?? endMonth
                let next   = cal.date(byAdding: .month, value: 1, to: mStart) ?? mStart

                return sumGrossIncludingLive(DateInterval(start: mStart, end: next))
            }
        }
    }

    private func sparklineNormalized(for range: DashRange) -> [CGFloat] {
        let s = incomeSeries(for: range)
        let maxV = max(s.max() ?? 1, 1)
        return s.map { CGFloat($0 / maxV) }
    }

    private var headlineIncome: Double {
        baseIncomeForPeriod
    }

    // ---- CSV builder (real income total; rest minimal for now) ----

   

    // ---- UI helpers ----

    private func number(_ value: Double) -> String {
        Int(value.rounded()).formatted(.number.grouping(.automatic))
    }

    private var cardBackground: Color {
        Color(UIColor.secondarySystemGroupedBackground)
    }

    // MARK: - UI

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {

                    // Title
                   

                    // Range picker
                    Picker("", selection: rangeBinding) {
                        ForEach(DashRange.allCases) { r in
                            Text(r.title).tag(r)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.top, 2)

                    // ✅ Income card (tap -> BottomLineDetailView)
                    NavigationLink {
                        BottomLineDetailView(
                            reports: store.reports,
                            liveToday: store.liveToday,   // ✅ pass
                            accent: .blue
                        )
                    } label: {
                        VStack(alignment: .leading, spacing: 10) {

                            HStack(spacing: 6) {
                                Image(systemName: "chart.bar.fill")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(.blue)

                                Text("הכנסות")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(.blue)

                                Spacer()

                                // ✅ Chevron like before
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.secondary)
                            }

                            HStack(alignment: .bottom, spacing: 12) {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text(number(headlineIncome))
                                        .font(.system(size: 30, weight: .bold))
                                        .foregroundColor(.primary)
                                        .contentTransition(.numericText())

                                    Text("₪")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(.secondary)
                                }
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)

                                Spacer()

                                Group {
                                    if range == .y {
                                        MiniBarSparklineFit(
                                            values: sparklineNormalized(for: range),
                                            accent: .blue
                                        )
                                        .frame(width: 120, height: 54)

                                    } else if range == .d {
                                        MiniBarSparklineFixed(
                                            values: sparklineNormalized(for: range),
                                            accent: .blue,
                                            highlightIndex: currentHourIndex08to17
                                        )
                                        .frame(width: 120, height: 54, alignment: .bottom)
                                        .padding(.trailing, 30)
                                    } else {
                                        MiniBarSparklineFixed(
                                            values: sparklineNormalized(for: range),
                                            accent: .blue,
                                            highlightIndex: nil
                                        )
                                        .frame(width: 120, height: 54)
                                    }
                                }
                                .frame(width: 120, height: 54)
                            }
                            .padding(.top, 10)
                        }
                        .padding(14)
                        .background(cardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .contentShape(RoundedRectangle(cornerRadius: 18))
                    }
                    .buttonStyle(.plain)

                    
                    
                    // Items report card (placeholder list for now)
                    NavigationLink {
                        SalesReportView(
                          title: "פריטים",
                          shopName: "",
                          initialRange: range,
                          reports: store.reports,
                          makeTop: { subset in store.aggregatedTop(from: subset) },
                          accent: .blue
                        )
                    } label: {
                        itemsSalesSummaryCard
                            .contentShape(RoundedRectangle(cornerRadius: 18))
                    }
                    .buttonStyle(.plain)

                    // Loading / error small status
                    if store.isLoading {
                        Text("Loading reports…")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.secondary)
                            .padding(.top, 6)
                    }
                    if let err = store.error {
                        Text(err)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.red)
                            .padding(.top, 6)
                    }
                    reductionsCard
                   
                }
                .id(store.refreshStamp)
                .padding(.horizontal, 14)
                .padding(.bottom, 18)
            }
            .navigationTitle("בית העם")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showCashpoint = true
                    } label: {
                        Image(systemName: "rectangle.and.hand.point.up.left.fill")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .tint(.primary)
                }
            }
            
            .navigationDestination(isPresented: $showCashpoint) {
              CashPointView()
            }
            .background(Color(UIColor.systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {

                // ✅ 1) instant render from cache
                store.loadCached()

                // ✅ 2) then refresh from network
                Task {
                    await store.syncSince(miniAppId: miniAppId)
                }
            }
            
        }
         
        .environment(\.layoutDirection, .rightToLeft)
        .environment(\.locale, Locale(identifier: "he_IL"))
       
    }

    // MARK: - Items report card (simple)

    private var itemsSalesSummaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {

            // 🔵 Header (icon + title + chevron)
            HStack(spacing: 8) {
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.blue)

                Text("פריטים")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.blue)

                Spacer()

                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.secondary)
            }

            // 📋 Rows
            VStack(spacing: 0) {
                let lines = topCategoriesForRange.prefix(5)

                if lines.isEmpty {
                    Text("No items for this range")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(.vertical, 14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(Array(lines.enumerated()), id: \.element.id) { idx, line in
                        HStack(spacing: 10) {

                            // Name
                            Text(line.name)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.primary)
                                .lineLimit(1)

                            Spacer()

                            // Amount + quantity
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("· (\(line.qty))")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.secondary)
                                HStack(alignment: .firstTextBaseline, spacing: 4) {
                                    Text(number(line.amount))
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundColor(.primary)

                                    Text("₪")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(.secondary)
                                }

                               
                            }
                        }
                        .padding(.vertical, 10)

                        if idx != min(4, lines.count - 1) {
                            Divider().opacity(0.5)
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    // MARK: - Placeholder items/categories (ONLY for items card, until wired)

    private var placeholderTopItems: [SalesLine] {
        [
            .init(name: "Toast גבינות", amount: 2140, qty: 44),
            .init(name: "Cappuccino", amount: 1870, qty: 71),
            .init(name: "Croissant", amount: 1640, qty: 52),
            .init(name: "Bagel + Salmon", amount: 1490, qty: 19),
            .init(name: "Fresh Juice", amount: 1120, qty: 36),
        ]
    }

    private var placeholderTopCategories: [SalesLine] {
        [
            .init(name: "Bakery", amount: 6420, qty: 231),
            .init(name: "Coffee", amount: 4880, qty: 310),
            .init(name: "Food", amount: 3120, qty: 88),
            .init(name: "Drinks", amount: 1460, qty: 140),
            .init(name: "Merch", amount: 380, qty: 9),
        ]
    }
    
    private struct ZReportDashboardPayload: Decodable {
        let top: TopBlock?

        struct TopBlock: Decodable {
            let categories: [TopLine]?
            let items: [TopLine]?
        }

        struct TopLine: Decodable {
            let name: String?
            let amount: Double?
            let qty: Int?
        }
    }

    private func parseTop(from report: ZReportDashboard) -> (cats: [ZReportDashboardPayload.TopLine], items: [ZReportDashboardPayload.TopLine]) {
        guard let s = report.jsonData, !s.isEmpty,
              let data = s.data(using: .utf8)
        else { return ([], []) }

        do {
            let payload = try JSONDecoder().decode(ZReportDashboardPayload.self, from: data)
            return (payload.top?.categories ?? [], payload.top?.items ?? [])
        } catch {
            // print("❌ top parse failed reportId=\(report.id):", error)
            return ([], [])
        }
    }
    
    private var zReportsInCurrentRange: [ZReportDashboard] {
        let cal = calendarIL
        let interval = currentInterval(for: range)

        let s = cal.startOfDay(for: interval.start)
        let e = cal.startOfDay(for: interval.end)

        return store.reports.filter { r in
            guard let d = r.rangeFromDate else { return false }
            let day = cal.startOfDay(for: d)
            return day >= s && day < e
        }
    }

    private var topCategoriesForRange: [SalesLine] {
        // ✅ D range: use LIVE today top.categories
        if range == .d, let cats = store.liveToday?.top?.categories {
            return cats.map { SalesLine(name: $0.name, amount: $0.amount, qty: $0.qty) }
        }

        // existing ZReports logic (keep as-is)
        var byName: [String: (amount: Double, qty: Int)] = [:]
        for r in zReportsInCurrentRange {
            let tops = parseTop(from: r).cats
            for t in tops {
                let name = (t.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }
                let amt = t.amount ?? 0
                let qty = t.qty ?? 0
                let cur = byName[name] ?? (0, 0)
                byName[name] = (cur.amount + amt, cur.qty + qty)
            }
        }
        return byName
            .map { SalesLine(name: $0.key, amount: $0.value.amount, qty: $0.value.qty) }
            .sorted { $0.amount > $1.amount }
    }

    private var topItemsForRange: [SalesLine] {
        // ✅ D range: use LIVE today top.items
        if range == .d, let items = store.liveToday?.top?.items {
            return items.map { SalesLine(name: $0.name, amount: $0.amount, qty: $0.qty) }
        }

        // existing ZReports logic (keep as-is)
        var byName: [String: (amount: Double, qty: Int)] = [:]
        for r in zReportsInCurrentRange {
            let tops = parseTop(from: r).items
            for t in tops {
                let name = (t.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }
                let amt = t.amount ?? 0
                let qty = t.qty ?? 0
                let cur = byName[name] ?? (0, 0)
                byName[name] = (cur.amount + amt, cur.qty + qty)
            }
        }
        return byName
            .map { SalesLine(name: $0.key, amount: $0.value.amount, qty: $0.value.qty) }
            .sorted { $0.amount > $1.amount }
    }
    
    private struct ZReportReductionsPayload: Decodable {
        let reductions: Reductions?

        struct Reductions: Decodable {
            let discounts: Double?
            let cancellations: Double?
            let other: Double?
        }
    }
    
    private var liveTeamTablesTotal: Double {
        store.liveToday?.teamTotal ?? 0
    }
    
    private var liveReductionsForToday: (discounts: Double, cancellations: Double, other: Double) {
        guard let t = store.liveToday else { return (0, 0, 0) }
        return (t.discounts ?? 0, t.cancellations ?? 0, t.other ?? 0)
    }
    
    private func parseReductions(from report: ZReportDashboard) -> (discounts: Double, cancellations: Double, other: Double) {
        guard let s = report.jsonData, !s.isEmpty,
              let data = s.data(using: .utf8)
        else { return (0, 0, 0) }

        do {
            let payload = try JSONDecoder().decode(ZReportReductionsPayload.self, from: data)
            let r = payload.reductions
            return (
                r?.discounts ?? 0,
                r?.cancellations ?? 0,
                r?.other ?? 0
            )
        } catch {
            return (0, 0, 0)
        }
    }
    
    private var reductionsCard: some View {
        NavigationLink {
       
            ReductionsDetailView(
                   reports: store.reports,
                   liveToday: store.liveToday,   // optional, only if you want “today” live reductions
                   accent: .blue
               )
        } label: {
            VStack(alignment: .leading, spacing: 12) {

                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.blue)

                    Text("הפחתות")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.blue)

                    Spacer()

                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.secondary)
                }

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(number(reductionsTotal))
                        .font(.system(size: 30, weight: .bold))
                        .foregroundColor(.primary)
                    Text("₪")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.secondary)
                }

                let r = reductionsForRange
                VStack(spacing: 0) {
                    reductionRow("ביטולים", r.cancellations)
                    Divider().opacity(0.4)
                    reductionRow("הנחות", r.discounts)
                    Divider().opacity(0.4)
                    reductionRow("על חשבון הבית", r.other)
                    Divider().opacity(0.4)
                    reductionRow("שולחנות צוות", r.team)
                }
            }
            .padding(14)
            .background(cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
    }

    private func reductionRow(_ title: String, _ value: Double) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.primary)

            Spacer()

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(number(value))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.primary)

                Text("₪")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 10)
    }

    // MARK: - Sparkline

    private struct MiniBarSparklineFit: View {
        let values: [CGFloat]
        let accent: Color

        var body: some View {
            GeometryReader { geo in
                let n = max(values.count, 1)
                let spacing: CGFloat = 4
                let minBar: CGFloat = 7

                let available = geo.size.width - spacing * CGFloat(max(0, n - 1))
                let barW = max(3, available / CGFloat(n))

                HStack(alignment: .bottom, spacing: spacing) {
                    ForEach(values.indices, id: \.self) { i in
                        let v = max(0, min(1, values[i]))

                        RoundedRectangle(cornerRadius: 3)
                            .fill(
                                i == values.count - 1
                                ? accent
                                : accent.opacity(v == 0 ? 0.35 : 1.0)
                            )
                            .frame(
                                width: barW,
                                height: v == 0
                                    ? minBar
                                    : max(minBar, v * geo.size.height)
                            )
                    }
                }
            }
        }
    }
    
    private struct MiniBarSparklineFixed: View {
        let values: [CGFloat]
        let accent: Color
        let highlightIndex: Int?

        var body: some View {
            let minBar: CGFloat = 7

            HStack(alignment: .bottom, spacing: 5) {
                ForEach(values.indices, id: \.self) { i in
                    let v = max(0, min(1, values[i]))

                    RoundedRectangle(cornerRadius: 3)
                        .fill(
                            i == highlightIndex
                            ? accent
                            : accent.opacity(v == 0 ? 0.35 : 1.0)
                        )
                        .frame(
                            width: 10,
                            height: v == 0
                                ? minBar
                                : max(minBar, v * 54)
                        )
                }
            }
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: .bottomTrailing
            )
        }
    }
}

struct ExportRangeSheet: View {
    @Environment(\.dismiss) private var dismiss

    let defaultRange: DateInterval
    let buildCSV: (_ range: DateInterval) -> String

    @State private var mode: Mode = .current
    @State private var start: Date
    @State private var end: Date

    // ✅ share sheet
    @State private var showShare = false
    @State private var shareURL: URL?

    enum Mode: String, CaseIterable, Identifiable {
        case current = "תצוגה נוכחית"
        case custom  = "טווח מותאם"
        var id: String { rawValue }
    }

    init(defaultRange: DateInterval, buildCSV: @escaping (DateInterval) -> String) {
        self.defaultRange = defaultRange
        self.buildCSV = buildCSV
        _start = State(initialValue: defaultRange.start)
        _end   = State(initialValue: defaultRange.end)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("טווח", selection: $mode) {
                        ForEach(Mode.allCases) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if mode == .custom {
                    Section("תאריכים") {
                        DatePicker("מתאריך", selection: $start, displayedComponents: .date)
                        DatePicker("עד תאריך", selection: $end, displayedComponents: .date)
                    }
                } else {
                    Section("ייצוא") {
                        Text(pretty(defaultRange))
                            .foregroundColor(.secondary)
                    }
                }

                Section {
                    Button {
                        let interval = (mode == .current)
                        ? defaultRange
                        : DateInterval(start: min(start, end), end: max(start, end))

                        let csv = buildCSV(interval)
                        let filename = makeFilename(for: interval)

                        do {
                            shareURL = try writeTempCSV(filename: filename, csv: csv)
                            showShare = true
                        } catch {
                        }
                    } label: {
                        Text("שיתוף קובץ CSV")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .disabled(mode == .custom &&
                              Calendar.current.startOfDay(for: start) > Calendar.current.startOfDay(for: end))
                }
            }
            .navigationTitle("ייצוא")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("סגור") { dismiss() }
                }
            }
            .sheet(isPresented: $showShare) {
                if let shareURL {
                    ShareSheet(items: [shareURL])
                }
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .environment(\.locale, Locale(identifier: "he_IL"))
    }

    private func pretty(_ r: DateInterval) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "he_IL")
        df.dateStyle = .medium
        return "\(df.string(from: r.start)) – \(df.string(from: r.end))"
    }

    private func makeFilename(for r: DateInterval) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return "income-\(f.string(from: r.start))_to_\(f.string(from: r.end))"
        // no .csv here — writeTempCSV adds it
    }
}
// MARK: - CSV FileDocument
 struct CSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }

    var csv: String

    init(csv: String) { self.csv = csv }

    init(configuration: ReadConfiguration) throws {
        let data = configuration.file.regularFileContents ?? Data()
        self.csv = String(data: data, encoding: .utf8) ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(csv.utf8))
    }
}

func writeTempCSV(filename: String, csv: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
    let url = dir.appendingPathComponent(filename).appendingPathExtension("csv")
    try csv.data(using: .utf8)?.write(to: url, options: .atomic)
    return url
}
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
