import Foundation
import SwiftUI
import PassKit
import StoreKit
import UIKit
import Combine

let primariesFontName = "PrimariesMLAAA-DemiBold"

@MainActor
final class MenuApiModel: ObservableObject {
    @Published var items: [ShellMenuItem] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var version: Int = 0
    @Published var categoryOrder: [String] = []
    
    func load(shopId explicit: String? = nil, skipCache: Bool = false) {
        let miniAppIdFromDefaults = UserDefaults.standard.integer(forKey: "miniAppId")
        let storedShopId = UserDefaults.standard.string(forKey: "shopId")

        let shopId: String
        if let explicit = explicit, !explicit.isEmpty {
            shopId = explicit
        } else if miniAppIdFromDefaults > 0 {
            shopId = String(miniAppIdFromDefaults)
        } else if let storedShopId, !storedShopId.isEmpty {
            shopId = storedShopId
        } else {
            //print("❌ MenuApiModel.load → no explicit, no miniAppId, no stored shopId → aborting load")
            errorMessage = "No shop selected"
            return
        }

       // print("🛒 MenuApiModel.load → using shopId=\(shopId) (explicit=\(explicit ?? "nil"), miniAppId=\(miniAppIdFromDefaults), storedShopId=\(storedShopId ?? "nil"))")

        let t = Int(Date().timeIntervalSince1970)
        guard let url = URL(string: "https://minis.studio/json/\(shopId).json?\(t)") else {
            errorMessage = "Invalid URL"
            return
        }

        let cacheKey = "MenuJSON_\(shopId)"
        let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("shop_\(shopId).json")

        isLoading = true
        errorMessage = nil

        if !skipCache, items.isEmpty {
            if let cachedData = UserDefaults.standard.data(forKey: cacheKey) {
                Task { await parseAndApply(data: cachedData) }
            } else if let cachedFile = try? Data(contentsOf: cacheURL) {
                Task { await parseAndApply(data: cachedFile) }
            }
        }

        URLSession.shared.dataTask(with: url) { [weak self] data, _, err in
            guard let self else { return }

            if let err = err {
                Task { @MainActor in
                    self.isLoading = false
                    if self.items.isEmpty {
                        self.errorMessage = err.localizedDescription
                    }
                }
                return
            }

            guard let data else {
                Task { @MainActor in
                    self.isLoading = false
                    if self.items.isEmpty {
                        self.errorMessage = "No data received"
                    }
                }
                return
            }

           

            UserDefaults.standard.set(data, forKey: cacheKey)
            try? data.write(to: cacheURL)

            Task { await self.parseAndApply(data: data) }
        }.resume()
    }

   
    
    private func applyCategoryOrder(_ items: [ShellMenuItem], order: [String]?) -> [ShellMenuItem] {
        guard let order, !order.isEmpty else { return items }

        // category -> rank
        var rank: [String: Int] = [:]
        for (i, c) in order.enumerated() { rank[c] = i }

        // Stable: categories in order first, then anything missing at the end.
        return items.sorted { a, b in
            let ra = rank[a.category] ?? Int.max
            let rb = rank[b.category] ?? Int.max
            if ra != rb { return ra < rb }

            // same category → keep your existing product sort
            // (use Sort if you have it; otherwise name/id)
            if a.id != b.id { return a.id < b.id }
            return a.name < b.name
        }
    }

    private func parseAndApply(data: Data) async {
        // 0️⃣ First, extract customization (title, subtitle, image, font, direction, currency)
        applyMiniCustomization(from: data)

        do {
            let decoder = JSONDecoder()

            // 1️⃣ Try wrapper: { theme: {...}, products: [...] }
            if let wrapper = try? decoder.decode(ShopPayload.self, from: data) {
                if let order = wrapper.categoryOrder, !order.isEmpty {
                    await MainActor.run {
                        self.categoryOrder = order
                        UserDefaults.standard.set(order, forKey: "categoryOrder")  // optional cache
                    }
                }

                if let products = wrapper.products {
                    let mapped = mapProducts(products)
                    let ordered = applyCategoryOrder(mapped, order: wrapper.categoryOrder)
                    await apply(ordered)
                    saveReferralForCurrentShop(kind: .fastlane)
                    return
                }
            } else {
                print("📦 parseAndApply → ShopPayload decode FAILED, trying plain array")
            }

            // 2️⃣ Fallback: plain [ProductPayload] (old simple format)
            let products = try decoder.decode([ProductPayload].self, from: data)
            print("📦 parseAndApply → decoded plain [ProductPayload] with \(products.count) products")

            #if DEBUG
            if let ceasar = products.first(where: { $0.name.contains("קיסר") }) {
                ceasar.modifiers?.forEach { g in
                    print("  • title=\(g.title ?? "?"), type=\(g.type ?? "nil"), mode=\(g.selection?.mode ?? "nil")")
                }
            }
            #endif

            await apply(mapProducts(products))
            saveReferralForCurrentShop(kind: .fastlane)

        } catch {
            print("❌ parseAndApply JSON error:", error.localizedDescription)
            await MainActor.run {
                errorMessage = "JSON parse error: \(error.localizedDescription)"
                isLoading = false
            }
        }
    }

    private func apply(_ newItems: [ShellMenuItem]) async {
        await MainActor.run {
            items = newItems
            if let first = newItems.first {
               // print("🧪 mapped ShellMenuItem printer:", first.name, "→", first.printer ?? "nil")
            }
            MenuCatalog.shared.update(items: newItems)   // ✅ add
            isLoading = false
            version &+= 1
        }
    }

    private func mapProducts(_ products: [ProductPayload]) -> [ShellMenuItem] {
        products.map {
            ShellMenuItem(
                id: $0.productId,
                name: $0.name,
                price: $0.price,
                category: $0.category,
                modifiers: mapModifiers(from: $0.modifiers),
                imageURL: $0.image,
                description: $0.description,
                status: $0.status,
                stockQuantity: $0.stockQuantity,
                printer: $0.printer          // 👈 NEW
            )
        }
    }

    private func mapModifiers(from apiGroups: [ApiModifierGroup]?) -> [ModifierGroup]? {
        guard let apiGroups, !apiGroups.isEmpty else { return nil }

        let groups = apiGroups.compactMap { g -> ModifierGroup? in
            let items = (g.items ?? []).map {
                ModifierItem(name: $0.optionName ?? "", extraPrice: $0.extraPrice ?? 0)
            }

            let rawType       = g.type?.lowercased()
            let selectionMode = g.selection?.mode?.lowercased()

            let type: ModifierGroup.GroupType
            if rawType == "additions" {
                type = .additions
            } else if rawType == "options" {
                type = .options
            } else if selectionMode == "multi" {
                type = .additions
            } else {
                type = .options
            }

           
            return ModifierGroup(type: type, title: g.title ?? "בחירה", items: items)
        }

        return groups.isEmpty ? nil : groups
    }
}

struct ShopPayload: Decodable {
    struct Theme: Decodable {
        let direction: String?
        let currency: String?
    }

    let theme: Theme?
    let products: [ProductPayload]?
    let categoryOrder: [String]?   // ✅ NEW
}


struct ProductPayload: Decodable {
    let productId: Int
    let name: String
    let price: Double
    let category: String
    let status: Int?
    let stockQuantity: Int?
    let image: String?
    let description: String?
    let modifiers: [ApiModifierGroup]?
    let printer: String?

    enum CodingKeys: String, CodingKey {
        case productId       = "ProductId"
        case name            = "Name"
        case price           = "Price"
        case category        = "Category"
        case status          = "Status"
        case stockQuantity   = "StockQuantity"
        case image           = "Image"
        case description     = "Description"

        case printer         = "Printer"
        case printerLower    = "printer"      // ✅ NEW

        case modifierGroups  = "ModifierGroups"
        case legacyModifiers = "Modifiers"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        productId      = try c.decode(Int.self,    forKey: .productId)
        name           = try c.decode(String.self, forKey: .name)
        price          = try c.decode(Double.self, forKey: .price)
        category       = try c.decode(String.self, forKey: .category)
        status         = try c.decodeIfPresent(Int.self, forKey: .status)
        stockQuantity  = try c.decodeIfPresent(Int.self, forKey: .stockQuantity)
        image          = try c.decodeIfPresent(String.self, forKey: .image)
        description    = try c.decodeIfPresent(String.self, forKey: .description)

        // ✅ accept both spellings
        let p =
            (try? c.decodeIfPresent(String.self, forKey: .printer)) ??
            (try? c.decodeIfPresent(String.self, forKey: .printerLower))

        // ✅ normalize now (critical)
        printer = p?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if let groups = try c.decodeIfPresent([ApiModifierGroup].self, forKey: .modifierGroups) {
            modifiers = groups
        } else {
            modifiers = try c.decodeIfPresent([ApiModifierGroup].self, forKey: .legacyModifiers)
        }
    }
}

struct ApiSelection: Decodable {
    let mode: String?
    let min: Int?
    let max: Int?
}

struct ApiModifierGroup: Decodable {
    let type: String?
    let title: String?
    let items: [ApiModifierItem]?
    let selection: ApiSelection?      // 👈 NEW

