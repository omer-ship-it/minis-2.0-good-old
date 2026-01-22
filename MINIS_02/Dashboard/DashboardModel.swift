import Foundation
import Combine

// MARK: - Dashboard Store

@MainActor
final class DashboardStore: ObservableObject {
    @Published var reports: [ZReportDashboard] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var liveToday: ZReportsSinceResponseDashboard.TodayLive?
    @Published var refreshStamp = UUID()

    // ✅ Parsed + aggregated cache (keyed by yyyy-MM-dd business day)
    @Published private(set) var parsedAggByDay: [String: ParsedAggDay] = [:]

    private let baseURL = "https://minis.studio"
    private let cacheKeyReports = "zreports_cache_v3"
    private let cacheKeyAgg     = "zreports_agg_cache_v1"

    // MARK: - Cache (reports + parsed agg)

    func loadCached() {
        // reports
        if let data = UserDefaults.standard.data(forKey: cacheKeyReports),
           let decoded = try? JSONDecoder().decode([ZReportDashboard].self, from: data) {
            self.reports = decoded
        }

        // parsed agg
        if let data = UserDefaults.standard.data(forKey: cacheKeyAgg),
           let decoded = try? JSONDecoder().decode([String: ParsedAggDay].self, from: data) {
            self.parsedAggByDay = decoded
        } else {
            // if missing, rebuild from reports
            rebuildParsedAggCache()
        }

        self.refreshStamp = UUID()
    }

    private func saveCachedReports() {
        guard let data = try? JSONEncoder().encode(reports) else { return }
        UserDefaults.standard.set(data, forKey: cacheKeyReports)
    }

    private func saveCachedAgg() {
        guard let data = try? JSONEncoder().encode(parsedAggByDay) else { return }
        UserDefaults.standard.set(data, forKey: cacheKeyAgg)
    }

    // MARK: - Public helpers for UI

    func topForDay(_ dayKey: String) -> (categories: [SalesLine], items: [SalesLine]) {
        let k = normalizeDayKey(dayKey)
        guard let agg = parsedAggByDay[k] else { return ([], []) }
        return (agg.categories.map { $0.toSalesLine() }, agg.items.map { $0.toSalesLine() })
    }

    func availableBusinessDays() -> [String] {
        parsedAggByDay.keys.sorted()
    }

    // MARK: - Sync window (NOW based on BusinessDay)

    private func newestBusinessDayKey(cal: Calendar) -> String? {
        reports
            .compactMap { $0.businessDayDate }                 // ✅ businessDay, not rangeFrom
            .map { ZDateUtil.dayKey($0, cal: cal) }            // yyyy-MM-dd
            .max()
    }

    func fromDateStringForSync(minDays: Int = 120) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Jerusalem") ?? .current

        if reports.count < minDays {
            let d = cal.date(byAdding: .day, value: -365, to: Date())!
            return ZDateUtil.dayKey(d, cal: cal)
        }

