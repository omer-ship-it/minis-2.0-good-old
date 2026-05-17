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
                  } else if oldValue == nil {
                  }
              }
      }
    
    
    private struct ProductsLastUpdateProbe: Decodable {
        struct Mini: Decodable {
            let productsLastUpdate: String?
            let isOpen: Bool?
            let settings: Settings?

            struct Settings: Decodable {
                let payments: Payments?

                struct Payments: Decodable {
                    let useChargeV2: Bool?
                }
            }
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

        // 🆕 Debug log so ops can watch the items/stock JSON refresh sequence in the
        // console alongside the [useChargeV2-poll] timer logs. Tagged distinctly so
        // they can be filtered separately. Event-driven (not timer-based) — fires
        // only when something explicitly calls load() (view onAppear, manual refresh,
        // toggle isOpen, after a product/stock change, etc.).
        let _loadTs = ISO8601DateFormatter().string(from: Date())
        print("[items-load] 🔄 triggered  shopId=\(shopId)  skipCache=\(skipCache)  ts=\(_loadTs)")

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

        // 🆕 Server-driven /charge toggle (read from mini.settings.payments.useChargeV2)
        // Persists to UserDefaults so the static OrderAPI.submitOrder helper can read it
        // synchronously without re-decoding the JSON each time.
        //
        // Live debug logging: every parse logs the current value (regardless of whether
        // it changed). Lets ops watch the console after publishing a JSON change to see
        // when the iPad picks it up. Filter logs by "[useChargeV2]" to isolate.
        func decodeAndPersistUseChargeV2(_ data: Data, source: String) {
            let dec = JSONDecoder()
            let parsed = (try? dec.decode(ProductsLastUpdateProbe.self, from: data))?
                .mini?.settings?.payments?.useChargeV2
            let prev = defaults.bool(forKey: "payments.useChargeV2")
            let ts = ISO8601DateFormatter().string(from: Date())

            if let v2 = parsed {
                defaults.set(v2, forKey: "payments.useChargeV2")
                if prev != v2 {
                    print("[useChargeV2] 🔄 CHANGED \(prev) → \(v2)  source=\(source)  ts=\(ts)")
                } else {
                    print("[useChargeV2] ✓ unchanged=\(v2)  source=\(source)  ts=\(ts)")
                }
            } else {
                // Field absent or null in JSON — keep last known value, log it
                print("[useChargeV2] ⚠️ field absent in JSON, keeping prev=\(prev)  source=\(source)  ts=\(ts)")
            }
        }

        // Apply to any cached data we already have on disk
        if let cd = cachedData {
            decodeAndPersistUseChargeV2(cd, source: "cache")
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
                    return
                }

                // ✅ Cache only valid JSON
                defaults.set(data, forKey: cacheKey)
                try? data.write(to: cacheURL, options: [.atomic])

                // ✅ Cache productsLastUpdate for quick future comparisons
                if let ts = decodeProductsLastUpdate(data), !ts.isEmpty {
                    defaults.set(ts, forKey: cacheTsKey)
                }

                // 🆕 Persist server-driven /charge toggle from fresh JSON
                decodeAndPersistUseChargeV2(data, source: "fresh-fetch")

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
                    }
                }
            } else {
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
                }
            } else {
            }
        } catch {
        }

        do {
            let decoder = JSONDecoder()

            // 1️⃣ Try wrapper: full shop payload
            if let wrapper = try? decoder.decode(ShopPayload.self, from: data) {

                // ✅ isOpen (again, if present)
                if let open = wrapper.mini?.isOpen {
                    await MainActor.run {
                        self.isOpen = open
                    }
                } else {
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

                if let raw = String(data: data, encoding: .utf8) {
                    if let r = raw.range(of: "\"netPrefix\"") {
                        let start = raw.index(r.lowerBound, offsetBy: -50, limitedBy: raw.startIndex) ?? raw.startIndex
                        let end   = raw.index(r.lowerBound, offsetBy: 80, limitedBy: raw.endIndex) ?? raw.endIndex
                    } else {
                    }
                }
                if let printers = printersPayload {
                    await MainActor.run {
                        persistPrinters(printers)
                    }
                } else {
                    // Helpful debug so you KNOW why it fell back to LAN prefix
                    #if DEBUG
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
            }

            // 2️⃣ Fallback: plain [ProductPayload]
            let products = try decoder.decode([ProductPayload].self, from: data)

            #if DEBUG
            if let ceasar = products.first(where: { $0.name.contains("קיסר") }) {
                ceasar.modifiers?.forEach { g in
                }
            }
            #endif

            await apply(mapProducts(products))
            saveReferralForCurrentShop(kind: .fastlane)

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

            // ✅ DEBUG BUNDLE CHECK
            if let it = newItems.first(where: { $0.id == 837 }) {
            } else {
            }
            if let b = newItems.first(where: { $0.id == 837 })?.bundle {
            } else {
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
                availableHours: $0.availableHours,
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
        return nil
    }


    // Optional: print raw JSON once (great for debugging)
    if let raw = String(data: data, encoding: .utf8) {
    } else {
    }

    do {
        let decoded = try JSONDecoder().decode(ShopPrintersPayload.self, from: data)
        return decoded
    } catch {
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

    // ✅ per-weekday available hours window (nil = no per-day restriction)
    let availableHours: [WeekdayHours]?

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

        case availableHours  = "AvailableHours"
        case availableHoursL = "availableHours"

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

        // ✅ per-weekday available hours
        let rawHours =
            (try? c.decodeIfPresent([WeekdayHours].self, forKey: .availableHours)) ??
            (try? c.decodeIfPresent([WeekdayHours].self, forKey: .availableHoursL))
        if let rawHours, !rawHours.isEmpty {
            availableHours = rawHours
        } else {
            availableHours = nil
        }

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


// MARK: - Per-weekday available hours
//
// One entry per weekday (Sunday=0 ... Saturday=6).
// `isOpen=false`  → product hidden on that weekday.
// Otherwise the product is available between `openMinutes`
// and `closeMinutes` (minutes from midnight, 0..1440).
// If `closeMinutes <= openMinutes`, the window wraps midnight.
struct WeekdayHours: Codable, Hashable, Equatable {
    let weekday: Int        // 0 = Sunday ... 6 = Saturday
    var isOpen: Bool
    var openMinutes: Int    // 0..1440
    var closeMinutes: Int   // 0..1440

    enum CodingKeys: String, CodingKey {
        case weekday    = "weekday"
        case isOpen     = "isOpen"
        case openMinutes  = "open"
        case closeMinutes = "close"
    }

    init(weekday: Int,
         isOpen: Bool = true,
         openMinutes: Int = 0,
         closeMinutes: Int = 24 * 60) {
        self.weekday = weekday
        self.isOpen = isOpen
        self.openMinutes = openMinutes
        self.closeMinutes = closeMinutes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let wd = (try? c.decode(Int.self, forKey: .weekday)) ?? 0
        let on = (try? c.decode(Bool.self, forKey: .isOpen)) ?? true
        let op = (try? c.decode(Int.self, forKey: .openMinutes)) ?? 0
        let cl = (try? c.decode(Int.self, forKey: .closeMinutes)) ?? 24 * 60
        self.weekday = max(0, min(6, wd))
        self.isOpen = on
        self.openMinutes = max(0, min(24 * 60, op))
        self.closeMinutes = max(0, min(24 * 60, cl))
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

    // ✅ NEW: per-weekday available hours (nil = no per-day restriction)
    let availableHours: [WeekdayHours]?

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

        // ✅ NEW: per-weekday available hours
        availableHours: [WeekdayHours]? = nil,

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

        // Normalize availableHours: keep one entry per weekday (0..6),
        // last write wins when duplicates appear, drop nil/empty arrays.
        if let availableHours, !availableHours.isEmpty {
            var dedup: [Int: WeekdayHours] = [:]
            for h in availableHours {
                let wd = max(0, min(6, h.weekday))
                dedup[wd] = WeekdayHours(
                    weekday: wd,
                    isOpen: h.isOpen,
                    openMinutes: max(0, min(24 * 60, h.openMinutes)),
                    closeMinutes: max(0, min(24 * 60, h.closeMinutes))
                )
            }
            self.availableHours = dedup.values.sorted { $0.weekday < $1.weekday }
        } else {
            self.availableHours = nil
        }

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

    // MARK: - useChargeV2 polling (debug visibility into the server-driven flag)
    //
    // Polls the published shop JSON every N seconds while the app is active and
    // updates UserDefaults["payments.useChargeV2"]. Logs every poll so ops can
    // watch the flag live in the console after publishing a JSON change.
    //
    // Wire from MINIS_02App.swift's scenePhase .active / .inactive cases.
    private static var useChargeV2PollTimer: Timer?

    static func startUseChargeV2Polling(intervalSeconds: TimeInterval = 20) {
        stopUseChargeV2Polling()
        // Fire once immediately so the first log appears right after activation
        pollUseChargeV2Once(reason: "active-start")
        useChargeV2PollTimer = Timer.scheduledTimer(withTimeInterval: intervalSeconds, repeats: true) { _ in
            pollUseChargeV2Once(reason: "timer-tick")
        }
        print("[useChargeV2-poll] ▶️ started — interval=\(Int(intervalSeconds))s")
    }

    static func stopUseChargeV2Polling() {
        guard useChargeV2PollTimer != nil else { return }
        useChargeV2PollTimer?.invalidate()
        useChargeV2PollTimer = nil
        print("[useChargeV2-poll] ⏸ stopped")
    }

    static func pollUseChargeV2Once(reason: String) {
        let defaults = UserDefaults.standard
        let miniAppIdFromDefaults = defaults.integer(forKey: "miniAppId")
        let storedShopId = defaults.string(forKey: "shopId") ?? ""
        let shopId: String
        if miniAppIdFromDefaults > 0 {
            shopId = String(miniAppIdFromDefaults)
        } else if !storedShopId.isEmpty {
            shopId = storedShopId
        } else {
            return // nothing to poll
        }

        let t = Int(Date().timeIntervalSince1970)
        guard let url = URL(string: "https://minis.studio/json/\(shopId).json?poll=\(t)") else { return }

        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue("no-store", forHTTPHeaderField: "Cache-Control")

        URLSession.shared.dataTask(with: req) { data, _, err in
            let ts = ISO8601DateFormatter().string(from: Date())
            if let err = err {
                print("[useChargeV2-poll] ❌ network error: \(err.localizedDescription)  reason=\(reason)  ts=\(ts)")
                return
            }
            guard let data else {
                print("[useChargeV2-poll] ❌ no data  reason=\(reason)  ts=\(ts)")
                return
            }

            // Minimal probe — just the flag, nothing else
            struct Probe: Decodable {
                struct Mini: Decodable {
                    struct Settings: Decodable {
                        struct Payments: Decodable { let useChargeV2: Bool? }
                        let payments: Payments?
                    }
                    let settings: Settings?
                }
                let mini: Mini?
            }

            guard let parsed = try? JSONDecoder().decode(Probe.self, from: data) else {
                print("[useChargeV2-poll] ❌ JSON decode failed  reason=\(reason)  ts=\(ts)")
                return
            }

            let prev = UserDefaults.standard.bool(forKey: "payments.useChargeV2")
            if let v2 = parsed.mini?.settings?.payments?.useChargeV2 {
                UserDefaults.standard.set(v2, forKey: "payments.useChargeV2")
                if prev != v2 {
                    print("[useChargeV2-poll] 🔄 CHANGED \(prev) → \(v2)  reason=\(reason)  shopId=\(shopId)  ts=\(ts)")
                } else {
                    print("[useChargeV2-poll] ✓ unchanged=\(v2)  reason=\(reason)  shopId=\(shopId)  ts=\(ts)")
                }
            } else {
                print("[useChargeV2-poll] ⚠️ field absent in JSON, keeping prev=\(prev)  reason=\(reason)  shopId=\(shopId)  ts=\(ts)")
            }
        }.resume()
    }

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
            // 🔎 DUPLICATE-YESH DIAGNOSTIC: log every single submitOrder INVOCATION.
            //   Each card transaction should produce EXACTLY ONE of these.
            //   If you see two for the same physical order with different timestamps
            //   close together → caller is double-firing. Capture call stack so we
            //   know which UI path triggered it.
            let __callerFile = (#file as NSString).lastPathComponent
            let __ts = ISO8601DateFormatter().string(from: Date())
            let __stackTop = Thread.callStackSymbols.prefix(6).joined(separator: " | ")
            print("🟦 [submitOrder/INVOKE] ts=\(__ts) orderId=\(orderId.map(String.init) ?? "nil") ticket=\(ticketNumber.map(String.init) ?? "nil") src=\(source) total=\(total) caller=\(__callerFile)")
            print("🟦 [submitOrder/STACK] \(__stackTop)")

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
            
            if let orderId {
                payload["orderId"] = orderId
                print("[submitOrder] sending orderId=\(orderId)")
            } else {
                print("[submitOrder] no orderId (fallback path)")
            }
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

                // ✅ FIX (Z-report gap): rebump dueVar/total to match cash+card on EVERY submit,
                // not just brand-new orders. Pre-/start-safe this guard was harmless because
                // orderId was always nil. After /start-safe, every cashpoint order already has
                // an orderId by the time we reach here, so the rebump silently stopped firing
                // for any order with a tip — producing the Gross > Payments gap on the Z report.
                // Dropping the `orderId == nil` clause keeps Total in sync with what was actually
                // collected, and the Z reconciles to the cent again.
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
            // When orderId exists (from start-safe / resumedOrderId), derive key
            // deterministically so backend matches the existing row and UPDATEs
            // instead of INSERTing.
            //
            // 🆕 Include payment method in the suffix. Two distinct submits for
            // the same orderId can occur (pay-later → cash on resumedOrderId),
            // and a method-less key collides — the server's idempotency layer
            // would replay the first submit's response and silently skip the
            // status=0 → status=1 update. Same-method retries still collide on
            // purpose, preserving idempotency for actual network retries.
            let idempotencyKey: String
            if let orderId {
                let methodSuffix = (payload["payment"] as? [String: Any])?["method"] as? String
                    ?? PaymentMethod.unpaid.rawValue
                idempotencyKey = "submit-\(orderId)-\(methodSuffix)"
            } else {
                idempotencyKey = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            }
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

#if DEBUG
            if let bodyData = req.httpBody,
               let bodyString = String(data: bodyData, encoding: .utf8) {
                let orderIdValue = payload["orderId"].map { "\($0)" } ?? "nil"
                let miniAppIdValue = payload["miniAppId"].map { "\($0)" } ?? "nil"
                let idempotencyValue = payload["idempotencyKey"].map { "\($0)" } ?? "nil"
                print("[submitOrder/json] orderId=\(orderIdValue) miniAppId=\(miniAppIdValue) idempotencyKey=\(idempotencyValue) body=\(bodyString)")
            }
            print("[submitOrder/curl] \(req.curlDebug)")
#endif

            // 🆕 (2026-05-15) Hole 62: build envelope and persist it to
            // disk SYNCHRONOUSLY before any network activity. This is
            // the cash-loss insurance for the rare crash-during-submit
            // window — if the app is killed while URLSession is mid
            // round-trip, the envelope is already on disk and the
            // drainer (on next launch / cashpoint onAppear / network
            // restore) will replay it. The server's idem-key dedup
            // handles the "already landed but we crashed before
            // hearing back" case so we never create a duplicate Yesh
            // invoice.
            //
            // State = `.sending`, `lastAttemptAt` = now: this tells the
            // drainer "a direct fire is currently in-flight, don't
            // touch this for 60s." On success the direct fire
            // synchronously removes the envelope; on failure it
            // flips state to `.pending` and kicks the drainer. See
            // Hole 62 comment in `OrderOutbox.drainNow` for the
            // drainer-side rule.
            let env = OutboxEnvelope(
                id: idempotencyKey,
                createdAt: Date(),
                state: .sending,
                attemptCount: 1,
                lastAttemptAt: Date(),
                endpoint: url.absoluteString,
                body: req.httpBody ?? Data(),
                headers: req.allHTTPHeaderFields ?? [:]
            )
            OrderOutbox.persistSync(env)
            print("📥 [submitOrder/PRE-FIRE-ENQUEUE] idem=\(idempotencyKey) state=sending — envelope on disk before URLSession fires")

            // 🛑 DUPLICATE-YESH FIX (canary):
            // Previously this fired BOTH the outbox (enqueue + drainNow) AND a direct
            // URLSession in parallel — two network POSTs to /submitOrder with the SAME
            // idempotency key, milliseconds apart. The server's early-replay SELECT is
            // not transactionally atomic with the INSERT, so the two requests could race
            // past it before either committed. Both INSERTed → two orderIds → two Yesh
            // invoices.
            //
            // New behavior: ONLY the direct URLSession fires on the happy path.
            // The outbox is only enqueued + drained if the direct fire fails (retry/durability).
            // Same idempotency key is preserved, so any future retry from outbox will hit
            // the server's idem dedup correctly.

            Task { @MainActor in
                NotificationCenter.default.post(name: .resetModifiers, object: nil)
            }

            Task { @MainActor in
                OutboxLog.shared.sending(id: idempotencyKey, msg: "sending…")
            }

            // 🟥 [submitOrder/DIRECT-FIRE] direct URLSession = ONLY network hit on happy path
            print("🟥 [submitOrder/DIRECT-FIRE] idem=\(idempotencyKey) ts=\(ISO8601DateFormatter().string(from: Date())) — direct URLSession.dataTask (outbox disabled on success path)")

            // 🆕 (2026-05-15) Hole 62: with the synchronous pre-fire
            // enqueue above, the envelope is already on disk in
            // `.sending` state. On failure we just flip it to
            // `.pending` so the drainer takes over. The disk write
            // is synchronous + nonisolated so it happens immediately
            // on the URLSession callback thread (no MainActor hop).
            // The drainer kick still hops through MainActor since the
            // drainer itself is @MainActor-bound.
            func enqueueForRetry(reason: String) {
                print("🔁 [submitOrder/RETRY-ENQUEUE] idem=\(idempotencyKey) reason=\(reason) — flipping pre-fired envelope to .pending")
                OrderOutbox.markPendingSync(id: idempotencyKey)
                Task { @MainActor in
                    OrderOutbox.shared.drainNow()
                }
            }

            URLSession.shared.dataTask(with: req) { data, resp, err in
                if let err = err {
                    Task { @MainActor in
                        OutboxLog.shared.failed(id: idempotencyKey, msg: err.localizedDescription)
                    }
                    enqueueForRetry(reason: "direct-fire error: \(err.localizedDescription)")
                    completion(.failure(err))
                    return
                }

                guard
                    let http = resp as? HTTPURLResponse,
                    (200...299).contains(http.statusCode),
                    let data = data,
                    let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                    enqueueForRetry(reason: "direct-fire bad status \(code)")
                    completion(.failure(SubmitError(message: "Server error")))
                    return
                }

                let oid = obj["orderId"] as? Int ?? 0
                let replay = (obj["replay"] as? Bool) ?? false

                // 🟩 [submitOrder/RESPONSE] server ack — note replay flag
                //   With outbox-on-failure-only, you should now see EXACTLY ONE RESPONSE
                //   per submitOrder INVOKE. If you still see Yesh duplicates after this
                //   fix is deployed, the source is server-side or external — not iPad.
                print("🟩 [submitOrder/RESPONSE] idem=\(idempotencyKey) orderId=\(oid) replay=\(replay) ts=\(ISO8601DateFormatter().string(from: Date()))")

                Task { @MainActor in
                    OutboxLog.shared.acked(
                        id: idempotencyKey,
                        orderId: oid,
                        replay: replay,
                        msg: replay ? "server replay" : "server ack"
                    )
                }

                if oid > 0 {
                    // 🆕 (2026-05-15) Hole 62: direct fire succeeded —
                    // synchronously remove the pre-fired envelope so the
                    // drainer can't pick it up and re-fire it. Removal
                    // is nonisolated + synchronous so it happens on this
                    // callback thread immediately, BEFORE the completion
                    // handler returns and any UI-side state change kicks
                    // a drain trigger.
                    OrderOutbox.removeSync(id: idempotencyKey)
                    print("✅ [submitOrder/POST-SUCCESS-REMOVE] idem=\(idempotencyKey) orderId=\(oid) — envelope cleared from outbox")
                    completion(.success(oid))
                } else {
                    enqueueForRetry(reason: "direct-fire returned no orderId")
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
    let orderId: Int?
    let rawPath: String?        // e.g. "commit_final", "status_exhausted"
    let rawReturnCode: String?  // e.g. "0", "-80", etc.

    /// Convenience flag so old code `if result.approved` keeps working
    var approved: Bool { status == .approved }
}

#if DEBUG
struct ZCreditAlreadyPaidDebugScenario {
    let shopId: Int
    let idempotencyKey: String
    let ticketId: String?
    let orderId: Int?
    let amount: Double
    let currency: String
    let paymentProvider: String
    let paymentMethod: String
    let customerName: String

    static let referenceOrder = ZCreditAlreadyPaidDebugScenario(
        shopId: 12,
        idempotencyKey: "ab62be2c-8751-4e81-a47d-965ac5993e86",
        ticketId: nil,
        orderId: 48668,
        amount: 68,
        currency: "GBP",
        paymentProvider: "minis",
        paymentMethod: "card",
        customerName: "נטלי"
    )
}

enum ZCreditDebugControls {
    static let alreadyPaidReferenceOrderKey = "zcredit.debug.alreadyPaid.referenceOrder"

    static var isReferenceOrderEnabled: Bool {
        UserDefaults.standard.bool(forKey: alreadyPaidReferenceOrderKey)
    }

    static func setReferenceOrderEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: alreadyPaidReferenceOrderKey)
    }
}
#endif

final class ZCreditPaymentHandler {
    static let shared = ZCreditPaymentHandler()

    private let baseURL = URL(string: "https://minis.studio")!

    // timers are no longer used for polling, but we keep them + invalidate
    // in case you later reintroduce some periodic logic
    private var statusTimer: Timer?
    private var timeoutTimer: Timer?

    private var currentDataTask: URLSessionDataTask?
    // Client-side safety timer for the iPad → server pinpad-charge call.
    //
    // Timeline of changes:
    //   30s → 60s on 2026-05-03 after a production incident where customer was charged
    //                successfully but the iPad showed "המסוף לא הגיב" because the server
    //                took >30s to return.
    //   60s → 120s on 2026-05-03 (same day): even with 60s, edge case existed where
    //                terminal hits its 60s limit + server processes Z-Credit response +
    //                returns to iPad, all within ~70-80s. Set ceiling to 2× terminal max
    //                so the iPad never gives up before the terminal has fully resolved.
    //
    // The matching URLRequest.timeoutInterval is also 120s (line ~2572), so URLSession
    // and our Timer fire together. Terminal's max transaction lifetime is 60s, so this
    // 120s gives 60s buffer for server-side Z-Credit roundtrip + JSON serialization +
    // network. If the iPad ever fires this timeout, something is genuinely broken
    // server-side, not a slow-but-successful pinpad transaction.
    private var paymentTimeoutSeconds: TimeInterval = 120

    private var currentCorrelationId: String?
    private var currentReferenceOrSession: String?
    private var currentSessionId: String?
    private var currentPinpadId: String?
    private(set) var lastStartSafeCurl: String?
    private(set) var lastStartSafeResponseDebug: String?
    private(set) var lastStartSafeParsedStatus: String?
    private(set) var lastReturnedOrderId: Int?

#if DEBUG
    private(set) var debugTerminalChargeStartCount: Int = 0
    private(set) var debugAlreadyPaidShortCircuitCount: Int = 0
    private(set) var debugEventLog: [String] = []
#endif

    // MARK: - Helper: map backend JSON → tri-state ZCreditResult

    private func log(_ message: String) {
        print("[ZCredit] \(message)")
        if message.contains("start-safe http status=") || message.contains("start-safe parse_error") {
            lastStartSafeResponseDebug = message
        }
#if DEBUG
        debugEventLog.append(message)
        if debugEventLog.count > 40 {
            debugEventLog.removeFirst(debugEventLog.count - 40)
        }
#endif
    }

    private func normalizedString(from json: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = json[key] as? String {
                let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !normalized.isEmpty {
                    return normalized.lowercased()
                }
            }
            if let value = json[key] as? NSNumber {
                return value.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }
        }
        return nil
    }

    private func boolValue(from json: [String: Any], keys: [String]) -> Bool? {
        for key in keys {
            if let value = json[key] as? Bool {
                return value
            }
            if let value = json[key] as? NSNumber {
                return value.boolValue
            }
            if let value = json[key] as? String {
                switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                case "true", "1", "yes", "approved", "success", "succeeded", "paid", "completed", "complete", "ok":
                    return true
                case "false", "0", "no", "declined", "failed", "cancelled", "canceled":
                    return false
                default:
                    break
                }
            }
        }
        return nil
    }

    var lastStartSafeDisplayStatus: String? {
        if let response = lastStartSafeResponseDebug?.lowercased(), !response.isEmpty {
            if response.contains("path=already_succeeded_short_circuit") ||
                response.contains("path=already_paid") ||
                response.contains("path=commit_success") ||
                response.contains("result=approved") ||
                response.contains("result=success") ||
                response.contains("result=succeeded") ||
                response.contains("result=paid") ||
                response.contains("result=completed") ||
                response.contains("checkoutstate=approved") ||
                response.contains("checkoutstate=paid") ||
                response.contains("submitstate=already_completed") ||
                response.contains("submitstate=completed") ||
                response.contains("submitstate=succeeded") ||
                response.contains("paymentstatus=approved") ||
                response.contains("paymentstatus=paid") ||
                response.contains("status=approved") ||
                response.contains("status=success") ||
                response.contains("status=succeeded") ||
                response.contains("status=paid") ||
                response.contains("status=completed") {
                return "approved"
            }
            if response.contains("result=declined") ||
                response.contains("result=failed") ||
                response.contains("checkoutstate=declined") ||
                response.contains("status=declined") ||
                response.contains("status=failed") {
                return "declined"
            }
            if response.contains("http status=202") ||
                response.contains("body=<empty>") ||
                response.contains("parse_error") {
                return "pending"
            }
        }
        return lastStartSafeParsedStatus
    }
    
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
            orderId: nil,
            rawPath: "client_bad_url",
            rawReturnCode: nil
        )
    }

#if DEBUG
    @MainActor
    func resetDebugInstrumentation() {
        debugTerminalChargeStartCount = 0
        debugAlreadyPaidShortCircuitCount = 0
        debugEventLog.removeAll()
    }
#endif

    private func finishFromResponse(
        json: [String: Any],
        completion: @escaping (ZCreditResult) -> Void
    ) {
        func extractOrderId(from json: [String: Any]) -> Int? {
            let candidates: [Any?] = [
                json["orderId"],
                json["OrderId"],
                json["existingOrderId"],
                json["ExistingOrderId"]
            ]

            for candidate in candidates {
                if let intValue = candidate as? Int, intValue > 0 {
                    return intValue
                }
                if let numberValue = candidate as? NSNumber, numberValue.intValue > 0 {
                    return numberValue.intValue
                }
                if let stringValue = candidate as? String,
                   let intValue = Int(stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
                   intValue > 0 {
                    return intValue
                }
            }
            return nil
        }

        func statusLabel(_ status: ZCreditResult.Status) -> String {
            switch status {
            case .approved: return "approved"
            case .declined: return "declined"
            case .unknown: return "pending"
            }
        }

        let pathRaw = normalizedString(from: json, keys: [
            "path", "Path", "rawPath", "RawPath", "statusPath", "StatusPath"
        ])
        let resultStr = normalizedString(from: json, keys: [
            "resultStatus", "ResultStatus", "result", "Result",
            "status", "Status", "paymentStatus", "PaymentStatus",
            "payment_status", "paymentState", "PaymentState"
        ])
        let checkoutState = normalizedString(from: json, keys: [
            "checkoutState", "CheckoutState", "checkout_state"
        ])
        let submitState = normalizedString(from: json, keys: [
            "submitState", "SubmitState", "submit_state"
        ])
        let replayRaw = boolValue(from: json, keys: ["replay", "Replay"])
        let path = pathRaw

        let reference = json["referenceNumber"] as? String
        let txId      = json["transactionId"] as? String
        let orderId   = extractOrderId(from: json)
        let rc = normalizedString(from: json, keys: [
            "invoiceReturnCode", "InvoiceReturnCode",
            "returnCode", "ReturnCode",
            "code", "Code",
            "statusCode", "StatusCode", "status_code"
        ])

        let msg = (json["invoiceReturnMessage"] as? String) ??
                  (json["ZCreditMessage"] as? String) ??
                  (json["message"] as? String) ??
                  ""

        // ------- CLASSIFICATION (similar spirit to old parseEnvelope) -------

        // 🆕 (2026-05-11): Pending paths take priority over rc-based classification.
        // These are server signals that the original /charge is still in flight or
        // that Z-Credit returned a transient response (-50101 etc). They must NOT
        // be treated as declined — that would cause the cashier to mint a fresh
        // idem key and bypass the server's in-flight guard, producing orphan rows.
        //
        //   - charge_in_flight : Step 3a-bis hit a Status=0 row younger than 90s
        //   - pending_fast     : Z-Credit returned -50101 (PinPad transient)
        //   - status_pending   : status-* lookup hasn't resolved yet
        //
        // Returning .unknown lets OrderFlowView's `shouldEnterReconciling` decide
        // — and the allowlist there forces TRUE for these paths, so the cashier
        // stays on "בדוק מצב עסקה" (verify-replay with same key) instead of
        // being shown "נסה שוב" (fresh key retry).
        let isPendingPath = (
            path == "charge_in_flight" ||
            path == "pending_fast" ||
            path == "status_pending"
        )
        if isPendingPath {
            let status: ZCreditResult.Status = .unknown
            lastStartSafeParsedStatus = statusLabel(status)

            invalidateTimers()
            currentCorrelationId      = nil
            currentReferenceOrSession = nil
            currentSessionId          = nil

            let fallbackMsg: String = {
                if path == "charge_in_flight" {
                    return "החיוב המקורי עדיין בתהליך. אנא המתינו ובדקו שוב."
                }
                if path == "pending_fast" {
                    return "התשלום בתהליך במסוף. אנא המתינו ובדקו שוב."
                }
                return "התשלום בתהליך. אנא בדקו שוב."
            }()

            let result = ZCreditResult(
                status: status,
                message: msg.isEmpty ? fallbackMsg : msg,
                referenceNumber: reference,
                transactionId: txId,
                orderId: orderId,
                rawPath: pathRaw,
                rawReturnCode: rc
            )
            log("start-safe returning orderId=\(orderId.map(String.init) ?? "nil") status=\(statusLabel(status)) (pending path=\(path))")
            DispatchQueue.main.async { completion(result) }
            return
        }

        // Explicit “device busy” code → decline with a clear message
        if rc == "-50101" {
            let status: ZCreditResult.Status = .declined
            lastStartSafeParsedStatus = statusLabel(status)

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
                orderId: orderId,
                rawPath: pathRaw,
                rawReturnCode: rc
            )
            log("start-safe returning orderId=\(orderId.map(String.init) ?? "nil") status=\(statusLabel(status))")
            DispatchQueue.main.async { completion(result) }
            return
        }

        // Old -80 = "keep waiting" → here we treat as UNKNOWN (caller can show 'payment not completed')
        if rc == "-80" {
            let status: ZCreditResult.Status = .unknown
            lastStartSafeParsedStatus = statusLabel(status)

            invalidateTimers()
            currentCorrelationId      = nil
            currentReferenceOrSession = nil
            currentSessionId          = nil

            let result = ZCreditResult(
                status: status,
                message: msg.isEmpty ? "התשלום לא הושלם במסוף" : msg,
                referenceNumber: reference,
                transactionId: txId,
                orderId: orderId,
                rawPath: pathRaw,
                rawReturnCode: rc
            )
            log("start-safe returning orderId=\(orderId.map(String.init) ?? "nil") status=\(statusLabel(status))")
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
            path == "commit_approved" ||
            path == "already_succeeded_short_circuit" ||
            path == "already_paid" ||
            path == "commit_success" ||
            path == "status_success"
        )

        let approvedStatusValues: Set<String> = [
            "approved", "success", "succeeded", "paid", "completed", "complete", "ok"
        ]
        let declinedStatusValues: Set<String> = [
            "declined", "failed", "error", "cancelled", "canceled"
        ]
        let approvedSubmitValues: Set<String> = [
            "already_completed", "completed", "succeeded", "approved"
        ]

        let isApprovedStatus = resultStr.map { approvedStatusValues.contains($0) } ?? false
        let isDeclinedStatus = resultStr.map { declinedStatusValues.contains($0) } ?? false
        let isApprovedCheckoutState = checkoutState.map { approvedStatusValues.contains($0) } ?? false
        let isDeclinedCheckoutState = checkoutState.map { declinedStatusValues.contains($0) } ?? false
        let isAlreadyCompletedSubmit = submitState.map { approvedSubmitValues.contains($0) } ?? false
        let isReplayApproved = (replayRaw == true) && (isApprovedStatus || isApprovedCheckoutState || isAlreadyCompletedSubmit)
        let isApprovedBool = boolValue(from: json, keys: [
            "approved", "Approved",
            "success", "Success",
            "alreadyPaid", "AlreadyPaid",
            "already_paid", "alreadySucceeded", "AlreadySucceeded"
        ]) == true

        let isApprovedCode = (rc == "0" || rc == "000" || rc == "00")   // typical “OK” codes
        let hasAnyCode     = (rc?.isEmpty == false)

        let finalStatus: ZCreditResult.Status

        if isApprovedStatus || isApprovedCheckoutState || isApprovedPath || isAlreadyCompletedSubmit || isReplayApproved || isApprovedBool || isApprovedCode {
            finalStatus = .approved
        } else if isDeclinedStatus || isDeclinedCheckoutState || isDeclinedPath || (hasAnyCode && !isApprovedCode) {
            // any non-0 code (except the special cases handled above) → decline
            finalStatus = .declined
        } else {
            // no clear signal → unknown
            finalStatus = .unknown
        }
        lastStartSafeParsedStatus = statusLabel(finalStatus)

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
            orderId: orderId,
            rawPath: pathRaw,
            rawReturnCode: rc
        )

        log("start-safe returning orderId=\(orderId.map(String.init) ?? "nil") status=\(statusLabel(finalStatus))")
        DispatchQueue.main.async {
            completion(result)
        }
    }
    @MainActor
    private func payLegacyStart(
        amount: Double,
        orderId: Int?,
        ticketId: String?,
        transactionType: String,
        idempotencyKey: String?,
        useLegacyEndpoint: Bool = false,
        completion: @escaping (ZCreditResult) -> Void
    ) {
        let _ = CashpointID(rawValue: UserDefaults.standard.integer(forKey: "cashpointID")) ?? .one

        let safeAmount = max(0, amount)
        let miniAppResolution = resolveMiniAppIdWithSource()
        let mid = miniAppResolution.value
        let pinpadId = resolvePinpadId(miniAppId: mid)


        guard mid > 0 else {
            let result = ZCreditResult(
                status: .unknown,
                message: "Missing miniAppId/shopId for /payments/zcredit/start",
                referenceNumber: nil,
                transactionId: nil,
                orderId: nil,
                rawPath: "client_missing_miniapp_id",
                rawReturnCode: nil
            )
            DispatchQueue.main.async { completion(result) }
            return
        }

        let correlationId = UUID().uuidString

        currentCorrelationId = correlationId
        currentPinpadId = pinpadId
        lastStartSafeResponseDebug = nil
        lastStartSafeParsedStatus = nil
        lastStartSafeCurl = nil
        lastReturnedOrderId = nil

        let stableKeyPrefix = idempotencyKey.map { String($0.prefix(8)) } ?? "-"

        let startBody: [String: Any] = [
            "MiniAppId": mid,
            "miniAppId": mid,
            "TicketId": ticketId ?? "",
            "ticketId": ticketId ?? "",
            "amount": safeAmount,
            "currency": "ILS",
            "authOnly": false,
            "orderId": orderId != nil ? String(orderId!) : "",
            "pinpadId": pinpadId,
            "transactionType": transactionType,
            "idempotencyKey": idempotencyKey ?? ""
        ]

        // 🚦 SERVER-DRIVEN /charge TOGGLE — single source of truth.
        //
        // Reads `payments.useChargeV2` from UserDefaults, populated each
        // time the published shop JSON is polled (see
        // `decodeAndPersistUseChargeV2` in `load()` and the periodic
        // `startUseChargeV2Polling` timer wired in `MINIS_02App.swift`).
        // The published JSON's `mini.settings.payments.useChargeV2` flag
        // is the only thing routing chooses on — there is no compile-time
        // hardcode, no simulator-only canary, and no per-shop override
        // anywhere in the iPad code. Republish the shop JSON with
        // `payments.useChargeV2: true` (or `false`) and every iPad picks
        // up the change on its next poll (~30 s).
        //
        // Selection logic:
        //   - useLegacyEndpoint == true                     → /start (caller forced legacy, e.g. partial pay)
        //   - txType != "01" (refunds, force-charge, etc.)  → /start (legacy, never /charge)
        //   - txType == "01" and useChargeV2 = true         → /charge (new endpoint)
        //   - txType == "01" and useChargeV2 = false        → /start (legacy)
        let useChargeV2Flag = UserDefaults.standard.bool(forKey: "payments.useChargeV2")
        let endpoint: String
        let endpointReason: String
        if useLegacyEndpoint {
            endpoint = "/payments/zcredit/start"
            endpointReason = "FORCE_LEGACY_PARTIAL"
        } else if transactionType != "01" {
            endpoint = "/payments/zcredit/start"
            endpointReason = "LEGACY_NON_01_TXTYPE_\(transactionType)"
        } else if useChargeV2Flag {
            endpoint = "/payments/zcredit/charge"
            endpointReason = "FLAG_USECHARGEV2_ON"
        } else {
            endpoint = "/payments/zcredit/start"
            endpointReason = "FLAG_USECHARGEV2_OFF"
        }
        let endpointTag = endpoint.contains("/charge") ? "⚡ /CHARGE" : "🔧 /START"
        print("[ENDPOINT] \(endpointTag) reason=\(endpointReason) forceLegacy=\(useLegacyEndpoint) flag=\(useChargeV2Flag) txType=\(transactionType) amount=\(safeAmount) pinpadId=\(pinpadId) miniAppId=\(mid) idempotency=\(idempotencyKey?.prefix(8) ?? "-")")
        guard let startURL = URL(string: endpoint, relativeTo: baseURL) else {
            DispatchQueue.main.async { completion(self.legacyBadURLResult()) }
            return
        }

        // 120s: aligned with paymentTimeoutSeconds (line ~2091).
        // Terminal's max transaction lifetime is 60s; we wait up to 2× that to cover
        // server-side Z-Credit response + serialization + network jitter. See the
        // detailed comment at paymentTimeoutSeconds for the timeline.
        var req = URLRequest(url: startURL, timeoutInterval: 120)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(correlationId, forHTTPHeaderField: "x-correlation-id")
        req.setValue(pinpadId, forHTTPHeaderField: "x-pinpad-id")
        req.setValue(String(mid), forHTTPHeaderField: "x-miniapp-id")
        if let idempotencyKey, !idempotencyKey.isEmpty {
            req.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
            req.setValue(idempotencyKey, forHTTPHeaderField: "X-Request-Id")
        }

        req.httpBody = try? JSONSerialization.data(withJSONObject: startBody)

#if DEBUG
        if let bodyData = req.httpBody,
           let bodyString = String(data: bodyData, encoding: .utf8) {
            var curlHeaders = [
                "Content-Type: application/json",
                "x-correlation-id: \(correlationId)",
                "x-pinpad-id: \(pinpadId)",
                "x-miniapp-id: \(mid)"
            ]
            if let idempotencyKey, !idempotencyKey.isEmpty {
                curlHeaders.append("Idempotency-Key: \(idempotencyKey)")
                curlHeaders.append("X-Request-Id: \(idempotencyKey)")
            }

            let escapedURL = startURL.absoluteString.replacingOccurrences(of: "'", with: "'\\''")
            let escapedBody = bodyString.replacingOccurrences(of: "'", with: "'\\''")
            let headerFlags = curlHeaders
                .map { "-H '\($0.replacingOccurrences(of: "'", with: "'\\''"))'" }
                .joined(separator: " \\\n  ")
            let curlString = """
            curl -X POST '\(escapedURL)' \\
              \(headerFlags) \\
              --data '\(escapedBody)'
            """
            lastStartSafeCurl = curlString
        }
#endif


        #if DEBUG
        debugTerminalChargeStartCount += 1
        #endif

        // Track whether this request already completed (guard against timeout + response race)
        var didComplete = false
        let completionOnce: (ZCreditResult) -> Void = { result in
            guard !didComplete else { return }
            didComplete = true
            completion(result)
        }

        // 30-second timeout: cancel ZCredit if no response
        invalidateTimers()
        let capturedCorrelationId = correlationId
        timeoutTimer = Timer.scheduledTimer(withTimeInterval: paymentTimeoutSeconds, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            guard self.currentCorrelationId == capturedCorrelationId else { return }
            self.log("payment timeout after \(Int(self.paymentTimeoutSeconds))s — cancelling")
            self.currentDataTask?.cancel()
            self.currentDataTask = nil
            self.cancelCurrent()
            let result = ZCreditResult(
                status: .unknown,
                message: "המסוף לא הגיב תוך \(Int(self.paymentTimeoutSeconds)) שניות",
                referenceNumber: nil,
                transactionId: nil,
                orderId: nil,
                rawPath: "client_timeout",
                rawReturnCode: nil
            )
            DispatchQueue.main.async { completionOnce(result) }
        }

        let task = URLSession.shared.dataTask(with: req) { [weak self] data, resp, error in
            guard let self = self else { return }
            DispatchQueue.main.async { self.timeoutTimer?.invalidate(); self.timeoutTimer = nil }

            if let error = error {
                // Ignore cancellation errors from our own timeout
                if (error as NSError).code == NSURLErrorCancelled {
                    return
                }
                let json: [String: Any] = [
                    "ok": false,
                    "path": "commit_http_error",
                    "message": "שגיאה בתחילת עסקה במסוף: \(error.localizedDescription)"
                ]
                self.finishFromResponse(json: json, completion: completionOnce)
                return
            }

            guard let http = resp as? HTTPURLResponse,
                  let data = data,
                  http.statusCode == 200,
                  !data.isEmpty
            else {
                if let http = resp as? HTTPURLResponse {
                    self.log("start-safe http status=\(http.statusCode) body=<empty>")
                } else {
                    self.log("start-safe http status=nil body=<empty>")
                }
                let json: [String: Any] = [
                    "ok": false,
                    "path": "commit_http_non_200",
                    "message": "שגיאה בתחילת עסקה במסוף"
                ]
                self.finishFromResponse(json: json, completion: completionOnce)
                return
            }

            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                let rawBody = String(data: data, encoding: .utf8) ?? "<non-utf8>"
                self.log("start-safe parse_error rawBody=\(rawBody)")
                let json: [String: Any] = [
                    "ok": false,
                    "path": "client_parse_error",
                    "message": "תגובה לא תקינה מהמסוף"
                ]
                self.finishFromResponse(json: json, completion: completionOnce)
                return
            }

            let rawBody = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            let pathValue = (obj["path"] as? String)
                ?? (obj["Path"] as? String)
                ?? (obj["rawPath"] as? String)
                ?? "nil"
            let resultValue = (obj["resultStatus"] as? String)
                ?? (obj["ResultStatus"] as? String)
                ?? (obj["result"] as? String)
                ?? (obj["Result"] as? String)
                ?? (obj["status"] as? String)
                ?? (obj["Status"] as? String)
                ?? "nil"
            let checkoutStateValue = (obj["checkoutState"] as? String)
                ?? (obj["CheckoutState"] as? String)
                ?? "nil"
            let submitStateValue = (obj["submitState"] as? String)
                ?? (obj["SubmitState"] as? String)
                ?? "nil"
            let returnCodeValue = (obj["returnCode"] as? String)
                ?? (obj["ReturnCode"] as? String)
                ?? (obj["code"] as? String)
                ?? (obj["Code"] as? String)
                ?? "nil"
            self.log("start-safe http status=\(http.statusCode) path=\(pathValue) result=\(resultValue) checkoutState=\(checkoutStateValue) submitState=\(submitStateValue) returnCode=\(returnCodeValue) rawBody=\(rawBody)")

            if let sid = (obj["sessionId"] as? String) ?? (obj["SessionId"] as? String) {
                self.currentSessionId = sid
            }
            if let ref = (obj["referenceNumber"] as? String) ?? (obj["ReferenceNumber"] as? String) {
                self.currentReferenceOrSession = ref
            }
            if let orderId = (obj["orderId"] as? Int)
                ?? (obj["OrderId"] as? Int)
                ?? Int((obj["orderId"] as? String) ?? "")
                ?? Int((obj["OrderId"] as? String) ?? ""),
               orderId > 0 {
                self.lastReturnedOrderId = orderId
                self.log("start-safe returned orderId=\(orderId)")
            }

            self.finishFromResponse(json: obj, completion: completionOnce)
        }
        currentDataTask = task
        task.resume()
    }

    // MARK: - Main entry point

    @MainActor
    func pay(
        amount: Double,
        orderId: Int?,
        ticketId: String? = nil,
        transactionType: String = "01",   // ✅ NEW: "01" = regular, "53" = refund
        idempotencyKey: String? = nil,
        useLegacyEndpoint: Bool = false,
        completion: @escaping (ZCreditResult) -> Void
    ) {
        let effectiveAmount = amount
        let effectiveOrderId = orderId
        let effectiveTicketId = ticketId

        let stableIdempotencyKey: String = {
            if let existingAttempt = PaymentAttemptStore.shared.unresolvedAttempt(
                reusingAmount: effectiveAmount,
                orderReference: effectiveTicketId
            ) {
                let reused = existingAttempt.idempotencyKey
                return reused
            }

            let generated = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            return generated
        }()

        log("starting real payment flow idempotency=\(stableIdempotencyKey)")

        payLegacyStart(
            amount: effectiveAmount,
            orderId: effectiveOrderId,
            ticketId: effectiveTicketId,
            transactionType: transactionType,
            idempotencyKey: stableIdempotencyKey,
            useLegacyEndpoint: useLegacyEndpoint,
            completion: completion
        )
    }

    // MARK: - Cancel

    private func invalidateTimers() {
        statusTimer?.invalidate()
        timeoutTimer?.invalidate()
        statusTimer = nil
        timeoutTimer = nil
        currentDataTask?.cancel()
        currentDataTask = nil
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
        print("[ZCredit] cancelCurrent → pinpadId=\(body["pinpadId"] ?? "nil") streamId=\(body["streamId"] ?? "nil")")

        URLSession.shared.dataTask(with: req) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            print("[ZCredit] cancel response status=\(status) error=\(error?.localizedDescription ?? "none")")
        }.resume()
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


        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err = err {
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
                self.pendingResult = .failure(e)
                completion(.init(status: .failure, errors: [e]))
                return
            }

            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]

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

        let curl = """
        curl -sS -i -X POST "\(url.absoluteString)" \
          -H "Content-Type: application/json" \
          -H "Accept: application/json" \
          -d '\(bodyString.replacingOccurrences(of: "\n", with: " "))'
        """

        let start = Date()

        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err = err {
                completion(.failure(err))
                return
            }

            guard let http = resp as? HTTPURLResponse else {
                let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? "<no body>"
                completion(.failure(NSError(domain: "TeamTabsAPI", code: -2, userInfo: ["body": text])))
                return
            }

            let ms = Int(Date().timeIntervalSince(start) * 1000)
            let raw = data ?? Data()
            let text = String(data: raw, encoding: .utf8) ?? "<non-utf8 \(raw.count) bytes>"

            // ✅ DEBUG RESPONSE

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
        }

        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err = err {
                completion(.failure(err))
                return
            }

            guard let http = resp as? HTTPURLResponse else {
                let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? "<no body>"
                completion(.failure(NSError(domain: "TeamTabsAPI", code: -3, userInfo: ["body": text])))
                return
            }

            guard (200...299).contains(http.statusCode), let data else {
                let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? "<no body>"
                completion(.failure(NSError(domain: "TeamTabsAPI", code: http.statusCode, userInfo: ["body": text])))
                return
            }

            do {
                let decoded = try JSONDecoder().decode(OpenResp.self, from: data)
                completion(.success(decoded.orderId))
            } catch {
                let text = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
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
                completion(.failure(NSError(domain: "TeamTabsAPI", code: -11, userInfo: ["body": body])))
                return
            }

            guard (200...299).contains(http.statusCode), let data = data else {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? "<no body>"
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
        print("📊 [ReportModel] load called — type=\(type) shopId=\(shopId) date=\(String(describing: date)) isLoading=\(isLoading)")
        guard !isLoading else {
            print("📊 [ReportModel] SKIPPED — already loading")
            return
        }
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
            print("📊 [ReportModel] CATCH error: \(error)")
            let ns = error as NSError
            let body = (ns.userInfo[NSLocalizedDescriptionKey] as? String) ?? ""
            self.loadError = body.isEmpty ? String(describing: error) : body
        }
    }

    // MARK: - X report

    private func fetchXReport(miniAppId: Int) async throws -> XReportApiResponse {
        let url = URL(string: "https://minis.studio/api/xreport?miniAppId=\(miniAppId)")!
        print("📊 [fetchXReport] GET \(url)")
        let (raw, resp) = try await URLSession.shared.data(from: url)

        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        print("📊 [fetchXReport] HTTP \(code), \(raw.count) bytes")
        guard (200..<300).contains(code) else {
            let body = String(data: raw, encoding: .utf8) ?? "<non-utf8 \(raw.count) bytes>"
            print("📊 [fetchXReport] ERROR body: \(body)")
            throw NSError(domain: "http", code: code, userInfo: [NSLocalizedDescriptionKey: body])
        }

        let decoded = try JSONDecoder().decode(XReportApiResponse.self, from: raw)
        print("📊 [fetchXReport] decoded ok=\(decoded.ok) ordersCount=\(decoded.agg.ordersCount)")
        return decoded
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

        // 🆕 (2026-05-16) Hole 94: discount aggregation columns.
        // Optional + default 0 in `applyingZReport` so older
        // ZReports rows that predate the columns decode cleanly
        // (server returns them as null on backwards-compat reads).
        let DiscountsTotal: Double?
        let DiscountsCount: Int?

        // 🆕 (2026-05-16) Hole 101: OTH (on-the-house)
        // aggregation columns. Same shape + decode tolerance as
        // the discount fields above — pre-Hole-101 rows return
        // null and we fall back to 0.
        let OtherTotal: Double?
        let OtherCount: Int?

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

        let (raw, resp) = try await URLSession.shared.data(from: url)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1

        let rawText = String(data: raw, encoding: .utf8) ?? "<non-utf8 \(raw.count) bytes>"

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

    // 🆕 (2026-05-16) Hole 94: discount aggregation columns
    // (added to dbo.ZReports). Both default to 0 in the decode
    // path below so older rows that predate the migration stay
    // valid on the wire.
    let discountsTotal: Double
    let discountsCount: Int

    // 🆕 (2026-05-16) Hole 101: OTH (on-the-house) aggregation
    // columns. Same shape + tolerant-decode handling as the
    // discount fields above — pre-migration rows default to 0.
    let othTotal: Double
    let othCount: Int

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
        case discountsTotal = "DiscountsTotal"
        case discountsCount = "DiscountsCount"
        case othTotal = "OtherTotal"
        case othCount = "OtherCount"

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

        // 🆕 (2026-05-16) Hole 94: tolerant decode — older ZReports
        // rows predate these columns and the server returns them as
        // null/missing on backwards-compat reads. Default to 0 so
        // the printed Z slip's "הנחות" line shows "-" for those.
        discountsTotal = (try? c.decodeIfPresent(Double.self, forKey: .discountsTotal)) ?? 0
        discountsCount = (try? c.decodeIfPresent(Int.self,    forKey: .discountsCount)) ?? 0

        // 🆕 (2026-05-16) Hole 101: tolerant decode for OTH —
        // pre-migration rows return null/missing, default to 0.
        othTotal = (try? c.decodeIfPresent(Double.self, forKey: .othTotal)) ?? 0
        othCount = (try? c.decodeIfPresent(Int.self,    forKey: .othCount)) ?? 0

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
        //
        // Cash bucket = cash sales + cash tips, so the figure on the slip
        // matches what's physically in the drawer (and the "הד. סגורות /
        // סה״כ במגירה / מגירה ראשית" rows below). Mirrors the explicit
        // restore-Z math at FastlaneModel.swift:4050–4058.
        let cashWithCashTips = res.agg.cashTotal + res.agg.cashTipsTotal

        d.cashCount = res.agg.cashCount
        d.cashAmount = cashWithCashTips
        d.cardCount = res.agg.cardCount
        d.cardAmount = res.agg.cardTotal
        d.collectionsTotalCount = res.agg.cashCount + res.agg.cardCount + res.agg.mixedCount
        d.collectionsTotalAmount = cashWithCashTips + res.agg.cardTotal

        // Drawer rows on the printed slip read from these fields and
        // currently default to 0 in the live X/Z path; populate them from
        // the cash-with-tips total so "הד. סגורות / סה״כ במגירה / מגירה
        // ראשית" don't lag behind the payments section.
        d.closedDrawersAmount = cashWithCashTips
        d.drawerTotalAmount   = cashWithCashTips
        d.mainDrawerAmount    = cashWithCashTips

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

        // 🆕 (2026-05-16) Hole 94: surface the discount aggregation
        // on the printed Z-Report. PrinterManager's printSalesReport
        // already has a "הנחות" row in the EXCEPTIONS section that
        // reads `report.discountsAmount` + `report.discountsCount` —
        // populating these here lights it up for closed Z reports
        // the same way applyingXReport does for the X variant.
        d.discountsAmount = latest.discountsTotal
        d.discountsCount = latest.discountsCount

        // 🆕 (2026-05-16) Hole 101: surface the OTH (on-the-
        // house) aggregation on the printed Z. PrinterManager's
        // EXCEPTIONS section already has an "OTH הזמנות" row
        // bound to `report.ordersOTHAmount` + `report.ordersOTHCount`;
        // populating those here means closed Zs print the comp
        // line the same way X-Reports do.
        d.ordersOTHAmount = latest.othTotal
        d.ordersOTHCount = latest.othCount

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
    let forcedIdempotencyKeyValue = "2B5B79A8411740E2A6BD4A0C2D7A0A12"
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
            return nil
        case .failedFinal:
            return nil
        }
        let age = Date().timeIntervalSince(attempt.updatedAt)
        if age > staleOpenAttemptThreshold {
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
        guard let attempt = activeAttempt else { return nil }
        switch attempt.state {
        case .succeeded:
            return nil
        case .pending, .reconciling, .failedFinal:
            break
        }
        let age = Date().timeIntervalSince(attempt.updatedAt)
        if age > staleOpenAttemptThreshold {
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
        log("reuseCurrent amount=\(amount ?? attempt.amount) orderRef=\(orderReference ?? attempt.orderReference ?? "-")", attempt: attempt)
        return attempt
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

    func updateOrderId(_ orderId: Int?) {
        guard let orderId else { return }
        guard var attempt = activeAttempt else { return }
        if attempt.orderId == orderId { return }

        attempt = PaymentAttempt(
            attemptId: attempt.attemptId,
            idempotencyKey: attempt.idempotencyKey,
            orderId: orderId,
            orderReference: attempt.orderReference,
            amount: attempt.amount,
            state: attempt.state,
            createdAt: attempt.createdAt,
            updatedAt: Date()
        )
        activeAttempt = attempt
        save()
        log("captured orderId=\(orderId)", attempt: attempt)
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

    // 🆕 (2026-05-15) Hole 62: nonisolated synchronous file ops so
    // submitOrder can persist the envelope to disk BEFORE firing the
    // network call. The MainActor wrapper on the class is only needed
    // for the ObservableObject publishing side; raw file I/O is
    // thread-safe with atomic writes and doesn't need actor isolation.
    //
    // Closes the crash-window where a wifi blip + force-quit during
    // URLSession.dataTask would have lost a cash row entirely. Before
    // this fix, the envelope was only written to disk on `.failure`
    // (and even then via a `Task { @MainActor in }` — async write).
    // Now the envelope hits disk synchronously on the thread that
    // started the submit, before any network activity.

    /// Nonisolated path to the outbox directory. Creates it if missing.
    nonisolated static func envelopeDirURL() -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("order_outbox", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    nonisolated static func envelopeFileURL(for id: String) -> URL {
        envelopeDirURL().appendingPathComponent("\(id).json")
    }

    /// Write (or overwrite) an envelope to disk synchronously. Used by
    /// `OrderAPI.submitOrder` to pre-stage the retry envelope BEFORE
    /// the URLSession.dataTask fires. Overwrites any prior envelope
    /// with the same idem key (deliberate — represents the freshest
    /// in-flight attempt).
    nonisolated static func persistSync(_ env: OutboxEnvelope) {
        let url = envelopeFileURL(for: env.id)
        guard let data = try? JSONEncoder().encode(env) else { return }
        try? data.write(to: url, options: [.atomic])
    }

    /// Synchronous delete — called on submitOrder direct-fire success
    /// to cleanly remove the pre-staged envelope before any drainer
    /// can pick it up and re-fire it.
    nonisolated static func removeSync(id: String) {
        let url = envelopeFileURL(for: id)
        try? FileManager.default.removeItem(at: url)
    }

    /// Synchronous state flip from `.sending` → `.pending`. Called on
    /// submitOrder direct-fire failure to hand the envelope over to
    /// the drainer for later retry.
    nonisolated static func markPendingSync(id: String) {
        let url = envelopeFileURL(for: id)
        guard let raw = try? Data(contentsOf: url),
              var env = try? JSONDecoder().decode(OutboxEnvelope.self, from: raw) else { return }
        env.state = .pending
        guard let data = try? JSONEncoder().encode(env) else { return }
        try? data.write(to: url, options: [.atomic])
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

                // 🆕 (2026-05-15) Hole 62: skip envelopes currently
                // in-flight from a direct fire. With the new
                // synchronous-before-network pattern, submitOrder
                // writes the envelope in `.sending` state with a
                // fresh `lastAttemptAt` BEFORE firing the network
                // call. If a drainer is triggered (e.g., by network
                // reachability) while the direct fire is mid-call,
                // we must NOT fire a second POST with the same idem
                // key — the server's idempotency SELECT/INSERT race
                // would create duplicate Yesh invoices (the bug
                // that the old "only enqueue on failure" pattern
                // was trying to avoid). Skip anything `.sending`
                // less than 60s old; older `.sending` envelopes are
                // assumed orphaned (app crashed mid-fire) and are
                // safe to retake.
                if env.state == .sending,
                   let last = env.lastAttemptAt,
                   Date().timeIntervalSince(last) < 60 {
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

    /// Today's available-hours entry, if one exists for the current weekday.
    /// Returns `nil` when the product has no per-day window configured (i.e.
    /// it's available all the time and no badge is needed).
    func todayAvailableHoursEntry(now: Date = Date(), calendar: Calendar = .current) -> WeekdayHours? {
        guard let hours = availableHours, !hours.isEmpty else { return nil }
        let weekday = calendar.component(.weekday, from: now) - 1
        return hours.first(where: { $0.weekday == weekday })
    }

    /// Short label describing the per-day availability, e.g. `"8:00–17:00"`
    /// or `"סגור היום"`. Returns `nil` when the product is currently inside
    /// its window (no badge needed) or has no per-day restriction at all.
    func availableHoursBadge(now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard let entry = todayAvailableHoursEntry(now: now, calendar: calendar) else { return nil }
        if isAvailableOnWeekday(now: now) { return nil }   // inside window → no badge

        if !entry.isOpen { return "סגור היום" }

        func format(_ minutes: Int) -> String {
            let h = (minutes / 60) % 24
            let m = minutes % 60
            return String(format: "%d:%02d", h, m)
        }

        return "\(format(entry.openMinutes))–\(format(entry.closeMinutes))"
    }

    /// Per-weekday available hours.
    /// • If `availableHours` is nil/empty → no restriction (true).
    /// • If today's entry is missing → treated as no restriction (true).
    /// • If today's entry has `isOpen=false` → false (hidden today).
    /// • Otherwise the current minute-of-day must fall inside [open, close).
    ///   If `close <= open`, the window wraps midnight.
    func isAvailableOnWeekday(now: Date = Date()) -> Bool {
        guard let hours = availableHours, !hours.isEmpty else { return true }

        let cal = Calendar.current
        // Calendar weekday: 1 = Sunday … 7 = Saturday  →  0..6
        let weekday = cal.component(.weekday, from: now) - 1
        let h = cal.component(.hour, from: now)
        let m = cal.component(.minute, from: now)
        let nowMin = h * 60 + m

        guard let entry = hours.first(where: { $0.weekday == weekday }) else {
            return true
        }
        if !entry.isOpen { return false }

        let open = entry.openMinutes
        let close = entry.closeMinutes
        if open == close { return true }                 // all-day edge
        if open < close { return nowMin >= open && nowMin < close }
        // wraps midnight (e.g. 22:00 → 02:00)
        return nowMin >= open || nowMin < close
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