    enum CodingKeys: String, CodingKey {
        case type      = "Type"
        case title     = "Title"
        case items     = "Items"
        case selection = "Selection"
    }
}

struct ApiModifierItem: Decodable {
    let optionName: String?
    let extraPrice: Double?

    enum CodingKeys: String, CodingKey {
        case optionName = "OptionName"
        case extraPrice = "ExtraPrice"
    }
}

struct ShellMenuItem: Identifiable {
    let id: Int
    let name: String
    let price: Double
    let category: String
    let modifiers: [ModifierGroup]?
    let imageURL: String?
    let description: String?
    let status: Int?
    let stockQuantity: Int?
    let printer: String?     // 👈 NEW

    var img: URL? {
        if let s = imageURL, !s.isEmpty { return URL(string: s) }
        return nil
    }

    var priceLabel: String { String(format: "%.2f", price) }

    init(
        id: Int,
        name: String,
        price: Double,
        category: String,
        modifiers: [ModifierGroup]?,
        imageURL: String?,
        description: String?,
        status: Int? = nil,
        stockQuantity: Int? = nil,
        printer: String? = nil        // 👈 NEW
    ) {
        self.id = id
        self.name = name
        self.price = price
        self.category = category
        self.modifiers = modifiers
        self.imageURL = imageURL
        self.description = description
        self.status = status
        self.stockQuantity = stockQuantity
        self.printer = printer         // 👈 NEW
    }
}

extension ShellMenuItem {
    var isAvailable: Bool {
        // 0 = out of stock → hide
        if let status = status, status == 0 {
            return false
        }
        // Optional: also hide if stockQuantity is known and <= 0
        if let stock = stockQuantity, stock <= 0 {
            return false
        }
        return true
    }
}

struct ModifierGroup: Identifiable {
    enum GroupType { case options, additions }
    let id = UUID()
    let type: GroupType
    let title: String
    let items: [ModifierItem]
}

struct ModifierItem: Identifiable {
    let id = UUID()
    let name: String
    let extraPrice: Double
}

struct BasketEntry: Identifiable {
    let id: Int
    let item: ShellMenuItem
    var quantity: Int
    var subtitle: String?
    var unitPrice: Double
}

enum DiningMode: String, CaseIterable, Identifiable {
    case dineIn = "Dine in"
    case takeAway = "Take away"
    var id: String { rawValue }
}

struct CategoryPositionKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

struct SheetContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct BasketContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

final class ApplePayHandler: NSObject, PKPaymentAuthorizationControllerDelegate {
    func startPayment(total: Double, note: String? = nil) {
        guard PKPaymentAuthorizationController.canMakePayments(usingNetworks: [.visa, .masterCard, .amex]) else { return }
        let r = PKPaymentRequest()
        r.merchantIdentifier = "merchant.your.identifier"
        r.supportedNetworks = [.visa, .masterCard, .amex]
        r.merchantCapabilities = .capability3DS
        r.countryCode = "GB"
        r.currencyCode = "GBP"
        let amount = NSDecimalNumber(value: total)
        let label = note.map { "Order (\($0))" } ?? "Order"
        r.paymentSummaryItems = [PKPaymentSummaryItem(label: label, amount: amount)]
        let c = PKPaymentAuthorizationController(paymentRequest: r)
        c.delegate = self
        c.present(completion: { _ in })
    }

    func paymentAuthorizationControllerDidFinish(_ controller: PKPaymentAuthorizationController) {
        controller.dismiss(completion: nil)
    }

    func paymentAuthorizationController(
        _ controller: PKPaymentAuthorizationController,
        didAuthorizePayment payment: PKPayment,
        handler completion: @escaping (PKPaymentAuthorizationResult) -> Void
    ) {
        completion(PKPaymentAuthorizationResult(status: .success, errors: nil))
    }
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b, a: UInt64
        switch hex.count {
        case 3:
            (r, g, b, a) = ((int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17, 255)
        case 6:
            (r, g, b, a) = (int >> 16, int >> 8 & 0xFF, int & 0xFF, 255)
        case 8:
            (r, g, b, a) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (r, g, b, a) = (1, 1, 1, 1)
        }
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: Double(a) / 255)
    }
}

struct SegmentedFontModifier: ViewModifier {
    init() {
        let font = UIFont(name: primariesFontName, size: 15)!
        UISegmentedControl.appearance().setTitleTextAttributes([.font: font], for: .normal)
        UISegmentedControl.appearance().setTitleTextAttributes([.font: font], for: .selected)
    }
    func body(content: Content) -> some View { content }
}

extension View {
    func segmentedFontPrimaries() -> some View { modifier(SegmentedFontModifier()) }
}

final class AppStoreSheetPresenter {
    static func present(appId: String) {
        guard
            let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
            let window = scene.windows.first(where: { $0.isKeyWindow }),
            let root = window.rootViewController
        else { return }
        let vc = SKStoreProductViewController()
        vc.loadProduct(withParameters: [SKStoreProductParameterITunesItemIdentifier: appId]) { loaded, _ in
            if loaded { root.present(vc, animated: true) }
        }
    }
}

enum OrderAPI {
    struct SubmitError: Error { let message: String }

    enum PaymentMethod: String {
        case card       // full card
        case cash       // full cash
        case mixed      // split card + cash
        case unpaid     // pay later / on account
    }

    struct PaymentSummary {
        let method: PaymentMethod
        let cashAmount: Double
        let cardAmount: Double
    }

    static func submitOrder(
        orderId: Int? = nil,
        entries: [BasketEntry],
        total: Double,
        diningMode: DiningMode,
        source: String,
        customerName: String? = nil,
        customerPhone: String? = nil,
        payment: PaymentSummary? = nil,
        zcreditMeta: [String: Any]? = nil,
        ticketNumber: Int? = nil,
        othLineIds: Set<Int>? = nil,

        // ✅ NEW (team tabs / special order types)
        orderType: String? = nil,
        tabKey: String? = nil,

        // ✅ NEW: totals breakdown (basket, discount, excluded, final total, etc.)
        totals: [String: Any]? = nil,

        completion: @escaping (Result<Int, Error>) -> Void
    ) {
        let defaults = UserDefaults.standard

        // ---------- helpers ----------
        func r2(_ x: Double) -> Double { (x * 100).rounded() / 100 }
        func closeEnough(_ a: Double, _ b: Double, tol: Double = 0.01) -> Bool { abs(a - b) <= tol }

        func flexDouble(_ any: Any?) -> Double? {
            if let d = any as? Double { return d }
            if let i = any as? Int { return Double(i) }
            if let s = any as? String {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: ",", with: ".")
                return Double(t)
            }
            return nil
        }

        // 🔥 Resolve miniAppId / shopId dynamically
        let miniAppIdFromDefaults = defaults.integer(forKey: "miniAppId")
        let storedShopIdString    = defaults.string(forKey: "shopId")

        let miniAppId: Int
        if miniAppIdFromDefaults > 0 {
            miniAppId = miniAppIdFromDefaults
        } else if
            let s = storedShopIdString,
            let v = Int(s)
        {
            miniAppId = v
        } else {
            completion(.failure(SubmitError(message: "No miniAppId / shopId selected for this order")))
            return
        }

        print("🧾 OrderAPI.submitOrder → miniAppId=\(miniAppId) (miniAppIdFromDefaults=\(miniAppIdFromDefaults), storedShopId=\(storedShopIdString ?? "nil"))")

        let uuid         = defaults.string(forKey: "anonUUID")    ?? UUID().uuidString
        let defaultEmail = defaults.string(forKey: "userEmail")   ?? "customer@example.com"
        let defaultName  = defaults.string(forKey: "userName")    ?? "Customer"

        let effectiveName: String = {
            let trimmed = customerName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? defaultName : trimmed
        }()

        let othSet = othLineIds ?? []

        let basketPayload: [[String: Any]] = entries.map { entry in
            let qty = max(entry.quantity, 0)

            let unitCandidate = (entry.unitPrice > 0) ? entry.unitPrice : entry.item.price
            let unit = unitCandidate

            let isOth = othSet.contains(entry.id)   // ✅ NEW

            return [
                "lineId":    entry.id,              // ✅ helpful for audit/debug
                "productId": entry.item.id,
                "name":      entry.item.name,
                "quantity":  qty,
                "unitPrice": unit,
                "lineTotal": unit * Double(qty),
                "modifiers": entry.subtitle ?? "",
                "isOth":     isOth                  // ✅ THIS is what you save in JSON/DB
            ]
        }

        let apnsToken = defaults.string(forKey: "apnsToken") ?? ""

        let serviceValue: String = {
            switch diningMode {
            case .dineIn:   return "sit"
            case .takeAway: return "ta"
            }
        }()

        // ---------- totals (discount-aware) ----------
        // Prefer totals["total"] as the amount due; fall back to function param `total`
        var finalTotals: [String: Any] = totals ?? [:]

        let dueFromTotals = flexDouble(finalTotals["total"])
        let due = r2(max(dueFromTotals ?? total, 0))

