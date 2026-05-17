import Foundation
import SwiftUI
import Darwin   // getifaddrs / inet_ntop

// MARK: - LAN IPv4 helper (Wi-Fi en0 / Ethernet bridge100)

func currentLANIPv4() -> String? {
    var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?

    guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else { return nil }
    defer { freeifaddrs(ifaddrPtr) }

    for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
        let interface = ptr.pointee
        let name = String(cString: interface.ifa_name)

        guard name == "en0" || name == "bridge100" else { continue }
        guard interface.ifa_addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }

        let addrInPtr = withUnsafePointer(to: interface.ifa_addr.pointee) {
            $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0 }
        }

        var addr4 = addrInPtr.pointee.sin_addr
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &addr4, &buffer, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buffer)
    }

    return nil
}

// MARK: - DTOs for /api/admin/orders/claim-to-print

private struct AutoOrdersApiResponse: Decodable {
    let ok: Bool
    let count: Int
    let orders: [AutoOrderDTO]
}

private struct AutoLineDTO: Decodable {
    let itemId: Int?
    let productId: Int?
    let name: String
    let qty: Int
    let category: String?
    let status: Int
    let station: String?
    let modifiers: String?

    enum CodingKeys: String, CodingKey {
        case itemId, productId, name, qty, category, status

        // routing variants
        case station
        case printer = "Printer"
        case printerLower = "printer"

        // modifiers variants
        case modifiers
        case modifiersUpper = "Modifiers"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        itemId    = try c.decodeIfPresent(Int.self,    forKey: .itemId)
        productId = try c.decodeIfPresent(Int.self,    forKey: .productId)
        name      = try c.decode(String.self,          forKey: .name)
        qty       = try c.decode(Int.self,             forKey: .qty)
        category  = try c.decodeIfPresent(String.self, forKey: .category)
        status    = try c.decode(Int.self,             forKey: .status)

        let p1 = try? c.decodeIfPresent(String.self, forKey: .printer)
        let p2 = try? c.decodeIfPresent(String.self, forKey: .printerLower)
        let st = try? c.decodeIfPresent(String.self, forKey: .station)
        station = p1 ?? p2 ?? st

        if let m = try c.decodeIfPresent(String.self, forKey: .modifiers) {
            modifiers = m
        } else if let m = try c.decodeIfPresent(String.self, forKey: .modifiersUpper) {
            modifiers = m
        } else {
            modifiers = nil
        }
    }
}

private struct ClaimDTO: Decodable {
    let token: String?
}

private struct AutoOrderDTO: Decodable {
    let id: Int
    let source: String
    let bucket: String
    let stage: String
    let placedAt: Date
    let scheduledFor: Date?
    let customerName: String
    let customerDisplayName: String?
    let totalGBP: Double
    let itemSummary: String
    let isDelivery: Bool
    let shortCode: String?
    let lines: [AutoLineDTO]
    let status: Int?
    let service: String?
    let customerPhone: String?
    let claim: ClaimDTO?

    enum CodingKeys: String, CodingKey {
        case id, source, bucket, stage, placedAt, scheduledFor
        case customerName, customerDisplayName, customerPhone
        case totalGBP, itemSummary
        case isDelivery, shortCode, lines, status
        case claim
        case Status = "Status"
        case service
        case Service = "Service"
        
        
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
        customerDisplayName = try? c.decodeIfPresent(String.self, forKey: .customerDisplayName)
        totalGBP     = try c.decode(Double.self, forKey: .totalGBP)
        itemSummary  = try c.decode(String.self, forKey: .itemSummary)
        isDelivery   = try c.decode(Bool.self,   forKey: .isDelivery)
        shortCode    = try? c.decodeIfPresent(String.self, forKey: .shortCode)
        lines        = try c.decode([AutoLineDTO].self, forKey: .lines)
        customerPhone = try? c.decodeIfPresent(String.self, forKey: .customerPhone)

