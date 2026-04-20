
import UniformTypeIdentifiers
import Kingfisher
import Combine
import SwiftUI
import WebKit
import MessageUI


struct CashPointView: View {
    @AppStorage("cashpointID") private var cashpointIDRaw: Int = 2
    @State private var activeTeamTab: TabType? = nil   // nil = normal customer mode
    @State private var showTeamTabsSheet = false
    @State private var noteEditingLineId: Int? = nil
    @State private var noteEditingText: String = ""
    @FocusState private var focusedStockProductId: Int?
    @State private var pinpadId: String = ""
    @Environment(\.isRtl) private var isRtl
    @Environment(\.currency) private var currency
    @StateObject private var api = MenuApiModel()
    @State private var adminDraft: AdminProductDraft?
    @State private var selectedCategory: String = ""
    @State private var basket: [Int: BasketEntry] = [:]    // key = lineId
    @State private var nextBasketLineId: Int = 1
    @State private var selectedItemForModifiers: ShellMenuItem?
    @State private var showConfirmation = false
    @State private var lastOrder: CashOrderSnapshot?
    @State private var diningMode: DiningMode = .dineIn
    @State private var showOrderFlow = false
    @State private var editzingLineId: Int? = nil
    @State private var swipingProductId: Int? = nil
    @State private var outOfStockProductIds: Set<Int> = []
    @State private var draggingProduct: ShellMenuItem?
    @State private var hasChosenServiceMode: Bool = false
    @State private var showLastInvoicePrompt: Bool = false
    @State private var zRestoreMode: Bool = false
    @State private var showZeroStockConfirm = false
    private enum DragAxis { case none, horizontal, vertical }
    @State private var localFrozenOverrides: [String: Bool] = [:]
    @State private var renamingCategory: String? = nil
    @State private var renamingText: String = ""
    @State private var basketShakeTrigger: CGFloat = 0
    private let archiveCategoryTitle = "ארכיון"
    
    private func hasBasketValidationError() -> Bool {
        firstBasketLineWithMissingRequired() != nil
    }
    
    private func isModifierVisible(_ opt: ModifierItem) -> Bool {
        guard let linkedId = opt.linkedProductId else {
            return true   // normal modifier, always visible
        }

        guard let linked = api.items.first(where: { $0.id == linkedId }) else {
            return true   // if linked product missing, don't hide it completely
        }

        // archived products should also disappear
        if isArchived(linked) {
            return false
        }

        // local stock quantity wins
        if let q = stockAdjustments[linkedId] {
            return q > 0
        }

        // fallback to toggle/status
        return stockToggles.isOn(linkedId)
    }
    
    private func displayModifierName(_ opt: ModifierItem) -> String {
        if let linkedId = opt.linkedProductId,
           let linked = api.items.first(where: { $0.id == linkedId }) {
            return linked.name
        }
        return opt.name
    }
    
    struct FlowLayout<Data: RandomAccessCollection, Content: View>: View where Data.Element: Hashable {

        var data: Data
        var spacing: CGFloat = 6
        var content: (Data.Element) -> Content

        @State private var totalHeight = CGFloat.zero

        var body: some View {
            GeometryReader { geo in
                self.generateContent(in: geo)
            }
            .frame(height: totalHeight)
        }

        private func generateContent(in geo: GeometryProxy) -> some View {

            var width = CGFloat.zero
            var height = CGFloat.zero

            return ZStack(alignment: .topLeading) {

                ForEach(Array(data), id: \.self) { item in

                    content(item)
                        .alignmentGuide(.leading) { dimension in
                            if abs(width - dimension.width) > geo.size.width {
                                width = 0
                                height -= dimension.height + spacing
                            }
                            let result = width
                            if item == data.last {
                                width = 0
                            } else {
                                width -= dimension.width + spacing
                            }
                            return result
                        }

                        .alignmentGuide(.top) { _ in
                            let result = height
                            if item == data.last {
                                height = 0
                            }
                            return result
                        }
                }
            }
            .background(
                GeometryReader { geo -> Color in
                    DispatchQueue.main.async {
                        totalHeight = geo.size.height
                    }
                    return Color.clear
                }
            )
        }
    }

    private func validateBasketBeforeCheckout() -> Bool {
        guard let badLineId = firstBasketLineWithMissingRequired() else {
            return true
        }

        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
            expandedBasketLineId = badLineId
        }

        if isPhoneLayout {
            showBasketSheetPhone = true
        }

        Haptics.error()

        withAnimation(.linear(duration: 0.45)) {
            basketShakeTrigger += 1
        }

