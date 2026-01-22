import SwiftUI

struct ReductionsDetailView: View {
    let reports: [ZReportDashboard]
    let liveToday: ZReportsSinceResponseDashboard.TodayLive?
    let accent: Color
    
    // ✅ Precomputed reductions per day (fast)
    private let reductionsAggByDay: [String: ReductionsAgg]
    private let miniId: Int
    private let newestSignature: String

    // Persisted UI state
    @AppStorage("dash.range.reductions.v1") private var rangeRaw: String = DashRange.w.rawValue
    @AppStorage("dash.reductions.focusTs.v1") private var focusTs: Double = 0

    // Cursor + plot geometry (same pattern)
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

    // Keep these reasonable for performance (like you did elsewhere)
    private static let dayPages = 60     // last ~60 days
    private static let weekPages = 26    // ~6 months of weeks

    // MARK: - Models

    private struct ReductionsAgg: Codable {
        var discounts: Double = 0
        var cancellations: Double = 0
        var other: Double = 0
        var team: Double = 0          // ✅ NEW

        var total: Double { discounts + cancellations + other + team } // ✅ include team

        mutating func add(_ o: ReductionsAgg) {
            discounts += o.discounts
            cancellations += o.cancellations
            other += o.other
            team += o.team            // ✅ NEW
        }
    }

    private struct ChartPoint: Identifiable {
        let id = UUID()
        var label: String
        var value: Double
    }
    
    // MARK: - Build reductions agg cache (per day)
    private static func buildReductionsAggByDay(
        reports: [ZReportDashboard],
        calendar: Calendar
    ) -> [String: ReductionsAgg] {

        var out: [String: ReductionsAgg] = [:]
        out.reserveCapacity(min(reports.count, 1200))

        for r in reports {
            // parse day from RangeFrom
            guard let d = ZDateUtil.parseDate(r.rangeFrom) else { continue }
            let key = ZDateUtil.dayKey(d, cal: calendar)

            // decode reductions from JsonData
            let agg = reductionsFromJsonStatic(r.jsonData)

            // add
            var cur = out[key] ?? ReductionsAgg()
            cur.discounts += agg.discounts
            cur.cancellations += agg.cancellations
            cur.other += agg.other
            out[key] = cur
        }

        return out
    }

    // Static JSON decode helper (so buildReductionsAggByDay can call it)
    private static func reductionsFromJsonStatic(_ json: String?) -> ReductionsAgg {
        guard let s = json, !s.isEmpty,
              let data = s.data(using: String.Encoding.utf8)
        else { return ReductionsAgg() }

        do {
            let payload = try JSONDecoder().decode(ZReportReductionsPayload.self, from: data)
            return ReductionsAgg(
                discounts: payload.reductions?.discounts ?? 0,
                cancellations: payload.reductions?.cancellations ?? 0,
                other: payload.reductions?.other ?? 0
            )
        } catch {
            return ReductionsAgg()
        }
    }

    private struct ZReportReductionsPayload: Decodable {
        let reductions: Reductions?

        struct Reductions: Decodable {
            let discounts: Double?
            let cancellations: Double?
            let other: Double?
        }
    }

    private static func cacheDataKey(miniId: Int) -> String { "dash.reductions.byDay.v1.\(miniId)" }
    private static func cacheSigKey(miniId: Int)  -> String { "dash.reductions.byDay.sig.v1.\(miniId)" }

    private static func loadReductionsCache(miniId: Int, signature: String) -> [String: ReductionsAgg]? {
        guard miniId > 0 else { return nil }
        let ud = UserDefaults.standard
        guard ud.string(forKey: cacheSigKey(miniId: miniId)) == signature else { return nil }
        guard let data = ud.data(forKey: cacheDataKey(miniId: miniId)) else { return nil }
        return try? JSONDecoder().decode([String: ReductionsAgg].self, from: data)
    }

