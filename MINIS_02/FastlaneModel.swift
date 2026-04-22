import Foundation
import SwiftUI
import PassKit
import StoreKit
import UIKit
import Combine

let primariesFontName = "PrimariesMLAAA-DemiBold"

enum DeviceKeys {
    static let apnsToken = "apns.token.v1"
}

enum MenuDecodeContext {
    static var isAdminMode: Bool = true
}

func loadApnsToken() -> String {
    // Prefer App Group if available
    if let suite = UserDefaults(suiteName: "group.minis") {
        let t = (suite.string(forKey: DeviceKeys.apnsToken) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
    }

    // Fallback standard
    return (UserDefaults.standard.string(forKey: DeviceKeys.apnsToken) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

func saveApnsToken(_ token: String) {
    let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty else { return }

    UserDefaults.standard.set(t, forKey: DeviceKeys.apnsToken)

    if let suite = UserDefaults(suiteName: "group.minis") {
        suite.set(t, forKey: DeviceKeys.apnsToken)
        suite.synchronize()
    }

    UserDefaults.standard.synchronize()
}

@MainActor
final class MenuApiModel: ObservableObject {
    @Published var items: [ShellMenuItem] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var version: Int = 0
    @Published var categoryOrder: [String] = []
    @Published private var nowTick: Int = 0
    private var clockTimer: AnyCancellable?
    @Published private var allItems: [ShellMenuItem] = []
    @Published var isOpen: Bool = true
    private var isAdminMode: Bool {
        return true
       // UserDefaults.standard.bool(forKey: "admin")
    }
    // ✅ ADD
      private var isOpenDebugCancellable: AnyCancellable?
      private var lastIsOpenDebug: Bool?
    
    init() {
          // prime the last value so we can print old → new
          lastIsOpenDebug = isOpen

          isOpenDebugCancellable = $isOpen
              .removeDuplicates()
              .sink { [weak self] newValue in
                  guard let self else { return }
                  let oldValue = self.lastIsOpenDebug
                  self.lastIsOpenDebug = newValue

                  if let oldValue, oldValue != newValue {
                      print("🟣 MenuApiModel.isOpen changed:", oldValue, "→", newValue)
                  } else if oldValue == nil {
                      print("🟣 MenuApiModel.isOpen initial:", newValue)
                  }
              }
      }
    
    
    private struct ProductsLastUpdateProbe: Decodable {
        struct Mini: Decodable {
            let productsLastUpdate: String?
            let isOpen: Bool?
        }
        let mini: Mini?
    }
    
    func load(shopId explicit: String? = nil, skipCache: Bool = false) {
        let defaults = UserDefaults.standard
        let miniAppIdFromDefaults = defaults.integer(forKey: "miniAppId")
        let storedShopId = defaults.string(forKey: "shopId")

        let shopId: String
        if let explicit = explicit, !explicit.isEmpty {
            shopId = explicit
        } else if miniAppIdFromDefaults > 0 {
            shopId = String(miniAppIdFromDefaults)
        } else if let storedShopId, !storedShopId.isEmpty {
            shopId = storedShopId
        } else {
            errorMessage = "No shop selected"
            return
        }

        let baseURL = "https://minis.studio/json/\(shopId).json"
        let t = Int(Date().timeIntervalSince1970)
        guard let url = URL(string: "\(baseURL)?\(t)") else {
            errorMessage = "Invalid URL"
            return
        }

        let cacheKey = "MenuJSON_\(shopId)"
        let cacheTsKey = "MenuJSON_TS_\(shopId)"          // productsLastUpdate string
        let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("shop_\(shopId).json")

        isLoading = true
        errorMessage = nil

        // --------------------------------------------
        // 1) FAST PATH: show cache immediately (if allowed)
        // --------------------------------------------
        var cachedData: Data? = nil

        if !skipCache, items.isEmpty {
            if let d = defaults.data(forKey: cacheKey) {
                cachedData = d
                Task { await parseAndApply(data: d) }
            } else if let f = try? Data(contentsOf: cacheURL) {
                cachedData = f
                Task { await parseAndApply(data: f) }
            }
        }

        // --------------------------------------------
        // 2) Cache helpers
        // --------------------------------------------
        func decodeProductsLastUpdate(_ data: Data) -> String? {
            let dec = JSONDecoder()
            if let probe = try? dec.decode(ProductsLastUpdateProbe.self, from: data) {
                return probe.mini?.productsLastUpdate
            }
            return nil
        }

        func decodeIsOpen(_ data: Data) -> Bool? {
            let dec = JSONDecoder()
            return (try? dec.decode(ProductsLastUpdateProbe.self, from: data))?.mini?.isOpen
        }

        let cachedTs = defaults.string(forKey: cacheTsKey) ?? (cachedData.flatMap(decodeProductsLastUpdate) ?? "")

        // --------------------------------------------
        // 3) Full fetch (always updates cache + parses)
        // --------------------------------------------
        func fetchFullJSON() {
            var req = URLRequest(url: url, timeoutInterval: 15)
            req.setValue("no-store", forHTTPHeaderField: "Cache-Control")

            URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
                guard let self else { return }

                if let err = err {
                    Task { @MainActor in
                        self.isLoading = false
                        if self.items.isEmpty { self.errorMessage = err.localizedDescription }
                    }
                    return
                }

                guard let http = resp as? HTTPURLResponse else {
                    Task { @MainActor in
                        self.isLoading = false
                        if self.items.isEmpty { self.errorMessage = "No HTTP response" }
                    }
                    return
                }

                guard let data else {
                    Task { @MainActor in
                        self.isLoading = false
                        if self.items.isEmpty { self.errorMessage = "No data received" }
                    }
                    return
                }

                // ✅ Reject non-2xx
                guard (200...299).contains(http.statusCode) else {
                    let text = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
                    Task { @MainActor in
                        self.isLoading = false
                        if self.items.isEmpty { self.errorMessage = "HTTP \(http.statusCode)" }
                    }
                    print("❌ MenuApiModel.load HTTP \(http.statusCode) body:", String(text.prefix(300)))
                    return
                }

                // ✅ Validate JSON BEFORE caching (prevents cache poisoning)
                let dec = JSONDecoder()
                let isValid =
                    (try? dec.decode(ShopPayload.self, from: data)) != nil
                    || (try? dec.decode([ProductPayload].self, from: data)) != nil

                guard isValid else {
                    let text = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
                    Task { @MainActor in
                        self.isLoading = false
                        if self.items.isEmpty { self.errorMessage = "Bad JSON" }
                    }
                    print("❌ MenuApiModel.load: invalid JSON, NOT caching. First 300:", String(text.prefix(300)))
                    return
                }

                // ✅ Cache only valid JSON
                defaults.set(data, forKey: cacheKey)
                try? data.write(to: cacheURL, options: [.atomic])

                // ✅ Cache productsLastUpdate for quick future comparisons
                if let ts = decodeProductsLastUpdate(data), !ts.isEmpty {
                    defaults.set(ts, forKey: cacheTsKey)
                }

                Task { await self.parseAndApply(data: data) }
            }.resume()
        }

        // If skipping cache, always fetch full (network)
        if skipCache {
            fetchFullJSON()
            return
        }

        // If we have no cache at all, fetch full
        if cachedData == nil {
            fetchFullJSON()
            return
        }

        // --------------------------------------------
        // 4) Probe server quickly: keep products caching logic,
        //    BUT ALWAYS update isOpen from probe (fixes NightView)
        // --------------------------------------------
        guard let probeURL = URL(string: "\(baseURL)?probe=\(t)") else {
            fetchFullJSON()
            return
        }

        var probeReq = URLRequest(url: probeURL, timeoutInterval: 8)
        probeReq.setValue("no-store", forHTTPHeaderField: "Cache-Control")

        URLSession.shared.dataTask(with: probeReq) { [weak self] data, resp, err in
            guard let self else { return }

            // If probe fails, still fetch full (best effort)
            guard err == nil, let data = data else {
                fetchFullJSON()
                return
            }

            // ✅ NEW: update isOpen even if productsLastUpdate didn't change
            if let open = decodeIsOpen(data) {
                Task { @MainActor in
                    let old = self.isOpen
                    if old != open {
                        self.isOpen = open
                        print("🟡 PROBE mini.isOpen changed:", old, "→", open)
                    }
                }
            } else {
                print("⚠️ PROBE mini.isOpen missing / failed decode")
            }

            let serverTs = decodeProductsLastUpdate(data) ?? ""

            // If server doesn't provide timestamp, safest: fetch full
            if serverTs.isEmpty {
                fetchFullJSON()
                return
            }

            // ✅ Cache is fresh -> stop loading (but isOpen already updated above)
            if !cachedTs.isEmpty, cachedTs == serverTs {
                Task { @MainActor in
                    self.isLoading = false
                }
                return
            }

            // Cache is stale -> fetch full + update cache
            fetchFullJSON()
        }.resume()
    }
    
    private func applyCategoryOrder(_ items: [ShellMenuItem], order: [String]?) -> [ShellMenuItem] {
        // ✅ If no category order, return as-is (preserve server order)
        guard let order, !order.isEmpty else { return items }

        // category -> rank
        var rank: [String: Int] = [:]
        for (i, c) in order.enumerated() {
            rank[c] = i
        }

        // ✅ IMPORTANT:
        // - keep category blocks in the desired order
        // - keep product order inside category EXACTLY as it arrived from JSON
        //   (stable tie-break via original index)
        var originalIndex: [Int: Int] = [:]  // productId -> index
        originalIndex.reserveCapacity(items.count)
        for (i, it) in items.enumerated() {
            originalIndex[it.id] = i
        }

        return items.sorted { a, b in
            let ra = rank[a.category] ?? Int.max
            let rb = rank[b.category] ?? Int.max
            if ra != rb { return ra < rb }

            // ✅ same category: preserve original JSON order
            let ia = originalIndex[a.id] ?? Int.max
            let ib = originalIndex[b.id] ?? Int.max
            return ia < ib
        }
    }
    
 
    private func persistPrinters(_ printers: ShopPrintersPayload) {
        let rawShopId = UserDefaults.standard.string(forKey: "shopId")
        let miniAppId = UserDefaults.standard.integer(forKey: "miniAppId")

        let resolvedShopId: String = {
            if let s = rawShopId, !s.isEmpty { return s }
            if miniAppId > 0 { return String(miniAppId) }
            return "0"
        }()

        let key = "printers.config.shop\(resolvedShopId)"

        if let data = try? JSONEncoder().encode(printers) {
            UserDefaults.standard.set(data, forKey: key)
        }

        print("""
        🖨️ printers SAVED
          raw shopId = \(rawShopId ?? "nil")
          miniAppId  = \(miniAppId)
          key        = \(key)
          prefix     = \(printers.netPrefix ?? "nil")
          stations   = \(printers.stations?.count ?? 0)
        """)
    }

    private struct MiniOpenProbe: Decodable {
        struct Mini: Decodable {
            let isOpen: Bool?

            enum CodingKeys: String, CodingKey {
                case isOpen  = "isOpen"
                case isOpenC = "IsOpen"
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)

                // Bool
                if let b = try? c.decodeIfPresent(Bool.self, forKey: .isOpen) { isOpen = b; return }
                if let b = try? c.decodeIfPresent(Bool.self, forKey: .isOpenC) { isOpen = b; return }

                // Int 1/0
                if let i = try? c.decodeIfPresent(Int.self, forKey: .isOpen) { isOpen = (i != 0); return }
                if let i = try? c.decodeIfPresent(Int.self, forKey: .isOpenC) { isOpen = (i != 0); return }

                // String
                func parse(_ s: String?) -> Bool? {
                    guard let s else { return nil }
                    let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if t == "true" || t == "1" || t == "yes" { return true }
                    if t == "false" || t == "0" || t == "no" { return false }
                    return nil
                }
                if let s = try? c.decodeIfPresent(String.self, forKey: .isOpen), let v = parse(s) { isOpen = v; return }
                if let s = try? c.decodeIfPresent(String.self, forKey: .isOpenC), let v = parse(s) { isOpen = v; return }

                isOpen = nil
            }
        }

        let mini: Mini?
    }
    
    private func parseAndApply(data: Data) async {
       
        // 0️⃣ First, extract customization (title, subtitle, image, font, direction, currency)
        applyMiniCustomization(from: data)

        // ✅ Mini open probe (keep your existing behavior)
        do {
            let probe = try JSONDecoder().decode(MiniOpenProbe.self, from: data)
            if let open = probe.mini?.isOpen {
                await MainActor.run {
                    let old = self.isOpen
                    self.isOpen = open
                    print("✅ MINI OPEN probe:", old, "→", open)
                }
            } else {
                print("⚠️ MINI OPEN probe: missing in JSON")
            }
        } catch {
            print("❌ MINI OPEN probe decode failed:", error.localizedDescription)
        }

        do {
            let decoder = JSONDecoder()

            // 1️⃣ Try wrapper: full shop payload
            if let wrapper = try? decoder.decode(ShopPayload.self, from: data) {

                // ✅ isOpen (again, if present)
                if let open = wrapper.mini?.isOpen {
                    await MainActor.run {
                        self.isOpen = open
                        print("✅ decoded mini.isOpen =", open)
                    }
                } else {
                    print("⚠️ mini.isOpen missing / failed decode")
                }

                // ✅ category order
                if let order = wrapper.categoryOrder, !order.isEmpty {
                    await MainActor.run {
                        self.categoryOrder = order
                        let shopId = UserDefaults.standard.string(forKey: "shopId") ?? "0"
                        UserDefaults.standard.set(order, forKey: "cash.categoryOrder.shop\(shopId)")
                    }
                }

                // ✅ PRINTERS: support BOTH shapes:
                // - top-level: printers
                // - new: admin.printers  (your mini 13 JSON)
                let printersPayload = wrapper.printers ?? wrapper.admin?.printers
                print("🧪 JSON printers decoded:")
                print("   wrapper.printers?.netPrefix =", wrapper.printers?.netPrefix ?? "nil")
                print("   wrapper.admin?.printers?.netPrefix =", wrapper.admin?.printers?.netPrefix ?? "nil")

                if let raw = String(data: data, encoding: .utf8) {
                    if let r = raw.range(of: "\"netPrefix\"") {
                        let start = raw.index(r.lowerBound, offsetBy: -50, limitedBy: raw.startIndex) ?? raw.startIndex
                        let end   = raw.index(r.lowerBound, offsetBy: 80, limitedBy: raw.endIndex) ?? raw.endIndex
                        print("🧾 RAW around netPrefix:", raw[start..<end])
                    } else {
                        print("🧾 RAW has no netPrefix text")
                    }
                }
                if let printers = printersPayload {
                    await MainActor.run {
                        persistPrinters(printers)
                    }
                } else {
                    // Helpful debug so you KNOW why it fell back to LAN prefix
                    #if DEBUG
                    print("⚠️ printers missing in JSON at both wrapper.printers and wrapper.admin?.printers")
                    #endif
                }

                // ✅ products
                if let products = wrapper.products {
                    let mapped  = mapProducts(products)
                    let ordered = applyCategoryOrder(mapped, order: wrapper.categoryOrder)
                    await apply(ordered)
                    saveReferralForCurrentShop(kind: .fastlane)
                    return
                }

            } else {
                print("📦 parseAndApply → ShopPayload decode FAILED, trying plain array")
            }

            // 2️⃣ Fallback: plain [ProductPayload]
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

            // ✅ DEBUG BUNDLE CHECK
            if let it = newItems.first(where: { $0.id == 837 }) {
                print("✅ 837 exists. name=\(it.name) hasBundle=\(it.bundle != nil)")
            } else {
                print("❌ 837 product not in newItems. count=\(newItems.count)")
            }
            if let b = newItems.first(where: { $0.id == 837 })?.bundle {
                print("🍳 bundle for 837 ids=", b.cleanedIds,
                      "max=", b.maxFree,
                      "strategy=", b.normalizedStrategy)
            } else {
                print("⚠️ bundle for 837 NOT FOUND")
            }

            MenuCatalog.shared.update(items: newItems)
            isLoading = false
            version &+= 1
        }
    }

    private func mapProducts(_ products: [ProductPayload]) -> [ShellMenuItem] {
        products.map {
            ShellMenuItem(
                id: $0.productId,
                name: $0.name,
                nameI18n: $0.nameI18n,
                price: $0.price,
                category: $0.category,
                modifiers: mapModifiers(from: $0.modifiers),
                imageURL: $0.image,
                description: $0.description,
                status: $0.status,
                stockQuantity: $0.stockQuantity,
                isArchived: $0.isArchived,
                printer: $0.printer,
                printers: $0.printers,
                activeFrom: $0.activeFrom,
                activeTo: $0.activeTo,
                isPhone: $0.isPhone,
                bundle: $0.bundle
            )
        }
    }
    
    
    
    private func mapModifiers(from apiGroups: [ApiModifierGroup]?) -> [ModifierGroup]? {
        guard let apiGroups, !apiGroups.isEmpty else { return nil }

        let groups = apiGroups.compactMap { g -> ModifierGroup? in
            let items = (g.items ?? [])
                .map {
                    ModifierItem(
                        name: ($0.optionName ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                        extraPrice: $0.extraPrice ?? 0,
                        status: $0.status,
                        linkedProductId: $0.linkedProductId
                    )
                }
                .filter { !$0.name.isEmpty }

            guard !items.isEmpty else { return nil }

            let rawType = g.type?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let selectionMode = g.selection?.mode?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

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

            let selection = ModifierSelection(
                mode: g.selection?.mode,
                min: g.selection?.min,
                max: g.selection?.max,
                required: g.selection?.required,
                defaultFirst: g.selection?.defaultFirst
            )

           
            return ModifierGroup(
                type: type,
                title: (g.title ?? "Choose").trimmingCharacters(in: .whitespacesAndNewlines),
                items: items,
                groupId: UUID().uuidString,
                selection: selection
            )
        }

        return groups.isEmpty ? nil : groups
    }
}
private struct JsonModifierGroupPayload: Encodable {
    let GroupId: String
    let Title: String
    let Selection: JsonSelectionPayload
    let Items: [JsonModifierItemPayload]
}

private struct JsonSelectionPayload: Encodable {
    let mode: String
    let min: Int
    let max: Int
}

private struct JsonModifierItemPayload: Encodable {
    let OptionName: String
    let ExtraPrice: Double
}
struct ShopPayload: Decodable {
    struct Theme: Decodable {
        let direction: String?
        let currency: String?
    }

    struct Mini: Decodable {
        let isOpen: Bool?

        enum CodingKeys: String, CodingKey {
            case isOpen  = "isOpen"
            case isOpenC = "IsOpen"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)

            if let b = try? c.decodeIfPresent(Bool.self, forKey: .isOpen) { isOpen = b; return }
            if let b = try? c.decodeIfPresent(Bool.self, forKey: .isOpenC) { isOpen = b; return }

            if let i = try? c.decodeIfPresent(Int.self, forKey: .isOpen) { isOpen = (i != 0); return }
            if let i = try? c.decodeIfPresent(Int.self, forKey: .isOpenC) { isOpen = (i != 0); return }

            if let s = try? c.decodeIfPresent(String.self, forKey: .isOpen) {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if t == "true" || t == "1" { isOpen = true; return }
                if t == "false" || t == "0" { isOpen = false; return }
            }
            if let s = try? c.decodeIfPresent(String.self, forKey: .isOpenC) {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if t == "true" || t == "1" { isOpen = true; return }
                if t == "false" || t == "0" { isOpen = false; return }
            }

            isOpen = nil
        }
    }

    // ✅ NEW: admin wrapper (because JSON is admin.printers)
    struct Admin: Decodable {
        let printers: ShopPrintersPayload?
    }

    let mini: Mini?
    let theme: Theme?
    let products: [ProductPayload]?
    let categoryOrder: [String]?

    // ✅ keep top-level printers for backward compat
    let printers: ShopPrintersPayload?

    // ✅ NEW
    let admin: Admin?
}
// MARK: - Printers payload (from /json/{id}.json)
// IMPORTANT: names are unique to avoid collisions with your existing types.

struct ShopPrintersPayload: Codable {
    let netPrefix: String?
    let stations: [ShopPrinterStationPayload]?
    let backup: [ShopPrinterStationPayload]?
}

func loadSavedPrinters(shopId: String) -> ShopPrintersPayload? {
    let key = "printers.config.shop\(shopId)"

    guard let data = UserDefaults.standard.data(forKey: key) else {
        print("❌ printers LOAD: no data for key:", key)
        return nil
    }

    print("🧾 printers LOAD: found data bytes =", data.count, "key:", key)

    // Optional: print raw JSON once (great for debugging)
    if let raw = String(data: data, encoding: .utf8) {
        print("🧾 printers LOAD RAW (first 400):", String(raw.prefix(400)))
    } else {
        print("⚠️ printers LOAD: data not utf8")
    }

    do {
        let decoded = try JSONDecoder().decode(ShopPrintersPayload.self, from: data)
        print("✅ printers LOAD decoded. prefix =", decoded.netPrefix ?? "nil",
              "stations =", decoded.stations?.count ?? 0)
        return decoded
    } catch {
        print("❌ printers LOAD decode error:", error)
        return nil
    }
}

struct ShopPrinterStationPayload: Codable, Identifiable {
    let id: String
    let label: String
    let octet: Int
    let set: String?
    let status: Int?
}

// ✅ Add this somewhere above ProductPayload (or in same file)
struct LocalizedTextDto: Decodable {
    let he: String?
    let ar: String?
    let en: String?
}

struct ProductBundlePayload: Decodable {
    let setProductIds: [Int]
    let maxFreeQty: Int?
    let strategy: String?

    enum CodingKeys: String, CodingKey {
        case setProductIds = "SetProductIds"
        case maxFreeQty    = "MaxFreeQty"
        case strategy      = "Strategy"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        // ✅ tolerant: missing -> []
        setProductIds = (try? c.decodeIfPresent([Int].self, forKey: .setProductIds)) ?? []

        // ✅ tolerant: Int or String
        if let i = try? c.decodeIfPresent(Int.self, forKey: .maxFreeQty) {
            maxFreeQty = i
        } else if let s = try? c.decodeIfPresent(String.self, forKey: .maxFreeQty),
                  let i = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
            maxFreeQty = i
        } else {
            maxFreeQty = nil
        }

        strategy = try? c.decodeIfPresent(String.self, forKey: .strategy)
    }

    var cleanedIds: [Int] {
        Array(Set(setProductIds)).filter { $0 > 0 }
    }

    var maxFree: Int { max(1, maxFreeQty ?? 1) }

    var normalizedStrategy: String {
        let s = (strategy ?? "cheapest")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if s == "most_expensive" || s == "cheapest" || s == "first_added" { return s }
        return "cheapest"
    }
}