        if let lastKey = newestBusinessDayKey(cal: cal) {
            return lastKey
        } else {
            let d = cal.date(byAdding: .day, value: -365, to: Date())!
            return ZDateUtil.dayKey(d, cal: cal)
        }
    }

    // MARK: - Networking

    func syncSince(miniAppId: Int) async {
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            let from = fromDateStringForSync(minDays: 120)

            var comps = URLComponents(string: baseURL + "/api/zreports/since")!
            comps.queryItems = [
                .init(name: "miniAppId", value: String(miniAppId)),
                .init(name: "from", value: from),
                .init(name: "includeHeavy", value: "false")
            ]

            guard let url = comps.url else {
                throw NSError(domain: "url", code: -1, userInfo: ["body": "Failed to build URL"])
            }

            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.setValue("application/json", forHTTPHeaderField: "Accept")

            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                throw NSError(domain: "http", code: -1, userInfo: ["body": "No HTTPURLResponse"])
            }

            if !(200..<300).contains(http.statusCode) {
                let body = String(data: data, encoding: .utf8) ?? "<no body>"
                throw NSError(domain: "http", code: http.statusCode, userInfo: ["body": body])
            }

            let decoded = try JSONDecoder().decode(ZReportsSinceResponseDashboard.self, from: data)
            guard decoded.ok else {
                throw NSError(domain: "api", code: -2, userInfo: ["body": "ok=false"])
            }

            self.reports = decoded.reports
            self.liveToday = decoded.today

            // ✅ rebuild parsed index after sync
            rebuildParsedAggCache()

            self.refreshStamp = UUID()
            saveCachedReports()
            saveCachedAgg()

        } catch {
            if let ns = error as NSError?,
               let body = ns.userInfo["body"] as? String {
                self.error = "HTTP \(ns.code)\n\(body)"
            } else {
                self.error = "\(error)"
            }
        }
    }

    // MARK: - Parsed agg cache builder

    private func normalizeDayKey(_ s: String) -> String {
        // accepts "yyyy-MM-dd" or "yyyy-MM-ddT00:00:00"
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(10))
    }

    private func rebuildParsedAggCache() {
        var dayToCatMap: [String: [String: (amount: Double, qty: Int)]] = [:]
        var dayToItemMap: [String: [String: (amount: Double, qty: Int)]] = [:]

        for r in reports {
            let dayKey = normalizeDayKey(r.businessDay ?? String(r.rangeFrom.prefix(10)))
            let top = r.parsedTop()

            // categories
            var cm = dayToCatMap[dayKey] ?? [:]
            for c in top.categories {
                let cur = cm[c.name] ?? (0, 0)
                cm[c.name] = (cur.amount + c.amount, cur.qty + c.qty)
            }
            dayToCatMap[dayKey] = cm

            // items
            var im = dayToItemMap[dayKey] ?? [:]
            for it in top.items {
                let cur = im[it.name] ?? (0, 0)
                im[it.name] = (cur.amount + it.amount, cur.qty + it.qty)
            }
            dayToItemMap[dayKey] = im
        }

        var out: [String: ParsedAggDay] = [:]

        for dayKey in Set(dayToCatMap.keys).union(dayToItemMap.keys) {
            let catsMap = dayToCatMap[dayKey] ?? [:]
            let itemsMap = dayToItemMap[dayKey] ?? [:]

            let cats = catsMap
                .map { ParsedLine(name: $0.key, amount: $0.value.amount, qty: $0.value.qty) }
                .sorted { $0.amount > $1.amount }

            let items = itemsMap
                .map { ParsedLine(name: $0.key, amount: $0.value.amount, qty: $0.value.qty) }
                .sorted { $0.amount > $1.amount }

            out[dayKey] = ParsedAggDay(categories: cats, items: items)
        }

        self.parsedAggByDay = out
    }

    // MARK: - Legacy Top parsing (still useful for ad-hoc subsets)
    func aggregatedTop(from subset: [ZReportDashboard]) -> (categories: [SalesLine], items: [SalesLine]) {
        var catMap: [String: (amount: Double, qty: Int)] = [:]
        var itemMap: [String: (amount: Double, qty: Int)] = [:]

        for r in subset {
            let top = r.parsedTop()

            for c in top.categories {
                let cur = catMap[c.name] ?? (0, 0)
                catMap[c.name] = (cur.amount + c.amount, cur.qty + c.qty)
            }

            for it in top.items {
                let cur = itemMap[it.name] ?? (0, 0)
                itemMap[it.name] = (cur.amount + it.amount, cur.qty + it.qty)
            }
        }

        let cats = catMap
            .map { SalesLine(name: $0.key, amount: $0.value.amount, qty: $0.value.qty) }
            .sorted { $0.amount > $1.amount }

        let items = itemMap
            .map { SalesLine(name: $0.key, amount: $0.value.amount, qty: $0.value.qty) }
            .sorted { $0.amount > $1.amount }

        return (cats, items)
    }
}

// MARK: - Cached parsed structures

struct ParsedAggDay: Codable {
    let categories: [ParsedLine]
    let items: [ParsedLine]
}

struct ParsedLine: Codable {
    let name: String
    let amount: Double
    let qty: Int

    func toSalesLine() -> SalesLine {
        SalesLine(name: name, amount: amount, qty: qty)
    }
}

// MARK: - Models

struct ZReportsSinceResponseDashboard: Decodable {
    let ok: Bool
    let count: Int
    let reports: [ZReportDashboard]
    let today: TodayLive?

    struct TodayLive: Decodable {
        let date: String
        let gross: Double
        let net: Double
        let vat: Double
        let tips: Double
        let cash: Double
        let card: Double
        let orders: Int
        let openOrders: Int?
        let missingPaymentCount: Int

        let discounts: Double?
        let cancellations: Double?
        let other: Double?

        let hourly: Hourly?

        let team: Team?
        let top: Top?

        var teamTotal: Double { team?.total ?? 0 }

        struct Team: Decodable {
            let managers: Double?
            let kitchen: Double?
            let patisserie: Double?
            let floor: Double?

            var total: Double { (managers ?? 0) + (kitchen ?? 0) + (patisserie ?? 0) + (floor ?? 0) }
        }

        struct Top: Decodable {
            let items: [TopLine]?
            let categories: [TopLine]?

            struct TopLine: Decodable, Identifiable {
                var id: String { name }
                let name: String
                let amount: Double
                let qty: Int
            }
        }
    }
}

struct ZReportDashboard: Codable, Identifiable {
    let id: Int
    let miniAppId: Int
    let businessDay: String?
    let rangeFrom: String
    let rangeTo: String

    let grossTotal: Double
    let netTotal: Double
    let vatTotal: Double
    let vatRate: Double

    let cashCount: Int
    let cashTotal: Double
    let cardCount: Int
    let cardTotal: Double
    let paymentsTotal: Double

    let tipsTotal: Double
    let cashTipsTotal: Double
    let cardTipsTotal: Double

    let ordersCount: Int
    let missingPaymentCount: Int