        return false
    }
    private func firstBasketLineWithMissingRequired() -> Int? {
        for entry in basketEntriesSorted {
            let groups = entry.item.modifiers ?? []
            let optionsMap = optionSelections[entry.id] ?? [:]

            for g in groups where g.type == .options {
                let isRequired = (g.selection?.required ?? 0) > 0
                guard isRequired else { continue }

                let selectedValue = optionsMap[g.title]?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if selectedValue.isEmpty {
                    return entry.id
                }
            }
        }
        return nil
    }

    private func triggerBasketValidationError() {
        if let badLineId = firstBasketLineWithMissingRequired() {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                expandedBasketLineId = badLineId
            }

            if isPhoneLayout {
                showBasketSheetPhone = true
            }

            Haptics.error()

            withAnimation(.linear(duration: 0.45)) {
                basketShakeTrigger += 1
            }
        }
    }
    
    private enum AdditionMode: String, Codable, Hashable {
        case with = "with"
        case without = "without"
        case side = "side"
    }
    
    struct ShakeEffect: GeometryEffect {
        var amount: CGFloat = 10
        var shakesPerUnit: CGFloat = 3
        var animatableData: CGFloat

        func effectValue(size: CGSize) -> ProjectionTransform {
            let translation = amount * sin(animatableData * .pi * shakesPerUnit)
            return ProjectionTransform(CGAffineTransform(translationX: translation, y: 0))
        }
    }
    private func isArchived(_ item: ShellMenuItem) -> Bool {
        item.isArchived ?? false
    }
    
    private func modifierPriceLabel(_ value: Double) -> String {
        guard value != 0 else { return "" }

        let absValue = abs(value)
        let formatted: String = absValue.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(absValue))
            : String(format: "%.2f", absValue)

        return value > 0 ? "+\(formatted)" : "-\(formatted)"
    }
    
    private func moveProductToCategory(productId: Int, newCategory: String) {
        let cleanNew = normalizeCategory(newCategory)
        guard !cleanNew.isEmpty else { return }

        guard let idx = api.items.firstIndex(where: { $0.id == productId }) else { return }

        let item = api.items[idx]
        let oldCategory = normalizeCategory(item.category)
        guard oldCategory != cleanNew else { return }

        // ✅ local update first
        api.items[idx] = ShellMenuItem(
            id: item.id,
            name: item.name,
            price: item.price,
            category: cleanNew,
            modifiers: item.modifiers,
            imageURL: item.imageURL,
            description: item.description,
            status: item.status,
            stockQuantity: item.stockQuantity,
            printer: item.printer,
            printers: item.printers
        )

        // ✅ if currently filtered by old category, jump to new one
        selectedCategory = cleanNew

        // optional: keep category order persisted
        if !categoryOrder.contains(cleanNew) {
            categoryOrder.append(cleanNew)
            persistCategoryOrder()
        }

        saveProductCategoryToServer(productId: productId, newCategory: cleanNew)
    }

    private func renameCategoryOnServer(oldName: String, newName: String) {
        let miniAppId = resolvedMiniAppId
        guard miniAppId > 0 else {
            print("❌ categories/rename: missing miniAppId")
            return
        }

        let cleanOld = normalizeCategory(oldName)
        let cleanNew = normalizeCategory(newName)

        guard !cleanOld.isEmpty, !cleanNew.isEmpty, cleanOld != cleanNew else { return }

        guard let url = URL(string: "https://minis.studio/api/categories/rename") else {
            print("❌ categories/rename: bad URL")
            return
        }

        let body: [String: Any] = [
            "miniAppId": miniAppId,
            "oldName": cleanOld,
            "newName": cleanNew
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else {
            print("❌ categories/rename: encode failed")
            return
        }

        print("""
        🌀 CATEGORY RENAME cURL:
        curl -X POST "https://minis.studio/api/categories/rename" \
          -H "Content-Type: application/json" \
          -d '\(String(data: jsonData, encoding: .utf8) ?? "{}")'
        """)

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = jsonData

        Task {
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                let text = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
                print("🌍 categories/rename HTTP \(code)")
                print("📦 categories/rename RESPONSE:", text)

                await MainActor.run {
                    safeReloadMenu(reason: "rename category")
                }
            } catch {
                print("❌ categories/rename network error:", error.localizedDescription)
            }
        }
    }
    
    private func applyLocalCategoryRename(oldName: String, newName: String) {
        let oldClean = normalizeCategory(oldName)
        let newClean = normalizeCategory(newName)

        guard !oldClean.isEmpty, !newClean.isEmpty, oldClean != newClean else { return }

        // update products locally
        for i in api.items.indices {
            let item = api.items[i]

            if normalizeCategory(item.category) == oldClean {
                api.items[i] = ShellMenuItem(
                    id: item.id,
                    name: item.name,
                    price: item.price,
                    category: newClean,              // 👈 changed
                    modifiers: item.modifiers,
                    imageURL: item.imageURL,
                    description: item.description,
                    status: item.status,
                    stockQuantity: item.stockQuantity,
                    printer: item.printer,
                    printers: item.printers
                )
            }
        }

        // update categoryOrder locally
        categoryOrder = categoryOrder.map { cat in
            normalizeCategory(cat) == oldClean ? newClean : cat
        }
        categoryOrder = uniqueNormalized(categoryOrder)

        // keep selection on renamed category
        if normalizeCategory(selectedCategory) == oldClean {
            selectedCategory = newClean
        }

        persistCategoryOrder()
    }
    private func normalizeCategory(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\u{00A0}", with: " ")   // non-breaking spaces
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func archiveProduct(productId: Int, mode: String) {
        let miniId =
            UserDefaults.standard.integer(forKey: "miniAppId") > 0
            ? UserDefaults.standard.integer(forKey: "miniAppId")
            : (Int(UserDefaults.standard.string(forKey: "shopId") ?? "0") ?? 0)

        guard miniId > 0 else {
            print("❌ archiveProduct: missing miniAppId/shopId")
            return
        }

        if mode == "archive" || mode == "remove" {
            if let idx = api.items.firstIndex(where: { $0.id == productId }) {
                api.items.remove(at: idx)
            }
        }

        let base = UserDefaults.standard.string(forKey: "apiBase") ?? "https://minis.studio"
        guard let url = URL(string: "\(base)/api/products/\(productId)/archive") else { return }

        let debugCurl = """
        curl -X POST "\(base)/api/products/\(productId)/archive" \\
          -H "Content-Type: application/json" \\
          -d '{ "miniAppId": \(miniId), "mode": "\(mode)" }'
        """
        print("🔎 Product action DEBUG CURL:\n\(debugCurl)")

        struct ArchiveBody: Encodable {
            let miniAppId: Int
            let mode: String
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(
            ArchiveBody(miniAppId: miniId, mode: mode)
        )

        Task {
            do {
                let (_, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                print("📦 product \(productId) mode=\(mode) miniAppId=\(miniId) → HTTP \(code)")

                await MainActor.run {
                    safeReloadMenu(reason: "product \(mode)")
                }
            } catch {
                print("❌ product \(mode) error:", error.localizedDescription)
            }
        }
    }
    
    private func displayCategory(for item: ShellMenuItem) -> String {
        if isArchived(item) { return archiveCategoryTitle }
        return item.category
    }
    @GestureState private var productDragAxis: DragAxis = .none
    @AppStorage(AppSettings.Key.cashPointMode) private var cashPointMode: Bool = true
    @State private var zRestoreDate: Date = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
    @StateObject private var net = NetworkMonitor.shared
    @State private var printInFlight = false
    private var isTeamTabMode: Bool { activeTeamTab != nil }
    @State private var pendingFinishAfterSubmit: Bool = false
    @State private var showClearStockConfirm = false
    @State private var isCategoryReorderMode: Bool = false
    @Environment(\.dismiss) private var dismiss
    @State private var frozenOrderIds: [Int] = []
    @State private var showLogsViewer = false
    @Environment(\.presentationMode) private var presentationMode
    private let NO_TERMINAL_PINPAD = "111111"
    @StateObject private var stockToggles = StockToggleStore(
        shopId: 12   // 👈 hard-coded miniAppId
    )
    
    @MainActor
    private func makeDuplicateDraft(from item: ShellMenuItem) -> AdminProductDraft {
        var d = makeAdminDraft(from: item)   // ✅ includes modifierGroups already

        // ✅ New product (so server creates a new id)
        d.productId = nil

        // ✅ Nice default name
        let baseName = d.name.trimmingCharacters(in: .whitespacesAndNewlines)
        d.name = baseName + " (העתק)"

        // (Optional) if you prefer not to duplicate image, uncomment:
        // d.imageURL = ""

        return d
    }
    
    private func freezeKey(productId: Int, groupTitle: String, optionName: String) -> String {
        "\(productId)|\(groupTitle)|\(optionName)"
    }

    private func isLocallyFrozen(productId: Int, groupTitle: String, optionName: String) -> Bool {
        localFrozenOverrides[freezeKey(productId: productId, groupTitle: groupTitle, optionName: optionName)] == true
    }
    enum ModifierStatusAPI {
        private static func resolvedMiniAppId() -> Int {
            let d = UserDefaults.standard
            let m = d.integer(forKey: "miniAppId")
            if m > 0 { return m }
            if let s = d.string(forKey: "shopId"), let v = Int(s), v > 0 { return v }
            return 0
        }

        static func setItemStatus(
            productId: Int,
            groupId: String,
            title: String,
            optionName: String,
            enabled: Bool
        ) async -> Bool {
            let miniAppId = resolvedMiniAppId()
            guard miniAppId > 0 else { return false }

            let base = UserDefaults.standard.string(forKey: "apiBase") ?? "https://minis.studio"
            guard let url = URL(string: "\(base)/api/products/\(productId)/modifier-item/status") else { return false }

            var req = URLRequest(url: url, timeoutInterval: 20)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("no-store", forHTTPHeaderField: "Cache-Control")

            let body: [String: Any] = [
                "miniAppId": miniAppId,
                "groupId": groupId,      // may be fake, ok
                "title": title,          // ✅ IMPORTANT fallback
                "optionName": optionName,
                "enabled": enabled
            ]
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)

            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                let txt = String(data: data, encoding: .utf8) ?? ""
                print("🧊 modifier/status HTTP \(code): \(txt.prefix(240))")
                return (200...299).contains(code)
            } catch {
                print("❌ modifier/status error:", error.localizedDescription)
                return false
            }
        }
    }
    
    private enum PinpadStore {
        static func key(miniAppId: Int) -> String { "pinpadId.\(miniAppId)" }

        static func load(miniAppId: Int) -> String {
            let raw = UserDefaults.standard.string(forKey: key(miniAppId: miniAppId)) ?? ""
            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        static func save(_ value: String, miniAppId: Int) {
            UserDefaults.standard.set(value, forKey: key(miniAppId: miniAppId))
        }
    }
    
    private func debugPinpad(_ tag: String) {
        let mid = resolvedMiniAppId
        let stored = PinpadStore.load(miniAppId: mid)
        let legacy = UserDefaults.standard.string(forKey: "pinpadId") ?? "nil"
        print("💳[\(tag)] mid=\(mid) state=\(pinpadId) stored=\(stored) legacy=\(legacy)")
        
        
    }
    
    private func migratePickupLocationOnce() {
        let d = UserDefaults.standard

        // if v2 already set, done
        let existing = (d.string(forKey: "pickup.location.v2") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !existing.isEmpty { return }

        // read old keys (whatever existed historically)
        let old =
            d.string(forKey: "pickup.location")
            ?? d.string(forKey: "admin.pickupLocation")
            ?? ""

        let migrated = canonPickup(old).rawValue
        d.set(migrated, forKey: "pickup.location.v2")

        // optional: kill old keys so nothing else reads them
        d.removeObject(forKey: "pickup.location")
        d.removeObject(forKey: "admin.pickupLocation")

        // keep @AppStorage var in sync immediately
        pickupLocationV2 = migrated

        print("📍 pickup migration old='\(old)' -> v2='\(migrated)'")
    }
    // ✅ TEMP (v1): local role gate (later replace with server-loaded grant role)
    @AppStorage("admin.role") private var adminRole: String = "cashier"   // cashier/admin/grandManager/owner
    private func canonPickup(_ raw: String) -> AdminPickupLocation {
        let s = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber } // ✅ keep Hebrew letters too

        switch s {

        // ✅ HUMANITIES
        case "humanities", "humanity", "humanitiesbuilding", "cafeteria",
             "מדעיהרוח", "רוח", "קפיטריה", "קפטריה":
            return .humanities

        // ✅ SOCIAL / SCIENCE
        case "social", "sciencebuilding", "science", "socialbuilding",
             "מדעיהחברה", "חברה":
            return .social

        default:
            // if already canonical, keep
            if s == AdminPickupLocation.humanities.rawValue { return .humanities }
            if s == AdminPickupLocation.social.rawValue     { return .social }

            // unknown -> do NOT guess wildly; default to humanities
            return .humanities
        }
    }
    
    private var isOwner: Bool { adminRole == "owner" }
    private var isGrandManager: Bool { adminRole == "grandManager" }

    // ✅ Who can manage admins/devices
    private var canManageAdmins: Bool { isOwner || isGrandManager }

    // ✅ Optional: can revoke (if you want grand manager to be able to add but NOT revoke)
    private var canRevokeAdmins: Bool { isOwner } // keep strict
    
    @State private var showAdminsDevices = false
    
    @MainActor
    private func backToCashpointFromTeamTab() {
        // close side menu first (nice UX)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            showSideMenu = false
        }

        // close any overlays/sheets related to ordering
        showBasketSheetPhone = false
        showOrderFlow = false

        // start a clean order (this already sets activeTeamTab=nil etc)
        startNewOrderFromPayLater()

        Haptics.success()
    }
    
    private var isAnyStockEditing: Bool {
        isStockEditMode || editingStockProductId != nil
    }
    @State private var stockCommitInFlight = false
    @State private var stockCommitError: String? = nil
    @State private var mobileIsOpen: Bool = true           // current server value
    @State private var mobileToggleBusy: Bool = false
    @State private var confirmCloseMobile = false
    @Environment(\.colorScheme) private var colorScheme
    @State private var priceText: String = "0"
    @State private var isNegative: Bool = false

    private func clearSavedContactAndService() {
        posSavedName = ""
        posSavedPhone = ""
       
    }
    
    @MainActor
    private func applyLocalAvailabilityFromStock(productId: Int) {
        let qty = stockAdjustments[productId]   // Int?  nil = ∞
        let on = (qty == nil) ? true : ((qty ?? 0) > 0)
        stockToggles.setLocalOn(productId, on)
    }
    
    var signedValue: Double {
        let v = Double(priceText.replacingOccurrences(of: ",", with: ".")) ?? 0
        return isNegative ? -v : v
    }
    @State private var pricePulseLineId: Int? = nil
    @State private var pricePulseScale: CGFloat = 1.0
    @AppStorage("pickup.location.v2") private var pickupLocationV2: String = AdminPickupLocation.humanities.rawValue
    
    @MainActor
    private func cleanupLineStateForCurrentBasket() {
        let live = Set(basket.keys)

        noteDrafts = noteDrafts.filter { live.contains($0.key) }
        optionSelections = optionSelections.filter { live.contains($0.key) }
        additionSelections = additionSelections.filter { live.contains($0.key) }
        basketSwipeOffsets = basketSwipeOffsets.filter { live.contains($0.key) }
        lineSessionTime = lineSessionTime.filter { live.contains($0.key) }

        lockedLineIds = lockedLineIds.intersection(live)

        if let e = expandedBasketLineId, !live.contains(e) { expandedBasketLineId = nil }
        if let p = pricePulseLineId, !live.contains(p) { pricePulseLineId = nil }
    }
    
    @MainActor
    private func applyOrderToLocalStock(entries: [BasketEntry]) {
        // sum qty per product
        var qtyByProduct: [Int: Int] = [:]
        for e in entries {
            qtyByProduct[e.item.id, default: 0] += e.quantity
        }

        for (pid, usedQty) in qtyByProduct {
            guard let current = stockAdjustments[pid] else { continue } // nil = ∞ / not tracked
            stockAdjustments[pid] = max(0, current - usedQty)
        }
    }
    
    @MainActor
    private func pulsePrice(for lineId: Int) {
        pricePulseLineId = lineId
        pricePulseScale = 1.0

        withAnimation(.easeOut(duration: 0.10)) { pricePulseScale = 1.06 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
            withAnimation(.easeOut(duration: 0.10)) { pricePulseScale = 1.0 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            if pricePulseLineId == lineId { pricePulseLineId = nil }
        }
    }
    
    enum AdminPickupLocation: String, CaseIterable, Identifiable {
        case humanities = "humanities"
        case social     = "social"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .humanities: return "מדעי הרוח"
            case .social:     return "מדעי החברה"
            }
        }
    }
    
    private var isMiniApp13: Bool { resolvedMiniAppId == 13 }

    private var selectedAdminLocation: AdminPickupLocation {
        canonPickup(pickupLocationV2)
    }

    private func setMiniAppOpen(_ open: Bool) {
        guard !mobileToggleBusy else { return }

        let id = resolvedMiniAppId
        guard id > 0 else { return }

        mobileToggleBusy = true
        let base = UserDefaults.standard.string(forKey: "apiBase") ?? "https://minis.studio"
        let url = URL(string: "\(base)/api/admin/miniapps/open?miniAppId=\(id)&isOpen=\(open)")!

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("no-store", forHTTPHeaderField: "Cache-Control")

        Task {
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                let text = String(data: data, encoding: .utf8) ?? ""

                await MainActor.run {
                    mobileToggleBusy = false
                    if (200...299).contains(code) {
                        mobileIsOpen = open
                        Haptics.success()
                        print("✅ miniApp IsOpen updated:", text)
                        // optional: refresh cached menu json
                        safeReloadMenu(reason: "toggle isOpen")
                    } else {
                        Haptics.error()
                        print("❌ miniApp open toggle failed HTTP \(code):", text)
                    }
                }
            } catch {
                await MainActor.run {
                    mobileToggleBusy = false
                    Haptics.error()
                    print("❌ miniApp open toggle network error:", error.localizedDescription)
                }
            }
        }
    }
    
    // MARK: - Single product stock edit (2s idle -> commit + close)

    private func startSingleStockEdit(productId: Int) {
        if let prev = editingStockProductId, prev != productId {
            Task { await commitSingleStockAndClose(prev) }
        }

        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            isStockEditMode = false
            editingStockProductId = productId
        }

        if stockText[productId] == nil {
            if let v = stockAdjustments[productId] {
                stockText[productId] = "\(max(v, 0))"
            } else {
                stockText[productId] = ""
            }
        }

        restartSingleStockEditTimer(productId: productId)
        Haptics.light()
    }

    private func restartSingleStockEditTimer(productId: Int) {
        stockEditWorkItem?.cancel()

        let work = DispatchWorkItem { [productId] in
            Task { await commitSingleStockAndClose(productId) }
        }

        stockEditWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: work)  // ✅ 2 seconds
    }

    @MainActor
    private func commitSingleStockAndClose(_ productId: Int) async {
        // if user already switched away, still commit that product and close the editor
        // but avoid double-commit storms
        if stockCommitInFlight { return }

        stockCommitInFlight = true
        stockCommitError = nil

        // take current value (nil = ∞ / untracked)
        let qty = stockAdjustments[productId]

        let ok = await StockQuantityAPI.setStock(productId: productId, quantity: qty)

        stockCommitInFlight = false

        if ok {
            applyLocalAvailabilityFromStock(productId: productId)

            dirtyStockIds.remove(productId)
            stockText[productId] = nil

            // close editor UI
            focusedStockProductId = nil
            if editingStockProductId == productId {
                editingStockProductId = nil
            }

            // refresh canonical menu state (optional but matches your global flow)
            safeReloadMenu(reason: "toggle isOpen")
            Haptics.success()
        } else {
            stockCommitError = "שמירת מלאי נכשלה"
            Haptics.error()
            // keep editor open so user can retry / keep changing
        }
    }
    // ✅ NOTE routing helper (station IDs)
    private func makeNoteItem(id: Int, name: String, stationId: String, legacy: String) -> ShellMenuItem {
        ShellMenuItem(
            id: id,
            name: name,
            price: 0,
            category: "✏️ הערות",
            modifiers: nil,
            imageURL: nil,
            description: nil,
            status: 1,
            stockQuantity: nil,

            // ✅ NEW routing (station id)
            printer: stationId,                 // primary printer id
            printers: [stationId],              // explicit list (PrinterIds)

            // ✅ Optional: keep legacy in description if you ever need it for debugging
            // description: legacy
                              // (only if your model has this field; otherwise remove)
        )
    }
    private func applyFrozenOrder(_ items: [ShellMenuItem]) -> [ShellMenuItem] {
        guard !frozenOrderIds.isEmpty else { return items }

        let map = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })

        var out: [ShellMenuItem] = []
        out.reserveCapacity(items.count)

        // keep frozen order first
        for id in frozenOrderIds {
            if let it = map[id] { out.append(it) }
        }

        // append anything new that wasn't in snapshot
        let used = Set(out.map(\.id))
        for it in items where !used.contains(it.id) {
            out.append(it)
        }

        return out
    }
    
    private func isCategoryZeroed(_ category: String) -> Bool {
        let items = api.items.filter { $0.category == category }
        guard !items.isEmpty else { return false }

        return items.allSatisfy { item in
            stockAdjustments[item.id] == 0
        }
    }
    
    private func flushDirtyStockAndExit() async {
        print("✅ flushDirtyStockAndExit() ENTER dirty=\(dirtyStockIds.sorted()) inFlight=\(stockCommitInFlight)")

        guard !stockCommitInFlight else {
            print("⛔️ flush EXIT: inFlight already true")
            return
        }

        guard !dirtyStockIds.isEmpty else {
            print("⛔️ flush EXIT: no dirty ids")
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                isStockEditMode = false
            }
            return
        }

        stockCommitInFlight = true
        stockCommitError = nil

        // close inline editor focus
        focusedStockProductId = nil
        editingStockProductId = nil
        stockEditWorkItem?.cancel()
        stockEditWorkItem = nil

        // snapshot ids so UI edits won't race the loop
        let ids = Array(dirtyStockIds)

        var failed: Set<Int> = []

        for pid in ids {
            
            let ok = await StockQuantityAPI.setStock(productId: pid, quantity: stockAdjustments[pid])
            if !ok { failed.insert(pid) }
        }

        dirtyStockIds = failed
        stockCommitInFlight = false

        if failed.isEmpty {
            // clear typed cache if you want
            for pid in ids { stockText[pid] = nil }

            // ✅ refresh canonical JSON immediately after successful writes
            safeReloadMenu(reason: "toggle isOpen")

            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                isStockEditMode = false
            }
        } else {
            stockCommitError = "לא כל המלאי נשמר. נסה שוב."
            Haptics.error()
            // stay in stock mode so user can hit Done again
        }
    }
    
    private func goBack() {
        // If menu is open, close it first (feels natural)
        if showSideMenu {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                showSideMenu = false
            }
            return
        }

        // If we're inside a NavigationStack push, pop
        if presentationMode.wrappedValue.isPresented {
            presentationMode.wrappedValue.dismiss()
            return
        }

        // Otherwise, if it's a modal (sheet / fullScreenCover), dismiss
        dismiss()
    }
    
    @ObservedObject private var printerStore = PrintersConfigStore.shared

    private func defaultPrinterId() -> String {
        printerStore.config.stations.first(where: { $0.status != 0 })?.id ?? ""
    }
    
    
    private var isPhoneDevice: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }
    
    private func norm(_ s: String?) -> String {
        (s ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{00A0}", with: " ") // non-breaking space
            .replacingOccurrences(of: "  ", with: " ")
    }
    
    
    @State private var showZReportDialog = false

    private func zReportGenerate() {
        // הפק דוח  ✅
        showEODWizard = true
    }

    private func zReportRestore() {
        zRestoreMode = true
        zRestoreDate = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()

        reportData = nil              // ✅ IMPORTANT
        activeReportType = .z
    }
    
    @State private var didConfirmNameThisSession: Bool = false
    @State private var showSideMenu = false
    @State private var activeReportType: ReportType? = nil
    @State private var reportData: PrinterManager.SalesReportData? = nil
    @State private var showBones = false
    @State private var showBonbon = false
 
    @State private var showPrintSuccess = false
    @State private var stockText: [Int: String] = [:]   // productId -> "typed value"
    @State private var printSuccessScale: CGFloat = 0.6
    @State private var printSuccessOpacity: Double = 0
    @State private var unpaidOrderId: Int? = nil
    @State private var hasPrintedFromSwipe: Bool = false   // already sent to kitchen?
    @State private var pendingTicketNumber: Int? = nil     // ticket used by swipe + completeOrder
    @State private var reportPreviewText: String = ""
    @State private var showNewCustomerConfirm = false
    @State private var categoryOrder: [String] = []
    @State private var draggingCategory: String? = nil
    @State private var showEODWizard = false
    @State private var showRefundFlow = false
    @State private var refundInput: String = ""
    @State private var showStudentHandshakeSheet = false
    private struct ReorderCategoriesReq: Encodable {
        let miniAppId: Int
        let order: [String]
    }

    @State private var showOutboxLog = false
    @State private var pinpadsExpanded: Bool = false

    private var pinpads: [(title: String, id: String)] {
        switch resolvedMiniAppId {

        case 12:
            return [
                ("קופה 1", "48796294"),
                ("קופה 2", "48796855"),
                ("קיוסק 1", "48796856"),
                ("קיוסק 2", "48799267")
            ]

        case 13:
            return [
                ("חברה קופה", "48799364")
            ]

        default:
            return [
                ("קופה", "48796294")
            ]
        }
    }
    
    

    private var currentPinpadId: String { pinpadId }

    private func setPinpadAndPing(_ id: String) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let mid = resolvedMiniAppId

        if trimmed == NO_TERMINAL_PINPAD {
            pinpadId = NO_TERMINAL_PINPAD
            PinpadStore.save(NO_TERMINAL_PINPAD, miniAppId: mid)

            // ✅ LEGACY MIRROR (so current payment code sees it)
            UserDefaults.standard.set(NO_TERMINAL_PINPAD, forKey: "pinpadId")

            ZCreditPaymentHandler.shared.cancelCurrent()
            Haptics.success()
            print("✅ pinpad disabled mid=\(mid) id=\(NO_TERMINAL_PINPAD)")
            return
        }

        guard !trimmed.isEmpty else {
            pinpadId = NO_TERMINAL_PINPAD
            PinpadStore.save(NO_TERMINAL_PINPAD, miniAppId: mid)

            // ✅ LEGACY MIRROR
            UserDefaults.standard.set(NO_TERMINAL_PINPAD, forKey: "pinpadId")

            ZCreditPaymentHandler.shared.cancelCurrent()
            Haptics.success()
            return
        }

        pinpadId = trimmed
        PinpadStore.save(trimmed, miniAppId: mid)

        // ✅ LEGACY MIRROR
        UserDefaults.standard.set(trimmed, forKey: "pinpadId")

        Haptics.light()

        // ping
        ZCreditPaymentHandler.shared.pay(amount: 1.0, orderId: nil) { _ in }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            ZCreditPaymentHandler.shared.cancelCurrent()
        }
    }
    
    @State private var showPrinterStatusSheet = false

    @StateObject private var printerMonitor = PrinterReachabilityMonitor(printers: [
        .init(name: "Kitchen", host: "10.100.10.232", port: 9100),
        .init(name: "Bar",     host: "10.100.10.234", port: 9100),
        .init(name: "Bakery",  host: "10.100.10.230", port: 9100),
    ])
    
    // MARK: - Print backlog HUD (OneShotPrinter queue)
    @State private var pendingKitchen: Int = 0
    @State private var pendingBar: Int = 0
    @State private var pendingBakery: Int = 0

    @State private var firstPendingAtKitchen: Date? = nil
    @State private var firstPendingAtBar: Date? = nil
    @State private var firstPendingAtBakery: Date? = nil

    @State private var backlogPoll = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    private var printerPort: UInt16 {
        let raw = UserDefaults.standard.integer(forKey: "kds.printer.port")
        let p = UInt16(exactly: raw) ?? 0
        return p == 0 ? 9100 : p
    }
    
    private func safeReloadMenu(reason: String) {
        if showOrderFlow { return }
        if !basket.isEmpty { return }
        if printInFlight { return }
        if isStockEditMode { return }
        if stockCommitInFlight { return }
        if !dirtyStockIds.isEmpty { return }
        api.load(skipCache: true)
    }

    private func updatePendingBacklog() {
        // Use the active IPs you already configured (Tabit set shown here)
        // If you want it to auto-follow PrinterManager.activePrinterSet, we can wire that next.
        let kitchenHost = "10.100.10.232"
        let barHost     = "10.100.10.234"
        let bakeryHost  = "10.100.10.230"

        let k = OneShotPrinter.pendingCount(host: kitchenHost, port: printerPort)
        let b = OneShotPrinter.pendingCount(host: barHost, port: printerPort)
        let v = OneShotPrinter.pendingCount(host: bakeryHost, port: printerPort)

        pendingKitchen = k
        pendingBar     = b
        pendingBakery  = v

        func updateStamp(count: Int, stamp: inout Date?) {
            if count > 0 {
                if stamp == nil { stamp = Date() }
            } else {
                stamp = nil
            }
        }

        updateStamp(count: k, stamp: &firstPendingAtKitchen)
        updateStamp(count: b, stamp: &firstPendingAtBar)
        updateStamp(count: v, stamp: &firstPendingAtBakery)
    }

    private func pendingAgeSeconds(_ d: Date?) -> Int? {
        guard let d else { return nil }
        return Int(Date().timeIntervalSince(d))
    }

    private var hasStuckBacklog: Bool {
        let threshold = 15
        return (pendingAgeSeconds(firstPendingAtKitchen) ?? 0) >= threshold ||
               (pendingAgeSeconds(firstPendingAtBar)     ?? 0) >= threshold ||
               (pendingAgeSeconds(firstPendingAtBakery)  ?? 0) >= threshold
    }
    
    @ViewBuilder
    private func printBacklogHUD() -> some View {
        let total = pendingKitchen + pendingBar + pendingBakery
        let onLan = printerMonitor.isNetworkUp

        // Visual style
        let bg: Color = {
            if !onLan { return Color(.systemGray5) }
            if hasStuckBacklog { return Color.red.opacity(0.14) }
            if total > 0 { return Color.black.opacity(0.06) }
            return Color.black.opacity(0.03)
        }()

        let title: String = {
            if !onLan { return "לא מחובר לרשת המדפסות" }
            if hasStuckBacklog { return "🛑 הדפסה תקועה" }
            if total > 0 { return "הדפסה בתור" }
            return "מדפסת תקינה"
        }()

        let icon: String = {
            if !onLan { return "wifi.slash" }
            if hasStuckBacklog { return "exclamationmark.triangle.fill" }
            if total > 0 { return "printer.fill" }
            return "checkmark.circle.fill"
        }()

        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .bold))

                Text(title)
                    .font(.system(size: 14, weight: .bold))

                Spacer()

                Button {
                    updatePendingBacklog()
                    Haptics.light()
                } label: {
                    Text("רענן")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(.systemBackground))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 10) {
                backlogChip("מטבח", pendingKitchen, pendingAgeSeconds(firstPendingAtKitchen), stuck: hasStuckBacklog)
                backlogChip("בר",   pendingBar,     pendingAgeSeconds(firstPendingAtBar),     stuck: hasStuckBacklog)
                backlogChip("מאפה", pendingBakery,  pendingAgeSeconds(firstPendingAtBakery),  stuck: hasStuckBacklog)
                Spacer()
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(bg))
    }
    
    @ViewBuilder
    private func backlogChip(_ title: String, _ count: Int, _ ageSec: Int?, stuck: Bool) -> some View {
        let show = count > 0
        if show {
            let ageText = ageSec.map { "\($0)s" } ?? "…"
            Text("\(title) \(count)  \(ageText)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(stuck ? .red : .primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(.systemBackground))
                .clipShape(Capsule())
        }
    }
    
    private func cleanModifierSubtitle(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }

        return raw
            .split(separator: ",")
            .map { part in
                let s = part.trimmingCharacters(in: .whitespaces)
                if let idx = s.firstIndex(of: ":") {
                    return String(s[s.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
                }
                return s
            }
            .joined(separator: ", ")
    }
    private func sendCategoryOrderToServer() {
        let miniAppId = Int(UserDefaults.standard.string(forKey: "shopId") ?? "12") ?? 12
        guard miniAppId > 0 else {
            print("❌ categories/reorder: missing shopId")
            return
        }

        // Never send notes in order (server can add it if needed)
        let cleanOrder = uniqueNormalized(categoryOrder).filter {
            $0 != "✏️ הערות" && $0 != archiveCategoryTitle
        }
        let payload = ReorderCategoriesReq(miniAppId: miniAppId, order: cleanOrder)

        guard let url = URL(string: "https://minis.studio/api/categories/reorder") else {
            print("❌ categories/reorder: bad URL")
            return
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]

        guard let body = try? encoder.encode(payload) else {
            print("❌ categories/reorder: encode failed")
            return
        }

        // Debug cURL
        let jsonString = String(data: body, encoding: .utf8) ?? "{}"
        print("""
        🌀 CATEGORY REORDER cURL:
        curl -X POST "https://minis.studio/api/categories/reorder" \
          -H "Content-Type: application/json" \
          -d '\(jsonString)'
        """)

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        Task {
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                let text = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
                print("🌍 categories/reorder HTTP \(code)")
                print("📦 categories/reorder RESPONSE:", text)
            } catch {
                print("❌ categories/reorder network error:", error.localizedDescription)
            }
        }
    }
    private var categoryOrderKey: String {
        "cash.categoryOrder.shop\(resolvedMiniAppId)"
    }
    
    private func uniqueNormalized(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for raw in values {
            let v = normalizeCategory(raw)
            guard !v.isEmpty else { continue }
            guard seen.insert(v).inserted else { continue }
            result.append(v)
        }

        return result
    }

    private func currentMenuCategoriesInAppearanceOrder() -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for item in api.items {
            let cat = normalizeCategory(displayCategory(for: item))
            guard !cat.isEmpty else { continue }
            guard seen.insert(cat).inserted else { continue }
            result.append(cat)
        }

        return result
    }
    
    private func mergedCategoryOrder(
        saved: [String],
        server: [String],
        menu: [String]
    ) -> [String] {
        let notes = "✏️ הערות"
        let archive = archiveCategoryTitle

        let menuClean = uniqueNormalized(menu)
        let menuSet = Set(menuClean)

        let serverClean = uniqueNormalized(
            server.filter { normalizeCategory($0) != notes && normalizeCategory($0) != archive }
        )

        let savedClean = uniqueNormalized(
            saved.filter { normalizeCategory($0) != notes && normalizeCategory($0) != archive }
        )

        // prefer server order if it exists, otherwise saved local order
        let preferredBase = !serverClean.isEmpty ? serverClean : savedClean

        var merged: [String] = []

        // keep only categories that still exist in real menu
        for cat in preferredBase {
            if menuSet.contains(cat), !merged.contains(cat) {
                merged.append(cat)
            }
        }

        // append newly discovered real categories at the end
        for cat in menuClean where cat != notes && cat != archive {
            if !merged.contains(cat) {
                merged.append(cat)
            }
        }

        // ✅ notes is always hardcoded and should always exist
        if !merged.contains(notes) {
            merged.append(notes)
        }

        // ✅ archive only if there are archived items
        if menuSet.contains(archive), !merged.contains(archive) {
            merged.append(archive)
        }

        return merged
    }
    
    
    private func loadCategoryOrderFromStorageOrMenu() {
        let notes = "✏️ הערות"
        let archive = archiveCategoryTitle

        let menuCats = Array(Set(api.items.map { displayCategory(for: $0) }))

        let server = api.categoryOrder
            .filter { $0 != notes && $0 != archive }

        let saved = (UserDefaults.standard.array(forKey: categoryOrderKey) as? [String]) ?? []

        // ✅ prefer saved first, then server, because local drag is current truth
        let base = !saved.isEmpty ? saved : server

        var merged: [String] = []

        for c in base {
            if menuCats.contains(c), !merged.contains(c), c != notes, c != archive {
                merged.append(c)
            }
        }

        // append newly discovered real categories
        for c in menuCats where c != notes && c != archive {
            if !merged.contains(c) {
                merged.append(c)
            }
        }

        // hardcoded notes
        merged.append(notes)

        // archive only if exists
        if menuCats.contains(archive) {
            merged.append(archive)
        }

        categoryOrder = merged
        UserDefaults.standard.set(merged, forKey: categoryOrderKey)

        print("🟣 menuCats =", menuCats)
        print("🟣 categoryOrder =", categoryOrder)
    }
    
    private func persistCategoryOrder() {
        let notes = "✏️ הערות"
        let archive = archiveCategoryTitle

        var clean = categoryOrder

        // keep one notes only, always near bottom
        clean.removeAll { $0 == notes }
        clean.append(notes)

        // keep archive one only, always last if exists
        clean.removeAll { $0 == archive }
        if categories.contains(archive) {
            clean.append(archive)
        }

        categoryOrder = clean
        UserDefaults.standard.set(clean, forKey: categoryOrderKey)
    }
    
    private func buildSalesReportData(for type: ReportType) -> PrinterManager.SalesReportData {
        return emptySalesReportData()
    }
    
    
    enum ReportType: Identifiable {
        case x
        case z

        var id: String {
            switch self {
            case .x: return "x"
            case .z: return "z"
            }
        }

        var title: String {
            switch self {
            case .x: return "דוח X"
            case .z: return "דוח Z"
            }
        }
    }
    @State private var showOrdersAdmin = false
    @State private var adminMode: AdminOrdersView.AdminMode = .normal
    @State private var lockedLineIds: Set<Int> = []          // lines restored from unpaid orders
    @State private var lineSessionTime: [Int: Date] = [:]    // lineId -> updated time (from API)
    private let sectionTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "he_IL")
        f.dateFormat = "H:mm"        // e.g. 8:32
        return f
    }()
    private var hasAddedLinesInPayLater: Bool {
        isPayLaterMode && basket.values.contains { !lockedLineIds.contains($0.id) }
    }
    
    
    private func playPrintSuccess() {
        showPrintSuccess = true
        printSuccessScale = 0.6
        printSuccessOpacity = 0

        withAnimation(.spring(response: 0.5, dampingFraction: 0.7, blendDuration: 0.1)) {
            printSuccessScale = 1.0
            printSuccessOpacity = 1.0
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            withAnimation(.easeOut(duration: 0.25)) {
                printSuccessOpacity = 0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                showPrintSuccess = false
            }
        }
    }
    
    private func closeActiveTeamTab() {
        guard let oid = unpaidOrderId else { return }

        TeamTabsAPI.close(orderId: oid) { res in
            DispatchQueue.main.async {
                switch res {
                case .success:
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        activeTeamTab = nil
                        isPayLaterMode = false
                    }
                    unpaidOrderId = nil
                    lockedLineIds.removeAll()
                    lineSessionTime.removeAll()
                    basket.removeAll()
                 //   nextBasketLineId = 1
                    Haptics.success()
                case .failure(let err):
                    print("❌ close tab failed:", err)
                    Haptics.error()
                }
            }
        }
    }
    
    private func updateStockFromKeyboard(productId: Int, raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            stockAdjustments[productId] = nil   // ∞
        } else if let value = Int(trimmed), value >= 0 {
            stockAdjustments[productId] = value
        } else {
            let current = remainingStock(for: ShellMenuItem(id: productId, name: "", price: 0, category: "", modifiers: nil, imageURL: nil, description: nil))
            stockText[productId] = current.map { String($0) } ?? ""
            return
        }

        dirtyStockIds.insert(productId)

        // ✅ NEW: make it immediately orderable / sortable
        applyLocalAvailabilityFromStock(productId: productId)
    }
    
    private func printUpdatedUnpaidOrder() {
        
        guard let existingId = unpaidOrderId else {
              if isTeamTabMode {
                  Haptics.error()
                  print("⚠️ teamTab print: unpaidOrderId not ready yet")
                  return
              }

              // normal customer fallback (keep your old behaviour)
              if isPhoneLayout {
                  showBasketSheetPhone = false
                  DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: {
                      showOrderFlow = true
                      hasChosenServiceMode = false
                  })
              } else {
                  showOrderFlow = true
                  hasChosenServiceMode = false
              }
              return
          }

        // Snapshot current basket
        let previousLocked = lockedLineIds
        let entriesArray = Array(basket.values)

        // Only new lines: those NOT in previousLocked
        let newEntries = entriesArray.filter { !previousLocked.contains($0.id) }
        guard !newEntries.isEmpty else {
            // ✅ Nothing new → do nothing, don’t print twice
            Haptics.selection()
            print("ℹ️ print: no new lines to print")
            return
        }

        let total      = finalTotal
        let newTotal   = newEntries.reduce(0.0) { $0 + Double($1.quantity) * $1.unitPrice }
        let mode       = diningMode

        let nameSnapshot: String? = {
            // ✅ Team table → print table title
            if let tab = activeTeamTab {
                return tab.titleHe   // e.g. "שולחן מנהלים"
            }

            // Normal customer fallback
            let trimmed = posSavedName.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }()

        let phoneSnapshot: String? = {
            // 🚫 Team tables never have phone
            guard activeTeamTab == nil else { return nil }

            let trimmed = posSavedPhone.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }()
        // 🔹 1) OPTIMISTIC UI – mark as sent + show success NOW

        // Give this batch a session time
        let sessionStamp = Date()
        for e in newEntries {
            lineSessionTime[e.id] = sessionStamp
        }

        // All current lines are now “sent”
       

        // Green check overlay immediately
       // playPrintSuccess()
        print(phoneSnapshot)
        // (Optional) snapshot for confirmation / debugging
        lastOrder = CashOrderSnapshot(
            orderNumber: existingId,
            entries: entriesArray,
            totalPrice: total,
            diningMode: mode,
            customerName: nameSnapshot,
            customerPhone: phoneSnapshot
        )

        // 🔹 2) FIRE & FORGET: print + submit to server in the background

        // Print only the new lines
        Task {
            await MainActor.run { printInFlight = true }
            let ok = await PrinterManager.shared.printCashPointSplit(
                orderNumber: existingId,
                entries: newEntries,
                total: newTotal,
                diningMode: mode,
                customerName: nameSnapshot,
                customerPhone: phoneSnapshot
            )
            await MainActor.run { printInFlight = false }

            await MainActor.run {
                if ok {
                    lockedLineIds.formUnion(newEntries.map { $0.id })
                    // ✅ ALL stations printed / queued successfully
                    playPrintSuccess()
                } else {
                    // ❌ At least one station failed or expired
                    print("❌ printCashPointSplit failed for order \(existingId)")

                    Haptics.error()

                    // 👇 pick ONE (recommended: outbox so staff can see which printer is pending)
                    showOutboxLog = true
                    // OR
                    // showPrinterStatusSheet = true
                }
            }
        }
        OrderAPI.submitOrder(
            orderId: existingId,
            entries: entriesArray,   // full basket → DB has full order
            total: total,
            diningMode: mode,
            source: "cashpoint",
            customerName: nameSnapshot,
            customerPhone: phoneSnapshot,
            payment: nil,
            zcreditMeta: nil,

            // ✅ NEW (team tabs)
            orderType: activeTeamTab == nil ? nil : "teamTab",
            tabKey: activeTeamTab?.rawValue
        ) { result in
            clearSavedContactAndService()

            DispatchQueue.main.async {
                if case .failure(let err) = result {
                    // You can keep this minimal or add a small toast
                    print("❌ submitOrder unpaid update \(existingId) failed:", err)
                    Haptics.error()
                    // Optional: show a small banner saying “Sync failed, please check admin”
                }
            }
        }
    }
    @AppStorage("cashPayLaterMode") private var isPayLaterMode: Bool = false
    @AppStorage("posSavedName") private var posSavedName: String = ""
    @AppStorage("posSavedPhone") private var posSavedPhone: String = ""
    
    private func dismissKeyboard() {
        isSearchFocused = false
        #if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil,
                                        from: nil,
                                        for: nil)
        #endif
    }
    @State private var productSwipeOffsets: [Int: CGFloat] = [:]   // productId -> x offset
    @State private var basketSwipeOffsets: [Int: CGFloat] = [:]    // lineId   -> x offset  👈 NEW
   @State private var isBasketDropTarget: Bool = false
  
    @State private var expandedBasketLineId: Int? = nil
    @State private var noteDrafts: [Int: String] = [:]
    @State private var optionSelections: [Int: [String: String]] = [:]   // lineId -> [groupTitle: optionName]
    @State private var additionSelections: [Int: [String: [AdditionMode: Set<String>]]] = [:]
    @State private var additionOrder: [Int: [String]] = [:]
    @State private var additionGroupModes: [Int: [String: AdditionMode]] = [:]
    
    @State private var reportsExpanded: Bool = false
    @State private var teamTabsExpanded: Bool = false
    @State private var dirtyStockIds: Set<Int> = []
    @State private var tappedProductId: Int? = nil
    @State private var sheetEntry: BasketEntry?
    @State private var showMessageSheet = false
    @State private var messageText: String = ""
    @State private var messagePrice: String = ""
    @State private var messageTargetIsKitchen: Bool = false
    @State private var messageTargetIsBakery: Bool = false
    @State private var stockAdjustments: [Int: Int] = [:]   // productId -> amount (1–3)
    @State private var editingStockProductId: Int? = nil
    @State private var stockEditWorkItem: DispatchWorkItem? = nil
    @State private var isStockEditMode: Bool = false
    @State private var locationsExpanded: Bool = false
    
    private enum DiscountMode {
        case none, ten, fifteen,thirteen, custom
    }
    
    private func selectedAdditionSet(
        lineId: Int,
        groupTitle: String,
        mode: AdditionMode
    ) -> Set<String> {
        additionSelections[lineId]?[groupTitle]?[mode] ?? []
    }

    private func setAdditionSet(
        lineId: Int,
        groupTitle: String,
        mode: AdditionMode,
        value: Set<String>
    ) {
        var lineMap = additionSelections[lineId] ?? [:]
        var groupMap = lineMap[groupTitle] ?? [:]
        groupMap[mode] = value
        lineMap[groupTitle] = groupMap
        additionSelections[lineId] = lineMap
    }

    private func moveAdditionToCurrentMode(
        lineId: Int,
        groupTitle: String,
        itemName: String,
        targetMode: AdditionMode
    ) {
        var lineMap = additionSelections[lineId] ?? [:]
        var groupMap = lineMap[groupTitle] ?? [:]

        var withSet = groupMap[.with] ?? []
        var withoutSet = groupMap[.without] ?? []
        var sideSet = groupMap[.side] ?? []

        withSet.remove(itemName)
        withoutSet.remove(itemName)
        sideSet.remove(itemName)

        switch targetMode {
        case .with:
            withSet.insert(itemName)
        case .without:
            withoutSet.insert(itemName)
        case .side:
            sideSet.insert(itemName)
        }

        groupMap[.with] = withSet
        groupMap[.without] = withoutSet
        groupMap[.side] = sideSet
        lineMap[groupTitle] = groupMap
        additionSelections[lineId] = lineMap
    }

    private func removeAdditionFromAllModes(
        lineId: Int,
        groupTitle: String,
        itemName: String
    ) {
        var lineMap = additionSelections[lineId] ?? [:]
        var groupMap = lineMap[groupTitle] ?? [:]

        var withSet = groupMap[.with] ?? []
        var withoutSet = groupMap[.without] ?? []
        var sideSet = groupMap[.side] ?? []

        withSet.remove(itemName)
        withoutSet.remove(itemName)
        sideSet.remove(itemName)

        groupMap[.with] = withSet
        groupMap[.without] = withoutSet
        groupMap[.side] = sideSet
        lineMap[groupTitle] = groupMap
        additionSelections[lineId] = lineMap
    }
    
    private var mainActionButtonTitle: String {
        if isTeamTabMode {
            return "הדפס"
        }
        if isPayLaterMode && hasAddedLinesInPayLater { return isRtl ? "שלח הזמנה" : "Print order" }
        if isPayLaterMode { return isRtl ? "תשלום" : "Pay" }
        return isRtl ? "הזמנה" : "Order"
    }
    
    struct PillButtonLabel: View {
        let text: String

        var body: some View {
            Text(text)
                .font(.system(size: 14, weight: .semibold))
                .frame( minHeight: 28)
                .padding(.horizontal, 15)
                .background(
                    Capsule().fill(Color(.systemGray5))
                )
        }
    }
    @State private var productPoll = Timer.publish(every: 20, on: .main, in: .common).autoconnect()
    @State private var showDiscountPanel = false
    @State private var discountMode: DiscountMode = .none
    @State private var discountAllSelected = true
    @State private var discountedLineIds: Set<Int> = []
    @State private var customDiscountText: String = ""
    @State private var showExcludePanel = false
    @State private var customIsPercentage: Bool = false   // false = amount, true = %
    @State private var excludeAllSelected = false
    @State private var excludedLineIds: Set<Int> = []
    @State private var searchText: String = ""
    @FocusState private var isSearchFocused: Bool
    
    @Environment(\.horizontalSizeClass) private var hSizeClass
    // MARK: - Basket Panel (type-safe / avoids SwiftUI metadata crash)

    private struct BasketTopBar: View {
        let isTeamTabMode: Bool
        let isRtl: Bool
        let currency: String

        let basketIsEmpty: Bool
        let basketKeys: [Int]
        let basketTotalQuantity: Int
       
        @Binding var showDiscountPanel: Bool
        @Binding var showExcludePanel: Bool
        @Binding var discountMode: DiscountMode
        @Binding var discountAllSelected: Bool
        @Binding var discountedLineIds: Set<Int>
        @Binding var customDiscountText: String
        @Binding var customIsPercentage: Bool

        @Binding var excludeAllSelected: Bool
        @Binding var excludedLineIds: Set<Int>

        var body: some View {
            HStack {
                Text(isRtl ? "הזמנה" : "Order")
                    .font(.system(size: 20, weight: .bold))
                if !isTeamTabMode {
                    
                    HStack {
                        Button {
                            withAnimation {
                                if showDiscountPanel {
                                    showDiscountPanel   = false
                                    discountMode        = .none
                                    discountAllSelected = true
                                    discountedLineIds.removeAll()
                                    customDiscountText  = ""
                                    customIsPercentage  = false
                                } else if !basketIsEmpty {
                                    showDiscountPanel   = true
                                    showExcludePanel    = false
                                    discountMode        = .ten
                                    discountAllSelected = true
                                    discountedLineIds   = Set(basketKeys)
                                    customDiscountText  = ""
                                    customIsPercentage  = false
                                }
                            }
                        } label: {
                            PillButtonLabel(text: "הנחה")
                        }
                        .buttonStyle(.plain)
                        .disabled(basketIsEmpty)
                        
                        Button {
                            withAnimation {
                                if showExcludePanel {
                                    showExcludePanel    = false
                                    excludeAllSelected  = false
                                    excludedLineIds.removeAll()
                                } else if !basketIsEmpty {
                                    showExcludePanel    = true
                                    showDiscountPanel   = false
                                    excludeAllSelected  = false
                                    excludedLineIds.removeAll()
                                }
                            }
                        } label: {
                            PillButtonLabel(text: "OTH")
                        }
                        .buttonStyle(.plain)
                        .disabled(basketIsEmpty)
                    }
                    .padding(.leading, 10)
                }

                Spacer()

                if basketTotalQuantity > 0 {
                    Text(isRtl ? "\(basketTotalQuantity) פריטים" : "\(basketTotalQuantity) items")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
                }
            }
            .padding(16)
        }
    }

    private struct DiscountPanelView: View {
        let isRtl: Bool
        let currency: String
        let basketKeys: [Int]
        let basketEntriesSorted: [BasketEntry]

        @Binding var showDiscountPanel: Bool
        @Binding var showExcludePanel: Bool
        @Binding var discountMode: DiscountMode
        @Binding var discountAllSelected: Bool
        @Binding var discountedLineIds: Set<Int>
        @Binding var customDiscountText: String
        @Binding var customIsPercentage: Bool

        let discountPill: (_ title: String, _ mode: DiscountMode) -> AnyView

        var body: some View {
            VStack(spacing: 8) {

                HStack(spacing: 8) {
                    Button {
                        withAnimation {
                            showDiscountPanel   = false
                            discountMode        = .none
                            discountAllSelected = true
                            discountedLineIds.removeAll()
                            customDiscountText  = ""
                        }
                    } label: {
                        Text(isRtl ? "בטל" : "Cancel")
                            .font(.system(size: 14, weight: .semibold))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    discountPill("10%", .ten)
                    discountPill("15%", .fifteen)
                    discountPill("30%", .thirteen)
                    discountPill(isRtl ? "אחר" : "Other", .custom)

                    Spacer()
                }

                if discountMode == .custom {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(isRtl ? "סכום הנחה" : "Discount")
                                .font(.system(size: 14))

                            TextField("0", text: $customDiscountText)
                                .keyboardType(.decimalPad)
                                .padding(6)
                                .background(Color(.secondarySystemBackground))
                                .cornerRadius(8)
                        }

                        HStack(spacing: 8) {
                            Text(isRtl ? "סוג הנחה" : "Type")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)

                            HStack(spacing: 8) {
                                Button { customIsPercentage = false } label: {
                                    Text(isRtl ? "סכום" : "Amount")
                                        .font(.system(size: 13, weight: .semibold))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .background(customIsPercentage ? Color(.systemGray6) : .black)
                                        .foregroundColor(customIsPercentage ? .primary : .white)
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)

                                Button { customIsPercentage = true } label: {
                                    Text("%")
                                        .font(.system(size: 13, weight: .semibold))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .background(customIsPercentage ? .black : Color(.systemGray6))
                                        .foregroundColor(customIsPercentage ? .white : .primary)
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                Divider().padding(.vertical, 4)

                Button {
                    discountAllSelected.toggle()
                    if discountAllSelected {
                        discountedLineIds = Set(basketKeys)
                    } else {
                        discountedLineIds.removeAll()
                    }
                } label: {
                    HStack {
                        Image(systemName: discountAllSelected ? "checkmark.square.fill" : "square")
                            .foregroundColor(discountAllSelected ? .primary : .secondary)
                        Text(isRtl ? "כל המוצרים" : "Apply to all items")
                            .font(.system(size: 14))
                        Spacer()
                    }
                }
                .buttonStyle(.plain)

                ForEach(basketEntriesSorted) { entry in
                    let isChecked = discountAllSelected || discountedLineIds.contains(entry.id)

                    Button {
                        if discountAllSelected {
                            discountAllSelected = false
                            discountedLineIds   = Set(basketKeys)
                        }
                        if isChecked {
                            discountedLineIds.remove(entry.id)
                        } else {
                            discountedLineIds.insert(entry.id)
                        }
                    } label: {
                        HStack {
                            Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                                .foregroundColor(isChecked ? .primary : .secondary)
                            Text("\(entry.item.name) × \(entry.quantity)")
                                .font(.system(size: 14))
                                .lineLimit(1)
                            Spacer()
                            Text(String(format: "\(currency)%.2f",
                                        entry.unitPrice * Double(entry.quantity)))
                                .font(.system(size: 14))
                                .foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
    
    

    private struct ExcludePanelView: View {
        let isRtl: Bool
        let currency: String
        let basketKeys: [Int]
        let basketEntriesSorted: [BasketEntry]

        @Binding var showExcludePanel: Bool
        @Binding var excludeAllSelected: Bool
        @Binding var excludedLineIds: Set<Int>

        var body: some View {
            VStack(spacing: 8) {

                Button {
                    excludeAllSelected.toggle()
                    if excludeAllSelected {
                        excludedLineIds = Set(basketKeys)
                    } else {
                        excludedLineIds.removeAll()
                    }
                } label: {
                    HStack {
                        Image(systemName: excludeAllSelected ? "checkmark.square.fill" : "square")
                            .foregroundColor(excludeAllSelected ? .primary : .secondary)
                        Text(isRtl ? "הוציאו את כל הפריטים מהחישוב"
                                   : "Exclude all items from total")
                            .font(.system(size: 14))
                        Spacer()
                    }
                }
                .buttonStyle(.plain)

                ForEach(basketEntriesSorted) { entry in
                    let isChecked = excludeAllSelected || excludedLineIds.contains(entry.id)

                    Button {
                        if excludeAllSelected {
                            excludeAllSelected = false
                            excludedLineIds    = Set(basketKeys)
                        }
                        if isChecked {
                            excludedLineIds.remove(entry.id)
                        } else {
                            excludedLineIds.insert(entry.id)
                        }
                    } label: {
                        HStack {
                            Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                                .foregroundColor(isChecked ? .primary : .secondary)
                            Text("\(entry.item.name) × \(entry.quantity)")
                                .font(.system(size: 14))
                                .lineLimit(1)
                            Spacer()
                            Text(String(format: "\(currency)%.2f",
                                        entry.unitPrice * Double(entry.quantity)))
                                .font(.system(size: 14))
                                .foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    withAnimation { showExcludePanel = false }
                } label: {
                    Text(isRtl ? "סיום" : "Done")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
    private var basketNavTitle: String {
        isTeamTabMode ? "שולחן צוות" : "קופה"
    }

    @ViewBuilder
    private func basketPanel(inline: Bool) -> some View {

        // ✅ snapshot values early (also helps, but main point is splitting view types)
        let basketSnapshot = basket
        let basketKeys = Array(basketSnapshot.keys)
        let basketIsEmpty = basketSnapshot.isEmpty

        VStack(spacing: 0) {

            BasketTopBar(
                isTeamTabMode: isTeamTabMode,
                isRtl: isRtl,
                currency: currency,
                basketIsEmpty: basketIsEmpty,
                basketKeys: basketKeys,
                basketTotalQuantity: basketTotalQuantity,
                showDiscountPanel: $showDiscountPanel,
                showExcludePanel: $showExcludePanel,
                discountMode: $discountMode,
                discountAllSelected: $discountAllSelected,
                discountedLineIds: $discountedLineIds,
                customDiscountText: $customDiscountText,
                customIsPercentage: $customIsPercentage,
                excludeAllSelected: $excludeAllSelected,
                excludedLineIds: $excludedLineIds
            )

            if showDiscountPanel {
                DiscountPanelView(
                    isRtl: isRtl,
                    currency: currency,
                    basketKeys: basketKeys,
                    basketEntriesSorted: basketEntriesSorted,
                    showDiscountPanel: $showDiscountPanel,
                    showExcludePanel: $showExcludePanel,
                    discountMode: $discountMode,
                    discountAllSelected: $discountAllSelected,
                    discountedLineIds: $discountedLineIds,
                    customDiscountText: $customDiscountText,
                    customIsPercentage: $customIsPercentage,
                    discountPill: { title, mode in
                        AnyView(discountPill(title: title, mode: mode))
                    }
                )
            }

            if showExcludePanel {
                ExcludePanelView(
                    isRtl: isRtl,
                    currency: currency,
                    basketKeys: basketKeys,
                    basketEntriesSorted: basketEntriesSorted,
                    showExcludePanel: $showExcludePanel,
                    excludeAllSelected: $excludeAllSelected,
                    excludedLineIds: $excludedLineIds
                )
            }

            if isPayLaterMode {
                VStack(alignment: .leading, spacing: 6) {
                    if isTeamTabMode && teamTabLoading {
                        Text("טוען שולחן…")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                    if let tab = activeTeamTab {
                        Text(tab.titleHe)
                            .font(.system(size: 26, weight: .heavy))
                            .foregroundColor(.primary)
                            .padding(.top, 4)

                        if let oid = unpaidOrderId {
                            Text("#\(oid)")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.secondary)
                        }
                    } else if !currentUnpaidOrderTitle.isEmpty {
                        Text(currentUnpaidOrderTitle)
                            .font(.system(size: 26, weight: .heavy))
                            .foregroundColor(.primary)
                            .padding(.top, 4)
                    } else {
                        Text("הזמנה פתוחה")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 4)
                .padding(.bottom, 10)
            }

            if basketEntriesSorted.isEmpty {
                VStack {
                    Spacer()
                    Text(isRtl ? "אין פריטים בסל" : "No items in basket")
                        .foregroundColor(.secondary)
                        .font(.system(size: 16, weight: .regular))
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if #available(iOS 16.0, *) {
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(spacing: 12) {
                            ForEach(basketSections()) { section in
                                if let label = section.headerTime {
                                    HStack {
                                        Text(label)
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundColor(.secondary)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.top, 4)
                                }

                                ForEach(section.entries) { entry in
                                    basketRow(entry)
                                }
                            }
                        }
                        .padding(.vertical, 12)
                    }
                    .scrollDisabled(isBasketHorizontalSwipe)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(spacing: 12) {
                            ForEach(basketSections()) { section in
                                if let label = section.headerTime {
                                    HStack {
                                        Text(label)
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundColor(.secondary)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.top, 4)
                                }

                                ForEach(section.entries) { entry in
                                    basketRow(entry)
                                }
                            }
                        }
                        .padding(.vertical, 12)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            // ✅ FOOTER (always visible) — no Spacer() pushing it away
            VStack(spacing: 12) {
                if discountAmount > 0 {
                    HStack {
                        Text(isRtl ? "הנחה" : "Discount")
                            .font(.system(size: 14))
                        Spacer()
                        Text(String(format: "-\(currency)%.2f", discountAmount))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.primary)
                    }
                    .padding(.horizontal, 16)
                }

                HStack {
                    Text(isRtl ? "סה״כ" : "Total")
                        .font(.system(size: 18, weight: .semibold))
                    Spacer()
                    Text(String(format: "\(currency)%.2f", finalTotal))
                        .font(.system(size: 20, weight: .bold))
                }
                .padding(.horizontal, 16)

                HStack(spacing: 10) {

                    if isTeamTabMode {
                        let canPrintNewLines = hasAddedLinesInPayLater

                        HStack(spacing: 12) {

                            // ⬅️ Back = same as "נקה"
                            Button {
                                Haptics.light()

                                // ✅ iPhone: if basket is presented as a sheet, close it first
                                if isPhoneLayout {
                                    showBasketSheetPhone = false
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                        startNewOrderFromPayLater()
                                    }
                                } else {
                                    startNewOrderFromPayLater()
                                }
                            } label: {
                                Image(systemName: "chevron.backward")
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundColor(.primary)
                                    .frame(width: 44, height: 44)
                                    .background(Color(.systemGray5))
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)

                            // ✅ Full-width print
                            Button {
                                guard canPrintNewLines else { return }

                                guard unpaidOrderId != nil else {
                                    Haptics.error()
                                    print("⚠️ teamTab print blocked: unpaidOrderId missing")
                                    return
                                }

                                printUpdatedUnpaidOrder()

                                // same behavior you had: after print, start fresh “new order”
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                    startNewOrderFromPayLater()
                                }
                            } label: {
                                Text(canPrintNewLines ? "הדפס" : "הודפס")
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 50)
                                    .background(canPrintNewLines ? Color.black : Color.gray.opacity(0.35))
                                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .disabled(!canPrintNewLines)
                        }
                    } else if isPayLaterMode {

                        NewOrderButton(title: "נקה הזמנה") {
                            startNewOrderFromPayLater()
                        }

                        Button {
                            guard !basketIsEmpty else { return }
                            guard validateBasketBeforeCheckout() else { return }

                            if hasAddedLinesInPayLater {
                                printUpdatedUnpaidOrder()
                            } else {
                                if inline {
                                    showOrderFlow = true
                                    hasChosenServiceMode = false
                                } else {
                                    showBasketSheetPhone = false
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                        showOrderFlow = true
                                        hasChosenServiceMode = false
                                    }
                                }
                            }
                        } label: {
                            let enabled = !basketIsEmpty

                            Text(mainActionButtonTitle)
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(
                                    enabled
                                        ? (colorScheme == .dark ? .black : .white)
                                        : .white
                                )
                                .frame(maxWidth: .infinity)
                                .frame(height: 48)
                                .background(
                                    enabled
                                        ? (colorScheme == .dark ? .white : .black)
                                        : Color.gray.opacity(0.4)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(basketIsEmpty)
                    } else {

                        Button {
                            guard !basketIsEmpty else { return }
                            guard validateBasketBeforeCheckout() else { return }

                            if hasAddedLinesInPayLater {
                                printUpdatedUnpaidOrder()
                            } else {
                                if inline {
                                    showOrderFlow = true
                                    hasChosenServiceMode = false
                                } else {
                                    showBasketSheetPhone = false
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                        showOrderFlow = true
                                        hasChosenServiceMode = false
                                    }
                                }
                            }
                        } label: {
                            let enabled = !basketIsEmpty

                            Text(mainActionButtonTitle)
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(
                                    enabled
                                        ? (colorScheme == .dark ? .black : .white)
                                        : .white
                                )
                                .frame(maxWidth: .infinity)
                                .frame(height: 48)
                                .background(
                                    enabled
                                        ? (colorScheme == .dark ? .white : .black)
                                        : Color.gray.opacity(0.4)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(basketIsEmpty)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
        .modifier(ShakeEffect(animatableData: CGFloat(basketShakeTrigger)))
        .background(Color(.systemGray6))
        .frame(width: inline ? 360 : nil)
    }
    private var isPhoneLayout: Bool {
        hSizeClass == .compact
    }
    @State private var showBasketSheetPhone: Bool = false
    
    private struct ReorderRequest: Encodable {
        let miniAppId: Int
        let id: Int
        let toCategory: String?
        let beforeId: Int?
        let afterId: Int?
        let targetIndex: Int?
    }
    
    
    private func lastInvoicePromptTitle() -> String? {
        guard let last = lastOrder else { return nil }

        let cleanName = last.customerName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "Customer", with: "")
            ?? ""

        if !cleanName.isEmpty {
            return "הזמנה אחרונה: \(cleanName)"
        } else {
            return "הזמנה אחרונה: \(last.orderNumber)"
        }
    }
    
    private var resolvedMiniAppId: Int {
        let m = UserDefaults.standard.integer(forKey: "miniAppId")
        if m > 0 { return m }
        if let s = UserDefaults.standard.string(forKey: "shopId"), let v = Int(s), v > 0 { return v }
        return 12
    }
    
    
    private func printInvoice(for snapshot: CashOrderSnapshot) {

        // 🔎 DEBUG what we are about to invoice
        print("🧾 invoice debug — entries=\(snapshot.entries.count)")
        for e in snapshot.entries {
            print("• \(e.quantity)x \(e.item.name) unitPrice=\(e.unitPrice) item.price=\(e.item.price)")
        }

        let items: [InvoiceItem] = snapshot.entries.map { entry in
            // ✅ fallback
            let unit = (entry.unitPrice > 0) ? entry.unitPrice : entry.item.price
            return InvoiceItem(
                name: entry.item.name,
                quantity: entry.quantity,
                unitPrice: unit
            )
        }

        // ✅ Totals (use the exact same logic as the invoice printer)
        let gross = items.reduce(0) { $0 + $1.lineTotal }

        // ✅ Invoice number (keep yours)
        let invoiceNumber = Int(Date().timeIntervalSince1970)

        // ✅ Payment (minimal + legal)
        // If you have actual payment data in snapshot, replace these mappings.
        let paidAmount = gross
        let paymentMethod = "Credit Card" // or "Cash" if this snapshot is cash

        PrinterManager.shared.printTaxInvoice(
            invoiceNumber: invoiceNumber,
            date: Date(),
            customerName: snapshot.customerName,
            items: items,
            vatRate: 0.18,

            // ✅ NEW required fields for "Tax Invoice / Receipt"
            paidAmount: paidAmount,
            paymentMethod: paymentMethod,
            cardBrand: nil,
            cardLast4: nil,
            installments: nil
        )
    }
    struct ProductToCategoryDropDelegate: DropDelegate {
        let targetCategory: String
        @Binding var draggingProduct: ShellMenuItem?
        let onMove: (Int, String) -> Void

        func dropEntered(info: DropInfo) { }

        func performDrop(info: DropInfo) -> Bool {
            guard let product = draggingProduct else {
                draggingProduct = nil
                return false
            }

            draggingProduct = nil
            onMove(product.id, targetCategory)
            return true
        }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            DropProposal(operation: .move)
        }
    }
 
    
    private func saveProductCategoryToServer(productId: Int, newCategory: String) {
        let shopId = resolvedMiniAppId
        guard shopId > 0 else {
            print("❌ saveProductCategoryToServer: missing shopId")
            return
        }

        guard let item = api.items.first(where: { $0.id == productId }) else { return }

        let draft = AdminProductDraft(
            productId: item.id,
            name: item.name,
            priceText: String(format: "%.2f", item.price),
            category: newCategory,
            description: item.description ?? "",
            imageURL: item.imageURL ?? "",
            modifierGroups: (item.modifiers ?? []).map { g in
                let kind: AdminModifierGroupDraft.Kind = (g.type == .options) ? .options : .additions

                return AdminModifierGroupDraft(
                    title: g.title,
                    kind: kind,
                    items: g.items.map {
                        AdminModifierItemDraft(
                            name: $0.name,
                            extraPriceText: String(format: "%.2f", $0.extraPrice),
                            linkedProductId: $0.linkedProductId
                        )
                    },
                    defaultFirst: {
                        guard kind == .options else { return false }

                        // ✅ DB rule:
                        // required = 0 -> toggle ON
                        // required = 1 -> toggle OFF
                        if let required = g.selection?.required {
                            return required == 0
                        }

                        // fallback for older saved data
                        if let defaultFirst = g.selection?.defaultFirst {
                            return defaultFirst == 1
                        }

                        // default if missing
                        return true
                    }()
                )
            },
            printerId: item.printer ?? defaultPrinterId(),
            printerIds: Set(item.printers ?? (item.printer != nil ? [item.printer!] : [])),
            isPhoneRequired: item.isPhone ?? false,
            isArchived: isArchived(item)
        )

        Task {
            await syncAdminDraftToServer(draft)
        }
    }
    
    private func sendReorderToServer(
        movedId: Int,
        newIndex: Int,
        category: String
    ) {
        // One product-sort pair
        struct SortUpdate: Encodable {
            let id: Int
            let sort: Int
        }

        // Bulk payload: miniAppId + all items in this category with their sort
        struct BulkReorderReq: Encodable {
            let miniAppId: Int
            let items: [SortUpdate]
        }

        // Resolve MiniApp / shop id
        let miniAppId = Int(UserDefaults.standard.string(forKey: "miniAppId") ?? "0") ?? 0

        // Find category index (0,1,2,…) from your left rail order
        let catIndex = categories.firstIndex(of: category) ?? 0
        let base = catIndex * 100

        // All products in this category, **in current UI order**:
        // api.items is being mutated by drag & drop, so this preserves
        // the visual order you see on screen.
        let itemsInCategory = api.items.filter { $0.category == category }

        // Compute sort = categoryIndex * 100 + 10 * indexWithinCategory
        let updates: [SortUpdate] = itemsInCategory.enumerated().map { idx, item in
            SortUpdate(
                id: item.id,
                sort: base + (idx + 1) * 10   // 10, 20, 30… within this category
            )
        }

        let payload = BulkReorderReq(miniAppId: miniAppId, items: updates)

        guard let url = URL(string: "https://minis.studio/api/products/reorder") else {
            print("❌ reorder: bad URL")
            return
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]

        guard let jsonData = try? encoder.encode(payload) else {
            print("❌ reorder: encode failed")
            return
        }
        let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"

        // 🔥 cURL print for debugging
        let curl = """
        curl -X POST "https://minis.studio/api/products/reorder" \\
          -H "Content-Type: application/json" \\
          -d '\(jsonString)'
        """
        print("🌀 REORDER cURL:")
        print(curl)

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = jsonData

        Task {
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                let body = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
                print("🌍 reorder HTTP \(code)")
                print("📦 reorder RESPONSE:", body)
            } catch {
                print("❌ reorder network error:", error.localizedDescription)
            }
        }
    }
    
    
    
    private struct ProductDropDelegate: DropDelegate {
        let target: ShellMenuItem
        @Binding var items: [ShellMenuItem]
        let category: String
        @Binding var dragging: ShellMenuItem?
        let onReorderCommitted: (Int, Int, String) -> Void   // movedId, newIndex, category

        func dropEntered(info: DropInfo) {
           
            guard let current = dragging, current.id != target.id else { return }

            // Only reorder within same category
            guard current.category == category,
                  target.category == category else { return }

            if let fromIndex = items.firstIndex(where: { $0.id == current.id }),
               let toIndex   = items.firstIndex(where: { $0.id == target.id }) {

                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    let item = items.remove(at: fromIndex)
                    items.insert(item, at: toIndex)
                }
            }
        }

        func performDrop(info: DropInfo) -> Bool {
            guard let current = dragging,
                  let newIndex = items.firstIndex(where: { $0.id == current.id }) else {
                dragging = nil
                return false
            }

            // ✅ Call back into the View to persist
            onReorderCommitted(current.id, newIndex, category)

            dragging = nil
            return true
        }
    }
    
    private func syncAdminDraftToServer(_ draft: AdminProductDraft) async {
        let shopId = resolvedMiniAppId
        guard shopId > 0 else {
            print("❌ syncAdminDraftToServer: missing shopId")
            return
        }

        let productApi = MinisProductAPI()


        do {
            let stations = PrintersConfigStore.shared.config.stations
            let payload  = draft.toUpsertPayload(shopId: shopId, stations: stations)
            let returnedId = try await productApi.upsertProduct(payload)
            if returnedId > 0 {
                // If this was a new product, we should update its productId for future edits
                print("🟢 upsertProduct → productId =", returnedId)
            }

           // try await productApi.publish(shopId: shopId)

            print("🟢 publish(shopId:\(shopId)) succeeded")

            // Optional: reload menu from server so CashPoint reflects the canonical state
            await MainActor.run {
                safeReloadMenu(reason: "toggle isOpen")
            }
        } catch let MinisProductAPI.APIError.badResponse(code, body) {
            print("❌ Admin upsert bad response: HTTP \(code)\n\(body)")
        } catch {
            print("❌ Admin upsert/publish error:", error.localizedDescription)
        }
    }
    @MainActor
    private func makeAdminDraft(from item: ShellMenuItem) -> AdminProductDraft {
        // Snapshot stations once (no actor issues)
        let stations = PrintersConfigStore.shared.config.stations.filter { $0.status != 0 }

        func normalize(_ s: String?) -> String {
            (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func stationIdForLegacyPrinter(_ legacy: String) -> String? {
            let t = legacy.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

            if t == "bar" || legacy.contains("בר") {
                return stations.first(where: { $0.label.lowercased().contains("bar") || $0.label.contains("בר") })?.id
            }
            if t == "kitchen" || legacy.contains("מטבח") {
                return stations.first(where: { $0.label.lowercased().contains("kitchen") || $0.label.contains("מטבח") })?.id
            }
            if t == "bakery" || legacy.contains("מאפ") || legacy.contains("ויטרינה") {
                return stations.first(where: {
                    $0.label.lowercased().contains("bakery")
                    || $0.label.contains("מאפ")
                    || $0.label.contains("ויטרינה")
                })?.id
            }
            return nil
        }

        // ✅ 1) ids from JSON "Printers": [...]
        let parsedIds: [String] = (item.printers ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        // ✅ 2) primary selection:
        // - prefer first parsed
        // - else try "printer" (could be "s2" or "Bar")
        // - else fallback to first station
        var primary: String = ""

        if let first = parsedIds.first {
            primary = first
        } else {
            let p = normalize(item.printer)

            if stations.contains(where: { $0.id == p }) {
                primary = p                      // already a station id
            } else if !p.isEmpty, let mapped = stationIdForLegacyPrinter(p) {
                primary = mapped                 // legacy "Bar/Kitchen/Bakery"
            } else {
                primary = stations.first?.id ?? ""
            }
        }

        // ✅ 3) checkbox set
        var idsSet = Set(parsedIds)
        if !primary.isEmpty { idsSet.insert(primary) }
        if idsSet.isEmpty, let first = stations.first?.id {
            primary = first
            idsSet = [first]
        }

        // ✅ 4) MODIFIERS: restore the old mapping (this is what was missing)
        let groups: [AdminModifierGroupDraft] = (item.modifiers ?? []).map { g in
            let kind: AdminModifierGroupDraft.Kind = (g.type == .options) ? .options : .additions

            let items: [AdminModifierItemDraft] = g.items.map { opt in

                let linkedProduct = api.items.first { $0.id == opt.linkedProductId }

                return AdminModifierItemDraft(
                    name: linkedProduct?.name ?? opt.name,
                    extraPriceText: String(format: "%.2f", opt.extraPrice),
                    linkedProductId: opt.linkedProductId,
                    useLinkedName: opt.linkedProductId != nil,
                    useLinkedPrice: false
                )
            }

            return AdminModifierGroupDraft(
                title: g.title,
                kind: kind,
                items: items,
                defaultFirst: (g.selection?.defaultFirst ?? 0) > 0
            )
        }
        
        return AdminProductDraft(
            productId: item.id,
            name: item.name,
            priceText: String(format: "%.2f", item.price),
            category: item.category,
            description: item.description ?? "",
            imageURL: item.imageURL ?? "",
            modifierGroups: groups,
            printerId: primary,
            printerIds: idsSet,
            isPhoneRequired: (item.isPhone ?? false),
            isArchived: isArchived(item)
        )
    }
    
    private var basketRequiresPhone: Bool {
        basket.values.contains { ($0.item.isPhone ?? false) }
    }
    // Apply an edited draft back into api.items (and optionally call your backend)
    // Apply an edited draft back into api.items (and optionally call your backend)
    private func applyAdminSave(_ draft: AdminProductDraft) {

        func normalizeId(_ s: String) -> String {
            s.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func resolvedPrimaryId(fallback: String) -> String {
            let p = normalizeId(draft.printerId)
            return p.isEmpty ? fallback : p
        }

        func resolvedPrinterIds(primary: String) -> [String]? {
            // If no checkboxes were used, we still publish [primary]
            var ids: [String] = []

            if !draft.printerIds.isEmpty {
                ids = draft.printerIds.map { normalizeId($0) }.filter { !$0.isEmpty }
            }

            // Always include primary (so routing is stable)
            let p = normalizeId(primary)
            if !p.isEmpty && !ids.contains(p) {
                ids.insert(p, at: 0)
            }

            // If still empty, return nil (means "not set")
            if ids.isEmpty { return nil }

            // Keep stable order (nice for diffs/debug)
            // Primary already inserted at [0], so sort the rest only
            if ids.count > 1 {
                let head = ids[0]
                let tail = Array(ids.dropFirst()).sorted()
                return [head] + tail
            }

            return ids
        }

        // 1) NEW product path
        guard let productId = draft.productId else {
            let price = Double(draft.priceText.replacingOccurrences(of: ",", with: ".")) ?? 0

            let newModifiers = draft.modifierGroups.map { g in
                let kind: ModifierGroup.GroupType = (g.kind == .options) ? .options : .additions
                let items = g.items.map {
                    ModifierItem(
                        name: $0.name,
                        extraPrice: Double($0.extraPriceText.replacingOccurrences(of: ",", with: ".")) ?? 0
                    )
                }

                return ModifierGroup(
                    type: kind,
                    title: g.title,
                    items: items,
                    selection: ModifierSelection(
                        required: 0,
                        defaultFirst: g.defaultFirst ? 1 : 0
                    )
                )
            }

            let newId = (api.items.map(\.id).max() ?? 0) + 1

            let primary = resolvedPrimaryId(fallback: defaultPrinterId())
            let printers = resolvedPrinterIds(primary: primary)

            let newItem = ShellMenuItem(
                id: newId,
                name: draft.name,
                price: price,
                category: draft.category,
                modifiers: newModifiers,
                imageURL: draft.imageURL.isEmpty ? nil : draft.imageURL,
                description: draft.description.isEmpty ? nil : draft.description,
                status: 1,
                stockQuantity: nil,
                printer: primary,
                printers: printers
            )

            api.items.append(newItem)

            // Remote upsert + publish
            Task { await syncAdminDraftToServer(draft) }
            return
        }

        // 2) EDIT EXISTING product locally in api.items
        if let idx = api.items.firstIndex(where: { $0.id == productId }) {

            let price = Double(draft.priceText.replacingOccurrences(of: ",", with: ".")) ?? api.items[idx].price

            let newModifiers = draft.modifierGroups.map { g in
                let kind: ModifierGroup.GroupType = (g.kind == .options) ? .options : .additions
                let items = g.items.map {
                    ModifierItem(
                        name: $0.name,
                        extraPrice: Double($0.extraPriceText.replacingOccurrences(of: ",", with: ".")) ?? 0
                    )
                }
                return ModifierGroup(type: kind, title: g.title, items: items)
            }

            let fallbackPrimary = api.items[idx].printer ?? defaultPrinterId()
            let primary = resolvedPrimaryId(fallback: fallbackPrimary)
            let printers = resolvedPrinterIds(primary: primary)

            let updatedItem = ShellMenuItem(
                id: productId,
                name: draft.name,
                price: price,
                category: draft.category,
                modifiers: newModifiers,
                imageURL: draft.imageURL.isEmpty ? nil : draft.imageURL,
                description: draft.description,
                status: api.items[idx].status,
                stockQuantity: api.items[idx].stockQuantity,
                printer: primary,
                printers: printers
            )

            api.items[idx] = updatedItem

            // 3) ALSO update any basket entries that use this product,
            //    so the basket reflects the changes immediately.
            for (lineId, entry) in basket {
                guard entry.item.id == productId else { continue }
                basket[lineId] = BasketEntry(
                    id: entry.id,
                    item: updatedItem,
                    quantity: entry.quantity,
                    subtitle: entry.subtitle,
                    unitPrice: entry.unitPrice
                )
            }
        }

        // 4) Remote upsert + publish
        Task { await syncAdminDraftToServer(draft) }
    }
    
    enum StockQuantityAPI {

        private static func resolvedMiniAppId() -> Int {
            let d = UserDefaults.standard
            let m = d.integer(forKey: "miniAppId")
            if m > 0 { return m }
            if let s = d.string(forKey: "shopId"), let v = Int(s), v > 0 { return v }
            return 0
        }

        /// ✅ Returns `true` only when the server ACKs with 2xx.
        /// - Retries on network errors + 408/429/502/503/504
        /// - Logs requestId + response body prefix for debugging
        static func setStock(productId: Int, quantity: Int?) async -> Bool {
            print("🔥 StockQuantityAPI.setStock CALLED productId=\(productId) qty=\(String(describing: quantity))")

            let miniAppId = resolvedMiniAppId()
            guard miniAppId > 0 else {
                print("❌ setStock: missing miniAppId/shopId")
                return false
            }

            guard let url = URL(string: "https://minis.studio/api/products/\(productId)/stock") else {
                print("❌ setStock: bad URL for productId=\(productId)")
                return false
            }

            let requestId = UUID().uuidString

            var body: [String: Any] = [
                "miniAppId": miniAppId,
                "stockQuantity": quantity as Any // Int or nil
            ]
            if quantity == nil { body["stockQuantity"] = NSNull() }

            let bodyData = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()

            var req = URLRequest(url: url, timeoutInterval: 20)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue("no-store", forHTTPHeaderField: "Cache-Control")
            req.setValue(requestId, forHTTPHeaderField: "X-Request-Id")
            req.httpBody = bodyData

            // Debug
            print("📤 setStock reqId=\(requestId) product=\(productId) qty=\(String(describing: quantity)) miniAppId=\(miniAppId)")
            print(req.curlDebug)

            // Retry policy
            // 0s, 0.4s, 0.9s, 1.8s (small exponential-ish backoff)
            let delays: [UInt64] = [0, 400_000_000, 900_000_000, 1_800_000_000]

            for attempt in 0..<delays.count {
                if delays[attempt] > 0 {
                    try? await Task.sleep(nanoseconds: delays[attempt])
                }

                do {
                    let (data, resp) = try await URLSession.shared.data(for: req)
                    let http = resp as? HTTPURLResponse
                    let code = http?.statusCode ?? -1

                    let text = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
                    let prefix = String(text.prefix(400))

                    // Helpful headers if present
                    let serverReqId =
                        http?.value(forHTTPHeaderField: "x-request-id")
                        ?? http?.value(forHTTPHeaderField: "X-Request-Id")
                        ?? http?.value(forHTTPHeaderField: "x-correlation-id")

                    print("📥 setStock resp reqId=\(requestId) serverReqId=\(serverReqId ?? "nil") attempt=\(attempt+1) HTTP \(code) body=\(prefix)")

                    if (200...299).contains(code) {
                        return true
                    }

                    // Retry only on transient cases
                    let retryableCodes: Set<Int> = [408, 429, 502, 503, 504]
                    if retryableCodes.contains(code), attempt < delays.count - 1 {
                        continue
                    }

                    return false

                } catch {
                    print("❌ setStock network reqId=\(requestId) attempt=\(attempt+1) err=\(error.localizedDescription)")
                    // Retry on network errors
                    if attempt < delays.count - 1 { continue }
                    return false
                }
            }

            return false
        }
    }
    
    
    /// Set stock of all products in the selected category to 0 (out of stock)
    private func toggleStockForSelectedCategory() {
        guard !selectedCategory.isEmpty,
              selectedCategory != "✏️ הערות"
        else { return }

        let items = api.items.filter { $0.category == selectedCategory }
        guard !items.isEmpty else { return }

        let isZeroed = isCategoryZeroed(selectedCategory)

        if isZeroed {
            // ✅ אינסוף = להסיר את הערך מהדיקט (nil => remove key)
            for item in items {
                stockAdjustments[item.id] = nil
                stockText[item.id] = nil
                dirtyStockIds.insert(item.id)
                applyLocalAvailabilityFromStock(productId: item.id)

            }
        } else {
            // ✅ אפס
            for item in items {
                stockAdjustments[item.id] = 0
                stockText[item.id] = nil
                dirtyStockIds.insert(item.id)
                applyLocalAvailabilityFromStock(productId: item.id)

            }
        }

        Haptics.light()
    }
    private func bumpStockAmount(productId: Int, delta: Int) {
        var currentOpt = stockAdjustments[productId]  // Int? (nil = ∞)

        if let current = currentOpt {
            let newValue = current + delta
            if newValue < 0 {
                currentOpt = nil          // below 0 => ∞
            } else {
                currentOpt = newValue     // 0..n
            }
        } else {
            // currently ∞
            if delta > 0 {
                currentOpt = 1            // first + => 1
            } else {
                currentOpt = nil          // - from ∞ => stays ∞
            }
        }

        // ✅ write once
        stockAdjustments[productId] = currentOpt
        dirtyStockIds.insert(productId)
        applyLocalAvailabilityFromStock(productId: productId)
        // ✅ IMPORTANT: if TextField is showing, it reads stockText first — update it!
        if editingStockProductId == productId || isStockEditMode {
            if let v = currentOpt {
                stockText[productId] = "\(max(v, 0))"
            } else {
                stockText[productId] = ""     // empty => shows placeholder "∞"
            }
        }

        print("📦 pending stock:", stockAdjustments, "dirty:", dirtyStockIds)

        // ✅ keep the 2s auto-commit alive when editing a single product
        if editingStockProductId == productId && !isStockEditMode {
            restartSingleStockEditTimer(productId: productId)
        } else if !isStockEditMode {
            restartStockEditTimer()
        }
    }
    

    private func restartStockEditTimer() {
        stockEditWorkItem?.cancel()
        let work = DispatchWorkItem {
            editingStockProductId = nil
        }
        stockEditWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }
    
   
   
    struct CashOrderSnapshot: Identifiable {
        let id = UUID()
        let orderNumber: Int
        let entries: [BasketEntry]
        let totalPrice: Double
        let diningMode: DiningMode
        let customerName: String?
        let customerPhone: String?
    }
    
    private func splitSubtitle(_ subtitle: String?) -> (optionsPart: String?, notePart: String?) {
        guard let subtitle, !subtitle.isEmpty else { return (nil, nil) }

        // Format: "options … • note …"
        if let dotIndex = subtitle.firstIndex(of: "•") {
            let options = subtitle[..<dotIndex]
            let note = subtitle[subtitle.index(after: dotIndex)...]

            let optStr = options.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            let noteStr = note.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            return (optStr.isEmpty ? nil : optStr, noteStr.isEmpty ? nil : noteStr)
        } else {
            // Backwards compat: all text is treated as "options"
            return (subtitle, nil)
        }
    }

    private func optionsFromSubtitle(_ subtitle: String?) -> [String: String] {
        let parts = splitSubtitle(subtitle)
        guard let optionsText = parts.optionsPart, !optionsText.isEmpty else { return [:] }

        var result: [String: String] = [:]
        let partsArray = optionsText.split(separator: ",")
        for part in partsArray {
            let trimmed = part.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            let comps = trimmed.split(separator: ":", maxSplits: 1)
            if comps.count == 2 {
                let key = comps[0].trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                let value = comps[1].trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                result[key] = value
            }
        }
        return result
    }

    private func noteFromSubtitle(_ subtitle: String?) -> String {
        let parts = splitSubtitle(subtitle)
        return parts.notePart ?? ""
    }

    @ViewBuilder
    private func additionModeChip(
        title: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Text(title)
            .font(.system(size: 15, weight: .semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                selected
                ? (colorScheme == .dark ? .white : .black)
                : Color(.systemGray5)
            )
            .foregroundColor(
                selected
                ? (colorScheme == .dark ? .black : .white)
                : .primary
            )
            .clipShape(Capsule())
            .onTapGesture(perform: action)
    }
    // INSIDE CashPointView
    private func combineSubtitle(_ optionsText: String?, _ noteText: String?) -> String? {
        let opt  = optionsText?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        let note = noteText?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

        if let opt, !opt.isEmpty, let note, !note.isEmpty {
            return "\(opt) • \(note)"
        }
        if let opt, !opt.isEmpty { return opt }
        if let note, !note.isEmpty { return note }
        return nil
    }

    /// Recalculate unitPrice + subtitle after inline changes in basket
    private func updateEntryPricingAndSubtitle(lineId: Int) {
        guard var current = basket[lineId] else { return }

        guard let groups = current.item.modifiers, !groups.isEmpty else {
            let raw = (noteDrafts[lineId] ?? current.subtitle ?? "")
            let noteClean = raw.trimmingCharacters(in: .whitespacesAndNewlines)

            current = BasketEntry(
                id: current.id,
                item: current.item,
                quantity: current.quantity,
                subtitle: noteClean.isEmpty ? nil : noteClean,
                unitPrice: current.item.price
            )
            basket[lineId] = current
            return
        }

        let optionsMap = optionSelections[lineId] ?? [:]
        let additionsMap = additionSelections[lineId] ?? [:]

        let extraPerUnit: Double = groups.reduce(0.0) { total, group in
            switch group.type {
            case .options:
                let selectedName = optionsMap[group.title]?
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                guard let selectedName,
                      !selectedName.isEmpty,
                      let opt = group.items.first(where: { $0.name == selectedName }) else {
                    return total
                }

                return total + opt.extraPrice

            case .additions:
                let groupMap = additionsMap[group.title] ?? [:]

                let allSelectedNames =
                    (groupMap[.with] ?? [])
                    .union(groupMap[.without] ?? [])
                    .union(groupMap[.side] ?? [])

                let addSum = group.items
                    .filter { allSelectedNames.contains($0.name) }
                    .map { $0.extraPrice }
                    .reduce(0.0, +)

                return total + addSum
            }
        }

        let unitPrice = current.item.price + extraPerUnit

        var subtitlePieces: [String] = []

        for group in groups where group.type == .options {
            let selectedName = optionsMap[group.title]?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard let selectedName, !selectedName.isEmpty else { continue }

            if let first = group.items.first?.name, selectedName == first {
                let isRequired = (group.selection?.required ?? 0) > 0
                if !isRequired { continue }
            }

            if let opt = group.items.first(where: { $0.name == selectedName }) {
                let shownName = displayModifierName(opt)
                subtitlePieces.append("\(group.title): \(shownName)")
            } else {
                subtitlePieces.append("\(group.title): \(selectedName)")
            }
        }

        var withItems: [String] = []
        var withoutItems: [String] = []
        var sideItems: [String] = []

        for group in groups where group.type == .additions {
            let groupMap = additionsMap[group.title] ?? [:]

            let withSet = groupMap[.with] ?? []
            let withoutSet = groupMap[.without] ?? []
            let sideSet = groupMap[.side] ?? []

            for opt in group.items {
                let shownName = displayModifierName(opt)

                if withSet.contains(opt.name) {
                    withItems.append("עם \(shownName)")
                }
                if withoutSet.contains(opt.name) {
                    withoutItems.append("בלי \(shownName)")
                }
                if sideSet.contains(opt.name) {
                    sideItems.append("\(shownName) בצד")
                }
            }
        }

        subtitlePieces.append(contentsOf: withItems)
        subtitlePieces.append(contentsOf: withoutItems)
        subtitlePieces.append(contentsOf: sideItems)

        let optionsText = subtitlePieces.joined(separator: ", ")

        let rawNote = noteDrafts[lineId] ?? noteFromSubtitle(current.subtitle)
        let noteClean = rawNote.trimmingCharacters(in: .whitespacesAndNewlines)

        let newSubtitle = combineSubtitle(
            optionsText.isEmpty ? nil : optionsText,
            noteClean.isEmpty ? nil : noteClean
        )

        current = BasketEntry(
            id: current.id,
            item: current.item,
            quantity: current.quantity,
            subtitle: newSubtitle,
            unitPrice: unitPrice
        )

        basket[lineId] = current
    }

    private var discountRate: Double {
        switch discountMode {
        case .ten:     return 0.10
        case .fifteen: return 0.15
        case .thirteen: return 0.3
        default:       return 0
        }
    }

    private var discountBaseTotal: Double {
        var includedIds: Set<Int>

        if discountAllSelected {
            includedIds = Set(basket.keys)
        } else {
            includedIds = discountedLineIds

            // ✅ safety: if user turned off "all" but didn't select anything,
            // treat it as "all" (prevents 0 discount surprises)
            if includedIds.isEmpty {
                includedIds = Set(basket.keys)
            }
        }

        return basket.values
            .filter { includedIds.contains($0.id) }
            .reduce(0) { $0 + $1.unitPrice * Double($1.quantity) }
    }

    private var discountAmount: Double {
        switch discountMode {
        case .none:
            return 0

        case .ten, .fifteen, .thirteen:
            return discountBaseTotal * discountRate

        case .custom:
            let raw = customDiscountText
                .replacingOccurrences(of: ",", with: ".")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let v = Double(raw) ?? 0
            guard v > 0 else { return 0 }

            if customIsPercentage {
                // v is a percent, e.g. 12 = 12% of base
                let pct = min(max(v, 0), 100)   // clamp 0–100
                return discountBaseTotal * (pct / 100.0)
            } else {
                // v is a flat amount (limit to base / total)
                return max(0, min(v, basketTotalPrice))
            }
        }
    }

    struct CategoryDropDelegate: DropDelegate {
        let target: String
        @Binding var order: [String]
        @Binding var dragging: String?
        let onCommitted: () -> Void

        func dropEntered(info: DropInfo) {
            guard let current = dragging, current != target else { return }

            // never move notes / archive
            if current == "✏️ הערות" || current == "ארכיון" { return }
            if target == "✏️ הערות" || target == "ארכיון" { return }

            guard let from = order.firstIndex(of: current),
                  let to = order.firstIndex(of: target) else { return }

            // already in place → do nothing
            if from == to { return }

            withAnimation(.interactiveSpring(response: 0.22, dampingFraction: 0.88)) {
                let moved = order.remove(at: from)
                order.insert(moved, at: to)
            }
        }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            DropProposal(operation: .move)
        }

        func performDrop(info: DropInfo) -> Bool {
            dragging = nil
            onCommitted()
            return true
        }
    }
    
    
    private let productColumns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    private var categories: [String] {
        let notes = "✏️ הערות"
        let archive = archiveCategoryTitle

        let realMenuCats = Array(Set(api.items.map { item in
            isArchived(item) ? archive : item.category
        }))

        var out: [String] = []

        // ✅ FIRST: trust current local categoryOrder
        for cat in categoryOrder {
            if cat == notes {
                if !out.contains(notes) { out.append(notes) }
                continue
            }

            if cat == archive {
                if realMenuCats.contains(archive), !out.contains(archive) {
                    out.append(archive)
                }
                continue
            }

            if realMenuCats.contains(cat), !out.contains(cat) {
                out.append(cat)
            }
        }

        // ✅ THEN: append any NEW categories not seen before
        for cat in realMenuCats where cat != notes && cat != archive {
            if !out.contains(cat) {
                out.append(cat)
            }
        }

        // ✅ always keep hardcoded notes
        if !out.contains(notes) {
            out.append(notes)
        }

        // ✅ archive only if exists
        if realMenuCats.contains(archive), !out.contains(archive) {
            out.append(archive)
        }

        return out
    }
    

    private var itemsForSelectedCategory: [ShellMenuItem] {
        guard !selectedCategory.isEmpty else { return [] }

        if selectedCategory == "✏️ הערות" {
            return [
                makeNoteItem(id: -1001, name: "הערה לבר",     stationId: "s2", legacy: "Bar"),
                makeNoteItem(id: -1002, name: "הערה למטבח",   stationId: "s1", legacy: "Kitchen"),
                makeNoteItem(id: -1003, name: "הערה לוטרינה", stationId: "s3", legacy: "Bakery")
            ]
        }

        if selectedCategory == archiveCategoryTitle {
            return api.items.filter { isArchived($0) }
        }

        return api.items.filter {
            !isArchived($0) && $0.category == selectedCategory
        }
    }
   
    struct NewOrderButton: View {
        let title: String
        let action: () -> Void
        @Environment(\.layoutDirection) private var dir

        var body: some View {
            Button {
                Haptics.light()
                action()
            } label: {
                HStack(spacing: 8) {
                    // ✅ Chevron BACK – leading
                  
                    Text(title)
                        .font(.system(size: 17, weight: .bold))
                }
                .foregroundColor(.white)
                .frame(height: 48)
                .padding(.horizontal, 16)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }
   
    private func remainingStock(for item: ShellMenuItem) -> Int? {
        stockAdjustments[item.id]
    }

    /// Max additional quantity you can still add for this item, taking current basket into account.
    /// If `editingLineId` is non-nil, we allow that line to change within the global stock budget.
    private func maxAdditionalQuantity(for item: ShellMenuItem, editingLineId: Int? = nil) -> Int? {
        guard let stock = remainingStock(for: item) else {
            // nil = no explicit stock limit
            return nil
        }
        let totalInBasket = quantityInBasket(for: item)
        let currentLineQty = editingLineId.flatMap { basket[$0]?.quantity } ?? 0
        let usedByOthers = max(0, totalInBasket - currentLineQty)
        let remaining = stock - usedByOthers
        return max(0, remaining)
    }
    private func quantityInBasket(for item: ShellMenuItem) -> Int {
        basket.values
            .filter { $0.item.id == item.id }
            .reduce(0) { $0 + $1.quantity }
    }

    private var basketEntriesSorted: [BasketEntry] {
        basket.values.sorted { $0.id < $1.id } // oldest at top, newest at bottom
    }
    
    private func startNewOrderFromPayLater() {
        activeTeamTab = nil
        // Exit pay-later context and start fresh
        isPayLaterMode = false
        unpaidOrderId = nil
        lockedLineIds.removeAll()
        lineSessionTime.removeAll()
        diningMode = .dineIn

        hasChosenServiceMode = false
        basket.removeAll()
   //     nextBasketLineId = 1

        // 🔥 Clear saved customer info
        posSavedName = ""
        posSavedPhone = ""

        // Also clear local working copies if needed
        // (This prevents the name/phone step from pre-filling)
        // These exist in OrderFlowView but POS keeps last values before entering:
        lastOrder = nil

        // Go back to service picker screen
        
    }
    private var currentUnpaidOrderTitle: String {
        // 🧩 Team tab stays as-is
        if let tab = activeTeamTab {
            return tab.titleHe
        }

        // 👤 Prefer customer name
        let cleanName = posSavedName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "Customer", with: "")

        if !cleanName.isEmpty {
            return cleanName
        }

        // 🔁 Fallback only if no name
        if let oid = unpaidOrderId {
            return "הזמנה \(oid)"
        }

        return "הזמנה פתוחה"
    }
    
    private var showCategoryRailOnPhone: Bool {
        if !isPhoneLayout { return true }
        if selectedCategory == "✏️ הערות" { return true }   // ✅ keep notes accessible
        return !isStockEditMode
    }
    
    private struct BasketSection: Identifiable {
        let id: Int
        let headerTime: String?   // e.g. "8:32" or "הוספה"
        let entries: [BasketEntry]
    }

    /// Groups basket entries by server time.
    /// New section if time diff > 2 minutes between consecutive locked lines.
    private func basketSections() -> [BasketSection] {
        let entries = basketEntriesSorted

        let restored = entries
            .filter { lockedLineIds.contains($0.id) }
            .sorted {
                let t1 = lineSessionTime[$0.id] ?? Date.distantPast
                let t2 = lineSessionTime[$1.id] ?? Date.distantPast
                return t1 < t2
            }
        let added    = entries.filter { !lockedLineIds.contains($0.id) }

        var result: [BasketSection] = []
        var sectionIndex = 0

        // MARK: Append helper (THIS is the version you asked about)
        func appendSection(header: String?, entries: [BasketEntry]) {
            guard !entries.isEmpty else { return }
            result.append(
                BasketSection(
                    id: sectionIndex,      // ← stable ID
                    headerTime: header,
                    entries: entries
                )
            )
            sectionIndex += 1           // next section gets next id
        }

        // MARK: 1. Restored sections — grouped by updated time
        if !restored.isEmpty {
            var currentHeader: String? = nil
            var currentEntries: [BasketEntry] = []
            var lastTime: Date? = nil

            func flush() {
                guard !currentEntries.isEmpty else { return }
                appendSection(header: currentHeader, entries: currentEntries)
                currentHeader = nil
                currentEntries = []
            }

            for entry in restored {
                guard let t = lineSessionTime[entry.id] else {
                    currentEntries.append(entry)
                    continue
                }

                if let last = lastTime {
                    let diffMinutes = abs(t.timeIntervalSince(last)) / 60.0
                    if diffMinutes > 2 {
                        // too far apart → new session
                        flush()
                        currentHeader = sectionTimeFormatter.string(from: t)
                    }
                } else {
                    // first entry
                    flush()
                    currentHeader = sectionTimeFormatter.string(from: t)
                }

                lastTime = t
                currentEntries.append(entry)
            }

            flush()
        }

        // MARK: 2. Added entries (only show "הוספה" in unpaid mode)
        let unpaidSession = isPayLaterMode && !restored.isEmpty

        if !added.isEmpty {
            if unpaidSession {
                appendSection(header: "הוספה", entries: added)
            } else {
                appendSection(header: nil, entries: added)
            }
        }

        return result
    }
    private func restoreUnpaidOrder(_ order: AdminOrderItem) {
        // Fresh state
        activeTeamTab = nil   // ✅ ADD THIS (important)

        basket.removeAll()
      //  nextBasketLineId = 1
        lockedLineIds.removeAll()
        lineSessionTime.removeAll()
        unpaidOrderId = order.id

        // 🔹 Reset all per-line UI/editing state so everything starts CLOSED
        expandedBasketLineId = nil
        noteDrafts.removeAll()
        optionSelections.removeAll()
        additionSelections.removeAll()
        basketSwipeOffsets.removeAll()

        // Rebuild basket from admin order lines
        for line in order.items {
            let lineId = nextBasketLineId
            nextBasketLineId += 1

            let item = makeShellMenuItem(from: line)

            let subtitleText = line.modifiersText?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let entry = BasketEntry(
                id: lineId,
                item: item,
                quantity: line.quantity,
                subtitle: (subtitleText?.isEmpty ?? true) ? nil : subtitleText,
                unitPrice: line.unitPrice
            )
            basket[lineId] = entry

            // 🔒 mark this line as “submitted already”
            lockedLineIds.insert(lineId)

            // ⏰ store server time (prefer per-item; fallback = order time)
            let ts = line.updatedAt ?? order.placedAt
            lineSessionTime[lineId] = ts
        }

        // Service + name etc...
        if order.subtitle.contains("לקחת") {
            diningMode = .takeAway
        } else {
            diningMode = .dineIn
        }
        hasChosenServiceMode = true
        
        let cleanName = order.customerName
            .replacingOccurrences(of: "Customer", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanName.isEmpty {
            posSavedName = cleanName
        }

        isPayLaterMode = true
    }

    private var basketTotalQuantity: Int {
        basket.values.reduce(0) { $0 + $1.quantity }
    }
    
    
    private func resolvedCustomerNameForPrint(
        fallbackNameFromFlow: String? = nil
    ) -> String {
        func clean(_ s: String?) -> String {
            (s ?? "")
                .replacingOccurrences(of: "Customer", with: "", options: .caseInsensitive)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 1) If OrderFlowView ever passes a name (optional future-proof)
        let a = clean(fallbackNameFromFlow)
        if a.count >= 2 { return a }

        // 2) Your POS stored name
        let b = clean(posSavedName)
        if b.count >= 2 { return b }

        // 3) Last resort: read directly from UserDefaults (covers timing issues)
        let c = clean(UserDefaults.standard.string(forKey: "posSavedName"))
        if c.count >= 2 { return c }

        // 4) Never return empty to printer
        return "שם לקוח"
    }
    
    private func stockLabel(for value: Int?, isOutOfStock: Bool) -> String {
        // If product is marked out-of-stock → show "0"
        if isOutOfStock { return "0" }

        // nil means infinite stock
        guard let v = value else { return "∞" }

        // if server sent a bad negative → treat as infinite
        if v < 0 { return "∞" }

        return "\(v)"
    }
    /// Remove a single unit from the *last added* basket line of this product.
    /// If that line reaches 0, it is removed (via `decrementEntry`).
    private func removeOneFromLastLine(of item: ShellMenuItem) {
        // Find the basket line with this productId that has the highest lineId (last added)
        guard let (lineId, _) = basket
            .filter({ $0.value.item.id == item.id })
            .max(by: { $0.key < $1.key }) else {
            return
        }

        decrementEntry(lineId)
    }

    @GestureState private var isHorizontalSwipe: Bool = false
    @GestureState private var isBasketHorizontalSwipe: Bool = false
    
    private func basketSwipeGesture(for entry: BasketEntry) -> some Gesture {
        let isLocked = lockedLineIds.contains(entry.id)

        return DragGesture(minimumDistance: 26) // ✅ harder to trigger accidentally
            .updating($isBasketHorizontalSwipe) { value, state, _ in
                guard !isLocked else { return }

                let dx = value.translation.width
                let dy = value.translation.height

                // ✅ Require STRONG horizontal intent
                if abs(dx) > 60 && abs(dx) > abs(dy) + 22 {
                    state = true
                }
            }
            .onChanged { value in
                guard !isLocked else { basketSwipeOffsets[entry.id] = 0; return }

                let dx = value.translation.width
                let dy = value.translation.height

                // ✅ If it’s not clearly horizontal, don’t touch offsets (let ScrollView scroll)
                guard abs(dx) > 60 && abs(dx) > abs(dy) + 22 else {
                    basketSwipeOffsets[entry.id] = 0
                    return
                }

                dismissKeyboard()

                let dir: CGFloat = isRtl ? -1 : 1
                basketSwipeOffsets[entry.id] = dx * dir
            }
            .onEnded { value in
                guard !isLocked else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        basketSwipeOffsets[entry.id] = 0
                    }
                    return
                }

                let dx = value.translation.width
                let dy = value.translation.height
                guard abs(dx) > 60 && abs(dx) > abs(dy) + 22 else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        basketSwipeOffsets[entry.id] = 0
                    }
                    return
                }

                let dir: CGFloat = isRtl ? -1 : 1
                let translated = dx * dir
                let commitThreshold: CGFloat = 90 // ✅ slightly higher

                if translated > commitThreshold {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                        basketSwipeOffsets[entry.id] = 120 * dir
                    }
                    Haptics.light()
                    incrementEntry(entry.id)

                } else if translated < -commitThreshold {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                        basketSwipeOffsets[entry.id] = -120 * dir
                    }
                    Haptics.light()
                    decrementEntry(entry.id)
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        basketSwipeOffsets[entry.id] = 0
                    }
                }
            }
    }
    private func productSwipeGesture(for item: ShellMenuItem) -> some Gesture {
        DragGesture(minimumDistance: 18)
            .updating($isHorizontalSwipe) { value, state, _ in
                let dx = value.translation.width
                let dy = value.translation.height
                // ✅ become “active” only for clearly horizontal drags
                if abs(dx) > 28 && abs(dx) > abs(dy) + 10 {
                    state = true
                }
            }
            .onChanged { value in
                guard !isStockEditMode else {
                    productSwipeOffsets[item.id] = 0
                    swipingProductId = nil
                    return
                }

                let dx = value.translation.width
                let dy = value.translation.height

                // ✅ if it’s not horizontal, do NOTHING (let ScrollView scroll)
                guard abs(dx) > 28 && abs(dx) > abs(dy) + 10 else {
                    productSwipeOffsets[item.id] = 0
                    swipingProductId = nil
                    return
                }

                dismissKeyboard()

                swipingProductId = item.id
                let dir: CGFloat = isRtl ? -1 : 1
                productSwipeOffsets[item.id] = dx * dir
            }
            .onEnded { value in
                defer { swipingProductId = nil }

                guard !isStockEditMode else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        productSwipeOffsets[item.id] = 0
                    }
                    return
                }

                let dx = value.translation.width
                let dy = value.translation.height

                // ✅ if it wasn’t horizontal, just reset (scroll already happened)
                guard abs(dx) > 28 && abs(dx) > abs(dy) + 10 else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        productSwipeOffsets[item.id] = 0
                    }
                    return
                }

                let dir: CGFloat = isRtl ? -1 : 1
                let translated = dx * dir
                let commitThreshold: CGFloat = 40

                let remaining = maxAdditionalQuantity(for: item) ?? 1
                let derivedOnFromQty: Bool = {
                    if let q = stockAdjustments[item.id] { return q > 0 } // 0 -> off
                    return true                                           // nil -> ∞ -> on
                }()
                let remainingForItem = maxAdditionalQuantity(for: item)

                

                let isOut: Bool = {
                    guard selectedCategory != "✏️ הערות" else { return false }

                    // ✅ If we have a stock number locally, it wins immediately
                    if let q = stockAdjustments[item.id] {
                        return q <= 0
                    }

                    // ✅ Otherwise fall back to the legacy on/off toggle + remaining
                    return (!stockToggles.isOn(item.id)) || ((remainingForItem ?? 1) <= 0)
                }()
                let canAdd = remaining > 0 && !isOut && selectedCategory != "✏️ הערות"
                let canRemove = quantityInBasket(for: item) > 0

                if translated > commitThreshold, canAdd {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                        productSwipeOffsets[item.id] = 200 * dir
                    }
                    Haptics.light()
                    addToBasket(item: item, quantity: 1, subtitle: nil, unitPrice: item.price)
                } else if translated < -commitThreshold, canRemove {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                        productSwipeOffsets[item.id] = -200 * dir
                    }
                    Haptics.light()
                    removeOneFromLastLine(of: item)
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        productSwipeOffsets[item.id] = 0
                    }
                }
            }
    }
    private var basketTotalPrice: Double {
        basket.values.reduce(0) { $0 + Double($1.quantity) * $1.unitPrice }
    }
    private var excludedAmount: Double {
        let idsToExclude: Set<Int>
        if excludeAllSelected {
            idsToExclude = Set(basket.keys)
        } else {
            idsToExclude = excludedLineIds
        }
        return basket.values
            .filter { idsToExclude.contains($0.id) }
            .reduce(0) { $0 + Double($1.quantity) * $1.unitPrice }
    }

    private var finalTotal: Double {
        let raw = basketTotalPrice - excludedAmount - discountAmount
        guard raw > 0 else { return 0 }

        // No discount → no special rounding, keep normal 2-decimal behaviour
        if discountMode == .none && discountAmount == 0 {
            return raw
        }

        // 🔹 Same idea as OrderFlowView.effectiveTotal:
        // split into shekels + agorot, > 0.50 → round up, else down
        let shekels = floor(raw)
        let agorot = raw - shekels

        let roundedShekels: Double
        if agorot > 0.5 {
            roundedShekels = shekels + 1
        } else {
            roundedShekels = shekels
        }

        return max(roundedShekels, 0)
    }

    private var filteredItems: [ShellMenuItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1) Search across all items
        if !query.isEmpty {
            let q = query
                .folding(options: .diacriticInsensitive, locale: .current)
                .lowercased()

            let base = api.items.filter { item in
                item.name
                    .folding(options: .diacriticInsensitive, locale: .current)
                    .lowercased()
                    .contains(q)
            }

            if isAnyStockEditing {
                return applyFrozenOrder(base)
            }

            return base.sorted { productSortKey($0) < productSortKey($1) }
        }

        // 2) Normal category mode
        guard !selectedCategory.isEmpty else { return [] }

        if selectedCategory == "✏️ הערות" {
            return [
                makeNoteItem(id: -1001, name: "הערה לבר",     stationId: "s2", legacy: "Bar"),
                makeNoteItem(id: -1002, name: "הערה למטבח",   stationId: "s1", legacy: "Kitchen"),
                makeNoteItem(id: -1003, name: "הערה לוטרינה", stationId: "s3", legacy: "Bakery")
            ]
        }

        let base: [ShellMenuItem]

        if selectedCategory == archiveCategoryTitle {
            base = api.items.filter { isArchived($0) }
        } else {
            base = api.items.filter {
                !isArchived($0) && $0.category == selectedCategory
            }
        }

        if isAnyStockEditing {
            return applyFrozenOrder(base)
        }

        return base.sorted { productSortKey($0) < productSortKey($1) }
    }
  

    @ViewBuilder
    private func sideMenuContainer() -> some View {
        ZStack {
            if showSideMenu {
                // 🔹 Dim background
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.spring(response: 0.33, dampingFraction: 0.85)) {
                            showSideMenu = false
                        }
                    }
                    .transition(.opacity)

                // 🔹 Panel pinned to trailing/leading, not center
                HStack(spacing: 0) {
                    if isRtl {
                        sideMenuPanel
                        Spacer()
                    } else {
                        Spacer()
                        sideMenuPanel
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.move(edge: isRtl ? .leading : .trailing))
            }
        }
        .animation(.spring(response: 0.33, dampingFraction: 0.85), value: showSideMenu)
    }

    private func printCustomerLabel() -> String? {
        if let tab = activeTeamTab {
            return tab.titleHe        // 👈 שולחן מנהלים / שולחן בר / etc
        }

        let trimmed = posSavedName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "Customer", with: "")

        return trimmed.isEmpty ? nil : trimmed
    }
    
    private var headerPrinterIconName: String {
        // Not on printer network → neutral
        guard printerMonitor.isNetworkUp else {
            return "printer"
        }

        // On network
        return printerMonitor.allPrintersOnline ? "printer.fill" : "printer"
    }

    private var headerPrinterIconColor: Color {
        // Not on network → gray
        guard printerMonitor.isNetworkUp else {
            return .secondary
        }

        // On network → primary (even if warning badge is shown)
        return .primary
    }
 
    private var sideMenuPanel: some View {
        let menuWidth: CGFloat = 280

        func fullRow(_ title: String, _ systemImage: String, action: @escaping () -> Void) -> some View {
            Button(action: action) {
                HStack(spacing: 10) {
                    Image(systemName: systemImage)
                        .font(.system(size: 18))

                    Text(title)
                        .font(.system(size: 18, weight: .medium))

                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }

        return VStack(alignment: isRtl ? .trailing : .leading, spacing: 0) {

            // 🔒 HEADER (fixed)
            HStack {
                Text("קפה יהושע")
                    .font(.system(size: 22, weight: .bold))

                Spacer()

                Button {
                    withAnimation(.spring(response: 0.33, dampingFraction: 0.85)) {
                        showSideMenu = false
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .bold))
                        .padding(8)
                        .background(Color(.systemGray5))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 10)

            Divider()

            // ✅ SCROLLABLE CONTENT
            ScrollView {
                VStack(alignment: isRtl ? .trailing : .leading, spacing: 0) {
                    if isMiniApp13 {
                       

                        Button {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                                // reuse one of your expand states or create a new one
                                // simplest: toggle a new flag
                                locationsExpanded.toggle()
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "mappin.and.ellipse")
                                    .font(.system(size: 18))
                                Text("מיקום")
                                    .font(.system(size: 18, weight: .medium))
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if locationsExpanded {
                            VStack(alignment: isRtl ? .trailing : .leading, spacing: 0) {
                                ForEach(AdminPickupLocation.allCases) { loc in
                                    Button {
                                        pickupLocationV2 = loc.rawValue
                                        UserDefaults.standard.set(loc.rawValue, forKey: "pickup.location.v2") // belt & braces
                                        Haptics.light()

                                        // optional: if Orders screen already open, you can force refresh there.
                                        // Also optional: auto-close menu:
                                        // showSideMenu = false
                                    } label: {
                                        HStack(spacing: 10) {
                                            Image(systemName: (selectedAdminLocation == loc) ? "checkmark.circle.fill" : "circle")
                                            Text(loc.title)
                                                .font(.system(size: 16, weight: .semibold))
                                            Spacer()
                                        }
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 10)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.leading, isRtl ? 0 : 32)
                            .padding(.trailing, isRtl ? 32 : 0)
                        }
                    }
                    if isTeamTabMode {
                        SideMenuRow(title: "קופה", systemImage: "cart") {
                            Task { @MainActor in
                                backToCashpointFromTeamTab()
                            }
                        }

                        Divider()
                            .padding(.vertical, 6)
                    }
                    
                    SideMenuRow(title: "הזמנות", systemImage: "list.bullet.rectangle") {
                        showSideMenu = false
                        showOrdersAdmin = true
                    }
                    /*
                    SideMenuRow(title: "בונים", systemImage: "square.grid.2x2") {
                        showSideMenu = false
                        showBones = true
                    }
                     */
                    SideMenuRow(title: "בונבונים", systemImage: "square.grid.3x2") {
                        showSideMenu = false
                        showBonbon = true
                    }

                    SideMenuRow(title: "פתח מגירה", systemImage: "tray") {
                        PrinterManager.shared.openCashDrawer()
                    }
                    
                    if canManageAdmins {
                        SideMenuRow(title: "מנהלים ומכשירים", systemImage: "person.badge.key") {
                            showSideMenu = false
                            showAdminsDevices = true
                        }
                    }
                   
                    SideMenuRow(title: "זיכוי לקוח", systemImage: "arrow.uturn.left.circle.fill") {
                        showSideMenu = false
                        refundInput = ""
                        showRefundFlow = true
                    }

                    // 🔽 TEAM TABS
                    Button {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                            teamTabsExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "person.2")
                                .font(.system(size: 18))
                            Text("שולחנות צוות")
                                .font(.system(size: 18, weight: .medium))
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if teamTabsExpanded {
                        VStack(alignment: isRtl ? .trailing : .leading, spacing: 0) {
                            teamTabSubRow(.manager)
                            teamTabSubRow(.conditur)
                            teamTabSubRow(.kitchen)
                            teamTabSubRow(.floor)
                        }
                        .padding(.leading, isRtl ? 0 : 32)
                        .padding(.trailing, isRtl ? 32 : 0)
                    }

                    // 🔽 REPORTS
                    Button {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                            reportsExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "doc.text.magnifyingglass")
                                .font(.system(size: 18))
                            Text("דוחות")
                                .font(.system(size: 18, weight: .medium))
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if reportsExpanded {
                        VStack(alignment: isRtl ? .trailing : .leading, spacing: 0) {
                            fullRow("דוח X", "doc.text") {
                                showSideMenu = false
                                prepareReportPreview(for: .x)
                            }
                            fullRow("דוח Z", "printer") {
                                showSideMenu = false
                                showZReportDialog = true
                            }
                        }
                        .padding(.leading, isRtl ? 0 : 32)
                        .padding(.trailing, isRtl ? 32 : 0)
                    }

                    // 🔽 PINPADS
                    Button {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                            pinpadsExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "creditcard")
                                .font(.system(size: 18))
                            Text("מסופי אשראי")
                                .font(.system(size: 18, weight: .medium))
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if pinpadsExpanded {
                        VStack(alignment: isRtl ? .trailing : .leading, spacing: 0) {

                            // ✅ NEW: no-terminal option (saves empty string)
                            Button {
                                showSideMenu = false
                                setPinpadAndPing(NO_TERMINAL_PINPAD)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: currentPinpadId == NO_TERMINAL_PINPAD ? "checkmark.circle.fill" : "circle")
                                    Text("ללא מסוף")
                                        .font(.system(size: 16, weight: .semibold))
                                    Spacer()
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            // existing terminals
                            ForEach(pinpads, id: \.id) { item in
                                Button {
                                    showSideMenu = false
                                    setPinpadAndPing(item.id)
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: item.id == currentPinpadId
                                              ? "checkmark.circle.fill"
                                              : "circle")
                                        Text(item.title)
                                            .font(.system(size: 16, weight: .semibold))
                                        Spacer()
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.leading, isRtl ? 0 : 32)
                        .padding(.trailing, isRtl ? 32 : 0)
                    }

                    fullRow("הנחת סטודנטים", "graduationcap.fill") {
                        showSideMenu = false
                        showStudentHandshakeSheet = true
                    }
                 
                    VStack(spacing: 0) {
                        HStack(spacing: 10) {
                            Image(systemName: mobileIsOpen ? "lock.open" : "lock")
                                .font(.system(size: 18))

                            Text("הזמנות מהאפליקציה")
                                .font(.system(size: 18, weight: .medium))

                            Spacer()

                            if mobileToggleBusy {
                                ProgressView().scaleEffect(0.8)
                            } else {
                                Toggle("", isOn: Binding(
                                    get: { api.isOpen },
                                    set: { newVal in
                                        if newVal == false {
                                            confirmCloseMobile = true
                                            return
                                        }

                                        // optimistic
                                        api.isOpen = true
                                        Haptics.light()
                                        setMiniAppOpen(true)
                                    }
                                ))
                                .labelsHidden()
                                .tint(.blue)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)

                        Text(mobileIsOpen ? "פתוח להזמנות" : "סגור — רק קופה")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 10)
                    }
                    .confirmationDialog(
                        "לסגור הזמנות מהטלפון?",
                        isPresented: $confirmCloseMobile,
                        titleVisibility: .visible
                    ) {
                        Button("סגור הזמנות", role: .destructive) {
                            mobileIsOpen = false
                            Haptics.light()
                            setMiniAppOpen(false)
                        }
                        Button("בטל", role: .cancel) {
                            mobileIsOpen = true
                        }
                    }
                    
                    fullRow("קופת שירות עצמי", "person.fill") {
                        Task { @MainActor in
                            cashPointMode = false                 // ✅ persist via AppStorage
                            UserDefaults.standard.set(false, forKey: AppSettings.Key.cashPointMode) // (optional safety)
                            Haptics.success()
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                showSideMenu = false
                            }
                            // If this view was presented modally and you want to go back to menu/home immediately:
                            // dismiss()
                        }
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 24) // ✅ breathing room at bottom
            }
        }
        .frame(width: menuWidth)
        .frame(maxHeight: .infinity)
        .background(Color(.systemBackground))
        .shadow(color: .black.opacity(0.3), radius: 12, x: -6, y: 0)
    }
    
    @ViewBuilder
    private func teamTabSubRow(_ tab: TabType) -> some View {
        Button {
            showSideMenu = false
            openTeamTab(tab)   // ✅ your function from earlier
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "table.furniture")
                    .font(.system(size: 16))

                Text(tab.titleHe)
                    .font(.system(size: 16))

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }
    
    private func ensureSelectedCategoryIsValid() {
        let first = categoryOrder.first(where: { $0 != "✏️ הערות" }) ?? categories.first
        guard let first else { return }

        if selectedCategory.isEmpty || !categoryOrder.contains(selectedCategory) {
            selectedCategory = first
        }
    }
    
    @ViewBuilder
    private func reportSubRow(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if !isRtl {
                    Image(systemName: systemImage)
                        .font(.system(size: 16))
                }

              

                if isRtl {
                    Image(systemName: systemImage)
                        .font(.system(size: 16))
                }

                Text(title)
                    .font(.system(size: 16))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }
    
    private func prepareReportPreview(for type: ReportType) {
        if type == .z {
            zRestoreMode = false   // ✅ IMPORTANT
            showEODWizard = true
            return
        }

        // X preview
        zRestoreMode = false       // ✅ IMPORTANT (avoid sticky restore)
        reportData = buildSalesReportData(for: type)
        activeReportType = type
    }
    /*
    /// Build the textual preview and open the sheet
    private func prepareReportPreview(for type: ReportType) {
        let shopId = Int(UserDefaults.standard.string(forKey: "shopId") ?? "12") ?? 12

        // Always allow X preview
        guard type == .z else {
            reportData = buildSalesReportData(for: type)
            activeReportType = type
            return
        }

        // Z preview: gate by open orders
        Task {
            do {
                let res = try await ZPrecheckAPI.fetch(miniAppId: shopId)

                await MainActor.run {
                    if res.openCount > 0 {
                        // ✅ Block Z and open EOD admin cleanup
                        adminMode = .endOfDay
                        showOrdersAdmin = true
                        Haptics.error()
                    } else {
                        // ✅ No open orders → show Z preview
                        reportData = buildSalesReportData(for: type)
                        activeReportType = type
                    }
                }
            } catch {
                // If precheck fails, safest: don’t allow Z
                print("❌ z precheck failed:", error.localizedDescription)
                await MainActor.run {
                    adminMode = .endOfDay
                    showOrdersAdmin = true
                    Haptics.error()
                }
            }
        }
    }
     */
    private func printXReport() {
        // TODO: hook your real X-report logic here
        print("🧾 Printing X report…")
    }

    private func printZReport() {
        // TODO: hook your real Z-report logic here
        print("🧾 Printing Z report…")
    }

    private struct SideMenuRow: View {
        let title: String
        let systemImage: String
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                HStack(spacing: 10) {
                    Image(systemName: systemImage)
                        .font(.system(size: 18))
                    Text(title)
                        .font(.system(size: 18, weight: .medium))
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
    
    private var cashpointHeaderTitle: String {
        if let tab = activeTeamTab {
            // Use the actual table name: שולחן מנהלים / שולחן בר / וכו'
            return tab.titleHe
        }
        return "קופה"
    }
    
    @ViewBuilder
    private func discountPill(title: String, mode: DiscountMode) -> some View {
        let isSelected = (discountMode == mode)
        Button {
            discountMode = mode
            debugDiscount("pill:\(title)")
        } label: {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    isSelected
                        ? (colorScheme == .dark ? .white : .black)
                        : Color(.systemGray5)
                )
                .foregroundColor(
                    isSelected
                        ? (colorScheme == .dark ? .black : .white)
                        : .primary
                )
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
    
    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    let isPhone = isPhoneLayout
                    
                    // MARK: - Responsive Header
                    Group {
                        if isPhone {
                            // 📱 iPhone: compact 2-row header
                            VStack(alignment: .leading, spacing: 8) {
                                // Row 1: Title + Stock
                                // Row 1: Header buttons + centered title
                                ZStack {
                                    // base row
                                    HStack(spacing: 12) {
                                       

                                        Button {
                                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                                showSideMenu.toggle()
                                            }
                                        } label: {
                                            Image(systemName: "line.3.horizontal")
                                                .font(.system(size: 20, weight: .bold))
                                                .padding(8)
                                                .clipShape(Circle())
                                        }

                                        Button {
                                            showPrinterStatusSheet = true
                                        } label: {
                                            ZStack(alignment: .topTrailing) {
                                                Image(systemName: headerPrinterIconName)
                                                    .font(.system(size: 18, weight: .bold))
                                                    .foregroundColor(headerPrinterIconColor)
                                                    .padding(8)
                                                    .background((printerMonitor.isNetworkUp && printerMonitor.anyPrinterOffline) ? Color(.systemGray5) : .clear)
                                                    .clipShape(Circle())

                                                if printerMonitor.isNetworkUp && printerMonitor.anyPrinterOffline {
                                                    Image(systemName: "exclamationmark.circle.fill")
                                                        .font(.system(size: 12, weight: .bold))
                                                        .foregroundColor(.black)
                                                        .background(Color(.systemBackground))
                                                        .clipShape(Circle())
                                                        .offset(x: 4, y: -4)
                                                }
                                            }
                                        }
                                        .buttonStyle(.plain)

                                        Spacer()

                                
                                            HStack(spacing: 8) {

                                                // ✅ Category-wide אפס / אינסוף (same as iPad branch)
                                                if isStockEditMode,
                                                   !selectedCategory.isEmpty,
                                                   selectedCategory != "✏️ הערות" {

                                                    let isZeroed = isCategoryZeroed(selectedCategory)

                                                    Button {
                                                        let items = api.items.filter { $0.category == selectedCategory }
                                                        guard !items.isEmpty else { return }

                                                        if isZeroed {
                                                            // אינסוף
                                                            for item in items {
                                                                stockAdjustments[item.id] = nil
                                                                stockText[item.id] = nil
                                                                dirtyStockIds.insert(item.id)
                                                                applyLocalAvailabilityFromStock(productId: item.id)
                                                            }
                                                        } else {
                                                            // אפס
                                                            for item in items {
                                                                stockAdjustments[item.id] = 0
                                                                stockText[item.id] = nil
                                                                dirtyStockIds.insert(item.id)
                                                                applyLocalAvailabilityFromStock(productId: item.id)
                                                            }
                                                        }

                                                        Haptics.light()
                                                    } label: {
                                                        Text(isZeroed ? "אינסוף" : "אפס")
                                                            .font(.system(size: 14, weight: .semibold))
                                                            .padding(.horizontal, 10)
                                                            .padding(.vertical, 6)
                                                            .background(Color(.systemGray5))
                                                            .clipShape(Capsule())
                                                    }
                                                    .buttonStyle(.plain)
                                                }

                                                // ✅ מלאי / סיים
                                                Button {
                                                    if isStockEditMode {
                                                        Task { await flushDirtyStockAndExit() }
                                                    } else {
                                                        var t = Transaction()
                                                        t.disablesAnimations = true
                                                        withTransaction(t) { isStockEditMode = true }
                                                    }
                                                } label: {
                                                    Text(isRtl ? (isStockEditMode ? "סיים" : "מלאי")
                                                               : (isStockEditMode ? "Done" : "Stock"))
                                                        .font(.system(size: 14, weight: .semibold))
                                                        .padding(.horizontal, 12)
                                                        .padding(.vertical, 6)
                                                        .background(Color(.systemGray5))
                                                        .clipShape(Capsule())
                                                }
                                                .buttonStyle(.plain)
                                                .disabled(stockCommitInFlight)
                                                .padding(.trailing, 40)
                                            }
                                        
                                    }

                                    // ✅ centered "nav bar" title
                                    Text(cashpointHeaderTitle)
                                        .font(.system(size: 18, weight: .bold))
                                        .foregroundColor(.primary)
                                        .lineLimit(1)
                                        .allowsHitTesting(false)
                                        .contentTransition(.interpolate)
                                        .animation(.easeInOut(duration: 0.25),
                                                   value: cashpointHeaderTitle)
                                }
                                
                                // Row 2: Search + compact "+"
                                HStack(spacing: 10) {

                                    // SEARCH
                                    HStack(spacing: 8) {

                                        if !isRtl {
                                            Image(systemName: "magnifyingglass")
                                                .foregroundColor(.secondary)
                                        }

                                        ZStack(alignment: isRtl ? .trailing : .leading) {

                                            // ✅ Placeholder follows RTL
                                            if searchText.isEmpty {
                                                Text(isRtl ? "חיפוש מוצר…" : "Search product…")
                                                    .foregroundColor(.secondary)
                                                    .padding(isRtl ? .trailing : .leading, 6)
                                                    .frame(maxWidth: .infinity,
                                                           alignment: isRtl ? .trailing : .leading)
                                            }

                                            TextField("", text: $searchText)
                                                .textInputAutocapitalization(.none)
                                                .autocorrectionDisabled()
                                                .focused($isSearchFocused)
                                                .multilineTextAlignment(isRtl ? .trailing : .leading)   // ✅ key line
                                                .frame(maxWidth: .infinity,
                                                       alignment: isRtl ? .trailing : .leading)
                                        }

                                        if isRtl {
                                            Image(systemName: "magnifyingglass")
                                                .foregroundColor(.secondary)
                                        }

                                        if !searchText.isEmpty {
                                            Button { searchText = "" } label: {
                                                Image(systemName: "xmark.circle.fill")
                                                    .foregroundColor(.secondary)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 10)
                                    .background(Color(.secondarySystemBackground))
                                    .clipShape(RoundedRectangle(cornerRadius: 12))

                                    Button {
                                        Haptics.light()

                                        let defaultCategory =
                                            selectedCategory.isEmpty
                                            ? (api.items.first?.category ?? (isRtl ? "כללי" : "General"))
                                            : selectedCategory

                                        adminDraft = AdminProductDraft(
                                            productId: nil,
                                            name: "",
                                            priceText: "0",
                                            category: defaultCategory,
                                            description: "",
                                            imageURL: "https://d25t2285lxl5rf.cloudfront.net/images/shops/28596.png",
                                            modifierGroups: [],
                                            printerId: defaultPrinterId()        // ✅ NEW
                                        )
                                    } label: {
                                        Image(systemName: "plus.circle.fill")
                                            .font(.system(size: 28, weight: .semibold))
                                            .foregroundColor(.primary)
                                            .padding(6)                 // ✅ bigger hit area
                                            .contentShape(Rectangle())  // ✅ whole area tappable
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                            .padding(.bottom, 8)
                            
                        } else {
                            // 💻 iPad / Mac: your original header
                            HStack(spacing: 12) {
                                // Title on the left
                                Button {
                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                            showSideMenu.toggle()
                                        }
                                    } label: {
                                        Image(systemName: "line.3.horizontal")
                                            .font(.system(size: 20, weight: .bold))
                                            .padding(8)
                                            
                                            .clipShape(Circle())
                                    }
                                
                                
                                Button {
                                    showPrinterStatusSheet = true
                                } label: {
                                    ZStack(alignment: .topTrailing) {

                                        // MAIN ICON
                                        Image(systemName: headerPrinterIconName)
                                            .font(.system(size: 18, weight: .bold))
                                            .foregroundColor(headerPrinterIconColor)
                                            .padding(8)
                                            .background(( printerMonitor.isNetworkUp && printerMonitor.anyPrinterOffline) ?  Color(.systemGray5) : .clear)
                                            .clipShape(Circle())

                                        // ⚠️ WARNING BADGE — only when on network AND some printers offline
                                        if printerMonitor.isNetworkUp && printerMonitor.anyPrinterOffline {
                                            Image(systemName: "exclamationmark.circle.fill")
                                                .font(.system(size: 12, weight: .bold))
                                                .foregroundColor(.black)
                                                .background(Color(.systemBackground))
                                                .clipShape(Circle())
                                                .offset(x: 4, y: -4)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                                    
                                    // Spacer before search
                                    Spacer()
                                        .frame(maxWidth: 70)
                                
                                // Search field roughly aligned with the middle products column
                                // Search field (iPad) — full hit area + RTL placeholder
                                HStack(spacing: 8) {
                                    Image(systemName: "magnifyingglass")
                                        .foregroundColor(.secondary)

                                    ZStack(alignment: isRtl ? .trailing : .leading) {

                                        // ✅ placeholder aligned RTL/LTR
                                        if searchText.isEmpty {
                                            Text(isRtl ? "חיפוש מוצר…" : "Search product…")
                                                .foregroundColor(.secondary)
                                            
                                                .frame(maxWidth: .infinity,
                                                       alignment: isRtl ? .leading : .leading)
                                        }

                                        // ✅ the actual field fills the whole pill (so tap works everywhere)
                                        TextField("", text: $searchText)
                                            .textInputAutocapitalization(.none)
                                            .autocorrectionDisabled()
                                            .focused($isSearchFocused)
                                            .multilineTextAlignment(isRtl ? .trailing : .leading)
                                            .frame(maxWidth: .infinity,
                                                   alignment: isRtl ? .leading : .leading)
                                    }

                                        
                                    if !searchText.isEmpty {
                                        Button { searchText = "" } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundColor(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color(.secondarySystemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .frame(maxWidth: 240)
                                .contentShape(Rectangle())            // ✅ whole pill clickable
                                .onTapGesture { isSearchFocused = true } // ✅ tap anywhere focuses
                                .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
                                
                                Spacer()
                                
                                // New product button
                                Button {
                                    let defaultCategory =
                                    selectedCategory.isEmpty
                                    ? (api.items.first?.category ?? (isRtl ? "כללי" : "General"))
                                    : selectedCategory
                                    
                                    adminDraft = AdminProductDraft(
                                        productId: nil,
                                        name: "",
                                        priceText: "0",
                                        category: defaultCategory,
                                        description: "",
                                        imageURL: "https://d25t2285lxl5rf.cloudfront.net/images/shops/28596.png",
                                        modifierGroups: [],
                                        printerId: defaultPrinterId()        // ✅ NEW
                                    )
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "plus.circle.fill")
                                        Text(isRtl ? "מוצר חדש" : "New product")
                                    }
                                    .font(.system(size: 14, weight: .semibold))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color(.systemGray5))
                                    .clipShape(Capsule())
                                }
                                
                                if isStockEditMode,
                                   !selectedCategory.isEmpty,
                                   selectedCategory != "✏️ הערות" {
                                    let isZeroed = isCategoryZeroed(selectedCategory)

                                    Button {
                                        let items = api.items.filter { $0.category == selectedCategory }
                                        guard !items.isEmpty else { return }

                                        if isZeroed {
                                            // אינסוף
                                            for item in items {
                                                stockAdjustments[item.id] = nil
                                                dirtyStockIds.insert(item.id)
                                            }
                                        } else {
                                            // אפס
                                            for item in items {
                                                stockAdjustments[item.id] = 0
                                                dirtyStockIds.insert(item.id)
                                            }
                                        }

                                        Haptics.light()
                                    } label: {
                                        Text(isZeroed ? "אינסוף" : "אפס")
                                            .font(.system(size: 14, weight: .semibold))
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 6)
                                            .background(Color(.systemGray5))
                                            .clipShape(Capsule())
                                    }
                                    .padding(.trailing, 50)
                                }
                                // Stock mode toggle
                                Button {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                        isStockEditMode.toggle()
                                        if isStockEditMode {
                                            stockEditWorkItem?.cancel()
                                            stockEditWorkItem = nil
                                            editingStockProductId = nil
                                        }
                                    }
                                } label: {
                                    Text(isRtl
                                         ? (isStockEditMode ? "סיים" : "מלאי")
                                         : (isStockEditMode ? "Done" : "Stock"))
                                    .font(.system(size: 14, weight: .semibold))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color(.systemGray5))
                                    .clipShape(Capsule())
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                            .padding(.bottom, 15)
                        }
                    }
                    
                    Divider()
                    
                    // MARK: - Main content
                    HStack(spacing: 0) {

                        // ⬅️ CATEGORY RAIL (hide on iPhone during stock edit)
                        if showCategoryRailOnPhone {
                            ZStack(alignment: .bottom) {

                                CashCategoryRail(
                                    categories: categories,
                                    selected: selectedCategory,
                                    onTap: { cat in
                                        searchText = ""
                                        isSearchFocused = false
                                        selectedCategory = cat
                                    },
                                    onOrdersTap: { showOrdersAdmin = true },
                                    enableReorder: true,
                                    draggingCategory: $draggingCategory,
                                    categoryOrder: $categoryOrder,
                                    renamingCategory: $renamingCategory,
                                    renamingText: $renamingText,
                                    draggingProduct: $draggingProduct,
                                    onRenameCommit: { oldName, newName in
                                        applyLocalCategoryRename(oldName: oldName, newName: newName)
                                        renameCategoryOnServer(oldName: oldName, newName: newName)
                                    },
                                    onProductDroppedToCategory: { productId, targetCategory in
                                        moveProductToCategory(productId: productId, newCategory: targetCategory)
                                    },
                                    onReorderCommitted: {
                                        persistCategoryOrder()
                                        sendCategoryOrderToServer()

                                        if !categoryOrder.contains(selectedCategory),
                                           let first = categoryOrder.first {
                                            selectedCategory = first
                                        }
                                    }
                                )
                                if isPad{
                                    VStack(spacing: 8) {
                                        if !isMiniApp13 {
                                            
                                          //  printBacklogHUD()
                                        }
                                        
                                        if showLastInvoicePrompt,
                                           let title = lastInvoicePromptTitle(),
                                           let snapshot = lastOrder {
                                            LastInvoicePill(
                                                isRtl: isRtl,
                                                title: title,
                                                onPrint: { printInvoice(for: snapshot) },
                                                onClose: { showLastInvoicePrompt = false }
                                            )
                                        }
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.bottom, 8)
                                }
                            }
                            .frame(width: 190)
                            .transition(
                                .move(edge: isRtl ? .trailing : .leading)
                                .combined(with: .opacity)
                            )
                        }

                        if showCategoryRailOnPhone {
                            Divider()
                                .transition(.opacity)
                        }
                        
                        GeometryReader { geo in

                            // ✅ iOS 16+: disable scroll ONLY while a horizontal swipe is active
                            if #available(iOS 16.0, *) {

                                ScrollView {
                                    LazyVStack(spacing: 8) {
                                        ForEach(filteredItems) { item in
                                            let qty: Int = {
                                                if isTeamTabMode {
                                                    return freshQuantityInBasket(for: item)   // ✅ only fresh lines
                                                } else {
                                                    return quantityInBasket(for: item)        // ✅ normal behaviour
                                                }
                                            }()
                                            let remainingForItem = maxAdditionalQuantity(for: item)

                                            let isOut: Bool = {
                                                guard selectedCategory != "✏️ הערות" else { return false }

                                                // ✅ If we have a stock number locally, it wins immediately
                                                if let q = stockAdjustments[item.id] {
                                                    return q <= 0
                                                }

                                                // ✅ Otherwise fall back to the legacy on/off toggle + remaining
                                                return (!stockToggles.isOn(item.id)) || ((remainingForItem ?? 1) <= 0)
                                            }()

                                            let stockAmount = stockAdjustments[item.id]
                                            let isEditingStock = editingStockProductId == item.id
                                            let showFullStockUI = isStockEditMode || isEditingStock

                                            let swipeOffset = productSwipeOffsets[item.id] ?? 0

                                            let tile =
                                            ZStack(alignment: .topTrailing) {

                                                // 🔹 MAIN CARD (no Button)
                                                CashProductTile(
                                                    item: item,
                                                    quantityInBasket: qty > 0 ? qty : nil,
                                                    isOutOfStock: isOut,
                                                    isArchived: isArchived(item)
                                                )
                                                .scaleEffect(tappedProductId == item.id ? 0.96 : 1.0)

                                                // ✅ tap layer (adds product), but DISABLED while stock UI is shown
                                                .overlay(
                                                    Color.clear
                                                        .contentShape(Rectangle())
                                                        .onTapGesture {

                                                            // ✅ If any single-item stock editor is open:
                                                            // tap another row -> commit+close, and do NOT add-to-basket
                                                            if let editing = editingStockProductId {
                                                                if editing != item.id {
                                                                    Task { await commitSingleStockAndClose(editing) }
                                                                }
                                                                return
                                                            }

                                                            // existing guards
                                                            guard !isStockEditMode else { return }
                                                            guard swipingProductId == nil else { return }

                                                            let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                                                            let wasSearching = !q.isEmpty

                                                            if wasSearching, item.category != "✏️ הערות" {
                                                                selectedCategory = item.category
                                                            }

                                                            // now clear search UI
                                                            searchText = ""
                                                            isSearchFocused = false
                                                            
                                                            searchText = ""
                                                            isSearchFocused = false

                                                            if selectedCategory == "✏️ הערות" {
                                                                // Map the hard-coded note items to targets
                                                                messageTargetIsKitchen = (item.id == -1002)
                                                                messageTargetIsBakery  = (item.id == -1003)

                                                                // Reset fields
                                                                messageText = ""
                                                                messagePrice = ""

                                                                // ✅ kill any focus/keyboard BEFORE presenting the sheet
                                                                dismissKeyboard()

                                                                // Show sheet
                                                                showMessageSheet = true
                                                                Haptics.light()
                                                                return
                                                            }

                                                            guard !isOut else { Haptics.error(); return }
                                                            if let maxAdd = maxAdditionalQuantity(for: item), maxAdd <= 0 { Haptics.error(); return }

                                                            withAnimation(.spring(response: 0.18, dampingFraction: 0.6, blendDuration: 0.1)) {
                                                                tappedProductId = item.id
                                                            }
                                                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                                                withAnimation(.spring(response: 0.25, dampingFraction: 0.7, blendDuration: 0.1)) {
                                                                    tappedProductId = nil
                                                                }
                                                            }

                                                            Haptics.light()
                                                            addToBasket(item: item, quantity: 1, subtitle: nil, unitPrice: item.price)
                                                        }
                                                        // ✅ KEY LINE: when stock UI is visible, this overlay stops receiving taps
                                                        .allowsHitTesting(!showFullStockUI)
                                                )
                                                .contextMenu {
                                                    Group {
                                                        // ✅ Edit product (existing)
                                                        Button("ערוך מוצר") {
                                                            adminDraft = makeAdminDraft(from: item)
                                                        }
                                                        Button("שכפל מוצר") {
                                                                   let dup = makeDuplicateDraft(from: item)

                                                                   // Option A (recommended): open editor so you can tweak before saving
                                                                   adminDraft = dup

                                                                   // Option B (instant duplicate, no editor):
                                                                   // applyAdminSave(dup)
                                                               }
                                                        // ✅ NEW: Edit stock for this specific product
                                                        Button("ערוך מלאי") {
                                                            var t = Transaction()
                                                            t.disablesAnimations = true
                                                            withTransaction(t) {
                                                                startSingleStockEdit(productId: item.id)
                                                            }
                                                        }
                                                    }
                                                    .environment(\.layoutDirection, .rightToLeft)
                                                }
                                                // 🔹 STOCK UI (unchanged)
                                                let isEditingThisStock = isStockEditMode || editingStockProductId == item.id

                                                if showFullStockUI {
                                                    HStack(spacing: 6) {
                                                        Button {
                                                            bumpStockAmount(productId: item.id, delta: -1)
                                                            
                                                        } label: {
                                                            Image(systemName: "minus")
                                                                .font(.system(size: 13, weight: .bold))
                                                                .foregroundColor(.primary)
                                                                .frame(width: 26, height: 26)
                                                                .background(Color(.systemGray5))
                                                                .clipShape(Circle())
                                                        }
                                                        .buttonStyle(.plain)


                                                        if isEditingThisStock {
                                                            TextField(
                                                                "∞",
                                                                text: Binding(
                                                                    get: {
                                                                        if let q = stockAdjustments[item.id], q <= 0 { return "0" }

                                                                        if let existing = stockText[item.id] { return existing }
                                                                        if let current = remainingStock(for: item) { return String(current) }
                                                                        return ""
                                                                    },
                                                                    set: { newValue in
                                                                        stockText[item.id] = newValue
                                                                        updateStockFromKeyboard(productId: item.id, raw: newValue)
                                                                    }
                                                                )
                                                            )
                                                            .keyboardType(.numberPad)
                                                            .multilineTextAlignment(.center)
                                                            .font(.system(size: 16, weight: .bold))
                                                            .frame(width: 50)
                                                            .padding(.horizontal, 4)
                                                            .padding(.vertical, 4)
                                                            .background(Color(.systemGray6))
                                                            .cornerRadius(6)
                                                            .focused($focusedStockProductId, equals: item.id)
                                                            .onChange(of: focusedStockProductId) { focusedId in
                                                                guard focusedId == item.id else { return }
                                                                DispatchQueue.main.async {
                                                                    UIApplication.shared.sendAction(
                                                                        #selector(UIResponder.selectAll(_:)),
                                                                        to: nil,
                                                                        from: nil,
                                                                        for: nil
                                                                    )
                                                                }
                                                            }

                                                        } else {
                                                            Text(stockLabel(for: stockAmount, isOutOfStock: isOut))
                                                                .font(.system(size: 16, weight: .bold))
                                                                .foregroundColor(.primary)
                                                                .frame(width: 28)
                                                        }

                                                        Button {
                                                            bumpStockAmount(productId: item.id, delta: +1)
                                                           
                                                        } label: {
                                                            Image(systemName: "plus")
                                                                .font(.system(size: 13, weight: .bold))
                                                                .foregroundColor(.primary)
                                                                .frame(width: 26, height: 26)
                                                                .background(Color(.systemGray5))
                                                                .clipShape(Circle())
                                                        }
                                                        .buttonStyle(.plain)
                                                    }
                                                    
                                                    .padding(6)
                                                    .background(
                                                        RoundedRectangle(cornerRadius: 12)
                                                            .fill(Color(.systemBackground))
                                                            .shadow(color: .black, radius: 4, y: 2)
                                                    )
                                                    .padding(6)

                                                } else if !isOut, let remaining = remainingForItem, remaining > 0 {
                                                    Text("(\(remaining))")
                                                        .font(.system(size: 13, weight: .bold))
                                                        .foregroundColor(.primary)
                                                        .frame(height: 24)
                                                        .padding(6)
                                                }
                                            }

                                            // ✅ Always apply the offset (this was missing in your snippet)
                                            let baseTile = tile.offset(x: swipeOffset)

                                            // ✅ Swipe enabled on BOTH phone + iPad
                                            let swipeableTile = baseTile
                                                .simultaneousGesture(productSwipeGesture(for: item))

                                            if 1==2 {
                                                swipeableTile
                                            } else {
                                                swipeableTile
                                                    .onDrag {
                                                        draggingProduct = item
                                                        return NSItemProvider(object: "\(item.id)" as NSString)
                                                    }
                                                    .onDrop(
                                                        of: [.text],
                                                        delegate: ProductDropDelegate(
                                                            target: item,
                                                            items: $api.items,
                                                            category: selectedCategory,
                                                            dragging: $draggingProduct,
                                                            onReorderCommitted: { movedId, newIndex, cat in
                                                                sendReorderToServer(movedId: movedId, newIndex: newIndex, category: cat)
                                                            }
                                                        )
                                                    )
                                            }
                                        }
                                    }
                                    .padding(16)
                                    .padding(.bottom, isPhoneLayout ? 100 : 0)
                                }
                                .scrollDisabled(isHorizontalSwipe)   // ✅ key line (iOS16+)

                            } else {
                                // iOS 15 fallback: swipe still works, but we can’t scroll-disable during swipe.
                                // (Usually OK, but iOS16+ is the ideal behaviour.)
                                ScrollView {
                                    LazyVStack(spacing: 8) {
                                        ForEach(filteredItems) { item in
                                            let qty   = quantityInBasket(for: item)
                                            let remainingForItem = maxAdditionalQuantity(for: item)

                                            let isOut: Bool = {
                                                guard selectedCategory != "✏️ הערות" else { return false }

                                                // ✅ If we have a stock number locally, it wins immediately
                                                if let q = stockAdjustments[item.id] {
                                                    return q <= 0
                                                }

                                                // ✅ Otherwise fall back to the legacy on/off toggle + remaining
                                                return (!stockToggles.isOn(item.id)) || ((remainingForItem ?? 1) <= 0)
                                            }()

                                            let stockAmount = stockAdjustments[item.id]
                                            let isEditingStock = editingStockProductId == item.id
                                            let showFullStockUI = isStockEditMode || isEditingStock

                                            let swipeOffset = productSwipeOffsets[item.id] ?? 0

                                            let tile =
                                            ZStack(alignment: .topTrailing) {
                                                CashProductTile(
                                                    item: item,
                                                    quantityInBasket: qty > 0 ? qty : nil,
                                                    isOutOfStock: isOut,
                                                    isArchived: isArchived(item)
                                                )
                                                // keep same tap/context menu/stock UI as above…
                                            }

                                            let baseTile = tile.offset(x: swipeOffset)
                                            let swipeableTile = baseTile
                                                .simultaneousGesture(productSwipeGesture(for: item))

                                            if isPhoneLayout {
                                                swipeableTile
                                            } else {
                                                swipeableTile
                                                    .onDrag {
                                                        draggingProduct = item
                                                        return NSItemProvider(object: "\(item.id)" as NSString)
                                                    }
                                                    .onDrop(
                                                        of: [.text],
                                                        delegate: ProductDropDelegate(
                                                            target: item,
                                                            items: $api.items,
                                                            category: selectedCategory,
                                                            dragging: $draggingProduct,
                                                            onReorderCommitted: { movedId, newIndex, cat in
                                                                sendReorderToServer(movedId: movedId, newIndex: newIndex, category: cat)
                                                            }
                                                        )
                                                    )
                                            }
                                        }
                                    }
                                    .padding(16)
                                    .padding(.bottom, isPhoneLayout ? 100 : 0)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .sheet(isPresented: $showStudentHandshakeSheet) {
                            StudentHandshakeWebSheet(url: URL(string: "https://minis.studio/handshake")!)
                                .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
                        }
                       
                        .sheet(isPresented: $showTeamTabsSheet) {
                            TeamTabsSheet { tab in
                                showTeamTabsSheet = false
                                openTeamTab(tab)
                            }
                            .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
                        }
                        .sheet(isPresented: $showPrinterStatusSheet) {
                            PrinterStatusSheet(
                                isRtl: isRtl,
                                monitor: printerMonitor,
                                onTestPrint: {
                                    // ✅ replace with your real test bone print
                                    Task { await printerMonitor.testPrintAllReachable() }

                                    // PrinterManager.shared.printTestBone()
                                }
                            )
                            .presentationDetents([.medium, .large])
                            .presentationDragIndicator(.hidden)
                            .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
                        }
                        .sheet(isPresented: $showMessageSheet) {
                            MessageSheet(
                                isRtl: isRtl,
                                targetIsKitchen: messageTargetIsKitchen,
                                targetIsBakery: messageTargetIsBakery,
                                text: $messageText,
                                priceText: $messagePrice
                            ) { text, price in

                                // ✅ Title / label
                                let name: String
                                if messageTargetIsKitchen {
                                    name = "הערה למטבח"
                                } else if messageTargetIsBakery {
                                    name = "הערה לוטרינה"
                                } else {
                                    name = "הערה לבר"
                                }

                                // ✅ Route by station id:
                                // s1 = Kitchen, s2 = Bar, s3 = Bakery/Vitrine
                                let stationId: String = {
                                    if messageTargetIsKitchen { return "s1" }
                                    if messageTargetIsBakery  { return "s3" }
                                    return "s2"
                                }()

                                let item = ShellMenuItem(
                                    id: Int.random(in: -9000 ... -8000),
                                    name: name,
                                    price: price,
                                    category: "✏️ הערות",      // ✅ keep consistent with your notes category
                                    modifiers: nil,
                                    imageURL: nil,
                                    description: nil,
                                    status: 1,
                                    stockQuantity: nil,

                                    // ✅ IMPORTANT: send to the right printer(s)
                                    printer: stationId,         // primary station
                                    printers: [stationId]       // explicit list (PrinterIds)
                                )

                                addToBasket(
                                    item: item,
                                    quantity: 1,
                                    subtitle: text,
                                    unitPrice: price
                                )

                                messageTargetIsKitchen = false
                                messageTargetIsBakery  = false
                            }
                            .presentationDetents([.height(280)])
                            .presentationDragIndicator(.hidden)
                        }
                        Divider()
                        
                        if !isPhone {
                                                   if !isStockEditMode {
                                                       basketPanel(inline: true)
                                                           .transition(
                                                               .move(edge: isRtl ? .leading : .trailing)
                                                               .combined(with: .opacity)
                                                           )
                                                   }
                                               }
                    }
                }
                .navigationBarHidden(true)
                .navigationBarBackButtonHidden(true)          // ✅ kills the default iOS back chevron
                .toolbar(.hidden, for: .navigationBar)        // ✅ hides the whole nav bar (extra safety)
                
                if isPhoneLayout && !basket.isEmpty {
                    BasketBar(
                        isTeamTabMode: isTeamTabMode,
                        teamTitle: activeTeamTab?.titleHe,
                        totalQuantity: basketTotalQuantity,
                        totalPrice: finalTotal,
                        onBack: {
                            startNewOrderFromPayLater()   // ✅ same as “נקה”
                        },
                        onTap: {
                            showBasketSheetPhone = true
                        }
                    )
                }
                sideMenuContainer()
                if showPrintSuccess {
                    ZStack {
                        Color.black.opacity(0.35)
                            .ignoresSafeArea()
                        
                        VStack(spacing: 16) {
                            ZStack {
                                Circle()
                                    .fill(.primary)
                                    .frame(width: 110, height: 110)
                                
                                Image(systemName: "checkmark")
                                    .font(.system(size: 52, weight: .bold))
                                    .foregroundColor(.white)
                            }
                            .scaleEffect(printSuccessScale)
                            .opacity(printSuccessOpacity)
                            
                            Text(isRtl ? "ההזמנה עודכנה" : "Order updated")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundColor(.white)
                        }
                    }
                    .transition(.opacity)
                }
            
            }
            .confirmationDialog(
                "דו״ח Z",
                isPresented: $showZReportDialog,
                titleVisibility: .visible
            ) {
                Button("הפק דוח") {
                    zReportGenerate()
                }
                Button("שחזר דוח") {
                    zReportRestore()
                }
                Button("בטל", role: .cancel) { }
            } message: {
                Text("בחר פעולה")
            }
            .environment(\.layoutDirection, .rightToLeft)
            .animation(.spring(response: 0.3, dampingFraction: 0.8),
                       value: expandedBasketLineId)
            
            .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
            
           
           // .transaction { $0.disablesAnimations = true }
            .onReceive(backlogPoll) { _ in
                if printInFlight { return }
                updatePendingBacklog()
            }
            
            .onAppear {
                
                debugPinpad("onAppear")
                let mid = resolvedMiniAppId
                pinpadId = PinpadStore.load(miniAppId: mid)
                let legacy = pinpadId.isEmpty ? NO_TERMINAL_PINPAD : pinpadId
                  UserDefaults.standard.set(legacy, forKey: "pinpadId")
                if pinpadId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                   || pinpadId == NO_TERMINAL_PINPAD {

                    if pinpads.count == 1 {
                        let only = pinpads[0].id
                        pinpadId = only
                        PinpadStore.save(only, miniAppId: mid)

                        // ✅ legacy mirror (if your payment handler still reads "pinpadId")
                        UserDefaults.standard.set(only, forKey: "pinpadId")

                        print("💳 PINPAD AUTOSET mid=\(mid) -> \(only)")
                    }
                }
                print("💳 PINPAD FINAL mid=\(mid) pinpadId=\(pinpadId) stored=\(PinpadStore.load(miniAppId: mid)) legacy=\(UserDefaults.standard.string(forKey: "pinpadId") ?? "nil")")
                if isMiniApp13 {
                       migratePickupLocationOnce()
                   }
                cashPointMode = true
                  UserDefaults.standard.set(true, forKey: AppSettings.Key.cashPointMode) // optional safety
                  UserDefaults.standard.synchronize() // optional, usually not needed
                clearSavedContactAndService()
                let sid = UserDefaults.standard.string(forKey: "shopId") ?? "12"
                   if let cfg = loadSavedPrinters(shopId: sid) {
                       print("🎯 TEST prefix =", cfg.netPrefix ?? "nil")
                   }
                updatePendingBacklog()
                OrderOutbox.shared.drainNow()
                isPayLaterMode = false
                lockedLineIds.removeAll()
                lineSessionTime.removeAll()

                // ✅ Use cached menu first, then network if available
                if api.items.isEmpty {
                    api.load(skipCache: false)   // allow UserDefaults/file cache
                } else {
                    // Already have items (e.g. returning to view) – just try a network refresh
                    safeReloadMenu(reason: "toggle isOpen")
                }
            }
            .onChange(of: focusedStockProductId) { newVal in
                if newVal == nil && !isStockEditMode {
                    editingStockProductId = nil
                }
            }
            .onChange(of: isStockEditMode) { nowOn in
                Task { @MainActor in
                    print("🟡 isStockEditMode changed -> \(nowOn) dirty=\(dirtyStockIds.sorted())")

                    if nowOn {
                        // ✅ freeze current visual order using the SAME rule as normal mode (ACTIVE FIRST)

                        let base: [ShellMenuItem] = {
                            let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !q.isEmpty {
                                let qq = q.folding(options: .diacriticInsensitive, locale: .current).lowercased()
                                return api.items.filter {
                                    $0.name.folding(options: .diacriticInsensitive, locale: .current)
                                        .lowercased()
                                        .contains(qq)
                                }
                            }

                            guard !selectedCategory.isEmpty else { return [] }
                            if selectedCategory == "✏️ הערות" { return filteredItems }
                            return api.items.filter { $0.category == selectedCategory }
                        }()

                        @MainActor func sortKeyActiveFirst(_ item: ShellMenuItem) -> (Int, Int, String) {
                            let activeRank = stockToggles.isOn(item.id) ? 0 : 1   // ✅ active first
                            let idx = api.items.firstIndex(where: { $0.id == item.id }) ?? Int.max
                            return (activeRank, idx, item.name)
                        }
                        /*
                        frozenOrderIds = base
                            .sorted { sortKeyActiveFirst($0) < sortKeyActiveFirst($1) }
                            .map(\.id)
                         */
                        frozenOrderIds = base
                            .sorted { lhs, rhs in
                                let li = api.items.firstIndex(where: { $0.id == lhs.id }) ?? Int.max
                                let ri = api.items.firstIndex(where: { $0.id == rhs.id }) ?? Int.max
                                return li < ri
                            }
                            .map(\.id)

                    } else {
                        // ✅ exit stock mode -> commit + clear freeze
                        await flushDirtyStockAndExit()
                        frozenOrderIds = []
                    }
                }
            }
            .onChange(of: basket.count) { _ in
                Task { @MainActor in cleanupLineStateForCurrentBasket() }
                let currentIds = Set(basket.keys)
                discountedLineIds = discountedLineIds.intersection(currentIds)
                if discountAllSelected {
                    discountedLineIds = currentIds
                }
                excludedLineIds = excludedLineIds.intersection(currentIds)
                if excludeAllSelected {
                    excludedLineIds = currentIds
                }
            }
            .onChange(of: api.items.count) { _ in
                if selectedCategory.isEmpty, let firstCat = api.items.first?.category {
                    selectedCategory = firstCat
                }
            }
            .sheet(isPresented: $showLogsViewer) {
                PrintLogsViewerSheet()
            }
            .fullScreenCover(isPresented: $showAdminsDevices) {
                AdminsDevicesView(
                    miniAppId: resolvedMiniAppId,
                    canRevoke: canRevokeAdmins,
                    onClose: { showAdminsDevices = false }
                )
                .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
            }
            .fullScreenCover(isPresented: $showEODWizard) {
                EODWizardView(
                    miniAppId: 12,
                    onContinueOrder: { order in
                        // ✅ THIS is the same “continue order” behavior you already have elsewhere:
                        isPayLaterMode = true
                        restoreUnpaidOrder(order)   // your existing function
                        showEODWizard = false       // close wizard if not already dismissed
                    }
                )
                .environment(\.layoutDirection, .rightToLeft)
                .environment(\.locale, Locale(identifier: "he_IL"))
            }
            .fullScreenCover(item: $activeReportType) { type in
                let isRestore = (type == .z && zRestoreMode)

                let data: PrinterManager.SalesReportData = {
                    if isRestore { return emptySalesReportData() }          // ✅ blank until load
                    return reportData ?? buildSalesReportData(for: type)    // normal X / normal Z
                }()

                ReportPreviewSheet(
                    isRtl: isRtl,
                    type: type,
                    shopId: Int(UserDefaults.standard.string(forKey: "shopId") ?? "12") ?? 12,
                    initialData: data,
                    restoreMode: isRestore,
                    restoreDate: $zRestoreDate,
                    onClose: { activeReportType = nil },
                    onPrint: { activeReportType = nil }
                )
            }
            .fullScreenCover(isPresented: $showRefundFlow) {
                RefundAmountView(
                    isRtl: isRtl,
                    currency: currency,
                    input: $refundInput,
                    onCancel: {
                        showRefundFlow = false
                    },
                    onConfirm: { amountInt in
                        showRefundFlow = false

                        // ✅ CASH refund path (negative amount)
                        if amountInt < 0 {
                            let cashAmount = Double(abs(amountInt))
                            Haptics.success()
                            print("🧾 cash refund:", cashAmount)
                            return
                        }

                        // ✅ CARD refund path (positive amount)
                        let amount = Double(amountInt)
                        guard amount > 0 else { return }

                        ZCreditPaymentHandler.shared.pay(
                            amount: amount,
                            orderId: nil,
                            transactionType: "53"   // ✅ refund
                        ) { result in
                            DispatchQueue.main.async {
                                switch result.status {
                                case .approved: Haptics.success()
                                case .declined: Haptics.error()
                                case .unknown:  Haptics.error()
                                }
                                print("🧾 refund result:", result.status, result.message)
                            }
                        }
                    }
                )
                .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
            }
            .fullScreenCover(isPresented: $showBones) {
                DigitalBonesView(onRefundToCashPoint: { bone in
                    // Refund into current basket
                    refundOrderFromBone(bone)

                    // Reset pay-later context just like when coming from AdminOrdersView
                    isPayLaterMode = false
                    lockedLineIds.removeAll()
                    lineSessionTime.removeAll()

                    showBones = false
                })
                .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
            }
            .fullScreenCover(isPresented: $showBonbon) {
                SwipeUpCardCarousel()
                .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
            }
            .fullScreenCover(isPresented: $showOrdersAdmin) {
                OrdersHostView(
                    mode: adminMode,
                    onSelectUnpaid: { unpaidOrder in
                        if adminMode == .normal {
                            isPayLaterMode = true
                            restoreUnpaidOrder(unpaidOrder)
                            showOrdersAdmin = false
                        } else {
                            // EOD mode: do nothing here
                        }
                    },
                    onRefundFromBone: { bone in
                        refundOrderFromBone(bone)
                        isPayLaterMode = false
                        lockedLineIds.removeAll()
                        lineSessionTime.removeAll()
                        showOrdersAdmin = false
                    }
                )
                .environment(\.isRtl, true)                      // ✅ your custom env key
                   .environment(\.layoutDirection, .rightToLeft)
            }
            .sheet(isPresented: $showBasketSheetPhone) {
                NavigationStack {
                    basketPanel(inline: false)
                        .navigationTitle(isRtl ? "הזמנה" : "Basket")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbarBackground(.hidden, for: .navigationBar)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button {
                                    showBasketSheetPhone = false
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 16, weight: .bold))
                                        .padding(8)
                                        .background(Color(.systemGray5))
                                        .clipShape(Circle())
                                }
                            }
                        }
                }
                .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
            }
            .sheet(item: $sheetEntry) { entry in
                let lineId = entry.id
                let item = entry.item

                let initialQty = entry.quantity
                let initialOptions = optionsFromSubtitle(entry.subtitle)
                let remainingForItem = maxAdditionalQuantity(for: item, editingLineId: lineId)

                let clampedInitialQty: Int = {
                    if let limit = remainingForItem {
                        return min(initialQty, max(1, limit))
                    }
                    return initialQty
                }()

                POSProductSheet(
                    item: item,
                    initialQuantity: clampedInitialQty,
                    initialSelectedOptions: initialOptions,
                    isUpdate: true,
                    maxQuantity: remainingForItem
                ) { product, quantity, subtitle, unitPrice in
                    if quantity <= 0 {
                        basket[lineId] = nil
                    } else {
                        basket[lineId] = BasketEntry(
                            id: lineId,
                            item: product,
                            quantity: quantity,
                            subtitle: subtitle,
                            unitPrice: unitPrice
                        )
                    }

                    sheetEntry = nil
                }
            }
            .onReceive(productPoll) { _ in
                // ✅ Don't reload while editing stock OR while we still have pending stock changes
                if isStockEditMode { return }
                if !dirtyStockIds.isEmpty { return }          // your debounced list
                if stockCommitInFlight { return }
                if !stockToggles.pending.isEmpty { return }   // status toggle sync in-flight

                if showOrderFlow { return }
                if !basket.isEmpty { return }          // ✅ stronger than “basket empty only”
                if printInFlight { return }            // ✅ add this flag
                safeReloadMenu(reason: "toggle isOpen")
            }
            .onChange(of: isPayLaterMode) { print("isPayLaterMode =", $0) }
            .fullScreenCover(isPresented: $showOrderFlow) {
                let safeNameForPrint: String = resolvedCustomerNameForPrint()
                OrderFlowView(
                    onSendToKitchen: {
                        // 🔥 1. PRINT ONLY ONCE PER ORDER
                        guard !hasPrintedFromSwipe else { return }

                        let entriesArray = basketEntriesSorted
                        guard !entriesArray.isEmpty else { return }

                        let totalForPrint = finalTotal

                        // 🔢 Shared ticket number for slip + server
                        let ticketNumber: Int = {
                            if let existing = unpaidOrderId {
                                return existing
                            }
                            if let pending = pendingTicketNumber {
                                return pending
                            }
                            let new = nextLocalTicketNumber()
                            pendingTicketNumber = new
                            return new
                        }()

                        // Clean customer name for slip
                        let safeName: String? = {
                            let n = posSavedName
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                                .replacingOccurrences(of: "Customer", with: "")
                            return n.isEmpty ? nil : n
                        }()

                        // 🖨️ PRINT – once
                        Task {
                            await MainActor.run { printInFlight = true }

                            let ok = await PrinterManager.shared.printCashPointSplit(
                                orderNumber: ticketNumber,
                                entries: entriesArray,
                                total: totalForPrint,
                                diningMode: diningMode,
                                customerName: safeNameForPrint,
                                customerPhone: posSavedPhone
                            )
                            await MainActor.run { printInFlight = false }


                            await MainActor.run {
                                if ok {
                                    playPrintSuccess()
                                } else {
                                    print("❌ printCashPointSplit failed for order \(ticketNumber)")
                                    Haptics.error()
                                    showOutboxLog = true
                                    // or showPrinterStatusSheet = true
                                }
                            }
                        }
                        
                        hasPrintedFromSwipe = true

                        // 🧾 2. FIRST SUBMIT – UNPAID SNAPSHOT
                        let unpaidSummary = OrderAPI.PaymentSummary(
                            method: .unpaid,
                            cashAmount: 0,
                            cardAmount: 0
                        )

                        let meta: [String: Any] = [
                            "paymentMethod": "unpaid",
                            "cashAmount": 0,
                            "cardAmount": 0
                        ]

                        OrderAPI.submitOrder(
                            orderId: nil,
                            entries: entriesArray,
                            total: totalForPrint,
                            diningMode: diningMode,
                            source: "cashpoint",
                            customerName: safeName,
                            customerPhone: nil,
                            payment: unpaidSummary,
                            zcreditMeta: meta,                  // ✅ unpaid meta only
                            ticketNumber: ticketNumber,
                            orderType: (activeTeamTab == nil) ? nil : "teamTab",
                            tabKey: activeTeamTab?.rawValue
                        ) { submitResult in
                            clearSavedContactAndService()

                            DispatchQueue.main.async {
                                switch submitResult {
                                case .success(let serverOrderId):
                                    unpaidOrderId = serverOrderId
                                    print("🟢 slider unpaid submit → orderId=\(serverOrderId) ticket=\(ticketNumber)")

                                case .failure(let error):
                                    print("❌ slider unpaid submit failed:", error)
                                    Haptics.error()
                                }
                            }
                        }
                    },

                    total: finalTotal,
                    entries: basketEntriesSorted,
                    isRtl: isRtl,
                    diningMode: $diningMode,
                    requiresPhoneStep: basketRequiresPhone,

                    onCancel: {
                        showOrderFlow = false
                        if let first = categories.first {
                            selectedCategory = first
                        }
                    },

                    // ✅ NOW: this only submits — must NOT close the sheet inside completeOrder
                    onCompleted: { phone, name, summary, discountOff, tip in
                        pendingFinishAfterSubmit = true
                        completeOrder(
                            customerPhone: phone,
                            customerName: name,
                            paymentSummary: summary,
                            checkoutDiscountOff: discountOff,
                            tipAmount: tip
                        )
                    },
                    // ✅ NEW: waiter clicks "סיים" inside OrderFlowView → only then we close & reset
                    onFinish: {
                        showOrderFlow = false

                        // Keep your reset in ONE place (here)
                        basket.removeAll()
                       // nextBasketLineId = 1

                        // reset modifiers/edit UI state (safe)
                        expandedBasketLineId = nil
                        noteDrafts.removeAll()
                        optionSelections.removeAll()
                        additionSelections.removeAll()
                        basketSwipeOffsets.removeAll()

                        // reset discount UI
                        discountMode = .none
                        discountAllSelected = true
                        discountedLineIds.removeAll()
                        customDiscountText = ""

                        // reset OTH UI
                        excludeAllSelected = false
                        excludedLineIds.removeAll()

                        // reset pay-later context
                        isPayLaterMode = false
                        unpaidOrderId = nil
                        lockedLineIds.removeAll()
                        lineSessionTime.removeAll()

                        // reset order flags
                        hasPrintedFromSwipe = false
                        pendingTicketNumber = nil
                        hasChosenServiceMode = false
                        diningMode = .dineIn

                        Haptics.success()
                    },

                    allowPayLater: (!isPayLaterMode) || hasAddedLinesInPayLater,
                    skipServiceStep: hasChosenServiceMode,
                    onServiceChosen: {
                        hasChosenServiceMode = true
                    },
                    startAtCharge: isPayLaterMode
                )
                .environment(\.layoutDirection, isRtl ? .rightToLeft : .rightToLeft)
            }
            .fullScreenCover(item: $adminDraft) { draft in
                AdminProductEditorView(
                    draft: draft,
                    mode: draft.productId == nil ? .create : .edit,
                    categories: categories.filter { $0 != "✏️ הערות" },
                    allProducts: api.items,
                    onSave: { updatedDraft in
                        applyAdminSave(updatedDraft)
                    },
                    onArchive: {
                        guard let pid = draft.productId else { return }

                        let miniId =
                            UserDefaults.standard.integer(forKey: "miniAppId") > 0
                            ? UserDefaults.standard.integer(forKey: "miniAppId")
                            : (Int(UserDefaults.standard.string(forKey: "shopId") ?? "0") ?? 0)

                        guard miniId > 0 else {
                            print("❌ onArchive: missing miniAppId/shopId")
                            return
                        }

                        let base = UserDefaults.standard.string(forKey: "apiBase") ?? "https://minis.studio"
                        guard let url = URL(string: "\(base)/api/products/\(pid)/archive") else { return }

                        let debugCurl = """
                        curl -X POST "\(base)/api/products/\(pid)/archive" \\
                          -H "Content-Type: application/json" \\
                          -d '{ "miniAppId": \(miniId), "mode": "archive" }'
                        """
                        print("🔎 ARCHIVE DEBUG CURL:\n\(debugCurl)")

                        struct ArchiveBody: Encodable {
                            let miniAppId: Int
                            let mode: String
                        }

                        var req = URLRequest(url: url)
                        req.httpMethod = "POST"
                        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                        req.httpBody = try? JSONEncoder().encode(
                            ArchiveBody(miniAppId: miniId, mode: "archive")
                        )

                        Task {
                            do {
                                let (data, resp) = try await URLSession.shared.data(for: req)
                                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                                let text = String(data: data, encoding: .utf8) ?? ""

                                print("📦 Product \(pid) mode=archive (miniAppId \(miniId)) → HTTP \(code)")
                                print("📦 Response:", text)

                                if (200...299).contains(code) {
                                    await MainActor.run {
                                        if let idx = api.items.firstIndex(where: { $0.id == pid }) {
                                            api.items.remove(at: idx)
                                        }
                                        safeReloadMenu(reason: "archive product")
                                    }
                                }
                            } catch {
                                print("❌ Archive error:", error.localizedDescription)
                            }
                        }
                    },
                    onRemoveFromMini: {
                        guard let pid = draft.productId else { return }

                        let miniId =
                            UserDefaults.standard.integer(forKey: "miniAppId") > 0
                            ? UserDefaults.standard.integer(forKey: "miniAppId")
                            : (Int(UserDefaults.standard.string(forKey: "shopId") ?? "0") ?? 0)

                        guard miniId > 0 else {
                            print("❌ onRemoveFromMini: missing miniAppId/shopId")
                            return
                        }

                        let base = UserDefaults.standard.string(forKey: "apiBase") ?? "https://minis.studio"
                        guard let url = URL(string: "\(base)/api/products/\(pid)/archive") else { return }

                        let debugCurl = """
                        curl -X POST "\(base)/api/products/\(pid)/archive" \\
                          -H "Content-Type: application/json" \\
                          -d '{ "miniAppId": \(miniId), "mode": "remove" }'
                        """
                        print("🔎 REMOVE DEBUG CURL:\n\(debugCurl)")

                        struct ArchiveBody: Encodable {
                            let miniAppId: Int
                            let mode: String
                        }

                        var req = URLRequest(url: url)
                        req.httpMethod = "POST"
                        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                        req.httpBody = try? JSONEncoder().encode(
                            ArchiveBody(miniAppId: miniId, mode: "remove")
                        )

                        Task {
                            do {
                                let (data, resp) = try await URLSession.shared.data(for: req)
                                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                                let text = String(data: data, encoding: .utf8) ?? ""

                                print("🗑️ Product \(pid) mode=remove (miniAppId \(miniId)) → HTTP \(code)")
                                print("🗑️ Response:", text)

                                if (200...299).contains(code) {
                                    await MainActor.run {
                                        if let idx = api.items.firstIndex(where: { $0.id == pid }) {
                                            api.items.remove(at: idx)
                                        }
                                        safeReloadMenu(reason: "remove product from mini")
                                    }
                                }
                            } catch {
                                print("❌ Remove error:", error.localizedDescription)
                            }
                        }
                    },
                    onRestore: {
                        guard let pid = draft.productId else { return }

                        let miniId =
                            UserDefaults.standard.integer(forKey: "miniAppId") > 0
                            ? UserDefaults.standard.integer(forKey: "miniAppId")
                            : (Int(UserDefaults.standard.string(forKey: "shopId") ?? "0") ?? 0)

                        guard miniId > 0 else {
                            print("❌ onRestore: missing miniAppId/shopId")
                            return
                        }

                        let base = UserDefaults.standard.string(forKey: "apiBase") ?? "https://minis.studio"
                        guard let url = URL(string: "\(base)/api/products/\(pid)/archive") else { return }

                        let debugCurl = """
                        curl -X POST "\(base)/api/products/\(pid)/archive" \\
                          -H "Content-Type: application/json" \\
                          -d '{ "miniAppId": \(miniId), "mode": "restore" }'
                        """
                        print("🔎 RESTORE DEBUG CURL:\n\(debugCurl)")

                        struct ArchiveBody: Encodable {
                            let miniAppId: Int
                            let mode: String
                        }

                        var req = URLRequest(url: url)
                        req.httpMethod = "POST"
                        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                        req.httpBody = try? JSONEncoder().encode(
                            ArchiveBody(miniAppId: miniId, mode: "restore")
                        )

                        Task {
                            do {
                                let (data, resp) = try await URLSession.shared.data(for: req)
                                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                                let text = String(data: data, encoding: .utf8) ?? ""

                                print("↩️ Product \(pid) mode=restore (miniAppId \(miniId)) → HTTP \(code)")
                                print("↩️ Response:", text)

                                if (200...299).contains(code) {
                                    await MainActor.run {
                                        safeReloadMenu(reason: "restore product")
                                    }
                                }
                            } catch {
                                print("❌ Restore error:", error.localizedDescription)
                            }
                        }
                    },
                    onChangeImage: {
                        // hook up image picker if needed
                    }
                )
            }
            
            // 🔁 Every time JSON is parsed, refresh stock & status maps
            .onChange(of: api.version) { _ in
                guard dirtyStockIds.isEmpty else { return }
                guard !isStockEditMode else { return }
                loadCategoryOrderFromStorageOrMenu()
                let items = api.items

                var initialStatus: [Int: Int] = [:]
                var initialAdjustments: [Int: Int] = [:]
                var frozen: [String: Bool] = [:]

                for item in items {
                    
                    
                    if let groups = item.modifiers {
                           for g in groups {
                               for opt in g.items {
                                   if (opt.status ?? 1) == 0 {
                                       let key = freezeKey(productId: item.id, groupTitle: g.title, optionName: opt.name)
                                       frozen[key] = true
                                   }
                               }
                           }
                       }
                    if let q = item.stockQuantity {
                        // ✅ stockQuantity is the truth (including 0)
                        initialAdjustments[item.id] = max(q, 0)

                        // ✅ derive status from qty when qty exists
                        initialStatus[item.id] = (q > 0) ? 1 : 0

                    } else if let s = item.status {
                        // fallback only if qty missing
                        initialStatus[item.id] = (s != 0) ? 1 : 0

                    } else {
                        initialStatus[item.id] = 1
                    }
                }
                localFrozenOverrides = frozen
                // ✅ sync ON/OFF immediately
                stockToggles.forceServerStatus(initialStatus)

                // ✅ ALWAYS overwrite local stock map with server values
                stockAdjustments = initialAdjustments

                if selectedCategory.isEmpty, let firstCat = items.first?.category {
                    selectedCategory = firstCat
                }
            }
        }
    }

    private struct RefundAmountView: View {
        let isRtl: Bool
        let currency: String
        @Binding var input: String
        let onCancel: () -> Void
        let onConfirm: (Int) -> Void

        private var amountInt: Int {
            Int(input.filter(\.isNumber)) ?? 0
        }

        private let padWidth: CGFloat = 280

        var body: some View {
            ZStack {
                Color(.systemBackground).ignoresSafeArea()

                // top bar
                VStack {
                    HStack {
                        if isRtl { Spacer() }

                        Button(action: onCancel) {
                            Image(systemName: "xmark")
                                .font(.system(size: 18, weight: .bold))
                                .padding(10)
                                .background(Color(.systemGray5))
                                .clipShape(Circle())
                        }

                        if !isRtl { Spacer() }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 35)

                    Spacer()
                }
                .ignoresSafeArea()

                // centered content
                VStack(spacing: 18) {
                    Text("זיכוי לקוח")
                        .font(.system(size: 26, weight: .bold))
                        .multilineTextAlignment(.center)

                    Text(isRtl ? "הכנס סכום לזיכוי" : "Enter refund amount")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)

                    // amount box
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(.secondarySystemBackground))

                        Text(amountInt == 0 ? "0" : "\(amountInt)")
                            .font(.system(size: 30, weight: .bold, design: .monospaced))
                            .foregroundColor(.primary)
                    }
                    .frame(width: padWidth, height: 56)

                    keypad
                        .frame(width: padWidth)
                        .environment(\.layoutDirection, .leftToRight)

                    // actions
                    VStack(spacing: 12) {

                        HStack(spacing: 12) {
                            Button {
                                input = ""
                            } label: {
                                Text(isRtl ? "נקה" : "Clear")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundColor(.primary)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 50)
                                    .background(Color(.systemGray5))
                                    .clipShape(RoundedRectangle(cornerRadius: 18))
                            }

                            // ✅ NEW: cash refund (no signature change)
                            Button {
                                guard amountInt > 0 else { return }
                                PrinterManager.shared.openCashDrawer()
                                onConfirm(-amountInt)   // 👈 negative = CASH refund
                            } label: {
                                Text(isRtl ? "מזומן" : "Cash")
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundColor(.primary)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 50)
                                    .background(amountInt > 0 ? Color(.systemGray5) : Color.gray.opacity(0.25))
                                    .clipShape(RoundedRectangle(cornerRadius: 18))
                            }
                            .disabled(amountInt <= 0)
                        }
                        .frame(width: padWidth)

                        Button {
                            guard amountInt > 0 else { return }
                            onConfirm(amountInt)      // 👈 positive = CARD refund
                        } label: {
                            Text(isRtl ? "זכה באשראי" : "Refund")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(amountInt > 0 ? .black : .white)
                                .frame(width: padWidth, height: 50)
                                .background(amountInt > 0 ? Color.white : Color.gray.opacity(0.4))
                                .clipShape(RoundedRectangle(cornerRadius: 18))
                        }
                        .disabled(amountInt <= 0)
                    }
                    .padding(.top, 6)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
              
            }
            .onAppear { input = "" }
        }

        private var keypad: some View {
            let rows: [[String]] = [
                ["1","2","3"],
                ["4","5","6"],
                ["7","8","9"],
                ["C","0","⌫"]
            ]

            let cols = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

            return LazyVGrid(columns: cols, spacing: 10) {
                ForEach(rows, id: \.self) { row in
                    ForEach(row, id: \.self) { key in
                        Button { tapKey(key) } label: {
                            Text(key)
                                .font(.system(size: key == "⌫" ? 22 : 24, weight: .bold))
                                .frame(height: 64)
                                .frame(maxWidth: .infinity)
                                .background(Color(.secondarySystemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                    }
                }
            }
        }

        private func tapKey(_ key: String) {
            switch key {
            case "C":
                input = ""
            case "⌫":
                if !input.isEmpty { input.removeLast() }
            default:
                guard key.allSatisfy(\.isNumber) else { return }
                if input.count < 7 { input.append(key) }
            }
        }
    }
    
    private func completeOrder(
        customerPhone: String?,
        customerName: String?,
        paymentSummary: OrderAPI.PaymentSummary?,
        checkoutDiscountOff: Double = 0,
        tipAmount: Double = 0
    ) {
        guard !basket.isEmpty else {
            showOrderFlow = false
            return
        }

        // ✅ Pay-later flag (this is the problematic case)
        let isPayLaterChoice = (paymentSummary?.method == .unpaid)

        // Persist last used contact details
        if let phone = customerPhone, !phone.isEmpty {
            UserDefaults.standard.set(phone, forKey: "posCustomerPhone")
        }
        if let name = customerName, !name.isEmpty {
            UserDefaults.standard.set(name, forKey: "posCustomerName")
        }

        // Close panels (but DO NOT clear ids before snapshot)
        showExcludePanel = false
        showDiscountPanel = false

        // reset stock editing UI
        editingStockProductId = nil
        stockEditWorkItem?.cancel()
        stockEditWorkItem = nil

        // Snapshot BEFORE we mutate basket
        let entriesArray  = Array(basket.values)
        let mode          = diningMode
        let nameSnapshot  = customerName
        let phoneSnapshot = customerPhone

        let existingIdForPayLater: Int? = unpaidOrderId

        let ticketNumber: Int = {
            if let existing = existingIdForPayLater {
                return existing
            } else {
                return nextLocalTicketNumber()
            }
        }()

        // ✅ Snapshot OTH selection NOW (before we clear UI state)
        let othSnapshot: Set<Int> = {
            if excludeAllSelected { return Set(basket.keys) }
            return excludedLineIds
        }()

        // Decide which lines to print on the ticket
        let printerEntries: [BasketEntry]
        let printerTotal: Double

        // ✅ Compute snapshots FIRST (before printing/submitting) so all numbers are correct
        let subtotalSnapshot = basketTotalPrice
        let excludedSnapshot = excludedAmount
        let discountSnapshot = checkoutDiscountOff > 0 ? checkoutDiscountOff : discountAmount
        let totalSnapshot = max(0, subtotalSnapshot - excludedSnapshot - discountSnapshot)

        // ✅ Tip is separate; grandTotal is what customer actually paid
        let tipSnapshot = max(0, tipAmount)
        let grandTotalSnapshot = totalSnapshot + tipSnapshot

        if isPayLaterMode, existingIdForPayLater != nil {
            let unsent = entriesArray.filter { !lockedLineIds.contains($0.id) }
            printerEntries = unsent
            printerTotal   = unsent.reduce(0.0) { $0 + Double($1.quantity) * $1.unitPrice }
        } else {
            printerEntries = entriesArray
            printerTotal   = totalSnapshot
        }

        // ✅ PRINT *IMMEDIATELY* with local ticketNumber
        if !hasPrintedFromSwipe, !printerEntries.isEmpty {

            print("""
            🖨️ PRINT DEBUG (completeOrder)
              ticket=\(ticketNumber)
              nameSnapshot=\(nameSnapshot ?? "nil")
              phoneSnapshot=\(phoneSnapshot ?? "nil")
              entries=\(printerEntries.count)
              printerTotal=\(printerTotal)
              hasPrintedFromSwipe=\(hasPrintedFromSwipe)
            """)

            Task {
                await MainActor.run { printInFlight = true }

                let ok = await PrinterManager.shared.printCashPointSplit(
                    orderNumber: ticketNumber,
                    entries: printerEntries,
                    total: printerTotal,
                    diningMode: mode,
                    customerName: nameSnapshot,
                    customerPhone: phoneSnapshot
                )
                await MainActor.run { printInFlight = false }


                await MainActor.run {
                    if ok {
                        playPrintSuccess()
                    } else {
                        print("❌ printCashPointSplit failed for order \(ticketNumber)")
                        Haptics.error()

                        // pick one:
                        showOutboxLog = true
                        // or:
                        // showPrinterStatusSheet = true
                    }
                }
            }
        }

        hasPrintedFromSwipe = false
        pendingTicketNumber = nil

        // ✅ Totals payload now includes tip + grandTotal
        var totals: [String: Any] = [
            "subtotal": subtotalSnapshot,
            "discount": discountSnapshot,
            "excluded": excludedSnapshot,
            "tip": tipSnapshot,
            "total": totalSnapshot,
            "grandTotal": grandTotalSnapshot,
            "currency": currency
        ]

        if activeTeamTab != nil {
            totals["orderType"] = "teamTab"
            totals["tabKey"] = activeTeamTab?.rawValue ?? ""
        }

        print("🧾 discount=\(discountSnapshot) tip=\(tipSnapshot) total=\(totalSnapshot) grand=\(grandTotalSnapshot) othLines=\(othSnapshot.sorted())")

        // Payment meta
        var meta: [String: Any] = [:]
        if let summary = paymentSummary {
            meta["paymentMethod"] = summary.method.rawValue
            meta["cardAmount"]    = summary.cardAmount
            meta["cashAmount"]    = summary.cashAmount
        }
        let metaToSend = meta.isEmpty ? nil : meta

        // ✅ One reset function (so we never “forget” and end up overriding)
        func resetLocalOrderUI() {
            // ✅ DO NOT close flow here (finish button controls that)
            // showOrderFlow = false

            basket.removeAll()
          //  nextBasketLineId = 1

            expandedBasketLineId = nil
            noteDrafts.removeAll()
            optionSelections.removeAll()
            additionSelections.removeAll()
            basketSwipeOffsets.removeAll()

            showDiscountPanel = false
            discountMode = .none
            discountAllSelected = true
            discountedLineIds.removeAll()
            customDiscountText = ""
            customIsPercentage = false

            showExcludePanel = false
            excludeAllSelected = false
            excludedLineIds.removeAll()

            isPayLaterMode = false
            unpaidOrderId = nil
            lockedLineIds.removeAll()
            lineSessionTime.removeAll()
            activeTeamTab = nil

            hasPrintedFromSwipe = false
            pendingTicketNumber = nil
            hasChosenServiceMode = false
            diningMode = .dineIn
        }

        // ✅ If cashier chose Pay Later, close/reset immediately so next customer starts clean
        if isPayLaterChoice {
            resetLocalOrderUI()
        }

        // ✅ Submit — OTH is separate from team tab type
        OrderAPI.submitOrder(
            orderId: existingIdForPayLater,
            entries: entriesArray,
            total: totalSnapshot,
            diningMode: mode,
            source: "cashpoint",
            customerName: nameSnapshot,
            customerPhone: phoneSnapshot,
            payment: paymentSummary,
            zcreditMeta: metaToSend,
            ticketNumber: ticketNumber,
            othLineIds: othSnapshot,
            orderType: activeTeamTab == nil ? nil : "teamTab",
            tabKey: activeTeamTab?.rawValue,
            totals: totals
        ) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let serverOrderId):
                    clearSavedContactAndService()

                    applyOrderToLocalStock(entries: entriesArray)
                    posSavedName  = ""
                    posSavedPhone = ""

                    let snapshot = CashOrderSnapshot(
                        orderNumber: ticketNumber,
                        entries: entriesArray,
                        totalPrice: totalSnapshot,
                        diningMode: mode,
                        customerName: nameSnapshot,
                        customerPhone: phoneSnapshot
                    )
                    lastOrder = snapshot
                    showConfirmation = true
                    showLastInvoicePrompt = true

                    let currentId = snapshot.id
                    DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
                        if lastOrder?.id == currentId {
                            showLastInvoicePrompt = false
                        }
                    }

                    print("🟢 submitOrder OK → serverOrderId=\(serverOrderId), ticket=\(ticketNumber)")

                    // ✅ For non-pay-later flows, we still want the old “clear after success”
                    if !isPayLaterChoice {
                        resetLocalOrderUI()
                        Haptics.success()
                    }

                case .failure:
                    CashpointOrderQueue.enqueue(
                        entries: entriesArray,
                        total: totalSnapshot,
                        diningMode: mode,
                        ticketNumber: ticketNumber
                    )

                    let snapshot = CashOrderSnapshot(
                        orderNumber: ticketNumber,
                        entries: entriesArray,
                        totalPrice: totalSnapshot,
                        diningMode: mode,
                        customerName: nameSnapshot,
                        customerPhone: phoneSnapshot
                    )
                    lastOrder = snapshot
                    showConfirmation = true

                    // ✅ If NOT pay-later, keep UI (so cashier can retry).
                    // ✅ If pay-later, we already reset above (so next order won’t override).
                }

                // Reset discount UI state (safe / idempotent)
                discountMode = .none
                discountAllSelected = true
                discountedLineIds.removeAll()
                customDiscountText = ""
            }
        }
    }
    
    private func debugDiscount(_ tag: String) {
        let lines = basket.values
            .sorted { $0.id < $1.id }
            .map { e in
                "\(e.id): \(e.item.name) qty=\(e.quantity) unit=\(e.unitPrice) itemPrice=\(e.item.price)"
            }
            .joined(separator: " | ")

        print("""
        🧾 DISCOUNT[\(tag)]
          mode=\(discountMode)
          all=\(discountAllSelected)
          selected=\(discountedLineIds.sorted())
          base=\(discountBaseTotal)
          discount=\(discountAmount)
          basketTotal=\(basketTotalPrice)
          excluded=\(excludedAmount)
          final=\(finalTotal)
          lines=\(lines)
        """)
    }
    private func stableIndex(_ item: ShellMenuItem) -> Int {
        api.items.firstIndex(where: { $0.id == item.id }) ?? Int.max
    }
    /*
    private func productSortKey(_ item: ShellMenuItem) -> (Int, Int, String) {
        let isActive = stockToggles.isOn(item.id)
        let activeRank = isActive ? 0 : 1
        return (activeRank, stableIndex(item), item.name)
    }
    */
    private func productSortKey(_ item: ShellMenuItem) -> (Int, Int, String) {
        // MiniApp 12 only: active products first, frozen/out-of-stock at bottom
        if resolvedMiniAppId == 12 {
            let isActive: Bool = {
                if let q = stockAdjustments[item.id] {
                    return q > 0          // 0 => bottom
                }
                return stockToggles.isOn(item.id) // fallback
            }()

            let activeRank = isActive ? 0 : 1
            return (activeRank, stableIndex(item), item.name)
        }

        // Other minis: keep normal manual/category order
        return (0, stableIndex(item), item.name)
    }
    
    private func addToBasket(item: ShellMenuItem, quantity: Int, subtitle: String?, unitPrice: Double) {
        // 1) Always squeeze / collapse the previously expanded row
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            expandedBasketLineId = nil
        }

        let hasModifiers = !(item.modifiers?.isEmpty ?? true)

        if hasModifiers {
            // Each modifiers combo is its own line
            let lineId = nextBasketLineId
            nextBasketLineId += 1

            basket[lineId] = BasketEntry(
                id: lineId,
                item: item,
                quantity: quantity,
                subtitle: subtitle,
                unitPrice: unitPrice
            )

            // 2) New line has modifiers → expand this one
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                expandedBasketLineId = lineId
            }
        } else {
               // No modifiers → single line per product
               // ✅ In pay-later mode, NEVER merge into locked lines.
               let mergeCandidate = basket.first(where: { pair in
                   let entry = pair.value
                   guard entry.item.id == item.id else { return false }

                   // In normal mode → merge as before
                   if !isPayLaterMode { return true }

                   // In pay-later mode → only merge into UNLOCKED lines
                   return !lockedLineIds.contains(pair.key)
               })

               if let (lineId, existing) = mergeCandidate {
                   // Merge into existing, editable line
                   basket[lineId] = BasketEntry(
                       id: lineId,
                       item: existing.item,
                       quantity: existing.quantity + quantity,
                       subtitle: subtitle ?? existing.subtitle,
                       unitPrice: existing.unitPrice
                   )
               } else {
                   // No suitable line (or only locked lines) → create NEW line
                   let lineId = nextBasketLineId
                   nextBasketLineId += 1

                   basket[lineId] = BasketEntry(
                       id: lineId,
                       item: item,
                       quantity: quantity,
                       subtitle: subtitle,
                       unitPrice: unitPrice
                   )
               }
               // For plain items we keep everything collapsed – just the squeeze.
           
            // For plain items we keep everything collapsed – just the squeeze.
        }
    }

    // MARK: - Refund from DigitalBones into CashPoint basket

    /// Strip common size words from a Hebrew product name to improve matching.
    private func stripSizeWords(from name: String) -> String {
        let sizeTokens = ["קטן", "גדול", "בינוני", "קצר", "ארוך", "כפול"]
        var result = name
        for token in sizeTokens {
            result = result.replacingOccurrences(of: " " + token, with: "")
            result = result.replacingOccurrences(of: token + " ", with: "")
            result = result.replacingOccurrences(of: token, with: "")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    struct TeamTabsSheet: View {
        let onSelect: (TabType) -> Void

        var body: some View {
            NavigationStack {
                List {
                    ForEach(TabType.allCases) { tab in
                        Button(tab.titleHe) { onSelect(tab) }
                    }
                }
                .navigationTitle("שולחנות צוות")
            }
        }
    }
    
    private var currentOrderTitle: String? {
        if let tab = activeTeamTab {
            return tab.titleHe
        }

        if isPayLaterMode, !currentUnpaidOrderTitle.isEmpty {
            return currentUnpaidOrderTitle
        }

        return nil
    }
    
    @State private var teamTabLoading = false

    private func openTeamTab(_ tab: TabType) {
        showSideMenu = false

        // enter team mode immediately
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            activeTeamTab = tab
            isPayLaterMode = true
            hasChosenServiceMode = true
            diningMode = .dineIn
        }
        // reset local state
        basket.removeAll()
        lockedLineIds.removeAll()
        lineSessionTime.removeAll()
        unpaidOrderId = nil
      //  nextBasketLineId = 1

        let miniAppId = resolvedMiniAppId

        TeamTabsAPI.openOrCreate(miniAppId: miniAppId, tab: tab) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let oid):
                    unpaidOrderId = oid

                    // ✅ Always fetch from server so it restores across devices
                    TeamTabsAPI.fetchOrderMetadata(orderId: oid) { res in
                        DispatchQueue.main.async {
                          
                        }
                    }

                case .failure(let err):
                    print("❌ openTeamTab failed:", err.localizedDescription)
                    Haptics.error()
                }
            }
        }
    }
    /// Try to find the matching menu item for a bone ticket line.
    private func findMenuItem(for ticketName: String) -> ShellMenuItem? {
        let clean = ticketName.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Exact match
        if let exact = api.items.first(where: { $0.name == clean }) {
            return exact
        }

        let strippedTicket = stripSizeWords(from: clean)

        // 2. Match by stripped name (ignore size words)
        if let byStripped = api.items.first(where: {
            stripSizeWords(from: $0.name) == strippedTicket
        }) {
            return byStripped
        }

        // 3. Fallback: contains / prefix match
        if let contains = api.items.first(where: {
            clean.contains($0.name) || $0.name.contains(clean)
        }) {
            return contains
        }

        return nil
    }

    /// Rebuild an order from DigitalBones into the cashpoint basket.
    private func refundOrderFromBone(_ bone: DigitalBonesView.Bone) {

        // 🔥🔥 CLEAR CURRENT BASKET BEFORE REFUNDING — NEW LINE
        basket.removeAll()
       // nextBasketLineId = 1

        var i = 0
        let lines = bone.items

        while i < lines.count {
            let raw = lines[i]

            // Skip accidental modifier rows
            if raw.hasPrefix("MOD:") {
                i += 1
                continue
            }

            // Parse "qty name" (example: "2 הפוך קטן")
            let parts = raw.split(separator: " ", maxSplits: 1)
            let qty: Int
            let name: String

            if parts.count == 2, let q = Int(parts[0]) {
                qty = max(q, 1)
                name = String(parts[1])
            } else {
                qty = 1
                name = raw
            }

            // Collect subsequent MOD: lines
            var mods: [String] = []
            var j = i + 1
            while j < lines.count, lines[j].hasPrefix("MOD:") {
                let m = lines[j]
                    .dropFirst("MOD:".count)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !m.isEmpty { mods.append(m) }
                j += 1
            }

            // Match product with real menu item
            if let item = findMenuItem(for: name) {
                let subtitle = mods.isEmpty ? nil : mods.joined(separator: " · ")

                addToBasket(
                    item: item,
                    quantity: qty,
                    subtitle: subtitle,
                    unitPrice: item.price   // use current menu price
                )
            } else {
                print("⚠️ refundOrderFromBone: failed to match menu item for '\(name)'")
            }

            i = j
        }

        // Sync service mode based on "**TA**" from DigitalBones
        if let s = bone.serviceText?.lowercased(), s.contains("ta") {
            diningMode = .takeAway
        } else {
            diningMode = .dineIn
        }
    }
    
    private func incrementEntry(_ id: Int) {
        guard let entry = basket[id] else { return }

        // If we track stock for this product, enforce it
        if let stock = remainingStock(for: entry.item) {
            // total quantity across ALL basket lines for this product
            let totalBefore = quantityInBasket(for: entry.item)

            if totalBefore >= stock {
                // No more stock → block
                Haptics.error()
                return
            }
        }

        // Either unlimited stock (nil) or still room to add
        basket[id] = BasketEntry(
            id: entry.id,
            item: entry.item,
            quantity: entry.quantity + 1,
            subtitle: entry.subtitle,
            unitPrice: entry.unitPrice
        )
    }
    private struct PrinterStatusSheet: View {
        let isRtl: Bool
        @ObservedObject var monitor: PrinterReachabilityMonitor
        let onTestPrint: () -> Void

        @Environment(\.dismiss) private var dismiss

        // ✅ NEW: open printer setup
        @State private var showPrinterSetup = false

        // ✅ NEW: owner PIN gate
        @State private var showOwnerPin = false
        @State private var unlocked = false

        private var ownerPin: String {
            UserDefaults.standard.string(forKey: "owner.pin") ?? "1234"
        }

        @ObservedObject private var printerStore = PrintersConfigStore.shared

        private var offlineCount: Int { monitor.rows.filter { !$0.isReachable }.count }
        private var isOnPrinterNetwork: Bool { monitor.isNetworkUp }
        private var allOnline: Bool { !monitor.rows.isEmpty && offlineCount == 0 }

        private var statusTitle: String {
            guard isOnPrinterNetwork else { return "לא מחובר לרשת המדפסות" }
            if allOnline { return "כל המדפסות מחוברות" }
            return "חסרה מדפסת (\(offlineCount))"
        }

        private var iconName: String {
            guard isOnPrinterNetwork else { return "printer" }
            return allOnline ? "printer.fill" : "printer"
        }

        private var iconColor: Color {
            guard isOnPrinterNetwork else { return .secondary }
            return .primary
        }

        private var canTestPrint: Bool {
            isOnPrinterNetwork && monitor.rows.contains(where: { $0.isReachable })
        }

        private var configuredPrefixText: String {
            let p = printerStore.config.netPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
            return p.isEmpty ? "—" : p
        }

        private var detectedLanIP: String? {
            // If you have monitor.currentIP, put it here.
            // return monitor.currentIP
            return nil
        }

        private func openSetup() {
            showPrinterSetup = true
        }

        var body: some View {
            NavigationStack {
                ZStack {
                    Color(.systemBackground).ignoresSafeArea()

                    VStack(spacing: 12) {

                        // header row
                        HStack(spacing: 10) {
                            Image(systemName: iconName)
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(iconColor)

                            Text(statusTitle)
                                .font(.system(size: 18, weight: .bold))

                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)

                        // config summary
                        VStack(spacing: 8) {
                            HStack {
                                Text("רשת")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text(configuredPrefixText)
                                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }

                            HStack {
                                Text("מדפסות")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.secondary)
                                Spacer()
                                let activeCount = printerStore.config.stations.filter { $0.status != 0 }.count
                                Text(activeCount == 0 ? "לא מוגדר" : "\(activeCount)")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal, 16)

                        // list
                        VStack(spacing: 8) {
                            ForEach(monitor.rows) { row in
                                HStack {
                                    Text(row.printer.name)
                                        .font(.system(size: 16, weight: .semibold))

                                    Spacer()

                                    Text(!isOnPrinterNetwork ? "—" : (row.isReachable ? "Online" : "Offline"))
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(!isOnPrinterNetwork ? .secondary : (row.isReachable ? .primary : .secondary))
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(Color(.secondarySystemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                        }
                        .padding(.horizontal, 16)

                        // test print (kept as the only bottom button)
                        Button {
                            onTestPrint()
                            Haptics.light()
                        } label: {
                            Text("הדפס בדיקה")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                                .background(canTestPrint ? Color.black : Color.gray.opacity(0.35))
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                        .disabled(!canTestPrint)
                        .padding(.horizontal, 16)
                        .padding(.top, 6)

                        Spacer(minLength: 8)
                    }
                }
                .navigationTitle("מדפסות")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    // Close button (left in LTR, right in RTL)
                    ToolbarItem(placement: .cancellationAction) {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 16, weight: .bold))
                                .padding(8)
                                .background(Color(.systemGray5))
                                .clipShape(Circle())
                        }
                    }

                    // ✅ Edit link in nav bar
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            openSetup()
                            Haptics.light()
                        } label: {
                            Text(isRtl ? "עריכה" : "Edit")
                                .font(.system(size: 16, weight: .bold))
                        }
                    }
                }
                .onAppear {
                    Task { await monitor.checkNow() }
                }
                .sheet(isPresented: $showOwnerPin) {
                    OwnerPinGateSheet(title: "Owner PIN", correctPin: ownerPin) {
                        unlocked = true
                        showPrinterSetup = true
                    }
                    .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
                }
                .sheet(isPresented: $showPrinterSetup) {
                    PrinterSetupSheet(
                        isRtl: isRtl,
                        detectedLANIP: detectedLanIP,
                        onClose: { showPrinterSetup = false }
                    )
                    .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
                }
            }
            .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
        }
    }
    
     struct SwipeToSendOrderView: View {
        let isRtl: Bool
        let hasSent: Bool
        let onSend: () -> Void

        @State private var dragOffset: CGFloat = 0
        @State private var showFlame: Bool = false
        @State private var flameScale: CGFloat = 0.5
        @State private var flameOpacity: Double = 0
        @State private var flameOffsetY: CGFloat = 12
        @State private var flameRotation: Double = 0
        @State private var flameHorizontalOffset: CGFloat = 0

        var body: some View {
            // 👇 **Smaller slider width**
            let totalWidth: CGFloat = 250
            let thumbDiameter: CGFloat = 40

            // 👇 Thumb movement = entire track minus thumb space
            let horizontalPadding: CGFloat = 8      // for left/right breathing room
            let maxTravel = totalWidth - thumbDiameter - horizontalPadding

            let threshold = maxTravel * 0.70        // commit swipe when crossing 70%

            let trackColor = hasSent ? Color(.systemGray4) : Color(.systemGray5)
            let thumbColor = hasSent ? Color(.systemGray3) : Color.black
            let titleText  = hasSent
                ? (isRtl ? "הזמנה נשלחה" : "Order sent")
                : (isRtl ? "שלח הזמנה"   : "Send order")

            VStack(spacing: 6) {

                // 🔥 BLACK FLAME ABOVE SLIDER
                ZStack {
                    if showFlame {
                        ZStack {
                            Image(systemName: "flame.fill")
                                .font(.system(size: 58))
                                .foregroundColor(Color.black.opacity(0.9))
                                .scaleEffect(flameScale)
                                .opacity(flameOpacity)
                                .offset(x: flameHorizontalOffset, y: flameOffsetY)
                                .rotationEffect(.degrees(flameRotation))

                            Image(systemName: "flame.fill")
                                .font(.system(size: 34))
                                .foregroundColor(Color.white.opacity(0.9))
                                .scaleEffect(flameScale * 0.75)
                                .opacity(flameOpacity * 0.95)
                                .offset(x: flameHorizontalOffset * 0.6,
                                        y: flameOffsetY + 4)
                                .rotationEffect(.degrees(flameRotation * 0.8))
                        }
                    }
                }
                .frame(height: 40)

                // SLIDER BAR
                ZStack {

                    RoundedRectangle(cornerRadius: 24)
                        .fill(trackColor)
                        .frame(width: totalWidth, height: 48)
                        .overlay(
                            Text(titleText)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.secondary)
                        )

                    HStack(spacing: 0) {

                        if isRtl {
                            // ✅ RTL: thumb starts RIGHT, moves LEFT
                            Spacer(minLength: 0)

                            Circle()
                                .fill(thumbColor)
                                .frame(width: thumbDiameter, height: thumbDiameter)
                                .offset(x: -dragOffset)
                                .gesture(
                                    DragGesture()
                                        .onChanged { value in
                                            guard !hasSent else { return }
                                            dragOffset = max(0, min(-value.translation.width, maxTravel)) // ✅ RIGHT→LEFT
                                        }
                                        .onEnded { _ in
                                            guard !hasSent else { return }

                                            if dragOffset >= threshold {
                                                triggerFlameAnimation()
                                                onSend()

                                                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                                                    dragOffset = maxTravel
                                                }
                                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                                                        dragOffset = 0
                                                    }
                                                }
                                            } else {
                                                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                                                    dragOffset = 0
                                                }
                                            }
                                        }
                                )

                        } else {
                            // ✅ LTR: thumb starts LEFT, moves RIGHT
                            Circle()
                                .fill(thumbColor)
                                .frame(width: thumbDiameter, height: thumbDiameter)
                                .offset(x: dragOffset)
                                .gesture(
                                    DragGesture()
                                        .onChanged { value in
                                            guard !hasSent else { return }
                                            dragOffset = max(0, min(value.translation.width, maxTravel)) // ✅ LEFT→RIGHT
                                        }
                                        .onEnded { _ in
                                            guard !hasSent else { return }

                                            if dragOffset >= threshold {
                                                triggerFlameAnimation()
                                                onSend()

                                                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                                                    dragOffset = maxTravel
                                                }
                                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                                                        dragOffset = 0
                                                    }
                                                }
                                            } else {
                                                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                                                    dragOffset = 0
                                                }
                                            }
                                        }
                                )

                            Spacer(minLength: 0)
                        }
                    }
                    .padding(.horizontal, horizontalPadding / 2)
                    .environment(\.layoutDirection, .leftToRight) // ✅ prevents SwiftUI from flipping our explicit layout
                }
            }
            .frame(width: totalWidth, height: 110)
        }

        private func triggerFlameAnimation() {
            showFlame = true
            flameScale = 0.3
            flameOpacity = 0.0
            flameOffsetY = 10
            flameRotation = 0
            flameHorizontalOffset = 0

            // Stage 1 – pop
            withAnimation(.spring(response: 0.28, dampingFraction: 0.6)) {
                flameScale = 1.4
                flameOpacity = 1.0
                flameOffsetY = -6
            }

            // Stage 2 – wobble
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                withAnimation(.easeInOut(duration: 0.18)) {
                    flameRotation = isRtl ? -9 : 9
                    flameHorizontalOffset = isRtl ? -6 : 6
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        flameRotation = isRtl ? 6 : -6
                        flameHorizontalOffset = isRtl ? 4 : -4
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            flameRotation = 0
                            flameHorizontalOffset = 0
                        }
                    }
                }
            }

            // Stage 3 – fade out
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                withAnimation(.easeOut(duration: 0.3)) {
                    flameOpacity = 0.0
                    flameOffsetY = -20
                    flameScale = 1.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    showFlame = false
                }
            }
        }
    }
    
    private struct MessageSheet: View {
        let isRtl: Bool
        let targetIsKitchen: Bool
        let targetIsBakery: Bool
        @Binding var text: String
        @Binding var priceText: String
        var onAdd: (String, Double) -> Void

        @Environment(\.dismiss) private var dismiss
        @FocusState private var messageFocused: Bool
        @FocusState private var priceFocused: Bool

        // ✅ sign toggle (because decimalPad has no minus on iPad)
        @State private var isNegative: Bool = false

        private var title: String {
            if targetIsKitchen {
                return isRtl ? "הערה למטבח" : "Message to kitchen"
            } else if targetIsBakery {
                return isRtl ? "הערה לוטרינה" : "Message to vitrine"
            } else {
                return isRtl ? "הערה לבר" : "Message to bar"
            }
        }

        private var trimmedPrice: String {
            priceText.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private var hasTypedPrice: Bool {
            !trimmedPrice.isEmpty
        }

        // ✅ Parse numeric value; empty = 0 (so you can add note without typing price)
        private var parsedAbsPrice: Double? {
            let raw = trimmedPrice
                .replacingOccurrences(of: ",", with: ".")

            if raw.isEmpty { return 0 } // ✅ allow empty => 0
            guard let d = Double(raw) else { return nil }
            return abs(d)
        }

        private var parsedPrice: Double? {
            guard let v = parsedAbsPrice else { return nil }
            return isNegative ? -v : v
        }

        private var canSubmit: Bool { parsedPrice != nil }

        private var hasText: Bool {
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        // ✅ show preview ONLY if user typed something (so you don't see 0.00)
        private var signedPreview: String {
            guard hasTypedPrice else { return "" }
            let v = (parsedAbsPrice ?? 0)
            let num = String(format: "%.2f", v)
            return (isNegative ? "-" : "") + num
        }

        var body: some View {
            NavigationStack {
                VStack(spacing: 16) {

                    // TEXT FIELD + CLEAR BUTTON
                    ZStack(alignment: .topTrailing) {
                        TextField(isRtl ? "טקסט הערה" : "Message text",
                                  text: $text,
                                  axis: .vertical)
                            .lineLimit(2...4)
                            .padding(10)
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(10)
                            .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
                            .focused($messageFocused)

                        if hasText {
                            Button { text = "" } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(.secondary)
                                    .padding(8)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // ✅ PRICE ROW: +/- toggle + placeholder-only "0"
                    HStack(spacing: 10) {

                        Button {
                            isNegative.toggle()
                            Haptics.light()
                        } label: {
                            Text(isNegative ? "−" : "+")
                                .font(.system(size: 20, weight: .heavy))
                                .foregroundColor(.primary)
                                .frame(width: 44, height: 44)
                                .background(Color(.systemGray5))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)

                        // ✅ Placeholder "0" drawn only when empty
                        ZStack(alignment: isRtl ? .trailing : .leading) {
                            if trimmedPrice.isEmpty {
                                Text("0")
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 10)
                                    .frame(maxWidth: .infinity,
                                           alignment: isRtl ? .trailing : .leading)
                                    .allowsHitTesting(false)
                            }

                            TextField("", text: Binding(
                                get: { priceText },
                                set: { newValue in
                                    var s = newValue
                                        .replacingOccurrences(of: ",", with: ".")
                                        .trimmingCharacters(in: .whitespacesAndNewlines)

                                    // remove leading "-"
                                    if s.hasPrefix("-") { s.removeFirst() }

                                    // keep only digits and "."
                                    s = s.filter { $0.isNumber || $0 == "." }

                                    // allow only one "."
                                    if let firstDot = s.firstIndex(of: ".") {
                                        let after = s.index(after: firstDot)
                                        let rest = s[after...].replacingOccurrences(of: ".", with: "")
                                        s = String(s[..<after]) + rest
                                    }

                                    priceText = s
                                }
                            ))
                            .keyboardType(.decimalPad)
                            .padding(10)
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(10)
                            .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
                            .focused($priceFocused)
                            .overlay(alignment: isRtl ? .trailing : .leading) {
                                if priceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Text("0")
                                        .foregroundColor(.secondary)
                                        .padding(.horizontal, 10)
                                        .allowsHitTesting(false)
                                }
                            }
                        }

                        // ✅ preview only after typing (otherwise empty)
                        if hasTypedPrice {
                            Text(signedPreview)
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                .foregroundColor(.secondary)
                                .frame(width: 88, alignment: .trailing)
                        }
                    }

                    // SAVE BUTTON – text can be empty
                    Button {
                        if let price = parsedPrice {
                            let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            onAdd(trimmedText, price)
                            dismiss()
                        }
                    } label: {
                        Text(isRtl ? "הוסף להזמנה" : "Add to order")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(canSubmit ? .white : Color.gray.opacity(0.4))
                            .cornerRadius(16)
                    }
                    .disabled(!canSubmit)

                    Spacer()
                }
                .padding(20)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 16, weight: .bold))
                                .padding(8)
                                .background(Color(.systemGray5))
                                .clipShape(Circle())
                        }
                    }
                }
                .onAppear {
                    // ✅ IMPORTANT: do NOT force "0"
                    if priceText.trimmingCharacters(in: .whitespacesAndNewlines) == "0" {
                        priceText = ""
                    }

                    // prevent auto-focus
                    messageFocused = false
                    priceFocused = false
                    DispatchQueue.main.async {
                        messageFocused = false
                        priceFocused = false
                    }
                }
            }
            .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
        }
    }

    struct BasketBar: View {
        @Environment(\.isRtl) private var isRtl
        @Environment(\.currency) private var currency
        @Environment(\.colorScheme) private var colorScheme   // ✅ NEW

        let isTeamTabMode: Bool
        let teamTitle: String?

        let totalQuantity: Int
        let totalPrice: Double

        let onBack: () -> Void
        let onTap: () -> Void

        private var teamButtonTitle: String {
            let raw = (teamTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.isEmpty { return isRtl ? "שולחן" : "Table" }
            if raw.contains("שולחן") { return raw }
            return (isRtl ? "שולחן " : "Table ") + raw
        }

        // ✅ Dark mode -> white pill with black text
        private var barBackground: Color { colorScheme == .dark ? .white : .black }
        private var barForeground: Color { colorScheme == .dark ? .black : .white }

        // Badge invert (so it always pops)
        private var badgeBackground: Color { colorScheme == .dark ? .black : .white }
        private var badgeForeground: Color { colorScheme == .dark ? .white : .black }

        var body: some View {
            HStack {
                Button {
                    onTap()
                } label: {
                    ZStack {

                        // 🔹 TEAM TAB MODE
                        if isTeamTabMode {

                            HStack {
                                Button {
                                    onBack()
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "chevron.backward")
                                            .font(.system(size: 18, weight: .bold))

                                        Text(isRtl ? "חזרה לקופה" : "Back to till")
                                            .font(.system(size: 15, weight: .semibold))
                                            .lineLimit(1)
                                    }
                                    .foregroundColor(barForeground)
                                    .padding(.horizontal, 14)
                                    .frame(height: 44)
                                    .background(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .fill(barBackground.opacity(0.92))
                                    )
                                }
                                .buttonStyle(.plain)

                                Spacer()

                                Text(teamButtonTitle)
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundColor(barForeground)

                                Spacer()

                                Color.clear
                                    .frame(width: 44, height: 44)
                            }
                            .padding(.horizontal, 12)
                            .frame(height: 60)
                            .frame(maxWidth: .infinity)
                            .background(
                                barBackground
                                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            )

                        } else {

                            // 🔹 NORMAL MODE
                            HStack {
                                if isRtl {
                                    HStack(spacing: 12) {
                                        Text("\(totalQuantity)")
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundColor(badgeForeground)
                                            .frame(width: 28, height: 28)
                                            .background(badgeBackground)
                                            .clipShape(Circle())

                                        Text("הזמנה")
                                            .font(.system(size: 18, weight: .semibold))
                                            .foregroundColor(barForeground)
                                    }

                                    Spacer()

                                    Text(String(format: "\(currency)%.2f", totalPrice))
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundColor(barForeground)

                                } else {
                                    Text(String(format: "\(currency)%.2f", totalPrice))
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundColor(barForeground)

                                    Spacer()

                                    HStack(spacing: 12) {
                                        Text("Order")
                                            .font(.system(size: 18, weight: .semibold))
                                            .foregroundColor(barForeground)

                                        Text("\(totalQuantity)")
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundColor(badgeForeground)
                                            .frame(width: 28, height: 28)
                                            .background(badgeBackground)
                                            .clipShape(Circle())
                                    }
                                }
                            }
                            .padding(.horizontal, 20)
                            .frame(height: 60)
                            .frame(maxWidth: .infinity)
                            .background(
                                barBackground
                                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            )
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, -12)
        }
    }
    private func decrementEntry(_ id: Int) {
        if let entry = basket[id] {
            let newQty = entry.quantity - 1
            if newQty <= 0 {
                if pricePulseLineId == id { pricePulseLineId = nil }
                basket[id] = nil
                if expandedBasketLineId == id {
                    expandedBasketLineId = nil
                }
            } else {
                basket[id] = BasketEntry(
                    id: entry.id,
                    item: entry.item,
                    quantity: newQty,
                    subtitle: entry.subtitle,
                    unitPrice: entry.unitPrice
                )
            }
        }
    }

    /// Builds a simple monospaced preview of the report.
    /// For now it uses the same demo numbers you used in SalesReportData.
    private func makeReportPreview(for type: ReportType) -> String {
        let now = Date()

        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "he_IL")
        timeFormatter.dateFormat = "HH:mm:ss"

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "he_IL")
        dateFormatter.dateFormat = "dd/MM/yyyy"

        let timeText = timeFormatter.string(from: now)
        let dateText = dateFormatter.string(from: now)

        let lrm = "\u{200E}"
        let headerLine = "\(lrm)\(timeText) \(dateText)"

        // 🔹 Demo numbers – SAME as the ESC/POS demo you used.
        // Later: replace them with real computed values.
        let lines: [String] = [
            "Beit Ha'am",
            "בית העם קונדיטוריה ויין בע\"מ",
            "ח.פ / ע.מ. 516784139",
            "",
            "דוח תנועות פעיל \(type == .x ? "X" : "Z")",
            dateText,
            "",
            headerLine,
            "------------------------------------------------",
            "מכירות",
            "PPA | סועד | כולל מע\"מ | ללא מע\"מ",
            "----------------------------------------------",
            " 26 | 14 | 375.0 | מסעדה  7.713",
            " 22 | 08 | 317.2 | 317.2     TA",
            "    |    | 692.2 | מכירות 7.713",
            "    |    | 7.713 | תשר    7.713",
            "    |    | 699.9 | סה\"כ   7.713",
            "------------------------------------------------",
            "תקבולים",
            "סכום  | תשלום | סוג | כמות",
            "--------------------------------",
            "250.0 | מזומן |  -  | 3",
            "329.9 | אשראי |  -  | 5",
            "--------------------------------",
            "579.9 | סה\"כ  |     | 8",
            "------------------------------------------------",
            "דוח מזומן",
            "סכום    | סוג מגירה     | סוג פעולה",
            "--------------------------------------------",
            "0       |               | הד. סגורות",
            "0       |               | הד. פתוחות",
            "0       |               | הפקדה/משיכה",
            "--------------------------------------------",
            "0       |               | סה\"כ במגירת",
            "0       | מגירה ראשית   |",
            "0       | עמדת מארחת    |",
            "--------------------------------------------",
            "תשר",
            "0       |               | תשר",
            "0       | שולחנות מסעדה|",
            "0       | בר ולקחת      |",
            "--------------------------------------------",
            "0       |               | עודף טיפ",
            "0       | מסעדה         |",
            "0       | בר             |",
            "--------------------------------------------",
            "חריגים",
            "0       | 0             | הזמנות OTH",
            "0       | 0             | מנות OTH",
            "0       | 0             | ביטולי מנות",
            "0       | 0             | החזרי מנות",
            "0       | 0             | הנחות",
            "0       | 0             | החזר הנחות",
            "------------------------------------------------"
        ]

        return lines.joined(separator: "\n")
    }
    struct LastInvoicePill: View {
        let isRtl: Bool
        let title: String        // e.g. "הזמנה אחרונה: מיכל"
        let onPrint: () -> Void
        let onClose: () -> Void

        private var namePart: String {
            // Extract part after ":" if exists
            if let idx = title.firstIndex(of: ":") {
                let raw = title[title.index(after: idx)...]
                return raw.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return title
        }

        var body: some View {
            VStack(spacing: 10) {

           

                // Title "הזמנה אחרונה"
                Text("הזמנה אחרונה")
                    .font(.system(size: 14, weight: .semibold))
                
                    .multilineTextAlignment(.center)

                // Customer name or order number
                if !namePart.isEmpty {
                    Text(namePart)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }

                // Invoice button
                Button(action: onPrint) {
                    Text("הדפס חשבונית")
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.1))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 4)

            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.black.opacity(0.06))
            )
            .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
        }
    }
    
  

    struct ReportPreviewSheet: View {
        let isRtl: Bool
        let type: CashPointView.ReportType
        let shopId: Int

        // ✅ opened from "שחזר דוח"
        let restoreMode: Bool

        // ✅ selected date for restore
        @Binding var restoreDate: Date

        let onClose: () -> Void
        let onPrint: () -> Void

        @State private var showCloseZSheet = false
        @State private var managerName: String = ""

        @StateObject private var model: ReportPreviewModel

        private var mono: Font { .system(size: 14, weight: .regular, design: .monospaced) }
        private var monoBold: Font { .system(size: 14, weight: .semibold, design: .monospaced) }

        private var yesterday: Date {
            Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        }

        /// Date used to FETCH the Z row (selected day)
        private var queryDate: Date {
            Calendar.current.date(byAdding: .day, value: +0, to: restoreDate) ?? restoreDate
        }

        /// Date shown on screen + printed on receipt
        private var printDate: Date { restoreDate }

        private var businessDayForPrint: Date {
            // If the API returned a business date, it wins (both X and Z)
            if let bd = model.businessDate { return bd }

            // Restore Z fallback (if API didn’t return bd for some reason)
            if type == .z && restoreMode { return restoreDate }

            // Normal mode fallback (only if API didn’t return bd)
            return Date()
        }
        private func handlePrint() {
            guard let d = model.data else { return } // ✅ must have data
            PrinterManager.shared.printSalesReport(
                d,
                type: type,
                reportDate: businessDayForPrint,
                isRestore: (type == .z && restoreMode),
                generatedAt: Date()
            )
        }

        // ✅ Header date:
        // - Normal mode: today
        // - Restore Z: use DB BusinessDate if available, otherwise restoreDate
        private var headerDate: Date {
            if type == .z && restoreMode {
                return model.businessDate ?? restoreDate
            }
            return Date()
        }

        private var headerDateText: String {
            let df = DateFormatter()
            df.locale = Locale(identifier: "he_IL")
            df.timeZone = TimeZone(identifier: "Asia/Jerusalem")
            df.dateFormat = "dd/MM/yyyy"
            return df.string(from: headerDate)
        }

        private var generatedLine: String {
            let lrm = "\u{200E}"

            let t = DateFormatter()
            t.locale = Locale(identifier: "he_IL")
            t.timeZone = TimeZone(identifier: "Asia/Jerusalem")
            t.dateFormat = "HH:mm:ss"

            let d = DateFormatter()
            d.locale = Locale(identifier: "he_IL")
            d.timeZone = TimeZone(identifier: "Asia/Jerusalem")
            d.dateFormat = "dd/MM/yyyy"

            if type == .z && restoreMode {
                let shown = model.businessDate ?? restoreDate
                return "שחזור לתאריך \(lrm)\(d.string(from: shown))"
            }
            return "הופק בתאריך \(lrm)\(t.string(from: Date())) \(d.string(from: Date()))"
        }

        init(
            isRtl: Bool,
            type: CashPointView.ReportType,
            shopId: Int,
            initialData: PrinterManager.SalesReportData,
            restoreMode: Bool,
            restoreDate: Binding<Date>,
            onClose: @escaping () -> Void,
            onPrint: @escaping () -> Void
        ) {
            self.isRtl = true
            self.type = type
            self.shopId = shopId
            self.restoreMode = restoreMode
            self._restoreDate = restoreDate
            self.onClose = onClose
            self.onPrint = onPrint
            _model = StateObject(wrappedValue: ReportPreviewModel(initial: initialData))
        }

        var body: some View {
            NavigationStack {
                ZStack {
                    Color(.systemGroupedBackground).ignoresSafeArea()

                    VStack(spacing: 16) {

                        // TOP BAR (close)
                        HStack {
                            if isRtl { Spacer() }
                            Button(action: onClose) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 18, weight: .bold))
                                    .padding(10)
                                    .background(Color(.systemGray5))
                                    .clipShape(Circle())
                            }
                            if !isRtl { Spacer() }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 16)

                        Text(type.title)
                            .font(.system(size: 24, weight: .bold))
                            .padding(.top, 4)

                        // ✅ Restore date picker (visible row)
                        if type == .z && restoreMode {
                            HStack(spacing: 10) {
                                Image(systemName: "calendar")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(.secondary)

                                Text("תאריך")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(.secondary)

                                Spacer()

                                DatePicker(
                                    "",
                                    selection: $restoreDate,
                                    in: ...Date(),
                                    displayedComponents: [.date]
                                )
                                .datePickerStyle(.compact)
                                .labelsHidden()
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .padding(.horizontal, 20)
                            .padding(.top, 4)
                        }

                        ScrollView {
                            VStack(spacing: 20) {
                                headerBlock

                                if model.isLoading {
                                    ProgressView("טוען נתונים…")
                                        .padding(.vertical, 8)
                                }

                                if model.loadError != nil, !model.isLoading {
                                    Text("שגיאה בטעינת הדוח")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(.secondary)
                                        .padding(.vertical, 6)
                                }

                                // ✅ show tables only when data exists
                                if let _ = model.data {
                                    section("מכירות") { salesTable }
                                    section("תקבולים") { paymentsTable }
                                    section("דוח מזומן") { cashReportTable }
                                    section("תשר") { tipsTable }
                                    section("חריגים") { exceptionsTable }
                                }
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                        }

                        Spacer()

                        bottomButtons
                    }
                }
            }
            .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
            .task {
                if type == .z && restoreMode {
                    await model.load(type: type, shopId: shopId, for: queryDate)
                } else {
                    await model.load(type: type, shopId: shopId, for: nil)
                }
            }
            .onChange(of: restoreDate) { _ in
                guard type == .z && restoreMode else { return }
                Task {
                    await model.load(type: type, shopId: shopId, for: queryDate)
                }
            }
            .onAppear {
                if type == .z && restoreMode {
                    if Calendar.current.isDateInToday(restoreDate) || restoreDate > Date() {
                        restoreDate = yesterday
                    }
                }
            }
        }

        // MARK: - SECTION WRAPPER
        @ViewBuilder
        private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
            VStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 16, weight: .bold))
                    .frame(maxWidth: .infinity, alignment: .center)

                content()
                    .padding(10)
                    .frame(maxWidth: .infinity)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }

        // MARK: - HEADER
        private var headerBlock: some View {
            VStack(spacing: 4) {
                Text("Beit Ha'am")
                    .font(.system(size: 20, weight: .bold))

                Text("בית העם קונדיטוריה ויין בע\"מ").font(mono)
                Text("ח.פ / ע.מ. 516784139").font(mono)

                Spacer().frame(height: 8)

                Text("דוח תנועות פעיל \(type == .x ? "X" : "Z")")
                    .font(.system(size: 18, weight: .bold))

                Text(headerDateText).font(mono)
                Spacer().frame(height: 4)
                Text(generatedLine).font(mono)
            }
            .frame(maxWidth: .infinity)
        }

        // MARK: - TABLE HELPERS
        @ViewBuilder
        private func rtlHeader(_ cols: [String]) -> some View {
            HStack(spacing: 8) {
                ForEach(cols, id: \.self) { col in
                    Text(col).font(monoBold).frame(maxWidth: .infinity)
                }
            }
        }

        @ViewBuilder
        private func rtlRow(_ cols: [String]) -> some View {
            HStack(spacing: 8) {
                ForEach(cols, id: \.self) { col in
                    Text(col).font(mono).frame(maxWidth: .infinity)
                }
            }
        }

        // MARK: - SECTIONS

        private var salesTable: some View {
            guard let d = model.data else { return AnyView(EmptyView()) }

            let vat = model.vatRate
            func exVat(_ inc: Double) -> Double { inc / (1.0 + vat) }

            return AnyView(
                VStack(spacing: 4) {
                    rtlHeader(["סוג", "ללא מע\"מ", "כולל מע\"מ", "סועד", "PPA"])
                    Divider()

                    rtlRow([
                        "מסעדה",
                        String(format: "%.1f", exVat(d.totalRestaurantIncVat)),
                        String(format: "%.1f", d.totalRestaurantIncVat),
                        "\(d.dinersRestaurant)",
                        "\(d.ppaRestaurant)"
                    ])

                    rtlRow([
                        "TA",
                        String(format: "%.1f", exVat(d.totalTAIncVat)),
                        String(format: "%.1f", d.totalTAIncVat),
                        "\(d.dinersTA)",
                        "\(d.ppaTA)"
                    ])

                    rtlRow(["מכירות", "", String(format: "%.1f", d.totalSalesIncVat), "", ""])
                    rtlRow(["תשר", "", String(format: "%.1f", d.tipsTotal), "", ""])
                    rtlRow(["סה\"כ", "", String(format: "%.1f", d.grandTotal), "", ""])
                }
            )
        }

        private var paymentsTable: some View {
            guard let d = model.data else { return AnyView(EmptyView()) }

            return AnyView(
                VStack(spacing: 4) {
                    rtlHeader(["כמות", "סוג", "תשלום", "סכום"])
                    Divider()
                    rtlRow(["\(d.cashCount)", "-", "מזומן", String(format: "%.2f", d.cashAmount)])
                    rtlRow(["\(d.cardCount)", "-", "אשראי", String(format: "%.2f", d.cardAmount)])
                    Divider()
                    rtlRow(["\(d.collectionsTotalCount)", "", "סה\"כ", String(format: "%.2f", d.collectionsTotalAmount)])
                }
            )
        }

        private var cashReportTable: some View {
            guard let d = model.data else { return AnyView(EmptyView()) }

            let cashWithTip = d.cashAmount

            return AnyView(
                VStack(spacing: 4) {
                    rtlHeader(["סוג פעולה", "סוג מגירה", "סכום"])
                    Divider()
                    rtlRow(["הד. סגורות", "", String(format: "%.1f", cashWithTip)])
                    rtlRow(["הד. פתוחות", "", String(format: "%.1f", d.openDrawersAmount)])
                    rtlRow(["הפקדה/משיכה", "", String(format: "%.1f", d.depositWithdrawAmount)])
                    Divider()
                    rtlRow(["סה\"כ במגירה", "", String(format: "%.1f", cashWithTip)])
                    rtlRow(["", "מגירה ראשית", String(format: "%.1f", d.mainDrawerAmount)])
                    rtlRow(["", "עמדת מארחת", String(format: "%.1f", d.hostStationDrawerAmount)])
                }
            )
        }

        private var tipsTable: some View {
            guard let d = model.data else { return AnyView(EmptyView()) }

            return AnyView(
                VStack(spacing: 4) {
                    rtlHeader(["סוג", "אזור", "סכום"])
                    Divider()
                    rtlRow(["תשר", "", String(format: "%.1f", d.tipBaseTotal)])
                    rtlRow(["", "שולחנות מסעדה", String(format: "%.1f", d.tipRestaurant)])
                    rtlRow(["", "בר ולקחת", String(format: "%.1f", d.tipBarTakeaway)])
                    Divider()
                    rtlRow(["עודף טיפ", "", String(format: "%.1f", d.extraTipTotal)])
                    rtlRow(["", "מסעדה", String(format: "%.1f", d.extraTipRestaurant)])
                    rtlRow(["", "בר", String(format: "%.1f", d.extraTipBar)])
                }
            )
        }

        private var exceptionsTable: some View {
            guard let d = model.data else { return AnyView(EmptyView()) }

            return AnyView(
                VStack(spacing: 4) {
                    rtlHeader(["תיאור", "כמות", "סכום"])
                    Divider()
                    rtlRow(["הזמנות OTH", "\(d.ordersOTHCount)", String(format: "%.1f", d.ordersOTHAmount)])
                    rtlRow(["מנות OTH", "\(d.itemsOTHCount)", String(format: "%.1f", d.itemsOTHAmount)])
                    rtlRow(["ביטולי מנות", "\(d.canceledItemsCount)", String(format: "%.1f", d.canceledItemsAmount)])
                    rtlRow(["החזרי מנות", "\(d.refundedItemsCount)", String(format: "%.1f", d.refundedItemsAmount)])
                    rtlRow(["הנחות", "\(d.discountsCount)", String(format: "%.1f", d.discountsAmount)])
                    rtlRow(["החזר הנחות", "\(d.discountsRefundCount)", String(format: "%.1f", d.discountsRefundAmount)])
                }
            )
        }

        // MARK: - BOTTOM BUTTONS
        @ViewBuilder
        private var bottomButtons: some View {
            let canPrint = (model.data != nil) && !model.isLoading && (model.loadError == nil)

            if type == .x {
                Button(action: handlePrint) {
                    Text("הדפס")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .opacity(canPrint ? 1 : 0.5)
                }
                .disabled(!canPrint)
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
            } else {
                HStack(spacing: 12) {
                    Button(action: handlePrint) {
                        Text("הדפס")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .opacity(canPrint ? 1 : 0.5)
                    }
                    .disabled(!canPrint)

                    if !restoreMode {
                        Button {
                            showCloseZSheet = true
                        } label: {
                            Text("סגור דו״ח Z")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(.primary)
                                .frame(maxWidth: .infinity)
                                .frame(height: 52)
                                .background(Color(.systemGray5))
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
                .sheet(isPresented: $showCloseZSheet) {
                    CloseZConfirmSheet(
                        managerName: $managerName,
                        onCancel: {
                            showCloseZSheet = false
                            managerName = ""
                        },
                        onCloseZ: {
                            showCloseZSheet = false
                            onClose()
                        }
                    )
                }
            }
        }
    }
    private struct CloseZConfirmSheet: View {
        @Environment(\.dismiss) private var dismiss
        @Binding var managerName: String

        let onCancel: () -> Void
        let onCloseZ: () -> Void

        private var todayText: String {
            let df = DateFormatter()
            df.locale = Locale(identifier: "he_IL")
            df.dateFormat = "dd/MM/yyyy"
            return df.string(from: Date())
        }

        var body: some View {
            NavigationStack {
                Form {
                    Section {
                        HStack {
                            Text("תאריך")
                            Spacer()
                            Text(todayText).foregroundColor(.secondary)
                        }
                    }

                    Section("מנהל") {
                        TextField("שם מלא", text: $managerName)
                            .textInputAutocapitalization(.words)
                    }

                    Section {
                        HStack(spacing: 12) {

                            Button(action: {
                                onCloseZ()
                            }) {
                                Text("סגור Z")
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 52)
                                    .background(Color.black)
                                    .clipShape(RoundedRectangle(cornerRadius: 16))
                            }
                            .disabled(managerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .opacity(managerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)

                            Button(action: {
                                onCancel()
                            }) {
                                Text("בטל")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundColor(.primary)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 52)
                                    .background(Color(.systemGray5))
                                    .clipShape(RoundedRectangle(cornerRadius: 16))
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }
                .navigationTitle("סגירת דו״ח Z")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }
    
    @ViewBuilder
    func optionChip(entry: BasketEntry, group: ModifierGroup, opt: ModifierItem) -> some View {
        if isModifierVisible(opt) {
            let isSelected = (optionSelections[entry.id] ?? [:])[group.title] == opt.name
            let key = freezeKey(productId: entry.item.id, groupTitle: group.title, optionName: opt.name)
            let frozenFromJson = (opt.status ?? 1) == 0
            let frozenLocal = (localFrozenOverrides[key] == true)
            let isFrozen = frozenFromJson || frozenLocal
            let shownName = displayModifierName(opt)

            Text(
                modifierPriceLabel(opt.extraPrice).isEmpty
                ? shownName
                : "\(shownName) \(modifierPriceLabel(opt.extraPrice))"
            )
            .font(.system(size: 17, weight: .medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(isSelected ? (colorScheme == .dark ? .white : .black) : Color(.systemGray5))
            .foregroundColor(isSelected ? (colorScheme == .dark ? .black : .white) : .primary)
            .opacity(isFrozen ? 0.35 : 1.0)
            .overlay(alignment: .topTrailing) {
                if isFrozen {
                    Image(systemName: "snowflake")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)
                        .padding(.top, 2)
                        .padding(.trailing, 2)
                }
            }
            .clipShape(Capsule())
            .onTapGesture {
                guard !isFrozen else { Haptics.error(); return }
                var map = optionSelections[entry.id] ?? [:]
                map[group.title] = opt.name
                optionSelections[entry.id] = map
                updateEntryPricingAndSubtitle(lineId: entry.id)
                Haptics.light()
            }
        }
    }
    
  
    private func isGroupRequired(_ group: ModifierGroup) -> Bool {
        (group.selection?.required ?? 0) > 0
    }
    
    private func basketRow(_ entry: BasketEntry) -> some View {
        let isLocked = lockedLineIds.contains(entry.id)
        let isExpanded = !isLocked && expandedBasketLineId == entry.id
        let swipeOffset = basketSwipeOffsets[entry.id] ?? 0
        let lineTotal = Double(entry.quantity) * entry.unitPrice

        let groups = entry.item.modifiers ?? []
        let optionsMap = optionSelections[entry.id] ?? [:]
        let additionsMap = additionSelections[entry.id] ?? [:]
        let additionsModes = additionGroupModes[entry.id] ?? [:]

        let missingRequiredGroups: Set<String> = {
            var missing = Set<String>()

            for g in groups where g.type == .options {
                let isRequired = (g.selection?.required ?? 0) > 0
                guard isRequired else { continue }

                let selectedValue = optionsMap[g.title]?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if selectedValue.isEmpty {
                    missing.insert(g.title)
                }
            }

            return missing
        }()

        let hasMissingRequired = !missingRequiredGroups.isEmpty

        let noteBinding = Binding<String>(
            get: {
                if let existing = noteDrafts[entry.id] {
                    return existing
                }
                return noteFromSubtitle(entry.subtitle)
            },
            set: { newValue in
                noteDrafts[entry.id] = newValue
                updateEntryPricingAndSubtitle(lineId: entry.id)
            }
        )

        let sentOpacity: Double = isLocked ? 0.42 : 1.0
        let sentBg: Color = isLocked ? Color(.systemGray6) : Color.clear

        let content = ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(entry.item.name)
                            .font(.system(size: 20, weight: .medium))
                            .foregroundColor(hasMissingRequired ? .purple : .primary)
                            .strikethrough(isLocked, color: .secondary)

                        Text(String(format: "\(currency)%.0f", lineTotal))
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.secondary)
                            .scaleEffect(pricePulseLineId == entry.id ? pricePulseScale : 1.0)

                        if let s = entry.subtitle, !s.isEmpty, !isExpanded {

                            let parts = (cleanModifierSubtitle(s) ?? s)
                                .components(separatedBy: ",")
                                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                                .filter { !$0.isEmpty }

                            if !parts.isEmpty {
                                FlowLayout(data: parts, spacing: 6) { part in
                                    Text(part)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundColor(.primary)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(Color(.systemGray5))
                                        .clipShape(Capsule())
                                }
                                .padding(.leading, 4)
                                .padding(.top, 2)
                            }
                        }
                    }

                    Spacer()

                    HStack(spacing: 8) {
                        if !isLocked {
                            Button {
                                decrementEntry(entry.id)
                                pulsePrice(for: entry.id)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .font(.system(size: 22))
                            }
                        }

                        Text("\(entry.quantity)")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(minWidth: 26)

                        if !isLocked {
                            Button {
                                incrementEntry(entry.id)
                                pulsePrice(for: entry.id)
                            } label: {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 22))
                            }
                        }
                    }
                }

                if isExpanded {
                    if !groups.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(groups.indices, id: \.self) { index in
                                let g = groups[index]

                                if index > 0 {
                                    Rectangle()
                                        .fill(Color.black.opacity(0.06))
                                        .frame(height: 1)
                                        .padding(.vertical, 4)
                                }

                                VStack(alignment: .leading, spacing: 6) {
                                    Text(g.title)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(missingRequiredGroups.contains(g.title) ? .purple : .primary)

                                    switch g.type {
                                    case .options:
                                        VStack(alignment: .leading, spacing: 8) {

                                            FlowLayout(data: g.items, spacing: 8) { opt in
                                                optionChip(entry: entry, group: g, opt: opt)
                                            }

                                        }
                                        .frame(maxWidth: .infinity, alignment: isRtl ? .leading : .trailing)
                                        .padding(10)
                                        .background(
                                            RoundedRectangle(cornerRadius: 12)
                                                .fill(missingRequiredGroups.contains(g.title) ? Color.purple.opacity(0.06) : Color.clear)
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 12)
                                                .stroke(
                                                    missingRequiredGroups.contains(g.title) ? Color.purple.opacity(0.35) : Color.clear,
                                                    lineWidth: 1
                                                )
                                        )

                                    case .additions:
                                        let selectedMode = additionsModes[g.title] ?? .with
                                        let groupSelections = additionsMap[g.title] ?? [:]
                                        let selectedSetForCurrentMode = groupSelections[selectedMode] ?? []

                                        let withItems = Array(groupSelections[.with] ?? []).sorted()
                                        let withoutItems = Array(groupSelections[.without] ?? []).sorted()
                                        let sideItems = Array(groupSelections[.side] ?? []).sorted()

                                        let withPills = withItems.map { "עם \($0)" }
                                        let withoutPills = withoutItems.map { "בלי \($0)" }
                                        let sidePills = sideItems.map { "\($0) בצד" }

                                        let order = additionOrder[entry.id] ?? []

                                        let summaryPills = order.compactMap { name -> String? in
                                            if additionsMap[g.title]?[.with]?.contains(name) == true {
                                                return "עם \(name)"
                                            }
                                            if additionsMap[g.title]?[.without]?.contains(name) == true {
                                                return "בלי \(name)"
                                            }
                                            if additionsMap[g.title]?[.side]?.contains(name) == true {
                                                return "\(name) בצד"
                                            }
                                            return nil
                                        }

                                        VStack(alignment: .leading, spacing: 10) {
                                            HStack(spacing: 8) {
                                                if !isRtl { Spacer() }

                                                additionModeChip(
                                                    title: "עם",
                                                    selected: selectedMode == .with
                                                ) {
                                                    var map = additionGroupModes[entry.id] ?? [:]
                                                    map[g.title] = .with
                                                    additionGroupModes[entry.id] = map
                                                    Haptics.light()
                                                }

                                                additionModeChip(
                                                    title: "בלי",
                                                    selected: selectedMode == .without
                                                ) {
                                                    var map = additionGroupModes[entry.id] ?? [:]
                                                    map[g.title] = .without
                                                    additionGroupModes[entry.id] = map
                                                    Haptics.light()
                                                }

                                                additionModeChip(
                                                    title: "בצד",
                                                    selected: selectedMode == .side
                                                ) {
                                                    var map = additionGroupModes[entry.id] ?? [:]
                                                    map[g.title] = .side
                                                    additionGroupModes[entry.id] = map
                                                    Haptics.light()
                                                }

                                                if isRtl { Spacer() }
                                            }

                                            if !summaryPills.isEmpty {
                                                FlowLayout(data: summaryPills, spacing: 8) { text in
                                                    Text(text)
                                                        .font(.system(size: 15, weight: .semibold))
                                                        .foregroundColor(.primary)
                                                        .padding(.horizontal, 10)
                                                        .padding(.vertical, 6)
                                                        .background(Color.white.opacity(0.15))
                                                        .clipShape(Capsule())
                                                }
                                            }
                                            let rowStarts = Array(stride(from: 0, to: g.items.count, by: 3))

                                            ForEach(rowStarts, id: \.self) { start in
                                                let end = min(start + 3, g.items.count)
                                                let rowItems = Array(g.items[start..<end])

                                                HStack(spacing: 8) {
                                                    if !isRtl { Spacer() }

                                                    ForEach(rowItems.filter { isModifierVisible($0) }) { opt in
                                                        let isSelected = selectedSetForCurrentMode.contains(opt.name)
                                                        let key = freezeKey(productId: entry.item.id, groupTitle: g.title, optionName: opt.name)
                                                        let frozenFromJson = (opt.status ?? 1) == 0
                                                        let frozenLocal = (localFrozenOverrides[key] == true)
                                                        let isFrozen = frozenFromJson || frozenLocal

                                                        let shownName = displayModifierName(opt)

                                                        Text(
                                                            modifierPriceLabel(opt.extraPrice).isEmpty
                                                            ? shownName
                                                            : "\(shownName) \(modifierPriceLabel(opt.extraPrice))"
                                                        )
                                                        .font(.system(size: 17, weight: .medium))
                                                        .padding(.horizontal, 16)
                                                        .padding(.vertical, 8)
                                                        .background(
                                                            isSelected
                                                            ? (colorScheme == .dark ? .white : .black)
                                                            : Color(.systemGray5)
                                                        )
                                                        .foregroundColor(
                                                            isSelected
                                                            ? (colorScheme == .dark ? .black : .white)
                                                            : .primary
                                                        )
                                                        .opacity(isFrozen ? 0.35 : 1.0)
                                                        .overlay(alignment: .topTrailing) {
                                                            if isFrozen {
                                                                Image(systemName: "snowflake")
                                                                    .font(.system(size: 10, weight: .bold))
                                                                    .foregroundColor(.secondary)
                                                                    .padding(.top, 2)
                                                                    .padding(.trailing, 2)
                                                            }
                                                        }
                                                        .clipShape(Capsule())
                                                        .onTapGesture {
                                                            guard !isFrozen else {
                                                                Haptics.error()
                                                                return
                                                            }

                                                            var lineMap = additionSelections[entry.id] ?? [:]
                                                            var groupMap = lineMap[g.title] ?? [
                                                                .with: [],
                                                                .without: [],
                                                                .side: []
                                                            ]

                                                            if isSelected {
                                                                groupMap[selectedMode]?.remove(opt.name)

                                                                additionOrder[entry.id]?.removeAll { $0 == opt.name }

                                                            } else {
                                                                groupMap[.with]?.remove(opt.name)
                                                                groupMap[.without]?.remove(opt.name)
                                                                groupMap[.side]?.remove(opt.name)

                                                                groupMap[selectedMode, default: []].insert(opt.name)

                                                                var order = additionOrder[entry.id] ?? []
                                                                order.removeAll { $0 == opt.name }
                                                                order.append(opt.name)            // ⭐ preserves tap order
                                                                additionOrder[entry.id] = order
                                                            }

                                                            lineMap[g.title] = groupMap
                                                            additionSelections[entry.id] = lineMap

                                                            updateEntryPricingAndSubtitle(lineId: entry.id)
                                                            Haptics.light()
                                                        }
                                                        .contextMenu {
                                                            Button(isFrozen ? "הפשר" : "הקפא") {
                                                                let targetEnabled = isFrozen
                                                                let optimisticFrozen = !targetEnabled

                                                                localFrozenOverrides[freezeKey(
                                                                    productId: entry.item.id,
                                                                    groupTitle: g.title,
                                                                    optionName: opt.name
                                                                )] = optimisticFrozen

                                                                Haptics.light()

                                                                Task {
                                                                    let ok = await ModifierStatusAPI.setItemStatus(
                                                                        productId: entry.item.id,
                                                                        groupId: g.groupId,
                                                                        title: g.title,
                                                                        optionName: opt.name,
                                                                        enabled: targetEnabled
                                                                    )

                                                                    await MainActor.run {
                                                                        if ok {
                                                                            Haptics.success()
                                                                            safeReloadMenu(reason: "modifier freeze")
                                                                        } else {
                                                                            localFrozenOverrides[freezeKey(
                                                                                productId: entry.item.id,
                                                                                groupTitle: g.title,
                                                                                optionName: opt.name
                                                                            )] = frozenFromJson
                                                                            Haptics.error()
                                                                        }
                                                                    }
                                                                }
                                                            }
                                                        }
                                                        .environment(\.layoutDirection, .rightToLeft)
                                                    }

                                                    if isRtl { Spacer() }
                                                }
                                            }
                                        }
                                        .padding(10)
                                    }
                                }
                            }
                        }
                        .padding(.top, 6)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(isRtl ? "הערות" : "Notes")
                            .font(.system(size: 13, weight: .semibold))

                        Button {
                            noteEditingLineId = entry.id
                            noteEditingText = noteBinding.wrappedValue
                        } label: {
                            HStack {
                                if noteBinding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Text(isRtl ? "הוסף הערה..." : "Add a note…")
                                        .foregroundColor(.secondary)
                                } else {
                                    Text(noteBinding.wrappedValue)
                                        .lineLimit(1)
                                        .foregroundColor(.primary)
                                }
                                Spacer()
                            }
                            .padding(8)
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 6)
                }
            }

            if isLocked {
                Text(isRtl ? "נשלח" : "Sent")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(.systemBackground))
                    .clipShape(Capsule())
                    .padding(.top, 10)
                    .padding(.trailing, 12)
            }
        }

        return VStack(spacing: 0) {
            content
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12).fill(sentBg)
                )
                .opacity(sentOpacity)
                .saturation(isLocked ? 0.45 : 1.0)

            Rectangle()
                .fill(Color.black.opacity(0.06))
                .frame(height: 1)
                .padding(.leading, 16)
        }
        .offset(x: swipeOffset)
        .contentShape(Rectangle())
        .simultaneousGesture(basketSwipeGesture(for: entry))
        .sheet(item: Binding(
            get: { noteEditingLineId.map { NoteEditHandle(id: $0) } },
            set: { handle in noteEditingLineId = handle?.id }
        )) { handle in
            let lineId = handle.id

            NoteEditSheet(
                isRtl: isRtl,
                initialText: noteEditingText
            ) { newText in
                noteDrafts[lineId] = newText
                updateEntryPricingAndSubtitle(lineId: lineId)
                noteEditingLineId = nil
            } onCancel: {
                noteEditingLineId = nil
            }
            .presentationDetents([.height(260)])
            .presentationDragIndicator(.hidden)
        }
        .onTapGesture {
            guard !isLocked else { return }

            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                if expandedBasketLineId == entry.id {
                    expandedBasketLineId = nil
                } else {
                    expandedBasketLineId = entry.id
                }
            }
        }
        .onAppear {
            print("🧪 basketRow product =", entry.item.name)

            for g in groups {
                print("""
                🧪 group title = \(g.title)
                   type = \(g.type)
                   required = \(g.selection?.required ?? -1)
                   defaultFirst = \(g.selection?.defaultFirst ?? -1)
                   selected now = \(optionSelections[entry.id]?[g.title] ?? "nil")
                   items = \(g.items.map(\.name))
                """)
            }

            if optionSelections[entry.id] == nil {
                var map = optionsFromSubtitle(entry.subtitle)

                for g in groups where g.type == .options {
                    if map[g.title] != nil { continue }

                    let isRequired = (g.selection?.required ?? 0) > 0

                    print("🧪 deciding group \(g.title) isRequired=\(isRequired)")

                    if isRequired {
                        print("🧪 required group -> leave empty")
                        continue
                    }

                    if let first = g.items.first?.name {
                        print("🧪 optional group -> default first =", first)
                        map[g.title] = first
                    }
                }

                print("🧪 final initial map =", map)

                optionSelections[entry.id] = map
                updateEntryPricingAndSubtitle(lineId: entry.id)
            }

            if additionSelections[entry.id] == nil {
                var lineMap: [String: [AdditionMode: Set<String>]] = [:]

                for g in groups where g.type == .additions {
                    lineMap[g.title] = [
                        .with: [],
                        .without: [],
                        .side: []
                    ]
                }

                additionSelections[entry.id] = lineMap
            }

            if additionGroupModes[entry.id] == nil {
                var map: [String: AdditionMode] = [:]

                for g in groups where g.type == .additions {
                    map[g.title] = .with
                }

                additionGroupModes[entry.id] = map
            }

            updateEntryPricingAndSubtitle(lineId: entry.id)
        }
    }
    private func freshQuantityInBasket(for item: ShellMenuItem) -> Int {
        basket.values
            .filter { $0.item.id == item.id }
            .filter { !lockedLineIds.contains($0.id) }   // ✅ only unsent lines
            .reduce(0) { $0 + $1.quantity }
    }
    
    private struct NoteEditHandle: Identifiable {
        let id: Int
    }

    private struct NoteEditSheet: View {
        let isRtl: Bool
        let initialText: String
        let onSave: (String) -> Void
        let onCancel: () -> Void

        @State private var text: String = ""
        @FocusState private var focused: Bool

        private var trimmedText: String {
            text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private var hasText: Bool {
            !trimmedText.isEmpty
        }

        private var placeholder: String {
            isRtl ? "הוסף הערה..." : "Add a note…"
        }

        var body: some View {
            NavigationStack {
                VStack(spacing: 16) {

                    // ✅ Text field with REAL placeholder (no default "0")
                    ZStack(alignment: isRtl ? .topTrailing : .topLeading) {

                        // Placeholder layer (only when empty)
                        if trimmedText.isEmpty {
                            Text(placeholder)
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 14)
                                .frame(maxWidth: .infinity,
                                       alignment: isRtl ? .topTrailing : .topLeading)
                                .allowsHitTesting(false)
                        }

                        // Actual editor
                        TextField("", text: $text, axis: .vertical)
                            .lineLimit(2...4)
                            .padding(12)
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(12)
                            .focused($focused)
                            .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)

                        // Clear button
                        if hasText {
                            Button { text = "" } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(.secondary)
                                    .padding(8)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Spacer()

                    // Save button – text can be empty (clears note)
                    Button {
                        onSave(trimmedText)   // "" = remove note
                    } label: {
                        Text(isRtl ? "שמירה" : "Save")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(.black)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                }
                .padding(20)
                .navigationTitle(isRtl ? "הערה לפריט" : "Item note")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { onCancel() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 16, weight: .bold))
                                .padding(8)
                                .background(Color(.systemGray5))
                                .clipShape(Circle())
                        }
                    }
                }
                .onAppear {
                    // ✅ Treat "0" as empty so placeholder shows
                    let cleaned = initialText
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    text = (cleaned == "0") ? "" : cleaned

                    // focus after present
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        focused = true
                    }
                }
            }
            .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
        }
    }
}



