import SwiftUI
import UniformTypeIdentifiers
import Kingfisher
import Combine




struct CashPointView: View {
    @AppStorage("cashpointID") private var cashpointIDRaw: Int = 2
    @State private var activeTeamTab: TabType? = nil   // nil = normal customer mode
    @State private var showTeamTabsSheet = false
    @State private var noteEditingLineId: Int? = nil
    @State private var noteEditingText: String = ""
    @FocusState private var focusedStockProductId: Int?
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
    @State private var editingLineId: Int? = nil
    @State private var swipingProductId: Int? = nil
    @State private var outOfStockProductIds: Set<Int> = []
    @State private var draggingProduct: ShellMenuItem?
    @State private var hasChosenServiceMode: Bool = false
    @State private var showLastInvoicePrompt: Bool = false
    @State private var zRestoreMode: Bool = false
    @State private var zRestoreDate: Date = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
    @StateObject private var net = NetworkMonitor.shared
    private var isTeamTabMode: Bool { activeTeamTab != nil }
    @State private var pendingFinishAfterSubmit: Bool = false
    @State private var showClearStockConfirm = false
    @StateObject private var stockToggles = StockToggleStore(
        shopId: 12   // 👈 hard-coded miniAppId
    )
    
    private var isPhoneDevice: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
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

    private let pinpads: [(title: String, id: String)] = [
        ("קופה 1", "48796294"),
        ("קופה 2", "48796855"),
        ("קיוסק 1", "48796856")
    ]

    private var currentPinpadId: String {
        UserDefaults.standard.string(forKey: "pinpadId") ?? ""
    }

    private func setPinpadAndPing(_ id: String) {
        // 1) persist
        UserDefaults.standard.set(id, forKey: "pinpadId")
        Haptics.light()

        // 2) ping: start 1₪ and cancel after 1s
        //    (this is exactly what you asked for; cancellation is "best effort")
        ZCreditPaymentHandler.shared.pay(amount: 1.0, orderId: nil) { _ in
            // ignore result; this is only a connectivity ping
        }

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

    @State private var backlogPoll = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var printerPort: UInt16 {
        let raw = UserDefaults.standard.integer(forKey: "kds.printer.port")
        let p = UInt16(exactly: raw) ?? 0
        return p == 0 ? 9100 : p
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
        let cleanOrder = categoryOrder.filter { $0 != "✏️ הערות" }

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
    private var categoryOrderKey: String { "cash.categoryOrder.shop12" } // or use shopId
    
    private func loadCategoryOrderFromStorageOrMenu() {
        let menuCats = Array(Set(api.items.map(\.category)))

        // ✅ 1) prefer server order if present
        let server = api.categoryOrder
            .filter { $0 != "✏️ הערות" }
            .filter { menuCats.contains($0) }

        // ✅ 2) fallback to local saved order only if server is empty
        let saved = (UserDefaults.standard.array(forKey: categoryOrderKey) as? [String]) ?? []
        var merged = (!server.isEmpty ? server : saved.filter { menuCats.contains($0) })

        // ✅ 3) append new categories that server/saved didn't include
        for c in menuCats where !merged.contains(c) { merged.append(c) }

        // ✅ 4) keep notes last
        merged.removeAll(where: { $0 == "✏️ הערות" })
        merged.append("✏️ הערות")

        categoryOrder = merged

        // ✅ optional: persist the server truth so your rail stays correct across launches
        if !server.isEmpty {
            UserDefaults.standard.set(merged, forKey: categoryOrderKey)
        }
    }
    
    private func persistCategoryOrder() {
        UserDefaults.standard.set(categoryOrder, forKey: categoryOrderKey)
    }
    
    private func buildSalesReportData(for type: ReportType) -> PrinterManager.SalesReportData {
        emptySalesReportData()   // ✅ always start blank
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
                    activeTeamTab = nil
                    isPayLaterMode = false
                    unpaidOrderId = nil
                    lockedLineIds.removeAll()
                    lineSessionTime.removeAll()
                    basket.removeAll()
                    nextBasketLineId = 1
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
            // empty → treat as ∞ / untracked
            stockAdjustments[productId] = nil
            stockToggles.binding(for: productId).wrappedValue = true    // in stock
        } else if let value = Int(trimmed), value >= 0 {
            stockAdjustments[productId] = value
            // 0 → out of stock, >0 → in stock
            stockToggles.binding(for: productId).wrappedValue = (value > 0)
        } else {
            // invalid input → ignore, reset from current stock
            let current = remainingStock(for: ShellMenuItem(id: productId,
                                                            name: "",
                                                            price: 0,
                                                            category: "",
                                                            modifiers: nil,
                                                            imageURL: nil,
                                                            description: nil))
            stockText[productId] = current.map { String($0) } ?? ""
            return
        }

        // mark this product as needing sync
        dirtyStockIds.insert(productId)
        scheduleStockCommit()
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
        lockedLineIds = Set(entriesArray.map { $0.id })

        // Green check overlay immediately
        playPrintSuccess()
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
        PrinterManager.shared.printCashPointSplit(
            orderNumber: existingId,
            entries: newEntries,
            total: newTotal,
            diningMode: mode,
            customerName: nameSnapshot,
            customerPhone: phoneSnapshot
        )
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
    @State private var additionSelections: [Int: Set<String>] = [:]      // lineId -> Set<additionName>
    
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
    @State private var stockCommitWorkItem: DispatchWorkItem? = nil
    private enum DiscountMode {
        case none, ten, fifteen,thirteen, custom
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
    @State private var productPoll = Timer.publish(every: 10, on: .main, in: .common).autoconnect()
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
                        NewOrderButton(title: "נקה") {
                            startNewOrderFromPayLater()
                        }
                        .buttonStyle(.plain)

                        Button {
                            closeActiveTeamTab()
                        } label: {
                            Text("סגור")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.primary)
                                .frame(width: 90, height: 44)
                                .background(Color(.systemGray5))
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)

                        let canPrintNewLines = hasAddedLinesInPayLater

                        Button {
                            guard canPrintNewLines else { return }

                            guard let _ = unpaidOrderId else {
                                Haptics.error()
                                print("⚠️ teamTab print blocked: unpaidOrderId missing")
                                return
                            }
                            printUpdatedUnpaidOrder()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                startNewOrderFromPayLater()
                            }
                        } label: {
                            Text(canPrintNewLines ? "הדפס" : "הודפס")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(.white)
                                .frame(width: 110, height: 44)
                                .background(canPrintNewLines ? Color.black : Color.gray.opacity(0.35))
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(!canPrintNewLines)

                    } else if isPayLaterMode {

                        NewOrderButton(title: "נקה הזמנה") {
                            startNewOrderFromPayLater()
                        }

                        Button {
                            guard !basketIsEmpty else { return }

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
                            Text(mainActionButtonTitle)
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(.white)
                                .frame(width: 180, height: 48)
                                .background(basketIsEmpty ? Color.gray.opacity(0.4) : .black)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(basketIsEmpty)

                    } else {

                        Button {
                            guard !basketIsEmpty else { return }
                            if inline {
                                showOrderFlow = true
                            } else {
                                showBasketSheetPhone = false
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                    showOrderFlow = true
                                }
                            }
                        } label: {
                            Text(mainActionButtonTitle)
                                .font(.system(size: 20, weight: .bold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 56)
                                .background(basketIsEmpty ? Color.gray.opacity(0.4) : .black)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(basketIsEmpty)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
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
    
    private func restoreOrderFromMetadata(_ meta: OrderMetadataDTO) {

        basket.removeAll()
        nextBasketLineId = 1
        lockedLineIds.removeAll()
        lineSessionTime.removeAll()

        let lines = meta.basket ?? []

        for l in lines {
            let item = MenuCatalog.shared.item(for: l.productId)
                ?? ShellMenuItem(
                    id: l.productId,
                    name: l.name,
                    price: l.unitPrice,
                    category: "",
                    modifiers: nil,
                    imageURL: nil,
                    description: nil,
                    status: 1,
                    stockQuantity: nil,
                    printer: nil
                )

            let entry = BasketEntry(
                id: l.lineId,
                item: item,
                quantity: l.quantity,
                subtitle: l.modifiers,
                unitPrice: l.unitPrice
            )

            basket[l.lineId] = entry
            lockedLineIds.insert(l.lineId)

            // We don’t have per-line timestamps in metadata yet → just tag now
            lineSessionTime[l.lineId] = Date()
        }

        // Important: future adds should use fresh line ids
        let maxLineId = lines.map(\.lineId).max() ?? 0
        nextBasketLineId = max(maxLineId + 1, 1)

        // service
        if (meta.service ?? "").lowercased() == "ta" {
            diningMode = .takeAway
        } else {
            diningMode = .dineIn
        }

        // team tab behavior
        isPayLaterMode = true
        hasChosenServiceMode = true
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
        let miniAppId = Int(UserDefaults.standard.string(forKey: "shopId") ?? "12") ?? 12

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
        let shopId = 12
        guard shopId > 0 else {
            print("❌ syncAdminDraftToServer: missing shopId")
            return
        }

        let productApi = MinisProductAPI()


        do {
            let payload = draft.toUpsertPayload(shopId: shopId)
            let returnedId = try await productApi.upsertProduct(payload)
            if returnedId > 0 {
                // If this was a new product, we should update its productId for future edits
                print("🟢 upsertProduct → productId =", returnedId)
            }

           // try await productApi.publish(shopId: shopId)

            print("🟢 publish(shopId:\(shopId)) succeeded")

            // Optional: reload menu from server so CashPoint reflects the canonical state
            await MainActor.run {
                api.load(skipCache: true)
            }
        } catch let MinisProductAPI.APIError.badResponse(code, body) {
            print("❌ Admin upsert bad response: HTTP \(code)\n\(body)")
        } catch {
            print("❌ Admin upsert/publish error:", error.localizedDescription)
        }
    }
    private func makeAdminDraft(from item: ShellMenuItem) -> AdminProductDraft {
        var groupDrafts: [AdminModifierGroupDraft] = []

        if let groups = item.modifiers {
            for g in groups {
                // Map ModifierGroup.GroupType -> AdminModifierGroupDraft.Kind
                let kind: AdminModifierGroupDraft.Kind
                switch g.type {
                case .options:
                    kind = .options
                case .additions:
                    kind = .additions
                }

                var itemDrafts: [AdminModifierItemDraft] = []
                for opt in g.items {
                    let priceText = String(format: "%.2f", opt.extraPrice)
                    let draftItem = AdminModifierItemDraft(
                        name: opt.name,
                        extraPriceText: priceText
                    )
                    itemDrafts.append(draftItem)
                }

                let groupDraft = AdminModifierGroupDraft(
                    title: g.title,
                    kind: kind,
                    items: itemDrafts
                )
                groupDrafts.append(groupDraft)
            }
        }

        return AdminProductDraft(
            productId: item.id,
            name: item.name,
            priceText: String(format: "%.2f", item.price),
            category: item.category,
            description: item.description ?? "",
            imageURL: item.imageURL ?? "",
            modifierGroups: groupDrafts,
            printer: item.printer ?? "Bar"      // ✅ NEW
        )
    }
    
    private var requiresPhoneStep: Bool {
        basket.values.contains { entry in
            let name     = entry.item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let category = entry.item.category.trimmingCharacters(in: .whitespacesAndNewlines)

            // Phone mandatory if:
            // 1) category contains "סלט"
            // 2) OR product name contains "טוסט"
            // 3) OR product name contains "מרק"
            return category.contains("סלט")
                || name.contains("טוסט")
                || name.contains("מרק")
        }
    }

    // Apply an edited draft back into api.items (and optionally call your backend)
    // Apply an edited draft back into api.items (and optionally call your backend)
    private func applyAdminSave(_ draft: AdminProductDraft) {
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
                return ModifierGroup(type: kind, title: g.title, items: items)
            }
            let newId = (api.items.map(\.id).max() ?? 0) + 1
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
                printer: "Bar"   // ✅ or "Kitchen" default
            )

            api.items.append(newItem)

            // Remote upsert + publish
            Task {
                await syncAdminDraftToServer(draft)
            }
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
                printer: api.items[idx].printer     // ✅ preserve
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
                    unitPrice: entry.unitPrice   // keep the price used when it was added
                )
            }
        }

