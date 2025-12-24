import SwiftUI
import AVFoundation
import Combine

let isPad = UIDevice.current.userInterfaceIdiom == .pad
enum AdminTab: String, CaseIterable {
    case orders = "הזמנות"
    case stock  = "מלאי"

    var title: String { rawValue }

    var icon: String {
        switch self {
        case .orders: return "list.bullet"
        case .stock:  return "shippingbox"
        }
    }
}

enum OrderSource: String, Codable {
    case kiosk      // App Clip / self-order
    case delivery   // Full customer order
}

enum KDSOrderBucket: String, CaseIterable, Identifiable {
    case active = "פתוח"
    case scheduled = "עתידיות"
    case completed = "סגור"
    var id: String { rawValue }
}

struct KDSOrderLine: Identifiable, Hashable {
    let id = UUID()              // UI id
    let itemId: Int?             // ← NEW (Items.Id from API, if you return it)
    let productId: Int?          // ← NEW (Products.Id; fallback if itemId is nil)
    let name: String
    let qty: Int
    let category: String?
    var status: Int              // ← NEW (Items.Status: 1/2/4/5)
    let station: String?
    let modifiers: String?
}

enum Station: String, CaseIterable, Identifiable {
    case kitchen = "מטבח"
    case bar     = "בר"
    case bakery     = "מאפים"
    var id: String { rawValue }
}

enum StationFilter: String, CaseIterable, Identifiable {
    case all     = "כל התחנות"
    case kitchen = "מטבח"
    case bar     = "בר"
    case bakery  = "מאפים"   // 👈 NEW

    var id: String { rawValue }
}

fileprivate func stationFromFilter(_ f: StationFilter) -> Station? {
    switch f {
    case .all:
        return nil
    case .kitchen:
        return .kitchen
    case .bar:
        return .bar
    case .bakery:           // 👈 NEW
        return .bakery
    }
}
fileprivate func filteredLines(_ order: KDSAdminOrder, for filter: StationFilter) -> [KDSOrderLine] {
    guard let st = stationFromFilter(filter) else { return order.lines }
    return order.lines.filter { lineStation($0) == st }   // was category-based
}

fileprivate func summary(for lines: [KDSOrderLine]) -> String {
    if lines.isEmpty { return "—" }
    let head = lines.prefix(2).map { "\($0.name) x\($0.qty)" }.joined(separator: ", ")
    let extra = max(0, lines.count - 2)
    return extra > 0 ? "\(head) +\(extra) more" : head
}


fileprivate func stationFromString(_ s: String?) -> Station? {
    guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !s.isEmpty else { return nil }
    switch s {
    case "kitchen": return .kitchen
    case "bar", "barista", "beverage", "drinks", "cashpoint", "till":
        return .bar
    default:
        return nil
    }
}

// Normalise Hebrew / text (you already had this)
@inline(__always)
fileprivate func heNorm(_ s: String) -> String {
    var t = s.precomposedStringWithCanonicalMapping
    t = t.replacingOccurrences(of: "\\p{M}", with: "", options: .regularExpression)
    t = t.replacingOccurrences(of: "[\\u200E\\u200F\\u202A-\\u202E\\u2066-\\u2069]", with: "", options: .regularExpression)
    t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    return t.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}


/// 🔹 NEW core rule:
/// - Kitchen if category is "סלטים" OR name contains "טוסט"
/// - Bar for everything else
@inline(__always)
fileprivate func lineStation(_ line: KDSOrderLine) -> Station? {
    let cat = heNorm(line.category ?? "")
    let nm  = heNorm(line.name)

    // Kitchen if category is סלטים (any variant)
    if cat.contains(heNorm("סלטים")) {
        return .kitchen
    }

    // Kitchen if product name contains "טוסט"
    if nm.contains(heNorm("טוסט")) {
        return .kitchen
    }

    // Everything else is Bar
    return .bar
}

@inline(__always)
fileprivate func norm(_ s: String) -> String {
    // NFC + strip combining marks (niqqud), bidi/invisible marks, collapse spaces
    var t = s.precomposedStringWithCanonicalMapping
    t = t.replacingOccurrences(of: "\\p{M}", with: "", options: .regularExpression)
    t = t.replacingOccurrences(of: "[\\u200E\\u200F\\u202A-\\u202E\\u2066-\\u2069]", with: "", options: .regularExpression)
    t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    return t.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}

/// Strict mapping: ONLY category decides station. No name heuristics.


fileprivate func statusLabel(_ code: Int) -> String {
    switch code {
    case 5: return "Collected"
    case 4: return "Ready"
    case 2: return "In Progress"
    default: return "New"
    }
}
fileprivate func statusColor(_ code: Int) -> Color {
    switch code {
    case 5: return .gray
    case 4: return .purple
    case 2: return .indigo
    default: return .blue
    }
}

// Aggregate items -> global status for the row
fileprivate func globalStatusCode(from lines: [KDSOrderLine]) -> Int? {
    guard !lines.isEmpty else { return nil }
    let uniq = Set(lines.map { $0.status })
    return uniq.count == 1 ? uniq.first! : nil
}
struct KDSAdminOrder: Identifiable, Hashable {
    enum Stage { case received, inProgress, ready, pickedUp }

    // Per-station numeric codes (1=Received, 4=Ready, 5=Collected)
    var stationStatus: [Station: Int] = [:]

    // Core
    let id: Int
    let source: OrderSource
    let tableLabel: String?                 // e.g. “Table 5”, “Stand 12”
    var bucket: KDSOrderBucket
    var stage: Stage = .received            // global stage (kept for backward-compat)

    let placedAt: Date
    let scheduledFor: Date?
    let customerName: String
    let totalGBP: Double
    let itemSummary: String
    let isDelivery: Bool
    let shortCode: String?
    var lines: [KDSOrderLine]
    let service: String?
    let name: String?

    // Stations touched by this order (derived from line categories)
    var stations: Set<Station> {
        Set(lines.compactMap { lineStation($0) })
    }

    // MARK: - Station utilities

    /// Lines that belong to a specific station (strict category-based)
    func lines(for station: Station) -> [KDSOrderLine] {
        lines.filter { lineStation($0) == station }
    }

    /// Is this order mixed across more than one station?
    var isMixed: Bool { stations.count > 1 }

    /// Raw numeric code (if present) for a station
    func stationCode(_ station: Station) -> Int? {
        stationStatus[station]
    }

    /// Map a numeric code → Stage (defaults to .received)
    private func mapStage(code: Int?) -> Stage {
        switch code ?? 1 {
        case 5: return .pickedUp
        case 4: return .ready
        case 2: return .inProgress
        default: return .received
        }
    }

