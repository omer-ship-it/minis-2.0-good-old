import Foundation
import SwiftUI

// MARK: - DTOs for /api/admin/orders

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

    enum CodingKeys: String, CodingKey {
        case id, source, bucket, stage, placedAt, scheduledFor,
             customerName, customerDisplayName, totalGBP, itemSummary,
             isDelivery, shortCode, lines, status
        case Status = "Status"
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
    }
}

// MARK: - Background auto printer

@MainActor
final class OrdersAutoPrinter {
    static let shared = OrdersAutoPrinter()

    private init() {}

    private let miniAppId = 12
    private let baseURL   = "https://minis.studio/api/admin/orders"

    /// Orders we've already printed in this app run
    private var printedOrderIds: Set<Int> = []

    /// Has the first successful fetch already seeded printedOrderIds?
    private var hasSeededPrintedIds = false

    /// Background polling task (timer loop)
    private var pollTask: Task<Void, Never>?

    /// Current polling interval (seconds) – just for debug
    private var currentInterval: TimeInterval = 60

    // Lightweight internal order + line model for printing
    private struct SimpleLine {
        let id: Int
        let name: String
        let quantity: Int
        let unitPrice: Double
        let category: String?
    }

    private struct SimpleOrder {
        let id: Int
        let source: String
        let customerName: String
        let subtitle: String
        let total: Double
        let placedAt: Date
        let items: [SimpleLine]
    }

    // MARK: - Public API

    /// New API: start polling every `interval` seconds.
    func startPolling(interval: TimeInterval = 60) {
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
        startPolling(interval: 60)
    }

    /// Called from AppDelegate silent push + NotificationCenter(.orderReady)
    func handleSilentPush(userInfo: [AnyHashable: Any]) async {
        print("📡 OrdersAutoPrinter.handleSilentPush userInfo:", userInfo)
        await pollOnce(trigger: "silentPush")
    }

    // MARK: - Poll

    private func pollOnce(trigger: String) async {
        guard miniAppId > 0 else { return }

        guard let url = URL(string: "\(baseURL)?miniAppId=\(miniAppId)") else {
            print("❌ OrdersAutoPrinter: bad URL")
            return
        }

        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                print("❌ OrdersAutoPrinter: no HTTPURLResponse")
                return
            }
            guard http.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
                print("❌ OrdersAutoPrinter HTTP \(http.statusCode)\n\(body)")
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

            processFetchedOrders(parsed.orders, trigger: trigger)
        } catch {
            print("❌ OrdersAutoPrinter network error:", error.localizedDescription)
        }
    }

    // MARK: - Mapping + print logic

    private func processFetchedOrders(_ dtos: [AutoOrderDTO], trigger: String) {
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
                    category: l.category  // 👈 PRESERVE CATEGORY HERE
                )
            }

            return SimpleOrder(
                id: dto.id,
                source: dto.source,
                customerName: displayName,
                subtitle: dto.itemSummary,
                total: dto.totalGBP,
                placedAt: dto.placedAt,
                items: items
            )
        }

        // 1) First successful fetch: seed baseline, no printing
        if !hasSeededPrintedIds {
            printedOrderIds = Set(mapped.map { $0.id })
            hasSeededPrintedIds = true
            print("🧩 [OrdersAutoPrinter] seeded baseline with \(printedOrderIds.count) orders (trigger=\(trigger))")
            return
        }

        // 2) Only print non-cashpoint orders that are *new*
        let newOrders = mapped.filter { order in
            let srcLower = order.source.lowercased()
            let isCash   = (srcLower == "cashpoint" || srcLower == "קופה")
            return !isCash && !printedOrderIds.contains(order.id)
        }

        guard !newOrders.isEmpty else {
            print("ℹ️ [OrdersAutoPrinter] no new orders to print (trigger=\(trigger))")
            return
        }

        for order in newOrders {
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
                    category: li.category ?? "",   // 👈 PASS REAL CATEGORY INTO SHELLMENUITEM
                    modifiers: nil,
                    imageURL: nil,
                    description: nil
                ),
                quantity: li.quantity,
                subtitle: nil,
                unitPrice: li.unitPrice
            )
        }
    }

    private func diningMode(for order: SimpleOrder) -> DiningMode {
        if order.subtitle.contains("לקחת") { return .takeAway }
        return .dineIn
    }
}