struct CashCategoryRail: View {
    let categories: [String]
    let selected: String
    let onTap: (String) -> Void
    let onOrdersTap: () -> Void

    let enableReorder: Bool

    @Binding var draggingCategory: String?
    @Binding var categoryOrder: [String]

    @Binding var renamingCategory: String?
    @Binding var renamingText: String

    @Binding var draggingProduct: ShellMenuItem?

    let onRenameCommit: (String, String) -> Void
    let onProductDroppedToCategory: (Int, String) -> Void
    let onReorderCommitted: () -> Void

    @FocusState private var renameFocusedCategory: String?

    private func normalized(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isSpecialCategory(_ cat: String) -> Bool {
        cat == "✏️ הערות" || cat == "ארכיון"
    }

    private func startRename(_ cat: String) {
        guard !isSpecialCategory(cat) else { return }
        renamingCategory = cat
        renamingText = cat

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            renameFocusedCategory = cat
        }
    }

    private func cancelRename() {
        renamingCategory = nil
        renamingText = ""
        renameFocusedCategory = nil
    }

    private func commitRename(for cat: String) {
        let oldValue = normalized(cat)
        let newValue = normalized(renamingText)

        renamingCategory = nil
        renameFocusedCategory = nil

        guard !oldValue.isEmpty, !newValue.isEmpty, oldValue != newValue else { return }
        onRenameCommit(oldValue, newValue)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(categories, id: \.self) { cat in
                    let isSelected = (cat == selected)
                    let isRenaming = (renamingCategory == cat)
                    let isSpecial = isSpecialCategory(cat)

                    let row =
                        HStack {
                            HStack(spacing: 6) {
                                if cat == "ארכיון" {
                                    Image(systemName: "archivebox.fill")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(isSelected ? .white : .primary)
                                }

                                if isRenaming {
                                    TextField("", text: $renamingText)
                                        .font(.system(size: 17, weight: .medium))
                                        .foregroundColor(isSelected ? .white : .primary)
                                        .textFieldStyle(.plain)
                                        .submitLabel(.done)
                                        .focused($renameFocusedCategory, equals: cat)
                                        .onSubmit {
                                            commitRename(for: cat)
                                        }
                                } else {
                                    Text(cat)
                                        .font(.system(size: 17, weight: .medium))
                                        .foregroundColor(isSelected ? .white : .primary)
                                        .lineLimit(1)
                                }
                            }
                            .padding(.vertical, 10)
                            .padding(.horizontal, 12)

                            Spacer()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(isSelected ? .black : Color.clear)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if renamingCategory != nil {
                                cancelRename()
                            }
                            onTap(cat)
                        }
                        .onTapGesture(count: 2) {
                            if !isRenaming {
                                startRename(cat)
                            }
                        }
                        .onDrop(
                            of: [.text],
                            delegate: CashPointView.ProductToCategoryDropDelegate(
                                targetCategory: cat,
                                draggingProduct: $draggingProduct,
                                onMove: onProductDroppedToCategory
                            )
                        )

                    if enableReorder && !isRenaming && !isSpecial {
                        row
                            .onDrag {
                                draggingCategory = cat
                                return NSItemProvider(object: cat as NSString)
                            }
                            .onDrop(
                                of: [.text],
                                delegate: CashPointView.CategoryDropDelegate(
                                    target: cat,
                                    order: $categoryOrder,
                                    dragging: $draggingCategory,
                                    onCommitted: onReorderCommitted
                                )
                            )
                    } else {
                        row
                    }
                }
            }
            .padding(.top, 12)
            .padding(.bottom, UIDevice.current.userInterfaceIdiom == .phone ? 60 : 12)
            .padding(.horizontal, 8)
        }
        .background(Color(.systemGray6))
    }
    
    
}