    /// Station-specific stage (falls back to global only if no per-station code exists)
    func stationStage(_ station: Station) -> Stage {
        mapStage(code: stationStatus[station])
    }

    /// Convenience checks for UI
    func isStationReady(_ station: Station) -> Bool {
        let st = stationStage(station)
        return st == .ready || st == .pickedUp
    }

    func isStationCollected(_ station: Station) -> Bool {
        stationStage(station) == .pickedUp
    }

    /// Optional: roll up stations to a synthetic global stage (does NOT mutate `stage`)
    /// - pickedUp if all touched stations are 5
    /// - ready    if all touched stations are >=4
    /// - otherwise nil (meaning keep existing global)
    func rolledUpStageFromStations() -> Stage? {
        let touched = stations
        guard !touched.isEmpty else { return nil }
        let codes = touched.map { stationStatus[$0] ?? 1 }
        if codes.allSatisfy({ $0 >= 5 }) { return .pickedUp }
        if codes.allSatisfy({ $0 >= 4 }) { return .ready }
        return nil
    }

    /// Mutating helper to set a station’s code (UI optimistic updates)
    mutating func setStationStatus(_ station: Station, to code: Int) {
        stationStatus[station] = code
    }
}

// MARK: - Sample Data


// MARK: - ViewModel

@MainActor
final class KDSOrdersVM: ObservableObject {
    @Published var all: [KDSAdminOrder] = []
    @Published var filter: KDSOrderBucket = .active
    @Published var search: String = ""
    @Published var isLoading = false
    @Published var lastServerLoad: Date? = nil
    @Published var lastPushAt: Date? = nil
    private var printedKeys = Set<String>()   // e.g., "orderId|station"
    private var allowAutoPrint = false
    
    

    private let fallbackInterval: TimeInterval = 120   // 2 minutes (tweak as you like)
    
    @Published var stationFilter: StationFilter = .all {
        didSet {
            UserDefaults.standard.set(stationFilter.rawValue, forKey: "LastStationFilter")
        }
    }
    
    

    

    private let baseURL = "https://minis.studio/api/admin/orders"
    private let miniAppId = 12 // or hardcode 8 if needed

    private var lastActivity: Date {
        max(lastServerLoad ?? .distantPast, lastPushAt ?? .distantPast)
    }

   
    /// Called by a timer to decide if we should poll
    func ensureFresh() {
        let elapsed = Date().timeIntervalSince(lastActivity)
        if elapsed >= fallbackInterval {
            Task { await load() }
        }
    }
    private func mapStatus(_ s: Int) -> (bucket: KDSOrderBucket, stage: KDSAdminOrder.Stage) {
        switch s {
        case 1:  return (.active,   .received)   // NEW
        case 2:  return (.active,   .inProgress) // IN PROGRESS
        case 4:  return (.active,   .ready)      // READY
        case 5:  return (.completed,.pickedUp)   // PICKED UP
        default: return (.active,   .received)   // sensible default
        }
    }

    private func mapStrings(bucket: String, stage: String) -> (bucket: KDSOrderBucket, stage: KDSAdminOrder.Stage) {
        let b: KDSOrderBucket = {
            switch bucket.lowercased() {
            case "completed": return .completed
            case "scheduled": return .scheduled
            default:          return .active
            }
        }()
        let st: KDSAdminOrder.Stage = {
            switch stage.lowercased() {
            case "in_progress", "inprogress": return .inProgress
            case "ready":                     return .ready
            case "picked_up", "pickedup":     return .pickedUp
            default:                          return .received
            }
        }()
        return (b, st)
    }
    private func mapStage(from status: Int?) -> KDSAdminOrder.Stage {
        switch status ?? 1 {
        case 1: return .received
        case 2: return .inProgress
        case 4: return .ready
        case 5: return .pickedUp
        default: return .received
        }
    }
    
    @MainActor
    func setStatus(orderId: Int, to newStatus: Int, miniAppId: Int) async -> Bool {
        guard let url = URL(string: "https://minis.studio/api/admin/orders/\(orderId)/status") else { return false }
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Inject station automatically from the persisted sidebar filter
        let lastStationRaw = UserDefaults.standard.string(forKey: "LastStationFilter") ?? StationFilter.all.rawValue
        let currentFilter = StationFilter(rawValue: lastStationRaw) ?? .all
        let currentStation = stationFromFilter(currentFilter) // Station? (nil for .all)

        var body: [String: Any] = ["status": newStatus, "miniAppId": miniAppId]
        if let st = currentStation { body["station"] = st.rawValue } // "Kitchen"/"Bar"/"Barista"
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                print("❌ setStatus HTTP fail:", (resp as? HTTPURLResponse)?.statusCode ?? -1,
                      String(data: data, encoding: .utf8) ?? "")
                return false
            }

            // Try to parse stationsStatus from response (if present)
            var returnedStationStatus: [Station: Int] = [:]
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let ss = json["stationsStatus"] as? [String: Any] {
                for (k, v) in ss {
                    if let st = Station(rawValue: k) {
                        if let i = v as? Int { returnedStationStatus[st] = i }
                        else if let s = v as? String, let i = Int(s) { returnedStationStatus[st] = i }
                    }
                }
            }

            // ✅ Optimistic local update
            if let idx = all.firstIndex(where: { $0.id == orderId }) {
                var copy = all[idx]

                if let st = currentStation {
                    // Station-specific action: prefer server stationsStatus, fallback to optimistic
                    if !returnedStationStatus.isEmpty {
                        for (k, v) in returnedStationStatus { copy.stationStatus[k] = v }
                    } else {
                        copy.stationStatus[st] = newStatus // 4 or 5
                    }
                    // Do NOT change global stage/bucket here — let roll-up happen via polling/response.
                } else {
                    // Global action (All stations): keep your original global stage update
                    switch newStatus {
                    case 4:
                        copy.stage  = .ready
                        copy.bucket = .active
                    case 5:
                        copy.stage  = .pickedUp
                        copy.bucket = .completed
                    case 1:
                        copy.stage  = .received
                        copy.bucket = .active
                    case 2:
                        copy.stage  = .inProgress
                        copy.bucket = .active
                    default:
                        break
                    }
                    // If server also returned stationsStatus, merge that in
                    if !returnedStationStatus.isEmpty {
                        for (k, v) in returnedStationStatus { copy.stationStatus[k] = v }
                    }
                }

                all[idx] = copy
            }