        // 4) Remote upsert + publish
        Task {
            await syncAdminDraftToServer(draft)
        }
    }
    
    enum StockQuantityAPI {
        static func setStock(productId: Int, quantity: Int?) async {
            let shopId = 12
            guard let url = URL(string: "https://minis.studio/api/products/\(productId)/stock") else { return }

            var body: [String: Any] = [
                "miniAppId": shopId
            ]

            if let q = quantity {
                body["stockQuantity"] = q   // finite stock
            } else {
                body["stockQuantity"] = NSNull()  // 👈 sends JSON null
            }

            let bodyData = try? JSONSerialization.data(withJSONObject: body)

            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = bodyData

            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    let text = String(data: data, encoding: .utf8) ?? "<non-utf8 body \(data.count) bytes>"
                    print("❌ setStock failed: \(http.statusCode)\n\(text)")
                } else if let http = response as? HTTPURLResponse {
                    print("✅ setStock OK: \(http.statusCode)")
                }
            } catch {
                print("❌ setStock error:", error.localizedDescription)
            }
        }
    }
    
    
    /// Set stock of all products in the selected category to 0 (out of stock)
    private func clearStockForSelectedCategory() {
        // No category / notes pseudo-category → do nothing
        guard !selectedCategory.isEmpty,
              selectedCategory != "✏️ הערות"
        else { return }

        // All items in this category
        let itemsInCategory = api.items.filter { $0.category == selectedCategory }
        guard !itemsInCategory.isEmpty else { return }

        for item in itemsInCategory {
            let pid = item.id

            // 0 = out of stock
            stockAdjustments[pid] = 0

            // Update toggle so UI immediately shows as out of stock
            stockToggles.binding(for: pid).wrappedValue = false

            // Mark for API sync
            dirtyStockIds.insert(pid)
        }

        print("📦 clearStockForSelectedCategory: '\(selectedCategory)' → \(itemsInCategory.count) items set to 0")

        // Commit to server after debounce
        scheduleStockCommit()
    }
    private func bumpStockAmount(productId: Int, delta: Int) {
        var currentOpt = stockAdjustments[productId]  // Int? (nil = ∞ / untracked)

        if let current = currentOpt {
            // We are currently tracking a finite stock number
            var newValue = current + delta

            if newValue < 0 {
                // Went below 0 → switch to nil (∞ / untracked)
                currentOpt = nil
            } else {
                // 5 → 4 → 3 → 2 → 1 → 0 (still tracked)
                currentOpt = newValue
            }
        } else {
            // Currently "infinite" / untracked (nil)
            if delta > 0 {
                // First "+" from ∞ → start tracking at 1
                currentOpt = 1
            } else {
                // "-" from ∞: stay at ∞ (no change)
                currentOpt = nil
            }
        }

        stockAdjustments[productId] = currentOpt

        // 👇 NEW: sync local Status (stockToggles) so isOut updates immediately
        if let value = currentOpt {
            if value > 0 {
                // have stock -> mark as "in stock"
                stockToggles.binding(for: productId).wrappedValue = true
            } else {
                // value == 0 -> out of stock
                stockToggles.binding(for: productId).wrappedValue = false
            }
        } else {
            // nil = infinite / untracked -> treat as "in stock"
            stockToggles.binding(for: productId).wrappedValue = true
        }

        // mark this product as needing sync
        dirtyStockIds.insert(productId)

        print("📦 pending stock:", stockAdjustments, "dirty:", dirtyStockIds)

        // Schedule commit after 3s of no further changes
        scheduleStockCommit()

        // Keep UI auto-close behaviour only when NOT in global edit mode
        if !isStockEditMode {
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
    
    private func scheduleStockCommit() {
        stockCommitWorkItem?.cancel()
        let work = DispatchWorkItem {
            Task {
                await commitStockAdjustments()
            }
        }
        stockCommitWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    @MainActor
    private func commitStockAdjustments() async {
        // snapshot dirty ids so we don't race with UI
        let pendingIds = dirtyStockIds
        guard !pendingIds.isEmpty else { return }

        // clear dirty set + timers
        dirtyStockIds.removeAll()
        stockCommitWorkItem = nil

        // close the inline stock editor but keep badge
        editingStockProductId = nil
        stockEditWorkItem?.cancel()
        stockEditWorkItem = nil

        for productId in pendingIds {
            let qtyOpt = stockAdjustments[productId] // Int?  (nil = ∞)
            await StockQuantityAPI.setStock(productId: productId, quantity: qtyOpt)
        }
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

        // No modifiers → only note matters
        guard let groups = current.item.modifiers, !groups.isEmpty else {
            let noteText = noteDrafts[lineId] ?? noteFromSubtitle(current.subtitle)
            let noteClean = noteText.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
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

        let optionsMap   = optionSelections[lineId] ?? [:]
        let additionsSet = additionSelections[lineId] ?? []

        let extraPerUnit: Double = groups.reduce(0.0) { total, group in
            switch group.type {
            case .options:
                let selectedName = optionsMap[group.title] ?? group.items.first?.name
                if let selectedName,
                   let opt = group.items.first(where: { $0.name == selectedName }) {
                    return total + opt.extraPrice
                }
                return total

            case .additions:
                let addSum = group.items
                    .filter { additionsSet.contains($0.name) }
                    .map { $0.extraPrice }
                    .reduce(0.0, +)
                return total + addSum
            }
        }

        let unitPrice = current.item.price + extraPerUnit

        var subtitlePieces: [String] = []

        // Options: only show if different from default
        for group in groups where group.type == .options {
            let defaultName  = group.items.first?.name
            let selectedName = optionsMap[group.title] ?? defaultName
            if let selectedName,
               let defaultName,
               selectedName != defaultName {
                subtitlePieces.append("\(group.title): \(selectedName)")
            }
        }

        // Additions: list chosen additions
        for group in groups where group.type == .additions {
            let chosen = group.items.filter { additionsSet.contains($0.name) }
            if !chosen.isEmpty {
                let joined = chosen.map { $0.name }.joined(separator: ", ")
                subtitlePieces.append("\(group.title): \(joined)")
            }
        }

        let optionsText = subtitlePieces.joined(separator: ", ")

        let rawNote   = noteDrafts[lineId] ?? noteFromSubtitle(current.subtitle)
        let noteClean = rawNote.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

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

            // Don't reorder notes, and don't drop onto notes
            if current == "✏️ הערות" || target == "✏️ הערות" { return }

            guard let from = order.firstIndex(of: current),
                  let to0  = order.firstIndex(of: target) else { return }

            if from == to0 { return }

            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                // ✅ Remove first
                let moved = order.remove(at: from)

                // ✅ Recompute target index after removal (this fixes the “off by 1 / wrong place”)
                let to = order.firstIndex(of: target) ?? min(to0, max(0, order.count))

                order.insert(moved, at: to)
            }
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
        let allCats = Array(Set(api.items.map(\.category)))

        // 1) start with server order
        var out: [String] = []
        let serverOrder = api.categoryOrder

        for c in serverOrder where allCats.contains(c) {
            out.append(c)
        }

        // 2) append any categories not present in server list (new ones)
        for c in allCats where !out.contains(c) {
            out.append(c)
        }

        // 3) keep notes last
        out.removeAll(where: { $0 == "✏️ הערות" })
        out.append("✏️ הערות")

        return out
    }

    private var itemsForSelectedCategory: [ShellMenuItem] {
        guard !selectedCategory.isEmpty else { return [] }

        if selectedCategory == "✏️ הערות" {
            return [
                ShellMenuItem(
                    id: -1001,
                    name: "הערה לבר",
                    price: 0,
                    category: "✏️ הערות",
                    modifiers: nil,
                    imageURL: nil,
                    description: nil,
                    status: 1,
                    stockQuantity: nil,
                    printer: "Bar"        // ✅
                ),
                ShellMenuItem(
                    id: -1002,
                    name: "הערה למטבח",
                    price: 0,
                    category: "✏️ הערות",
                    modifiers: nil,
                    imageURL: nil,
                    description: nil,
                    status: 1,
                    stockQuantity: nil,
                    printer: "Kitchen"    // ✅
                ),
                ShellMenuItem(
                    id: -1003,
                    name: "הערה לוטרינה",
                    price: 0,
                    category: "✏️ הערות",
                    modifiers: nil,
                    imageURL: nil,
                    description: nil,
                    status: 1,
                    stockQuantity: nil,
                    printer: "Bakery"     // ✅
                )
            ]
        }

        return api.items.filter { $0.category == selectedCategory }
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
                .frame(height: 46)
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
        nextBasketLineId = 1

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
        !(isPhoneLayout && isStockEditMode)
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
        nextBasketLineId = 1
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

        return DragGesture(minimumDistance: 18)
            .updating($isBasketHorizontalSwipe) { value, state, _ in
                guard !isLocked else { return }
                let dx = value.translation.width
                let dy = value.translation.height
                if abs(dx) > 32 && abs(dx) > abs(dy) + 10 {
                    state = true
                }
            }
            .onChanged { value in
                guard !isLocked else {
                    basketSwipeOffsets[entry.id] = 0
                    return
                }

                let dx = value.translation.width
                let dy = value.translation.height

                // ✅ if it’s not horizontal, do NOTHING (let ScrollView scroll)
                guard abs(dx) > 32 && abs(dx) > abs(dy) + 10 else {
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

                guard abs(dx) > 32 && abs(dx) > abs(dy) + 10 else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        basketSwipeOffsets[entry.id] = 0
                    }
                    return
                }

                let dir: CGFloat = isRtl ? -1 : 1
                let translated = dx * dir
                let commitThreshold: CGFloat = 80

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
                let isOut =
                    selectedCategory != "✏️ הערות"
                    && (!stockToggles.isOn(item.id) || remaining <= 0)

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
           // 1) If search is active → global search (all categories)
           let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
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

               // 🔹 Sort: active first, then by `sort`, then name
               return base.sorted { lhs, rhs in
                   productSortKey(lhs) < productSortKey(rhs)
               }
           }

           // 2) No search → regular category behaviour
           guard !selectedCategory.isEmpty else { return [] }

           // Notes category stays as-is (no stock / sort logic needed)
           if selectedCategory == "✏️ הערות" {
               return [
                   ShellMenuItem(
                       id: -1001,
                       name: "הערה לבר",
                       price: 0,
                       category: "✏️ הערות",
                       modifiers: nil,
                       imageURL: nil,
                       description: nil
                   ),
                   ShellMenuItem(
                       id: -1002,
                       name: "הערה למטבח",
                       price: 0,
                       category: "✏️ הערות",
                       modifiers: nil,
                       imageURL: nil,
                       description: nil
                   ),
                   ShellMenuItem(
                       id: -1003,
                       name: "הערה לוטרינה",
                       price: 0,
                       category: "✏️ הערות",
                       modifiers: nil,
                       imageURL: nil,
                       description: nil
                   )
               ]
           }

           let base = api.items.filter { $0.category == selectedCategory }

           // 🔹 Sort: active first, then by `sort`, then name
           return base.sorted { lhs, rhs in
               productSortKey(lhs) < productSortKey(rhs)
           }
       }
    // MARK: - Side menu

    // MARK: - Side menu (animated)
    // MARK: - Side menu (iOS-style)

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

        // small helper for full-width clickable row
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
                .frame(maxWidth: .infinity, alignment: .leading) // ✅ full width
                .contentShape(Rectangle())                       // ✅ full hit area
            }
            .buttonStyle(.plain)
        }

        return VStack(alignment: isRtl ? .trailing : .leading, spacing: 0) {

            // HEADER
            HStack {
                Text("בית העם")
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

            // MENU ITEMS
            VStack(alignment: isRtl ? .trailing : .leading, spacing: 0) {

                fullRow("הזמנות", "list.bullet.rectangle") {
                    showSideMenu = false
                    showOrdersAdmin = true
                }

                fullRow("בונים", "rectangle.grid.2x2") {
                    showSideMenu = false
                    showBones = true
                }

                fullRow("פתח מגירה", "tray.and.arrow.down") {
                    PrinterManager.shared.openCashDrawer()
                }

                fullRow("זיכוי לקוח", "arrow.uturn.left.circle") {
                    showSideMenu = false
                    refundInput = ""
                    showRefundFlow = true
                }
                
               

                // TEAM TABS parent row — FULL WIDTH CLICKABLE
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
                    .frame(maxWidth: .infinity, alignment: .leading)
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
                    .padding(.leading,  isRtl ? 0  : 32)
                    .padding(.trailing, isRtl ? 32 : 0)
                }

                // REPORTS parent row — FULL WIDTH CLICKABLE
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
                    .frame(maxWidth: .infinity, alignment: .leading)
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
                    .padding(.leading,  isRtl ? 0  : 32)
                    .padding(.trailing, isRtl ? 32 : 0)
                }
                
                // ✅ PINPADS (parent row)
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
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

             
                // 🔻 Suboptions under Pinpads
                if pinpadsExpanded {
                    VStack(alignment: isRtl ? .trailing : .leading, spacing: 0) {
                        ForEach(pinpads, id: \.id) { item in
                            Button {
                                showSideMenu = false
                                setPinpadAndPing(item.id)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: item.id == currentPinpadId
                                          ? "checkmark.circle.fill"
                                          : "circle")
                                        .foregroundColor(item.id == currentPinpadId ? .primary : .secondary)

                                    Text(item.title)
                                        .font(.system(size: 16, weight: .semibold))

                                    Spacer()
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.leading,  isRtl ? 0  : 32)
                    .padding(.trailing, isRtl ? 32 : 0)
                }
                
                fullRow("הנחת סטודנטים", "graduationcap.fill") {
                    showSideMenu = false
                    showStudentHandshakeSheet = true
                }
               
            }
            .padding(.top, 8)

            Spacer()
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
        // prefer your rail order, skip notes
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

    private func sideMenuRow(
        _ title: String,
        _ systemImage: String,
        _ action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if !isRtl {
                    Image(systemName: systemImage)
                        .font(.system(size: 18))
                }

                if isRtl {
                    Image(systemName: systemImage)
                        .font(.system(size: 18))
                }
                
                Text(title)
                    .font(.system(size: 18, weight: .medium))


                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
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
                .background(isSelected ?.black : Color(.systemGray6))
                .foregroundColor(isSelected ? .white : .primary)
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
                                HStack(spacing: 12) {
                                    Button {
                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                            showSideMenu.toggle()
                                        }
                                    } label: {
                                        Image(systemName: "line.3.horizontal")
                                            .font(.system(size: 20, weight: .bold))
                                            .padding(8)
                                          //  .background(Color(.systemGray5))
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

                                    Spacer()
                                    
                                    HStack(spacing: 8) {
                                        if isStockEditMode,
                                           !selectedCategory.isEmpty,
                                           selectedCategory != "✏️ הערות" {
                                            Button {
                                                clearStockForSelectedCategory()
                                            } label: {
                                                Text("אפס")
                                                    .font(.system(size: 14, weight: .semibold))
                                                    .padding(.horizontal, 10)
                                                    .padding(.vertical, 6)
                                                    .background(Color(.systemGray5))
                                                    .clipShape(Capsule())
                                            }
                                        }

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
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 6)
                                                .background(Color(.systemGray5))
                                                .clipShape(Capsule())
                                        }
                                    }
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

                                    // +
                                    Button { /* your add product */ } label: {
                                        Image(systemName: "plus.circle.fill")
                                            .font(.system(size: 26, weight: .semibold))
                                            .foregroundColor(.primary)
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
                                HStack(spacing: 8) {
                                    Image(systemName: "magnifyingglass")
                                        .foregroundColor(.secondary)
                                    
                                    TextField(isRtl ? "חיפוש מוצר…" : "Search product…", text: $searchText)
                                        .textInputAutocapitalization(.none)
                                        .autocorrectionDisabled()
                                        .multilineTextAlignment(.leading)
                                        .focused($isSearchFocused)
                                        .padding(.trailing,
                                                 searchText.isEmpty
                                                    ? 120
                                                    : 0
                                           )
                                    if !searchText.isEmpty {
                                        Button {
                                            searchText = ""
                                        } label: {
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
                                .environment(\.layoutDirection, .rightToLeft)
                                
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
                                        imageURL: "https://beithaam.com/wp-content/uploads/2024/12/share.jpg",
                                        modifierGroups: []
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
                                    Button {
                                        showClearStockConfirm = true
                                    } label: {
                                        Text("אפס")
                                            .font(.system(size: 14, weight: .semibold))
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 6)
                                            .background(Color(.systemGray5))
                                            .clipShape(Capsule())
                                    }
                                    .alert("האם אתה בטוח?", isPresented: $showClearStockConfirm) {
                                        Button("כן", role: .destructive) {
                                            clearStockForSelectedCategory()
                                        }
                                        Button("בטל", role: .cancel) { }
                                    } message: {
                                        Text("זה יאפס את המלאי לכל המוצרים בקטגוריה הנבחרת.")
                                    }
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
                                    categories: categoryOrder,
                                    selected: selectedCategory,
                                    onTap: { cat in
                                        searchText = ""
                                        isSearchFocused = false
                                        selectedCategory = cat
                                    },
                                    onOrdersTap: { showOrdersAdmin = true },
                                    enableReorder: false,
                                    draggingCategory: $draggingCategory,
                                    categoryOrder: $categoryOrder,
                                    onReorderCommitted: {
                                        persistCategoryOrder()
                                        sendCategoryOrderToServer()
                                        if !categoryOrder.contains(selectedCategory),
                                           let first = categoryOrder.first { selectedCategory = first }
                                    }
                                )

                                VStack(spacing: 8) {
                                    printBacklogHUD()

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
                                            let qty   = quantityInBasket(for: item)
                                            let remainingForItem = maxAdditionalQuantity(for: item)

                                            let isOut =
                                            selectedCategory != "✏️ הערות"
                                            && (
                                                !stockToggles.isOn(item.id)
                                                || (remainingForItem ?? 1) <= 0
                                            )

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
                                                    isOutOfStock: isOut
                                                )
                                                .scaleEffect(tappedProductId == item.id ? 0.96 : 1.0)
                                                .contentShape(Rectangle())
                                                .onTapGesture {
                                                    // If this interaction was a swipe, ignore the tap
                                                    guard !isStockEditMode else { return }
                                                    guard swipingProductId == nil else { return }

                                                    searchText = ""
                                                    isSearchFocused = false

                                                    if selectedCategory == "✏️ הערות" {
                                                        messageTargetIsKitchen = false
                                                        messageTargetIsBakery  = false

                                                        if item.name.contains("וטרינה") {
                                                            messageTargetIsBakery  = true
                                                        } else if item.name.contains("מטבח") {
                                                            messageTargetIsKitchen = true
                                                        }

                                                        messageText  = ""
                                                        messagePrice = ""

                                                        DispatchQueue.main.async {
                                                            showMessageSheet = true
                                                        }
                                                        return
                                                    }

                                                    guard !isOut else {
                                                        Haptics.error()
                                                        return
                                                    }

                                                    if let maxAdd = maxAdditionalQuantity(for: item), maxAdd <= 0 {
                                                        Haptics.error()
                                                        return
                                                    }

                                                    withAnimation(.spring(response: 0.18, dampingFraction: 0.6, blendDuration: 0.1)) {
                                                        tappedProductId = item.id
                                                    }
                                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                                        withAnimation(.spring(response: 0.25, dampingFraction: 0.7, blendDuration: 0.1)) {
                                                            tappedProductId = nil
                                                        }
                                                    }

                                                    Haptics.light()

                                                    addToBasket(
                                                        item: item,
                                                        quantity: 1,
                                                        subtitle: nil,
                                                        unitPrice: item.price
                                                    )
                                                }
                                                .contextMenu {
                                                    Group {
                                                        if selectedCategory != "הודעות" {

                                                           


                                                            Button("ערוך מוצר") {
                                                                adminDraft = makeAdminDraft(from: item)
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

                                                        if isEditingThisStock {
                                                            TextField(
                                                                "∞",
                                                                text: Binding(
                                                                    get: {
                                                                        if !stockToggles.isOn(item.id) { return "0" }

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
                                .scrollDisabled(isHorizontalSwipe)   // ✅ key line (iOS16+)

                            } else {
                                // iOS 15 fallback: swipe still works, but we can’t scroll-disable during swipe.
                                // (Usually OK, but iOS16+ is the ideal behaviour.)
                                ScrollView {
                                    LazyVStack(spacing: 8) {
                                        ForEach(filteredItems) { item in
                                            let qty   = quantityInBasket(for: item)
                                            let remainingForItem = maxAdditionalQuantity(for: item)

                                            let isOut =
                                            selectedCategory != "✏️ הערות"
                                            && (
                                                !stockToggles.isOn(item.id)
                                                || (remainingForItem ?? 1) <= 0
                                            )

                                            let stockAmount = stockAdjustments[item.id]
                                            let isEditingStock = editingStockProductId == item.id
                                            let showFullStockUI = isStockEditMode || isEditingStock

                                            let swipeOffset = productSwipeOffsets[item.id] ?? 0

                                            let tile =
                                            ZStack(alignment: .topTrailing) {
                                                CashProductTile(
                                                    item: item,
                                                    quantityInBasket: qty > 0 ? qty : nil,
                                                    isOutOfStock: isOut
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
                        .sheet(isPresented: $showOutboxLog) {
                            OutboxLogView()
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
                            .presentationDetents([.height(340)])
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
                                                     let name: String
                                                     if messageTargetIsKitchen {
                                                         name = "הערה למטבח"
                                                     } else if messageTargetIsBakery {
                                                         name = "הערה לוטרינה"
                                                     } else {
                                                         name = "הערה לבר"
                                                     }

                                                     let printer: String = {
                                                         if messageTargetIsKitchen { return "Kitchen" }
                                                         if messageTargetIsBakery  { return "Bakery" }
                                                         return "Bar"
                                                     }()

                                                     let item = ShellMenuItem(
                                                         id: Int.random(in: -9000 ... -8000),
                                                         name: name,
                                                         price: price,
                                                         category: "הערות",
                                                         modifiers: nil,
                                                         imageURL: nil,
                                                         description: nil,
                                                         status: 1,
                                                         stockQuantity: nil,
                                                         printer: printer          // ✅
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
                
                if isPhoneLayout && !basket.isEmpty {
                    BasketBar(
                        totalQuantity: basketTotalQuantity,
                        totalPrice: finalTotal
                    ) {
                        showBasketSheetPhone = true
                    }
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
                updatePendingBacklog()
            }
            
            .onAppear {
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
                    api.load(skipCache: true)
                }
            }
            .onChange(of: basket.count) { _ in
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
                .environment(\.isRtl, isRtl)
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
                if stockCommitWorkItem != nil { return }      // commit scheduled/running
                if !stockToggles.pending.isEmpty { return }   // status toggle sync in-flight

                if !showOrderFlow && basket.isEmpty {
                    api.load(skipCache: true)
                }
            }
            .onChange(of: isPayLaterMode) { print("isPayLaterMode =", $0) }
            .fullScreenCover(isPresented: $showOrderFlow) {
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
                        PrinterManager.shared.printCashPointSplit(
                            orderNumber: ticketNumber,
                            entries: entriesArray,
                            total: totalForPrint,
                            diningMode: diningMode,
                            customerName: safeName,
                            customerPhone: posSavedPhone
                        )
                        
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
                    isRtl: isRtl,
                    diningMode: $diningMode,
                    requiresPhoneStep: requiresPhoneStep,

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
                        nextBasketLineId = 1

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
            }
            .fullScreenCover(item: $adminDraft) { draft in
                AdminProductEditorView(
                    draft: draft,
                    mode: draft.productId == nil ? .create : .edit,
                    onSave: { updatedDraft in
                        applyAdminSave(updatedDraft)
                    },
                    onDelete: {
                        guard let pid = draft.productId else { return }

                        let miniId = Int(UserDefaults.standard.string(forKey: "shopId") ?? "0") ?? 0
                        guard miniId > 0 else {
                            print("❌ onDelete: missing miniAppId/shopId")
                            return
                        }

                        if let idx = api.items.firstIndex(where: { $0.id == pid }) {
                            api.items.remove(at: idx)
                        }

                        let base = UserDefaults.standard.string(forKey: "apiBase") ?? "https://minis.studio"
                        guard let url = URL(string: "\(base)/api/products/\(pid)/archive") else { return }
                        let debugCurl = """
                        curl -X POST "\(base)/api/products/\(pid)/archive" \\
                          -H "Content-Type: application/json" \\
                          -d '{ "miniAppId": \(miniId) }'
                        """
                        print("🔎 Archive DEBUG CURL:\n\(debugCurl)")
                        struct ArchiveBody: Encodable { let miniAppId: Int }

                        var req = URLRequest(url: url)
                        req.httpMethod = "POST"
                        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                        req.httpBody = try? JSONEncoder().encode(ArchiveBody(miniAppId: miniId))

                        Task {
                            do {
                                let (_, resp) = try await URLSession.shared.data(for: req)
                                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                                print("🗑️ Archive product \(pid) (miniAppId \(miniId)) → HTTP \(code)")
                            } catch {
                                print("❌ Archive error:", error.localizedDescription)
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
                guard !isStockEditMode else { return }
                loadCategoryOrderFromStorageOrMenu()
                let items = api.items

                var initialStatus: [Int: Int] = [:]
                var initialAdjustments: [Int: Int] = [:]

                for item in items {

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
                                .foregroundColor(.white)
                                .frame(width: padWidth, height: 50)
                                .background(amountInt > 0 ? Color.black : Color.gray.opacity(0.4))
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

            PrinterManager.shared.printCashPointSplit(
                orderNumber: ticketNumber,
                entries: printerEntries,
                total: printerTotal,
                diningMode: mode,
                customerName: nameSnapshot,
                customerPhone: phoneSnapshot     // ✅ FIX (was nil)
            )
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
            nextBasketLineId = 1

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
    
    private func productSortKey(_ item: ShellMenuItem) -> (Int, Int, String) {
        // ✅ While editing stock: do NOT sort by active/inactive (prevents jumping)
        if isStockEditMode {
            return (0, stableIndex(item), item.name)
        }

        // Normal mode: active first
        let isActive = stockToggles.isOn(item.id)
        let activeRank = isActive ? 0 : 1
        return (activeRank, stableIndex(item), item.name)
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
        activeTeamTab = tab
        isPayLaterMode = true
        hasChosenServiceMode = true
        diningMode = .dineIn

        // reset local state
        basket.removeAll()
        lockedLineIds.removeAll()
        lineSessionTime.removeAll()
        unpaidOrderId = nil
        nextBasketLineId = 1

        let miniAppId = resolvedMiniAppId

        TeamTabsAPI.openOrCreate(miniAppId: miniAppId, tab: tab) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let oid):
                    unpaidOrderId = oid

                    // ✅ Always fetch from server so it restores across devices
                    TeamTabsAPI.fetchOrderMetadata(orderId: oid) { res in
                        DispatchQueue.main.async {
                            switch res {
                            case .success(let meta):
                                restoreOrderFromMetadata(meta)   // ✅ fills basket + lockedLineIds
                            case .failure(let err):
                                // If order exists but has no metadata yet, keep empty
                                print("⚠️ fetchOrderMetadata failed:", err.localizedDescription)
                            }
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
        nextBasketLineId = 1

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

        private var offlineCount: Int {
            monitor.rows.filter { !$0.isReachable }.count
        }

        private var isOnPrinterNetwork: Bool {
            monitor.isNetworkUp
        }

        private var allOnline: Bool {
            !monitor.rows.isEmpty && offlineCount == 0
        }

        private var statusTitle: String {
            // ✅ If we don’t even have network, show “neutral” copy
            guard isOnPrinterNetwork else {
                return "לא מחובר לרשת המדפסות"
            }

            // On network: show real health
            if allOnline { return "כל המדפסות מחוברות" }
            return "חסרה מדפסת (\(offlineCount))"
        }

        private var iconName: String {
            // ✅ Not on network → neutral printer icon
            guard isOnPrinterNetwork else { return "printer" }

            // On network → show filled when everything ok, otherwise still show printer (not slash)
            return allOnline ? "printer.fill" : "printer"
        }

        private var iconColor: Color {
            // ✅ Not on network → gray
            guard isOnPrinterNetwork else { return .secondary }

            // On network: good = primary, problem = primary (with badge later if you want)
            return allOnline ? .primary : .primary
        }

        private var canTestPrint: Bool {
            // ✅ Only allow test print if we are on the printer network
            // and at least one printer is reachable
            isOnPrinterNetwork && monitor.rows.contains(where: { $0.isReachable })
        }

        var body: some View {
            ZStack {
                Color(.systemBackground).ignoresSafeArea()

                VStack(spacing: 12) {

                    // top bar
                    HStack {
                        if isRtl { Spacer() }
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 16, weight: .bold))
                                .padding(8)
                                .background(Color(.systemGray5))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        if !isRtl { Spacer() }
                    }
                    .padding(.top, 10)
                    .padding(.horizontal, 14)

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

                    // test print
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

                    Spacer(minLength: 0)
                }
            }
            .onAppear {
                Task { await monitor.checkNow() }
            }
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

        private var title: String {
            if targetIsKitchen {
                return isRtl ? "הערה למטבח" : "Message to kitchen"
            } else if targetIsBakery {
                return isRtl ? "הערה לוטרינה" : "Message to vitrine"
            } else {
                return isRtl ? "הערה לבר" : "Message to bar"
            }
        }

        // Text is OPTIONAL now – only price must be numeric
        private var parsedPrice: Double? {
            let raw = priceText
                .replacingOccurrences(of: ",", with: ".")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // allow empty -> treat as 0 by default
            if raw.isEmpty { return 0 }

            guard let d = Double(raw), d >= 0 else { return nil }
            return d
        }

        private var canSubmit: Bool {
            parsedPrice != nil          // 👈 text no longer required
        }

        private var hasText: Bool {
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
                            Button {
                                text = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(.secondary)
                                    .padding(8)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // PRICE FIELD
                    TextField(isRtl ? "סכום" : "Amount", text: $priceText)
                        .keyboardType(.decimalPad)
                        .padding(10)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(10)
                        .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
                        .focused($priceFocused)
                        .onChange(of: priceFocused) { focused in
                            if focused {
                                DispatchQueue.main.async {
                                    UIApplication.shared.sendAction(
                                        #selector(UIResponder.selectAll(_:)),
                                        to: nil,
                                        from: nil,
                                        for: nil
                                    )
                                }
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
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(canSubmit ? .black : Color.gray.opacity(0.4))
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
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 16, weight: .bold))
                                .padding(8)
                                .background(Color(.systemGray5))
                                .clipShape(Circle())
                        }
                    }
                }
                .onAppear {
                    // default price to 0 so waiter can just type note or nothing
                    if priceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        priceText = "0"
                    }
                    messageFocused = true
                }
            }
            .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
        }
    }

    struct BasketBar: View {
        @Environment(\.isRtl) private var isRtl
        @Environment(\.currency) private var currency

        let totalQuantity: Int
        let totalPrice: Double
        let onTap: () -> Void

        var body: some View {
            HStack {
                Button(action: onTap) {
                    HStack {
                        if isRtl {
                            // RTL: quantity • הזמנה • price
                            HStack(spacing: 12) {
                                Text("\(totalQuantity)")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(Color.black)
                                    .frame(width: 28, height: 28)
                                    .background(Color.white)
                                    .clipShape(Circle())

                                Text("הזמנה")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundColor(.white)
                            }

                            Spacer()

                            Text(String(format: "\(currency)%.2f", totalPrice))
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(.white)

                        } else {
                            // LTR: price • Order • quantity
                            Text(String(format: "\(currency)%.2f", totalPrice))
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(.white)

                            Spacer()

                            HStack(spacing: 12) {
                                Text("Order")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundColor(.white)

                                Text("\(totalQuantity)")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(Color.black)
                                    .frame(width: 28, height: 28)
                                    .background(Color.white)
                                    .clipShape(Circle())
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .frame(height: 60)
                    .frame(maxWidth: .infinity)
                    .background(
                        Color.black
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    )
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

        /// Date used to FETCH the Z row (previous day)
        private var queryDate: Date {
            Calendar.current.date(byAdding: .day, value: +0, to: restoreDate) ?? restoreDate
        }

        /// Date shown on screen + printed on receipt
        private var printDate: Date { restoreDate }

        private func handlePrint() {
            guard let d = model.data else { return } // ✅ must have data
            PrinterManager.shared.printSalesReport(
                d,
                type: type,
                reportDate: printDate,
                isRestore: (type == .z && restoreMode),
                generatedAt: Date()
            )
        }

        // ✅ Header date reflects restore selection when restoring Z
        private var headerDate: Date {
            (type == .z && restoreMode) ? restoreDate : Date()
        }

        private var headerDateText: String {
            let df = DateFormatter()
            df.locale = Locale(identifier: "he_IL")
            df.dateFormat = "dd/MM/yyyy"
            return df.string(from: headerDate)
        }

        private var generatedLine: String {
            let lrm = "\u{200E}"

            let t = DateFormatter()
            t.locale = Locale(identifier: "he_IL")
            t.dateFormat = "HH:mm:ss"

            let d = DateFormatter()
            d.locale = Locale(identifier: "he_IL")
            d.dateFormat = "dd/MM/yyyy"

            if type == .z && restoreMode {
                return "שחזור לתאריך \(lrm)\(d.string(from: restoreDate))"
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
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(.black)
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
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(.black)
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
        let isSelected =
            (optionSelections[entry.id] ?? [:])[group.title] == opt.name

        Text(opt.extraPrice > 0
             ? "\(opt.name) +\(Int(opt.extraPrice))"
             : opt.name)
            .font(.system(size: 17, weight: .medium))   // ⬅️ Bigger
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(isSelected
                        ?.black
                        : Color(.systemGray5))
            .foregroundColor(isSelected ? .white : .primary)
            .clipShape(Capsule())
            .onTapGesture {
                var map = optionSelections[entry.id] ?? [:]
                map[group.title] = opt.name
                optionSelections[entry.id] = map
                updateEntryPricingAndSubtitle(lineId: entry.id)
                Haptics.light()
            }
    }
    
    @ViewBuilder
    func additionChip(entry: BasketEntry, group: ModifierGroup, opt: ModifierItem) -> some View {
        let isSelected = (additionSelections[entry.id] ?? []).contains(opt.name)

        Text(opt.extraPrice > 0
             ? "\(opt.name) +\(Int(opt.extraPrice))"
             : opt.name)
            .font(.system(size: 17, weight: .medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(isSelected ? Color.black : Color(.systemGray5))
            .foregroundColor(isSelected ? .white : .primary)
            .clipShape(Capsule())
            .onTapGesture {
                var set = additionSelections[entry.id] ?? []
                if isSelected {
                    set.remove(opt.name)
                } else {
                    set.insert(opt.name)
                }
                additionSelections[entry.id] = set
                updateEntryPricingAndSubtitle(lineId: entry.id)
                Haptics.light()
            }
    }
    private func basketRow(_ entry: BasketEntry) -> some View {
        let isLocked   = lockedLineIds.contains(entry.id)
        let isExpanded = !isLocked && expandedBasketLineId == entry.id
        let swipeOffset = basketSwipeOffsets[entry.id] ?? 0

        let lineTotal = Double(entry.quantity) * entry.unitPrice

        let noteBinding = Binding<String>(
            get: {
                if let existing = noteDrafts[entry.id] { return existing }
                return noteFromSubtitle(entry.subtitle)
            },
            set: { newValue in
                noteDrafts[entry.id] = newValue
                updateEntryPricingAndSubtitle(lineId: entry.id)
            }
        )

        // Main content for this row
        let content = VStack(alignment: .leading, spacing: 6) {
            // MAIN ROW
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.item.name)
                        .font(.system(size: 20, weight: .medium))

                    if let s = entry.subtitle, !s.isEmpty, !isExpanded {
                        Text(cleanModifierSubtitle(s) ?? s)
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                // ✅ RIGHT SIDE: line total + qty controls
                HStack(spacing: 10) {
                    Text(String(format: "\(currency)%.0f", lineTotal))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(minWidth: 86, alignment: isRtl ? .leading : .trailing)

                    HStack(spacing: 8) {
                        if !isLocked {
                            Button { decrementEntry(entry.id) } label: {
                                Image(systemName: "minus.circle.fill")
                                    .font(.system(size: 22))
                            }
                        }

                        Text("\(entry.quantity)")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(minWidth: 26)

                        if !isLocked {
                            Button { incrementEntry(entry.id) } label: {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 22))
                            }
                        }
                    }
                }
            }

            // EXPANDED: modifiers + notes
            if isExpanded {
                if let groups = entry.item.modifiers, !groups.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {

                        // 🔹 Separator BETWEEN modifier groups
                        ForEach(Array(groups.enumerated()), id: \.element.id) { index, g in
                            if index > 0 {
                                Rectangle()
                                    .fill(Color.black.opacity(0.06))
                                    .frame(height: 1)
                                    .padding(.vertical, 4)
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text(g.title)
                                    .font(.system(size: 14, weight: .semibold))

                                switch g.type {
                                case .options:
                                    if g.items.count > 3 {
                                        let rowStarts = Array(stride(from: 0, to: g.items.count, by: 3))

                                        VStack(alignment: isRtl ? .leading : .trailing, spacing: 8) {
                                            ForEach(rowStarts, id: \.self) { start in
                                                let end = min(start + 3, g.items.count)
                                                let rowItems = Array(g.items[start..<end])

                                                HStack(spacing: 8) {
                                                    if !isRtl { Spacer() }
                                                    ForEach(rowItems) { opt in
                                                        optionChip(entry: entry, group: g, opt: opt)
                                                    }
                                                    if isRtl { Spacer() }
                                                }
                                            }
                                        }
                                    } else {
                                        HStack(spacing: 8) {
                                            if !isRtl { Spacer() }
                                            ForEach(g.items) { opt in
                                                optionChip(entry: entry, group: g, opt: opt)
                                            }
                                            if isRtl { Spacer() }
                                        }
                                        .frame(maxWidth: .infinity,
                                               alignment: isRtl ? .leading : .trailing)
                                    }

                                case .additions:
                                    Group {
                                        if g.items.count > 3 {
                                            let rowStarts = Array(stride(from: 0, to: g.items.count, by: 3))

                                            VStack(alignment: isRtl ? .leading : .trailing, spacing: 8) {
                                                ForEach(rowStarts, id: \.self) { start in
                                                    let end = min(start + 3, g.items.count)
                                                    let rowItems = Array(g.items[start..<end])

                                                    HStack(spacing: 8) {
                                                        if !isRtl { Spacer() }

                                                        ForEach(rowItems) { opt in
                                                            let isSelected =
                                                                (additionSelections[entry.id] ?? []).contains(opt.name)

                                                            Text(opt.extraPrice > 0
                                                                 ? "\(opt.name) +\(Int(opt.extraPrice))"
                                                                 : opt.name)
                                                                .font(.system(size: 17, weight: .medium))
                                                                .padding(.horizontal, 16)
                                                                .padding(.vertical, 8)
                                                                .background(isSelected ? Color.black : Color(.systemGray5))
                                                                .foregroundColor(isSelected ? .white : .primary)
                                                                .clipShape(Capsule())
                                                                .onTapGesture {
                                                                    var set = additionSelections[entry.id] ?? []
                                                                    if isSelected { set.remove(opt.name) }
                                                                    else { set.insert(opt.name) }
                                                                    additionSelections[entry.id] = set
                                                                    updateEntryPricingAndSubtitle(lineId: entry.id)
                                                                    Haptics.light()
                                                                }
                                                        }

                                                        if isRtl { Spacer() }
                                                    }
                                                }
                                            }

                                        } else {
                                            HStack(spacing: 8) {
                                                if !isRtl { Spacer() }

                                                ForEach(g.items) { opt in
                                                    let isSelected =
                                                        (additionSelections[entry.id] ?? []).contains(opt.name)

                                                    Text(opt.extraPrice > 0
                                                         ? "\(opt.name) +\(Int(opt.extraPrice))"
                                                         : opt.name)
                                                        .font(.system(size: 17, weight: .medium))
                                                        .padding(.horizontal, 16)
                                                        .padding(.vertical, 8)
                                                        .background(isSelected ? Color.black : Color(.systemGray5))
                                                        .foregroundColor(isSelected ? .white : .primary)
                                                        .clipShape(Capsule())
                                                        .onTapGesture {
                                                            var set = additionSelections[entry.id] ?? []
                                                            if isSelected { set.remove(opt.name) }
                                                            else { set.insert(opt.name) }
                                                            additionSelections[entry.id] = set
                                                            updateEntryPricingAndSubtitle(lineId: entry.id)
                                                            Haptics.light()
                                                        }
                                                }

                                                if isRtl { Spacer() }
                                            }
                                            .frame(maxWidth: .infinity,
                                                   alignment: isRtl ? .leading : .trailing)
                                        }
                                    }
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
                        let currentText = noteBinding.wrappedValue
                        noteEditingLineId = entry.id
                        noteEditingText = currentText
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

        return VStack(spacing: 0) {
            content
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

            Rectangle()
                .fill(Color.black.opacity(0.06))
                .frame(height: 1)
                .padding(.leading, 16)
        }
        .offset(x: swipeOffset)
        .contentShape(Rectangle())
        .simultaneousGesture(basketSwipeGesture(for: entry))
        
        // ✅ KEEP ONLY ONE note sheet (you had it twice)
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
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                if expandedBasketLineId == entry.id {
                    expandedBasketLineId = nil
                } else {
                    expandedBasketLineId = entry.id
                }
            }
        }
        .onAppear {
            if optionSelections[entry.id] == nil {
                var map = optionsFromSubtitle(entry.subtitle)

                if let groups = entry.item.modifiers, !groups.isEmpty {
                    for g in groups where g.type == .options {
                        if map[g.title] == nil {
                            map[g.title] = g.items.first?.name
                        }
                    }
                    optionSelections[entry.id] = map
                    updateEntryPricingAndSubtitle(lineId: entry.id)
                } else {
                    optionSelections[entry.id] = map
                }
            }

            if additionSelections[entry.id] == nil {
                additionSelections[entry.id] = []
            }
        }
        
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

        var body: some View {
            NavigationStack {
                VStack(spacing: 16) {
                    // Text field + inline clear button
                    ZStack(alignment: .topTrailing) {
                        TextField(isRtl ? "הוסף הערה..." : "Add a note…",
                                  text: $text,
                                  axis: .vertical)
                            .lineLimit(2...4)
                            .padding(12)
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(12)
                            .focused($focused)
                            .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)

                        if hasText {
                            Button {
                                text = ""
                            } label: {
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
                        Button {
                            onCancel()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 16, weight: .bold))
                                .padding(8)
                                .background(Color(.systemGray5))
                                .clipShape(Circle())
                        }
                    }
                }
                .onAppear {
                    text = initialText
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

    let enableReorder: Bool   // ✅ NEW

    @Binding var draggingCategory: String?
    @Binding var categoryOrder: [String]
    let onReorderCommitted: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(categories, id: \.self) { cat in
                    let row = HStack {
                        Text(cat)
                            .font(.system(size: 17, weight: .medium))
                            .foregroundColor(cat == selected ? .white : .primary)
                            .padding(.vertical, 10)
                            .padding(.horizontal, 12)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(cat == selected ? .black : Color.clear)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { onTap(cat) }

                    if enableReorder {
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

    var body: some View {
        let inBasket = (quantityInBasket ?? 0) > 0

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
            .shadow(color: .black.opacity(0.04), radius: 2, y: 2)
            .opacity(isOutOfStock ? 0.4 : 1.0)

            // 🔴 OUT OF STOCK BADGE
            if isOutOfStock {
                Text("")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.gray)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                //.background(Color.gray)
                    .clipShape(Capsule())
                    .padding(6)
            }
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
        guard let url = URL(string: "\(API_BASE)/api/products/\(productId)/status") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        struct Payload: Encodable { let miniAppId: Int; let enabled: Bool }

        do {
            req.httpBody = try JSONEncoder().encode(Payload(miniAppId: shopId, enabled: enabled))
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return false
            }
            return true
        } catch {
            return false
        }
    }
}


private extension View {
    @ViewBuilder
    func applyIf<T: View>(_ condition: Bool, transform: (Self) -> T) -> some View {
        if condition { transform(self) } else { self }
    }
}

import SwiftUI
import WebKit

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


import SwiftUI
import WebKit

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



// MARK: - CashPoint WebView (HTML + minis://zcredit intercept)