struct CashProductTile: View {
    let item: ShellMenuItem
    let quantityInBasket: Int?
    let isOutOfStock: Bool
    let isArchived: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(item.name)
                        .font(.system(size: 20, weight: .regular))
                        .lineLimit(2)

                    Spacer()
                }

                Text(item.priceLabel)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.secondary)

                if let qty = quantityInBasket, qty > 0 {
                    Text("\(qty)x")
                        .font(.system(size: 18, weight: .bold))
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 70, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(.systemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.black.opacity(0.05), lineWidth: 1)
            )
            .opacity(isOutOfStock ? 0.4 : (isArchived ? 0.72 : 1.0))

            VStack(alignment: .trailing, spacing: 6) {
                if isArchived {
                    Text("ארכיון")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color(.systemGray5))
                        .clipShape(Capsule())
                }

                if isOutOfStock {
                    Text("אזל")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(.systemGray5))
                        .clipShape(Capsule())
                }
            }
            .padding(6)
        }
    }
}







final class TerminalPaymentHandler {
    static let shared = TerminalPaymentHandler()
    
    func startPayment(amount: Double, completion: @escaping (Bool) -> Void) {
        // Replace with real terminal integration.
        // For now, simulate payment result.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let success = Bool.random()   // or always true while testing
            completion(success)
        }
    }
}