            return true
        } catch {
            print("❌ setStatus network error:", error.localizedDescription)
            return false
        }
    }
    
    private var player: AVAudioPlayer?

    private func playAlertSound() {
        guard let url = Bundle.main.url(forResource: "bell", withExtension: "mp4") else {
            print("⚠️ bell.mp4 not found in bundle")
            return
        }
        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.prepareToPlay()
            player?.play()
        } catch {
            print("❌ Audio playback error:", error.localizedDescription)
        }
    }
    
    init() {
        Task {                             // ← flip flag 5 s after launch
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    await MainActor.run { self.allowAutoPrint = true }
                    print("✅ Auto-print enabled")
                }
        NotificationCenter.default.addObserver(
            forName: .refreshOrders,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.lastPushAt = Date()
            Task { await self.load() }
        }

        // 🟢 Restore the last saved station
        if let raw = UserDefaults.standard.string(forKey: "LastStationFilter"),
           let restored = StationFilter(rawValue: raw) {
            stationFilter = restored
        }
    }
    
    
    @MainActor
    func load() async {
        guard miniAppId > 0 else { return }
        isLoading = true
        defer { isLoading = false }

        guard let url = URL(string: "\(baseURL)?miniAppId=\(miniAppId)") else {
            print("❌ admin/orders: bad URL")
            return
        }

        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                print("❌ admin/orders: no HTTPURLResponse")
                return
            }
            guard http.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
                print("❌ admin/orders HTTP \(http.statusCode)\n\(body)")
                return
            }

            // --- Models coming from API ---
            struct ApiResponse: Decodable {
                let ok: Bool
                let count: Int
                let orders: [OrderDTO]
            }
            struct LineDTO: Decodable {
                let itemId: Int?
                let productId: Int?
                let name: String
                let qty: Int
                let category: String?
                let status: Int
                let station: String?
                let modifiers: String?
            }
            struct OrderDTO: Decodable {
                let id: Int
                let source: String
                let bucket: String
                let stage: String
                let placedAt: Date
                let scheduledFor: Date?
                let customerName: String
                let totalGBP: Double
                let itemSummary: String
                let isDelivery: Bool
                let shortCode: String?
                let lines: [LineDTO]
                let status: Int?
                let stationsStatus: [String:Int]?
                let service: String?
                let name: String?

                enum CodingKeys: String, CodingKey {
                    case id, source, bucket, stage, placedAt, scheduledFor, customerName, totalGBP, itemSummary, isDelivery, shortCode, lines
                    case status = "status"
                    case Status = "Status"
                    case stationsStatus
                    case service, name
                }

                init(from decoder: Decoder) throws {
                    let c = try decoder.container(keyedBy: CodingKeys.self)
                    id           = try c.decode(Int.self,    forKey: .id)
                    source       = try c.decode(String.self, forKey: .source)
                    bucket       = try c.decode(String.self, forKey: .bucket)
                    stage        = try c.decode(String.self, forKey: .stage)
                    placedAt     = try c.decode(Date.self,   forKey: .placedAt)
                    scheduledFor = try? c.decodeIfPresent(Date.self, forKey: .scheduledFor)
                    customerName = try c.decode(String.self, forKey: .customerName)
                    totalGBP     = try c.decode(Double.self, forKey: .totalGBP)
                    itemSummary  = try c.decode(String.self, forKey: .itemSummary)
                    isDelivery   = try c.decode(Bool.self,   forKey: .isDelivery)
                    shortCode    = try? c.decodeIfPresent(String.self, forKey: .shortCode)
                    lines        = try c.decode([LineDTO].self, forKey: .lines)
                    service      = try? c.decodeIfPresent(String.self, forKey: .service)
                    name         = try? c.decodeIfPresent(String.self, forKey: .name)

                    if let s = try? c.decodeIfPresent(Int.self, forKey: .status) {
                        status = s
                    } else if let sStr = try? c.decodeIfPresent(String.self, forKey: .status),
                              let sInt = Int(sStr) {
                        status = sInt
                    } else if let sUpper = try? c.decodeIfPresent(Int.self, forKey: .Status) {
                        status = sUpper
                    } else if let sUpperStr = try? c.decodeIfPresent(String.self, forKey: .Status),
                              let sInt = Int(sUpperStr) {
                        status = sInt
                    } else {
                        status = nil
                    }

                    if let ss = try? c.decodeIfPresent([String:Int].self, forKey: .stationsStatus) {
                        stationsStatus = ss
                    } else if let ssStr = try? c.decodeIfPresent([String:String].self, forKey: .stationsStatus) {
                        var parsed: [String:Int] = [:]
                        for (k, v) in ssStr { if let iv = Int(v) { parsed[k] = iv } }
                        stationsStatus = parsed.isEmpty ? nil : parsed
                    } else {
                        stationsStatus = nil
                    }
                }
            }

            // --- Robust date parser (…Z, fractional, etc.) ---
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { dec in
                let c = try dec.singleValueContainer()
                let s = try c.decode(String.self)

                let isoFrac = ISO8601DateFormatter()
                isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let d = isoFrac.date(from: s) { return d }

                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime]
                if let d = iso.date(from: s) { return d }

                let df = DateFormatter()
                df.calendar = Calendar(identifier: .gregorian)
                df.locale   = Locale(identifier: "en_US_POSIX")
                df.timeZone = TimeZone(secondsFromGMT: 0)
                for f in [
                    "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
                    "yyyy-MM-dd'T'HH:mm:ssXXXXX",
                    "yyyy-MM-dd'T'HH:mm:ss.SSS",
                    "yyyy-MM-dd'T'HH:mm:ss"
                ] {
                    df.dateFormat = f
                    if let d = df.date(from: s) { return d }
                }
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unrecognized date: \(s)")
            }

            // --- Decode ---
            let parsed: ApiResponse
            do {
                parsed = try decoder.decode(ApiResponse.self, from: data)
            } catch {
                let body = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
                print("❌ Decode failed: \(error)\nBody:\n\(body)")
                return
            }

            guard parsed.ok else {
                print("❌ admin/orders returned ok=false")
                return
            }

            // --- Map DTO → view models ---
            let mapped: [KDSAdminOrder] = parsed.orders.map { dto in
                let bs: (bucket: KDSOrderBucket, stage: KDSAdminOrder.Stage) = {
                    if let s = dto.status { return mapStatus(s) }
                    return mapStrings(bucket: dto.bucket, stage: dto.stage)
                }()
                var order = KDSAdminOrder(
                    id: dto.id,
                    source: dto.isDelivery ? .delivery : .kiosk,
                    tableLabel: nil,
                    bucket: bs.bucket,
                    stage: bs.stage,
                    placedAt: dto.placedAt,
                    scheduledFor: dto.scheduledFor,
                    customerName: dto.customerName,
                    totalGBP: dto.totalGBP,
                    itemSummary: dto.itemSummary,
                    isDelivery: dto.isDelivery,
                    shortCode: dto.shortCode,
                    lines: dto.lines.map { l in
                        KDSOrderLine(
                            itemId: l.itemId,
                            productId: l.productId,
                            name: l.name,
                            qty: l.qty,
                            category: l.category,
                            status: l.status,
                            station: l.station,
                            modifiers: l.modifiers
                        )
                    },
                    service: dto.service?.lowercased(),
                    name: dto.name?.lowercased()
                )
                if let ss = dto.stationsStatus {
                    var dict: [Station:Int] = [:]
                    for (k,v) in ss {
                        if let st = stationFromString(k) { dict[st] = v }
                    }
                    order.stationStatus = dict
                }
                return order
            }

            // Debug sample
            if let o = mapped.first(where: { $0.id == 2862 }) {
                let stations = o.stations.map(\.rawValue).joined(separator: ",")
                let ss = o.stationStatus.map { "\($0.key.rawValue)=\($0.value)" }.joined(separator: ",")
                let cats = o.lines.map { $0.category ?? "nil" }.joined(separator: " | ")
                print("🧪 2862 stations=\(stations)  stationStatus={\(ss)}")
                print("🧪 2862 categories=\(cats)")
            }
            print("✅ Loaded \(mapped.count) orders, first statuses:", mapped.prefix(5).map { $0.stage })

            // === Compute to-print set (no placedAt gating) ===
            let previousById = Dictionary(uniqueKeysWithValues: self.all.map { ($0.id, $0) })

            // Heuristic station extraction for an order
            @inline(__always)
            func stationsForOrder(_ o: KDSAdminOrder) -> Set<Station> {
                var s = Set(o.lines.compactMap { lineStation($0) })
                if s.isEmpty {
                    // Fallback: name-based heuristic (Bar)
                    let BAR_NAME_KEYS: [String] = [
                        heNorm("קפה"), heNorm("אספרסו"), heNorm("אמריקנו"),
                        heNorm("קפוצינו"), heNorm("קפוצ'ינו"), heNorm("לאטה"),
                        heNorm("שתיה"), heNorm("שתייה"), heNorm("משקה"),
                        "latte","espresso","americano","capuccino","cappuccino",
                        "drink","beverage","tea","chai","matcha","mocha"
                    ]
                    let anyBarish = o.lines.contains { ln in
                        let t = heNorm(ln.name)
                        return BAR_NAME_KEYS.contains(where: { t.contains($0) })
                    }
                    if anyBarish { s.insert(.bar) }
                }
                return s
            }

            // Station gating predicate for current UI tab
            @inline(__always)
            func matchesCurrentStation(_ o: KDSAdminOrder) -> Bool {
                let sts = stationsForOrder(o)
                switch stationFilter {
                case .all:
                    return true
                case .kitchen:
                    return sts.contains(.kitchen)
                case .bar:
                    return sts.contains(.bar)
                case .bakery:                  // 👈 NEW
                    return sts.contains(.bakery)
                }
            }

            var toPrint: [KDSAdminOrder] = []

            for cur in mapped {
                // only Active & not picked up
                guard cur.bucket == .active, cur.stage != .pickedUp else { continue }

                // station gating by current UI tab (with heuristics)
                guard matchesCurrentStation(cur) else {
                    let stText = stationsForOrder(cur).map(\.rawValue).joined(separator: ",")
                  //  print("⏭️ Skip \(cur.id): stations=[\(stText)] not matching \(stationFilter.rawValue)")
                    continue
                }

                if previousById[cur.id] == nil {
                    // first time seen → print
                  //  print("🆕 First-seen ID → print \(cur.id)")
                    toPrint.append(cur)
                } else if let prev = previousById[cur.id] {
                    // activation transition (e.g., Scheduled -> Active) → print once
                    if prev.bucket != .active && cur.bucket == .active {
                     //   print("🔁 Activated → print \(cur.id) (prev=\(prev.bucket) → cur=active)")
                        toPrint.append(cur)
                    } else if let uiStation = stationFromFilter(stationFilter) {
                        // Optional: station-delta print — when order first touches current station
                        let prevStations = Set(prev.lines.compactMap { lineStation($0) })
                        let curStations  = stationsForOrder(cur)
                        if !prevStations.contains(uiStation) && curStations.contains(uiStation) {
                          //  print("🔀 Station-delta → print \(cur.id) (newly touches \(uiStation.rawValue))")
                            toPrint.append(cur)
                        }
                    }
                }
            }

            // === Mutate state AFTER computing toPrint ===
            self.all = mapped
            self.lastServerLoad = Date()
            guard allowAutoPrint else {
                     //  print("⏸️  Skipping auto-print (startup delay active)")
                       return
                   }
            // 🔔 Auto-print (deduped)
            if !toPrint.isEmpty {
                let currentStationFilter = self.stationFilter
                var actuallyQueued: [Int] = []

                for ord in toPrint {
                    let key = "\(ord.id)|\(currentStationFilter.rawValue)"
                    if !printedKeys.contains(key) {
                        PrinterManager.shared.print(order: ord, for: currentStationFilter)
                        printedKeys.insert(key)
                        actuallyQueued.append(ord.id)
                    } else {
                      ///  print("🛑 Dedupe: \(ord.id) already printed for \(currentStationFilter.rawValue)")
                    }
                }

                if !actuallyQueued.isEmpty {
                    playAlertSound()
                //    print("🔔 Auto-printed:", actuallyQueued)
                } else {
                 //   print("ℹ️ Nothing new to send after dedupe.")
                }
            } else {
             //   print("ℹ️ No orders qualified for printing this cycle.")
            }

        } catch {
          //  print("❌ admin/orders network error:", error.localizedDescription)
        }
    }

    var filtered: [KDSAdminOrder] {
        var list = all.filter { $0.bucket == filter }

        // Station filter
        switch stationFilter {
        case .all:
            break

        case .kitchen, .bar, .bakery:   // 👈 add .bakery here
            guard let target = stationFromFilter(stationFilter) else { return list }
            list = list.filter { $0.stations.contains(target) }
        }
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !q.isEmpty {
            list = list.filter {
                "\($0.id)\($0.customerName)\($0.itemSummary)".lowercased().contains(q)
            }
        }

        switch filter {
        case .active, .completed:
            return list.sorted { $0.placedAt > $1.placedAt }
        case .scheduled:
            return list.sorted { ($0.scheduledFor ?? $0.placedAt) < ($1.scheduledFor ?? $1.placedAt) }
        }
    }
}