        // Ensure totals always include currency + total (so reporting never misses it)
        if finalTotals["currency"] == nil {
            finalTotals["currency"] = defaults.string(forKey: "currency") ?? "ILS"
        }
        finalTotals["total"] = due

        // (Optional) If caller didn’t include subtotal/discount, derive “discount” as a fallback
        if finalTotals["subtotal"] == nil {
            // best-effort: basket sum is subtotal baseline
            let subtotalGuess = r2(entries.reduce(0.0) { acc, e in acc + (Double(e.quantity) * e.unitPrice) })
            finalTotals["subtotal"] = subtotalGuess
        }
        if finalTotals["discount"] == nil {
            if let sub = flexDouble(finalTotals["subtotal"]) {
                finalTotals["discount"] = r2(max(0, sub - due))
            }
        }

        // ---------- base payload ----------
        var payload: [String: Any] = [
            "uuid": uuid,
            "email": defaultEmail,
            "name": effectiveName,
            "miniAppId": miniAppId,

            // keep for backwards compat (old server paths)
            "total": due,

            "basket": basketPayload,
            "diningMode": diningMode.rawValue,
            "service": serviceValue,
            "device": [
                "platform": "ios",
                "token": apnsToken
            ],

            // ✅ NEW unified totals object (discount, subtotal, total, currency)
            "totals": finalTotals
        ]

        if let orderId = orderId {
            payload["orderId"] = orderId
        }

        if let ticketNumber = ticketNumber {
            payload["ticketNumber"] = ticketNumber
        }

        // ✅ Order classification (team tab)
        if let orderType, !orderType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payload["orderType"] = orderType
        }
        if let tabKey, !tabKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payload["tabKey"] = tabKey
        }

        // ------------------------------------------------------------
        // 🧾 Payment summary: normalize amounts + ensure paid matches DUE
        // ------------------------------------------------------------
        var normalizedMethod: String? = nil
        var normalizedCash: Double? = nil
        var normalizedCard: Double? = nil

        var dueVar = due  // 👈 make due mutable so we can align it with paid sum

        if let payment {
            var cash = r2(max(payment.cashAmount, 0))
            var card = r2(max(payment.cardAmount, 0))
            var sum  = r2(cash + card)

            // ✅ If anything was paid, prefer the paid sum as the “due”
            // This fixes discount rounding cases (e.g. 6 -10% => UI due 5, cash paid 5)
            if sum > 0.01, !closeEnough(sum, dueVar) {
                dueVar = sum
                finalTotals["total"] = dueVar
            }

            // ✅ Derive method from normalized amounts (don’t trust caller)
            let method: String
            if sum <= 0.01 {
                cash = 0
                card = 0
                method = PaymentMethod.unpaid.rawValue
            } else if cash > 0.01 && card > 0.01 {
                method = PaymentMethod.mixed.rawValue
            } else if card > 0.01 {
                method = PaymentMethod.card.rawValue
            } else {
                method = PaymentMethod.cash.rawValue
            }

            normalizedMethod = method
            normalizedCash   = cash
            normalizedCard   = card

            payload["payment"] = [
                "provider": "minis",
                "method": method,
                "cardAmount": card,
                "cashAmount": cash
            ]
        }

        // ✅ Make sure payload uses the final due (possibly adjusted to paid sum)
        payload["total"] = dueVar
        var totalsOut = finalTotals
        totalsOut["total"] = dueVar
        payload["totals"] = totalsOut

        // 📲 WhatsApp notifications
        if let phone = customerPhone?.trimmingCharacters(in: .whitespacesAndNewlines),
           !phone.isEmpty {
            payload["notifications"] = [
                "wa": [
                    "phone": phone,
                    "consent": 1
                ]
            ]
        }

        // 💳 ZCredit meta – prefer normalized method if available
       
        guard let url = URL(string: "https://minis.studio/submitOrder") else {
            completion(.failure(SubmitError(message: "Bad URL")))
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        let normalizedSource = source
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        req.setValue(normalizedSource, forHTTPHeaderField: "X-Order-Source")

        if !apnsToken.isEmpty {
            req.setValue("ios", forHTTPHeaderField: "X-Device-Platform")
            req.setValue(apnsToken, forHTTPHeaderField: "X-Device-Token")

            #if APPCLIP
            let topic = "minis.co.uk.Clip"
            #else
            let topic = Bundle.main.bundleIdentifier ?? "minis.studio.app"
            #endif
            req.setValue(topic, forHTTPHeaderField: "X-APNs-Topic")

            #if DEBUG
            req.setValue("sandbox", forHTTPHeaderField: "X-APNs-Env")
            #else
            req.setValue("production", forHTTPHeaderField: "X-APNs-Env")
            #endif
        }

        print("curl:", req.curlDebug)

        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err = err {
                completion(.failure(err))
                return
            }
            guard
                let http = resp as? HTTPURLResponse,
                (200...299).contains(http.statusCode),
                let data = data,
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                completion(.failure(SubmitError(message: "Server error")))
                return
            }
            completion(.success(obj["orderId"] as? Int ?? 0))
        }.resume()
    }
}

extension URLRequest {
    var curlDebug: String {
        var s = "curl -X \(httpMethod ?? "GET")"
        allHTTPHeaderFields?.forEach { k, v in s += " -H '\(k): \(v)'" }
        if let body = httpBody, let json = String(data: body, encoding: .utf8) {
            s += " -d '\(json)'"
        }
        if let u = url?.absoluteString { s += " '\(u)'" }
        return s
    }
}

enum Haptics {
    static func light() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func medium() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func heavy() { UIImpactFeedbackGenerator(style: .heavy).impactOccurred() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
    static func selection() { UISelectionFeedbackGenerator().selectionChanged() }
}

struct ZCreditResult {
    enum Status {
        case approved        // gateway clearly approved
        case declined        // gateway clearly declined
        case unknown         // unclear (network error, timeout, device busy, etc.)
    }

    let status: Status
    let message: String
    let referenceNumber: String?
    let transactionId: String?
    let rawPath: String?        // e.g. "commit_final", "status_exhausted"
    let rawReturnCode: String?  // e.g. "0", "-80", etc.

    /// Convenience flag so old code `if result.approved` keeps working
    var approved: Bool { status == .approved }
}

final class ZCreditPaymentHandler {
    static let shared = ZCreditPaymentHandler()

    private let baseURL = URL(string: "https://minis.studio")!

    // timers are no longer used for polling, but we keep them + invalidate
    // in case you later reintroduce some periodic logic
    private var statusTimer: Timer?
    private var timeoutTimer: Timer?

    private var currentCorrelationId: String?
    private var currentReferenceOrSession: String?
    private var currentSessionId: String?
    private var currentPinpadId: String?

    // MARK: - Helper: map backend JSON → tri-state ZCreditResult

    private func finishFromResponse(
        json: [String: Any],
        completion: @escaping (ZCreditResult) -> Void
    ) {
        let pathRaw   = json["path"] as? String
        let resultRaw = json["resultStatus"] as? String

        let path      = pathRaw?.lowercased()
        let resultStr = resultRaw?.lowercased()

        let reference = json["referenceNumber"] as? String
        let txId      = json["transactionId"] as? String
        let rc        = (json["invoiceReturnCode"] as? String) ?? (json["returnCode"] as? String)

        let msg = (json["invoiceReturnMessage"] as? String) ??
                  (json["ZCreditMessage"] as? String) ??
                  (json["message"] as? String) ??
                  ""

        // ------- CLASSIFICATION (similar spirit to old parseEnvelope) -------

        // Explicit “device busy” code → decline with a clear message
        if rc == "-50101" {
            let status: ZCreditResult.Status = .declined

            invalidateTimers()
            currentCorrelationId      = nil
            currentReferenceOrSession = nil
            currentSessionId          = nil

            let result = ZCreditResult(
                status: status,
                message: msg.isEmpty
                         ? "מכשיר הסליקה עסוק בתהליך אחר. ודאו שהמסוף במסך המתנה ונסו שוב."
                         : msg,
                referenceNumber: reference,
                transactionId: txId,
                rawPath: pathRaw,
                rawReturnCode: rc
            )
            DispatchQueue.main.async { completion(result) }
            return
        }

        // Old -80 = "keep waiting" → here we treat as UNKNOWN (caller can show 'payment not completed')
        if rc == "-80" {
            let status: ZCreditResult.Status = .unknown

            invalidateTimers()
            currentCorrelationId      = nil
            currentReferenceOrSession = nil
            currentSessionId          = nil

            let result = ZCreditResult(
                status: status,
                message: msg.isEmpty ? "התשלום לא הושלם במסוף" : msg,
                referenceNumber: reference,
                transactionId: txId,
                rawPath: pathRaw,
                rawReturnCode: rc
            )
            DispatchQueue.main.async { completion(result) }
            return
        }

        // Path-based decline signals (cancel / explicit decline)
        let isDeclinedPath = (
            path == "commit_declined" ||
            path == "status_declined" ||
            path == "no_reference" ||
            path == "commit_cancelled" ||
            path == "status_cancelled"
        )

        let isApprovedPath = (
            path == "commit_final" ||
            path == "status_final" ||
            path == "commit_approved"
        )

        let isApprovedStatus = (resultStr == "approved")
        let isDeclinedStatus = (resultStr == "declined")

        let isApprovedCode = (rc == "0" || rc == "000" || rc == "00")   // typical “OK” codes
        let hasAnyCode     = (rc?.isEmpty == false)

        let finalStatus: ZCreditResult.Status

        if isApprovedStatus || isApprovedPath || isApprovedCode {
            finalStatus = .approved
        } else if isDeclinedStatus || isDeclinedPath || (hasAnyCode && !isApprovedCode) {
            // any non-0 code (except the special cases handled above) → decline
            finalStatus = .declined
        } else {
            // no clear signal → unknown
            finalStatus = .unknown
        }

        // -------------------------------------------------------------------

        invalidateTimers()
        currentCorrelationId      = nil
        currentReferenceOrSession = nil
        currentSessionId          = nil

        let result = ZCreditResult(
            status: finalStatus,
            message: msg,
            referenceNumber: reference,
            transactionId: txId,
            rawPath: pathRaw,
            rawReturnCode: rc
        )

        DispatchQueue.main.async {
            completion(result)
        }
    }
    // MARK: - Main entry point

