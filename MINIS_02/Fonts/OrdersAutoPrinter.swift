import Foundation
import SwiftUI
import Darwin   // getifaddrs / inet_ntop

// MARK: - LAN IPv4 helper (Wi-Fi en0 / Ethernet bridge100)

func currentLANIPv4() -> String? {
    var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?

    guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else {
        return nil
    }
    defer { freeifaddrs(ifaddrPtr) }

    for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
        let interface = ptr.pointee
        let name = String(cString: interface.ifa_name)

        // We only care about Wi-Fi (en0) and Ethernet bridge (bridge100)
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
    let station: String?     // NOTE: this field holds routing (Printer/printer/station collapsed)
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

        // ✅ FIX: Prefer per-product Printer fields first. station is fallback.
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

    enum CodingKeys: String, CodingKey {
        case id, source, bucket, stage, placedAt, scheduledFor,
             customerName, customerDisplayName, totalGBP, itemSummary,
             isDelivery, shortCode, lines, status
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

    private let miniAppId = 12
    private let claimURLBase   = "https://minis.studio/api/admin/orders/claim-to-print"
    private let printedURLBase = "https://minis.studio/api/admin/orders"

    private var printedOrderIds: Set<Int> = []
    private var pollTask: Task<Void, Never>?
    private var currentInterval: TimeInterval = 5

    private struct SimpleLine {
        let id: Int
        let productId: Int?
        let name: String
        let quantity: Int
        let unitPrice: Double
        let category: String?
        let modifiers: String?
        let station: String           // ✅ canonical: "kitchen" / "bar" / "bakery"
    }

    private struct SimpleOrder {
        let id: Int
        let source: String
        let bucket: String
        let customerName: String
        let subtitle: String
        let total: Double
        let placedAt: Date
        let items: [SimpleLine]
        let service: String?
        let isDelivery: Bool
    }

    // MARK: - Public API

    func startPolling(interval: TimeInterval = 5) {
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

    func startBackgroundPolling() { startPolling(interval: 5) }

    func handleSilentPush(userInfo: [AnyHashable: Any]) async {
        await pollOnce(trigger: "silentPush")
    }

    // MARK: - Poll

    private func pollOnce(trigger: String) async {
        guard miniAppId > 0 else { return }

        if let ip = currentLANIPv4() {
            guard ip.hasPrefix("10.100.10.") else { return }
        } else {
            return
        }

        guard let url = URL(string: "\(claimURLBase)?miniAppId=\(miniAppId)") else {
            print("❌ OrdersAutoPrinter: bad claim URL")
            return
        }

        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                print("❌ OrdersAutoPrinter: no HTTPURLResponse")
                return
            }
            guard http.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
                print("❌ OrdersAutoPrinter claim HTTP \(http.statusCode)\n\(body)")
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
                print("❌ OrdersAutoPrinter: ok=false")
                return
            }

            processFetchedOrders(parsed.orders, trigger: trigger)
        } catch {
            print("❌ OrdersAutoPrinter network error:", error.localizedDescription)
        }
    }

    // MARK: - Mapping + print logic

    private func processFetchedOrders(_ dtos: [AutoOrderDTO], trigger: String) {
        guard !dtos.isEmpty else {
            print("ℹ️ [OrdersAutoPrinter] no claimed orders to print (trigger=\(trigger))")
            return
        }

        // Kiosk sources only
        let allowedSources: Set<String> = ["mini", "kiosk", "appclip", "fastlane"]

        // Block CashPoint/POS
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
            print("ℹ️ [OrdersAutoPrinter] all claimed orders filtered out (trigger=\(trigger))")
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
                let resolved = resolvePrinter(productId: l.productId, station: l.station)
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
                subtitle: dto.itemSummary,
                total: dto.totalGBP,
                placedAt: dto.placedAt,
                items: items,
                service: dto.service,
                isDelivery: dto.isDelivery
            )
        }

        let newOrders = mapped.filter { order in
            !printedOrderIds.contains(order.id)
        }

        guard !newOrders.isEmpty else {
            print("ℹ️ [OrdersAutoPrinter] no new orders after local filtering (trigger=\(trigger))")
            return
        }

        for order in newOrders {
            Task { await self.printAndMark(order: order, trigger: trigger) }
        }
    }

    // MARK: - Routing

    private func normalizePrinter(_ s: String?) -> String? {
        let raw = (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        switch raw.lowercased() {
        case "מטבח", "kitchen": return "kitchen"
        case "בר", "bar":       return "bar"
        case "מאפה", "קונדיטוריה", "bakery": return "bakery"
        default:
            let cleaned = raw.lowercased()
            if cleaned.contains("kitchen") { return "kitchen" }
            if cleaned.contains("bakery")  { return "bakery"  }
            if cleaned.contains("bar")     { return "bar"     }
            return nil
        }
    }

    // ✅ Simple + safe: API printer wins if present, else catalog, else bar.
    private func resolvePrinter(productId: Int?, station: String?) -> String {
        // 1️⃣ Catalog (your shop json) is the truth
        if let cat = normalizePrinter(MenuCatalog.shared.printer(for: productId)) {
            return cat
        }

        // 2️⃣ Fallback: whatever server sent (Printer/station)
        if let api = normalizePrinter(station) {
            return api
        }

        // 3️⃣ Last resort
        return "bar"
    }

    // MARK: - Print + markPrinted

    private func printAndMark(order: SimpleOrder, trigger: String) async {
        print("🖨 [OrdersAutoPrinter] AUTO PRINT #\(order.id) trigger=\(trigger)")

        let entries = toBasketEntries(from: order)
        let mode    = diningMode(for: order)

        let grouped = Dictionary(grouping: entries) { e in
            normalizePrinter(e.item.printer) ?? "bar"
        }

        print("🧾 AUTO PRINT order #\(order.id) groups=\(grouped.keys.sorted()) totalEntries=\(entries.count)")
        print("🧾 AUTO groups:", grouped.map { "\($0.key)=\($0.value.count)" }.sorted().joined(separator: ", "))

        for (printer, list) in grouped {
            print("   • group=\(printer) lines=\(list.count)")
            for e in list {
                print("     - \(e.quantity)x \(e.item.name) printer=\(e.item.printer ?? "nil")")
            }

            PrinterManager.shared.printCashPointSplit(
                orderNumber: order.id,
                entries: list,
                total: list.reduce(0.0) { $0 + (Double($1.quantity) * $1.unitPrice) },
                diningMode: mode,
                customerName: order.customerName
            )
        }

        printedOrderIds.insert(order.id)
        await markPrinted(orderId: order.id)
    }

    private func markPrinted(orderId: Int) async {
        guard let url = URL(string: "\(printedURLBase)/\(orderId)/printed?miniAppId=\(miniAppId)") else {
            print("❌ markPrinted: bad URL for order \(orderId)")
            return
        }

        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 200 {
                    print("✅ [OrdersAutoPrinter] markPrinted(\(orderId)) OK")
                } else {
                    print("⚠️ [OrdersAutoPrinter] markPrinted(\(orderId)) HTTP \(http.statusCode)")
                }
            }
        } catch {
            print("❌ [OrdersAutoPrinter] markPrinted(\(orderId)) network error:", error.localizedDescription)
        }
    }

    private func toBasketEntries(from order: SimpleOrder) -> [BasketEntry] {
        order.items.enumerated().map { idx, li in
            let pid = li.productId

            // canonical printer for this line
            let resolvedPrinter =
                normalizePrinter(MenuCatalog.shared.printer(for: pid))
                ?? normalizePrinter(li.station)
                ?? "bar"

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
                        printer: resolvedPrinter
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
                    printer: resolvedPrinter
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
        if let svc = order.service?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            switch svc {
            case "ta", "takeaway", "take_away", "take-away":
                return .takeAway
            case "sit", "table", "ls":
                return .dineIn
            default:
                break
            }
        }

        if order.subtitle.contains("לקחת") ||
            order.subtitle.localizedCaseInsensitiveContains("take away") {
            return .takeAway
        }

        return .dineIn
    }
}