// MARK: - Row

struct KDSOrderRow: View {
    let order: KDSAdminOrder
    let visibleLines: [KDSOrderLine]
    let currentStation: Station?    // pass stationFromFilter(vm.stationFilter)

    // Map a code → (label, fg, bg)
    private func labelColors(for code: Int) -> (String, Color, Color) {
        switch code {
        case 5: return ("Collected", .gray,   .gray.opacity(0.15))
        case 4: return ("Ready",     .purple, .purple.opacity(0.15))
        case 2: return ("In Progress", .indigo, .indigo.opacity(0.15))
        default: return ("New", .blue, .blue.opacity(0.15))
        }
    }

    // Single chip view (station-specific or global)
    
    // Station code helper (defaults to 1 if not present)
    private func stationCode(_ st: Station) -> Int {
        order.stationStatus[st] ?? 1
    }

    // Status area: station-aware
    

    // Small pill
   
    var body: some View {
        HStack(spacing: 12) {
            VStack(spacing: 6) {
                // #ID + optional customer name (only if exists)
                VStack(spacing: 2) {
                    Text("#" + String(order.id))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))

                  
                }

                // Inline chips row: TA (if any) + status in the SAME row
                HStack(spacing: 6) {
                    if (order.service ?? "") == "ta" {
                        Text("TA")
                            .font(.system(size: 10, weight: .heavy, design: .rounded))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.orange)
                            .clipShape(Capsule())
                    }
                    // Existing status chip view
                //    statusArea
                }
            }
            .frame(width: 100, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
          
         
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    let trimmedName = order.customerName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmedName.isEmpty && trimmedName.lowercased() != "customer" {
                        // ✅ Real name
                        Text(trimmedName)
                            .font(.system(size: 16, weight: .semibold))
                    } else if order.source == .kiosk {
                        // ✅ Kiosk label fallback
                        Text(order.tableLabel ?? "Tap station")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    Spacer()
                    
                }

                Text(summary(for: visibleLines))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Image(systemName: order.source == .delivery ? "bicycle" : "takeoutbag.and.cup.and.straw")
                    Text(order.placedAt.formatted(date: .omitted, time: .shortened))
                }
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - White GroupBox style for the sheet