    func pay(
        amount: Double,
        orderId: Int?,
        transactionType: String = "01",   // ✅ NEW: "01" = regular, "53" = refund
        completion: @escaping (ZCreditResult) -> Void
    ) {

        // You still hard-code pinpads – leaving your logic as-is
    //    UserDefaults.standard.set("48796294", forKey: "pinpadId")
  //   UserDefaults.standard.set("48796855", forKey: "pinpadId")
   //   UserDefaults.standard.set("48796856", forKey: "pinpadId")

        let _ = CashpointID(rawValue: UserDefaults.standard.integer(forKey: "cashpointID")) ?? .one

        let safeAmount    = max(0, amount)
        let pinpadId      = UserDefaults.standard.string(forKey: "pinpadId") ?? "48796294"
        let correlationId = UUID().uuidString

        currentCorrelationId = correlationId
        currentPinpadId      = pinpadId

        let startBody: [String: Any] = [
            "amount": safeAmount,
            "currency": "ILS",
            "authOnly": false,
            "orderId": orderId != nil ? String(orderId!) : "",
            "pinpadId": pinpadId,

            // ✅ NEW: tell backend which ZCredit transaction type to run
            "transactionType": transactionType
        ]

        guard let startURL = URL(string: "/payments/zcredit/start", relativeTo: baseURL) else {
            let result = ZCreditResult(
                status: .unknown,
                message: "שגיאה בכתובת השרת",
                referenceNumber: nil,
                transactionId: nil,
                rawPath: "client_bad_url",
                rawReturnCode: nil
            )
            DispatchQueue.main.async { completion(result) }
            return
        }

        var req = URLRequest(url: startURL, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(correlationId, forHTTPHeaderField: "x-correlation-id")
        req.setValue(pinpadId, forHTTPHeaderField: "x-pinpad-id")
        req.httpBody = try? JSONSerialization.data(withJSONObject: startBody)

        // 🔍 Debug: print the full curl for /payments/zcredit/start
        print("🔵 ZCredit /payments/zcredit/start cURL:")
        print(req.curlDebug)

        URLSession.shared.dataTask(with: req) { [weak self] data, resp, error in
            guard let self = self else { return }

            // Network / transport error → unknown
            if let error = error {
                let json: [String: Any] = [
                    "ok": false,
                    "path": "commit_http_error",
                    "message": "שגיאה בתחילת עסקה במסוף: \(error.localizedDescription)"
                ]
                self.finishFromResponse(json: json, completion: completion)
                return
            }

            guard let http = resp as? HTTPURLResponse,
                  let data = data,
                  http.statusCode == 200,
                  !data.isEmpty
            else {
                let json: [String: Any] = [
                    "ok": false,
                    "path": "commit_http_non_200",
                    "message": "שגיאה בתחילת עסקה במסוף"
                ]
                self.finishFromResponse(json: json, completion: completion)
                return
            }

            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                let json: [String: Any] = [
                    "ok": false,
                    "path": "client_parse_error",
                    "message": "תגובה לא תקינה מהמסוף"
                ]
                self.finishFromResponse(json: json, completion: completion)
                return
            }

            // Stash session info for potential /cancel
            if let sid = (obj["sessionId"] as? String) ?? (obj["SessionId"] as? String) {
                self.currentSessionId = sid
            }
            if let ref = (obj["referenceNumber"] as? String) ?? (obj["ReferenceNumber"] as? String) {
                self.currentReferenceOrSession = ref
            }

            // ✅ Let the helper map json → ZCreditResult (approved / declined / unknown)
            self.finishFromResponse(json: obj, completion: completion)

        }.resume()
    }

    // MARK: - Cancel

    private func invalidateTimers() {
        statusTimer?.invalidate()
        timeoutTimer?.invalidate()
        statusTimer = nil
        timeoutTimer = nil
    }

    func cancelCurrent() {
        invalidateTimers()

        guard let url = URL(string: "/payments/zcredit/cancel", relativeTo: baseURL) else {
            return
        }

        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [:]

        if let pinpadId = currentPinpadId {
            body["pinpadId"] = pinpadId
        }

        if let streamId = currentSessionId ?? currentReferenceOrSession {
            body["streamId"] = streamId
        }

        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: req).resume()
    }
}

final class ZCreditApplePayHandler: NSObject, PKPaymentAuthorizationControllerDelegate {
    private var selfPin: ZCreditApplePayHandler?
    private var completionHandler: ((Result<[String: Any], Error>) -> Void)?
    private var pendingResult: Result<[String: Any], Error>?   // 👈 NEW: store result until sheet dismisses

    private let commitURL = URL(string: "https://minis.studio/payments/zcredit/applepay/commit")!

    private let countryCode: String
    private let currencyCode: String
    private var committedAmountMinor: Int = 0

    init(countryCode: String = "IL", currencyCode: String = "ILS") {
        self.countryCode = countryCode
        self.currencyCode = currencyCode
        super.init()
        self.selfPin = self
    }

    private func done(_ result: Result<[String: Any], Error>?) {
        if let result {
            completionHandler?(result)
        }
        completionHandler = nil
        pendingResult = nil
        selfPin = nil
    }

    func present(
        total: Decimal,
        merchantId: String,
        onComplete: @escaping (Result<[String: Any], Error>) -> Void
    ) {
        completionHandler = onComplete
        pendingResult = nil

        committedAmountMinor = NSDecimalNumber(decimal: total)
            .multiplying(by: 100)
            .intValue

        guard PKPaymentAuthorizationController.canMakePayments(usingNetworks: [.visa, .masterCard, .amex]) else {
            let err = NSError(
                domain: "applepay.capability",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Device not configured for Apple Pay"]
            )
            onComplete(.failure(err))
            done(nil)
            return
        }

        let req = PKPaymentRequest()
        req.merchantIdentifier   = merchantId
        req.countryCode          = countryCode
        req.currencyCode         = currencyCode
        req.merchantCapabilities = [.capability3DS]
        req.supportedNetworks    = [.visa, .masterCard, .amex]
        req.paymentSummaryItems  = [
            PKPaymentSummaryItem(
                label: "MINIS",
                amount: NSDecimalNumber(decimal: total),
                type: .final
            )
        ]

        let ctrl = PKPaymentAuthorizationController(paymentRequest: req)
        ctrl.delegate = self

        // (You effectively don't use `root` here; keeping the guard as a sanity check)
        guard
            let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
            let window = scene.windows.first(where: { $0.isKeyWindow }),
            let _ = window.rootViewController
        else {
            let err = NSError(
                domain: "applepay.ui",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "No root view controller"]
            )
            onComplete(.failure(err))
            done(nil)
            return
        }

