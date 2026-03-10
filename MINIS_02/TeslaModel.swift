import SwiftUI
import Foundation
import Combine

// MARK: - Shared models

struct ShopOption: Identifiable, Equatable {
    let id: Int
    let name: String
}

enum MiniTint {
    static let accent = Color(red: 0.50, green: 0.93, blue: 1.00)

    static func delta(_ text: String) -> Color {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("-") { return Color(red: 1.00, green: 0.40, blue: 0.40) }
        if t.hasPrefix("+") { return Color(red: 0.45, green: 0.95, blue: 0.72) }
        return .white
    }
}

// MARK: - Dashboard (Today) DTO + VM

struct TodayDashboardDTO: Decodable {
    let ok: Bool
    let miniAppId: Int
    let turnover: Double
    let orders: Int
    let aov: Double
}

@MainActor
final class DashboardVM: ObservableObject {
    @Published var turnover: Int = 0
    @Published var orders: Int = 0
    @Published var aov: Double = 0

    @Published var lastUpdatedAt: Date? = nil
    @Published var isLoading: Bool = false
    @Published var lastError: String? = nil

    private var pollTask: Task<Void, Never>?

    func startPolling(miniAppId: Int) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }
            await self.fetch(miniAppId: miniAppId)

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
                if Task.isCancelled { break }
                await self.fetch(miniAppId: miniAppId)
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func fetch(miniAppId: Int) async {
        isLoading = true
        lastError = nil
        defer { isLoading = false }

        do {
            var comps = URLComponents(string: "https://minis.studio/api/dashboard/today")!
            comps.queryItems = [URLQueryItem(name: "miniAppId", value: String(miniAppId))]
            let url = comps.url!

            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.timeoutInterval = 12
            req.cachePolicy = .reloadIgnoringLocalCacheData
            req.setValue("application/json", forHTTPHeaderField: "Accept")

            let (data, resp) = try await URLSession.shared.data(for: req)

            guard let http = resp as? HTTPURLResponse else {
                throw NSError(domain: "DashboardVM", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "No HTTP response"])
            }
            guard (200...299).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? ""
                throw NSError(domain: "DashboardVM", code: http.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode) \(body)"])
            }

            let decoded = try JSONDecoder().decode(TodayDashboardDTO.self, from: data)
            guard decoded.ok else {
                throw NSError(domain: "DashboardVM", code: -2,
                              userInfo: [NSLocalizedDescriptionKey: "API ok=false"])
            }

            withAnimation(.easeInOut(duration: 0.35)) {
                turnover = Int(decoded.turnover.rounded(.toNearestOrAwayFromZero))
                orders = decoded.orders
                aov = decoded.aov
            }
            lastUpdatedAt = Date()
        } catch {
            lastError = (error as NSError).localizedDescription
        }
    }
}

// MARK: - Shared helper (Israel opening time)

func ordersPerHourSince8amIsrael(orders: Int, now: Date = Date()) -> Double {
    let tz = TimeZone(identifier: "Asia/Jerusalem") ?? .current
    let cal = Calendar(identifier: .gregorian)

    let comps = cal.dateComponents(in: tz, from: now)
    var openComps = DateComponents()
    openComps.year = comps.year
    openComps.month = comps.month
    openComps.day = comps.day
    openComps.hour = 8
    openComps.minute = 0
    openComps.second = 0
    openComps.timeZone = tz

    let openDate = cal.date(from: openComps) ?? now
    let elapsed = now.timeIntervalSince(openDate)
    let hours = max(0.0, elapsed / 3600.0)
    let safeHours = max(0.5, hours)
    return Double(orders) / safeHours
}

// MARK: - Analytics models

enum AnalyticsRange: String, CaseIterable, Identifiable {
    case d = "D", w = "W", m = "M", m6 = "6M", y = "Y"
    var id: String { rawValue }
}

enum AnalyticsChannel: String, CaseIterable, Identifiable {
    case cashpoint = "Cashpoint"
    case selfService = "Self Service"
    case miniApp = "MiniApp"
    case app = "App"

    var id: String { rawValue }

    var short: String {
        switch self {
        case .cashpoint: return "COUNTER"
        case .selfService: return "KIOSK"
        case .miniApp: return "MINIAPP"
        case .app: return "APP"
        }
    }
}

struct ChannelMetric: Identifiable {
    var id: String { channel.rawValue }
    let channel: AnalyticsChannel
    let orders: Int
}