struct ProductPayload: Decodable {
    let productId: Int
    let name: String

    // ✅ multilingual name object from JSON ("nameI18n": {he,ar,en})
    let nameI18n: LocalizedTextDto?

    let price: Double
    let category: String
    let status: Int?
    let stockQuantity: Int?
    let image: String?
    let description: String?
    let modifiers: [ApiModifierGroup]?
    let printer: String?

    // ✅ multi printers from JSON
    let printers: [String]?

    // ✅ active window
    let activeFrom: Int?
    let activeTo: Int?

    // ✅ ask phone (from published JSON "isPhone")
    let isPhone: Bool?

    // ✅ bundle pricing rule
    let bundle: ProductBundlePayload?

    // ✅ admin-only archive flag
    let isArchived: Bool?

    enum CodingKeys: String, CodingKey {
        case productId       = "ProductId"
        case name            = "Name"
        case nameI18n        = "nameI18n"
        case price           = "Price"
        case category        = "Category"
        case status          = "Status"
        case stockQuantity   = "StockQuantity"
        case image           = "Image"
        case description     = "Description"

        case printer         = "Printer"
        case printerLower    = "printer"

        case printers        = "Printers"
        case printerIdsAlt   = "PrinterIds"

        case activeFrom      = "ActiveFrom"
        case activeFromLower = "activeFrom"
        case activeTo        = "ActiveTo"
        case activeToLower   = "activeTo"