        ctrl.present { success in
            if !success {
                let err = NSError(
                    domain: "applepay.ui",
                    code: -3,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to present Apple Pay"]
                )
                onComplete(.failure(err))
                self.done(nil)
            }
        }
    }

    // MARK: - PKPaymentAuthorizationControllerDelegate

    func paymentAuthorizationController(
        _ controller: PKPaymentAuthorizationController,
        didAuthorizePayment payment: PKPayment,
        handler completion: @escaping (PKPaymentAuthorizationResult) -> Void
    ) {
        let tokenData = payment.token.paymentData

        guard
            let paymentDataJSON = try? JSONSerialization.jsonObject(with: tokenData) as? [String: Any]
        else {
            let err = NSError(
                domain: "zcredit.applepay",
                code: -10,
                userInfo: [NSLocalizedDescriptionKey: "Invalid Apple Pay token"]
            )
            // Tell Apple Pay it's a failure (it will show error / dismiss)
            pendingResult = .failure(err)
            completion(.init(status: .failure, errors: [err]))
            return
        }

        let pm = payment.token.paymentMethod
        var paymentMethodDict: [String: Any] = [:]
        paymentMethodDict["type"] = pm.type.rawValue
        if let net = pm.network?.rawValue { paymentMethodDict["network"] = net }
        if let name = pm.displayName { paymentMethodDict["displayName"] = name }

        // Structured Apple payload
        let appleToken: [String: Any] = [
            "paymentData": paymentDataJSON,
            "paymentMethod": paymentMethodDict,
            "transactionIdentifier": payment.token.transactionIdentifier
        ]

        guard
            let fullData = try? JSONSerialization.data(withJSONObject: appleToken, options: []),
            let fullJSON = String(data: fullData, encoding: .utf8)
        else {
            let err = NSError(
                domain: "zcredit.applepay",
                code: -11,
                userInfo: [NSLocalizedDescriptionKey: "Failed to serialize Apple token"]
            )
            pendingResult = .failure(err)
            completion(.init(status: .failure, errors: [err]))
            return
        }

        let amountMinor = committedAmountMinor
        let orderId = "apple-\(Int(Date().timeIntervalSince1970))"

        let body: [String: Any] = [
            "amountMinor": amountMinor,
            "currency": currencyCode,
            "orderId": orderId,
            "appleFullTokenJson": fullJSON,
            "applePayload": appleToken
        ]

        var req = URLRequest(url: commitURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [])

        print("🔵 ZCredit ApplePay commit cURL:\n\(req.curlDebug)")

        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err = err {
                print("❌ ZCredit network error:", err.localizedDescription)
                self.pendingResult = .failure(err)
                completion(.init(status: .failure, errors: [err]))
                return
            }

            guard let http = resp as? HTTPURLResponse, let data = data else {
                let e = NSError(
                    domain: "zcredit.applepay",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "No HTTP response"]
                )
                print("❌ ZCredit backend: no HTTP response")
                self.pendingResult = .failure(e)
                completion(.init(status: .failure, errors: [e]))
                return
            }

            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            print("🟢 ZCredit backend status:", http.statusCode)
            print("📦 ZCredit backend body:", obj)

            let ok = (obj["ok"] as? Int ?? 0) == 1 || (obj["ok"] as? Bool ?? false)
            let hasError = (obj["zcreditHasError"] as? Int ?? 0) == 1

            if http.statusCode == 200, ok, !hasError {
                // ✅ success → tell Apple Pay success, store result for later
                self.pendingResult = .success(obj)
                completion(.init(status: .success, errors: nil))
            } else {
                let msg = (obj["zcreditReturnMessage"] as? String)
                    ?? (obj["error"] as? String)
                    ?? "Payment failed"
                let e = NSError(
                    domain: "zcredit.applepay",
                    code: http.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: msg, "body": obj]
                )
                print("❌ ZCredit ApplePay refused:", msg)
                self.pendingResult = .failure(e)
                completion(.init(status: .failure, errors: [e]))
            }
        }.resume()
    }

    func paymentAuthorizationControllerDidFinish(_ controller: PKPaymentAuthorizationController) {
        controller.dismiss { [weak self] in
            guard let self = self else { return }

            if let result = self.pendingResult {
                // We have a backend result (success or failure) → deliver it now
                self.done(result)
            } else if self.completionHandler != nil {
                // No didAuthorize result, but we still have a completionHandler → user cancelled
                let e = NSError(
                    domain: "applepay.user",
                    code: -999,
                    userInfo: [NSLocalizedDescriptionKey: "Cancelled"]
                )
                self.done(.failure(e))
            } else {
                // present() might have failed earlier and already cleaned up
            }
        }
    }
}

struct MiniCustomization: Decodable {
    struct Mini: Decodable {
        let miniAppType: String?
        let miniAppId: Int?
        let title: String?
        let subtitle: String?
        let miniImage: String?
    }

    struct Theme: Decodable {
        let direction: String?
        let currency: String?
        let fontName: String?   // 👈 NEW
    }

    let mini: Mini?
    let theme: Theme?
}

func applyMiniCustomization(from data: Data) {
    let decoder = JSONDecoder()
    guard let cfg = try? decoder.decode(MiniCustomization.self, from: data) else {
        return
    }

    let std = UserDefaults.standard

    if let mini = cfg.mini {
        if let title = mini.title, !title.isEmpty {
            std.set(title, forKey: "miniTitle")
        }
        if let subtitle = mini.subtitle {
            std.set(subtitle, forKey: "miniSubtitle")
        }
        if let img = mini.miniImage, !img.isEmpty {
            std.set(img, forKey: "miniImage")
        }
        if let id = mini.miniAppId {
            std.set(id, forKey: "miniAppId")
            std.set(String(id), forKey: "shopId")
        }
    }

    if let theme = cfg.theme {
        if let dirRaw = theme.direction?.lowercased() {
            let resolved = (dirRaw == "rtl") ? "rtl" : "ltr"
            std.set(resolved, forKey: "direction")
           // print("🌍 applyMiniCustomization → theme.direction=\(dirRaw) → stored=\(resolved)")
        }

        if let currency = theme.currency {
            std.set(currency, forKey: "currency")
        }

        if let fontName = theme.fontName, !fontName.isEmpty {
            std.set(fontName, forKey: "fontName")
         //   print("🔤 applyMiniCustomization → theme.fontName=\(fontName)")
        }
    }
}
func appFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
    let name = UserDefaults.standard.string(forKey: "fontName") ?? "System"

    if name == "System" {
        return .system(size: size, weight: weight)
    } else {
        // Weight handling for custom fonts is a bit looser, but good enough for now
        return .custom(name, size: size)
    }
}


func saveReferralForCurrentShop(kind: MiniKind = .fastlane) {
    let std = UserDefaults.standard

    // 1️⃣ Resolve the current mini id
    let miniIdFromDefaults = std.integer(forKey: "miniAppId")
    let miniId: Int

    if miniIdFromDefaults > 0 {
        miniId = miniIdFromDefaults
    } else if
        let shopIdString = std.string(forKey: "shopId"),
        let parsed = Int(shopIdString)
    {
        miniId = parsed
    } else {
      //  print("⚠️ saveReferralForCurrentShop → no miniAppId / shopId in defaults, aborting")
        return
    }

    // 2️⃣ Resolve dynamic title / subtitle / image from JSON / customization
    //    (set these keys when you load your mini’s JSON/customizations)
    let title    = std.string(forKey: "miniTitle")    ?? "Mini"
    let subtitle = std.string(forKey: "miniSubtitle") ?? ""
    let imageURL = std.string(forKey: "miniImage")    ?? ""

  //  print("💾 saveReferralForCurrentShop → miniAppId=\(miniId), kind=\(kind), title=\(title)")

    // 3️⃣ Load existing referrals from the app group
    let defaults = UserDefaults(suiteName: "group.minis")
    var referrals: [MiniReferral] = []

    if let data = defaults?.data(forKey: "miniReferralsJSON"),
       let decoded = try? JSONDecoder().decode([MiniReferral].self, from: data) {
        referrals = decoded
    }

    // 4️⃣ Upsert (update if exists, else insert) for this miniId+kind
    if let idx = referrals.firstIndex(where: { $0.miniAppId == miniId && $0.kind == kind }) {
        let old = referrals.remove(at: idx)

        let updated = MiniReferral(
            title: title,
            subtitle: subtitle,
            miniAppId: miniId,
            imageURL: imageURL,
            sharedAt: Date(),   // refresh timestamp
            kind: old.kind
        )

        referrals.insert(updated, at: 0)
    } else {
        let newReferral = MiniReferral(
            title: title,
            subtitle: subtitle,
            miniAppId: miniId,
            imageURL: imageURL,
            sharedAt: Date(),
            kind: kind
        )

        referrals.insert(newReferral, at: 0)
    }

    if let data = try? JSONEncoder().encode(referrals) {
        defaults?.set(data, forKey: "miniReferralsJSON")
    }
}

final class MenuCatalog {
    static let shared = MenuCatalog()
    private init() {}

    private var byId: [Int: ShellMenuItem] = [:]
    private let q = DispatchQueue(label: "menu.catalog.lock")

    func update(items: [ShellMenuItem]) {
        q.sync {
            byId = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        }
    }

    func item(for productId: Int?) -> ShellMenuItem? {
        guard let id = productId else { return nil }
        return q.sync { byId[id] }
    }

    func printer(for productId: Int?) -> String? {
        item(for: productId)?.printer
    }

    // ✅ ADD THIS
    func price(for productId: Int?) -> Double {
        item(for: productId)?.price ?? 0
    }
}
// GLOBAL helper – accessible from anywhere
func makeShellMenuItem(from line: AdminOrderLineItem) -> ShellMenuItem {
    // ✅ If we have the menu item, use it (includes printer)
    if let menuItem = MenuCatalog.shared.item(for: line.productId) {
        return menuItem
    }

    // ✅ fallback uses line.printer (from server or catalog)
    return ShellMenuItem(
        id: line.productId ?? line.id,
        name: line.name,
        price: line.unitPrice,
        category: line.category ?? "",
        modifiers: nil,
        imageURL: nil,
        description: nil,
        status: nil,
        stockQuantity: nil,
        printer: line.printer ?? "Bar"
    )
}

struct SalesRow {
    let net: String        // ללא מע״מ
    let gross: String      // כולל מע״מ
    let diners: String     // סועד
    let ppa: String        // PPA
}