struct ChannelMetricPct: Identifiable {
    var id: String { channel.rawValue }
    let channel: AnalyticsChannel
    let orders: Int
    let pct: Double // 0..100
}

struct HourPoint: Identifiable {
    let id = UUID()
    let h: Int
    let v: Double
}

enum AnalyticsFormat {
    static func int(_ v: Double) -> String {
        let i = Int(v.rounded(.toNearestOrAwayFromZero))
        return NumberFormatter.localizedString(from: NSNumber(value: i), number: .decimal)
    }

    static func delta(_ pct: Double) -> String {
        let s = String(format: "%.0f", abs(pct))
        return (pct >= 0 ? "+" : "-") + s + "%"
    }
}

enum AnalyticsDate {
    static let tzIL = TimeZone(identifier: "Asia/Jerusalem") ?? .current

    static func dayKeyIL(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tzIL
        let d = cal.startOfDay(for: date)

        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tzIL
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    static func parseDayIL(_ s: String?) -> Date? {
        let raw = (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tzIL
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: String(raw.prefix(10)))
    }

    static func parseISODate(_ s: String?) -> Date? {
        let raw = (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: raw) { return d }
        return parseDayIL(String(raw.prefix(10)))
    }
}

// MARK: - ZReport helpers used by Analytics VM

extension Array where Element == ZReportDashboard {

    func sortedByBusinessDateDescIL() -> [ZReportDashboard] {
        self.sorted { a, b in
            let da = AnalyticsDate.parseDayIL(a.businessDay) ?? AnalyticsDate.parseISODate(a.rangeFrom) ?? Date.distantPast
            let db = AnalyticsDate.parseDayIL(b.businessDay) ?? AnalyticsDate.parseISODate(b.rangeFrom) ?? Date.distantPast
            return da > db
        }
    }

    func sumMapDailyGrossIL() -> [String: Double] {
        var out: [String: Double] = [:]
        for r in self {
            let date =
                AnalyticsDate.parseDayIL(r.businessDay)
                ?? AnalyticsDate.parseISODate(r.rangeFrom)
                ?? AnalyticsDate.parseISODate(r.createdAt)
            guard let d = date else { continue }
            out[AnalyticsDate.dayKeyIL(d), default: 0] += r.grossTotal
        }
        return out
    }

    func sumGrossIL(in interval: DateInterval) -> Double {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = AnalyticsDate.tzIL

        let s = cal.startOfDay(for: interval.start)
        let e = cal.startOfDay(for: interval.end)

        var total: Double = 0
        for r in self {
            let date =
                AnalyticsDate.parseDayIL(r.businessDay)
                ?? AnalyticsDate.parseISODate(r.rangeFrom)
                ?? AnalyticsDate.parseISODate(r.createdAt)
            guard let d = date else { continue }

            let day = cal.startOfDay(for: d)
            if day >= s && day < e { total += r.grossTotal }
        }
        return total
    }

    func sumOrdersIL(in interval: DateInterval) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = AnalyticsDate.tzIL

        let s = cal.startOfDay(for: interval.start)
        let e = cal.startOfDay(for: interval.end)

        var total = 0
        for r in self {
            let date =
                AnalyticsDate.parseDayIL(r.businessDay)
                ?? AnalyticsDate.parseISODate(r.rangeFrom)
                ?? AnalyticsDate.parseISODate(r.createdAt)
            guard let d = date else { continue }

            let day = cal.startOfDay(for: d)
            if day >= s && day < e { total += r.ordersCount }
        }
        return total
    }
}

// MARK: - Analytics VM (NO mutations inside snapshot)

@MainActor
final class AnalyticsV1VM: ObservableObject {

    @Published var range: AnalyticsRange = .d
    @Published var useCustomRange: Bool = false
    @Published var customStart: Date? = nil
    @Published var customEnd: Date? = nil

    @Published var store: DashboardStore

    // Placeholder channels orders (replace with real endpoint later)
    @Published var channelMetrics: [ChannelMetric] = [
        .init(channel: .cashpoint, orders: 170),
        .init(channel: .selfService, orders: 60),
        .init(channel: .miniApp, orders: 28),
        .init(channel: .app, orders: 12)
    ]

    init(store: DashboardStore) {
        self.store = store
    }

    // MARK: - Lifecycle

    func loadCached() {
        store.loadCached()
    }

    func sync(miniAppId: Int) async {
        // Safe: publishes happen in DashboardStore, we're already on main actor
        await store.syncSince(miniAppId: miniAppId)
    }

