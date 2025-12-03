import Foundation
import SwiftUI
import PassKit
import StoreKit
import UIKit

let primariesFontName = "PrimariesMLAAA-DemiBold"

@MainActor
final class MenuApiModel: ObservableObject {
    @Published var items: [ShellMenuItem] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var version: Int = 0

    func load(shopId explicit: String? = nil, skipCache: Bool = false) {
        let shopId = "12"
        let t = Int(Date().timeIntervalSince1970)
        guard let url = URL(string: "https://minis.studio/json/\(shopId).json?\(t)") else {
            errorMessage = "Invalid URL"
            return
        }
        let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("shop_\(shopId).json")

        isLoading = true
        errorMessage = nil

        // 👇 only show cache if skipCache == false
        if !skipCache, let cached = try? Data(contentsOf: cacheURL) {
            Task { await parseAndApply(data: cached) }
        }

        URLSession.shared.dataTask(with: url) { [weak self] data, _, err in
            guard let self else { return }
            if let err = err {
                Task { @MainActor in
                    self.isLoading = false
                    self.errorMessage = err.localizedDescription
                }
                return
            }
            guard let data else {
                Task { @MainActor in
                    self.isLoading = false
                    self.errorMessage = "No data received"
                }
                return
            }
            try? data.write(to: cacheURL)
            Task { await self.parseAndApply(data: data) }
        }.resume()
    }

    private func parseAndApply(data: Data) async {
        do {
            if let wrapper = try? JSONDecoder().decode(ShopPayload.self, from: data),
               let products = wrapper.products {
                await apply(mapProducts(products))
                return
            }
            let products = try JSONDecoder().decode([ProductPayload].self, from: data)
            await apply(mapProducts(products))
        } catch {
            await MainActor.run {
                errorMessage = "JSON parse error: \(error.localizedDescription)"
                isLoading = false
            }
        }
    }

    private func apply(_ newItems: [ShellMenuItem]) async {
        await MainActor.run {
            items = newItems
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
                stockQuantity: $0.stockQuantity      // 👈 NEW
            )
        }
    }

    private func mapModifiers(from apiGroups: [ApiModifierGroup]?) -> [ModifierGroup]? {
        guard let apiGroups, !apiGroups.isEmpty else { return nil }
        let groups = apiGroups.compactMap { g -> ModifierGroup? in
            let items = (g.items ?? []).map {
                ModifierItem(name: $0.optionName ?? "", extraPrice: $0.extraPrice ?? 0)
            }
            let type: ModifierGroup.GroupType = (g.type?.lowercased() == "additions") ? .additions : .options
            return ModifierGroup(type: type, title: g.title ?? "בחירה", items: items)
        }
        return groups.isEmpty ? nil : groups
    }
}

struct ShopPayload: Decodable {
    let products: [ProductPayload]?
}

struct ProductPayload: Decodable {
    let productId: Int
    let name: String
    let price: Double
    let category: String
    let status: Int?
    let stockQuantity: Int?    // 👈 NEW
    let image: String?
    let description: String?
    let modifiers: [ApiModifierGroup]?

    enum CodingKeys: String, CodingKey {
        case productId      = "ProductId"
        case name           = "Name"
        case price          = "Price"
        case category       = "Category"
        case status         = "Status"
        case stockQuantity  = "StockQuantity"   // 👈 NEW
        case image          = "Image"
        case description    = "Description"
        case modifierGroups = "ModifierGroups"
        case legacyModifiers = "Modifiers"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        productId      = try c.decode(Int.self,    forKey: .productId)
        name           = try c.decode(String.self, forKey: .name)
        price          = try c.decode(Double.self, forKey: .price)
        category       = try c.decode(String.self, forKey: .category)
        status         = try c.decodeIfPresent(Int.self, forKey: .status)
        stockQuantity  = try c.decodeIfPresent(Int.self, forKey: .stockQuantity)   // 👈 NEW
        image          = try c.decodeIfPresent(String.self, forKey: .image)
        description    = try c.decodeIfPresent(String.self, forKey: .description)

        if let groups = try c.decodeIfPresent([ApiModifierGroup].self, forKey: .modifierGroups) {
            modifiers = groups
        } else {
            modifiers = try c.decodeIfPresent([ApiModifierGroup].self, forKey: .legacyModifiers)
        }
    }
}

struct ApiModifierGroup: Decodable {
    let type: String?
    let title: String?
    let items: [ApiModifierItem]?