func nextLocalTicketNumber() -> Int {
    let defaults = UserDefaults.standard
    let key = "cpLastTicketNumber"

    let last = defaults.integer(forKey: key)   // 0 if missing
    let base = max(last, 1000)                 // start from 1000
    let next = base + 1

    defaults.set(next, forKey: key)
    return next
}

enum CashpointID: Int {
    case one = 1
    case two = 2
}
struct ZReportData: Decodable {
    let date: Date
    let grossTotal: Double
    let netTotal: Double
    let vatTotal: Double
    let cashTotal: Double
    let cardTotal: Double
    let paymentsTotal: Double
    let totalTips: Double
    let cashTips: Double
    let cardTips: Double
}


enum KeyboardCustomization {
    static func disableQuickTypeBar() {
        let tf = UITextField.appearance()
        tf.inputAssistantItem.leadingBarButtonGroups = []
        tf.inputAssistantItem.trailingBarButtonGroups = []

        let tv = UITextView.appearance()
        tv.inputAssistantItem.leadingBarButtonGroups = []
        tv.inputAssistantItem.trailingBarButtonGroups = []
    }
}

func resetShopUserDefaultsToDefaults() {
    let defaults = UserDefaults.standard
    defaults.set("#f7f5f1", forKey: "bg")
    defaults.set("#000000", forKey: "categorySelectedTextColor")
    defaults.set("#000000", forKey: "categoryTextColor")
    defaults.removeObject(forKey: "priceColor")
    defaults.removeObject(forKey: "selectedCategoryColor")
    defaults.set("#000000", forKey: "brandColor")
    defaults.set("ltr", forKey: "direction")
    defaults.set("#000000", forKey: "basketBadgeTextColor")
    defaults.set("#000000", forKey: "priceTextColor")
    defaults.set("#FFFFFF", forKey: "basketBadgeBackground")
    defaults.set("#FFFFFF", forKey: "badgeTextColor")
    defaults.set("#000000", forKey: "buttonColor")
    defaults.set("#FFFFFF", forKey: "buttonTextColor")
    defaults.set("System", forKey: "fontName")
    defaults.set("false", forKey: "isDelivery")
    defaults.set("GBP", forKey: "currency")
}

func disableQuickTypeBar() {
    let tf = UITextField.appearance()
    tf.inputAssistantItem.leadingBarButtonGroups = []
    tf.inputAssistantItem.trailingBarButtonGroups = []

    let tv = UITextView.appearance()
    tv.inputAssistantItem.leadingBarButtonGroups = []
    tv.inputAssistantItem.trailingBarButtonGroups = []
}


import Foundation
import PassKit

final class StripeApplePayHandler: NSObject, PKPaymentAuthorizationControllerDelegate {

    private var controller: PKPaymentAuthorizationController?
    private var completion: ((Result<PKPayment, Error>) -> Void)?
    private var didAuthorize = false
    private var authorizedPayment: PKPayment?

    func start(
        merchantId: String,
        countryCode: String = "GB",
        currencyCode: String = "GBP",
        label: String = "Order",
        total: Double,
        completion: @escaping (Result<PKPayment, Error>) -> Void
    ) {
        self.completion = completion
        self.didAuthorize = false
        self.authorizedPayment = nil

        guard PKPaymentAuthorizationController.canMakePayments(usingNetworks: [.visa, .masterCard, .amex]) else {
            completion(.failure(NSError(domain: "applepay", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Apple Pay not available on this device."
            ])))
            return
        }

        let req = PKPaymentRequest()
        req.merchantIdentifier = merchantId
        req.countryCode = countryCode
        req.currencyCode = currencyCode
        req.merchantCapabilities = [.capability3DS]
        req.supportedNetworks = [.visa, .masterCard, .amex]

        let amount = NSDecimalNumber(value: total)
        req.paymentSummaryItems = [
            PKPaymentSummaryItem(label: label, amount: amount, type: .final)
        ]

        let ctrl = PKPaymentAuthorizationController(paymentRequest: req)
        ctrl.delegate = self
        self.controller = ctrl

        ctrl.present { ok in
            if !ok {
                completion(.failure(NSError(domain: "applepay", code: -2, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to present Apple Pay sheet."
                ])))
            }
        }
    }

    // MARK: - PKPaymentAuthorizationControllerDelegate

    func paymentAuthorizationController(
        _ controller: PKPaymentAuthorizationController,
        didAuthorizePayment payment: PKPayment,
        handler completion: @escaping (PKPaymentAuthorizationResult) -> Void
    ) {
        didAuthorize = true
        authorizedPayment = payment

        // For now we approve locally (no charge)
        completion(PKPaymentAuthorizationResult(status: .success, errors: nil))
    }

    func paymentAuthorizationControllerDidFinish(_ controller: PKPaymentAuthorizationController) {
        controller.dismiss {
            defer {
                self.controller = nil
                self.completion = nil
                self.authorizedPayment = nil
                self.didAuthorize = false
            }

            if self.didAuthorize, let pay = self.authorizedPayment {
                self.completion?(.success(pay))
            } else {
                self.completion?(.failure(NSError(domain: "applepay", code: -999, userInfo: [
                    NSLocalizedDescriptionKey: "Cancelled"
                ])))
            }
        }
    }
}

enum TabType: String, CaseIterable, Identifiable {
    case manager, conditur, kitchen, floor
    var id: String { rawValue }

    var titleHe: String {
        switch self {
        case .manager: return "שולחן מנהלים"
        case .conditur:     return "שולחן קונדיטוריה"
        case .kitchen: return "שולחן מטבח"
        case .floor:   return "שולחן פלור"
        }
    }
}


enum TeamTabsAPI {
    static func close(orderId: Int, completion: @escaping (Result<Void, Error>) -> Void) {
           guard let url = URL(string: "https://minis.studio/api/teamtabs/\(orderId)/close") else {
               completion(.failure(NSError(domain: "TeamTabsAPI", code: -1)))
               return
           }
           var req = URLRequest(url: url, timeoutInterval: 15)
           req.httpMethod = "POST"
           req.setValue("application/json", forHTTPHeaderField: "Content-Type")
           req.httpBody = try? JSONSerialization.data(withJSONObject: [:])

           URLSession.shared.dataTask(with: req) { data, resp, err in
               if let err = err { completion(.failure(err)); return }
               guard let http = resp as? HTTPURLResponse else {
                   completion(.failure(NSError(domain: "TeamTabsAPI", code: -2))); return
               }
               if !(200...299).contains(http.statusCode) {
                   let body = String(data: data ?? Data(), encoding: .utf8) ?? ""
                   completion(.failure(NSError(domain: "TeamTabsAPI", code: http.statusCode, userInfo: ["body": body])))
                   return
               }
               completion(.success(()))
           }.resume()
       }
    struct OpenResp: Decodable {
        let orderId: Int
    }
    
    static func fetchOrderMetadata(
        orderId: Int,
        completion: @escaping (Result<OrderMetadataDTO, Error>) -> Void
    ) {
        guard let url = URL(string: "https://minis.studio/api/orders/\(orderId)") else {
            completion(.failure(NSError(domain: "TeamTabsAPI", code: -10)))
            return
        }

        URLSession.shared.dataTask(with: url) { data, resp, err in
            if let err = err {
                completion(.failure(err))
                return
            }

            guard let http = resp as? HTTPURLResponse else {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? "<no body>"
                print("❌ fetchOrderMetadata NO HTTP RESPONSE body:", body)
                completion(.failure(NSError(domain: "TeamTabsAPI", code: -11)))
                return
            }

            guard (200...299).contains(http.statusCode), let data = data else {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? "<no body>"
                print("❌ fetchOrderMetadata HTTP \(http.statusCode) body:", body)
                completion(.failure(NSError(domain: "TeamTabsAPI", code: http.statusCode)))
                return
            }

            do {
                let dec = JSONDecoder()
                dec.dateDecodingStrategy = .iso8601
                let decoded = try dec.decode(OrderMetadataDTO.self, from: data)
                completion(.success(decoded))
            } catch {
                let body = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
                print("❌ fetchOrderMetadata decode failed body:", body)
                completion(.failure(error))
            }
        }.resume()
    }

    // ✅ NEW: fetch order details so we can restore basket
     
    static func openOrCreate(
        miniAppId: Int,
        tab: TabType,
        completion: @escaping (Result<Int, Error>) -> Void
    ) {
        let miniAppId = miniAppId

        guard miniAppId > 0 else {
            completion(.failure(NSError(domain: "TeamTabsAPI", code: -1)))
            return
        }

        guard let url = URL(string: "https://minis.studio/api/team-tabs/open") else {
            completion(.failure(NSError(domain: "TeamTabsAPI", code: -2)))
            return
        }

        let payload: [String: Any] = [
            "miniAppId": miniAppId,
            "tabKey": tab.rawValue
        ]

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        // ✅ Debug curl
        if let body = req.httpBody, let s = String(data: body, encoding: .utf8) {
            print("🧩 TeamTabsAPI.openOrCreate payload:", s)
        }

        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err = err {
                completion(.failure(err))
                return
            }

            guard let http = resp as? HTTPURLResponse else {
                let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? "<no body>"
                print("❌ TeamTabsAPI.openOrCreate NO HTTP RESPONSE body:", text)
                completion(.failure(NSError(domain: "TeamTabsAPI", code: -3)))
                return
            }

            guard (200...299).contains(http.statusCode), let data else {
                let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? "<no body>"
                print("❌ TeamTabsAPI.openOrCreate HTTP \(http.statusCode) body:", text)
                completion(.failure(NSError(domain: "TeamTabsAPI", code: -3)))
                return
            }

            do {
                let decoded = try JSONDecoder().decode(OpenResp.self, from: data)
                completion(.success(decoded.orderId))
            } catch {
                let text = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
                print("❌ TeamTabsAPI.openOrCreate decode failed body:", text)
                completion(.failure(error))
            }
        }.resume()
    }

   
}


