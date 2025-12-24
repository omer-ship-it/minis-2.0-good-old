import Foundation
import Combine

@MainActor
final class DashboardStore: ObservableObject {
    @Published var reports: [ZReport] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var liveToday: ZReportsSinceResponse.TodayLive?
    @Published var refreshStamp = UUID()
    private let baseURL = "https://minis.studio"
    private let cacheKey = "zreports_cache_v1"

    func loadCached() {
        guard
            let data = UserDefaults.standard.data(forKey: cacheKey),
            let decoded = try? JSONDecoder().decode([ZReport].self, from: data)
        else { return }
        self.reports = decoded
    }

    func saveCached() {
        guard let data = try? JSONEncoder().encode(reports) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey)
    }

    func fromDateStringForSync(minDays: Int = 120) -> String {
        // If we don't have enough history, force a backfill
        if reports.count < minDays {
            let d = Calendar.current.date(byAdding: .day, value: -365, to: Date())!
            return String(ISO8601DateFormatter().string(from: d).prefix(10))
        }

        // Otherwise incremental sync from last known day
        guard let last = reports.last else {
            let d = Calendar.current.date(byAdding: .day, value: -365, to: Date())!
            return String(ISO8601DateFormatter().string(from: d).prefix(10))
        }
        return String(last.rangeFrom.prefix(10))
    }

    func syncSince(miniAppId: Int) async {
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            let from = fromDateStringForSync(minDays: 120)

            var comps = URLComponents(string: baseURL + "/api/zreports/since")!
            comps.queryItems = [
                .init(name: "miniAppId", value: String(miniAppId)),
                .init(name: "from", value: from)
            ]

            let (data, resp) = try await URLSession.shared.data(from: comps.url!)
            guard let http = resp as? HTTPURLResponse else {
                throw NSError(domain: "http", code: -1)
            }

            if !(200..<300).contains(http.statusCode) {
                let body = String(data: data, encoding: .utf8) ?? "<no body>"
                throw NSError(
                    domain: "http",
                    code: http.statusCode,
                    userInfo: ["body": body]
                )
            }

            let decoded = try JSONDecoder().decode(ZReportsSinceResponse.self, from: data)

            guard decoded.ok else {
                throw NSError(domain: "api", code: -2)
            }

            // Z reports
            self.reports = decoded.reports

            // Live today (optional)
            self.liveToday = decoded.today
            self.refreshStamp = UUID()
            
            saveCached()
            
        } catch {
            if let ns = error as NSError?,
               let body = ns.userInfo["body"] as? String {
                self.error = "HTTP \(ns.code)\n\(body)"
            } else {
                self.error = "\(error)"
            }
        }
    }
}
import Foundation

struct Hourly: Decodable {
    let tz: String
    let buckets: [HourBucket]
}

struct Today: Decodable {
    let date: String
    let gross: Double
    let net: Double
    let vat: Double
    let cash: Double
    let card: Double
    let orders: Int
    let missingPaymentCount: Int
    let hourly: Hourly?
}

struct ZReportsSinceResponse: Decodable {
    let ok: Bool
    let count: Int
    let reports: [ZReport]
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

        // ✅ team object from API: { managers, kitchen, patisserie, floor }
        let team: Team?

        // ✅ NEW: top sellers for today
        let top: Top?

        // ✅ convenience totals
        var teamTotal: Double { team?.total ?? 0 }
        var discountsValue: Double { discounts ?? 0 }
        var cancellationsValue: Double { cancellations ?? 0 }
        var otherValue: Double { other ?? 0 }

        struct Team: Decodable {
            let managers: Double?
            let kitchen: Double?
            let patisserie: Double?
            let floor: Double?

            var total: Double {
                let m = managers ?? 0
                let k = kitchen ?? 0
                let p = patisserie ?? 0
                let f = floor ?? 0
                return m + k + p + f
            }
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

        struct Hourly: Decodable {
            let tz: String?
            // ✅ IMPORTANT: hourly buckets include discounts/other/cancellations now
            let buckets: [LiveHourBucket]
        }
    }

    // ✅ matches today.hourly.buckets payload from API
    struct LiveHourBucket: Decodable, Identifiable {
        var id: Int { h }

        let h: Int
        let gross: Double
        let orders: Int
        let cash: Double
        let card: Double
        let tips: Double

        let discounts: Double?
        let cancellations: Double?
        let other: Double?
    }
}

struct ZReport: Codable, Identifiable {
    let id: Int
    let miniAppId: Int
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


struct TopItem: Decodable, Identifiable {
    // stable id for SwiftUI lists
    var id: String { "\(name)|\(category)" }

    let name: String
    let category: String
    let amount: Double
    let qty: Int

    enum CodingKeys: String, CodingKey {
        case name, category, amount, qty
    }
}

struct HourBucket: Decodable, Identifiable {
    var id: Int { h }

    let h: Int
    let gross: Double
    let orders: Int
    let cash: Double
    let card: Double
    let tips: Double

    // ✅ NEW
    let discounts: Double
    let cancellations: Double
    let other: Double

    // If you still have topItems in some payloads, keep it optional:
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

        // ✅ NEW (default 0 if not provided)
        discounts = try c.decodeIfPresent(Double.self, forKey: .discounts) ?? 0
        cancellations = try c.decodeIfPresent(Double.self, forKey: .cancellations) ?? 0
        other = try c.decodeIfPresent(Double.self, forKey: .other) ?? 0

        topItems = try c.decodeIfPresent([TopItem].self, forKey: .topItems) ?? []
    }
}


import SwiftUI
import UniformTypeIdentifiers

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

func writeTempCSV(filename: String, csv: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
    let url = dir.appendingPathComponent(filename).appendingPathExtension("csv")
    try csv.data(using: .utf8)?.write(to: url, options: .atomic)
    return url
}

import Foundation

private enum ZDateUtil {
    static func parseDate(_ s: String) -> Date? {
        // Accepts "yyyy-MM-dd..." or full ISO
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

private extension ZReport {
    var rangeFromDate: Date? { ZDateUtil.parseDate(rangeFrom) }
}

 extension Array where Element == ZReport {
    func dailyGrossMap(cal: Calendar) -> [String: Double] {
        var out: [String: Double] = [:]
        for r in self {
            guard let d = r.rangeFromDate else { continue }
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
            guard let d = r.rangeFromDate else { continue }
            let day = cal.startOfDay(for: d)
            if day >= s && day < e { total += r.grossTotal }
        }
        return total
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
                            print("❌ Share export failed:", error)
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