struct POSProductSheet: View {
    let item: ShellMenuItem
    let initialQuantity: Int
    let initialSelectedOptions: [String: String]
    let isUpdate: Bool
    let maxQuantity: Int?               // nil = no upper limit
    let onAdd: (ShellMenuItem, Int, String?, Double) -> Void
    @State private var customMessage: String = ""
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isRtl) private var isRtl
    @Environment(\.currency) private var currency

    @State private var quantity: Int
    @State private var selectedOptions: [String: String]
    @State private var selectedAdditions: Set<String> = []

    private var hasModifiers: Bool { !(item.modifiers?.isEmpty ?? true) }

    private var isRemoveMode: Bool {
        isUpdate && quantity == 0
    }

    init(
        item: ShellMenuItem,
        initialQuantity: Int,
        initialSelectedOptions: [String: String],
        isUpdate: Bool,
        maxQuantity: Int?,
        onAdd: @escaping (ShellMenuItem, Int, String?, Double) -> Void
    ) {
        self.item = item
        self.initialQuantity = initialQuantity
        self.initialSelectedOptions = initialSelectedOptions
        self.isUpdate = isUpdate
        self.maxQuantity = maxQuantity
        self.onAdd = onAdd
        _quantity = State(initialValue: initialQuantity)
        _selectedOptions = State(initialValue: initialSelectedOptions)
    }

    private func extraPricePerUnit() -> Double {
        guard let groups = item.modifiers else { return 0 }
        return groups.reduce(0) { total, g in
            switch g.type {
            case .options:
                if let sel = selectedOptions[g.title],
                   let opt = g.items.first(where: { $0.name == sel }) {
                    return total + opt.extraPrice
                }
                return total
            case .additions:
                return total + g.items
                    .filter { selectedAdditions.contains($0.name) }
                    .map { $0.extraPrice }
                    .reduce(0, +)
            }
        }
    }

    private func subtitle() -> String? {
        guard let groups = item.modifiers else { return nil }
        let parts = groups.compactMap { group -> String? in
            guard group.type == .options else { return nil }
            guard
                let sel = selectedOptions[group.title],
                let first = group.items.first,
                sel != first.name
            else { return nil }
            return "\(group.title): \(sel)"
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private var unitPrice: Double { item.price + extraPricePerUnit() }
    private var totalPrice: Double { unitPrice * Double(quantity) }

    private var detents: Set<PresentationDetent> {
        let h = UIScreen.main.bounds.height
        return [.height(h * 0.96), .large]
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.name)
                            .font(.system(size: 24, weight: .bold))
                            .lineLimit(2)
                        Text(String(format: "\(currency)%.2f", item.price))
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.primary)
                            .frame(width: 32, height: 32)
                            .background(Color(.systemGray5))
                            .clipShape(Circle())
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 8)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if let groups = item.modifiers {
                            ForEach(groups) { g in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(g.title)
                                        .font(.system(size: 18, weight: .semibold))
                                    
                                    if g.type == .options {
                                        // SINGLE-SELECT OPTIONS (existing behaviour)
                                        ScrollView(.horizontal, showsIndicators: false) {
                                            HStack(spacing: 8) {
                                                ForEach(g.items) { opt in
                                                    let selected = selectedOptions[g.title] == opt.name
                                                    Text(opt.extraPrice > 0
                                                         ? "\(opt.name) +\(Int(opt.extraPrice))"
                                                         : opt.name)
                                                    .font(.system(size: 15))
                                                    .padding(.horizontal, 14)
                                                    .padding(.vertical, 8)
                                                    .background(selected ? Color.black : Color(.systemGray5))
                                                    .foregroundColor(selected ? .white : .primary)
                                                    .clipShape(Capsule())
                                                    .onTapGesture {
                                                        selectedOptions[g.title] = opt.name
                                                        Haptics.light()
                                                    }
                                                }
                                            }
                                        }
                                        
                                    } else {
                                        // MULTI-SELECT ADDITIONS – same chip design, but toggle on/off
                                        ScrollView(.horizontal, showsIndicators: false) {
                                            HStack(spacing: 8) {
                                                ForEach(g.items) { opt in
                                                    let selected = selectedAdditions.contains(opt.name)
                                                    
                                                    Text(opt.extraPrice > 0
                                                         ? "\(opt.name) +\(Int(opt.extraPrice))"
                                                         : opt.name)
                                                    .font(.system(size: 15))
                                                    .padding(.horizontal, 14)
                                                    .padding(.vertical, 8)
                                                    .background(selected ? Color.black : Color(.systemGray5))
                                                    .foregroundColor(selected ? .white : .primary)
                                                    .clipShape(Capsule())
                                                    .onTapGesture {
                                                        var set = selectedAdditions
                                                        if selected {
                                                            set.remove(opt.name)
                                                        } else {
                                                            set.insert(opt.name)
                                                        }
                                                        selectedAdditions = set
                                                        Haptics.light()
                                                    }
                                                }
                                            }
                                        }
                                    }
                                
                                }
                            }
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text(isRtl ? "הערה" : "Item note")
                                .font(.system(size: 18, weight: .semibold))

                            TextField(isRtl ? "הקלד הערה..." : "Enter a note…", text: $customMessage, axis: .vertical)
                                .lineLimit(1)
                                .padding(10)
                                .background(Color(.secondarySystemBackground))
                                .cornerRadius(8)
                        }
                        .padding(.top, 10)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                }
                .padding(.bottom, 90)
            }
        }
        .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
        .presentationDetents(detents)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                Spacer().frame(height: 10)
                bottomBar
                    .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
                    .padding(.horizontal, 24)
                Spacer().frame(height: 10)
            }
            .background(Color(.systemBackground))
        }
        .onAppear {
   

            if let groups = item.modifiers {
                for g in groups where g.type == .options {
                    if selectedOptions[g.title] == nil,
                       let first = g.items.first {
                        selectedOptions[g.title] = first.name
                    }
                }
            }
            if let maxQ = maxQuantity, quantity > maxQ {
                quantity = maxQ
            }
        }
    }

    private func finalSubtitle() -> String? {
        let opt = subtitle()    // options string
        let msg = customMessage.trimmingCharacters(in: .whitespacesAndNewlines)

        let optClean = opt?.trimmingCharacters(in: .whitespacesAndNewlines)
        let msgClean = msg.isEmpty ? nil : msg

        if let optClean, let msgClean {
            // Important: we use " • " to split later
            return "\(optClean) • \(msgClean)"
        }
        if let optClean { return optClean }
        if let msgClean { return msgClean }
        return nil
    }
    
    /// Recalculate unitPrice + subtitle after inline changes in basket
  
    
    private var bottomBar: some View {
        HStack(spacing: 16) {
            HStack(spacing: 24) {
                Button {
                    if isUpdate {
                        if quantity > 0 { quantity -= 1 }   // allow 0 in update mode
                    } else {
                        if quantity > 1 { quantity -= 1 }   // min 1 in add mode
                    }
                    Haptics.light()
                } label: {
                    Circle()
                        .fill(Color(.systemGray5))
                        .frame(width: 44, height: 44)
                        .overlay(Image(systemName: "minus"))
                }

                Text("\(quantity)")
                    .font(.system(size: 22, weight: .bold))

                Button {
                    if let maxQ = maxQuantity, quantity >= maxQ {
                        Haptics.error()
                        return
                    }
                    quantity += 1
                    Haptics.light()
                } label: {
                    Circle()
                        .fill(Color(.systemGray5))
                        .frame(width: 44, height: 44)
                        .overlay(Image(systemName: "plus"))
                }
            }

            Button {
                onAdd(item, quantity, finalSubtitle(), unitPrice)
                Haptics.success()
                dismiss()
            } label: {
                HStack {
                    if isRtl {
                        Text(isRemoveMode ? "הסר" : (isUpdate ? "עדכן" : "הוסף להזמנה"))
                    } else {
                        Text(isRemoveMode ? "Remove" : (isUpdate ? "Update" : "Add to order"))
                    }
                    Spacer()
                    Text(String(format: "\(currency)%.2f", totalPrice))
                }
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 20)
                .frame(height: 60)
                .background(isRemoveMode ? Color.red :.black)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
        }
        .frame(height: 60)
    }
}