final class OrderPricingState: ObservableObject {
    @Published var subtotal: Double = 0      // sum of lines before discount/excluded
    @Published var excluded: Double = 0      // OTH excluded sum
    @Published var discount: Double = 0      // discount amount
    @Published var total: Double = 0         // final payable total (after rounding rule)
    @Published var currency: String = "GBP"

    var totalsPayload: [String: Any] {
        [
            "subtotal": subtotal,
            "excluded": excluded,
            "discount": discount,
            "total": total,
            "currency": currency
        ]
    }
}

import Foundation

@MainActor
final class ReportPreviewModel: ObservableObject {
    @Published var data: PrinterManager.SalesReportData
    @Published var isLoading: Bool = false
    @Published var loadError: String? = nil
    @Published var vatRate: Double = 0.18

    init(initial: PrinterManager.SalesReportData) {
        self.data = initial
    }
    func printCurrentReport(type: CashPointView.ReportType) {
        // Prevent printing while loading / error
        if isLoading { return }
        if loadError != nil { return }

        // IMPORTANT:
        // data already contains restored Z totals if restoreMode == true
        PrinterManager.shared.printSalesReport(
            data,
            type: type
        )
    }

    // ✅ NEW: optional date param for restore (used for Z restore)
    func load(type: CashPointView.ReportType, shopId: Int, for date: Date? = nil) async {
        guard !isLoading else { return }
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        do {
            switch type {
            case .x:
                let res = try await fetchXReport(miniAppId: shopId)
                self.data = PrinterManager.SalesReportData.applyingXReport(res, onto: self.data)

            case .z:
                // ✅ Restore date (Z) → call /api/zreports/by-day?day=YYYY-MM-DD
                if let date {
                    let tz = TimeZone(identifier: "Asia/Jerusalem") ?? .current
                    let ymd = Self.ymd(date, tz: tz)

                    let row = try await fetchZByDay(miniAppId: shopId, dayYMD: ymd)

                    // ✅ vat rate comes from DB row
                    self.vatRate = row.VatRate

                    // ✅ Map DB totals into your report preview model
                    var d = self.data

                    // -------------------------
                    // Sales (gross + net)
                    // -------------------------
                    d.totalSalesIncVat = row.GrossTotal
                    d.grandTotal       = row.GrossTotal - row.VatTotal   // net (ex VAT)

                    // -------------------------
                    // Tips ✅
                    // -------------------------
                    d.tipBaseTotal = row.TipsTotal
                    d.tipsTotal    = row.TipsTotal

                    // -------------------------
                    // Payments (collections)
                    // ✅ IMPORTANT: cashAmount INCLUDES tips
                    // -------------------------
                    let cashWithTips = row.CashTotal + row.TipsTotal

                    d.cashAmount = cashWithTips
                    d.cardAmount = row.CardTotal

                    d.cashCount  = row.CashCount
                    d.cardCount  = row.CardCount

                    // total collections (cash-with-tips + card)
                    d.collectionsTotalAmount = cashWithTips + row.CardTotal
                    d.collectionsTotalCount  = row.CashCount + row.CardCount + row.MixedCount

                    // -------------------------
                    // Cash report section
                    // If you want drawer totals to reflect "cash incl tips"
                    // -------------------------
                    d.closedDrawersAmount      = cashWithTips
                    d.drawerTotalAmount        = cashWithTips
                    d.mainDrawerAmount         = cashWithTips
                    // keep host station / open drawers / deposits from DB if you have them;
                    // otherwise zero them to avoid stale values:
                    d.openDrawersAmount        = 0
                    d.depositWithdrawAmount    = 0
                    d.hostStationDrawerAmount  = 0

                    // -------------------------
                    // Optional: clear / set “restaurant/TA” so no stale values
                    // -------------------------
                    d.totalRestaurantIncVat = row.RestaurantGross
                    d.totalTAIncVat         = row.TaGross
                    d.dinersRestaurant      = row.RestaurantCount
                    d.dinersTA              = row.TaCount
                    d.ppaRestaurant         = 0
                    d.ppaTA                 = 0

                    // Optional: per-channel tips not available yet
                    d.tipRestaurant       = 0
                    d.tipBarTakeaway      = 0
                    d.extraTipTotal       = 0
                    d.extraTipRestaurant  = 0
                    d.extraTipBar         = 0

                    self.data = d
                    return
                }

                // ✅ Normal Z (no restore date): keep your existing behaviour for now
                let res = try await fetchXReport(miniAppId: shopId)
                self.data = PrinterManager.SalesReportData.applyingXReport(res, onto: self.data)

                // ✅ Normal Z (no restore date) – keep your existing behaviour for now
}
        } catch {
            // ✅ NEVER show empty error
            let ns = error as NSError
            let body = (ns.userInfo[NSLocalizedDescriptionKey] as? String) ?? ""
            self.loadError = body.isEmpty ? String(describing: error) : body
        }
    }

    // MARK: - X report

    private func fetchXReport(miniAppId: Int) async throws -> XReportApiResponse {
        let url = URL(string: "https://minis.studio/api/xreport?miniAppId=\(miniAppId)")!
        let (raw, resp) = try await URLSession.shared.data(from: url)

        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(code) else {
            let body = String(data: raw, encoding: .utf8) ?? "<non-utf8 \(raw.count) bytes>"
            throw NSError(domain: "http", code: code, userInfo: [NSLocalizedDescriptionKey: body])
        }

        return try JSONDecoder().decode(XReportApiResponse.self, from: raw)
    }

    // MARK: - Z by-day

    private struct ZByDayResponseDTO: Decodable {
        let ok: Bool
        let report: ZReportRowDTO?
        let error: String?
        let detail: String?
    }

    // ✅ Match your RAW payload fields
    private struct ZReportRowDTO: Decodable {
        let Id: Int
        let MiniAppId: Int
        let RangeFrom: String
        let RangeTo: String

        let GrossTotal: Double
        let NetTotal: Double
        let VatTotal: Double
        let VatRate: Double

        let TaCount: Int
        let TaGross: Double
        let RestaurantCount: Int
        let RestaurantGross: Double

        let CashCount: Int
        let CashTotal: Double
        let CardCount: Int
        let CardTotal: Double
        let MixedCount: Int

        let PaymentsTotal: Double

        let TipsTotal: Double
        let CashTipsTotal: Double
        let CardTipsTotal: Double

        let OrdersCount: Int
        let MissingPaymentCount: Int

        let JsonData: String?
    }

    private func fetchZByDay(miniAppId: Int, dayYMD: String) async throws -> ZReportRowDTO {
        var comps = URLComponents(string: "https://minis.studio/api/zreports/by-day")!
        comps.queryItems = [
            .init(name: "miniAppId", value: String(miniAppId)),
            .init(name: "day", value: dayYMD)
        ]
        let url = comps.url!

        // ✅ Debug cURL
        print("🧾 ZREPORT BY-DAY cURL:\ncurl \"\(url.absoluteString)\"")

        let (raw, resp) = try await URLSession.shared.data(from: url)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1

        let rawText = String(data: raw, encoding: .utf8) ?? "<non-utf8 \(raw.count) bytes>"
        print("🌍 zreports/by-day HTTP \(code)")
        print("📦 zreports/by-day RAW (first 600 chars):\n\(String(rawText.prefix(600)))")

        guard (200..<300).contains(code) else {
            throw NSError(domain: "http", code: code, userInfo: [NSLocalizedDescriptionKey: rawText])
        }

        let decoded = try JSONDecoder().decode(ZByDayResponseDTO.self, from: raw)

        guard decoded.ok, let row = decoded.report else {
            let msg = decoded.error ?? decoded.detail ?? "Unknown API error"
            throw NSError(domain: "api", code: -2, userInfo: [NSLocalizedDescriptionKey: msg])
        }

        return row
    }

    // MARK: - Helpers

    private static func ymd(_ date: Date, tz: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}

struct XReportApiResponse: Decodable {
    let ok: Bool
    let miniAppId: Int
    let sinceUtc: String
    let nowUtc: String
    let vatRate: Double
    let agg: XReportAgg

    enum CodingKeys: String, CodingKey {
        case ok
        case miniAppId
        case sinceUtc
        case nowUtc
        case vatRate
        case agg
    }
}

struct XReportAgg: Decodable {

    // MARK: - Orders / Sales
    let ordersCount: Int
    let grossTotal: Double
    let netTotal: Double
    let vatTotal: Double