struct WhiteGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            configuration.content
        }
        .padding(12)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
       // .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.gray.opacity(0.12)))
      //  .shadow(color: .black.opacity(0.04), radius: 3, y: 2)
    }
}

// MARK: - Quick Sheet (Binding-based)


private struct SheetHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct KDSOrderQuickSheet: View {
    @Binding var order: KDSAdminOrder
    var onOpenFull: () -> Void
    var onPrint: (() -> Void)? = nil
    var onChangeStatus: (Int) async -> Bool
    private var allItemsCollected: Bool { order.lines.allSatisfy { $0.status == 5 } }
    @Environment(\.dismiss) private var dismiss
    @State private var isAdvancing = false
    @State private var measuredContentHeight: CGFloat = 480

    @AppStorage("LastStationFilter") private var lastStationRaw: String = StationFilter.all.rawValue
    private var sidebarStation: Station? { stationFromFilter(StationFilter(rawValue: lastStationRaw) ?? .all) }

    private var allVisibleReady: Bool {
        visibleLines.allSatisfy { $0.status >= 4 }
    }
    private var allVisibleCollected: Bool {
        visibleLines.allSatisfy { $0.status == 5 }
    }

    private var displayName: String {
        let trimmed = order.customerName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed.lowercased() != "customer" {
            // real name from kiosk / delivery
            return trimmed
        }

        // Kiosk fallback (e.g. "Tap station", "Table 5", etc.)
        if order.source == .kiosk, let label = order.tableLabel, !label.isEmpty {
            return label
        }

        return ""
    }
    
    private var buttonTitle: String {
        if allVisibleCollected { return "Collected" }
        if allVisibleReady     { return "Mark Collected" }
        return "Mark Ready"
    }
    private var buttonColor: Color {
        if allVisibleCollected { return .gray }
        if allVisibleReady     { return .purple }
        return .green
    }
    private var isActionDisabled: Bool { isAdvancing || allVisibleCollected }
    // MARK: - Visible Lines
    private var visibleLines: [KDSOrderLine] {
        if let st = sidebarStation {
            return order.lines.filter { lineStation($0) == st }  // ✅ station from API (fallback category)
        } else {
            return order.lines
        }
    }

    // MARK: - Helpers
    private func stationStatusLabel(for code: Int) -> (String, Color) {
        switch code {
        case 5: return ("Collected", .gray)
        case 4: return ("Ready", .purple)
        case 2: return ("In Progress", .indigo)
        default: return ("New", .blue)
        }
    }

    private func lineStatus(for line: KDSOrderLine) -> (String, Color) {
        switch line.status {
        case 5: return ("Collected", .gray)
        case 4: return ("Ready", .purple)
        case 2: return ("In Progress", .indigo)
        default: return ("New", .blue)
        }
    }

    private var currentCode: Int {
        if let st = sidebarStation {
            return order.stationStatus[st] ?? 1
        } else {
            switch order.stage {
            case .pickedUp: return 5
            case .ready: return 4
            case .inProgress: return 2
            case .received: return 1
            }
        }
    }

  
   

    
   