    private static func saveReductionsCache(miniId: Int, signature: String, map: [String: ReductionsAgg]) {
        guard miniId > 0 else { return }
        let ud = UserDefaults.standard
        if let data = try? JSONEncoder().encode(map) {
            ud.set(signature, forKey: cacheSigKey(miniId: miniId))
            ud.set(data, forKey: cacheDataKey(miniId: miniId))
        }
    }
    // MARK: - Formatters (Hebrew)

    init(
        reports: [ZReportDashboard],
        liveToday: ZReportsSinceResponseDashboard.TodayLive?,
        accent: Color
    ) {
        self.reports = reports
        self.liveToday = liveToday
        self.accent = accent

        let mid = reports.first?.miniAppId ?? 0
        self.miniId = mid

        if let last = reports.max(by: { $0.id < $1.id }) {
            self.newestSignature = "\(last.id)|\(last.rangeFrom)"
        } else {
            self.newestSignature = "empty"
        }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Jerusalem") ?? .current

        if let cached = Self.loadReductionsCache(miniId: mid, signature: self.newestSignature) {
            self.reductionsAggByDay = cached
        } else {
            let built = Self.buildReductionsAggByDay(
                reports: reports,
                calendar: cal
            )

            self.reductionsAggByDay = built
            Self.saveReductionsCache(miniId: mid, signature: self.newestSignature, map: built)
        }
    }
    