        case isPhoneP        = "isPhone"
        case isPhoneC        = "IsPhone"

        case modifierGroups  = "ModifierGroups"
        case legacyModifiers = "Modifiers"

        case bundle          = "Bundle"

        // ✅ only this key, exactly as you wanted
        case isArchivedP     = "isArchived"
    }

    // ✅ supports Bool / Int / String
    private static func decodeBoolFlex(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Bool? {
        if let b = try? c.decodeIfPresent(Bool.self, forKey: key) { return b }
        if let i = try? c.decodeIfPresent(Int.self, forKey: key) { return i != 0 }
        if let s = try? c.decodeIfPresent(String.self, forKey: key) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if t == "true" || t == "1" || t == "yes" { return true }
            if t == "false" || t == "0" || t == "no" { return false }
        }
        return nil
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        productId = try c.decode(Int.self, forKey: .productId)
        name      = try c.decode(String.self, forKey: .name)

        // ✅ multilingual name
        nameI18n = try? c.decodeIfPresent(LocalizedTextDto.self, forKey: .nameI18n)

        price         = try c.decode(Double.self, forKey: .price)
        category      = try c.decode(String.self, forKey: .category)
        status        = try c.decodeIfPresent(Int.self, forKey: .status)
        stockQuantity = try c.decodeIfPresent(Int.self, forKey: .stockQuantity)
        image         = try c.decodeIfPresent(String.self, forKey: .image)
        description   = try c.decodeIfPresent(String.self, forKey: .description)

        // ✅ legacy single printer
        let p =
            (try? c.decodeIfPresent(String.self, forKey: .printer)) ??
            (try? c.decodeIfPresent(String.self, forKey: .printerLower))

        printer = p?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        // ✅ printers[]
        let rawPrinters =
            (try? c.decodeIfPresent([String].self, forKey: .printers)) ??
            (try? c.decodeIfPresent([String].self, forKey: .printerIdsAlt))

        if let rawPrinters {
            let cleaned = rawPrinters
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            printers = cleaned.isEmpty ? nil : cleaned
        } else {
            printers = nil
        }

        activeFrom =
            (try? c.decodeIfPresent(Int.self, forKey: .activeFrom)) ??
            (try? c.decodeIfPresent(Int.self, forKey: .activeFromLower))

        activeTo =
            (try? c.decodeIfPresent(Int.self, forKey: .activeTo)) ??
            (try? c.decodeIfPresent(Int.self, forKey: .activeToLower))

        // ✅ isPhone
        isPhone =
            Self.decodeBoolFlex(c, .isPhoneP) ??
            Self.decodeBoolFlex(c, .isPhoneC)

        // ✅ bundle
        bundle = try? c.decodeIfPresent(ProductBundlePayload.self, forKey: .bundle)

        // ✅ modifiers
        if let groups = try c.decodeIfPresent([ApiModifierGroup].self, forKey: .modifierGroups) {
            modifiers = groups
        } else {
            modifiers = try c.decodeIfPresent([ApiModifierGroup].self, forKey: .legacyModifiers)
        }

        // ✅ admin-only parse
        if MenuDecodeContext.isAdminMode {
            isArchived = Self.decodeBoolFlex(c, .isArchivedP)
        } else {
            isArchived = nil
        }
    }
}

struct ApiSelection: Decodable {
    let mode: String?
    let min: Int?
    let max: Int?
    let required: Int?
    let defaultFirst: Int?

    enum CodingKeys: String, CodingKey {
        case mode
        case min
        case max
        case required
        case defaultFirst
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        mode = try? c.decodeIfPresent(String.self, forKey: .mode)

        func decodeFlexibleInt(_ key: CodingKeys) -> Int? {
            if let i = try? c.decodeIfPresent(Int.self, forKey: key) {
                return i
            }
            if let s = try? c.decodeIfPresent(String.self, forKey: key) {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                return Int(t)
            }
            if let b = try? c.decodeIfPresent(Bool.self, forKey: key) {
                return b ? 1 : 0
            }
            return nil
        }

        min = decodeFlexibleInt(.min)
        max = decodeFlexibleInt(.max)
        required = decodeFlexibleInt(.required)
        defaultFirst = decodeFlexibleInt(.defaultFirst)
    }
}

struct ApiModifierGroup: Decodable {
    let type: String?
    let title: String?
    let items: [ApiModifierItem]?
    let selection: ApiSelection?

    enum CodingKeys: String, CodingKey {
        case typeP = "Type"
        case typeC = "type"

        case titleP = "Title"
        case titleC = "title"

        case itemsP = "Items"
        case itemsC = "items"

        case selectionP = "Selection"
        case selectionC = "selection"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        type =
            (try? c.decodeIfPresent(String.self, forKey: .typeP)) ??
            (try? c.decodeIfPresent(String.self, forKey: .typeC))

        title =
            (try? c.decodeIfPresent(String.self, forKey: .titleP)) ??
            (try? c.decodeIfPresent(String.self, forKey: .titleC))

        items =
            (try? c.decodeIfPresent([ApiModifierItem].self, forKey: .itemsP)) ??
            (try? c.decodeIfPresent([ApiModifierItem].self, forKey: .itemsC))

        selection =
            (try? c.decodeIfPresent(ApiSelection.self, forKey: .selectionP)) ??
            (try? c.decodeIfPresent(ApiSelection.self, forKey: .selectionC))
    }
}

struct ApiModifierItem: Decodable {
    let optionName: String?
    let extraPrice: Double?
    let status: Int?
    let linkedProductId: Int?

    enum CodingKeys: String, CodingKey {
        case optionName = "OptionName"
        case extraPrice = "ExtraPrice"
        case status = "Status"
        case linkedProductId = "LinkedProductId"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        optionName = try? c.decodeIfPresent(String.self, forKey: .optionName)

        if let d = try? c.decodeIfPresent(Double.self, forKey: .extraPrice) {
            extraPrice = d
        } else if let i = try? c.decodeIfPresent(Int.self, forKey: .extraPrice) {
            extraPrice = Double(i)
        } else if let s = try? c.decodeIfPresent(String.self, forKey: .extraPrice) {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: ",", with: ".")
            extraPrice = Double(trimmed)
        } else {
            extraPrice = nil
        }

        if let i = try? c.decodeIfPresent(Int.self, forKey: .status) {
            status = i
        } else if let s = try? c.decodeIfPresent(String.self, forKey: .status) {
            status = Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            status = nil
        }

        if let i = try? c.decodeIfPresent(Int.self, forKey: .linkedProductId) {
            linkedProductId = i
        } else if let s = try? c.decodeIfPresent(String.self, forKey: .linkedProductId) {
            linkedProductId = Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            linkedProductId = nil
        }
    }
}


struct ShellMenuItem: Identifiable {
    let id: Int

    // ✅ Base (legacy) name from JSON "Name"
    let name: String

    // ✅ NEW: i18n names from JSON "nameI18n"
    let nameI18n: LocalizedTextDto?

    let price: Double
    let category: String
    let modifiers: [ModifierGroup]?
    let imageURL: String?
    let description: String?
    let status: Int?
    let stockQuantity: Int?

    // ✅ NEW: keep original MiniAppId so archived products (-14 etc.) can be shown under "ארכיון"
    let isArchived: Bool?

    // ✅ OLD (keep for safety / backward compat)
    let printer: String?

    // ✅ NEW (multi route)
    let printers: [String]?

    // ✅ Active window
    let activeFrom: Int?
    let activeTo: Int?

    // ✅ NEW: ask phone (from JSON isPhone)
    let isPhone: Bool?

    // ✅ NEW: Bundle (free drink set etc.)
    let bundle: ProductBundlePayload?

    var img: URL? {
        if let s = imageURL, !s.isEmpty { return URL(string: s) }
        return nil
    }

    var priceLabel: String { String(format: "%.2f", price) }