extension EnvironmentValues {
    var currencySymbol: String {
        self.isRtl ? "₪" : "£"
    }
}

struct CurrencyKey: EnvironmentKey {
    static let defaultValue = "£"
}

extension EnvironmentValues {
    var currency: String {
        get { self[CurrencyKey.self] }
        set { self[CurrencyKey.self] = newValue }
    }
}

struct QueuedCashpointEntry: Codable {
    let productId: Int
    let name: String
    let quantity: Int
    let unitPrice: Double
}

struct QueuedCashpointOrder: Codable {
    let entries: [QueuedCashpointEntry]
    let total: Double
    let diningMode: String
    let createdAt: Date
    let ticketNumber: Int?
}

enum CashpointOrderQueue {
    private static let storageKey = "pendingCashpointOrders"

    private static func load() -> [QueuedCashpointOrder] {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return [] }
        return (try? JSONDecoder().decode([QueuedCashpointOrder].self, from: data)) ?? []
    }

    private static func save(_ orders: [QueuedCashpointOrder]) {
        guard let data = try? JSONEncoder().encode(orders) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    static func enqueue(
        entries: [BasketEntry],
        total: Double,
        diningMode: DiningMode,
        ticketNumber: Int? = nil
    ) {
        var pending = load()
        let mapped = entries.map {
            QueuedCashpointEntry(
                productId: $0.item.id,
                name: $0.item.name,
                quantity: $0.quantity,
                unitPrice: $0.unitPrice
            )
        }
        let order = QueuedCashpointOrder(
            entries: mapped,
            total: total,
            diningMode: diningMode.rawValue,
            createdAt: Date(),
            ticketNumber: ticketNumber
        )
        pending.append(order)
        save(pending)
    }

    
    static func retryPending() {
        var pending = load()
        guard !pending.isEmpty else { return }

        for (index, queued) in pending.enumerated().reversed() {
            let entries: [BasketEntry] = queued.entries.map { qe in
                let item = ShellMenuItem(
                    id: qe.productId,
                    name: qe.name,
                    price: qe.unitPrice,
                    category: "",          // or real category if you decide to store it
                    modifiers: nil,        // no modifiers on resend (or store them in the queue if needed)
                    imageURL: nil,
                    description: nil
                )

                return BasketEntry(
                    id: 0,
                    item: item,
                    quantity: qe.quantity,
                    subtitle: nil,
                    unitPrice: qe.unitPrice
                )
            }

            let dm = DiningMode(rawValue: queued.diningMode) ?? .dineIn

            let basketSum = entries.reduce(0.0) { acc, e in
                acc + (Double(e.quantity) * e.unitPrice)
            }

            let discount = max(0, basketSum - queued.total)

            let totals: [String: Any] = [
                "basket": basketSum,
                "discount": discount,
                "excluded": 0,
                "total": queued.total
            ]
            
            

            OrderAPI.submitOrder(
                entries: entries,
                total: queued.total,
                diningMode: dm,
                source: "cashpoint",
                customerName: nil,
                customerPhone: nil,
                payment: nil,
                zcreditMeta: nil,
                ticketNumber: queued.ticketNumber,
                totals: totals
            ) { result in
                switch result {
                case .success:
                

                    var updated = load()
                    if index < updated.count {
                        updated.remove(at: index)
                        save(updated)
                    }
                case .failure:
                    break
                }
            }
        }
    }
}

