import SwiftUI

struct BottomLineDetailView: View {
    let reports: [ZReportDashboard]
    let liveToday: ZReportsSinceResponseDashboard.TodayLive?
    let accent: Color

    // Persisted UI state
    @AppStorage("dash.range.income.v1") private var rangeRaw: String = DashRange.w.rawValue
    @AppStorage("dash.income.focusTs.v1") private var focusTs: Double = 0
    @State private var showExportSheet = false
    // Local UI
    @State private var range: DashRange = .w
    @State private var focusDate: Date = Date()
    @State private var pageIndex: Int = 0
    @State private var monthAnchorEndDate: Date = Date()
    @State private var cachedReportsByDay: [String: [ZReportDashboard]] = [:]
    // Tooltip selection
    @State private var selectedBarIndex: Int? = nil
    @State private var selectedBarX: CGFloat? = nil

    // Share
    @State private var showShare = false
    @State private var shareURL: URL?

    // ✅ Precomputed daily aggregates (fast lookups)
    private let dailyAgg: [String: Agg]
    private let miniId: Int
    private let newestSignature: String

    
    // MARK: - Calendar (single TZ)
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Jerusalem") ?? .current
        return c
    }
    private var today: Date { calendar.startOfDay(for: Date()) }

    // MARK: - Paging config (keep small for performance)
    private static let dayPages = 10
    private static let weekPages = 4

    private struct ZReportDashboardPayload: Decodable {
        let hourly: HourlyValue?

        enum HourlyValue: Decodable {
            case object(HourlyBlock)
            case string(String)

            init(from decoder: Decoder) throws {
                // try object first
                if let obj = try? HourlyBlock(from: decoder) {
                    self = .object(obj)
                    return
                }
                // then string
                let c = try decoder.singleValueContainer()
                self = .string(try c.decode(String.self))
            }
        }
    }
    
    private var liveAggToday: Agg? {
        guard let t = liveToday else { return nil }
        var a = Agg()
        // ✅ PAID ONLY (and team tables don't matter because unpaid has cash/card = 0)
        a.gross = (t.cash + t.card)
        a.net = t.net
        a.vat = t.vat
        a.tips = t.tips
        a.cash = t.cash
        a.card = t.card
        a.orders = t.orders
        a.missing = t.missingPaymentCount
        a.openOrders = t.openOrders ?? 0
        return a
    }
    
    private func buildReportsByDayCache() -> [String: [ZReportDashboard]] {
        var out: [String: [ZReportDashboard]] = [:]
        out.reserveCapacity(min(reports.count, 1200))

        for r in reports {
            guard let d = ZDateUtil.parseDate(r.rangeFrom) else { continue }
            let k = ZDateUtil.dayKey(d, cal: calendar)
            out[k, default: []].append(r)
        }
        return out
    }

    private struct HourBucket: Decodable {
        let h: Int
        let gross: Double
        let orders: Int?
        let cash: Double?
        let card: Double?
        let tips: Double?
    }

    private struct HourlyBlock: Decodable {
        let tz: String?
        let buckets: [HourBucket]
    }

  
    
    private func hourlyBuckets(from report: ZReportDashboard) -> [HourBucket] {
        guard let s = report.jsonData, !s.isEmpty else { return [] }
        guard let data = s.data(using: .utf8) else { return [] }

        do {
            let payload = try JSONDecoder().decode(ZReportDashboardPayload.self, from: data)
            guard let hourly = payload.hourly else { return [] }

            switch hourly {
            case .object(let block):
                return block.buckets

            case .string(let raw):
                guard let data2 = raw.data(using: .utf8) else { return [] }
                return (try? JSONDecoder().decode(HourlyBlock.self, from: data2))?.buckets ?? []
            }

        } catch {
            return []
        }
    }
    
    // MARK: - Init (build cache once)
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

        if let cached = Self.loadDailyAggCache(miniId: mid, signature: self.newestSignature) {
            self.dailyAgg = cached
        } else {
            let built = Self.buildDailyAgg(reports: reports, cal: cal)
            self.dailyAgg = built
            Self.saveDailyAggCache(miniId: mid, signature: self.newestSignature, dailyAgg: built)
        }
    }

    // MARK: - Agg model (codable for UserDefaults)
    private struct Agg: Codable {
        var gross: Double = 0
        var net: Double = 0
        var vat: Double = 0
        var tips: Double = 0
        var cash: Double = 0
        var card: Double = 0
        var orders: Int = 0
        var missing: Int = 0
        var openOrders: Int = 0
        
        init() {}

        init(_ rs: [ZReportDashboard]) {
            for r in rs {
                // ✅ PAID ONLY
                gross += (r.cashTotal + r.cardTotal)

                // keep breakdowns (still useful for the detail card)
                net += r.netTotal
                vat += r.vatTotal
                tips += r.tipsTotal
                cash += r.cashTotal
                card += r.cardTotal
                orders += r.ordersCount
                missing += r.missingPaymentCount
            }
        }

        mutating func add(_ other: Agg) {
            gross += other.gross
            net += other.net
            vat += other.vat
            tips += other.tips
            cash += other.cash
            card += other.card
            orders += other.orders
            missing += other.missing
            openOrders += other.openOrders
        }
    }

    // MARK: - Cached formatters (no allocations)
    private enum Fmt {
        static let weekdayHebrewNumber: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "he_IL")
            f.timeZone = TimeZone(identifier: "Asia/Jerusalem")
            f.dateFormat = "c"   // weekday number 1–7
            return f
        }()

        static func hebrewWeekdayLetter(from date: Date) -> String {
            let n = Int(weekdayHebrewNumber.string(from: date)) ?? 1
            // 1=Sunday … 7=Saturday
            return ["א", "ב", "ג", "ד", "ה", "ו", "ש"][max(0, min(6, n - 1))]
        }
        // keys
        static let yyyyMMdd: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "Asia/Jerusalem")
            f.dateFormat = "yyyy-MM-dd"
            return f
        }()

        // date labels
        static let dayMonthYear: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "he_IL")
            f.timeZone = TimeZone(identifier: "Asia/Jerusalem")
            f.dateFormat = "d MMMM yyyy"          // 7 דצמ׳ 2025
            return f
        }()

        static let weekdayEEE: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "he_IL")
            f.timeZone = TimeZone(identifier: "Asia/Jerusalem")
            f.dateFormat = "EEE"                 // א׳ ב׳ ג׳ ...
            return f
        }()

        static let monthShort: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "he_IL")
            f.timeZone = TimeZone(identifier: "Asia/Jerusalem")
            f.dateFormat = "MMMM"                 // דצמ׳
            return f
        }()

        static let monthYear: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "he_IL")
            f.timeZone = TimeZone(identifier: "Asia/Jerusalem")
            f.dateFormat = "MMMM yyyy"            // דצמ׳ 2025
            return f
        }()

        // for “7–13 דצמבר 2025”
        static let dayOnly: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "he_IL")
            f.timeZone = TimeZone(identifier: "Asia/Jerusalem")
            f.dateFormat = "d"
            return f
        }()

        static let monthYearHebrew: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "he_IL")
            f.timeZone = TimeZone(identifier: "Asia/Jerusalem")
            f.dateFormat = "MMMM yyyy"           // דצמבר 2025
            return f
        }()
    }

   
    // MARK: - Cache keys
    private static func cacheDataKey(miniId: Int) -> String { "dash.income.dailyAgg.v1.\(miniId)" }
    private static func cacheSigKey(miniId: Int)  -> String { "dash.income.dailyAgg.sig.v1.\(miniId)" }

    private static func loadDailyAggCache(miniId: Int, signature: String) -> [String: Agg]? {
        guard miniId > 0 else { return nil }
        let ud = UserDefaults.standard
        let sigKey = cacheSigKey(miniId: miniId)
        let dataKey = cacheDataKey(miniId: miniId)

        guard ud.string(forKey: sigKey) == signature else { return nil }
        guard let data = ud.data(forKey: dataKey) else { return nil }

        return try? JSONDecoder().decode([String: Agg].self, from: data)
    }

    private static func saveDailyAggCache(miniId: Int, signature: String, dailyAgg: [String: Agg]) {
        guard miniId > 0 else { return }
        let ud = UserDefaults.standard
        let sigKey = cacheSigKey(miniId: miniId)
        let dataKey = cacheDataKey(miniId: miniId)

        if let data = try? JSONEncoder().encode(dailyAgg) {
            ud.set(signature, forKey: sigKey)
            ud.set(data, forKey: dataKey)
        }
    }

    private static func buildDailyAgg(reports: [ZReportDashboard], cal: Calendar) -> [String: Agg] {
        var tmp: [String: [ZReportDashboard]] = [:]
        tmp.reserveCapacity(min(reports.count, 1200))

        for r in reports {
            guard let d = ZDateUtil.parseDate(r.rangeFrom) else { continue }
            let key = ZDateUtil.dayKey(d, cal: cal)
            tmp[key, default: []].append(r)
        }

        var out: [String: Agg] = [:]
        out.reserveCapacity(tmp.count)
        for (k, rs) in tmp {
            out[k] = Agg(rs)
        }
        return out
    }

    // MARK: - Fast day / interval sums
    private func dayKey(_ d: Date) -> String {
        Fmt.yyyyMMdd.string(from: calendar.startOfDay(for: d))
    }

    private func sumForDay(_ d: Date) -> Agg {
        let day = calendar.startOfDay(for: d)

        // ✅ override with LIVE today (if present)
        if calendar.isDate(day, inSameDayAs: today),
           let live = liveAggToday {
            return live
        }

        // ✅ fallback to ZReports cache
        return dailyAgg[dayKey(day)] ?? Agg()
    }

    private func sumForInterval(_ interval: DateInterval) -> Agg {
        let s = calendar.startOfDay(for: interval.start)
        let e = calendar.startOfDay(for: interval.end)

        var total = Agg()
        var d = s
        while d < e {
            total.add(sumForDay(d))
            d = calendar.date(byAdding: .day, value: 1, to: d) ?? e
        }
        return total
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
        return min(max(idx, 0), Self.dayPages - 1)
    }

    // MARK: - W paging
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

    // MARK: - Rolling month (anchored)
    private var monthEnd: Date { calendar.startOfDay(for: monthAnchorEndDate) }
    private var monthStart: Date { calendar.date(byAdding: .day, value: -29, to: monthEnd) ?? monthEnd }
    private func dateForMonthIndex(_ i: Int) -> Date {
        calendar.date(byAdding: .day, value: i, to: monthStart) ?? monthStart
    }

    // MARK: - Month helpers
    private func startOfMonth(_ d: Date) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: d)) ?? d
    }

    private func monthStartFor6mIndex(_ i: Int) -> Date {
        let endMonth = startOfMonth(today)
        return calendar.date(byAdding: .month, value: -(5 - i), to: endMonth) ?? endMonth
    }

    private func monthStartForYearIndex(_ i: Int) -> Date {
        let endMonth = startOfMonth(today)
        return calendar.date(byAdding: .month, value: -(11 - i), to: endMonth) ?? endMonth
    }

    // MARK: - Chart points
    private struct ChartPoint: Identifiable {
        let id = UUID()
        var label: String
        var value: Double
    }

    private func rollingWeekLabels(endingAt endDate: Date) -> [String] {
        let end = calendar.startOfDay(for: endDate)
        return (0..<7).map { i in
            let d = calendar.date(byAdding: .day, value: i - 6, to: end) ?? end
            return Fmt.hebrewWeekdayLetter(from: d)
        }
    }

    private func monthXAxisLabels(for window: [ChartPoint]) -> [String] {
        window.indices.map { i in (i % 7 == 0) ? window[i].label : "" }
    }

    // MARK: - Real window builder (FAST)
    private func makeWindow() -> [ChartPoint] {
        switch range {
        case .d:
            let day = dayForDayPage(pageIndex)
            let dayStart = calendar.startOfDay(for: day)

            // 1) If this day is today and we have live hourly -> use it
            if calendar.isDate(dayStart, inSameDayAs: today),
               let buckets = liveToday?.hourly?.buckets {

                var byHour: [Int: Double] = [:]
                for b in buckets {
                    let gross = b.gross ?? 0
                    byHour[b.h, default: 0] += gross
                }

                let hours = Array(8...17)
                return hours.map { h in
                    ChartPoint(label: String(format: "%02d", h), value: byHour[h] ?? 0)
                }
            }

            // 2) Otherwise use ZReport JsonData hourly for that day (cachedReportsByDay)
            let key = dayKey(dayStart)
            let rs = cachedReportsByDay[key] ?? []

            var byHour: [Int: Double] = [:]
            for r in rs {
                for b in hourlyBuckets(from: r) {
                    byHour[b.h, default: 0] += b.gross
                }
            }

            let hours = Array(8...17)
            return hours.map { h in
                ChartPoint(label: String(format: "%02d", h), value: byHour[h] ?? 0)
            }

        case .w:
            let end = weekEndForWeekPage(pageIndex)
            let labels = rollingWeekLabels(endingAt: end)
            return (0..<7).map { i in
                let d = dateForWeekIndex(i, weekEnd: end)
                return ChartPoint(label: labels[i], value: sumForDay(d).gross)
            }

        case .m:
            return (0..<30).map { i in
                let d = dateForMonthIndex(i)
                let dayNum = calendar.component(.day, from: d)
                return ChartPoint(label: "\(dayNum)", value: sumForDay(d).gross)
            }

        case .m6:
            return (0..<6).map { i in
                let m0 = monthStartFor6mIndex(i)
                let m1 = calendar.date(byAdding: .month, value: 1, to: m0) ?? m0
                let v = sumForInterval(DateInterval(start: m0, end: m1)).gross
                return ChartPoint(label: Fmt.monthShort.string(from: m0), value: v)
            }

        case .y:
            return (0..<12).map { i in
                let m0 = monthStartForYearIndex(i)
                let m1 = calendar.date(byAdding: .month, value: 1, to: m0) ?? m0
                let v = sumForInterval(DateInterval(start: m0, end: m1)).gross
                return ChartPoint(label: "\(calendar.component(.month, from: m0))", value: v)
            }
        }
    }

    private var window: [ChartPoint] { makeWindow() }

    // MARK: - Period interval for current view
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
            let endM  = calendar.date(byAdding: .month, value: 1, to: monthStartFor6mIndex(5)) ?? monthStartFor6mIndex(5)
            return DateInterval(start: start, end: endM)

        case .y:
            let start = monthStartForYearIndex(0)
            let endM  = calendar.date(byAdding: .month, value: 1, to: monthStartForYearIndex(11)) ?? monthStartForYearIndex(11)
            return DateInterval(start: start, end: endM)
        }
    }

    // MARK: - Header + period
    private var periodAgg: Agg {
        guard let i = selectedBarIndex, i >= 0, i < window.count else {
            return sumForInterval(currentInterval())
        }

        switch range {
        case .d:
            return sumForDay(focusDate)

        case .w:
            let end = weekEndForWeekPage(pageIndex)
            let d = dateForWeekIndex(i, weekEnd: end)
            return sumForDay(d)

        case .m:
            let d = dateForMonthIndex(i)
            return sumForDay(d)

        case .m6:
            let m0 = monthStartFor6mIndex(i)
            let m1 = calendar.date(byAdding: .month, value: 1, to: m0) ?? m0
            return sumForInterval(DateInterval(start: m0, end: m1))

        case .y:
            let m0 = monthStartForYearIndex(i)
            let m1 = calendar.date(byAdding: .month, value: 1, to: m0) ?? m0
            return sumForInterval(DateInterval(start: m0, end: m1))
        }
    }
    
    static let monthYearHebrew: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "he_IL")
        f.timeZone = TimeZone(identifier: "Asia/Jerusalem")
        f.dateFormat = "MMMM yyyy"   // דצמבר 2025
        return f
    }()
    
    static let dayOnly: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "he_IL")
        f.timeZone = TimeZone(identifier: "Asia/Jerusalem")
        f.dateFormat = "d"
        return f
    }()

    private var periodText: String {
        switch range {
        case .d:
            let f = calendar.startOfDay(for: focusDate)
            if f == today { return "היום" }
            if f == (calendar.date(byAdding: .day, value: -1, to: today) ?? today) { return "Yesterday" }
            return Fmt.dayMonthYear.string(from: focusDate)

        case .w:
            if selectedBarIndex != nil { return Fmt.dayMonthYear.string(from: focusDate) }
            let end = weekEndForWeekPage(pageIndex)
            let start = weekStart(forEnd: end)
            return compactRangeText(start: start, end: end)

        case .m:
            if selectedBarIndex != nil { return Fmt.dayMonthYear.string(from: focusDate) }
            return "\(Fmt.dayMonthYear.string(from: monthStart)) – \(Fmt.dayMonthYear.string(from: monthEnd))"

        case .m6:
            if let i = selectedBarIndex {
                let m0 = monthStartFor6mIndex(i)
                return Fmt.monthYear.string(from: m0)
            }
            return sixMonthRangeText()

        case .y:
            if let i = selectedBarIndex {
                let m0 = monthStartForYearIndex(i)
                return Fmt.monthYear.string(from: m0)
            }
            let start = monthStartForYearIndex(0)
            let end = monthStartForYearIndex(11)
            return "\(Fmt.monthYear.string(from: start)) – \(Fmt.monthYear.string(from: end))"
        }
    }

    private func compactRangeText(start: Date, end: Date) -> String {
        let sameMonth = calendar.component(.month, from: start) == calendar.component(.month, from: end)
        let sameYear  = calendar.component(.year,  from: start) == calendar.component(.year,  from: end)

        if sameMonth && sameYear {
            // 7–13 דצמבר 2025
            let d1 = Fmt.dayOnly.string(from: start)
            let d2 = Fmt.dayOnly.string(from: end)
            let monthYear = Fmt.monthYearHebrew.string(from: end)
            return "\(d1)–\(d2) \(monthYear)"
        }

        // fallback: full dates
        return "\(Fmt.dayMonthYear.string(from: start)) – \(Fmt.dayMonthYear.string(from: end))"
    }
    
    private func sixMonthRangeText() -> String {
        let start = monthStartFor6mIndex(0)
        let end = monthStartFor6mIndex(5)
        let sameYear = calendar.component(.year, from: start) == calendar.component(.year, from: end)
        if sameYear {
            return "\(Fmt.monthShort.string(from: start))–\(Fmt.monthShort.string(from: end)) \(calendar.component(.year, from: end))"
        }
        return "\(Fmt.monthYear.string(from: start)) – \(Fmt.monthYear.string(from: end))"
    }

    private func number(_ value: Double) -> String {
        Int(value.rounded()).formatted(.number.grouping(.automatic))
    }

    private func tooltipSubtitle(for i: Int) -> String {
        guard i >= 0, i < window.count else { return periodText }
        switch range {
        case .d:
            let h0 = Int(window[i].label) ?? 0
            let h1 = (h0 + 1) % 24
            return "\(Fmt.dayMonthYear.string(from: focusDate)) \(String(format: "%02d", h0))–\(String(format: "%02d", h1))"
        case .w:
            let end = weekEndForWeekPage(pageIndex)
            return Fmt.dayMonthYear.string(from: dateForWeekIndex(i, weekEnd: end))
        case .m:
            return Fmt.dayMonthYear.string(from: dateForMonthIndex(i))
        case .m6:
            return Fmt.monthYear.string(from: monthStartFor6mIndex(i))
        case .y:
            return Fmt.monthYear.string(from: monthStartForYearIndex(i))
        }
    }

    // MARK: - CSV
    private var exportFilename: String {
        let df = DateFormatter()
        df.timeZone = calendar.timeZone
        df.locale = Locale(identifier: "en_GB")
        df.dateFormat = "yyyy-MM-dd"
        return "Income_\(df.string(from: focusDate))_range_\(range.rawValue)"
    }

    private func makeCSV(for interval: DateInterval) -> String {
        let df = DateFormatter()
        df.timeZone = calendar.timeZone
        df.locale = Locale(identifier: "en_GB")
        df.dateFormat = "yyyy-MM-dd"

        var lines: [String] = ["date,gross,net,vat,tips,cash,card,orders,missingPayments"]

        var d = calendar.startOfDay(for: interval.start)
        let end = calendar.startOfDay(for: interval.end)

        while d < end {
            let a = sumForDay(d)
            lines.append("\(df.string(from: d)),\(Int(a.gross.rounded())),\(Int(a.net.rounded())),\(Int(a.vat.rounded())),\(Int(a.tips.rounded())),\(Int(a.cash.rounded())),\(Int(a.card.rounded())),\(a.orders),\(a.missing)")
            d = calendar.date(byAdding: .day, value: 1, to: d) ?? end
        }

        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - UI blocks
    private var headerOrTooltip: some View {
        ZStack(alignment: .topLeading) {

            VStack(alignment: .leading, spacing: 6) {
                Text("סה״כ")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(number(periodAgg.gross))
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
               idx >= 0,
               idx < window.count {

                GeometryReader { geo in
                    let tooltipW: CGFloat = 220
                    let clampedX = min(
                        max(x - tooltipW / 2, 0),
                        max(0, geo.size.width - tooltipW)
                    )

                    VStack(alignment: .leading, spacing: 6) {
                        Text("סה״כ")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.secondary)

                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(number(window[idx].value))
                                .font(.system(size: 36, weight: .bold))

                            Text("₪")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.secondary)
                        }

                        Text(tooltipSubtitle(for: idx))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                    .padding(12)
                    .frame(width: tooltipW, alignment: .leading)
                    .background(Color(UIColor.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .offset(x: clampedX, y: 0)
                }
            }
        }
        .frame(height: 92)
    }

    private var chart: some View {
        Group {
            if range == .d || range == .w {
                let pageCount = (range == .d) ? Self.dayPages : Self.weekPages

                TabView(selection: $pageIndex) {
                    ForEach(0..<pageCount, id: \.self) { p in
                        let w: [ChartPoint] = {
                            switch range {

                            case .d:
                                let day = calendar.startOfDay(for: dayForDayPage(p))

                                // ✅ TODAY → LIVE hourly
                                if calendar.isDate(day, inSameDayAs: today),
                                   let buckets = liveToday?.hourly?.buckets {

                                    var byHour: [Int: Double] = [:]
                                    for b in buckets {
                                        let paid = (b.cash ?? 0) + (b.card ?? 0)
                                        byHour[b.h, default: 0] += paid
                                    }

                                    let hours = Array(8...17)
                                    return hours.map { h in
                                        ChartPoint(
                                            label: String(format: "%02d", h),
                                            value: byHour[h] ?? 0
                                        )
                                    }
                                }

                                // ✅ PAST DAY → ZReport hourly
                                let key = dayKey(day)
                                let rs = cachedReportsByDay[key] ?? []

                                var byHour: [Int: Double] = [:]
                                for r in rs {
                                    for b in hourlyBuckets(from: r) {
                                        byHour[b.h, default: 0] += b.gross
                                    }
                                }

                                let hours = Array(8...17)
                                return hours.map { h in
                                    ChartPoint(
                                        label: String(format: "%02d", h),
                                        value: byHour[h] ?? 0
                                    )
                                }

                            case .w:
                                let end = weekEndForWeekPage(p)
                                let labels = rollingWeekLabels(endingAt: end)
                                return (0..<7).map { i in
                                    let d = dateForWeekIndex(i, weekEnd: end)
                                    return ChartPoint(label: labels[i], value: sumForDay(d).gross)
                                }

                            default:
                                // safety (never hit)
                                return []
                            }
                        }()

                        HealthBarChart(
                            values: w.map(\.value),
                            accent: accent,
                            xLabels: w.map(\.label),
                            selectedIndex: $selectedBarIndex,
                            selectedX: $selectedBarX
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
                HealthBarChart(
                    values: window.map(\.value),
                    accent: accent,
                    xLabels: (range == .m) ? monthXAxisLabels(for: window) : window.map(\.label),
                    selectedIndex: $selectedBarIndex,
                    selectedX: $selectedBarX
                )
                .frame(height: 260)
                .background(Color(UIColor.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 18))
            }
        }
    }

    private var paymentSplitCard: some View {
        let a = periodAgg
        let total = max(a.cash + a.card, 1)
        let cashP = a.cash / total
        let cardP = a.card / total

        return VStack(alignment: .leading, spacing: 12) {
            Text("אמצעי תשלום")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.gray)

            HStack(spacing: 12) {
                paymentMetric(
                    title: "אשראי",
                    amount: a.card,
                    percent: cardP,
                    systemImage: "creditcard.fill"
                )
                paymentMetric(
                    title: "מזומן",
                    amount: a.cash,
                    percent: cashP,
                    systemImage: "banknote.fill"
                )
            }
        }
        .padding(14)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private func paymentMetric(title: String, amount: Double, percent: Double, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: systemImage).font(.system(size: 12, weight: .semibold))
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(Int((percent * 100).rounded()))%")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.secondary)
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(number(amount))
                    .font(.system(size: 18, weight: .bold))
                Text("₪")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var detailCard: some View {
        let a = periodAgg
        return VStack(spacing: 0) {
            detailRow("מכירות ברוטו", a.gross)
            Divider().opacity(0.5)
            detailRow("הכנסה נטו", a.net)
            Divider().opacity(0.5)
            detailRow("מע״מ", a.vat)
            Divider().opacity(0.5)
            detailRow("טיפים", a.tips)
            Divider().opacity(0.5)
            //detailRow("הזמנות", Double(a.orders), unit: nil, isMoney: false)
        //    Divider().opacity(0.5)
         //   let missingOrOpen = (calendar.isDate(focusDate, inSameDayAs: today)) ? a.openOrders : a.missing
         //   detailRow("תשלומים חסרים", Double(missingOrOpen), unit: nil, isMoney: false)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private func detailRow(_ key: String, _ value: Double, unit: String? = "₪", isMoney: Bool = true) -> some View {
        HStack {
            Text(key)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.secondary)

            Spacer()

            if isMoney {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(number(value))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.primary)
                    if let unit {
                        Text(unit)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                }
            } else {
                Text(Int(value.rounded()).description)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)
            }
        }
        .padding(.vertical, 10)
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
                    .padding(.bottom, 20)
                chart
                paymentSplitCard
                detailCard
            }
            .onChange(of: selectedBarIndex) { sel in
                guard let i = sel else { return }

                switch range {
                case .w:
                    let end = weekEndForWeekPage(pageIndex)
                    setFocusDay(dateForWeekIndex(i, weekEnd: end))
                case .m:
                    setFocusDay(dateForMonthIndex(i))
                case .m6:
                    let m0 = monthStartFor6mIndex(i)
                    let m1 = calendar.date(byAdding: .month, value: 1, to: m0) ?? m0
                    setFocusDay(calendar.date(byAdding: .day, value: -1, to: m1) ?? m0)
                case .y:
                    let m0 = monthStartForYearIndex(i)
                    let m1 = calendar.date(byAdding: .month, value: 1, to: m0) ?? m0
                    setFocusDay(calendar.date(byAdding: .day, value: -1, to: m1) ?? m0)
                case .d:
                    break
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 18)
        }
        .background(Color(UIColor.systemGroupedBackground))
        .navigationTitle("הכנסות")
        .navigationBarTitleDisplayMode(.inline)
        .tint(accent)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showExportSheet = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .sheet(isPresented: $showExportSheet) {
            ExportRangeSheet(
                defaultRange: currentInterval(),
                buildCSV: { interval in
                    // if you already have makeCSV() for "current only",
                    // replace it with a range-aware one:
                    makeCSV(for: interval)   // <-- implement below
                }
            )
        }
        .onAppear {
            range = DashRange(rawValue: rangeRaw) ?? .w
            cachedReportsByDay = buildReportsByDayCache()
            
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

private enum ZDateUtil {
    static func parseDate(_ s: String) -> Date? {
        // try full ISO + fractional
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }

        // try ISO without fractional
        let iso2 = ISO8601DateFormatter()
        iso2.formatOptions = [.withInternetDateTime]
        if let d = iso2.date(from: s) { return d }

        // fallback yyyy-MM-dd
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

struct HealthBarChart: View {
   let values: [Double]
   let accent: Color
   let xLabels: [String]

   // optional selection (nil => chart is display-only)
   private var selectedIndexBinding: Binding<Int?>?
   private var selectedXBinding: Binding<CGFloat?>?

   // ✅ OPTIONAL: global “Health-style” cursor shared by parent across charts
   private var cursorActiveBinding: Binding<Bool>?
   private var cursorXNormBinding: Binding<CGFloat>?
   private var registerPlot: ((_ left: CGFloat, _ width: CGFloat) -> Void)?

   // ✅ local interaction state (used only when global cursor bindings are NOT provided)
   @State private var isCursorMode: Bool = false

   // MARK: - Inits

   init(values: [Double], accent: Color, xLabels: [String]) {
       self.values = values
       self.accent = accent
       self.xLabels = xLabels
       self.selectedIndexBinding = nil
       self.selectedXBinding = nil
       self.cursorActiveBinding = nil
       self.cursorXNormBinding = nil
       self.registerPlot = nil
   }

   init(values: [Double], accent: Color, xLabels: [String],
        selectedIndex: Binding<Int?>,
        selectedX: Binding<CGFloat?>) {
       self.values = values
       self.accent = accent
       self.xLabels = xLabels
       self.selectedIndexBinding = selectedIndex
       self.selectedXBinding = selectedX
       self.cursorActiveBinding = nil
       self.cursorXNormBinding = nil
       self.registerPlot = nil
   }

   // ✅ New init: same as above + shared cursor support
   init(values: [Double], accent: Color, xLabels: [String],
        selectedIndex: Binding<Int?>,
        selectedX: Binding<CGFloat?>,
        cursorActive: Binding<Bool>,
        cursorXNorm: Binding<CGFloat>,
        registerPlot: @escaping (_ left: CGFloat, _ width: CGFloat) -> Void) {
       self.values = values
       self.accent = accent
       self.xLabels = xLabels
       self.selectedIndexBinding = selectedIndex
       self.selectedXBinding = selectedX
       self.cursorActiveBinding = cursorActive
       self.cursorXNormBinding = cursorXNorm
       self.registerPlot = registerPlot
   }

   // MARK: - Bindings

   private var selectedIndex: Int? {
       get { selectedIndexBinding?.wrappedValue }
       nonmutating set { selectedIndexBinding?.wrappedValue = newValue }
   }

   private var selectedX: CGFloat? {
       get { selectedXBinding?.wrappedValue }
       nonmutating set { selectedXBinding?.wrappedValue = newValue }
   }

   private var usesGlobalCursor: Bool {
       cursorActiveBinding != nil && cursorXNormBinding != nil
   }

   private var cursorActive: Bool {
       get { cursorActiveBinding?.wrappedValue ?? false }
       nonmutating set { cursorActiveBinding?.wrappedValue = newValue }
   }

   private var cursorXNorm: CGFloat {
       get { cursorXNormBinding?.wrappedValue ?? 0 }
       nonmutating set { cursorXNormBinding?.wrappedValue = newValue }
   }

   // MARK: - Helpers

   private func labelWidth(_ s: String) -> CGFloat {
       CGFloat(max(4, s.count)) * 7.0
   }

   private func indexForX(_ x: CGFloat, leftPad: CGFloat, cellW: CGFloat, n: Int) -> Int {
       let local = max(0, x - leftPad)
       let i = Int(floor(local / max(cellW, 1)))
       return min(max(i, 0), max(0, n - 1))
   }

   private func indexForNorm(_ norm: CGFloat, n: Int) -> Int {
       let nn = max(n, 1)
       let clamped = min(max(norm, 0), 1)
       // 0..1 -> 0..n-1
       let i = Int(floor(clamped * CGFloat(nn)))
       return min(max(i, 0), nn - 1)
   }

   private func fmt(_ v: Double) -> String {
       Int(v.rounded()).formatted(.number.grouping(.automatic))
   }

   // MARK: - Body

   var body: some View {
       GeometryReader { geo in
           let w = geo.size.width
           let h = geo.size.height

           let leftPad: CGFloat = 10
           let topPad: CGFloat = 14
           let bottomPad: CGFloat = 15

           let maxVal = max(values.max() ?? 1, 1)
           let midVal = maxVal / 3.0

           let maxLabel = fmt(maxVal)
           let midLabel = fmt(midVal)
           let axisWidth = max(labelWidth(maxLabel), labelWidth(midLabel)) + 18

           let plotW = max(1, w - leftPad - axisWidth)
           let plotH = max(1, h - topPad - bottomPad)

           let n = max(values.count, 1)
           let cellW = plotW / CGFloat(n)
           let barW = min(34, cellW * 0.55)

           let centerX: (Int) -> CGFloat = { i in
               leftPad + (CGFloat(i) + 0.5) * cellW
           }

           // ✅ Long press:
           // - Standalone: enables local cursor mode
           // - Global: tells parent to enable cursor mode + registers plot geometry
           let longPress = LongPressGesture(minimumDuration: 0.45)
               .onEnded { _ in
                   guard selectedIndexBinding != nil else { return }
                   guard let idx = selectedIndex else {
                       return
                   }

                   if usesGlobalCursor {
                       // activate global cursor
                       cursorActive = true
                       registerPlot?(leftPad, plotW)

                       // set cursor to current selected bar
                       let norm = (CGFloat(idx) + 0.5) / CGFloat(max(n, 1))
                       cursorXNorm = norm

                   } else {
                       isCursorMode = true
                   }
               }

           // ✅ Drag cursor (standalone only)
           let dragCursor = DragGesture(minimumDistance: 0)
               .onChanged { g in
                   guard selectedIndexBinding != nil else { return }
                   guard isCursorMode else { return }

                   let i = indexForX(g.location.x, leftPad: leftPad, cellW: cellW, n: n)

                   selectedIndex = i
                   selectedX = centerX(i)
               }
               .onEnded { _ in
                   guard isCursorMode else { return }
                   isCursorMode = false
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

               // bars + x labels
               HStack(alignment: .bottom, spacing: 0) {
                   ForEach(0..<n, id: \.self) { i in
                       let v = (i < values.count) ? values[i] : 0
                       let barH = CGFloat(v / maxVal) * plotH

                       VStack(spacing: 4) {
                           RoundedRectangle(cornerRadius: 6)
                               .fill(accent)
                               .frame(width: barW, height: max(4, barH))

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
                           guard selectedIndexBinding != nil else { return }

                           if selectedIndex == i {
                               selectedIndex = nil
                               selectedX = nil
                               isCursorMode = false
                               if usesGlobalCursor { cursorActive = false }
                           } else {
                               selectedIndex = i
                               selectedX = centerX(i)
                               isCursorMode = false

                               if usesGlobalCursor {
                                   // keep global cursor OFF until long press
                                   cursorActive = false
                                   // but register plot so parent can normalize correctly once long press starts
                                   registerPlot?(leftPad, plotW)
                               }

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

               // vertical line when selected
               if let idx = selectedIndex, idx >= 0, idx < n {
                   Rectangle()
                       .fill(Color.gray.opacity(0.35))
                       .frame(width: 1, height: plotH)
                       .offset(x: centerX(idx), y: topPad)
               }

               // ✅ Standalone cursor overlay ONLY when local cursor mode is ON
               // (Global cursor drag should be handled by parent overlay.)
               if isCursorMode && !usesGlobalCursor {
                   Color.clear
                       .contentShape(Rectangle())
                       .gesture(dragCursor)
                       .allowsHitTesting(true)
               }
           }
           .simultaneousGesture(longPress)
           // ✅ If parent is driving cursorXNorm, keep updating this chart selection from it.
           .onChange(of: cursorXNorm) { newNorm in
               guard usesGlobalCursor else { return }
               guard cursorActive else { return }
               guard selectedIndexBinding != nil else { return }

               let i = indexForNorm(newNorm, n: n)
               selectedIndex = i
               selectedX = centerX(i)
               // Debug:
               // print("🟩 GLOBAL cursor norm=\(String(format:"%.3f", newNorm)) -> i=\(i)")
           }
       }
   }
}