        // ✅ NEW: claim (token)
        claim = try? c.decodeIfPresent(ClaimDTO.self, forKey: .claim)

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

        service = (try? c.decodeIfPresent(String.self, forKey: .service))
              ?? (try? c.decodeIfPresent(String.self, forKey: .Service))
    }
}

// MARK: - Background auto printer

@MainActor
final class OrdersAutoPrinter {
    static let shared = OrdersAutoPrinter()
    private init() {}

    private var miniAppId: Int {
        let v = UserDefaults.standard.integer(forKey: "miniAppId")
        return v > 0 ? v : 0
    }

    private var adminPickupLocation: String {
        UserDefaults.standard.string(forKey: "admin.pickupLocation") ?? "cafeteria"
    }
    private let claimURLBase   = "https://minis.studio/api/admin/orders/claim-to-print-by-location"
    private let printedURLBase = "https://minis.studio/api/admin/orders"

    private var printedOrderIds: Set<Int> = []
    private var pollTask: Task<Void, Never>?
    private var currentInterval: TimeInterval = 5

    private func makeClaimURL() -> URL? {
        guard miniAppId > 0 else { return nil }

        var comps = URLComponents(string: claimURLBase)
        var q: [URLQueryItem] = [
            .init(name: "miniAppId", value: String(miniAppId))
        ]

        // ✅ Only miniAppId 13 uses location filtering
        if miniAppId == 13 {
            let loc = adminPickupLocation.trimmingCharacters(in: .whitespacesAndNewlines)
            if !loc.isEmpty {
                q.append(.init(name: "pickupLocation", value: loc))
            }
        }

        comps?.queryItems = q
        return comps?.url
    }
    
    private struct SimpleLine {
        let id: Int
        let productId: Int?
        let name: String
        let quantity: Int
        let unitPrice: Double
        let category: String?
        let modifiers: String?
        let station: String
    }

    private func isToastName(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.contains("טוסט") { return true }
        if t.lowercased().contains("toast") { return true }
        return false
    }

    private struct SimpleOrder {
        let id: Int
        let source: String
        let bucket: String
        let customerName: String
        let customerPhone: String?
        let subtitle: String
        let total: Double
        let placedAt: Date
        let items: [SimpleLine]
        let service: String?
        let isDelivery: Bool

        // ✅ token returned from backend claim
        let claimToken: String?
    }

    // MARK: - ClientId helper (shared with backend headers)