private let API_BASE: String = UserDefaults.standard.string(forKey: "apiBase") ?? "https://minis.studio"

@MainActor
final class StockToggleStore: ObservableObject {
    @Published private(set) var state: [Int: Bool] = [:]   // productId -> isOn
    @Published private(set) var pending: Set<Int> = []     // in-flight ids

    private let prefix: String
    private let shopId: Int

    @MainActor
    func setLocalOn(_ productId: Int, _ on: Bool) {
        state[productId] = on
        UserDefaults.standard.set(on, forKey: prefix + String(productId))
        objectWillChange.send()
    }
    init(shopId: Int) {
        self.shopId = shopId
        self.prefix = "stock.toggle.\(shopId)."

        // Load any locally persisted overrides (will be overwritten by forceServerStatus when JSON loads)
        for (k, v) in UserDefaults.standard.dictionaryRepresentation() where k.hasPrefix(prefix) {
            if let b = v as? Bool,
               let id = Int(k.replacingOccurrences(of: prefix, with: "")) {
                state[id] = b
            }
        }
    }

    func isOn(_ productId: Int) -> Bool {
        state[productId] ?? true  // default ON
    }

    /// ✅ Soft apply (kept for compatibility): only updates keys that differ.
    func applyServerStatus(_ map: [Int: Int]) {
        var changed = false
        for (pid, bit) in map {
            let val = (bit != 0)
            if state[pid] != val {
                state[pid] = val
                UserDefaults.standard.set(val, forKey: prefix + String(pid))
                changed = true
            }
        }
        if changed { objectWillChange.send() }
    }