    // MARK: - Advance Logic
    private func advance() {
        guard !isAdvancing, let _ = sidebarStation else { return }
        isAdvancing = true

        // Decide next target for the visible set
        let target = allVisibleReady ? 5 : 4

        // Prepare ids for backend (prefer itemIds; fallback productIds)
        let itemIds = visibleLines.compactMap { $0.itemId }
        let productIds = visibleLines.compactMap { $0.productId }

        // Optimistic UI: update the visible lines’ statuses
        withAnimation {
            for idx in 0..<order.lines.count {
                let l = order.lines[idx]
                if visibleLines.contains(where: { $0.itemId == l.itemId || ($0.itemId == nil && $0.productId == l.productId && $0.name == l.name) }) {
                    order.lines[idx].status = target
                }
            }
        }

        // Build request
        var body: [String: Any] = [
            "miniAppId": 12,
            "status": target
        ]
        if !itemIds.isEmpty {
            body["itemIds"] = itemIds
        } else if !productIds.isEmpty {
            body["productIds"] = productIds
        } else if let st = sidebarStation {
            // last resort: station category targeting (works if your API supports "station")f
            body["station"] = st.rawValue.lowercased()
        }

        Task {
            var req = URLRequest(url: URL(string: "https://minis.studio/api/admin/orders/12/status")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            _ = try? await URLSession.shared.data(for: req)
            isAdvancing = false
        }
    }

    // MARK: - View
    var body: some View {
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        let screenH = UIScreen.main.bounds.height
        let headerAllowance: CGFloat = isPad ? 110 : 90
        let minH: CGFloat = isPad ? 480 : 320
        let maxFraction: CGFloat = isPad ? 0.92 : 0.80
        let desired = measuredContentHeight + headerAllowance
        let clamped = min(max(desired, minH), screenH * maxFraction)

        VStack(spacing: 0) {
            Capsule()
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 36, height: 5)
                .padding(.top, 8)

            // Header with buttons + customer name
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 12) {
                    Text("#" + String(order.id))
                        .font(.system(size: isPad ? 32 : 28, weight: .bold))
                    Spacer()
                    if sidebarStation == nil {
                        // ✅ All stations → one overall checkbox (no button)
                        Image(systemName: allItemsCollected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(allItemsCollected ? Color.green : Color.secondary)
                    } else {
                        // Station view → action button as before
                        HStack(spacing: 10) {
                            // 🖨 Print button on the left
                            Button {
                                onPrint?()   // triggers the closure you already passed from OrdersAdminView
                            } label: {
                                Label("Print", systemImage: "printer.fill")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.white)
                                    .frame(height: 50)
                                    .padding(.horizontal, 14)
                                    .background(Color.gray) // or .blue / .black — choose your theme
                                    .cornerRadius(8)
                            }

                            // ✅ Existing advance button
                            Button(action: advance) {
                                Label(buttonTitle, systemImage: "checkmark.circle.fill")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.white)
                                    .frame(height: 50)
                                    .padding(.horizontal, 14)
                                    .background(buttonColor)
                                    .cornerRadius(8)
                            }
                            .disabled(isActionDisabled)
                            .opacity(isActionDisabled ? 0.6 : 1)
                        }
                    }
                }

                // 🔹 Customer name / label under the ID
                if !displayName.isEmpty {
                    Text(displayName)
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundColor(.primary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)

            // Scrollable content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Items").font(.headline)
                                Spacer()
                                /*
                                Button {
                                    dismiss()
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                        onOpenFull()
                                    }
                                } label: {
                                    Label("Full details", systemImage: "doc.text.magnifyingglass")
                                        .font(.subheadline.weight(.semibold))
                                }
                                 */
                            }

                            HStack {
                                Text("Item").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                                Spacer()
                                Text("Status").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                                Text("Qty").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                                    .frame(width: 36, alignment: .trailing)
                            }
                            .padding(.vertical, 4)

                            ForEach(visibleLines) { line in
                                let (statusText, statusColor) = lineStatus(for: line)
                                HStack(spacing: 10) {
                                    // LEFT: name + modifiers
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(line.name)
                                            .font(.body)
                                        if let mods = line.modifiers?.trimmingCharacters(in: .whitespacesAndNewlines),
                                           !mods.isEmpty {
                                            Text(mods)
                                                .font(.footnote)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                        }
                                    }

                                    Spacer()

                                    if sidebarStation == nil {
                                        Text(statusText)
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundColor(statusColor)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 3)
                                            .background(statusColor.opacity(0.1))
                                            .clipShape(Capsule())
                                    } else {
                                        Image(systemName: line.status >= 4 ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 16, weight: .semibold))
                                            .foregroundStyle(line.status >= 4 ? .green : .secondary)
                                    }

                                    Text("\(line.qty)")
                                        .font(.body.weight(.semibold))
                                        .frame(width: 36, alignment: .trailing)
                                }
                                .padding(.vertical, 6)
                                Divider().opacity(0.08)
                            }
                        }
                    }
                }
                .padding(16)
                .padding(.bottom, 8)
                .background(
                    GeometryReader { g in
                        Color.clear.preference(key: SheetHeightKey.self, value: g.size.height)
                    }
                )
            }
        }
        .onPreferenceChange(SheetHeightKey.self) { measuredContentHeight = $0 }
        .groupBoxStyle(WhiteGroupBoxStyle())
        .presentationDetents([.height(clamped)])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(isPad ? 18 : 12)
    }
}

// MARK: - Detail

struct KDSOrderDetailView: View {
    let order: KDSAdminOrder

    private var orderIdText: String { "#" + String(order.id) }
    private var totalText: String { "£" + String(format: "%.2f", order.totalGBP) }

    var body: some View {
        List {
            Section {
                LabeledContent("Order ID", value: orderIdText)
                LabeledContent("Customer", value: order.customerName.isEmpty ? "Guest" : order.customerName)
                LabeledContent("Type", value: order.isDelivery ? "Delivery" : "Collection")
                if let s = order.scheduledFor {
                    LabeledContent("Scheduled", value: s.formatted(date: .abbreviated, time: .shortened))
                } else {
                    LabeledContent("Placed", value: order.placedAt.formatted(date: .abbreviated, time: .shortened))
                }
                LabeledContent("Status", value: order.bucket.rawValue)
            } header: {
                Text("Order details").textCase(nil)
            }

            Section {
                ForEach(order.lines) { line in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(line.name)
                            Spacer()
                            Text("×\(line.qty)")
                                .foregroundStyle(.secondary)
                        }
                        if let mods = line.modifiers?.trimmingCharacters(in: .whitespacesAndNewlines),
                           !mods.isEmpty {
                            Text(mods)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                    }
                    .padding(.vertical, 4)
                }
                HStack {
                    Text("Total").font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Text(totalText)
                        .font(.system(size: 18, weight: .bold))
                        .monospacedDigit()
                }
                .padding(.top, 6)
            } header: {
                Text("Items").textCase(nil)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.white)
        .navigationTitle(orderIdText)
    }
}

// MARK: - iPhone Main Screen (as before)

struct OrdersAdminView: View {
    @StateObject private var vm = KDSOrdersVM()
    @State private var path: [KDSAdminOrder] = []
    @State private var quick: KDSAdminOrder? = nil
    @Environment(\.layoutDirection) private var layout
    @Environment(\.isRtl) private var isRtl
    @State private var poll = Timer.publish(every: 5, tolerance: 1, on: .main, in: .common).autoconnect()


    @State private var selectedTab: AdminTab = .orders

    @State private var showStatusSheet = false
    @State private var searchExpanded = false
    @FocusState private var searchFocused: Bool

    @State private var showSidebar = false
    @Environment(\.dismiss) private var dismiss
    