    func clearCustom() {
        useCustomRange = false
        customStart = nil
        customEnd = nil
    }

    func applyCustom(start: Date, end: Date) {
        customStart = start
        customEnd = end
        useCustomRange = true
    }

    // MARK: - Derived (no side effects)

    var errorText: String? {
        let e = store.error ?? ""
        return e.isEmpty ? nil : e
    }

    func latestClosedReport() -> ZReportDashboard? {
        store.reports.sortedByBusinessDateDescIL().first
    }

    func latestClosedDayKeyIL() -> String {
        guard let d = latestClosedDayStartIL() else { return "—" }
        return AnalyticsDate.dayKeyIL(d)
    }

    func headerSubtitle() -> String {
        if useCustomRange { return "Custom" }
        if range == .d { return "\(latestClosedDayKeyIL()) • Hours" }
        return "Scoreboard • \(range.rawValue)"
    }

    // MARK: - Turnover card

    func total(miniAppId: Int) -> Double {
        let fallback = latestClosedReport()?.grossTotal ?? 0
        guard !store.reports.isEmpty else { return fallback }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = AnalyticsDate.tzIL
        return store.reports.sumGrossIL(in: selectedInterval(cal: cal))
    }

    func orders(miniAppId: Int) -> Int {
        let fallback = latestClosedReport()?.ordersCount ?? 0
        guard !store.reports.isEmpty else { return fallback }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = AnalyticsDate.tzIL
        return store.reports.sumOrdersIL(in: selectedInterval(cal: cal))
    }

    func aov(total: Double, orders: Int) -> Double {
        orders > 0 ? (total / Double(orders)) : 0
    }

    func deltaPct() -> Double {
        guard !store.reports.isEmpty else { return 0 }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = AnalyticsDate.tzIL

        let cur = selectedInterval(cal: cal)
        let prev = DateInterval(start: cur.start.addingTimeInterval(-cur.duration), end: cur.start)

        let curSum = store.reports.sumGrossIL(in: cur)
        let prevSum = store.reports.sumGrossIL(in: prev)

        guard prevSum > 0 else { return 0 }
        return ((curSum - prevSum) / prevSum) * 100.0
    }

    func ordersPerHour(orders: Int) -> Double {
        guard orders > 0 else { return 0 }

        if range == .d, let latest = latestClosedReport() {
            let day =
                AnalyticsDate.parseDayIL(latest.businessDay)
                ?? AnalyticsDate.parseISODate(latest.rangeFrom)
                ?? AnalyticsDate.parseISODate(latest.createdAt)

            if let day {
                let h = openHours(for: day)
                return Double(orders) / max(1.0, h)
            }
        }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = AnalyticsDate.tzIL
        let interval = selectedInterval(cal: cal)
        let days = businessDayStartsInInterval(interval: interval, cal: cal)
        let totalOpenHours = days.reduce(0.0) { $0 + openHours(for: $1) }

        return Double(orders) / max(1.0, totalOpenHours)
    }

    func hourlyPointsForDay() -> [HourPoint] {
        let latest = latestClosedReport()
        let hourly = hourlyFromReportJson(latest?.jsonData)

        if let b = hourly?.buckets, !b.isEmpty {
            let sorted = b.sorted { $0.h < $1.h }
            return sorted.map { HourPoint(h: $0.h, v: max(0, $0.gross)) }
        }

        let hours = Array(8...20)
        let vals = pseudoHourShape(count: hours.count)
        return zip(hours, vals).map { HourPoint(h: $0.0, v: $0.1) }
    }

    func sparkValuesForRange() -> [Double] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = AnalyticsDate.tzIL

        let interval = selectedInterval(cal: cal)
        let daily = store.reports.sumMapDailyGrossIL()

        var out: [Double] = []
        var d = cal.startOfDay(for: interval.start)
        let end = cal.startOfDay(for: interval.end)

        while d < end {
            out.append(max(0, daily[AnalyticsDate.dayKeyIL(d)] ?? 0))
            d = cal.date(byAdding: .day, value: 1, to: d)!
        }