    /// ✅ HARD sync: server is source of truth.
    /// Overwrites local state (fixes iPad being stuck "out of stock" after relaunch).
    func forceServerStatus(_ map: [Int: Int]) {
        pending.removeAll()

        // Optional: remove locally stored keys that are not in server map
        // (prevents orphaned stale product ids from living forever)
        let serverIds = Set(map.keys)
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            let idStr = key.replacingOccurrences(of: prefix, with: "")
            if let id = Int(idStr), !serverIds.contains(id) {
                UserDefaults.standard.removeObject(forKey: key)
                state[id] = nil
            }
        }

        // Apply server truth for all ids
        for (pid, bit) in map {
            let val = (bit != 0)
            state[pid] = val
            UserDefaults.standard.set(val, forKey: prefix + String(pid))
        }

        objectWillChange.send()
    }

    func binding(for productId: Int) -> Binding<Bool> {
        Binding(
            get: { self.isOn(productId) },
            set: { newVal in
                let old = self.isOn(productId)
                guard newVal != old else { return }
                self.state[productId] = newVal
                UserDefaults.standard.set(newVal, forKey: self.prefix + String(productId))

                self.pending.insert(productId)

                Task {
                    let ok = await self.syncStatus(productId: productId, enabled: newVal)

                    await MainActor.run {
                        self.pending.remove(productId)

                        if !ok {
                            // revert
                            self.state[productId] = old
                            UserDefaults.standard.set(old, forKey: self.prefix + String(productId))
                        }
                    }
                }
            }
        )
    }

    private func syncStatus(productId: Int, enabled: Bool) async -> Bool {
        let base = UserDefaults.standard.string(forKey: "apiBase") ?? "https://minis.studio"
        guard let url = URL(string: "\(base)/api/products/\(productId)/status") else { return false }

        let requestId = UUID().uuidString

        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        req.setValue(requestId, forHTTPHeaderField: "X-Request-Id")

        struct Payload: Encodable { let miniAppId: Int; let enabled: Bool }
        req.httpBody = try? JSONEncoder().encode(Payload(miniAppId: shopId, enabled: enabled))

        print("📤 setStatus reqId=\(requestId) product=\(productId) enabled=\(enabled) shopId=\(shopId)")
        print(req.curlDebug)

        let delays: [UInt64] = [0, 400_000_000, 900_000_000]

        for attempt in 0..<delays.count {
            if delays[attempt] > 0 { try? await Task.sleep(nanoseconds: delays[attempt]) }
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                let text = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
                print("📥 setStatus resp reqId=\(requestId) attempt=\(attempt+1) HTTP \(code) body=\(String(text.prefix(300)))")
                if (200..<300).contains(code) { return true }
                if [502, 503, 504].contains(code), attempt < delays.count - 1 { continue }
                return false
            } catch {
                print("❌ setStatus network reqId=\(requestId) attempt=\(attempt+1) err=\(error.localizedDescription)")
                if attempt < delays.count - 1 { continue }
                return false
            }
        }
        return false
    }
}


private extension View {
    @ViewBuilder
    func applyIf<T: View>(_ condition: Bool, transform: (Self) -> T) -> some View {
        if condition { transform(self) } else { self }
    }
}



// MARK: - CashPoint Hosted Card (ZCredit) Result Types

enum CashPointZCreditHostedState {
    case success
    case failure
    case unknown
}

struct CashPointZCreditHostedResult {
    let state: CashPointZCreditHostedState
    let reference: String?
}

// MARK: - CashPoint ZCredit Hosted Checkout Sheet

struct CashPointZCreditHostedCheckoutSheet: View {
    let isRtl: Bool
    let amount: Double
    let currency: String
    let onClose: () -> Void
    let onResult: (CashPointZCreditHostedResult) -> Void

    // ✅ The page origin we load HTML under (so relative paths work if needed)
    private let baseURLString = "https://minis.studio/test2"

    // ✅ Your app return URL (backend/hosted checkout must redirect to this)
    // Expect: minis://zcredit?success=1&ref=XXXX
    private let returnScheme = "minis://zcredit"

    private func autoHTML() -> String {
        let amountInt = Int(amount.rounded())

        return """
        <!doctype html>
        <html lang="en">
        <head>
            <meta charset="utf-8" />
            <meta name="viewport" content="width=device-width, initial-scale=1" />
            <style>
                html,body { margin:0; padding:0; background:#f5f5f7; font-family:-apple-system,system-ui,sans-serif; }
                .card { max-width:520px; margin:40px auto; padding:20px; background:#fff; border-radius:12px;
                        box-shadow:0 3px 10px rgba(0,0,0,0.10); text-align:center; }
                .title { font-size:20px; font-weight:600; margin-bottom:10px; }
                .spinner { width:34px; height:34px; margin:14px auto 10px auto; border-radius:50%;
                           border:4px solid #e5e5ea; border-top-color:#005ebb; animation:spin 0.9s linear infinite; }
                @keyframes spin { to { transform: rotate(360deg); } }
                #status { font-size:13px; color:#666; white-space:pre-wrap; }
            </style>
        </head>
        <body>

            <div class="card">
                <div class="title">Processing payment…</div>
                <div class="spinner"></div>
                <div id="status">Creating Z-Credit session…</div>
            </div>

            <script>
            const statusEl = document.getElementById("status");
            function setStatus(t){ statusEl.textContent = t || ""; }

            (async function start() {
              try {
                const amount = \(amountInt);
                const returnUrl = "\(returnScheme)";

                // ✅ Endpoint your old test used (ABSOLUTE)
                const url =
                  "https://minis.studio/test/zcredit/create?amount=" + amount +
                  "&returnUrl=" + encodeURIComponent(returnUrl);

                const res = await fetch(url, { method: "GET", cache: "no-store" });
                const text = await res.text();

                if (!res.ok) {
                  setStatus("HTTP " + res.status + "\\n" + text.slice(0, 600));
                  return;
                }

                let data = null;
                try { data = JSON.parse(text); }
                catch { setStatus("Non-JSON response\\n" + text.slice(0, 600)); return; }

                // ✅ Accept a few possible field names (helps while you iterate server-side)
                const checkoutUrl =
                  data.checkoutUrl || data.checkoutURL ||
                  data.SessionUrl  || data.sessionUrl ||
                  (data.data && (data.data.SessionUrl || data.data.sessionUrl));

                if (!checkoutUrl) {
                  setStatus("Bad JSON (no checkout url)\\n" + JSON.stringify(data).slice(0, 600));
                  return;
                }

                // Redirect to hosted checkout
                window.location.href = checkoutUrl;

              } catch (e) {
                setStatus("Network error: " + (e && e.message ? e.message : ""));
              }
            })();
            </script>

        </body>
        </html>
        """
    }

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()

            VStack(spacing: 14) {
                // Top bar
                HStack {
                    if isRtl { Spacer() }
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .bold))
                            .padding(8)
                            .background(Color(.systemGray5))
                            .clipShape(Circle())
                    }
                    if !isRtl { Spacer() }
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)

                Text(isRtl ? "הקלדת אשראי" : "Manual card entry")
                    .font(.system(size: 20, weight: .bold))

                Text(String(format: isRtl ? "לתשלום: \(currency)%.2f" : "Amount: \(currency)%.2f", amount))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.secondary)

                // ✅ WebView container (HTML)
                CashPointZCreditHostedWebView(
                    html: autoHTML(),
                    baseURL: URL(string: baseURLString)!,
                    onReturnURL: { url in
                        // Expect: minis://zcredit?success=1&ref=XXXX
                        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
                        let successRaw =
                            comps?.queryItems?.first(where: { $0.name == "success" })?.value?.lowercased()
                        let resultRaw =
                            comps?.queryItems?.first(where: { $0.name == "result" })?.value?.lowercased()
                        let ref =
                            comps?.queryItems?.first(where: { $0.name == "ref" })?.value

                        let isSuccess =
                            successRaw == "1" || successRaw == "true" ||
                            resultRaw == "success"

                        let isCancel =
                            successRaw == "0" || successRaw == "false" ||
                            resultRaw == "cancel"

                        if isSuccess {
                            onResult(CashPointZCreditHostedResult(state: .success, reference: ref))
                        } else if successRaw == "0" || successRaw == "false" || successRaw == "no" || successRaw == "fail" || successRaw == "failure" {
                            onResult(CashPointZCreditHostedResult(state: .failure, reference: ref))
                        } else {
                            onResult(CashPointZCreditHostedResult(state: .unknown, reference: ref))
                        }
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.black.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.10), radius: 14, x: 0, y: 8)
                .padding(.horizontal, 16)
                .padding(.bottom, 14)

                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - CashPoint Hosted WebView (HTML + Deep Link Intercept)

struct CashPointZCreditHostedWebView: UIViewRepresentable {
    let html: String
    let baseURL: URL
    let onReturnURL: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onReturnURL: onReturnURL)
    }

    func makeUIView(context: Context) -> WKWebView {
        let web = WKWebView(frame: .zero)
        web.navigationDelegate = context.coordinator

        // ✅ allow scrolling
        web.scrollView.isScrollEnabled = true
        web.scrollView.bounces = true
        web.scrollView.alwaysBounceVertical = true

        // ✅ better layout
        web.isOpaque = false
        web.backgroundColor = .clear

        // ✅ helps when the page uses 100vh etc.
        web.scrollView.contentInsetAdjustmentBehavior = .always

        web.loadHTMLString(html, baseURL: baseURL)
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onReturnURL: (URL) -> Void

        init(onReturnURL: @escaping (URL) -> Void) {
            self.onReturnURL = onReturnURL
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if let url = navigationAction.request.url {

                // ✅ 1) minis://zcredit?success=...
                if url.scheme == "minis", url.host == "zcredit" {
                    onReturnURL(url)
                    decisionHandler(.cancel)
                    return
                }

                // ✅ 2) https://minis.studio/fastlane?result=success|cancel
                if url.host == "minis.studio", url.path.lowercased() == "/fastlane" {
                    onReturnURL(url)
                    decisionHandler(.cancel)
                    return
                }
            }
            decisionHandler(.allow)
        }
    }
}



// MARK: - CashPoint Result Types (rename to avoid collisions)

enum CashPointZCreditManualState {
    case success
    case failure
    case unknown
}

struct CashPointZCreditManualResult {
    let state: CashPointZCreditManualState
    let reference: String?
}

// MARK: - CashPoint ZCredit Hosted Checkout Sheet (AUTO card, no button)



// MARK: - CashPoint WebView (HTML + minis://zcredit intercept)bcxzfgg