    /// ✅ DEBUG: language-aware display name
    var displayName: String {
        let lang = (UserDefaults.standard.string(forKey: LangKeys.lang) ?? "he")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        func clean(_ s: String?) -> String {
            (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let he = clean(nameI18n?.he)
        let ar = clean(nameI18n?.ar)
        let en = clean(nameI18n?.en)
        let base = name.trimmingCharacters(in: .whitespacesAndNewlines)

        switch lang {
        case "ar":
            return !ar.isEmpty ? ar : (!he.isEmpty ? he : (!en.isEmpty ? en : base))
        case "en":
            return !en.isEmpty ? en : (!he.isEmpty ? he : (!ar.isEmpty ? ar : base))
        default: // "he"
            return !he.isEmpty ? he : (!en.isEmpty ? en : (!ar.isEmpty ? ar : base))
        }
    }

    /// ✅ ONE printer id convenience
    var effectivePrinterId: String? {
        if let list = printers,
           let first = list.first?.trimmingCharacters(in: .whitespacesAndNewlines),
           !first.isEmpty {
            return first
        }
        if let p = printer?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty {
            return p
        }
        return nil
    }

    /// ✅ Convenience: treat nil as false
    var requiresPhone: Bool { (isPhone ?? false) }

    /// ✅ Archive helpers
    var archived: Bool { isArchived ?? false }

    // ✅ Bundle helpers (optional but useful)
    var hasBundle: Bool { bundle?.cleanedIds.isEmpty == false }
    var bundleEligibleDrinkIds: [Int] { bundle?.cleanedIds ?? [] }

    init(
        id: Int,
        name: String,
        nameI18n: LocalizedTextDto? = nil,
        price: Double,
        category: String,
        modifiers: [ModifierGroup]?,
        imageURL: String?,
        description: String?,
        status: Int? = nil,
        stockQuantity: Int? = nil,

        // ✅ NEW
        isArchived: Bool? = nil,

        // ✅ old
        printer: String? = nil,

        // ✅ new
        printers: [String]? = nil,

        activeFrom: Int? = nil,
        activeTo: Int? = nil,

        // ✅ NEW
        isPhone: Bool? = nil,

        // ✅ NEW
        bundle: ProductBundlePayload? = nil
    ) {
        self.id = id
        self.name = name
        self.nameI18n = nameI18n

        self.price = price
        self.category = category
        self.modifiers = modifiers
        self.imageURL = imageURL
        self.description = description
        self.status = status
        self.stockQuantity = stockQuantity
        self.isArchived = isArchived

        // Normalize stored values a bit
        let p1 = printer?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.printer = (p1?.isEmpty ?? true) ? nil : p1

        if let printers {
            let cleaned = printers
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            self.printers = cleaned.isEmpty ? nil : cleaned
        } else {
            self.printers = nil
        }

        self.activeFrom = activeFrom
        self.activeTo = activeTo
        self.isPhone = isPhone

        // ✅ bundle
        self.bundle = bundle
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


struct ModifierSelection: Codable, Hashable, Equatable {
    var mode: String?
    var min: Int?
    var max: Int?
    var required: Int?
    var defaultFirst: Int?
}

struct ModifierItem: Identifiable, Codable, Hashable, Equatable {
    var id: String {
        if let linkedProductId {
            return "\(name)_\(linkedProductId)"
        }
        return name
    }

    let name: String
    let extraPrice: Double
    let status: Int?
    let linkedProductId: Int?

    init(
        name: String,
        extraPrice: Double,
        status: Int? = nil,
        linkedProductId: Int? = nil
    ) {
        self.name = name
        self.extraPrice = extraPrice
        self.status = status
        self.linkedProductId = linkedProductId
    }

    enum CodingKeys: String, CodingKey {
        case name = "OptionName"
        case extraPrice = "ExtraPrice"
        case status = "Status"
        case linkedProductId = "LinkedProductId"
    }

    enum LocalCodingKeys: String, CodingKey {
        case name
        case extraPrice
        case status
        case linkedProductId
    }

    init(from decoder: Decoder) throws {
        if let c = try? decoder.container(keyedBy: CodingKeys.self) {
            let apiName = (try? c.decode(String.self, forKey: .name))?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if let apiName, !apiName.isEmpty {
                self.name = apiName
                self.extraPrice = (try? c.decode(Double.self, forKey: .extraPrice)) ?? 0
                self.status = try? c.decode(Int.self, forKey: .status)
                self.linkedProductId = try? c.decodeIfPresent(Int.self, forKey: .linkedProductId)
                return
            }
        }

        let c = try decoder.container(keyedBy: LocalCodingKeys.self)
        self.name = (try? c.decode(String.self, forKey: .name)) ?? ""
        self.extraPrice = (try? c.decode(Double.self, forKey: .extraPrice)) ?? 0
        self.status = try? c.decode(Int.self, forKey: .status)
        self.linkedProductId = try? c.decodeIfPresent(Int.self, forKey: .linkedProductId)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(extraPrice, forKey: .extraPrice)
        try c.encodeIfPresent(status, forKey: .status)
        try c.encodeIfPresent(linkedProductId, forKey: .linkedProductId)
    }
}

struct ModifierGroup: Identifiable, Codable, Hashable, Equatable {
    enum GroupType: String, Codable, Hashable {
        case options
        case additions
    }

    let groupId: String
    var id: String { groupId }

    let type: GroupType
    let title: String
    let items: [ModifierItem]
    let selection: ModifierSelection?

    init(
        type: GroupType,
        title: String,
        items: [ModifierItem],
        groupId: String = UUID().uuidString,
        selection: ModifierSelection? = nil
    ) {
        let cleanId = groupId.trimmingCharacters(in: .whitespacesAndNewlines)

        self.groupId = cleanId.isEmpty ? UUID().uuidString : cleanId
        self.type = type
        self.title = title
        self.items = items
        self.selection = selection
    }

    enum CodingKeys: String, CodingKey {
        case groupId = "GroupId"
        case title = "Title"
        case items = "Items"
        case selection = "Selection"
    }

    enum LocalCodingKeys: String, CodingKey {
        case groupId
        case type
        case title
        case items
        case selection
    }

    init(from decoder: Decoder) throws {
        if let c = try? decoder.container(keyedBy: CodingKeys.self) {
            let apiTitle = (try? c.decode(String.self, forKey: .title)) ?? ""
            let apiItems = (try? c.decode([ModifierItem].self, forKey: .items)) ?? []

            if !apiTitle.isEmpty || !apiItems.isEmpty {
                let gid = (try? c.decode(String.self, forKey: .groupId))?
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                self.groupId = (gid?.isEmpty == false) ? gid! : UUID().uuidString
                self.title = apiTitle
                self.items = apiItems
                self.selection = try? c.decode(ModifierSelection.self, forKey: .selection)

                let mode = selection?.mode?.lowercased() ?? "single"
                self.type = (mode == "multi") ? .additions : .options
                return
            }
        }

        let c = try decoder.container(keyedBy: LocalCodingKeys.self)

        let gid = (try? c.decode(String.self, forKey: .groupId))?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        self.groupId = (gid?.isEmpty == false) ? gid! : UUID().uuidString
        self.type = (try? c.decode(GroupType.self, forKey: .type)) ?? .options
        self.title = (try? c.decode(String.self, forKey: .title)) ?? ""
        self.items = (try? c.decode([ModifierItem].self, forKey: .items)) ?? []
        self.selection = try? c.decode(ModifierSelection.self, forKey: .selection)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(groupId, forKey: .groupId)
        try c.encode(title, forKey: .title)
        try c.encode(items, forKey: .items)
        try c.encodeIfPresent(selection, forKey: .selection)
    }
}

struct BasketEntry: Identifiable {
    let id: Int
    let item: ShellMenuItem
    var quantity: Int
    var subtitle: String?
    var unitPrice: Double
    // ✅ NEW: persistent selection
      var selectedOptions: [String: String] = [:]     // normalized keys + values
      var selectedAdditions: Set<String> = []         // normalized names
}

enum DiningMode: String, CaseIterable, Identifiable {
    case dineIn = "Dine in"
    case takeAway = "Take away"
    var id: String { rawValue }
}

 struct CategoryPositionKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]

    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        // ✅ MUST merge (not overwrite)
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
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
            let isPad = UIDevice.current.userInterfaceIdiom == .pad
            let cashPointMode = UserDefaults.standard.bool(forKey: "cashPointMode")
            let defaults = UserDefaults.standard

            func r2(_ x: Double) -> Double { (x * 100).rounded() / 100 }
            func closeEnough(_ a: Double, _ b: Double, tol: Double = 0.01) -> Bool { abs(a - b) <= tol }

            func normalizeLoc(_ s: String) -> String {
                s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }

            func resolveWaPhone(miniAppId: Int, customerPhone: String?) -> String {
                // Prefer passed phone
                let p1 = (customerPhone ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !p1.isEmpty { return p1 }

                // fallback to stored
                let p2 = (defaults.string(forKey: "userPhone") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !p2.isEmpty { return p2 }

                // last resort (your debug number)
                if miniAppId == 3 { return "+447522552608" }

                return ""
            }

            func resolveDeliveryLoc(miniAppId: Int) -> String {
                if miniAppId != 3 { return "" }

                let saved = normalizeLoc(defaults.string(forKey: "deliveryLoc") ?? "")
                if !saved.isEmpty { return saved }

                // ✅ HARD FALLBACK like you asked (debug / default bar)
                return "mikkeller"
            }

            
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
            } else if let s = storedShopIdString, let v = Int(s) {
                miniAppId = v
            } else {
                completion(.failure(SubmitError(message: "No miniAppId / shopId selected for this order")))
                return
            }

            let uuid         = defaults.string(forKey: "anonUUID")    ?? UUID().uuidString
            let defaultEmail = defaults.string(forKey: "userEmail")   ?? "customer@example.com"
            let defaultName  = defaults.string(forKey: "userName")    ?? "Customer"

            let effectiveName: String = {
                let trimmed = customerName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? defaultName : trimmed
            }()

            let effectivePhone: String = {
                let passed = (customerPhone ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !passed.isEmpty { return passed }

                let stored = (defaults.string(forKey: "userPhone") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return stored
            }()

            let othSet = othLineIds ?? []

            let basketPayload: [[String: Any]] = entries.map { entry in
                let qty = max(entry.quantity, 0)
                let unitCandidate = (entry.unitPrice > 0) ? entry.unitPrice : entry.item.price
                let unit = unitCandidate
                let isOth = othSet.contains(entry.id)

                return [
                    "lineId":    entry.id,
                    "productId": entry.item.id,
                    "name":      entry.item.name,
                    "quantity":  qty,
                    "unitPrice": unit,
                    "lineTotal": unit * Double(qty),
                    "modifiers": entry.subtitle ?? "",
                    "isOth":     isOth
                ]
            }

            let apnsToken = loadApnsToken()

            let serviceValue: String = {
                switch diningMode {
                case .dineIn:   return "sit"
                case .takeAway: return "ta"
                }
            }()

            // ------------------------------------------------------------
            // ✅ SOURCE: normalize ONCE (used for payload + headers)
            // ------------------------------------------------------------
            var normalizedSource = source
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()

            // ✅ SIMPLE RULE
            if !cashPointMode && isPad {
                normalizedSource = "self-cashpoint"
            }
            // ---------- totals ----------
            var finalTotals: [String: Any] = totals ?? [:]

            let dueFromTotals = flexDouble(finalTotals["total"])
            let due = r2(max(dueFromTotals ?? total, 0))

            if finalTotals["currency"] == nil {
                // ✅ match the working curl for mini 3
                if miniAppId == 3 {
                    finalTotals["currency"] = "GBP"
                } else {
                    finalTotals["currency"] = defaults.string(forKey: "currency") ?? "ILS"
                }
            }
            finalTotals["total"] = due

            if finalTotals["subtotal"] == nil {
                let subtotalGuess = r2(entries.reduce(0.0) { acc, e in acc + (Double(e.quantity) * e.unitPrice) })
                finalTotals["subtotal"] = subtotalGuess
            }
            if finalTotals["discount"] == nil {
                if let sub = flexDouble(finalTotals["subtotal"]) {
                    finalTotals["discount"] = r2(max(0, sub - due))
                }
            }

            // ---------- payload ----------
            var payload: [String: Any] = [
                "uuid": uuid,
                "email": defaultEmail,
                "name": effectiveName,
                "miniAppId": miniAppId,
                "total": due,
                "basket": basketPayload,
                "diningMode": diningMode.rawValue,
                "service": serviceValue,
                "device": [
                    "platform": "ios",
                    "token": apnsToken
                ],
                "totals": finalTotals,

                // ✅ IMPORTANT: include source IN JSON (backend might ignore headers)
                "source": normalizedSource,
                "orderSource": normalizedSource
            ]

            if !effectivePhone.isEmpty {
                payload["phone"] = effectivePhone
                payload["customerPhone"] = effectivePhone
            }
            
            if miniAppId == 13 {
                let d = UserDefaults.standard

                let rawV2 = (d.string(forKey: "pickup.location.v2") ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                let rawV1 = (d.string(forKey: "pickup.location") ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                let raw = !rawV2.isEmpty ? rawV2 : rawV1
                print("📍 pickup debug v2=\(rawV2) v1=\(rawV1) -> raw=\(raw)")
                
                if let pickup = canonicalPickupLocation(raw) {
                    payload["pickupLocation"] = pickup   // "humanities" | "social"
                }
            }
            // ------------------------------------------------------------
            // ✅ DELIVERY (Fastlane / miniAppId == 3 via loc key)
            // ------------------------------------------------------------
            // ------------------------------------------------------------
            // ------------------------------------------------------------
            // ✅ DELIVERY (Fastlane / miniAppId == 3)
            // Always send a loc. If none exists -> fallback to "mikkeller".
            // Backend requires delivery.loc to resolve address.
            // ------------------------------------------------------------
            if miniAppId == 3 {

                // ✅ 1) Read from app group first (recommended), then standard defaults
                let appGroupId = "group.minis"
                let suite = UserDefaults(suiteName: appGroupId)

                func clean(_ s: String?) -> String {
                    (s ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                      
                }

                let locFromSuite = clean(suite?.string(forKey: "deliveryLoc"))
                let locFromStd   = clean(defaults.string(forKey: "deliveryLoc"))

                // ✅ 2) Final loc: suite -> std -> fallback
                let fallbackLoc = "mikkeller"
                let loc = !locFromSuite.isEmpty ? locFromSuite
                        : (!locFromStd.isEmpty ? locFromStd : fallbackLoc)

                // ✅ 3) Persist fallback so future requests are consistent (both stores)
                if locFromSuite.isEmpty && locFromStd.isEmpty {
                    defaults.set(loc, forKey: "deliveryLoc")
                    suite?.set(loc, forKey: "deliveryLoc")
                    suite?.synchronize()
                }

                // ✅ 4) Send delivery payload in the exact shape backend expects
                payload["delivery"] = [
                    "isDelivery": true,
                    "loc": loc
                ]

                // ✅ 5) Delivery forces takeaway (backend expects this)
                payload["service"] = "ta"
            }

            if let zcreditMeta, !zcreditMeta.isEmpty {
                payload["zcredit"] = zcreditMeta           // ✅ best: namespaced
                // or: payload["paymentMeta"] = zcreditMeta // alternative
            }
            
            if let orderId { payload["orderId"] = orderId }
            if let ticketNumber { payload["ticketNumber"] = ticketNumber }

            if let orderType, !orderType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                payload["orderType"] = orderType
            }
            if let tabKey, !tabKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                payload["tabKey"] = tabKey
            }

            // ------------------------------------------------------------
            // Payment: normalize
            // ------------------------------------------------------------
            var dueVar = due

            if let payment {
                var cash = r2(max(payment.cashAmount, 0))
                var card = r2(max(payment.cardAmount, 0))
                let sum  = r2(cash + card)

                if sum > 0.01, !closeEnough(sum, dueVar) {
                    dueVar = sum
                    finalTotals["total"] = dueVar
                }

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

                payload["payment"] = [
                    "provider": "minis",
                    "method": method,
                    "cardAmount": card,
                    "cashAmount": cash
                ]
            }

            // ✅ If ApplePay succeeded but you forgot to pass PaymentSummary,
            // still mark the order as CARD so DB won't show unpaid.
            if payload["payment"] == nil, zcreditMeta != nil, dueVar > 0.01 {
                payload["payment"] = [
                    "provider": "zcredit",
                    "method": PaymentMethod.card.rawValue,
                    "cardAmount": dueVar,
                    "cashAmount": 0
                ]
            }

            // ensure final totals use dueVar
            payload["total"] = dueVar
            var totalsOut = finalTotals
            totalsOut["total"] = dueVar
            payload["totals"] = totalsOut

            if !effectivePhone.isEmpty {
                payload["notifications"] = [
                    "wa": [
                        "phone": effectivePhone,
                        "consent": 1
                    ]
                ]
            }

            guard let url = URL(string: "https://minis.studio/submitOrder") else {
                completion(.failure(SubmitError(message: "Bad URL")))
                return
            }

            // ✅ Idempotency key (persisted by outbox)
            let idempotencyKey = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            payload["idempotencyKey"] = idempotencyKey

            Task { @MainActor in
                OutboxLog.shared.queued(
                    id: idempotencyKey,
                    miniAppId: miniAppId,
                    ticketNumber: ticketNumber,
                    msg: "queued for /submitOrder"
                )
            }

            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: payload)

            // ✅ still send header version too
            req.setValue(normalizedSource, forHTTPHeaderField: "X-Order-Source")

            // ✅ send idempotency in headers too (your backend reads these)
            req.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
            req.setValue(idempotencyKey, forHTTPHeaderField: "X-Request-Id")

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

            // ✅ Enqueue BEFORE sending (durability)
            let env = OutboxEnvelope(
                id: idempotencyKey,
                createdAt: Date(),
                state: .pending,
                attemptCount: 0,
                lastAttemptAt: nil,
                endpoint: url.absoluteString,
                body: req.httpBody ?? Data(),
                headers: req.allHTTPHeaderFields ?? [:]
            )

            Task { @MainActor in
                OrderOutbox.shared.enqueue(env)
                OrderOutbox.shared.drainNow()   // try immediately
            }

            print("curl:", req.curlDebug)

            Task { @MainActor in
                NotificationCenter.default.post(name: .resetModifiers, object: nil)
            }

            Task { @MainActor in
                OutboxLog.shared.sending(id: idempotencyKey, msg: "sending…")
            }

            // ✅ Fire normal request too (fast path). Outbox will retry if this fails.
            URLSession.shared.dataTask(with: req) { data, resp, err in
                if let err = err {
                    Task { @MainActor in
                        OutboxLog.shared.failed(id: idempotencyKey, msg: err.localizedDescription)
                    }
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

                let oid = obj["orderId"] as? Int ?? 0
                let replay = (obj["replay"] as? Bool) ?? false

                Task { @MainActor in
                    OutboxLog.shared.acked(
                        id: idempotencyKey,
                        orderId: oid,
                        replay: replay,
                        msg: replay ? "server replay" : "server ack"
                    )
                }

                if oid > 0 {
                    Task { @MainActor in OrderOutbox.shared.drainNow() }
                    completion(.success(oid))
                } else {
                    completion(.failure(SubmitError(message: "Server did not return orderId")))
                }
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
    
    private func resolveMiniAppIdWithSource() -> (value: Int, source: String) {
        let d = UserDefaults.standard
        let miniAppId = d.integer(forKey: "miniAppId")
        if miniAppId > 0 { return (miniAppId, "defaults.miniAppId") }

        if let shopId = d.string(forKey: "shopId"),
           let parsedShopId = Int(shopId),
           parsedShopId > 0 {
            return (parsedShopId, "defaults.shopId")
        }

        let pendingMiniAppId = d.integer(forKey: CheckoutRecoveryKeys.pendingMiniAppId)
        if pendingMiniAppId > 0 { return (pendingMiniAppId, "defaults.pendingMiniAppId") }

        return (0, "failed.zero")
    }

    private func resolveMiniAppId() -> Int {
        resolveMiniAppIdWithSource().value
    }

    private func resolvePinpadId(miniAppId: Int) -> String {
        let d = UserDefaults.standard

        // ✅ per-mini key first
        let perMini = (d.string(forKey: "pinpadId.\(miniAppId)") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !perMini.isEmpty { return perMini }

        // ✅ legacy fallback
        let legacy = (d.string(forKey: "pinpadId") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !legacy.isEmpty { return legacy }

        // ✅ final fallback = no terminal
        return "111111"
    }

    private func resolveTPN(miniAppId: Int) -> String {
        let d = UserDefaults.standard

        let perMini = (d.string(forKey: "tpn.\(miniAppId)") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !perMini.isEmpty { return perMini }

        let legacy = (d.string(forKey: "tpn") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !legacy.isEmpty { return legacy }

        switch miniAppId {
        case 13:
            return "2679742012"
        default:
            return ""
        }
    }

    private func resolveCurrency(miniAppId: Int) -> String {
        if miniAppId == 3 { return "GBP" }
        let currency = (UserDefaults.standard.string(forKey: "currency") ?? "ILS")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return currency.isEmpty ? "ILS" : currency
    }

    private func legacyBadURLResult() -> ZCreditResult {
        ZCreditResult(
            status: .unknown,
            message: "שגיאה בכתובת השרת",
            referenceNumber: nil,
            transactionId: nil,
            rawPath: "client_bad_url",
            rawReturnCode: nil
        )
    }

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
    @MainActor
    private func payLegacyStart(
        amount: Double,
        orderId: Int?,
        transactionType: String,
        idempotencyKey: String?,
        completion: @escaping (ZCreditResult) -> Void
    ) {
        let _ = CashpointID(rawValue: UserDefaults.standard.integer(forKey: "cashpointID")) ?? .one

        let safeAmount = max(0, amount)
        let miniAppResolution = resolveMiniAppIdWithSource()
        let mid = miniAppResolution.value
        let pinpadId = resolvePinpadId(miniAppId: mid)

        print("💳 ZCREDIT PAY mid=\(mid) source=\(miniAppResolution.source) pinpadId=\(pinpadId) perMini=\(UserDefaults.standard.string(forKey: "pinpadId.\(mid)") ?? "nil") legacy=\(UserDefaults.standard.string(forKey: "pinpadId") ?? "nil")")

        guard mid > 0 else {
            let result = ZCreditResult(
                status: .unknown,
                message: "Missing miniAppId/shopId for /payments/zcredit/start-safe",
                referenceNumber: nil,
                transactionId: nil,
                rawPath: "client_missing_miniapp_id",
                rawReturnCode: nil
            )
            DispatchQueue.main.async { completion(result) }
            return
        }

        let correlationId = UUID().uuidString

        currentCorrelationId = correlationId
        currentPinpadId = pinpadId

        let stableKeyPrefix = idempotencyKey.map { String($0.prefix(8)) } ?? "-"
        print("🟡 ZCredit payLegacyStart using key=\(stableKeyPrefix)")

        let startBody: [String: Any] = [
            "MiniAppId": mid,
            "miniAppId": mid,
            "amount": safeAmount,
            "currency": "ILS",
            "authOnly": false,
            "orderId": orderId != nil ? String(orderId!) : "",
            "pinpadId": pinpadId,
            "transactionType": transactionType,
            "idempotencyKey": idempotencyKey ?? ""
        ]

        guard let startURL = URL(string: "/payments/zcredit/start-safe", relativeTo: baseURL) else {
            DispatchQueue.main.async { completion(self.legacyBadURLResult()) }
            return
        }

        var req = URLRequest(url: startURL, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(correlationId, forHTTPHeaderField: "x-correlation-id")
        req.setValue(pinpadId, forHTTPHeaderField: "x-pinpad-id")
        if mid != 12 {
            req.setValue(String(mid), forHTTPHeaderField: "x-miniapp-id")
        }
        if let idempotencyKey, !idempotencyKey.isEmpty {
            req.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
            req.setValue(idempotencyKey, forHTTPHeaderField: "X-Request-Id")
        }

        req.httpBody = try? JSONSerialization.data(withJSONObject: startBody)

        print("🟡 ZCredit start-safe miniAppId handling mid=\(mid) omitHeaderMiniAppId=\(mid == 12) bodyMiniAppId=\(mid)")
        print("🔵 ZCredit /payments/zcredit/start-safe cURL:")
        print(req.curlDebug)

        URLSession.shared.dataTask(with: req) { [weak self] data, resp, error in
            guard let self = self else { return }

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

            if let sid = (obj["sessionId"] as? String) ?? (obj["SessionId"] as? String) {
                self.currentSessionId = sid
            }
            if let ref = (obj["referenceNumber"] as? String) ?? (obj["ReferenceNumber"] as? String) {
                self.currentReferenceOrSession = ref
            }

            self.finishFromResponse(json: obj, completion: completion)
        }.resume()
    }

    // MARK: - Main entry point

    @MainActor
    func pay(
        amount: Double,
        orderId: Int?,
        transactionType: String = "01",   // ✅ NEW: "01" = regular, "53" = refund
        idempotencyKey: String? = nil,
        completion: @escaping (ZCreditResult) -> Void
    ) {
        let stableIdempotencyKey: String = {
            if let idempotencyKey,
               !idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let trimmed = idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines)
                print("🟡 ZCredit pay() idempotency reused source=caller key=\(String(trimmed.prefix(8)))")
                return trimmed
            }

            if let existingAttempt = PaymentAttemptStore.shared.unresolvedAttempt(reusingAmount: amount) {
                let reused = existingAttempt.idempotencyKey
                print("🟡 ZCredit pay() idempotency reused source=unresolvedAttempt key=\(String(reused.prefix(8)))")
                return reused
            }

            let generated = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            print("🟡 ZCredit pay() idempotency created source=freshAttempt key=\(String(generated.prefix(8)))")
            return generated
        }()

        print("🟡 ZCredit start path = LEGACY /payments/zcredit/start-safe")
        payLegacyStart(
            amount: amount,
            orderId: orderId,
            transactionType: transactionType,
            idempotencyKey: stableIdempotencyKey,
            completion: completion
        )
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
    let miniAppId = UserDefaults.standard.integer(forKey: "miniAppId")
    
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
            "miniAppId": miniAppId,
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
        item(for: productId)?.effectivePrinterId   // <-- prefers printers[0] then printer
    }

    // ✅ ADD THIS
    func price(for productId: Int?) -> Double {
        item(for: productId)?.price ?? 0
    }
}
// GLOBAL helper – accessible from anywhere
func stationIds(from any: String?) -> [String] {
    let t = (any ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if t.hasPrefix("s") { return [t] }
    if t.contains("kitchen") || t.contains("מטבח") { return ["s1"] }
    if t.contains("bakery")  || t.contains("מאפ")  || t.contains("ויטר") { return ["s3"] }
    if t.contains("bar")     || t.contains("בר")   { return ["s2"] }
    return []
}

func makeShellMenuItem(from line: AdminOrderLineItem) -> ShellMenuItem {
    if let menuItem = MenuCatalog.shared.item(for: line.productId) {
        return menuItem
    }

    let sids = stationIds(from: line.printer)

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

        // ✅ force station ids when we can
        printer: sids.first,      // could be "s3"
        printers: sids.isEmpty ? nil : sids
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

    private static let base = "https://minis.studio"

    // MARK: - Close team tab (DEBUG + correct endpoint)

    static func close(orderId: Int, completion: @escaping (Result<Void, Error>) -> Void) {

        // ✅ BACKEND ROUTE IS /api/teamtabs/close (no /{id}/close)
        guard let url = URL(string: "\(base)/api/teamtabs/close") else {
            completion(.failure(NSError(domain: "TeamTabsAPI", code: -1)))
            return
        }

        // ✅ Backend expects TeamTabCloseReq with OrderId
        // C# property likely "OrderId" but JSON should be camelCase "orderId" by default.
        let payload: [String: Any] = [
            "orderId": orderId
        ]

        let bodyData = (try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])) ?? Data()
        let bodyString = String(data: bodyData, encoding: .utf8) ?? "<non-utf8 body>"

        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = bodyData

        // ✅ DEBUG REQUEST
        print("🧾 TeamTabsAPI.close REQUEST")
        print("   url:", url.absoluteString)
        print("   method:", req.httpMethod ?? "")
        print("   body:\n\(bodyString)")

        let curl = """
        curl -sS -i -X POST "\(url.absoluteString)" \
          -H "Content-Type: application/json" \
          -H "Accept: application/json" \
          -d '\(bodyString.replacingOccurrences(of: "\n", with: " "))'
        """
        print("   curl:\n\(curl)")

        let start = Date()

        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err = err {
                print("❌ TeamTabsAPI.close NETWORK error:", err.localizedDescription)
                completion(.failure(err))
                return
            }

            guard let http = resp as? HTTPURLResponse else {
                let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? "<no body>"
                print("❌ TeamTabsAPI.close NO HTTP RESPONSE body:", text)
                completion(.failure(NSError(domain: "TeamTabsAPI", code: -2, userInfo: ["body": text])))
                return
            }

            let ms = Int(Date().timeIntervalSince(start) * 1000)
            let raw = data ?? Data()
            let text = String(data: raw, encoding: .utf8) ?? "<non-utf8 \(raw.count) bytes>"

            // ✅ DEBUG RESPONSE
            print("📥 TeamTabsAPI.close RESPONSE (\(ms)ms)")
            print("   status:", http.statusCode)
            if let ct = http.value(forHTTPHeaderField: "Content-Type") { print("   content-type:", ct) }
            if let rid = http.value(forHTTPHeaderField: "x-request-id") { print("   x-request-id:", rid) }
            if let cf = http.value(forHTTPHeaderField: "cf-ray") { print("   cf-ray:", cf) }
            print("   body:\n\(text)")

            guard (200...299).contains(http.statusCode) else {
                completion(.failure(NSError(
                    domain: "TeamTabsAPI",
                    code: http.statusCode,
                    userInfo: ["body": text]
                )))
                return
            }

            completion(.success(()))
        }.resume()
    }

    // MARK: - OpenOrCreate

    struct OpenResp: Decodable {
        let orderId: Int
    }

    static func openOrCreate(
        miniAppId: Int,
        tab: TabType,
        completion: @escaping (Result<Int, Error>) -> Void
    ) {
        guard miniAppId > 0 else {
            completion(.failure(NSError(domain: "TeamTabsAPI", code: -1)))
            return
        }

        guard let url = URL(string: "\(base)/api/team-tabs/open") else {
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
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)

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
                completion(.failure(NSError(domain: "TeamTabsAPI", code: -3, userInfo: ["body": text])))
                return
            }

            guard (200...299).contains(http.statusCode), let data else {
                let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? "<no body>"
                print("❌ TeamTabsAPI.openOrCreate HTTP \(http.statusCode) body:", text)
                completion(.failure(NSError(domain: "TeamTabsAPI", code: http.statusCode, userInfo: ["body": text])))
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

    // MARK: - Fetch order metadata

    static func fetchOrderMetadata(
        orderId: Int,
        completion: @escaping (Result<OrderMetadataDTO, Error>) -> Void
    ) {
        guard let url = URL(string: "\(base)/api/orders/\(orderId)") else {
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
                completion(.failure(NSError(domain: "TeamTabsAPI", code: -11, userInfo: ["body": body])))
                return
            }

            guard (200...299).contains(http.statusCode), let data = data else {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? "<no body>"
                print("❌ fetchOrderMetadata HTTP \(http.statusCode) body:", body)
                completion(.failure(NSError(domain: "TeamTabsAPI", code: http.statusCode, userInfo: ["body": body])))
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


#if !APPCLIP
import Foundation

@MainActor
final class ReportPreviewModel: ObservableObject {
    @Published var data: PrinterManager.SalesReportData?
    private let initial: PrinterManager.SalesReportData   // ✅ keep a clean base

    @Published var isLoading = false
    @Published var loadError: String? = nil
    @Published var vatRate: Double = 0.18

    // ✅ NEW: authoritative business day for restore preview (from DB if available)
    @Published var businessDate: Date? = nil

    init(initial: PrinterManager.SalesReportData) {
        self.initial = initial
        self.data = nil          // ✅ empty until load finishes
    }

    func printCurrentReport(type: CashPointView.ReportType) {
        if isLoading { return }
        if loadError != nil { return }
        guard let d = data else { return }
        PrinterManager.shared.printSalesReport(d, type: type)
    }

    // ✅ NEW: optional date param for restore (used for Z restore)
    func load(type: CashPointView.ReportType, shopId: Int, for date: Date? = nil) async {
        guard !isLoading else { return }
        isLoading = true
        loadError = nil
        data = nil                  // ✅ clears UI while loading
        businessDate = nil          // ✅ clear until we know the truth
        defer { isLoading = false }

        do {
            switch type {

            case .x:
                let res = try await fetchXReport(miniAppId: shopId)
                self.data = PrinterManager.SalesReportData
                    .applyingXReport(res, onto: initial)

            case .z:
                // ✅ Restore date (Z)
                if let date {
                    let tz = TimeZone(identifier: "Asia/Jerusalem") ?? .current
                    let ymd = Self.ymd(date, tz: tz)

                    let row = try await fetchZByDay(miniAppId: shopId, dayYMD: ymd)

                    // ✅ VAT
                    self.vatRate = row.VatRate

                    // ✅ BusinessDate: prefer DB value if present, else fallback to selected restore date
                    if let db = parseISODateOnly(row.BusinessDate) {
                        self.businessDate = db
                    } else {
                        self.businessDate = date
                    }

                    var d = initial   // ✅ clean base, no stale values

                    // Sales
                    d.totalSalesIncVat = row.GrossTotal
                    d.grandTotal       = row.NetTotal

                    // Tips
                    d.tipBaseTotal = row.TipsTotal
                    d.tipsTotal    = row.TipsTotal

                    // Payments (cash includes tips)
                    let cashTips = row.CashTipsTotal
                    let cashWithCashTips = row.CashTotal + cashTips

                    d.cashAmount = cashWithCashTips
                    d.cardAmount = row.CardTotal

                    d.collectionsTotalAmount = cashWithCashTips + row.CardTotal
                    d.closedDrawersAmount    = cashWithCashTips
                    d.drawerTotalAmount      = cashWithCashTips
                    d.mainDrawerAmount       = cashWithCashTips

                 
                    // Cash report section
                    d.openDrawersAmount       = 0
                    d.depositWithdrawAmount   = 0
                    d.hostStationDrawerAmount = 0

                    // Service split
                    d.totalRestaurantIncVat = row.RestaurantGross
                    d.totalTAIncVat         = row.TaGross
                    d.dinersRestaurant      = row.RestaurantCount
                    d.dinersTA              = row.TaCount
                    d.ppaRestaurant         = 0
                    d.ppaTA                 = 0

                    // Not available yet
                    d.tipRestaurant      = 0
                    d.tipBarTakeaway     = 0
                    d.extraTipTotal      = 0
                    d.extraTipRestaurant = 0
                    d.extraTipBar        = 0

                    self.data = d
                    return
                }

                // ✅ Normal Z (no restore date) — currently using X endpoint logic
                let res = try await fetchXReport(miniAppId: shopId)
                self.data = PrinterManager.SalesReportData
                    .applyingXReport(res, onto: initial)

                // No restore → don’t show a specific business day
                self.businessDate = nil
            }

        } catch {
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

        // ✅ NEW (from DB): "yyyy-MM-dd" (recommended), may be missing on older rows
        let BusinessDate: String?

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

    private func parseISODateOnly(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Jerusalem")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)
    }
}
#endif
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
#if !APPCLIP
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
#endif
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
    let isCancelled: Int?   // instead of Bool?
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

enum PaymentAttemptState: String, Codable {
    case pending
    case reconciling
    case succeeded
    case failedFinal
}

struct PaymentAttempt: Codable {
    let attemptId: String
    let idempotencyKey: String
    let orderId: Int?
    let orderReference: String?
    let amount: Double
    var state: PaymentAttemptState
    let createdAt: Date
    var updatedAt: Date
}

@MainActor
final class PaymentAttemptStore: ObservableObject {
    static let shared = PaymentAttemptStore()

    @Published private(set) var activeAttempt: PaymentAttempt?

    private let key = "payment.attempt.v1"
    private let staleOpenAttemptThreshold: TimeInterval = 30
    private let sessionStartedAt = Date()

#if DEBUG
    let forcedIdempotencyKeyDefaultsKey = "payment.debug.forceFixedIdempotencyKey"
    let forcedIdempotencyKeyValue = "3299101e-6a26-4d74-a699-0947dd659fb1"
#endif

    private init() {
        load()
    }

    private func log(_ message: String, attempt: PaymentAttempt? = nil) {
        let active = attempt ?? activeAttempt
        let attemptId = active?.attemptId ?? "-"
        let keyPrefix = active.map { String($0.idempotencyKey.prefix(8)) } ?? "-"
        let state = active?.state.rawValue ?? "-"
        let orderId = active?.orderId.map(String.init) ?? "-"
        let orderRef = active?.orderReference ?? "-"
        print("🧾[PaymentAttempt] \(message) attemptId=\(attemptId) key=\(keyPrefix) state=\(state) orderId=\(orderId) orderRef=\(orderRef)")
    }

#if DEBUG
    var forcedIdempotencyKeyIfEnabled: String? {
        guard UserDefaults.standard.bool(forKey: forcedIdempotencyKeyDefaultsKey) else { return nil }
        return forcedIdempotencyKeyValue
    }
#endif

    var hasOpenAttempt: Bool {
        guard let attempt = activeAttempt else { return false }
        switch attempt.state {
        case .pending, .reconciling:
            return true
        case .succeeded, .failedFinal:
            return false
        }
    }

    func beginNewAttempt(
        amount: Double,
        orderId: Int? = nil,
        orderReference: String? = nil,
        forcedIdempotencyKey: String? = nil
    ) -> PaymentAttempt {
        let now = Date()
        let idempotencyKey = forcedIdempotencyKey ?? UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let attempt = PaymentAttempt(
            attemptId: UUID().uuidString,
            idempotencyKey: idempotencyKey,
            orderId: orderId,
            orderReference: orderReference,
            amount: amount,
            state: .pending,
            createdAt: now,
            updatedAt: now
        )
        activeAttempt = attempt
        save()
        if forcedIdempotencyKey != nil {
            log("beginNew fixedKeyEnabled=true amount=\(amount) orderRef=\(orderReference ?? "-")", attempt: attempt)
        } else {
            log("beginNew fixedKeyEnabled=false amount=\(amount) orderRef=\(orderReference ?? "-")", attempt: attempt)
        }
        return attempt
    }

    func unresolvedAttempt(reusingAmount amount: Double? = nil, orderReference: String? = nil) -> PaymentAttempt? {
        guard let attempt = activeAttempt else { return nil }
        switch attempt.state {
        case .pending, .reconciling:
            break
        case .succeeded:
            print("🟡 replay denied reason=succeeded key=\(String(attempt.idempotencyKey.prefix(8)))")
            return nil
        case .failedFinal:
            print("🟡 replay denied reason=failedFinal key=\(String(attempt.idempotencyKey.prefix(8)))")
            return nil
        }
        let age = Date().timeIntervalSince(attempt.updatedAt)
        if age > staleOpenAttemptThreshold {
            print("🟡 replay denied reason=stale age=\(Int(age)) key=\(String(attempt.idempotencyKey.prefix(8)))")
            return nil
        }
        if let amount, abs(attempt.amount - amount) > 0.01 {
            return nil
        }
        if let orderReference,
           let existingReference = attempt.orderReference,
           existingReference != orderReference {
            return nil
        }
        log("reuseUnresolved amount=\(amount ?? attempt.amount) orderRef=\(orderReference ?? attempt.orderReference ?? "-")", attempt: attempt)
        return attempt
    }

    func currentAttempt(reusingAmount amount: Double? = nil, orderReference: String? = nil) -> PaymentAttempt? {
        unresolvedAttempt(reusingAmount: amount, orderReference: orderReference)
    }

    func blocksParallelAttempt() -> Bool {
        guard let attempt = activeAttempt else { return false }
        switch attempt.state {
        case .pending, .reconciling:
            log("blockedParallel", attempt: attempt)
            return true
        case .succeeded, .failedFinal:
            return false
        }
    }

    func markPending() {
        updateState(.pending)
    }

    func markReconciling() {
        updateState(.reconciling)
    }

    func markSucceeded() {
        updateState(.succeeded)
    }

    func markFailedFinal() {
        updateState(.failedFinal)
    }

    func clearIfTerminal() {
        guard let attempt = activeAttempt else { return }
        switch attempt.state {
        case .succeeded, .failedFinal:
            activeAttempt = nil
            save()
        case .pending, .reconciling:
            break
        }
    }

    private func updateState(_ newState: PaymentAttemptState) {
        guard var attempt = activeAttempt else { return }
        let oldState = attempt.state
        attempt.state = newState
        attempt.updatedAt = Date()
        activeAttempt = attempt
        save()
        log("transition \(oldState.rawValue)->\(newState.rawValue)", attempt: attempt)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode(PaymentAttempt.self, from: data) else {
            activeAttempt = nil
            return
        }
        var restored = decoded
        let age = Date().timeIntervalSince(restored.updatedAt)
        if age > staleOpenAttemptThreshold {
            switch restored.state {
            case .pending, .reconciling:
                restored.state = .failedFinal
                restored.updatedAt = Date()
                activeAttempt = restored
                save()
                log("loadPersisted staleOpenExpired age=\(Int(age))", attempt: restored)
                return
            case .succeeded, .failedFinal:
                break
            }
        }
        activeAttempt = restored
        log("loadPersisted age=\(Int(age))", attempt: restored)
    }

    private func save() {
        if let attempt = activeAttempt,
           let data = try? JSONEncoder().encode(attempt) {
            UserDefaults.standard.set(data, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}


import Foundation

struct OutboxEnvelope: Codable, Identifiable {
    enum State: String, Codable { case pending, sending }

    let id: String                  // idempotencyKey
    let createdAt: Date
    var state: State
    var attemptCount: Int
    var lastAttemptAt: Date?

    let endpoint: String
    let body: Data
    let headers: [String: String]
}

@MainActor
final class OrderOutbox: ObservableObject {
    static let shared = OrderOutbox()

    private let fm = FileManager.default
    private let dir: URL
    private var isDraining = false

    private init() {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        dir = base.appendingPathComponent("order_outbox", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func fileURL(for id: String) -> URL {
        dir.appendingPathComponent("\(id).json")
    }

    func enqueue(_ env: OutboxEnvelope) {
        let url = fileURL(for: env.id)
        if fm.fileExists(atPath: url.path) { return } // idempotent
        if let data = try? JSONEncoder().encode(env) {
            try? data.write(to: url, options: [.atomic])
        }
    }

    func drainNow() {
        guard !isDraining else { return }
        isDraining = true

        Task {
            defer { isDraining = false }

            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            let sorted = files.sorted { $0.lastPathComponent < $1.lastPathComponent }

            for f in sorted {
                guard let raw = try? Data(contentsOf: f),
                      var env = try? JSONDecoder().decode(OutboxEnvelope.self, from: raw) else {
                    try? fm.removeItem(at: f) // corrupt -> drop
                    continue
                }

                // mark sending + persist
                env.state = .sending
                env.attemptCount += 1
                env.lastAttemptAt = Date()
                if let updated = try? JSONEncoder().encode(env) {
                    try? updated.write(to: f, options: [.atomic])
                }

                let ok = await send(env)

                if ok {
                    try? fm.removeItem(at: f) // ACKed -> delete
                } else {
                    // revert to pending and stop (likely offline)
                    env.state = .pending
                    if let updated = try? JSONEncoder().encode(env) {
                        try? updated.write(to: f, options: [.atomic])
                    }
                    break
                }
            }
        }
    }

    private func send(_ env: OutboxEnvelope) async -> Bool {
        guard let url = URL(string: env.endpoint) else { return false }

        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.httpBody = env.body
        for (k, v) in env.headers { req.setValue(v, forHTTPHeaderField: k) }

        func parseOrderId(_ any: Any?) -> Int? {
            if let i = any as? Int { return i }
            if let d = any as? Double { return Int(d) }
            if let s = any as? String { return Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return nil
        }

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard (200...299).contains(code) else { return false }

            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let oid = parseOrderId(obj["orderId"]),
               oid > 0 {
                return true
            }
            return false
        } catch {
            return false
        }
    }
}

import Foundation
import SwiftUI

@MainActor
final class OutboxLog: ObservableObject {
    static let shared = OutboxLog()

    struct Row: Identifiable, Codable {
        let id: String            // idempotencyKey
        let createdAt: Date
        var updatedAt: Date
        var state: String         // queued/sending/acked/failed/replay
        var orderId: Int?
        var ticketNumber: Int?
        var miniAppId: Int?
        var message: String?
    }

    @Published private(set) var rows: [Row] = []

    private let key = "outbox.log.v1"

    private init() {
        load()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([Row].self, from: data) else {
            rows = []
            return
        }
        rows = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(rows) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func upsert(_ row: Row) {
        if let i = rows.firstIndex(where: { $0.id == row.id }) {
            rows[i] = row
        } else {
            rows.insert(row, at: 0)
        }
        save()
    }

    func queued(id: String, miniAppId: Int, ticketNumber: Int?, msg: String? = nil) {
        let now = Date()
        upsert(Row(id: id, createdAt: now, updatedAt: now, state: "queued",
                   orderId: nil, ticketNumber: ticketNumber, miniAppId: miniAppId, message: msg))
    }

    func sending(id: String, msg: String? = nil) {
        let now = Date()
        if var r = rows.first(where: { $0.id == id }) {
            r.updatedAt = now
            r.state = "sending"
            r.message = msg
            upsert(r)
        }
    }

    func acked(id: String, orderId: Int, replay: Bool = false, msg: String? = nil) {
        let now = Date()
        if var r = rows.first(where: { $0.id == id }) {
            r.updatedAt = now
            r.state = replay ? "replay" : "acked"
            r.orderId = orderId
            r.message = msg
            upsert(r)
        } else {
            upsert(Row(id: id, createdAt: now, updatedAt: now,
                       state: replay ? "replay" : "acked",
                       orderId: orderId, ticketNumber: nil, miniAppId: nil, message: msg))
        }
    }

    func failed(id: String, msg: String) {
        let now = Date()
        if var r = rows.first(where: { $0.id == id }) {
            r.updatedAt = now
            r.state = "failed"
            r.message = msg
            upsert(r)
        }
    }

    func clear() {
        rows.removeAll()
        save()
    }
}

struct OutboxLogView: View {
    @StateObject private var log = OutboxLog.shared
    private let df: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        NavigationStack {
            List {
                ForEach(log.rows) { r in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(r.state.uppercased())
                                .font(.system(size: 12, weight: .bold))
                            Spacer()
                            Text(df.string(from: r.updatedAt))
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }

                        if let oid = r.orderId {
                            Text("orderId: \(oid)")
                                .font(.system(size: 13, weight: .semibold))
                        }

                        let mini = r.miniAppId.map { "miniAppId: \($0)" } ?? "miniAppId: —"
                        let ticket = r.ticketNumber.map { "ticket: \($0)" } ?? "ticket: —"
                        Text("\(mini)   \(ticket)")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)

                        Text("id: \(r.id)")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .lineLimit(1)

                        if let m = r.message, !m.isEmpty {
                            Text(m)
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Outbox Log")
            .toolbar {
                Button("Clear") { log.clear() }
            }
        }
    }
}

import Network
import Foundation

@MainActor
final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()

    @Published private(set) var isOnline: Bool = true

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "network.monitor")

    private init() {
        monitor.pathUpdateHandler = { path in
            let ok = (path.status == .satisfied)
            Task { @MainActor in
                let wasOffline = (self.isOnline == false)
                self.isOnline = ok

                // ✅ When internet comes back → retry outbox
                if ok && wasOffline {
                    OrderOutbox.shared.drainNow()
                    NotificationCenter.default.post(name: .paymentAttemptNetworkRestored, object: nil)
                }
            }
        }
        monitor.start(queue: queue)
    }
}

extension Notification.Name {
    static let resetModifiers = Notification.Name("resetModifiers")
    static let paymentAttemptNetworkRestored = Notification.Name("paymentAttemptNetworkRestored")
}


struct MyItem: Codable, Identifiable, Equatable {
    let id: Int
    let name: String
    let imageURL: String?
    let lastPrice: Double
    let lastSubtitle: String?     // ✅ NEW
    let lastUsedAt: Date
    
    let lastSelectedOptions: [String: String]?
    let lastSelectedAdditions: [String]?
}

enum MyItemsStore {
    private static func currentMiniId() -> Int {
        let d = UserDefaults.standard
        let mini = d.integer(forKey: "miniAppId")
        if mini > 0 { return mini }

        if let s = d.string(forKey: "shopId"), let v = Int(s) { return v }
        return 0
    }
     
    // MARK: - Config
    private static var key: String {
        let miniId = currentMiniId()
        return "myItems.v1.mini.\(miniId)"
    }
    private static let maxItems = 8

    private static var defaults: UserDefaults {
        MinisShared.sharedDefaults
    }

    // MARK: - Public API

    /// Returns items ordered by most-recent first
    static func load() -> [MyItem] {
        guard let data = defaults.data(forKey: key),
              let items = try? JSONDecoder().decode([MyItem].self, from: data)
        else { return [] }

        return items.sorted { $0.lastUsedAt > $1.lastUsedAt }
    }

    /// Touch (add or promote) an item after a successful order
    static func touch(
        productId: Int,
        name: String,
        imageURL: String?,
        price: Double,
        subtitle: String?,
        selectedOptions: [String:String]? = nil,
        selectedAdditions: Set<String>? = nil
    ){
        var items = load()
        let now = Date()

        if let index = items.firstIndex(where: { $0.id == productId }) {
            let existing = items[index]
            items.remove(at: index)
            items.insert(
                MyItem(
                    id: productId,
                    name: name,
                    imageURL: imageURL,
                    lastPrice: price,
                    lastSubtitle: subtitle,
                    lastUsedAt: now,
                    lastSelectedOptions: selectedOptions,
                    lastSelectedAdditions: selectedAdditions.map { Array($0) }
                ),
                at: 0
            )
        } else {
            items.insert(
                MyItem(
                    id: productId,
                    name: name,
                    imageURL: imageURL,
                    lastPrice: price,
                    lastSubtitle: subtitle,
                    lastUsedAt: now,
                    lastSelectedOptions: selectedOptions,
                    lastSelectedAdditions: selectedAdditions.map { Array($0) }
                ),
                at: 0
            )
        }

        if items.count > maxItems { items = Array(items.prefix(maxItems)) }
        save(items)
    }

    static func remove(productId: Int) {
        var items = load()
        items.removeAll { $0.id == productId }
        save(items) // ✅ will post
    }

    static func clear() {
        defaults.removeObject(forKey: key)
        defaults.synchronize()
        NotificationCenter.default.post(name: .myItemsChanged, object: nil)   // ✅
    }

    // MARK: - Private

    private static func save(_ items: [MyItem]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: key)
        defaults.synchronize()
        NotificationCenter.default.post(name: .myItemsChanged, object: nil)   // ✅
    }

}
enum ServiceIntent: String {
    case sit
    case ta
}

private func diningModeFromIntent(_ raw: String) -> DiningMode {
    (ServiceIntent(rawValue: raw) == .sit) ? .dineIn : .takeAway
}

 func intentFromDiningMode(_ mode: DiningMode) -> ServiceIntent {
    (mode == .dineIn) ? .sit : .ta
}

 func labelForIntent(_ intent: ServiceIntent, isRtl: Bool) -> String {
    if isRtl {
        return intent == .sit ? "לשבת" : "לקחת"
    } else {
        return intent == .sit ? "Dine-in" : "Takeaway"
    }
}

#if !APPCLIP
 func emptySalesReportData() -> PrinterManager.SalesReportData {
    PrinterManager.SalesReportData(
        ppaRestaurant: 0,
        dinersRestaurant: 0,
        totalRestaurantIncVat: 0,
        ppaRestaurantValue: 0,
        ppaTA: 0,
        dinersTA: 0,
        totalTAIncVat: 0,
        totalSalesIncVat: 0,
        tipsTotal: 0,
        grandTotal: 0,
        cashAmount: 0,
        cashCount: 0,
        cardAmount: 0,
        cardCount: 0,
        collectionsTotalAmount: 0,
        collectionsTotalCount: 0,
        closedDrawersAmount: 0,
        openDrawersAmount: 0,
        depositWithdrawAmount: 0,
        drawerTotalAmount: 0,
        mainDrawerAmount: 0,
        hostStationDrawerAmount: 0,
        tipBaseTotal: 0,
        tipRestaurant: 0,
        tipBarTakeaway: 0,
        extraTipTotal: 0,
        extraTipRestaurant: 0,
        extraTipBar: 0,
        ordersOTHAmount: 0,  ordersOTHCount: 0,
        itemsOTHAmount: 0,   itemsOTHCount: 0,
        canceledItemsAmount: 0, canceledItemsCount: 0,
        refundedItemsAmount: 0, refundedItemsCount: 0,
        discountsAmount: 0,   discountsCount: 0,
        discountsRefundAmount: 0, discountsRefundCount: 0
    )
}
#endif
final class MenuScrollCoordinator: ObservableObject {
    @Published var scrollToTop = false
}

func nextMenuTicketNumber() -> Int {
    let key = "menu.localTicketNumber"
    let v = UserDefaults.standard.integer(forKey: key) + 1
    UserDefaults.standard.set(v, forKey: key)
    return v
}

struct AdminOrderLineItem: Identifiable, Hashable {
    let id: Int
    let productId: Int?
    let basketLineId: Int?

    var name: String
    var quantity: Int
    var unitPrice: Double
    var category: String?
    var modifiersText: String?
    var updatedAt: Date?
    var printer: String?

    var isCancelled: Bool = false   // ✅ ADD (default false)

    var rowTotal: Double { Double(quantity) * unitPrice }
}

struct AdminOrderItem: Identifiable, Hashable {
    let id: Int

    var orderId: String
    var customerName: String
    var subtitle: String
    var source: String
    var status: AdminOrderStatus
    var placedAt: Date
    var items: [AdminOrderLineItem]
    var total: Double
    var stations: Set<AdminStation>
    var isUnpaid: Bool
    var paymentMethod: String?

    // ✅ already added
    var customerPhone: String?

    // ✅ NEW — used by row badge + printer
    var diningMode: DiningMode

    // ✅ OPTIONAL but VERY useful for debugging / future DEL badge
    var isDelivery: Bool
}

// MARK: - API DTOs


 struct LineDTO: Decodable {
    let itemId: Int?
    let basketLineId: Int?   // ✅ ADD THIS (from Orders.Metadata basket[].lineId)
    let productId: Int?
    let name: String
    let qty: Int
    let category: String?
    let status: Int
    let station: String?
    let modifiers: String?
    let updatedAt: Date?
    let unitPrice: Double?
    let lineTotal: Double?
}

struct OrderDTO: Decodable {
    let id: Int
    let ticketNumber: Int?        // local slip number from DB (if present)
    let source: String
    let bucket: String
    let stage: String
    let placedAt: Date
    let scheduledFor: Date?
    let customerName: String
    let customerDisplayName: String?
    let customerPhone: String?    // ✅ NEW
    let totalGBP: Double
    let itemSummary: String
    let isDelivery: Bool
    let shortCode: String?
    let lines: [LineDTO]
    let status: Int?
    let paymentMethod: String?

    let service: String?          // ✅ NEW ("ta" / "sit" etc.)

    enum CodingKeys: String, CodingKey {
        case id, source, bucket, stage, placedAt, scheduledFor,
             customerName, customerDisplayName, customerPhone,
             totalGBP, itemSummary,
             isDelivery, shortCode, lines, status, paymentMethod, ticketNumber,
             service                      // ✅ NEW
        case Status = "Status"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        id           = try c.decode(Int.self, forKey: .id)
        ticketNumber = try? c.decodeIfPresent(Int.self, forKey: .ticketNumber)

        source       = try c.decode(String.self, forKey: .source)
        bucket       = try c.decode(String.self, forKey: .bucket)
        stage        = try c.decode(String.self, forKey: .stage)
        placedAt     = try c.decode(Date.self, forKey: .placedAt)
        scheduledFor = try? c.decodeIfPresent(Date.self, forKey: .scheduledFor)

        customerName        = try c.decode(String.self, forKey: .customerName)
        customerDisplayName = try? c.decodeIfPresent(String.self, forKey: .customerDisplayName)
        customerPhone       = try? c.decodeIfPresent(String.self, forKey: .customerPhone)

        totalGBP     = try c.decode(Double.self, forKey: .totalGBP)
        itemSummary  = try c.decode(String.self, forKey: .itemSummary)
        isDelivery   = try c.decode(Bool.self, forKey: .isDelivery)
        shortCode    = try? c.decodeIfPresent(String.self, forKey: .shortCode)
        lines        = try c.decode([LineDTO].self, forKey: .lines)
        paymentMethod = try? c.decodeIfPresent(String.self, forKey: .paymentMethod)

        service      = try? c.decodeIfPresent(String.self, forKey: .service)   // ✅ NEW

        // robust status decoding as before
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

// MARK: - Main View
struct BasketItem: Identifiable, Hashable {
    let id: Int
    let name: String
    let category: String
    let price: Double
}


enum AdminStation: Hashable {
    case bar
    case kitchen
    case bakery
}

enum StationViewMode: String {
    case bar
    case kitchen

    var title: String {
        switch self {
        case .bar:     return "עמדת בר"
        case .kitchen: return "עמדת מטבח"
        }
    }
}

// MARK: - Models

enum AdminOrderStatus: String, Codable {
    case received   // חדש / בתהליך
    case ready      // מוכן
    case collected  // נאסף
}

extension ShellMenuItem {

    private static func currentHour(now: Date) -> Int {
        Calendar.current.component(.hour, from: now) // 0...23
    }

    /// If no window is set -> available all day.
    /// If only from/to exists -> treat missing side as open-ended.
    /// Supports wrap (e.g. 22 -> 2).
    func isWithinActiveHours(now: Date = Date()) -> Bool {
        let from = activeFrom
        let to = activeTo
        if from == nil && to == nil { return true }

        let h = Self.currentHour(now: now)

        if let from, let to {
            if from == to { return true } // "all day" edge case
            if from < to {
                return (h >= from && h < to)
            } else {
                // wraps midnight (e.g. 22..2)
                return (h >= from || h < to)
            }
        }

        if let from { return h >= from }
        if let to { return h < to }
        return true
    }

  
}


extension Array where Element == BasketEntry {
    var requiresPhone: Bool {
        self.contains { ($0.item.isPhone ?? false) == true }
    }
}

func loadPendingCheckoutKey() -> String {
    (UserDefaults.standard.string(forKey: CheckoutRecoveryKeys.pendingCheckoutKey) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}
func savePendingCheckoutKey(_ key: String, miniAppId: Int) {
    UserDefaults.standard.set(key, forKey: CheckoutRecoveryKeys.pendingCheckoutKey)
    UserDefaults.standard.set(miniAppId, forKey: CheckoutRecoveryKeys.pendingMiniAppId)
}
func clearPendingCheckoutKey() {
    UserDefaults.standard.removeObject(forKey: CheckoutRecoveryKeys.pendingCheckoutKey)
    UserDefaults.standard.removeObject(forKey: CheckoutRecoveryKeys.pendingMiniAppId)
}

func canonicalPickupLocation(_ raw: String?) -> String? {
    let s = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

    if s == "humanities" { return "humanities" }
    if s == "humanity"   { return "humanities" }   // ✅ add
    if s == "social"     { return "social" }

    let compact = s.filter { $0.isLetter || $0.isNumber }
    if ["humanity","cafeteria","מדעיהרוח","רוח","קפיטריה","קפטריה"].contains(compact) { return "humanities" }
    if ["sciencebuilding","science","socialbuilding","מדעיהחברה","חברה"].contains(compact) { return "social" }

    return nil
}
extension ModifierItem {
    var linkedProduct: ShellMenuItem? {
        MenuCatalog.shared.item(for: linkedProductId)
    }

    var effectiveStatus: Int? {
        if let linked = linkedProduct {
            if let stock = linked.stockQuantity {
                return stock > 0 ? 1 : 0
            }
            return linked.status
        }
        return status
    }

    var effectiveName: String {
        linkedProduct?.displayName ?? name
    }

    var isAvailable: Bool {
        if let linked = linkedProduct {
            return linked.isAvailable
        }
        if let status, status == 0 { return false }
        return true
    }
}
extension ModifierItem {
    var resolvedName: String {
        if let linkedProductId,
           let linked = MenuCatalog.shared.item(for: linkedProductId) {
            return linked.displayName
        }
        return name
    }

    var isResolvedAvailable: Bool {
        if let linkedProductId,
           let linked = MenuCatalog.shared.item(for: linkedProductId) {
            return linked.isAvailable
        }

        if let status, status == 0 {
            return false
        }

        return true
    }
}