    @ViewBuilder
    private func actionButton(_ order: KDSAdminOrder,
                              label: String,
                              color: Color,
                              target: Int) -> some View {

        Button {
            Task {
                _ = await vm.setStatus(orderId: order.id, to: target, miniAppId: 12)
            }
        } label: {
            Text(label)
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 150, height: 50)     // <<< FIXED SIZE
                .background(color)
                .cornerRadius(16)                  // <<< ROUNDED CORNERS
        }
        .buttonStyle(.plain)
    }
    
    var body: some View {
        NavigationStack(path: $path) {
            ZStack(alignment: .topLeading) {

                // === Main content switches by selectedTab ===
                Group {
                    switch selectedTab {
                    case .orders:
                        VStack(spacing: 0) {
                            HStack(spacing: 10) {
                                if searchExpanded {
                                    Button {
                                        withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                                            vm.search = ""
                                            searchExpanded = false
                                            searchFocused = false
                                        }
                                    } label: {
                                        Image(systemName: "chevron.left")
                                            .font(.system(size: 16, weight: .semibold))
                                    }

                                    HStack(spacing: 8) {
                                        Image(systemName: "magnifyingglass")
                                            .foregroundStyle(.secondary)
                                        TextField("Search by name, item, #", text: $vm.search)
                                            .textInputAutocapitalization(.never)
                                            .autocorrectionDisabled()
                                            .focused($searchFocused)
                                        if !vm.search.isEmpty {
                                            Button { vm.search = "" } label: {
                                                Image(systemName: "xmark.circle.fill")
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 10)
                                    .background(Color(.secondarySystemBackground))
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                    .transition(.move(edge: .leading).combined(with: .opacity))

                                } else {
                                    Button {
                                        withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                                            searchExpanded = true
                                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                                searchFocused = true
                                            }
                                        }
                                    } label: {
                                        HStack(spacing: 6) {
                                            Image(systemName: "magnifyingglass")
                                            Text("חיפוש")
                                        }
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(.primary)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 10)
                                        .background(Color(.secondarySystemBackground))
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                    }
                                    .buttonStyle(.plain)
                                }

                                Button {
                                    showStatusSheet = true
                                } label: {
                                    Text(vm.filter.rawValue)
                                        .font(.system(size: 14, weight: .semibold))
                                        .frame(maxWidth: .infinity, alignment: .center)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 10)
                                        .background(
                                            RoundedRectangle(cornerRadius: 12)
                                                .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
                                        )
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .sheet(isPresented: $showStatusSheet) {
                                    StatusPickerSheet(selected: $vm.filter)
                                        .presentationDetents([.height(240)])
                                }
                            }
                            .padding(.horizontal)
                            .padding(.top, 8)
                            .padding(.bottom, 6)

                            List {
                                if vm.filtered.isEmpty {
                                    Text("No orders yet")
                                } else {
                                    Section {
                                        ForEach(vm.filtered) { order in
                                            HStack {
                                                KDSOrderRow(
                                                    order: order,
                                                    visibleLines: filteredLines(order, for: vm.stationFilter),
                                                    currentStation: stationFromFilter(vm.stationFilter)
                                                )

                                                // ↘️ NEW quick action button
                                                if let code = globalStatusCode(from: order.lines) {
                                                    if code == 1 || code == 2 {   // New / In progress
                                                        actionButton(order, label: isRtl ? "מוכן" : "Ready", color: .green, target: 4)
                                                    } else if code == 4 {         // Ready
                                                        actionButton(order, label: isRtl ? "סגור" : "Collected", color: .black, target: 5)
                                                    }
                                                }
                                            }
                                            .contentShape(Rectangle())
                                            .onTapGesture { quick = order }
                                        }
                                    }
                                }
                            }
                            .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
                            .refreshable {
                                await vm.load()
                            }
                            .listStyle(.plain)
                           
                        }
                        .navigationTitle(selectedTab.title)
                        // 🔁 poll every 5s
                                .onReceive(poll) { _ in
                                    Task { await vm.load() }
                                }
                                .task { await vm.load() }
                    case .stock:
                        StockView()
                            .navigationTitle(selectedTab.title)
                    }
                }
                .onAppear {
                    // pick the current shop ID you already use
                    let miniId = Int(UserDefaults.standard.string(forKey: "shopId") ?? "0") ?? 0
                   // AdminDeviceRegistrar.registerIfNeeded(miniAppId: miniId)
                }

                // Sidebar overlay (phone)
                if showSidebar {
                    Color.black.opacity(0.28)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) { showSidebar = false }
                        }
                        .transition(.opacity)

                    SideBar(
                        current: selectedTab,
                        onPick: { tab in
                            selectedTab = tab
                            showSidebar = false
                        },
                        onClose: { showSidebar = false },
                        stationFilter: $vm.stationFilter           // ⬅️ NEW
                    )
                    .frame(width: 260)
                    .offset(x: showSidebar ? 0 : -280)
                    .transition(.move(edge: .leading))
                   
                }
            }
            .toolbar {
                // existing leading sidebar toggle...
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { showSidebar.toggle() }
                    } label: {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.black)
                    }
                }

                // ✅ new trailing close button
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                    .accessibilityLabel("Close")
                }
            }
            .sheet(item: $quick) { selected in
                if let idx = vm.all.firstIndex(where: { $0.id == selected.id }) {
                    KDSOrderQuickSheet(
                        order: $vm.all[idx],
                        onOpenFull: { path.append(vm.all[idx]) },
                        onPrint: {
                            // Reuse the same station scope the user is viewing
                            let stFilter = vm.stationFilter
                            PrinterManager.shared.print(order: vm.all[idx], for: stFilter)
                        },
                        onChangeStatus: { newStatus in
                            await vm.setStatus(orderId: vm.all[idx].id, to: newStatus, miniAppId: 12)
                        }
                    )
                    .groupBoxStyle(WhiteGroupBoxStyle())
                    .background(Color.white)
                }
            }
            .navigationDestination(for: KDSAdminOrder.self) { order in
                KDSOrderDetailView(order: order)
            }
        }
    }
}

// MARK: - Sidebar (shared)







/// Map a Hebrew category name → Station


private enum SidebarTab: String, CaseIterable {
    case orders = "הזמנות"
    case stock  = "מלאי"

    var title: String { rawValue }
    var icon: String {
        switch self {
        case .orders: return "list.bullet"
        case .stock:  return "shippingbox"
        }
    }
}

struct SideBar: View {
    let current: AdminTab
    let onPick: (AdminTab) -> Void
    let onClose: () -> Void
    @Binding var stationFilter: StationFilter
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
           