        return downsample(out, maxPoints: 14)
    }

    // MARK: - Channels snapshot (PURE)

    func channelsSnapshot() -> (selfPct: Double, totalOrders: Int, metrics: [ChannelMetricPct]) {
        let totalOrders = channelMetrics.reduce(0) { $0 + $1.orders }
        let totalD = Double(max(0, totalOrders))

        let metricsPct: [ChannelMetricPct] = channelMetrics.map { m in
            let pct = (totalD > 0) ? (Double(m.orders) / totalD) * 100.0 : 0
            return ChannelMetricPct(channel: m.channel, orders: m.orders, pct: pct)
        }

        let cashPct = metricsPct.first(where: { $0.channel == .cashpoint })?.pct ?? 0
        let selfPct = max(0, 100.0 - cashPct)

        return (selfPct, totalOrders, metricsPct)
    }

    // MARK: - Internal

    private func latestClosedDayStartIL() -> Date? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = AnalyticsDate.tzIL

        var best: Date? = nil
        for r in store.reports {
            let d =
                AnalyticsDate.parseDayIL(r.businessDay)
                ?? AnalyticsDate.parseISODate(r.rangeFrom)
                ?? AnalyticsDate.parseISODate(r.createdAt)
            guard let dd = d else { continue }
            let s = cal.startOfDay(for: dd)
            if best == nil || s > best! { best = s }
        }
        return best
    }

    private func selectedInterval(cal: Calendar) -> DateInterval {
        if useCustomRange, let s = customStart, let e = customEnd, e > s {
            return DateInterval(
                start: cal.startOfDay(for: s),
                end: cal.startOfDay(for: e).addingTimeInterval(24 * 3600)
            )
        }

        let endBase = latestClosedDayStartIL() ?? cal.startOfDay(for: Date())
        let endExclusive = cal.date(byAdding: .day, value: 1, to: endBase)!

        switch range {
        case .d:
            return DateInterval(start: endBase, end: endExclusive)
        case .w:
            let start = cal.date(byAdding: .day, value: -6, to: endBase)!
            return DateInterval(start: start, end: endExclusive)
        case .m:
            let start = cal.date(byAdding: .day, value: -29, to: endBase)!
            return DateInterval(start: start, end: endExclusive)
        case .m6:
            let start = cal.date(byAdding: .month, value: -6, to: endExclusive)!
            return DateInterval(start: start, end: endExclusive)
        case .y:
            let start = cal.date(byAdding: .year, value: -1, to: endExclusive)!
            return DateInterval(start: start, end: endExclusive)
        }
    }

    private func openHours(for date: Date) -> Double {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = AnalyticsDate.tzIL
        let weekday = cal.component(.weekday, from: date) // Sun=1 ... Fri=6 ... Sat=7
        return (weekday == 6) ? 6.0 : 9.0
    }

    private func businessDayStartsInInterval(interval: DateInterval, cal: Calendar) -> [Date] {
        var set = Set<String>()
        var out: [Date] = []

        for r in store.reports {
            guard let d =
                    AnalyticsDate.parseDayIL(r.businessDay)
                    ?? AnalyticsDate.parseISODate(r.rangeFrom)
                    ?? AnalyticsDate.parseISODate(r.createdAt)
            else { continue }

            let day = cal.startOfDay(for: d)
            if day >= cal.startOfDay(for: interval.start) && day < cal.startOfDay(for: interval.end) {
                let k = AnalyticsDate.dayKeyIL(day)
                if !set.contains(k) {
                    set.insert(k)
                    out.append(day)
                }
            }
        }
        return out.sorted()
    }

    private func hourlyFromReportJson(_ json: String?) -> Hourly? {
        guard let s = json, !s.isEmpty, let data = s.data(using: .utf8) else { return nil }
        do {
            if let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let hourlyStr = obj["hourly"] as? String,
               let hourlyData = hourlyStr.data(using: .utf8) {
                return try JSONDecoder().decode(Hourly.self, from: hourlyData)
            }
        } catch {
            return nil
        }
        return nil
    }

    private func downsample(_ values: [Double], maxPoints: Int) -> [Double] {
        guard values.count > maxPoints, maxPoints > 0 else { return values }
        let step = Double(values.count) / Double(maxPoints)
        return (0..<maxPoints).map { i in
            let idx = Int((Double(i) * step).rounded(.down))
            return values[min(idx, values.count - 1)]
        }
    }

    private func pseudoHourShape(count: Int) -> [Double] {
        guard count > 0 else { return [] }
        return (0..<count).map { i in
            let x = Double(i) / Double(max(1, count - 1))
            let lunch = exp(-pow((x - 0.35) / 0.16, 2))
            let dinner = exp(-pow((x - 0.75) / 0.18, 2))
            return (lunch * 0.8 + dinner * 1.0 + 0.15) * 100.0
        }
    }
}