    let jsonData: String?
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case miniAppId = "MiniAppId"
        case businessDay = "BusinessDay"
        case rangeFrom = "RangeFrom"
        case rangeTo = "RangeTo"
        case grossTotal = "GrossTotal"
        case netTotal = "NetTotal"
        case vatTotal = "VatTotal"
        case vatRate = "VatRate"
        case cashCount = "CashCount"
        case cashTotal = "CashTotal"
        case cardCount = "CardCount"
        case cardTotal = "CardTotal"
        case paymentsTotal = "PaymentsTotal"
        case tipsTotal = "TipsTotal"
        case cashTipsTotal = "CashTipsTotal"
        case cardTipsTotal = "CardTipsTotal"
        case ordersCount = "OrdersCount"
        case missingPaymentCount = "MissingPaymentCount"
        case jsonData = "JsonData"
        case createdAt = "CreatedAt"
    }
}

// MARK: - report.jsonData decoding

private struct ZReportDashboardJson: Decodable {
    let top: Block?
    let all: Block?

    struct Block: Decodable {
        let categories: [Line]?
        let items: [Line]?
    }

    struct Line: Decodable {
        let productId: Int?
        let name: String?
        let amount: Double?
        let qty: Int?
    }
}

extension ZReportDashboard {
    func parsedBlock(useAll: Bool) -> (categories: [SalesLine], items: [SalesLine]) {
        guard let s = jsonData, !s.isEmpty,
              let data = s.data(using: .utf8) else { return ([], []) }

        do {
            let payload = try JSONDecoder().decode(ZReportDashboardJson.self, from: data)
            let block = useAll ? payload.all : payload.top

            let cats: [SalesLine] = (block?.categories ?? []).compactMap { t in
                let name = (t.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return nil }
                return SalesLine(name: name, amount: t.amount ?? 0, qty: t.qty ?? 0)
            }

            let items: [SalesLine] = (block?.items ?? []).compactMap { t in
                let name = (t.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return nil }
                return SalesLine(name: name, amount: t.amount ?? 0, qty: t.qty ?? 0)
            }

            return (cats, items)
        } catch {
            return ([], [])
        }
    }

    func parsedTop() -> (categories: [SalesLine], items: [SalesLine]) {
        parsedBlock(useAll: false)
    }

    func parsedAll() -> (categories: [SalesLine], items: [SalesLine]) {
        parsedBlock(useAll: true)
    }
}

// MARK: - Hourly models (used by TodayLive)

struct Hourly: Decodable {
    let tz: String
    let buckets: [HourBucket]
}

struct HourBucket: Decodable, Identifiable {
    var id: Int { h }

    let h: Int
    let gross: Double
    let orders: Int
    let cash: Double
    let card: Double
    let tips: Double

    let discounts: Double
    let cancellations: Double
    let other: Double

    let topItems: [TopItem]

    enum CodingKeys: String, CodingKey {
        case h, gross, orders, cash, card, tips
        case discounts, cancellations, other
        case topItems
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        h = try c.decode(Int.self, forKey: .h)
        gross = try c.decodeIfPresent(Double.self, forKey: .gross) ?? 0
        orders = try c.decodeIfPresent(Int.self, forKey: .orders) ?? 0
        cash = try c.decodeIfPresent(Double.self, forKey: .cash) ?? 0
        card = try c.decodeIfPresent(Double.self, forKey: .card) ?? 0
        tips = try c.decodeIfPresent(Double.self, forKey: .tips) ?? 0

        discounts = try c.decodeIfPresent(Double.self, forKey: .discounts) ?? 0
        cancellations = try c.decodeIfPresent(Double.self, forKey: .cancellations) ?? 0
        other = try c.decodeIfPresent(Double.self, forKey: .other) ?? 0

        topItems = try c.decodeIfPresent([TopItem].self, forKey: .topItems) ?? []
    }
}

struct TopItem: Decodable, Identifiable {
    var id: String { "\(name)|\(category)" }
    let name: String
    let category: String
    let amount: Double
    let qty: Int
}

// MARK: - Date helpers

private enum ZDateUtil {
    static func parseDayKey(_ s: String, tz: TimeZone) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
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
    var businessDayDate: Date? {
        guard let bd = businessDay, !bd.isEmpty else { return nil }
        return ZDateUtil.parseDayKey(bd, tz: TimeZone(identifier: "Asia/Jerusalem") ?? .current)
    }
}

extension Array where Element == ZReportDashboard {
    func dailyGrossMap(cal: Calendar) -> [String: Double] {
        var out: [String: Double] = [:]
        for r in self {
            guard let d = r.businessDayDate else { continue }
            let k = ZDateUtil.dayKey(d, cal: cal)
            out[k, default: 0] += r.grossTotal
        }
        return out
    }

    func sumGross(in interval: DateInterval, cal: Calendar) -> Double {
        let s = cal.startOfDay(for: interval.start)
        let e = cal.startOfDay(for: interval.end)
        var total: Double = 0
        for r in self {
            guard let d = r.businessDayDate else { continue }
            let day = cal.startOfDay(for: d)
            if day >= s && day < e { total += r.grossTotal }
        }
        return total
    }
}
