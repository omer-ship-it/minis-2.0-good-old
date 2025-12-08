import Foundation
import SwiftUI
import Darwin   // for getifaddrs / inet_ntop

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

        // We only care about Wi-Fi (en0) and Ethernet-style bridge (bridge100)
        guard name == "en0" || name == "bridge100" else { continue }

        // Only IPv4
        guard interface.ifa_addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }

        // Cast sockaddr -> sockaddr_in
        let addrInPtr = withUnsafePointer(to: interface.ifa_addr.pointee) {
            $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0 }
        }

        var addr4 = addrInPtr.pointee.sin_addr

        // Convert binary address -> string
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
        case itemId
        case productId
        case name
        case qty
        case category
        case status
        case station
        case modifiers
        case modifiersUpper = "Modifiers"   // DB / JSON field
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        itemId    = try c.decodeIfPresent(Int.self,    forKey: .itemId)
        productId = try c.decodeIfPresent(Int.self,    forKey: .productId)
        name      = try c.decode(String.self,          forKey: .name)
        qty       = try c.decode(Int.self,             forKey: .qty)
        category  = try c.decodeIfPresent(String.self, forKey: .category)
        status    = try c.decode(Int.self,             forKey: .status)
        station   = try c.decodeIfPresent(String.self, forKey: .station)

        // 🔑 accept both "modifiers" and "Modifiers"
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

    // 👇 NEW
    let service: String?

    enum CodingKeys: String, CodingKey {
        case id, source, bucket, stage, placedAt, scheduledFor,
             customerName, customerDisplayName, totalGBP, itemSummary,
             isDelivery, shortCode, lines, status
        case Status = "Status"
        // 👇 support both cases, like in BonesOrderDTO
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

        // 👇 NEW: read service if present, safe if missing
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

    /// Claim endpoint (server uses SentToPrinterAt / PrintedAt)
    private let claimURLBase   = "https://minis.studio/api/admin/orders/claim-to-print"

    /// Printed endpoint (marks PrintedAt on server)
    private let printedURLBase = "https://minis.studio/api/admin/orders"

    /// Orders we've already printed in this app run (extra safety)
    private var printedOrderIds: Set<Int> = []

    /// Background polling task (timer loop)
    private var pollTask: Task<Void, Never>?

    /// Current polling interval (seconds) – tweak as needed
    private var currentInterval: TimeInterval = 5   // fast polling for claim

    // Lightweight internal order + line model for printing
    private struct SimpleLine {
        let id: Int
        let name: String
        let quantity: Int
        let unitPrice: Double
        let category: String?
        let modifiers: String?      // 👈 NEW
    }

    private struct SimpleOrder {
        let id: Int
        let source: String
        let customerName: String
        let subtitle: String
        let total: Double
        let placedAt: Date
        let items: [SimpleLine]

        // 👇 NEW
        let service: String?
        let isDelivery: Bool
    }

    // MARK: - Public API

    /// Start polling every `interval` seconds.
    func startPolling(interval: TimeInterval = 5) {
        guard pollTask == nil else { return }   // already running

        currentInterval = interval
        print("🟢 OrdersAutoPrinter.startPolling(interval=\(interval))")

        pollTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce(trigger: "timer")
                let ns = UInt64(interval * 1_000_000_000)
                try? await Task.sleep(nanoseconds: ns)
            }
        }
    }

    /// Stop the background polling loop.
    func stopPolling() {
        print("🔴 OrdersAutoPrinter.stopPolling()")
        pollTask?.cancel()
        pollTask = nil
    }

    /// Backwards-compatible alias used by older code.
    func startBackgroundPolling() {
        startPolling(interval: 5)
    }

    /// Called from AppDelegate silent push + NotificationCenter(.orderReady)
    func handleSilentPush(userInfo: [AnyHashable: Any]) async {
        print("📡 OrdersAutoPrinter.handleSilentPush userInfo:", userInfo)
        await pollOnce(trigger: "silentPush")
    }

    // MARK: - Poll

    private func pollOnce(trigger: String) async {
        guard miniAppId > 0 else { return }

        // 🔒 Guard per tick: only work when LAN IP is in the allowed prefix
        if let ip = currentLANIPv4() {
            if !ip.hasPrefix("10.100.10.") {   // <-- home test; in prod use "10.100.10."
                print("ℹ️ [OrdersAutoPrinter] pollOnce: LAN IP \(ip) not allowed prefix → skipping this poll")
                return
            }
        } else {
            print("ℹ️ [OrdersAutoPrinter] pollOnce: no LAN IPv4 (en0/bridge100) → skipping this poll")
            return
        }

        guard let url = URL(string: "\(claimURLBase)?miniAppId=\(miniAppId)") else {
            print("❌ OrdersAutoPrinter: bad claim URL")
            return
        }

        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"                         // 👈 claim is POST
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
                for format in [
                    "yyyy-MM-dd'T'HH:mm:ss.SSS",
                    "yyyy-MM-dd'T'HH:mm:ss"
                ] {
                    df.dateFormat = format
                    if let d = df.date(from: s) { return d }
                }

                throw DecodingError.dataCorruptedError(
                    in: c,
                    debugDescription: "Unrecognized date: \(s)"
                )
            }

            let parsed = try decoder.decode(AutoOrdersApiResponse.self, from: data)
            guard parsed.ok else {
                print("❌ OrdersAutoPrinter: ok=false")
                return
            }

            // These orders were already claimed (SentToPrinterAt set) on the server
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

        // Map DTOs to simple orders
        let mapped: [SimpleOrder] = dtos.map { dto in

            let displayName: String = {
                if let dn = dto.customerDisplayName, !dn.isEmpty {
                    return dn
                }
                return dto.customerName
            }()

            let totalQty = max(1, dto.lines.reduce(0) { $0 + max($1.qty, 1) })
            let perUnit  = totalQty > 0 ? dto.totalGBP / Double(totalQty) : dto.totalGBP

            let items: [SimpleLine] = dto.lines.enumerated().map { idx, l in
                SimpleLine(
                    id: l.itemId ?? l.productId ?? idx,
                    name: l.name,
                    quantity: max(l.qty, 1),
                    unitPrice: perUnit,
                    category: l.category,
                    modifiers: l.modifiers
                )
            }

            return SimpleOrder(
                id: dto.id,
                source: dto.source,
                customerName: displayName,
                subtitle: dto.itemSummary,
                total: dto.totalGBP,
                placedAt: dto.placedAt,
                items: items,
                service: dto.service,        // 👈 NEW
                isDelivery: dto.isDelivery   // 👈 NEW
            )
        }

        // Optional extra guard: only kiosk-ish sources
        let kioskSources: Set<String> = ["mini", "kiosk", "appclip", "fastlane"]

        let newOrders = mapped.filter { order in
            let srcLower = order.source.lowercased()
            guard kioskSources.contains(srcLower) else { return false }

            if printedOrderIds.contains(order.id) {
                print("⚠️ [OrdersAutoPrinter] order #\(order.id) already printed this run, skipping")
                return false
            }
            return true
        }

        guard !newOrders.isEmpty else {
            print("ℹ️ [OrdersAutoPrinter] no new orders after local filtering (trigger=\(trigger))")
            return
        }

        for order in newOrders {
            Task {
                await self.printAndMark(order: order, trigger: trigger)
            }
        }
    }

    // MARK: - Print + markPrinted

    private func printAndMark(order: SimpleOrder, trigger: String) async {
        print("🖨 [OrdersAutoPrinter] AUTO PRINT #\(order.id) (src=\(order.source)) trigger=\(trigger)")

        let entries = toBasketEntries(from: order)
        let mode    = diningMode(for: order)

        PrinterManager.shared.printCashPointSplit(
            orderNumber: order.id,
            entries: entries,
            total: order.total,
            diningMode: mode,
            customerName: order.customerName
        )

        printedOrderIds.insert(order.id)
        await markPrinted(orderId: order.id)
    }

    // MARK: - /printed call

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
            } else {
                print("⚠️ [OrdersAutoPrinter] markPrinted(\(orderId)) no HTTPURLResponse")
            }
        } catch {
            print("❌ [OrdersAutoPrinter] markPrinted(\(orderId)) network error:", error.localizedDescription)
        }
    }

    // MARK: - Helpers used by printing

    private func toBasketEntries(from order: SimpleOrder) -> [BasketEntry] {
        order.items.map { li in
            BasketEntry(
                id: li.id,
                item: ShellMenuItem(
                    id: li.id,
                    name: li.name,
                    price: li.unitPrice,
                    category: li.category ?? "",
                    modifiers: nil,
                    imageURL: nil,
                    description: nil
                ),
                quantity: li.quantity,
                subtitle: li.modifiers,   // 👈 now goes into KDSOrderLine.modifiers
                unitPrice: li.unitPrice
            )
        }
    }

    private func diningMode(for order: SimpleOrder) -> DiningMode {
        // 1) Explicit service field (from Metadata → API)
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

        // 2) Fallback: API isDelivery flag
       

        // 3) Legacy heuristic from subtitle, for old orders
        if order.subtitle.contains("לקחת") ||
           order.subtitle.localizedCaseInsensitiveContains("take away") {
            return .takeAway
        }

        // 4) Default
        return .dineIn
    }
}