    private func printerClientId() -> String {
        let key = "printer.clientId"
        if let existing = UserDefaults.standard.string(forKey: key),
           !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return existing
        }
        let newId = UUID().uuidString
        UserDefaults.standard.set(newId, forKey: key)
        return newId
    }

    // MARK: - Public API

    func startPolling(interval: TimeInterval = 15) {
        guard pollTask == nil else { return }
        currentInterval = interval

        pollTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce(trigger: "timer")
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func startBackgroundPolling() { startPolling(interval: 15) }

    func handleSilentPush(userInfo: [AnyHashable: Any]) async {
        await pollOnce(trigger: "silentPush")
    }

    // MARK: - Poll

    private func pollOnce(trigger: String) async {
        guard miniAppId > 0 else { return }

        // ⛓️ The previous version short-circuited polling entirely when the
        //     iPad's LAN IP didn't match the shop's `10.100.10.x` subnet.
        //     That was silently dropping orders on the floor whenever the
        //     iPad got a different DHCP lease, switched WiFi, or had a brief
        //     network blip — no log, no retry. The right gate is the print
        //     itself: PrinterManager already fails fast when no printer is
        //     reachable, and the bounded print-retry handles transient
        //     blips. So we just log the current IP for debugging and let
        //     the poll proceed regardless of the subnet.
        let lanIP = currentLANIPv4() ?? "unknown"
        print("[OrdersAutoPrinter] 📡 pollOnce trigger=\(trigger) lanIP=\(lanIP) miniAppId=\(miniAppId)")

        guard let url = makeClaimURL() else {
            return
        }
        if miniAppId == 13 {
        }


        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        // ✅ send client id so server stores PrintClaimedBy
        req.setValue(printerClientId(), forHTTPHeaderField: "X-Printer-ClientId")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return
            }
            guard http.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
                return
            }

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
                df.timeZone = TimeZone.current
                for format in ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss"] {
                    df.dateFormat = format
                    if let d = df.date(from: s) { return d }
                }

                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unrecognized date: \(s)")
            }

            let parsed = try decoder.decode(AutoOrdersApiResponse.self, from: data)
            guard parsed.ok else {
                return
            }

            await processFetchedOrders(parsed.orders, trigger: trigger)

        } catch {
        }
    }

    // MARK: - Mapping + print logic

    private func processFetchedOrders(_ dtos: [AutoOrderDTO], trigger: String) async {
        guard !dtos.isEmpty else {
            return
        }

        let allowedSources: Set<String> = ["mini", "kiosk", "appclip", "fastlane"]
        let blockedBuckets: Set<String> = ["cashpoint", "pos", "admin"]
        let blockedSources: Set<String> = ["cashpoint", "pos", "register", "till", "admin"]

        let filteredDTOs = dtos.filter { dto in
            let src    = dto.source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let bucket = dto.bucket.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let stage  = dto.stage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

            if blockedBuckets.contains(bucket) { return false }
            if blockedSources.contains(src) { return false }

            let hay = "\(src) \(bucket) \(stage)"
            if hay.contains("cashpoint") || hay.contains("pos") || hay.contains("register") || hay.contains("till") {
                return false
            }

            return allowedSources.contains(src)
        }

        guard !filteredDTOs.isEmpty else {
            return
        }

        let mapped: [SimpleOrder] = filteredDTOs.map { dto in
            let displayName: String = {
                if let dn = dto.customerDisplayName, !dn.isEmpty { return dn }
                return dto.customerName
            }()

            let totalQty = max(1, dto.lines.reduce(0) { $0 + max($1.qty, 1) })
            let perUnit  = totalQty > 0 ? dto.totalGBP / Double(totalQty) : dto.totalGBP

            let items: [SimpleLine] = dto.lines.enumerated().map { idx, l in
                let ids = resolveStationIds(productId: l.productId, station: l.station, name: l.name)
                // keep first for now (or you can support multi later)
                let resolved = ids.first ?? "s2"

                return SimpleLine(
                    id: l.itemId ?? idx,
                    productId: l.productId,
                    name: l.name,
                    quantity: max(l.qty, 1),
                    unitPrice: perUnit,
                    category: l.category,
                    modifiers: l.modifiers,
                    station: resolved
                )
            }

            return SimpleOrder(
                id: dto.id,
                source: dto.source,
                bucket: dto.bucket,
                customerName: displayName,
                customerPhone: dto.customerPhone,
                subtitle: dto.itemSummary,
                total: dto.totalGBP,
                placedAt: dto.placedAt,
                items: items,
                service: dto.service,
                isDelivery: dto.isDelivery,
                claimToken: dto.claim?.token   // ✅ NEW
            )
        }

        let newOrders = mapped.filter { order in
            !printedOrderIds.contains(order.id)
        }

        guard !newOrders.isEmpty else {
            return
        }

        for order in newOrders {
            await printAndMark(order: order, trigger: trigger)
        }
    }

    // MARK: - Routing

    private func normalizePrinter(_ s: String?) -> String? {
        let raw = (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        let t = raw.lowercased()

        // ✅ NEW: station ids
        if t == "s1" { return "kitchen" }
        if t == "s2" { return "bar" }
        if t == "s3" { return "bakery" }

        switch t {
        case "מטבח", "kitchen": return "kitchen"
        case "בר", "bar":       return "bar"
        case "מאפה", "קונדיטוריה", "bakery": return "bakery"
        default:
            if t.contains("kitchen") { return "kitchen" }
            if t.contains("bakery")  { return "bakery" }
            if t.contains("bar")     { return "bar" }
            return nil
        }
    }

    private func normalizeToStationIds(_ s: String?) -> [String] {
        let raw = (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !raw.isEmpty else { return [] }

        // already station id
        if raw.hasPrefix("s"), raw.count >= 2 { return [raw] }

        // legacy words
        switch raw {
        case "מטבח", "kitchen": return ["s1"]
        case "בר", "bar":       return ["s2"]
        case "מאפה", "קונדיטוריה", "bakery": return ["s3"]
        default:
            if raw.contains("kitchen") { return ["s1"] }
            if raw.contains("bakery")  { return ["s3"] }
            if raw.contains("bar")     { return ["s2"] }
            return []
        }
    }
    
    private func resolveStationIds(productId: Int?, station: String?, name: String) -> [String] {
        if isToastName(name) { return ["s1"] }

        // ✅ 1) MenuCatalog is authoritative
        if let pid = productId, let item = MenuCatalog.shared.item(for: pid) {

            if let ps = item.printers, !ps.isEmpty {
                let cleaned = ps.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                let sids = cleaned.filter { $0.hasPrefix("s") }
                if !sids.isEmpty { return sids }
            }

            // legacy single printer may already be "s3"
            let p = (item.printer ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if p.hasPrefix("s") { return [p] }

            // legacy words
            let legacy = normalizeToStationIds(item.printer)
            if !legacy.isEmpty { return legacy }
        }

        // ✅ 2) API station
        let api = normalizeToStationIds(station)
        if !api.isEmpty { return api }

        // ✅ 3) final fallback
        return ["s2"]
    }
    
    
    // MARK: - Print + markPrinted

    /// Back-off delays between print attempts (in seconds).
    /// 0 = first attempt, then 3s, 10s, 30s before the next try.
    /// Total worst-case wall time before giving up: ~43 s, which still
    /// leaves the server-side claim valid (orders are eligible for up
    /// to 5 minutes from PlacedAt) and avoids stale-state on the iPad.
    /// Server is unchanged: the order stays claimed by this iPad the
    /// whole time, so no other iPad will pick it up while we retry.
    private static let printRetryDelaysSeconds: [UInt64] = [3, 10, 30]

    private func printAndMark(order: SimpleOrder, trigger: String) async {
        let entries = toBasketEntries(from: order)
        let mode    = diningMode(for: order)

        // Try up to 1 + retries.count = 4 attempts. Most failures are a
        // transient printer/network blip and clear on the first retry.
        var ok = false
        var attemptIndex = 0
        let maxAttempts = Self.printRetryDelaysSeconds.count + 1

        while attemptIndex < maxAttempts {
            ok = await PrinterManager.shared.printCashPointSplit(
                orderNumber: order.id,
                entries: entries,
                total: order.total,
                diningMode: mode,
                customerName: order.customerName,
                customerPhone: order.customerPhone,
                showMinisRow: true   // auto-printer = app/auto order → show MINIS
            )

            if ok { break }

            // Last attempt: don't sleep, just fall out to the failure log.
            if attemptIndex == maxAttempts - 1 { break }

            let delay = Self.printRetryDelaysSeconds[attemptIndex]
            print("[OrdersAutoPrinter] ⚠️ print attempt \(attemptIndex + 1)/\(maxAttempts) FAILED orderId=\(order.id) — retrying in \(delay)s trigger=\(trigger)")
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            attemptIndex += 1
        }

        guard ok else {
            // All attempts exhausted. Order stays SentToPrinterAt-set on
            // the server; manual reprint or DB intervention required.
            // The pre-existing [printCashPointSplit] log inside
            // PrinterManager tells us which station kept failing.
            let _ts = ISO8601DateFormatter().string(from: Date())
            print("[OrdersAutoPrinter] ❌ printAndMark gave up after \(maxAttempts) attempts orderId=\(order.id) trigger=\(trigger) total=\(order.total) ts=\(_ts)")
            return
        }

        let marked = await markPrinted(orderId: order.id, claimToken: order.claimToken)
        if marked {
            print("[OrdersAutoPrinter] ✅ printed+marked orderId=\(order.id) trigger=\(trigger) attempts=\(attemptIndex + 1) ts=\(ISO8601DateFormatter().string(from: Date()))")
            printedOrderIds.insert(order.id)
        } else {
            // Edge case: print succeeded but server rejected the markPrinted POST
            print("[OrdersAutoPrinter] ⚠️ printed but markPrinted FAILED orderId=\(order.id) trigger=\(trigger) ts=\(ISO8601DateFormatter().string(from: Date()))")
        }
    }

    private func markPrinted(orderId: Int, claimToken: String?) async -> Bool {
        var comps = URLComponents(string: "\(printedURLBase)/\(orderId)/printed")!
        comps.queryItems = [
            URLQueryItem(name: "miniAppId", value: String(miniAppId))
        ]

        if let t = claimToken?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            comps.queryItems?.append(URLQueryItem(name: "token", value: t))
        }

        guard let url = comps.url else {
            return false
        }

        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(printerClientId(), forHTTPHeaderField: "X-Printer-ClientId")

        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 200 {
                    return true
                } else {
                }
            }
        } catch {
        }

        return false
    }

    // MARK: - Mapping to BasketEntry (unchanged)

    private func toBasketEntries(from order: SimpleOrder) -> [BasketEntry] {
        order.items.enumerated().map { idx, li in
            let pid = li.productId

            // li.station is already resolved to "sX", but we keep this robust:
            let stationIds = resolveStationIds(productId: pid, station: li.station, name: li.name)
            let resolvedSid = stationIds.first ?? "s2"

            let item: ShellMenuItem = {
                if let menuItem = MenuCatalog.shared.item(for: pid) {
                    return ShellMenuItem(
                        id: menuItem.id,
                        name: menuItem.name,
                        price: menuItem.price,
                        category: menuItem.category,
                        modifiers: menuItem.modifiers,
                        imageURL: menuItem.imageURL,
                        description: menuItem.description,
                        status: menuItem.status,
                        stockQuantity: menuItem.stockQuantity,
                        printer: resolvedSid,
                        printers: stationIds    // ✅ optional but good (if your initializer includes it)
                    )
                }

                return ShellMenuItem(
                    id: pid ?? (li.id + 10_000),
                    name: li.name,
                    price: li.unitPrice,
                    category: li.category ?? "",
                    modifiers: nil,
                    imageURL: nil,
                    description: nil,
                    status: nil,
                    stockQuantity: nil,
                    printer: resolvedSid,
                    printers: stationIds     // ✅ optional but good
                )
            }()

            return BasketEntry(
                id: idx + 1,
                item: item,
                quantity: li.quantity,
                subtitle: li.modifiers,
                unitPrice: li.unitPrice
            )
        }
    }

    private func diningMode(for order: SimpleOrder) -> DiningMode {

        func norm(_ s: String) -> String {
            s.trimmingCharacters(in: .whitespacesAndNewlines)
             .replacingOccurrences(of: "\u{200F}", with: "")
             .replacingOccurrences(of: "\u{200E}", with: "")
             .replacingOccurrences(of: "\u{00A0}", with: " ")
             .lowercased()
        }

        if let raw = order.service, !raw.isEmpty {
            let svc = norm(raw)
            if svc == "ta" || svc.contains("take") || svc.contains("pickup") || svc.contains("togo") || svc.contains("to-go") {
                return .takeAway
            }
            if svc == "sit" || svc.contains("dine") || svc.contains("table") {
                return .dineIn
            }
        }

        // ✅ production-safe default for miniAppId 12 auto-print:
        // if service is missing/garbled, assume takeaway.
        if miniAppId == 12 { return .takeAway }

        return .dineIn
    }
}