    private enum Fmt {
        static let yyyyMMdd: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "Asia/Jerusalem")
            f.dateFormat = "yyyy-MM-dd"
            return f
        }()

        static let hebDayMonthYear: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "he_IL")
            f.timeZone = TimeZone(identifier: "Asia/Jerusalem")
            f.dateFormat = "d MMMM yyyy" // 7 דצמבר 2025
            return f
        }()

        static let hebMonthYear: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "he_IL")
            f.timeZone = TimeZone(identifier: "Asia/Jerusalem")
            f.dateFormat = "MMMM yyyy"   // דצמבר 2025
            return f
        }()

        static let hebMonthShort: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "he_IL")
            f.timeZone = TimeZone(identifier: "Asia/Jerusalem")
            f.dateFormat = "MMM"         // דצמ׳
            return f
        }()
    }

    private func weekdayHebrewLetter(_ d: Date) -> String {
        // Sunday = 1
        switch calendar.component(.weekday, from: d) {
        case 1: return "א׳"
        case 2: return "ב׳"
        case 3: return "ג׳"
        case 4: return "ד׳"
        case 5: return "ה׳"
        case 6: return "ו׳"
        case 7: return "ש׳"
        default: return ""
        }
    }

    // MARK: - Parsing reductions from JsonData

    private func reductionsFromJson(_ json: String?) -> ReductionsAgg {
        guard let s = json, !s.isEmpty, let data = s.data(using: .utf8) else { return .init() }
        do {
            let p = try JSONDecoder().decode(ZReportReductionsPayload.self, from: data)
            return ReductionsAgg(
                discounts: p.reductions?.discounts ?? 0,
                cancellations: p.reductions?.cancellations ?? 0,
                other: p.reductions?.other ?? 0
            )
        } catch {
            return .init()
        }
    }

    // MARK: - Date parsing helpers (RangeFrom)

    private func parseReportDay(_ r: ZReportDashboard) -> Date? {
        // full ISO + fractional
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: r.rangeFrom) { return d }

        // ISO without fractional
        let iso2 = ISO8601DateFormatter()
        iso2.formatOptions = [.withInternetDateTime]
        if let d = iso2.date(from: r.rangeFrom) { return d }

        // fallback yyyy-MM-dd
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: String(r.rangeFrom.prefix(10)))
    }

    private func dayKey(_ d: Date) -> String {
        Fmt.yyyyMMdd.string(from: calendar.startOfDay(for: d))
    }

    // Precompute per-day reductions once (fast lookups)
    private func liveReductionsAgg() -> ReductionsAgg {
        ReductionsAgg(
            discounts: liveToday?.discounts ?? 0,
            cancellations: liveToday?.cancellations ?? 0,
            other: liveToday?.other ?? 0,
            team: liveToday?.teamTotal ?? 0        // ✅ NEW
        )
    }
    
    private func hourlyReductionsTotalForToday08to17() -> [Double] {
        guard let buckets = liveToday?.hourly?.buckets else {
            return Array(repeating: 0, count: 10)
        }

        var byHour: [Int: Double] = [:]
        for b in buckets {
            let v = (b.discounts ?? 0) + (b.cancellations ?? 0) + (b.other ?? 0)
            byHour[b.h, default: 0] += v
        }

        return Array(8...17).map { byHour[$0] ?? 0 }
    }

    private func activeDayForTeam() -> Date {
        // If no bar selected → use focusDate
        guard let i = selectedBarIndex else { return calendar.startOfDay(for: focusDate) }

        switch range {
        case .d:
            return calendar.startOfDay(for: focusDate)

        case .w:
            let end = weekEndForWeekPage(pageIndex)
            return calendar.startOfDay(for: dateForWeekIndex(i, weekEnd: end))

        case .m:
            return calendar.startOfDay(for: dateForMonthIndex(i))

        case .m6:
            return calendar.startOfDay(for: monthStartFor6mIndex(i))

        case .y:
            return calendar.startOfDay(for: monthStartForYearIndex(i))
        }
    }

    private func activeTeamTables() -> (managers: Double, kitchen: Double, patisserie: Double, floor: Double) {
        let d = activeDayForTeam()

        // ✅ only today has team split (from /since today.team)
        guard calendar.isDate(d, inSameDayAs: today),
              let t = liveToday?.team
        else {
            return (0, 0, 0, 0)
        }

        let m = t.managers ?? 0
        let k = t.kitchen ?? 0
        let p = t.patisserie ?? 0
        let f = t.floor ?? 0
        return (m, k, p, f)
    }

    private var activeTeamTotal: Double {
        let t = activeTeamTables()
        return t.managers + t.kitchen + t.patisserie + t.floor
    }
    private func reductionsForDay(_ d: Date) -> ReductionsAgg {
        let day = calendar.startOfDay(for: d)

        // ✅ TODAY uses liveToday (because it's not in ZReports)
        if calendar.isDate(day, inSameDayAs: today) {
            return liveReductionsAgg()
        }

        return reductionsAggByDay[dayKey(day)] ?? .init()
    }
    
    

    private func reductionsForInterval(_ interval: DateInterval) -> ReductionsAgg {
        let s = calendar.startOfDay(for: interval.start)
        let e = calendar.startOfDay(for: interval.end)

        var total = ReductionsAgg()
        var d = s
        while d < e {
            total.add(reductionsForDay(d))
            d = calendar.date(byAdding: .day, value: 1, to: d) ?? e
        }
        return total
    }

    // MARK: - Paging helpers

    private func setFocusDay(_ d: Date) {
        let dd = calendar.startOfDay(for: d)
        focusDate = dd
        focusTs = dd.timeIntervalSince1970
    }

    private func clearSelection() {
        selectedBarIndex = nil
        selectedBarX = nil
    }

    private func dayForDayPage(_ p: Int) -> Date {
        let newest = today
        let offsetFromNewest = (Self.dayPages - 1) - p
        return calendar.date(byAdding: .day, value: -offsetFromNewest, to: newest) ?? newest
    }

    private func pageIndexForFocusInDayPager() -> Int {
        let diff = calendar.dateComponents([.day], from: focusDate, to: today).day ?? 0
        let idx = (Self.dayPages - 1) - max(0, diff)
        return min(max(idx, 0), Self.dayPages - 1)
    }

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
        return min(max(idx, 0), Self.weekPages - 1)
    }

    private func startOfMonth(_ d: Date) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: d)) ?? d
    }

    private var monthEnd: Date { calendar.startOfDay(for: monthAnchorEndDate) }
    private var monthStart: Date { calendar.date(byAdding: .day, value: -29, to: monthEnd) ?? monthEnd }
    private func dateForMonthIndex(_ i: Int) -> Date {
        calendar.date(byAdding: .day, value: i, to: monthStart) ?? monthStart
    }

    private func monthStartFor6mIndex(_ i: Int) -> Date {
        let endMonth = startOfMonth(today)
        return calendar.date(byAdding: .month, value: -(5 - i), to: endMonth) ?? endMonth
    }

    private func monthStartForYearIndex(_ i: Int) -> Date {
        let endMonth = startOfMonth(today)
        return calendar.date(byAdding: .month, value: -(11 - i), to: endMonth) ?? endMonth
    }

    // MARK: - Window (REAL reductions totals)

    private func makeWindow() -> [ChartPoint] {
        switch range {
        case .d:
            let hours = Array(8...17).map { String(format: "%02d", $0) }

            // ✅ TODAY: use live hourly reductions
            if calendar.isDate(focusDate, inSameDayAs: today) {
                let vals = hourlyReductionsTotalForToday08to17()
                return zip(hours, vals).map { ChartPoint(label: $0.0, value: $0.1) }
            }

            // ✅ past days: no hourly reductions yet
            return hours.map { ChartPoint(label: $0, value: 0) }

        case .w:
            let end = weekEndForWeekPage(pageIndex)
            return (0..<7).map { i in
                let d = dateForWeekIndex(i, weekEnd: end)
                let lbl = weekdayHebrewLetter(d)
                return ChartPoint(label: lbl, value: reductionsForDay(d).total)
            }

        case .m:
            return (0..<30).map { i in
                let d = dateForMonthIndex(i)
                let dayNum = calendar.component(.day, from: d)
                return ChartPoint(label: "\(dayNum)", value: reductionsForDay(d).total)
            }

        case .m6:
            return (0..<6).map { i in
                let m0 = monthStartFor6mIndex(i)
                let m1 = calendar.date(byAdding: .month, value: 1, to: m0) ?? m0
                let v = reductionsForInterval(DateInterval(start: m0, end: m1)).total
                return ChartPoint(label: Fmt.hebMonthShort.string(from: m0), value: v)
            }

        case .y:
            return (0..<12).map { i in
                let m0 = monthStartForYearIndex(i)
                let m1 = calendar.date(byAdding: .month, value: 1, to: m0) ?? m0
                let v = reductionsForInterval(DateInterval(start: m0, end: m1)).total
                // numeric month label is fine in Hebrew UI
                return ChartPoint(label: "\(calendar.component(.month, from: m0))", value: v)
            }
        }
    }

    private var window: [ChartPoint] { makeWindow() }

    // MARK: - Header / tooltip text

    private func number(_ value: Double) -> String {
        Int(value.rounded()).formatted(.number.grouping(.automatic))
    }

    private func compactHebrewRange(start: Date, end: Date) -> String {
        let sameMonth = calendar.component(.month, from: start) == calendar.component(.month, from: end)
        let sameYear  = calendar.component(.year, from: start) == calendar.component(.year, from: end)

        if sameMonth && sameYear {
            // "7–13 דצמבר 2025"
            let d1 = calendar.component(.day, from: start)
            let d2 = calendar.component(.day, from: end)
            let monthYear = Fmt.hebMonthYear.string(from: end)
            return "\(d1)–\(d2) \(monthYear)"
        } else {
            return "\(Fmt.hebDayMonthYear.string(from: start)) – \(Fmt.hebDayMonthYear.string(from: end))"
        }
    }

    private func sixMonthRangeTextHeb() -> String {
        let start = monthStartFor6mIndex(0)
        let end = monthStartFor6mIndex(5)
        let sameYear = calendar.component(.year, from: start) == calendar.component(.year, from: end)
        if sameYear {
            return "\(Fmt.hebMonthShort.string(from: start))–\(Fmt.hebMonthShort.string(from: end)) \(calendar.component(.year, from: end))"
        }
        return "\(Fmt.hebMonthYear.string(from: start)) – \(Fmt.hebMonthYear.string(from: end))"
    }

    private var headerLabel: String {
        switch range {
        case .d, .w, .m, .m6, .y:
            return "סה״כ"
        }
    }
    struct LiveHourBucket: Decodable, Identifiable {
        var id: Int { h }

        let h: Int
        let gross: Double
        let orders: Int
        let cash: Double
        let card: Double
        let tips: Double

        // ✅ NEW
        let discounts: Double?
        let cancellations: Double?
        let other: Double?

        enum CodingKeys: String, CodingKey {
            case h, gross, orders, cash, card, tips
            case discounts, cancellations, other
        }
    }
    
    private var headerValue: Double {
        guard !window.isEmpty else { return 0 }
        switch range {
        case .d:
            return reductionsForDay(focusDate).total

        case .w, .m:
            return window.map(\.value).reduce(0, +)

        case .m6, .y:
            return window.last?.value ?? 0
        }
    }

    private var periodText: String {
        switch range {
        case .d:
            let f = calendar.startOfDay(for: focusDate)
            if f == today { return "היום" }
            if f == (calendar.date(byAdding: .day, value: -1, to: today) ?? today) { return "אתמול" }
            return Fmt.hebDayMonthYear.string(from: focusDate)

        case .w:
            if selectedBarIndex != nil { return Fmt.hebDayMonthYear.string(from: focusDate) }
            let end = weekEndForWeekPage(pageIndex)
            let start = weekStart(forEnd: end)
            return compactHebrewRange(start: start, end: end)

        case .m:
            if selectedBarIndex != nil { return Fmt.hebDayMonthYear.string(from: focusDate) }
            return "\(Fmt.hebDayMonthYear.string(from: monthStart)) – \(Fmt.hebDayMonthYear.string(from: monthEnd))"

        case .m6:
            if let i = selectedBarIndex {
                let m0 = monthStartFor6mIndex(i)
                return Fmt.hebMonthYear.string(from: m0)
            }
            return sixMonthRangeTextHeb()

        case .y:
            if let i = selectedBarIndex {
                let m0 = monthStartForYearIndex(i)
                return Fmt.hebMonthYear.string(from: m0)
            }
            let start = monthStartForYearIndex(0)
            let end = monthStartForYearIndex(11)
            return "\(Fmt.hebMonthYear.string(from: start)) – \(Fmt.hebMonthYear.string(from: end))"
        }
    }

    private func tooltipSubtitle(for i: Int) -> String {
        guard window.indices.contains(i) else { return periodText }

        switch range {
        case .d:
            let h0 = Int(window[i].label) ?? 0
            let h1 = (h0 + 1) % 24
            return "\(periodText) \(String(format: "%02d", h0))–\(String(format: "%02d", h1))"

        case .w:
            let end = weekEndForWeekPage(pageIndex)
            let d = dateForWeekIndex(i, weekEnd: end)
            return "\(weekdayHebrewLetter(d)) \(Fmt.hebDayMonthYear.string(from: d))"

        case .m:
            return Fmt.hebDayMonthYear.string(from: dateForMonthIndex(i))

        case .m6:
            return Fmt.hebMonthYear.string(from: monthStartFor6mIndex(i))

        case .y:
            return Fmt.hebMonthYear.string(from: monthStartForYearIndex(i))
        }
    }

    private var selectedValue: Double? {
        guard let i = selectedBarIndex, window.indices.contains(i) else { return nil }
        return window[i].value
    }
    private var activeValue: Double { selectedValue ?? headerValue }

    private var activeBreakdown: ReductionsAgg {
        // When a bar is selected, show that bar’s true breakdown where possible:
        // - W/M: that day
        // - M6/Y: that month interval
        // - D: day-level only (no hourly breakdown)
        guard let i = selectedBarIndex else {
            // whole view range
            return reductionsForInterval(currentInterval())
        }

        switch range {
        case .d:
            return reductionsForDay(focusDate)

        case .w:
            let end = weekEndForWeekPage(pageIndex)
            let d = dateForWeekIndex(i, weekEnd: end)
            return reductionsForDay(d)

        case .m:
            let d = dateForMonthIndex(i)
            return reductionsForDay(d)

        case .m6:
            let m0 = monthStartFor6mIndex(i)
            let m1 = calendar.date(byAdding: .month, value: 1, to: m0) ?? m0
            return reductionsForInterval(DateInterval(start: m0, end: m1))

        case .y:
            let m0 = monthStartForYearIndex(i)
            let m1 = calendar.date(byAdding: .month, value: 1, to: m0) ?? m0
            return reductionsForInterval(DateInterval(start: m0, end: m1))
        }
    }

    private func currentInterval() -> DateInterval {
        let endDay = calendar.startOfDay(for: focusDate)

        switch range {
        case .d:
            let start = endDay
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
            return DateInterval(start: start, end: end)

        case .w:
            let end = weekEndForWeekPage(pageIndex)
            let start = weekStart(forEnd: end)
            let e = calendar.date(byAdding: .day, value: 1, to: end) ?? end
            return DateInterval(start: start, end: e)

        case .m:
            let e = calendar.date(byAdding: .day, value: 1, to: monthEnd) ?? monthEnd
            return DateInterval(start: monthStart, end: e)

        case .m6:
            let start = monthStartFor6mIndex(0)
            let endM = calendar.date(byAdding: .month, value: 1, to: monthStartFor6mIndex(5)) ?? monthStartFor6mIndex(5)
            return DateInterval(start: start, end: endM)

        case .y:
            let start = monthStartForYearIndex(0)
            let endM = calendar.date(byAdding: .month, value: 1, to: monthStartForYearIndex(11)) ?? monthStartForYearIndex(11)
            return DateInterval(start: start, end: endM)
        }
    }

    // MARK: - UI Cards

    private func reductionRow(_ title: String, _ value: Double) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.secondary)

            Spacer()

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(number(value))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)

                Text("₪")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 10)
    }

    private var breakdownCard: some View {
        let a = activeBreakdown
        return VStack(spacing: 0) {
            reductionRow("ביטולים", a.cancellations)
            Divider().opacity(0.4)
            reductionRow("הנחות", a.discounts)
            Divider().opacity(0.4)
            reductionRow("על חשבון הבית", a.other)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private var headerOrTooltip: some View {
        ZStack(alignment: .topLeading) {

            VStack(alignment: .leading, spacing: 6) {
                Text(headerLabel)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(number(activeValue))
                        .font(.system(size: 44, weight: .bold))
                        .foregroundColor(.primary)

                    Text("₪")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)

                Text(periodText)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .opacity(selectedBarIndex == nil ? 1 : 0)

            if let idx = selectedBarIndex,
               let x = selectedBarX,
               window.indices.contains(idx) {

                GeometryReader { geo in
                    let tooltipW: CGFloat = 210
                    let clampedX = min(max(x - tooltipW / 2, 0), max(0, geo.size.width - tooltipW))

                    VStack(alignment: .leading, spacing: 6) {
                        Text(headerLabel)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.secondary)

                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(number(window[idx].value))
                                .font(.system(size: 34, weight: .bold))
                            Text("₪")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.secondary)
                        }

                        Text(tooltipSubtitle(for: idx))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                    .padding(10)
                    .frame(width: tooltipW, alignment: .leading)
                    .background(Color(UIColor.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .offset(x: clampedX, y: 0)
                }
            }
        }
        .frame(height: 92)
    }

    private func rollingWeekLabels(endingAt endDate: Date) -> [String] {
        let end = calendar.startOfDay(for: endDate)
        return (0..<7).map { i in
            let d = calendar.date(byAdding: .day, value: i - 6, to: end) ?? end
            return weekdayHebrewLetter(d)
        }
    }

    private func monthXAxisLabels(for window: [ChartPoint]) -> [String] {
        // show weekly ticks only
        window.indices.map { i in (i % 7 == 0) ? window[i].label : "" }
    }

    private var chart: some View {
        Group {
            if range == .d || range == .w {

                let pageCount = (range == .d) ? Self.dayPages : Self.weekPages

                TabView(selection: $pageIndex) {
                    ForEach(0..<pageCount, id: \.self) { p in
                        let w: [ChartPoint] = {
                            if range == .d {
                                let day = calendar.startOfDay(for: dayForDayPage(p))
                                let hours = Array(8...17).map { String(format: "%02d", $0) }

                                // ✅ TODAY → live hourly reductions (08–17)
                                if calendar.isDate(day, inSameDayAs: today) {
                                    let vals = hourlyReductionsTotalForToday08to17()
                                    return zip(hours, vals).map { ChartPoint(label: $0.0, value: $0.1) }
                                }

                                // ✅ Past days → no hourly reductions yet
                                return hours.map { ChartPoint(label: $0, value: 0) }
                            } else {
                                let end = weekEndForWeekPage(p)
                                let labels = rollingWeekLabels(endingAt: end)
                                return (0..<7).map { i in
                                    let d = dateForWeekIndex(i, weekEnd: end)
                                    return ChartPoint(label: labels[i], value: reductionsForDay(d).total)
                                }
                            }
                        }()

                        HealthBarChart(
                            values: w.map(\.value),
                            accent: accent,
                            xLabels: w.map(\.label),
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
                    cursorActive = false
                    if range == .d {
                        setFocusDay(dayForDayPage(pageIndex))
                    } else {
                        setFocusDay(weekEndForWeekPage(pageIndex))
                    }
                }

            } else {
                HealthBarChart(
                    values: window.map(\.value),
                    accent: accent,
                    xLabels: (range == .m) ? monthXAxisLabels(for: window) : window.map(\.label),
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
    }

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

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {

                Picker("", selection: $range) {
                    ForEach(DashRange.allCases) { r in
                        Text(r.title).tag(r)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.top, 10)
                .onChange(of: range) {  newRange in
                    clearSelection()
                    cursorActive = false
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
                breakdownCard
                teamCard
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
                    let m0 = monthStartFor6mIndex(i)
                    setFocusDay(m0)
                case .y:
                    let m0 = monthStartForYearIndex(i)
                    setFocusDay(m0)
                case .d:
                    break
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 18)
        }
        .overlay { cursorOverlay }
        .background(Color(UIColor.systemGroupedBackground))
        .navigationTitle("הפחתות")
        .navigationBarTitleDisplayMode(.inline)
        .tint(accent)
        .onAppear {
            range = DashRange(rawValue: rangeRaw) ?? .w

            setFocusDay(today)        // ✅ always start at today for reductions
            focusTs = 0               // ✅ optional: clear persisted focus so it won’t drift again

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
            cursorActive = false
        }
    }
    private func teamRow(_ title: String, _ value: Double) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.secondary)

            Spacer()

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(number(value))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)

                Text("₪")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 10)
    }

    private var teamCard: some View {
        let t = activeTeamTables()
        let total = activeTeamTotal

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "person.3.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.blue)

                Text("שולחנות צוות")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.blue)

                Spacer()

                // optional: show total on the right
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(number(total))
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.primary)
                    Text("₪")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                }
            }

            VStack(spacing: 0) {
                teamRow("שולחן מנהלים", t.managers)
                Divider().opacity(0.4)
                teamRow("שולחן מטבח", t.kitchen)
                Divider().opacity(0.4)
                teamRow("שולחן קונדיטוריה", t.patisserie)
                Divider().opacity(0.4)
                teamRow("שולחן פלור", t.floor)
            }
        }
        .padding(14)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }
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
}


private struct ReductionsRangeAgg {
    var discounts: Double = 0
    var cancellations: Double = 0
    var other: Double = 0

    // ✅ NEW
    var teamTotal: Double = 0

    var total: Double { discounts + cancellations + other } // keep as-is (or include team if you want)
}