    enum CodingKeys: String, CodingKey {
        case type = "Type"
        case title = "Title"
        case items = "Items"
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
    let status: Int?          // 0 = out of stock, 1 = in stock, nil = treat as in stock
    let stockQuantity: Int?   // 👈 NEW

    
    var img: URL? {
        if let s = imageURL, !s.isEmpty {
            return URL(string: s)
        }
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
        stockQuantity: Int? = nil    // 👈 NEW
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
        entries: [BasketEntry],
        total: Double,
        diningMode: DiningMode,
        source: String,
        customerName: String? = nil,
        customerPhone: String? = nil,
        payment: PaymentSummary? = nil,
        zcreditMeta: [String: Any]? = nil,
        completion: @escaping (Result<Int, Error>) -> Void
    ) {
        let shopId = 12
        let uuid = UserDefaults.standard.string(forKey: "anonUUID") ?? UUID().uuidString
        let defaultEmail = UserDefaults.standard.string(forKey: "userEmail") ?? "customer@example.com"
        let defaultName  = UserDefaults.standard.string(forKey: "userName")  ?? "Customer"

        let effectiveName: String = {
            let trimmed = customerName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? defaultName : trimmed
        }()

        let basketPayload: [[String: Any]] = entries.map { entry in
            let unit = entry.unitPrice
            return [
                "productId": entry.item.id,
                "name":      entry.item.name,
                "quantity":  entry.quantity,
                "price":     unit,                // server expects this
                "unitPrice": unit,                // optional, for future
                "modifiers": entry.subtitle ?? "" // notes / modifiers
            ]
        }

        let apnsToken = UserDefaults.standard.string(forKey: "apnsToken") ?? ""

        let serviceValue: String = {
            switch diningMode {
            case .dineIn:   return "sit"
            case .takeAway: return "ta"
            }
        }()

        var payload: [String: Any] = [
            "uuid": uuid,
            "email": defaultEmail,
            "name": effectiveName,
            "miniAppId": shopId,
            "total": total,
            "basket": basketPayload,
            "diningMode": diningMode.rawValue,
            "service": serviceValue,
            "device": [
                "platform": "ios",
                "token": apnsToken
            ]
        ]

        // 🧾 Optional: rich payment summary
        if let payment {
            // Clamp to 2 decimals just to be safe
            func r2(_ x: Double) -> Double {
                (x * 100).rounded() / 100
            }

            let cash = r2(max(payment.cashAmount, 0))
            let card = r2(max(payment.cardAmount, 0))

            payload["payment"] = [
                "method": payment.method.rawValue,
                "cashAmount": cash,
                "cardAmount": card,
                "totalPaid": cash + card
            ]
        }

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

        // 💳 ZCredit meta – include paymentMethod if we know it
        var finalMeta: [String: Any] = zcreditMeta ?? [:]

        if let payment {
            // Don’t overwrite if caller explicitly set paymentMethod
            if finalMeta["paymentMethod"] == nil {
                finalMeta["paymentMethod"] = payment.method.rawValue
            }
        }

        if !finalMeta.isEmpty {
            payload["zcreditMeta"] = finalMeta
        }

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
    let approved: Bool
    let message: String
    let referenceNumber: String?
}

final class ZCreditPaymentHandler {
    static let shared = ZCreditPaymentHandler()

    private let baseURL = URL(string: "https://minis.studio")!

    private var statusTimer: Timer?
    private var timeoutTimer: Timer?

    private var currentCorrelationId: String?
    private var currentReferenceOrSession: String?
    private var currentSessionId: String?
    private var currentPinpadId: String?

    func pay(amount: Double,
             orderId: Int?,
             completion: @escaping (ZCreditResult) -> Void) {

          //  UserDefaults.standard.set("48796294", forKey: "pinpadId")   // cashpoint 1
        UserDefaults.standard.set("48796855", forKey: "pinpadId")   // cashpoint 2
        
        let safeAmount = max(0, amount)
        let pinpadId = UserDefaults.standard.string(forKey: "pinpadId") ?? "48796294"
        let correlationId = UUID().uuidString

        currentCorrelationId = correlationId
        currentPinpadId = pinpadId

        let startBody: [String: Any] = [
            "amount": safeAmount,
            "currency": "ILS",
            "authOnly": false,
            "orderId": orderId != nil ? String(orderId!) : "",
            "pinpadId": pinpadId
        ]

        guard let startURL = URL(string: "/payments/zcredit/start", relativeTo: baseURL) else {
            completion(.init(approved: false,
                             message: "שגיאה בכתובת השרת",
                             referenceNumber: nil))
            return
        }

        var req = URLRequest(url: startURL, timeoutInterval: 45)
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

            if let error = error {
                self.finish(approved: false,
                            message: "שגיאה בתחילת עסקה במסוף: \(error.localizedDescription)",
                            referenceNumber: nil,
                            completion: completion)
                return
            }

            guard
                let http = resp as? HTTPURLResponse,
                let data = data,
                http.statusCode == 200,
                let txt = String(data: data, encoding: .utf8),
                !txt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                self.finish(approved: false,
                            message: "שגיאה בתחילת עסקה במסוף",
                            referenceNumber: nil,
                            completion: completion)
                return
            }

            var sessionId: String?
            var referenceNumber: String?

            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                sessionId =
                    obj["sessionId"] as? String ??
                    obj["SessionId"] as? String
                referenceNumber =
                    obj["referenceNumber"] as? String ??
                    obj["ReferenceNumber"] as? String
            }

            guard let sid = sessionId else {
                self.finish(approved: false,
                            message: "חסר מזהה עסקה מהמסוף",
                            referenceNumber: nil,
                            completion: completion)
                return
            }