            VStack(alignment: .leading, spacing: 6) {
                SideItem(
                    title: "הזמנות",
                    systemImage: "list.bullet.rectangle",
                    isActive: current == .orders
                ) { onPick(.orders) }

                SideItem(
                    title: "מלאי",
                    systemImage: "shippingbox",
                    isActive: current == .stock
                ) { onPick(.stock) }
                VStack(alignment: .leading, spacing: 12) {
                    Text("תחנות")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)

                    ForEach(StationFilter.allCases) { s in
                        Button {
                            stationFilter = s
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName:
                                      s == .all     ? "square.stack.3d.up.fill" :
                                      s == .kitchen ? "fork.knife" :
                                                      "wineglass")   // Bar
                                    .font(.system(size: 16, weight: .semibold))
                                Text(s.rawValue).font(.system(size: 16, weight: .semibold))
                                Spacer()
                                if stationFilter == s {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(Color.black)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 16)
               
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)

            Spacer()
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.white)
    }

    @ViewBuilder
    private func SideItem(title: String, systemImage: String, isActive: Bool, tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.black)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        
      
        
    }
}

// MARK: - Status Picker (sheet)

struct StatusPickerSheet: View {
    @Binding var selected: KDSOrderBucket
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 36, height: 5)
                .padding(.top, 8)
                .padding(.bottom, 10)

            Text("Status")
                .font(.system(size: 17, weight: .semibold))
                .padding(.bottom, 12)

            VStack(spacing: 8) {
                ForEach(KDSOrderBucket.allCases) { bucket in
                    Button {
                        selected = bucket
                        dismiss()
                    } label: {
                        HStack {
                            Text(bucket.rawValue)
                                .font(.system(size: 16, weight: .medium))
                            Spacer()
                            if selected == bucket {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.accentColor)
                                    .font(.system(size: 18, weight: .bold))
                            }
                        }
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(selected == bucket
                                      ? Color.accentColor.opacity(0.08)
                                      : Color(.secondarySystemBackground))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity)
        .background(Color.white.ignoresSafeArea())
    }
}

// MARK: - iPad Adaptive Container

struct AdminRoot: View {
    var body: some View {
        if isPad {
            AdminSplitViewPad()
        } else {
            OrdersAdminView()
        }
    }
}

/// iPad split: left tools + middle list + right detail
struct AdminSplitViewPad: View {
    @StateObject private var ordersVM = KDSOrdersVM()
    @State private var selectedTab: AdminTab = .orders
    @State private var selectedOrder: KDSAdminOrder? = nil
    @State private var showQuickPopover = false
    let isPad = UIDevice.current.userInterfaceIdiom == .pad
    var body: some View {
        NavigationSplitView {

            SidebarPanel(
                selectedTab: $selectedTab,
                search: $ordersVM.search,
                status: $ordersVM.filter,
                station: $ordersVM.stationFilter
            )
            .navigationTitle("MINIS")
        } content: {
            switch selectedTab {
            case .orders:
                OrdersListPane(
                    vm: ordersVM,
                    selection: $selectedOrder,
                    onQuick: { selectedOrder = $0; showQuickPopover = true }
                )
                .navigationTitle("הזמנות")
            case .stock:
                StockView()
                    .navigationTitle("מלאי")
            }
        } detail: {
            if selectedTab == .orders {
                if let order = selectedOrder {
                    KDSOrderDetailView(order: order)
                } else {
                    ContentUnavailableView("Select an order", systemImage: "list.bullet.rectangle", description: Text("Choose an order to see details."))
                }
            } else {
                ContentUnavailableView("No item selected", systemImage: "shippingbox", description: Text("Pick a product from Stock."))
            }
        }
        .popover(isPresented: $showQuickPopover, arrowEdge: .top) {
            if let order = selectedOrder,
               let idx = ordersVM.all.firstIndex(where: { $0.id == order.id }) {
                KDSOrderQuickSheet(
                    order: $ordersVM.all[idx],
                    onOpenFull: {
                        showQuickPopover = false
                        selectedOrder = ordersVM.all[idx]
                    },
                    onPrint: { /* print */ },
                    onChangeStatus: { newStatus in
                        // 🔹 Call your new API function in the ViewModel
                        await ordersVM.setStatus(
                            orderId: ordersVM.all[idx].id,
                            to: newStatus,
                            miniAppId: 12   // or your actual MiniApp ID
                        )
                    }
                )
                .frame(minWidth: 420, minHeight: 380)
            }
        }
    }
}

/// iPad left rail
private struct SidebarPanel: View {
    @Binding var selectedTab: AdminTab
    @Binding var search: String
    @Binding var status: KDSOrderBucket
    @FocusState private var searchFocused: Bool
    @Binding var station: StationFilter

    var body: some View {
        List {
            // Tabs
            Section {
                tabRow(.orders, title: "הזמנות", systemImage: "list.bullet.rectangle")
                tabRow(.stock,  title: "מלאי",  systemImage: "shippingbox")
            }

            // Filters
            Section("Filter") {
                Picker("Status", selection: $status) {
                    ForEach(KDSOrderBucket.allCases) { s in
                        Text(s.rawValue).tag(s)
                    }
                }
                .pickerStyle(.segmented)

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search by name, item, #", text: $search)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($searchFocused)
                    if !search.isEmpty {
                        Button { search = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .contentShape(Rectangle())
            }
        }
        .listStyle(.sidebar)
        
        Section("Stations") {
            Picker("Station", selection: $station) {
                ForEach(StationFilter.allCases) { s in
                    Text(s.rawValue).tag(s)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    @ViewBuilder
    private func tabRow(_ tab: AdminTab, title: String, systemImage: String) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { selectedTab = tab }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                if selectedTab == tab {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.accentColor)
                }
            }
            .contentShape(Rectangle()) // whole row tappable
        }
        .buttonStyle(.plain)
        .listRowBackground(
            (selectedTab == tab ? Color.accentColor.opacity(0.08) : Color.clear)
        )
        .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
    }
}
/// iPad center list
private struct OrdersListPane: View {
    @ObservedObject var vm: KDSOrdersVM
    @Binding var selection: KDSAdminOrder?
    var onQuick: (KDSAdminOrder) -> Void

    var body: some View {
        List(vm.filtered, selection: $selection) { order in
            HStack {
                KDSOrderRow(
                    order: order,
                    visibleLines: filteredLines(order, for: vm.stationFilter),
                    currentStation: stationFromFilter(vm.stationFilter)     // ⬅️ NEW
                )
                Spacer()
                Button {
                    onQuick(order)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 18, weight: .semibold))
                }
                .buttonStyle(.plain)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                selection = order
            }
        }
        .listStyle(.plain)
        .refreshable {
            try? await Task.sleep(nanoseconds: 350_000_000)
        }
    }
}

extension Notification.Name {
    static let refreshOrders = Notification.Name("refreshOrders")
}