    // ✅ Discounts
    let discountsTotal: Double
    let discountsCount: Int

    // MARK: - Payments
    let cashTotal: Double
    let cardTotal: Double
    let cashCount: Int
    let cardCount: Int
    let mixedCount: Int
    let missingPaymentCount: Int
    let paymentsTotal: Double

    // MARK: - Tips
    let tipsTotal: Double
    let cashTipsTotal: Double
    let cardTipsTotal: Double

    // MARK: - Grand total (sales + tips)
    let grandTotal: Double

    // MARK: - Service split
    let restaurantCount: Int
    let taCount: Int
    let restaurantGross: Double
    let taGross: Double

    // MARK: - OTH / Exceptions
    let ordersOTHCount: Int
    let ordersOTHAmount: Double

    enum CodingKeys: String, CodingKey {

        // Orders / Sales
        case ordersCount            = "OrdersCount"
        case grossTotal             = "GrossTotal"
        case netTotal               = "NetTotal"
        case vatTotal               = "VatTotal"

        // Discounts
        case discountsTotal         = "DiscountsTotal"
        case discountsCount         = "DiscountsCount"

        // Payments
        case cashTotal              = "CashTotal"
        case cardTotal              = "CardTotal"
        case cashCount              = "CashCount"
        case cardCount              = "CardCount"
        case mixedCount             = "MixedCount"
        case missingPaymentCount    = "MissingPaymentCount"
        case paymentsTotal          = "PaymentsTotal"

        // Tips
        case tipsTotal              = "TipsTotal"
        case cashTipsTotal          = "CashTipsTotal"
        case cardTipsTotal          = "CardTipsTotal"

        // Grand
        case grandTotal             = "GrandTotal"

        // Service split
        case restaurantCount        = "RestaurantCount"
        case taCount                = "TaCount"
        case restaurantGross        = "RestaurantGross"
        case taGross                = "TaGross"

        // OTH / Exceptions
        case ordersOTHCount         = "OrdersOTHCount"
        case ordersOTHAmount        = "OrdersOTHAmount"
    }
}

struct ZReportsSinceResponse: Decodable {
    let ok: Bool
    let count: Int
    let reports: [ZReport]
}

struct ZReportsSinceResponseDTO: Decodable {
    let ok: Bool
    let miniAppId: Int
    let fromRaw: String
    let fromUtc: String
    let reports: [ZReportRowDTO]
}

struct ZReportRowDTO: Decodable {
    let Id: Int
    let MiniAppId: Int
    let RangeFrom: String
    let RangeTo: String
    let VatRate: Double
    let JsonData: String
}

struct ZReport: Decodable, Identifiable {
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

        // ✅ accept both styles
        case jsonData = "JsonData"
        case jsonDataCamel = "jsonData"
        case createdAt = "CreatedAt"
        case createdAtCamel = "createdAt"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        id = try c.decode(Int.self, forKey: .id)
        miniAppId = try c.decode(Int.self, forKey: .miniAppId)
        rangeFrom = try c.decode(String.self, forKey: .rangeFrom)
        rangeTo = try c.decode(String.self, forKey: .rangeTo)

        grossTotal = try c.decode(Double.self, forKey: .grossTotal)
        netTotal = try c.decode(Double.self, forKey: .netTotal)
        vatTotal = try c.decode(Double.self, forKey: .vatTotal)
        vatRate = try c.decode(Double.self, forKey: .vatRate)

        cashCount = try c.decode(Int.self, forKey: .cashCount)
        cashTotal = try c.decode(Double.self, forKey: .cashTotal)
        cardCount = try c.decode(Int.self, forKey: .cardCount)
        cardTotal = try c.decode(Double.self, forKey: .cardTotal)
        paymentsTotal = try c.decode(Double.self, forKey: .paymentsTotal)

        tipsTotal = try c.decode(Double.self, forKey: .tipsTotal)
        cashTipsTotal = try c.decode(Double.self, forKey: .cashTipsTotal)
        cardTipsTotal = try c.decode(Double.self, forKey: .cardTipsTotal)

        ordersCount = try c.decode(Int.self, forKey: .ordersCount)
        missingPaymentCount = try c.decode(Int.self, forKey: .missingPaymentCount)

        // ✅ tolerant decode
        jsonData =
            (try? c.decodeIfPresent(String.self, forKey: .jsonData))
            ?? (try? c.decodeIfPresent(String.self, forKey: .jsonDataCamel))

        createdAt =
            (try? c.decodeIfPresent(String.self, forKey: .createdAt))
            ?? (try? c.decodeIfPresent(String.self, forKey: .createdAtCamel))
    }
}

extension PrinterManager.SalesReportData {

    static func applyingXReport(_ res: XReportApiResponse, onto base: Self) -> Self {
        var d = base

        // Sales by service (inc VAT)
        d.totalRestaurantIncVat = res.agg.restaurantGross
        d.totalTAIncVat = res.agg.taGross
        d.totalSalesIncVat = res.agg.grossTotal

        // "Diners" (blueprint): use counts as diners
        d.dinersRestaurant = res.agg.restaurantCount
        d.dinersTA = res.agg.taCount

        // PPA (blueprint): total / diners (avoid div0)
        d.ppaRestaurant = (res.agg.restaurantCount > 0) ? Int((res.agg.restaurantGross / Double(res.agg.restaurantCount)).rounded()) : 0
        d.ppaTA = (res.agg.taCount > 0) ? Int((res.agg.taGross / Double(res.agg.taCount)).rounded()) : 0

        // Payments
        d.cashCount = res.agg.cashCount
        d.cashAmount = res.agg.cashTotal
        d.cardCount = res.agg.cardCount
        d.cardAmount = res.agg.cardTotal
        d.collectionsTotalCount = res.agg.cashCount + res.agg.cardCount + res.agg.mixedCount
        d.collectionsTotalAmount = res.agg.cashTotal + res.agg.cardTotal

        // Tips
        d.tipsTotal = res.agg.tipsTotal
        d.tipBaseTotal = res.agg.tipsTotal
        d.tipRestaurant = res.agg.tipsTotal * 0.5
        d.tipBarTakeaway = res.agg.tipsTotal * 0.5

        // Grand total (sales + tips)
        d.grandTotal = res.agg.grandTotal

        // Exceptions best effort
        d.discountsCount = res.agg.discountsCount
        d.discountsAmount = res.agg.discountsTotal
        d.ordersOTHCount = res.agg.ordersOTHCount
        d.ordersOTHAmount = res.agg.ordersOTHAmount
        return d
    }

    static func applyingZReport(_ res: ZReportsSinceResponse, onto base: Self) -> Self {
        var d = base
        guard let latest = res.reports.max(by: { $0.rangeFrom < $1.rangeFrom }) else { return d }

        // Payments
        d.cashCount = latest.cashCount
        d.cashAmount = latest.cashTotal
        d.cardCount = latest.cardCount
        d.cardAmount = latest.cardTotal
        d.collectionsTotalCount = latest.cashCount + latest.cardCount
        d.collectionsTotalAmount = latest.cashTotal + latest.cardTotal

        // Sales totals (best effort)
        d.totalSalesIncVat = latest.grossTotal
        d.grandTotal = latest.grossTotal

        // Tips (your struct uses these in tables)
        d.tipsTotal = latest.tipsTotal

        // Note: don't set ordersCount (no such field)
        return d
    }
}

struct AdminOrderDTO: Decodable {
    let id: Int
    let ticketNumber: Int?
    let customerDisplayName: String?
    let service: String?
    let items: [AdminOrderLineDTO]
}

struct AdminOrderLineDTO: Decodable {
    let productId: Int?
    let name: String
    let quantity: Int
    let unitPrice: Double
    let modifiers: String?
    let isOth: Bool?
    let updatedAt: Date?
}

struct OrderMetadataDTO: Decodable {
    let schema: String?
    let shopId: Int?
    let ticketNumber: Int?

    let customerDisplayName: String?
    let service: String?

    let teamTab: TeamTabDTO?

    // ✅ basket lines (now may include isCancelled per line)
    let basket: [OrderBasketLineDTO]?

    let totals: OrderTotalsDTO?
    let payment: PaymentDTO?

    // ✅ optional close info (useful when backend auto-closes after all cancelled)
    let close: CloseDTO?
}

struct CloseDTO: Decodable {
    let closeType: String?
    let closedAtUtc: String?
}

struct TeamTabDTO: Decodable {
    let orderType: String?
    let tabKey: String?
    let isClosed: Bool?
    let businessDate: String?
}

struct OrderBasketLineDTO: Decodable {
    let lineId: Int
    let productId: Int
    let name: String
    let quantity: Int
    let unitPrice: Double
    let modifiers: String?
    let isOth: Bool?
    let isCancelled: Bool?   // ✅ ADD THIS
}

struct OrderTotalsDTO: Decodable {
    let subtotal: Double?
    let discount: Double?
    let excluded: Double?
    let tip: Double?
    let total: Double?
    let grandTotal: Double?
    let currency: String?
}

struct PaymentDTO: Decodable {
    let provider: String?
    let method: String?
    let cardAmount: Double?
    let cashAmount: Double?
}