            let idForStatus = referenceNumber ?? sid
            self.currentReferenceOrSession = idForStatus
            self.currentSessionId = sid

            DispatchQueue.main.async {
                self.startStatusPolling(id: idForStatus,
                                        correlationId: correlationId,
                                        completion: completion)
            }
        }.resume()
    }

    private func startStatusPolling(id: String,
                                    correlationId: String,
                                    completion: @escaping (ZCreditResult) -> Void) {

        invalidateTimers()

        guard let statusURL = URL(string: "/payments/zcredit/status/\(id)", relativeTo: baseURL) else {
            finish(approved: false,
                   message: "שגיאה בכתובת השרת",
                   referenceNumber: nil,
                   completion: completion)
            return
        }

        statusTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }

            var req = URLRequest(url: statusURL, timeoutInterval: 10)
            req.httpMethod = "GET"
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue(correlationId, forHTTPHeaderField: "x-correlation-id")

            URLSession.shared.dataTask(with: req) { data, resp, _ in
                guard let data = data,
                      let http = resp as? HTTPURLResponse,
                      http.statusCode == 200,
                      !data.isEmpty
                else { return }

                let env = self.parseEnvelope(data: data)

                if env.code == "-80" {
                    return
                }

                if env.code == "-50101" {
                    self.finish(approved: false,
                                message: "מכשיר הסליקה עסוק בתהליך אחר. ודאו שהמסוף במסך המתנה ונסו שוב.",
                                referenceNumber: env.ref,
                                completion: completion)
                    return
                }

                if env.code == "0" {
                    self.finish(approved: true,
                                message: env.msg.isEmpty ? "אושר" : env.msg,
                                referenceNumber: env.ref,
                                completion: completion)
                    return
                }

                if !env.code.isEmpty {
                    self.finish(approved: false,
                                message: env.msg.isEmpty ? "העסקה לא אושרה" : env.msg,
                                referenceNumber: env.ref,
                                completion: completion)
                    return
                }

            }.resume()
        }

        timeoutTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.finish(approved: false,
                        message: "זמן מקסימלי עבר ללא תגובה מהמסוף",
                        referenceNumber: nil,
                        completion: completion)
        }
    }

    private func invalidateTimers() {
        statusTimer?.invalidate()
        timeoutTimer?.invalidate()
        statusTimer = nil
        timeoutTimer = nil
    }

    private func finish(approved: Bool,
                        message: String,
                        referenceNumber: String?,
                        completion: @escaping (ZCreditResult) -> Void) {
        invalidateTimers()
        currentCorrelationId = nil
        currentReferenceOrSession = nil
        currentSessionId = nil

        let result = ZCreditResult(approved: approved,
                                   message: message,
                                   referenceNumber: referenceNumber)
        DispatchQueue.main.async {
            completion(result)
        }
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
    
    private func parseEnvelope(data: Data) -> (code: String, msg: String, ref: String?) {
        do {
            let topAny = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let rawAny: Any
            if let rawStr = topAny["raw"] as? String,
               let rawData = rawStr.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: rawData) {
                rawAny = obj
            } else {
                rawAny = topAny
            }

            let raw = rawAny as? [String: Any] ?? [:]

            let code: String
            if let c = raw["ReturnCode"] {
                code = String(describing: c)
            } else {
                code = ""
            }

            let msg =
                (raw["ReturnMessage"] as? String ??
                 raw["ZCreditMessage"] as? String ??
                 raw["message"] as? String ??
                 "").trimmingCharacters(in: .whitespacesAndNewlines)

            let ref =
                raw["ReferenceNumber"] as? String ??
                raw["referenceNumber"] as? String

            return (code, msg, ref)
        } catch {
            return ("", "", nil)
        }
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
 func saveReferralForCurrentShop(kind: MiniKind = .fastlane) {
    guard let shopIdString = UserDefaults.standard.string(forKey: "shopId"),
          let shopId = Int(shopIdString) else {
        return
    }

    let defaults = UserDefaults(suiteName: "group.minis")
    var referrals: [MiniReferral] = []

    // Load existing
    if let data = defaults?.data(forKey: "miniReferralsJSON"),
       let decoded = try? JSONDecoder().decode([MiniReferral].self, from: data) {
        referrals = decoded
    }

    // HARD-CODED referral data
    let title = "בית העם"
    let subtitle = "תפריט בוקר"
    let imageURL = "https://img.mako.co.il/2024/11/24/beithaam_vitrina_re_autoOrient_i.jpg"

    if let idx = referrals.firstIndex(where: { $0.miniAppId == shopId && $0.kind == kind }) {

        let old = referrals.remove(at: idx)

        let updated = MiniReferral(
            title: title,
            subtitle: subtitle,
            miniAppId: shopId,
            imageURL: imageURL,
            sharedAt: Date(),     // refresh timestamp
            kind: old.kind
        )

        referrals.insert(updated, at: 0)

    } else {

        let newReferral = MiniReferral(
            title: title,
            subtitle: subtitle,
            miniAppId: shopId,
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

