import SwiftUI
import Combine

// MARK: - Station enums (TOP LEVEL)



struct AdminOrdersApiResponse: Decodable {
    let ok: Bool
    let count: Int
    let orders: [OrderDTO]
}



struct AdminOrdersView: View {
    @State private var searchText: String = ""
    @State private var showOpenOnly: Bool = false
    @State private var closingTeamTableIds: Set<Int> = []
    @State private var optimisticallyClosedIds: Set<Int> = []
    enum AdminMode {
        case normal
        case endOfDay
    }
    let mode: AdminMode
       let eodFilter: EODFilter
       let onSelectUnpaid: ((AdminOrderItem) -> Void)?
       let onRemainingChanged: ((Int) -> Void)?
       let onAllResolved: (() -> Void)?

       init(
           mode: AdminMode = .normal,
           eodFilter: EODFilter = .all,
           onSelectUnpaid: ((AdminOrderItem) -> Void)? = nil,
           onRemainingChanged: ((Int) -> Void)? = nil,
           onAllResolved: (() -> Void)? = nil
       ) {
           self.mode = mode
           self.eodFilter = eodFilter
           self.onSelectUnpaid = onSelectUnpaid
           self.onRemainingChanged = onRemainingChanged
           self.onAllResolved = onAllResolved
       }
    
    private func isTeamTableName(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("שולחן")
    }
    
    @MainActor
    private func refreshOrders() async {
        await loadOrders(showSpinner: false)
    }
  
    private func isTeamTableOrder(_ o: AdminOrderItem) -> Bool {
        o.customerName.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("שולחן")
    }

    private var visibleOrders: [AdminOrderItem] {
        // whatever you already do in filteredOrders,
        // but ALSO hide those we optimistically closed
        filteredOrders.filter { !optimisticallyClosedIds.contains($0.id) }
    }

    private func notifyRemainingChangedIfNeeded() {
        // only when you're in the team-table step (or your eodFilter == .teamTablesOnly)
        let remaining = visibleOrders.filter { isTeamTableOrder($0) && $0.isUnpaid }.count
        onRemainingChanged?(remaining)
    }
    // MARK: - Decoding helper (shared by cache + network)
    private func decodeAdminOrders(from data: Data) -> [AdminOrderItem]? {
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

            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unrecognized date: \(s)")
        }

        do {
            let parsed = try decoder.decode(AdminOrdersApiResponse.self, from: data)
            guard parsed.ok else {
                print("❌ admin/orders cache: ok=false")
                return nil
            }

            let mapped: [AdminOrderItem] = parsed.orders.map { dto in
                let displayOrderNumber = dto.ticketNumber ?? dto.id

                let status: AdminOrderStatus = {
                    switch dto.status ?? 0 {
                    case 4:  return .ready
                    case 5:  return .collected
                    default: return .received
                    }
                }()

                let displayName: String = {
                    let preferred = (dto.customerDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
                    let fallback  = dto.customerName.trimmingCharacters(in: .whitespacesAndNewlines)

                    let name = !preferred.isEmpty ? preferred : fallback
                    return name.isEmpty ? "אינשם" : name
                }()

                let sourceHe: String = {
                    switch dto.source.lowercased() {
                    case "cashpoint": return "קופה"
                    case "kiosk":     return "קיוסק"
                    case "mini", "appclip", "web": return "מיני"
                    default:          return dto.source
                    }
                }()

                let lineItems: [AdminOrderLineItem] = dto.lines.enumerated().map { idx, l in
                    let quantity = max(l.qty, 1)

                    let effectiveUnit: Double = {
                        if let explicitUnit = l.unitPrice, explicitUnit > 0 {
                            return explicitUnit
                        }
                        if let row = l.lineTotal, row > 0, quantity > 0 {
                            return row / Double(quantity)
                        }
                        if let pid = l.productId {
                            let p = MenuCatalog.shared.price(for: pid)
                            if p > 0 { return p }
                        }
                        return 0
                    }()

                    let resolvedPrinter = l.station ?? MenuCatalog.shared.printer(for: l.productId)

                    let cancelId = l.basketLineId ?? l.itemId ?? (idx + 1)   // idx fallback only if you must

                    return AdminOrderLineItem(
                        id: l.itemId ?? (l.productId ?? idx),   // stable UI id
                        productId: l.productId,
                        basketLineId: l.basketLineId,               // ✅ used for cancel endpoint
                        name: l.name,
                        quantity: quantity,
                        unitPrice: effectiveUnit,
                        category: l.category,
                        modifiersText: l.modifiers,
                        updatedAt: l.updatedAt,
                        printer: resolvedPrinter
                    )
                }

                let stationSet = Set(dto.lines.map { line in
                    classifyAdminStation(fromPrinter: line.station ?? MenuCatalog.shared.printer(for: line.productId))
                })

                // ✅ NEW: Open order detection (prefer server status + payment method)
                // You changed server status: 0=open, 1=closed. So use it when present.
                

                // fallback for older servers (bucket/stage)
                let bucketLower = dto.bucket.lowercased()
                let stageLower  = dto.stage.lowercased()
                let legacyUnpaid =
                    bucketLower.contains("unpaid")
                    || bucketLower.contains("open")
                    || bucketLower.contains("tab")
                    || stageLower.contains("unpaid")

                let statusIsOpen = (dto.status == 0)
                let paymentIsUnpaid = (dto.paymentMethod ?? "").lowercased() == "unpaid"

              
                // If server sends Status reliably (0=open, 1=closed), trust it.
                // Only fallback to paymentMethod/bucket if status is missing (nil).
                let isUnpaid: Bool = {
                    if dto.status != nil { return statusIsOpen }

                    let paymentIsUnpaid = (dto.paymentMethod ?? "").lowercased() == "unpaid"
                    let bucketLower = dto.bucket.lowercased()
                    let stageLower  = dto.stage.lowercased()
                    let legacyUnpaid =
                        bucketLower.contains("unpaid")
                        || bucketLower.contains("open")
                        || bucketLower.contains("tab")
                        || stageLower.contains("unpaid")

                    return paymentIsUnpaid || legacyUnpaid
                }()
                return AdminOrderItem(
                    id: dto.id,
                    orderId: String(displayOrderNumber),
                    customerName: displayName,
                    subtitle: dto.itemSummary,
                    source: sourceHe,
                    status: status,
                    placedAt: dto.placedAt,
                    items: lineItems,
                    total: dto.totalGBP,
                    stations: stationSet,
                    isUnpaid: isUnpaid,
                    paymentMethod: dto.paymentMethod,
                    customerPhone: dto.customerPhone          // ✅ NEW
                )
            }

            return mapped
        } catch {
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
            print("❌ admin/orders decode failed: \(error)\nBody:\n\(body)")
            return nil
        }
    }

    private func classifyAdminStation(fromPrinter printer: String?) -> AdminStation {
        switch (printer ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "kitchen": return .kitchen
        case "bakery":  return .bakery
        case "bar":     return .bar
        default:        return .bar
        }
    }

    private func toBasketEntries(from order: AdminOrderItem) -> [BasketEntry] {
        order.items.map { li in
            BasketEntry(
                id: li.id,
                item: makeShellMenuItem(from: li),
                quantity: li.quantity,
                subtitle: li.modifiersText,
                unitPrice: li.unitPrice
            )
        }
    }

    private func diningMode(for order: AdminOrderItem) -> DiningMode {
        if order.subtitle.contains("לקחת") { return .takeAway }
        return .dineIn
    }

    @State private var allowAutoPrint = true
    private let baseURL = "https://minis.studio/api/admin/orders"
    private let miniAppId = MenuTheme.miniId

    @Environment(\.dismiss) private var dismiss
    @Environment(\.isRtl)   private var isRtl

    @State private var printedOrderIds: Set<Int> = []
    @State private var orders: [AdminOrderItem] = []
    @State private var selectedOrder: AdminOrderItem? = nil
    @State private var isLoading = false

    @State private var pollTimer = Timer
        .publish(every: 10, on: .main, in: .common)
        .autoconnect()

  
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {

                // 🔹 Top controls: Open-only toggle + counts
                
           

                Divider().padding(.top, 8)

                if isLoading && orders.isEmpty {
                    Spacer()
                    ProgressView()
                    Spacer()
                } else {
                    ScrollView {
                        let list = filteredOrders

                        LazyVStack(spacing: 14) {
                            ForEach(visibleOrders) { order in

                                let isEod = (mode == .endOfDay)
                                let isTeam = isTeamTableOrder(order)

                                AdminOrderRow(
                                    item: order,

                                    // ✅ EOD: hide ALL row buttons by passing nil for all actions
                                    onPrint: isEod ? {} : { printOrder(order) },
                                    onPrintInvoice: isEod ? {} : { printInvoice(for: order) },

                                    // ✅ IMPORTANT: in EOD we still want tap-to-open-details,
                                    // but row should NOT show buttons => keep this nil in EOD.
                                    onOpenInCashPoint: isEod ? nil : ((order.isUnpaid) ? { onSelectUnpaid?(order) } : nil),

                                    // ✅ EOD: also hide "סגור שולחן" button on the row card
                                    onCloseTeamTable: isEod ? nil : (isTeam ? {
                                        TeamTabsAPI.close(orderId: order.id) { res in
                                            DispatchQueue.main.async {
                                                switch res {
                                                case .success:
                                                    orders.removeAll { $0.id == order.id }
                                                    Task { await loadOrders(showSpinner: false) }
                                                    Haptics.success()
                                                case .failure(let err):
                                                    print("❌ close team tab failed:", err)
                                                    Haptics.error()
                                                }
                                            }
                                        }
                                    } : nil)
                                )
                                .contentShape(Rectangle())
                                .onTapGesture { selectedOrder = order }
                                .padding(.horizontal)
                            }
                            if list.isEmpty {
                                Text(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                     ? (showOpenOnly ? "אין הזמנות פתוחות" : "אין הזמנות")
                                     : "אין תוצאות לחיפוש")
                                    .foregroundColor(.secondary)
                                    .padding(.top, 40)
                            }
                        }
                        .padding(.vertical, 14)
                    }
                }
            }
            .navigationTitle("הזמנות")
            .toolbar {

                // Back
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: isRtl ? "chevron.right" : "chevron.left")
                            .font(.system(size: 18, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                }
                let isEod = (mode == .endOfDay)
                // Center pill
                ToolbarItem(placement: .principal) {
                    if !isEod{
                        Button {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                                showOpenOnly.toggle()
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: showOpenOnly ? "checkmark.circle.fill" : "circle")
                                Text("פתוחות")
                            }
                            .font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(Color(.systemGray6))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Search capsule
                ToolbarItem(placement: .navigationBarTrailing) {
                    ZStack(alignment: .trailing) {

                        // ✅ Custom placeholder (RTL-correct)
                        if searchText.isEmpty {
                            Text(isRtl ? "חיפוש…" : "Search…")
                                .foregroundColor(.secondary)
                                .padding(.trailing, 80)   // space for magnifier
                                .allowsHitTesting(false)
                        }

                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(.secondary)

                            // Real TextField has EMPTY placeholder
                            TextField("", text: $searchText)
                                .textInputAutocapitalization(.none)
                                .autocorrectionDisabled()
                                .multilineTextAlignment(.leading)   // ✅ RTL typing
                              

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
                    }
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .frame(width: 180)
                }
            }
            .navigationTitle("הזמנות")
            .navigationBarTitleDisplayMode(.inline)
            .task { await loadOrders(showSpinner: true) }
            .onReceive(pollTimer) { _ in
                Task { await loadOrders(showSpinner: false) }
            }
        }
        .fullScreenCover(item: $selectedOrder) { order in
            AdminOrderActionScreen(
                mode: mode,
                miniAppId: miniAppId,
                order: order,
                onClose: { selectedOrder = nil },
                onResolved: {
                    // ✅ instantly close + remove from list
                    let oid = order.id
                    selectedOrder = nil
                    orders.removeAll { $0.id == oid }

                    Task { await refreshOrders() }
                },
                onPrintBon: {
                    printOrder(order)
                    selectedOrder = nil
                },
                onPrintInvoice: {
                    printInvoice(for: order)
                    selectedOrder = nil
                },
                onContinue: order.isUnpaid
                    ? {
                        // 1) Close the details screen
                        selectedOrder = nil

                        // 2) Bring the order back to the main page & restore into basket
                        // Parent (CashPointView) already implements this via onSelectUnpaid.
                        onSelectUnpaid?(order)
                    }
                    : nil
            )
          
            .navigationTitle("הזמנות")
            .navigationBarTitleDisplayMode(.inline)
            .environment(\.layoutDirection, .rightToLeft)   // ✅ FORCE RTL HERE (highest level of the cover)
            .environment(\.locale, Locale(identifier: "he_IL"))
        }
     
        .navigationTitle("הזמנות")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func closeTeamTableOptimistic(orderId: Int) {
        guard !closingTeamTableIds.contains(orderId) else { return }

        Haptics.light()

        // ✅ optimistic: remove from list immediately
        closingTeamTableIds.insert(orderId)
        optimisticallyClosedIds.insert(orderId)

        // ✅ also update remaining immediately so "Next" can enable
        notifyRemainingChangedIfNeeded()

        TeamTabsAPI.close(orderId: orderId) { res in
            DispatchQueue.main.async {
                closingTeamTableIds.remove(orderId)

                switch res {
                case .success:
                    Haptics.success()

                    // ✅ OPTIONAL: also patch local orders array so if you switch filters it’s closed
                    if let idx = orders.firstIndex(where: { $0.id == orderId }) {
                        orders[idx].isUnpaid = false
                    }

                    // keep it hidden (already in optimisticallyClosedIds)
                    notifyRemainingChangedIfNeeded()

                case .failure(let err):
                    // ❌ revert
                    print("❌ closeTeamTable failed:", err)
                    Haptics.error()

                    optimisticallyClosedIds.remove(orderId)
                    notifyRemainingChangedIfNeeded()
                }
            }
        }
    }
    struct AdminOrderActionScreen: View {
        let mode: AdminOrdersView.AdminMode
        let miniAppId: Int
        let order: AdminOrderItem

        let onClose: () -> Void
        let onResolved: () -> Void
        let onPrintBon: () -> Void
        let onPrintInvoice: () -> Void
        let onContinue: (() -> Void)?

        @State private var metaLines: [OrderBasketLineDTO] = []
        @State private var isLoadingMeta = false

        // Local-only cancellation state (by row index to avoid duplicate ids breaking List)
        @State private var cancelledRowIndexes: Set<Int> = []

        private var isEOD: Bool { mode == .endOfDay }

        private var displayName: String {
            let s = order.customerName
                .replacingOccurrences(of: "Customer", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? "לקוח" : s
        }

        private func loadMeta() {
            isLoadingMeta = true
            TeamTabsAPI.fetchOrderMetadata(orderId: order.id) { res in
                DispatchQueue.main.async {
                    isLoadingMeta = false
                    switch res {
                    case .success(let meta):
                        metaLines = meta.basket ?? []
                    case .failure(let err):
                        print("❌ fetchOrderMetadata failed:", err.localizedDescription)
                        Haptics.error()
                    }
                }
            }
        }

        private var statusText: String { order.isUnpaid ? "פתוח" : "סגור" }
        private var amountLabel: String { order.isUnpaid ? "לתשלום" : "שולם" }

        private var effectiveTotal: Double {
            let activeSum = order.items.enumerated().reduce(0.0) { acc, pair in
                let (idx, line) = pair
                if cancelledRowIndexes.contains(idx) { return acc }
                return acc + (Double(max(1, line.quantity)) * line.unitPrice)
            }
            return activeSum > 0 ? activeSum : order.total
        }

        private var amountText: String { String(format: "₪%.0f", effectiveTotal) }

        private var timeString: String {
            let adjusted = Calendar.current.date(byAdding: .hour, value: 2, to: order.placedAt) ?? order.placedAt
            return DateTimeFormatter.cachedFormatter.string(from: adjusted)
        }

        var body: some View {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()

                List {

                    VStack(alignment: .trailing, spacing: 6) {

                        HStack(spacing: 8) {
                            Text(timeString)
                                .font(.system(size: 22, weight: .heavy))
                                .foregroundColor(.primary)

                            statusPill

                            Spacer()

                            Text(String(format: "₪%.0f", effectiveTotal))
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(.primary)
                        }

                        HStack {
                            Text(displayName)
                                .font(.system(size: 20, weight: .bold))
                                .foregroundColor(.primary)
                                .lineLimit(1)

                            Spacer()
                        }

                        HStack {
                            Text(order.orderId)
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                                .multilineTextAlignment(.trailing)
                            Spacer()
                        }
                    }

                    Section(header: Text("פריטים")) {
                        if order.items.isEmpty {
                            Text("אין פריטים להזמנה")
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 18)
                        } else {
                            ForEach(Array(order.items.enumerated()), id: \.offset) { idx, line in
                                orderLineRow(line, isCancelled: cancelledRowIndexes.contains(idx))
                                    .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                                    .swipeActions(edge: .leading, allowsFullSwipe: false) {

                                        Button {
                                            Haptics.light()
                                            toggleCancelIndex(idx)
                                        } label: {
                                            Text("OTH")
                                        }
                                        .tint(.gray)

                                        Button {
                                            Haptics.light()
                                            toggleCancelIndex(idx)
                                        } label: {
                                            Text(cancelledRowIndexes.contains(idx) ? "החזר" : "בטל")
                                        }
                                        .tint(cancelledRowIndexes.contains(idx) ? .gray : .red)
                                    }
                            }
                        }
                    }
                }
                .onAppear {
                    if mode == .endOfDay {
                        loadMeta()
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .safeAreaInset(edge: .top) { topBar }
                .safeAreaInset(edge: .bottom) {
                    bottomActions
                        .background(.ultraThinMaterial)
                }
            }
            .environment(\.layoutDirection, .rightToLeft)
            .environment(\.locale, Locale(identifier: "he_IL"))
        }

        // MARK: - Top bar
        private var topBar: some View {
            HStack {
                Text("פרטי הזמנה")
                    .font(.system(size: 17, weight: .bold))
                    .frame(maxWidth: .infinity, alignment: .center)

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .bold))
                        .padding(10)
                        .background(Color(.systemGray5))
                        .clipShape(Circle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 10)
            .background(.ultraThinMaterial)
        }

        private var statusPill: some View {
            Text(statusText)
                .font(.system(size: 13, weight: .bold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.18))
                .foregroundColor(.black)
                .clipShape(Capsule())
        }

        // MARK: - Row
        private func orderLineRow(_ line: AdminOrderLineItem, isCancelled: Bool) -> some View {
            let qty = max(1, line.quantity)
            let lineTotal = Double(qty) * line.unitPrice

            return VStack(alignment: .trailing, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("×\(qty)")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.secondary)
                        .opacity(isCancelled ? 0.45 : 1.0)

                    Text(line.name)
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(1)
                        .multilineTextAlignment(.trailing)
                        .strikethrough(isCancelled)
                        .opacity(isCancelled ? 0.45 : 1.0)

                    Spacer()

                    Text(String(format: "₪%.0f", lineTotal))
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.secondary)
                        .opacity(isCancelled ? 0.45 : 1.0)
                }

                if let mods = line.modifiersText,
                   !mods.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(mods)
                            .font(.system(size: 13))
                            .foregroundColor(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.trailing)
                            .opacity(isCancelled ? 0.45 : 1.0)
                            .padding(.horizontal, 30)
                        Spacer()
                    }
                }

                if isCancelled {
                    Text("מסומן כ״בוטל״ (מקומי)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.red.opacity(0.85))
                    Spacer()
                }
            }
        }

        private func toggleCancelIndex(_ idx: Int) {
            guard order.items.indices.contains(idx) else { return }

            let line = order.items[idx]
            let newValue = !cancelledRowIndexes.contains(idx)

            if newValue { cancelledRowIndexes.insert(idx) }
            else { cancelledRowIndexes.remove(idx) }

            if let basketId = line.basketLineId, basketId > 0 {
                sendCancelLineId(basketId, idx: idx, line: line, newValue: newValue)
                return
            }

            TeamTabsAPI.fetchOrderMetadata(orderId: order.id) { res in
                switch res {
                case .success(let meta):
                    let basket = meta.basket ?? []
                    print("🧾 meta basket lineIds:", basket.map(\.lineId))

                    let match = basket.first(where: { b in
                        if let pid = line.productId, pid > 0, b.productId == pid { return true }
                        return b.name == line.name
                    })

                    guard let match else {
                        print("❌ could not match item '\(line.name)' pid=\(line.productId ?? -1)")
                        DispatchQueue.main.async {
                            if newValue { cancelledRowIndexes.remove(idx) }
                            else { cancelledRowIndexes.insert(idx) }
                        }
                        return
                    }

                    sendCancelLineId(match.lineId, idx: idx, line: line, newValue: newValue)

                case .failure(let err):
                    print("❌ fetchOrderMetadata failed:", err.localizedDescription)
                    DispatchQueue.main.async {
                        if newValue { cancelledRowIndexes.remove(idx) }
                        else { cancelledRowIndexes.insert(idx) }
                    }
                }
            }
        }

        private func sendCancelLineId(_ lineId: Int, idx: Int, line: AdminOrderLineItem, newValue: Bool) {
            OrdersResolveAPI.setLineCancelled(
                miniAppId: miniAppId,
                orderId: order.id,
                lineId: lineId,
                isCancelled: newValue
            ) { result in
                switch result {
                case .success(let allCancelled):
                    if allCancelled {
                        DispatchQueue.main.async { onResolved() }
                    }
                case .failure(let err):
                    let ns = err as NSError
                    let body = ns.userInfo["body"] as? String ?? ""
                    if ns.code == 404 && body.contains("lineId not found in basket") {
                        print("♻️ server rejected lineId=\(lineId). Retrying via metadata…")

                        TeamTabsAPI.fetchOrderMetadata(orderId: order.id) { res in
                            switch res {
                            case .success(let meta):
                                let basket = meta.basket ?? []
                                print("🧾 meta basket lineIds:", basket.map(\.lineId))

                                let match = basket.first(where: { b in
                                    if let pid = line.productId, pid > 0, b.productId == pid { return true }
                                    return b.name == line.name
                                })

                                guard let match else {
                                    print("❌ retry: could not match item '\(line.name)' pid=\(line.productId ?? -1)")
                                    DispatchQueue.main.async {
                                        if newValue { cancelledRowIndexes.remove(idx) }
                                        else { cancelledRowIndexes.insert(idx) }
                                    }
                                    return
                                }

                                OrdersResolveAPI.setLineCancelled(
                                    miniAppId: miniAppId,
                                    orderId: order.id,
                                    lineId: match.lineId,
                                    isCancelled: newValue
                                ) { r2 in
                                    switch r2 {
                                    case .success(let allCancelled):
                                        if allCancelled { DispatchQueue.main.async { onResolved() } }
                                    case .failure(let e2):
                                        print("❌ retry cancel failed:", e2)
                                        DispatchQueue.main.async {
                                            if newValue { cancelledRowIndexes.remove(idx) }
                                            else { cancelledRowIndexes.insert(idx) }
                                        }
                                    }
                                }

                            case .failure(let e):
                                print("❌ retry fetch metadata failed:", e.localizedDescription)
                                DispatchQueue.main.async {
                                    if newValue { cancelledRowIndexes.remove(idx) }
                                    else { cancelledRowIndexes.insert(idx) }
                                }
                            }
                        }
                        return
                    }

                    print("❌ cancel line failed:", err)
                    DispatchQueue.main.async {
                        if newValue { cancelledRowIndexes.remove(idx) }
                        else { cancelledRowIndexes.insert(idx) }
                    }
                }
            }
        }

        // MARK: - Bottom actions
      
        @ViewBuilder
        private var bottomActions: some View {
            VStack(spacing: 10) {

                // ✅ EOD MODE — always show Continue
                if isEOD {
                    Button {
                        Haptics.light()
                        print("➡️ Continue tapped. onContinue is nil? \(onContinue == nil)")
                        onContinue?()
                    } label: {
                        Text("המשך הזמנה")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(Color.black)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(onContinue == nil)
                    .opacity(onContinue == nil ? 0.35 : 1.0)
                } else {

                    // ✅ NORMAL MODE — unchanged
                    if let onContinue {
                        Button(action: onContinue) {
                            Text("המשך הזמנה")
                                .font(.system(size: 17, weight: .bold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 52)
                                .background(Color.black)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }

                    HStack(spacing: 12) {
                        Button(action: onPrintBon) {
                            Text("בונבון")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                                .background(Color.black)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }

                        Button(action: onPrintInvoice) {
                            Text("חשבונית")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                                .background(Color.black)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 10)
        }
    }
    // MARK: - UI building blocks

    private var headerBar: some View {
        let openCount = orders.filter { $0.isUnpaid }.count
        let totalCount = orders.count

        return HStack(spacing: 10) {
            Button {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                    showOpenOnly.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: showOpenOnly ? "checkmark.circle.fill" : "circle")
                    Text("פתוחות בלבד")
                }
                .font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.systemGray6))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            Spacer()

            // Counts pill
            Text(showOpenOnly ? "פתוחות: \(openCount)" : "סה״כ: \(totalCount) · פתוחות: \(openCount)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)

            TextField("חיפוש בהזמנות…", text: $searchText)
                .textFieldStyle(.plain)
                .disableAutocorrection(true)
                .textInputAutocapitalization(.never)

            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.leading, 4)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(.systemGray6))
        .cornerRadius(12)
        .padding(.horizontal)
    }
 
    @MainActor
    private func publishRemaining() {
        let n = filteredOrders.count
        onRemainingChanged?(n)
        if n == 0 { onAllResolved?() }
    }
    // MARK: - Sorting & filtering

    private func sortRule(_ a: AdminOrderItem, _ b: AdminOrderItem) -> Bool {
        // open first, then newest
        
        return a.placedAt > b.placedAt
    }

    private var filteredOrders: [AdminOrderItem] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        var base = orders

        // ✅ EOD filters
        if mode == .endOfDay {
            // Always open-only in EOD
            base = base.filter { $0.isUnpaid }

            switch eodFilter {
            case .all:
                break
            case .teamTablesOnly:
                base = base.filter { isTeamTableName($0.customerName) }
            case .openOrdersOnly:
                base = base.filter { !isTeamTableName($0.customerName) }
            }
        } else {
            // normal mode behaviour
            base = base.filter { !isTeamTableName($0.customerName) }
            if showOpenOnly { base = base.filter { $0.isUnpaid } }
        }

        // Search
        if !trimmed.isEmpty {
            let q = trimmed.folding(options: .diacriticInsensitive, locale: .current).lowercased()
            base = base.filter { order in
                let haystack = [
                    order.customerName,
                    order.orderId,
                    order.subtitle,
                    order.source,
                    order.items.map { $0.name }.joined(separator: " ")
                ]
                .joined(separator: " ")
                .folding(options: .diacriticInsensitive, locale: .current)
                .lowercased()

                return haystack.contains(q)
            }
        }

        return base.sorted(by: sortRule)
    }

    // MARK: - Printing

    private func printInvoice(for order: AdminOrderItem) {
        let items = makeInvoiceItems(from: order)

        let customer = order.customerName
            .replacingOccurrences(of: "Customer", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // ✅ If unpaid, don’t print "Tax Invoice/Receipt"
        let pmRaw = (order.paymentMethod ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if order.isUnpaid || pmRaw == "unpaid" {
            Swift.print("⚠️ Order \(order.id) is unpaid — skipping Tax Invoice / Receipt")
            return
        }

        let paidAmount = order.total

        // ✅ Hebrew label (what prints on the receipt)
        let paymentMethodHeb: String = {
            switch pmRaw {
            case "cash", "mezuman":
                return "מזומן"
            case "card", "credit", "cc", "zcredit", "stripe", "square":
                return "אשראי"
            case "applepay":
                return "אפל פיי"
            case "googlepay":
                return "גוגל פיי"
            case "":
                // fallback if server didn’t send it
                return "אשראי"
            default:
                return pmRaw
            }
        }()

        PrinterManager.shared.printTaxInvoice(
            invoiceNumber: order.id,
            date: order.placedAt,
            customerName: customer.isEmpty ? "לקוח" : customer,
            items: items,
            vatRate: 0.18,
            paidAmount: paidAmount,
            paymentMethod: paymentMethodHeb,
            cardBrand: nil,
            cardLast4: nil,
            installments: nil
        )
    }
    private func makeInvoiceItems(from order: AdminOrderItem) -> [InvoiceItem] {
        let lines = order.items
        let sumKnownLines = lines.reduce(0.0) { acc, li in
            let q = Double(max(1, li.quantity))
            let u = li.unitPrice
            return acc + (u > 0 ? (u * q) : 0)
        }

        let missing = max(0, order.total - sumKnownLines)
        let missingQty = Double(lines.filter { $0.unitPrice <= 0 }.reduce(0) { $0 + max(1, $1.quantity) })
        let fallbackUnit = (missingQty > 0) ? (missing / missingQty) : 0

        return lines.map { li in
            let qInt = max(1, li.quantity)
            let fullName: String = {
                if let mods = li.modifiersText, !mods.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return "\(li.name)"
                }
                return li.name
            }()
            let unit = (li.unitPrice > 0) ? li.unitPrice : fallbackUnit
            return InvoiceItem(name: fullName, quantity: qInt, unitPrice: unit)
        }
    }

    private func printOrder(_ order: AdminOrderItem) {
        let entries = toBasketEntries(from: order)
        let mode = diningMode(for: order)
        let ticketNumber = Int(order.orderId) ?? order.id

        Task {
            let ok = await PrinterManager.shared.printCashPointSplit(
                orderNumber: ticketNumber,
                entries: entries,
                total: order.total,
                diningMode: mode,
                customerName: order.customerName,
                customerPhone: order.customerPhone
            )

            if !ok {
                print("❌ printCashPointSplit failed for order \(ticketNumber)")
            }
        }
    }

    private func update(order: AdminOrderItem, to newStatus: AdminOrderStatus) {
        guard let idx = orders.firstIndex(where: { $0.id == order.id }) else { return }
        orders[idx].status = newStatus
        if let so = selectedOrder, so.id == order.id { selectedOrder?.status = newStatus }

        let statusCode: Int
        switch newStatus {
        case .received:  statusCode = 1
        case .ready:     statusCode = 4
        case .collected: statusCode = 5
        }

        Task {
            let ok = await setStatus(orderId: order.id, to: statusCode, miniAppId: miniAppId)
            if !ok {
                print("❌ Failed to update status on server for order \(order.id) → \(statusCode)")
            }
        }
    }

    // MARK: - API Load

    @MainActor
    private func loadOrders(showSpinner: Bool) async {
        guard miniAppId > 0 else { return }

       

        if showSpinner { isLoading = true }
        defer { if showSpinner { isLoading = false } }

        guard let url = URL(string: "\(baseURL)?miniAppId=\(miniAppId)") else {
            print("❌ admin/orders: bad URL")
            return
        }

        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { return }

            guard http.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
                print("❌ admin/orders HTTP \(http.statusCode)\n\(body)")
                return
            }

            guard let freshOrders = decodeAdminOrders(from: data) else { return }
         
            self.orders = freshOrders
            await MainActor.run { publishRemaining() }
            
            let remaining = filteredOrders.count
            onRemainingChanged?(remaining)
            if remaining == 0 {
                onAllResolved?()
            }
        } catch {
            print("❌ admin/orders network error:", error.localizedDescription)
        }
    }
}

// MARK: - Row

struct AdminOrderRow: View {
    let item: AdminOrderItem
    let onPrint: () -> Void
    let onPrintInvoice: () -> Void
    let onOpenInCashPoint: (() -> Void)?
    let onCloseTeamTable: (() -> Void)?   // ✅ NEW

    private var displayName: String {
        let cleaned = item.customerName
            .replacingOccurrences(of: "Customer", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "אינשם" : cleaned
    }

    private var isTeamTable: Bool {
        let name = item.customerName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        return name.hasPrefix("שולחן") || name.hasPrefix("Team")
    }

    private var formattedItemsSummary: String {
        // If server already sends empty or weird subtitle, fallback
        guard !item.subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ""
        }

        // Split common separators
        let parts = item.subtitle
            .replacingOccurrences(of: "·", with: ",")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        let formatted = parts.compactMap { part -> String? in
            // Try to extract quantity patterns like "name ×2" or "name x2"
            if let range = part.range(of: #"(.+?)\s*[×x]\s*(\d+)"#, options: .regularExpression) {
                let text = String(part[range])
                let comps = text
                    .replacingOccurrences(of: "×", with: "x")
                    .split(separator: "x")

                if comps.count == 2,
                   let qty = Int(comps[1].trimmingCharacters(in: .whitespaces)) {
                    let name = comps[0].trimmingCharacters(in: .whitespaces)
                    return "\(qty) \(name)"
                }
            }

            // No quantity → assume 1
            return "1 \(part)"
        }

        return formatted.joined(separator: ", ")
    }
    private var timeString: String {
        let adjusted = Calendar.current.date(byAdding: .hour, value: 2, to: item.placedAt) ?? item.placedAt
        return DateTimeFormatter.cachedFormatter.string(from: adjusted)
    }

    private var openBadge: some View {
        HStack(spacing: 6) {
            Circle().fill(Color.black).frame(width: 7, height: 7)
            Text("פתוח")
                .font(.system(size: 12, weight: .bold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.12))
        .clipShape(Capsule())
    }

    private var closeTeamButton: some View {
        Button {
            Haptics.light()
            onCloseTeamTable?()
        } label: {
            Text("סגור שולחן")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 96, height: 34)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        VStack(spacing: 10) {

            // ───────── Header ─────────
            VStack(alignment: .leading, spacing: 6) {

                // ✅ Top line: TIME is most important (leading, big)
                HStack(spacing: 8) {
                    Text(timeString)
                        .font(.system(size: 22, weight: .heavy))
                        .foregroundColor(.primary)

                    if item.isUnpaid { openBadge }

                    Spacer()

                    Text(String(format: "₪%.0f", item.total))
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.primary)
                }

                // ✅ Name important
                Text(displayName)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                // ✅ Subtitle important (primary)
                if !item.subtitle.isEmpty {
                    Text(formattedItemsSummary)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(2)
                }

                // ✅ Secondary line: order id + source
                HStack(spacing: 8) {
                    Text("#\(item.orderId)")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.secondary)

                    Text(item.source)
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color(.systemGray6))
                        .clipShape(Capsule())

                    Spacer()
                }
            }

            // ───────── Actions (compact, trailing) ─────────
            HStack(spacing: 8) {
                Spacer()

                // ✅ If we're in EOD mode, we pass onOpenInCashPoint == nil.
                // Use that as a signal to hide ALL action buttons.
                let isEodRow = (onOpenInCashPoint == nil) && (onCloseTeamTable == nil)

                if isTeamTable, onCloseTeamTable != nil {
                    closeTeamButton
                } else if !isEodRow {

                    if let onOpenInCashPoint {
                        Button {
                            Haptics.light()
                            onOpenInCashPoint()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.right.circle.fill")
                                    .font(.system(size: 14, weight: .bold))
                                Text("המשך הזמנה")
                                    .font(.system(size: 14, weight: .semibold))
                            }
                            .foregroundColor(.white)
                            .frame(width: 120, height: 34)
                            .background(Color.black)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        Haptics.light()
                        onPrint()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "printer.fill")
                                .font(.system(size: 13, weight: .bold))
                            Text("בונבון")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .frame(width: 86, height: 34)
                        .background(Color.black)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    Button {
                        Haptics.light()
                        onPrintInvoice()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.text.fill")
                                .font(.system(size: 13, weight: .bold))
                            Text("חשבונית")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .frame(width: 98, height: 34)
                        .background(Color.black)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
    }
}

// MARK: - Detail Sheet



@MainActor
func setStatus(orderId: Int, to newStatus: Int, miniAppId: Int) async -> Bool {
    guard let url = URL(string: "https://minis.studio/api/admin/orders/\(orderId)/status") else {
        return false
    }

    var req = URLRequest(url: url, timeoutInterval: 12)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let body: [String: Any] = [
        "status": newStatus,     // 4 = ready, 5 = collected
        "miniAppId": miniAppId
    ]
    req.httpBody = try? JSONSerialization.data(withJSONObject: body)

    do {
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            print("❌ setStatus HTTP fail:",
                  (resp as? HTTPURLResponse)?.statusCode ?? -1,
                  String(data: data, encoding: .utf8) ?? "")
            return false
        }
        return true
    } catch {
        print("❌ setStatus network error:", error.localizedDescription)
        return false
    }
}

// MARK: - Date Formatter Cache

private enum DateTimeFormatter {
    static let cachedFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = .current
        f.locale = Locale(identifier: "he_IL")
        f.dateFormat = "HH:mm"
        return f
    }()
}

struct OrdersHostView: View {
    let mode: AdminOrdersView.AdminMode
    let onSelectUnpaid: ((AdminOrderItem) -> Void)?
    let onRefundFromBone: ((DigitalBonesView.Bone) -> Void)?

    @Environment(\.isRtl) private var isRtl

    var body: some View {
        GeometryReader { proxy in
            let isPad       = UIDevice.current.userInterfaceIdiom == .pad
            let isLandscape = proxy.size.width > proxy.size.height

            Group {
                AdminOrdersView(mode: mode, onSelectUnpaid: onSelectUnpaid)   // ✅ FIX
                    .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
            }
        }
    }
}


enum ZPrecheckAPI {
    struct Resp: Decodable {
        let ok: Bool
        let miniAppId: Int
        let openCount: Int
    }

    static func fetch(miniAppId: Int) async throws -> Resp {
        var comps = URLComponents(string: "https://minis.studio/api/z/precheck")!
        comps.queryItems = [.init(name: "miniAppId", value: String(miniAppId))]
        let url = comps.url!

        let (data, resp) = try await URLSession.shared.data(from: url)
        let http = resp as? HTTPURLResponse
        guard let http, (200...299).contains(http.statusCode) else {
            throw NSError(domain: "ZPrecheckAPI", code: http?.statusCode ?? -1)
        }

        return try JSONDecoder().decode(Resp.self, from: data)
    }
}
enum OrdersResolveAPI {
    struct CancelResp: Decodable {
        let ok: Bool?
        let allCancelled: Bool?
    }

    static func setLineCancelled(
        miniAppId: Int,
        orderId: Int,
        lineId: Int,
        isCancelled: Bool,
        completion: @escaping (Result<Bool, Error>) -> Void
    ) {
        guard let url = URL(string: "https://minis.studio/api/orders/\(orderId)/lines/\(lineId)/cancel") else {
            completion(.failure(NSError(domain: "OrdersResolveAPI", code: -1)))
            return
        }

        let payload: [String: Any] = [
            "miniAppId": miniAppId,
            "isCancelled": isCancelled
        ]

        let bodyData = (try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])) ?? Data()
        let bodyString = String(data: bodyData, encoding: .utf8) ?? "<non-utf8 body>"

        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = bodyData

        // ✅ DEBUG: request
        let start = Date()
        print("📡 cancel line REQUEST")
        print("   url:", url.absoluteString)
        print("   orderId:", orderId, "lineId:", lineId, "miniAppId:", miniAppId, "isCancelled:", isCancelled)
        print("   body:\n\(bodyString)")
        print("   curl:\n  curl -sS -i -X POST '\(url.absoluteString)' -H 'Content-Type: application/json' -d '\(bodyString.replacingOccurrences(of: "\n", with: " "))'")

        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err = err {
                print("❌ cancel line NETWORK error:", err.localizedDescription)
                completion(.failure(err))
                return
            }

            guard let http = resp as? HTTPURLResponse else {
                print("❌ cancel line: no HTTPURLResponse")
                completion(.failure(NSError(domain: "OrdersResolveAPI", code: -2)))
                return
            }

            let ms = Int(Date().timeIntervalSince(start) * 1000)
            let raw = data ?? Data()
            let text = String(data: raw, encoding: .utf8) ?? "<non-utf8 \(raw.count) bytes>"

            // ✅ DEBUG: response
            print("📥 cancel line RESPONSE (\(ms)ms)")
            print("   status:", http.statusCode)
            if let ct = http.value(forHTTPHeaderField: "Content-Type") { print("   content-type:", ct) }
            if let rid = http.value(forHTTPHeaderField: "x-request-id") { print("   x-request-id:", rid) }
            if let cf = http.value(forHTTPHeaderField: "cf-ray") { print("   cf-ray:", cf) }
            print("   body:\n\(text)")

            guard (200...299).contains(http.statusCode) else {
                completion(.failure(NSError(domain: "OrdersResolveAPI", code: http.statusCode, userInfo: ["body": text])))
                return
            }

            do {
                let decoded = try JSONDecoder().decode(CancelResp.self, from: raw)
                let ok = decoded.allCancelled ?? false
                print("✅ cancel line decoded allCancelled:", ok)
                completion(.success(ok))
            } catch {
                print("❌ cancel line decode failed:", error)
                completion(.failure(error))
            }
        }.resume()
    }
}

struct TipsExpected: Equatable {
    var cash: Double
    var card: Double
    var other: Double

    var total: Double { cash + card + other }
}

struct TipsDraft: Equatable {
    var cash: String = ""
    var card: String = ""
    var other: String = ""

    func parsed(_ s: String) -> Double {
        let t = s
            .replacingOccurrences(of: "₪", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(t) ?? 0
    }

    var cashValue: Double  { parsed(cash) }
    var cardValue: Double  { parsed(card) }
    var otherValue: Double { parsed(other) }

    var total: Double { cashValue + cardValue + otherValue }
}


private struct EODStepBusinessDayView<Next: View>: View {
    let miniAppId: Int
    @Binding var businessDate: Date
    let next: () -> Next

    var body: some View {
        VStack(spacing: 14) {

            VStack(alignment: .trailing, spacing: 10) {
                Text("תאריך עסקי")
                    .font(.system(size: 20, weight: .bold))

                Text("בחר תאריך עבור דוח סוף יום. ברירת מחדל היא היום, ניתן לשנות.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.secondary)

                HStack {
                    DatePicker(
                        "",
                        selection: $businessDate,
                        displayedComponents: .date
                    )
                    .datePickerStyle(.compact)
                    .labelsHidden()

                    Spacer()

                    Text(formatBusinessDate(businessDate))
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .monospacedDigit()
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(16)
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            Spacer()

            NavigationLink {
                next()
            } label: {
                Text("הבא")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .padding(.bottom, 14)
        }
        .padding(.horizontal, 16)
        .background(Color(UIColor.systemGroupedBackground))
        .navigationTitle("0/3 תאריך עסקי")
    }

    private func formatBusinessDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "he_IL")
        f.timeZone = TimeZone(identifier: "Asia/Jerusalem")
        f.dateFormat = "EEEE, dd/MM/yyyy"
        return f.string(from: d)
    }
}


struct EODWizardView: View {
    @Environment(\.dismiss) private var dismiss
    let miniAppId: Int
    let onContinueOrder: (AdminOrderItem) -> Void

    // ✅ NEW: selected business day for the wizard
    @State private var businessDate: Date = Date() // default “obvious”: today (Israel locale already applied)

    var body: some View {
        NavigationStack {
            EODStepBusinessDayView(
                miniAppId: miniAppId,
                businessDate: $businessDate
            ) {
                // continue to step 1
                EODStepOpenOrdersView(
                    miniAppId: miniAppId,
                    businessDate: businessDate,
                    onContinueOrder: onContinueOrder,
                    dismissWizard: { dismiss() }
                )
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .environment(\.layoutDirection, .rightToLeft)
        .environment(\.locale, Locale(identifier: "he_IL"))
    }
}

// MARK: - Shared "dismiss like iOS back" button

private struct WizardDismissBackButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.backward")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.primary)
                .padding(10)
                .background(Color(.systemBackground).opacity(0.95))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

private extension View {
    func wizardBackDismiss(_ dismissWizard: @escaping () -> Void) -> some View {
        self
            .navigationBarBackButtonHidden(true) // ✅ hide system pop-back
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    WizardDismissBackButton(action: dismissWizard)
                }
            }
    }
}

// MARK: - STEP 1/3: Open Orders

private struct EODStepOpenOrdersView: View {
    let miniAppId: Int
    let businessDate: Date                 // ✅ NEW
    let onContinueOrder: (AdminOrderItem) -> Void
    let dismissWizard: () -> Void

    @State private var remainingOpenOrders: Int = 0

    var body: some View {
        VStack(spacing: 14) {

            HStack(spacing: 8) {
                pill("פתוחות", ok: remainingOpenOrders == 0, value: remainingOpenOrders)
                pill("מזומן/טיפ", ok: false, value: nil)
            }
            .padding(.top, 10)

            AdminOrdersView(
                mode: .endOfDay,
                eodFilter: .openOrdersOnly,
                onSelectUnpaid: { order in
                    onContinueOrder(order)
                    dismissWizard()
                },
                onRemainingChanged: { remainingOpenOrders = $0 },
                onAllResolved: { remainingOpenOrders = 0 }
            )
            .environment(\.layoutDirection, .rightToLeft)

            NavigationLink {
                EODStepTipsView(
                    miniAppId: miniAppId,
                    dismissWizard: dismissWizard, businessDate: businessDate
                )
            } label: {
                Text("הבא")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(remainingOpenOrders == 0 ? Color.black : Color.gray.opacity(0.35))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .disabled(remainingOpenOrders != 0)
            .padding(.bottom, 14)
        }
        .padding(.horizontal, 16)
        .background(Color(UIColor.systemGroupedBackground))
        .navigationTitle("1/3 הזמנות פתוחות")
    }

    private func pill(_ title: String, ok: Bool, value: Int?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle")
            Text(value == nil ? title : "\(title): \(value!)")
        }
        .font(.system(size: 13, weight: .semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(.systemGray6))
        .clipShape(Capsule())
    }
}


// MARK: - STEP 2/3: Tips

private struct EODStepTipsView: View {
    let miniAppId: Int
    let dismissWizard: () -> Void
    let businessDate: Date
    @State private var cashSystemInclTip: Double? = nil
    @State private var cashCountedText: String = ""
    @State private var cashAdjText: String = ""
    @State private var tipsAdjText: String = ""

    @State private var tipsLoading = false
    @State private var tipsError: String? = nil
    @State private var showAfterCounted: Bool = false

    @State private var didSubmitAdjustment = false
    @State private var isSubmitting = false
    @State private var goPreview = false

    var body: some View {
        VStack(spacing: 14) {

            HStack(spacing: 8) {
                pill("פתוחות", ok: true, value: nil)
                pill("מזומן/טיפ", ok: canProceedFromTips, value: nil)
            }
            .padding(.top, 10)

            tipsScreen
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            NavigationLink(isActive: $goPreview) {
                EODStepPreviewView(
                    miniAppId: miniAppId,
                    businessDate: businessDate,
                    dismissWizard: dismissWizard,
                    cashSystemInclTip: cashSystemInclTip ?? 0,
                    countedCash: countedCash,
                    cashUpdate: cashUpdate,
                    tipsUpdate: tipsUpdate,
                    gap: gap,
                    gapIsZero: gapIsZero,
                    updateMatchesGap: updateMatchesGap
                )
            } label: { EmptyView() }
            .hidden()

            Button {
                guard canProceedFromTips else { return }
                guard !isSubmitting else { return }
                isSubmitting = true

                Task {
                    await submitEodAdjustmentOrderIfNeeded()
                    await MainActor.run {
                        isSubmitting = false
                        goPreview = true
                    }
                }
            } label: {
                Text(isSubmitting ? "שולח…" : "הבא")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(canProceedFromTips && !isSubmitting ? Color.black : Color.gray.opacity(0.35))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .disabled(!canProceedFromTips || isSubmitting)
            .padding(.bottom, 14)
        }
        .padding(.horizontal, 16)
        .background(Color(UIColor.systemGroupedBackground))
        .navigationTitle("2/3 מזומן + טיפים")
        .task { await loadCashExpectedIfNeeded() }
        .wizardBackDismiss(dismissWizard)
    }

    private func parseNumber(_ s: String) -> Double {
        let t = s
            .replacingOccurrences(of: "₪", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(t) ?? 0
    }

    private var countedCash: Double { parseNumber(cashCountedText) }
    private var cashUpdate: Double  { parseNumber(cashAdjText) }
    private var tipsUpdate: Double  { parseNumber(tipsAdjText) }

    private func r0(_ v: Double) -> Double { v.rounded(.toNearestOrAwayFromZero) }

    private var gap: Double {
        guard let sys = cashSystemInclTip else { return 0 }
        return r0(countedCash) - r0(sys)
    }

    private var totalUpdate: Double { cashUpdate + tipsUpdate }

    private var gapIsZero: Bool { abs(gap) < 0.01 }
    private var updateMatchesGap: Bool { abs(r0(totalUpdate) - gap) < 0.01 }

    private var hasEnteredCountedCash: Bool {
        !cashCountedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canProceedFromTips: Bool {
        guard cashSystemInclTip != nil else { return false }
        guard hasEnteredCountedCash else { return false }

        // ✅ If counted is LOWER than system, allow continuing even if not "balanced"
        if gap < -0.01 { return true }

        // Otherwise keep strict logic (gap zero or updates match)
        return gapIsZero || updateMatchesGap
    }

    private var tipsScreen: some View {
        VStack(spacing: 12) {

            VStack(alignment: .trailing, spacing: 8) {
                HStack {
                    Text("מזומן + טיפים")
                        .font(.system(size: 20, weight: .bold))
                    Spacer()

                    Button {
                        cashCountedText = ""
                        cashAdjText = ""
                        tipsAdjText = ""
                        tipsError = nil
                        didSubmitAdjustment = false
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                            showAfterCounted = false
                        }
                        Haptics.light()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.counterclockwise")
                            Text("איפוס")
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color(.systemGray6))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    Button {
                        Task { await reloadCashExpectedFromXReport() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.clockwise")
                            Text("רענן מערכת")
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color(.systemGray6))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }

                Text("הכנס מזומן נספר במגירה — ואז יוצג פער ועדכון פער.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(16)
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            if tipsLoading {
                Spacer()
                ProgressView()
                Spacer()
            } else {
                VStack(spacing: 12) {
                    if let err = tipsError {
                        Text(err)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }

                    VStack(spacing: 10) {
                        HStack(spacing: 12) {
                            Text("מזומן מערכת (כולל טיפ)")
                                .font(.system(size: 15, weight: .semibold))
                                .frame(maxWidth: .infinity, alignment: .trailing)

                            Text(formatILS(cashSystemInclTip ?? 0))
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .frame(width: 140, alignment: .trailing)
                        }

                        HStack(spacing: 12) {
                            Text("נספר במגירה")
                                .font(.system(size: 15, weight: .semibold))
                                .frame(maxWidth: .infinity, alignment: .trailing)

                            TextField("0", text: $cashCountedText)
                                .keyboardType(.numbersAndPunctuation)
                                .multilineTextAlignment(.trailing)
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .padding(.horizontal, 10)
                                .padding(.vertical, 10)
                                .frame(width: 140, alignment: .trailing)
                                .background(Color(.systemGray6))
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .onChange(of: cashCountedText) { _ in
                                    let shouldShow = hasEnteredCountedCash
                                    if shouldShow != showAfterCounted {
                                        withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                                            showAfterCounted = shouldShow
                                        }
                                    }
                                }
                        }

                        if showAfterCounted {
                            Divider().padding(.vertical, 2)
                            HStack {
                                Spacer()
                                Text("פער: \(formatILS(gap))")
                                    .font(.system(size: 16, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundColor(gapIsZero ? .secondary : .primary)
                            }
                        }
                    }
                    .padding(16)
                    .background(Color(UIColor.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                    if showAfterCounted {
                        VStack(spacing: 10) {
                            HStack {
                                Text("עדכון פער")
                                    .font(.system(size: 16, weight: .bold))
                                Spacer()
                                Text(gap < -0.01 ? "אפשר להמשיך גם אם חסר מזומן" : "חייב להשתוות לפער")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.secondary)
                            }

                            allocationRow(title: "עדכון מזומן", text: $cashAdjText)
                            allocationRow(title: "עדכון טיפים", text: $tipsAdjText)

                            Divider().padding(.vertical, 2)

                            HStack {
                                Text("סה״כ עדכון")
                                    .font(.system(size: 15, weight: .bold))
                                Spacer()
                                Text(formatILS(totalUpdate))
                                    .font(.system(size: 16, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundColor((gapIsZero || updateMatchesGap) ? .secondary : .red)
                            }

                            if !gapIsZero && !updateMatchesGap {
                                HStack {
                                    Spacer()
                                    Text(gap < -0.01 ? "אפשר להמשיך גם אם חסר מזומן" : "חייב להשתוות לפער")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(.red)
                                }
                            }
                        }
                        .padding(16)
                        .background(Color(UIColor.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                }
            }

            Spacer()
        }
    }

    private func allocationRow(title: String, text: Binding<String>) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .trailing)

            TextField("0", text: text)
                .keyboardType(.numbersAndPunctuation)
                .multilineTextAlignment(.trailing)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .monospacedDigit()
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
                .frame(width: 140, alignment: .trailing)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func pill(_ title: String, ok: Bool, value: Int?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle")
            Text(value == nil ? title : "\(title): \(value!)")
        }
        .font(.system(size: 13, weight: .semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(.systemGray6))
        .clipShape(Capsule())
    }

    private func formatILS(_ v: Double) -> String { String(format: "₪%.0f", v) }

    private func loadCashExpectedIfNeeded() async {
        guard cashSystemInclTip == nil, !tipsLoading else { return }
        await reloadCashExpectedFromXReport()
    }

    private func reloadCashExpectedFromXReport() async {
        tipsLoading = true
        tipsError = nil
        defer { tipsLoading = false }

        do {
            let x = try await XReportAPI.fetch(miniAppId: miniAppId)
            cashSystemInclTip = (x.agg.cashTotal) + (x.agg.tipsTotal)
        } catch {
            let ns = error as NSError
            let body = ns.userInfo["body"] as? String ?? ""
            tipsError = body.isEmpty ? "שגיאה בטעינת X" : "שגיאה בטעינת X: \(body)"
            cashSystemInclTip = nil
        }
    }

    private func submitEodAdjustmentOrderIfNeeded() async {
        print("🧾 EOD submit CALLED didSubmit=\(didSubmitAdjustment)")
        guard !didSubmitAdjustment else {
            print("🧾 EOD submit skipped (already submitted)")
            return
        }

        // only submit if there is actually something to submit
        let shouldSubmit = (!gapIsZero) || abs(totalUpdate) > 0.01
        guard shouldSubmit else {
            didSubmitAdjustment = true
            print("🧾 EOD submit skipped (nothing to submit) -> didSubmit=true")
            return
        }

        didSubmitAdjustment = true

        // --- tiny cash hack (same as you had) ---
        let cashUpdateRaw = cashUpdate
        let tipsUpdateRaw = tipsUpdate
        let needsTinyCashHack = (cashUpdateRaw <= 0.01 && tipsUpdateRaw > 0.01)
        let cashUpdateForDb = needsTinyCashHack ? 0.2 : cashUpdateRaw
        let totalUpdateForDb = cashUpdateForDb + tipsUpdateRaw

        // Build the single "עדכון" entry
        let item = ShellMenuItem(
            id: -900_001,
            name: "עדכון",
            price: cashUpdateForDb,
            category: "EOD",
            modifiers: nil,
            imageURL: nil,
            description: nil,
            status: 1,
            stockQuantity: nil,
            printer: nil
        )

        let entries: [BasketEntry] = [
            BasketEntry(
                id: 1,
                item: item,
                quantity: 1,
                subtitle: nil,
                unitPrice: cashUpdateForDb
            )
        ]

        // Totals payload (match your backend keys)
        let totals: [String: Any] = [
            "subtotal": cashUpdateForDb,
            "discount": 0,
            "excluded": 0,
            "tip": tipsUpdateRaw,
            "total": cashUpdateForDb,               // keep aligned with your existing server logic
            "grandTotal": totalUpdateForDb,
            "currency": "ILS",
            "eodTinyCashHack": needsTinyCashHack
        ]

        print("""
        🧾 EOD SUBMIT begin
          cashUpdateRaw=\(cashUpdateRaw)
          tipsUpdateRaw=\(tipsUpdateRaw)
          cashUpdateForDb=\(cashUpdateForDb)
          totalUpdateForDb=\(totalUpdateForDb)
          gap=\(gap) gapIsZero=\(gapIsZero) matches=\(updateMatchesGap)
        """)

        // Optional: print a cURL for submitOrder (if you keep that helper around)
        // printSubmitOrderCurl(miniAppId: miniAppId, customerName: "עדכון סוף יום",
        //                      entries: entries, totals: totals,
        //                      paymentMethod: "cash", cashAmount: cashUpdateForDb, cardAmount: 0)

        await withCheckedContinuation { cont in
            let payment = OrderAPI.PaymentSummary(
                method: .cash,
                cashAmount: cashUpdateForDb,
                cardAmount: 0
            )

            OrderAPI.submitOrder(
                entries: entries,
                total: cashUpdateForDb,              // ✅ critical: server stores this as order.total
                diningMode: .dineIn,
                source: "cashpoint",
                customerName: "עדכון סוף יום",
                customerPhone: nil,
                payment: payment,
                zcreditMeta: nil,
                ticketNumber: nil,
                totals: totals
            ) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let oid):
                        print("✅ EOD update saved. orderId=\(oid) tinyHack=\(needsTinyCashHack)")
                        Haptics.success()
                    case .failure(let err):
                        print("❌ EOD update submit failed:", err)
                        Haptics.error()
                        didSubmitAdjustment = false // allow retry
                    }
                    cont.resume()
                }
            }
        }
    }
}

// MARK: - STEP 3/3: Preview

private struct EODStepPreviewView: View {
    let miniAppId: Int
    let businessDate: Date
    let dismissWizard: () -> Void

    let cashSystemInclTip: Double
    let countedCash: Double
    let cashUpdate: Double
    let tipsUpdate: Double
    let gap: Double
    let gapIsZero: Bool
    let updateMatchesGap: Bool

    private enum ZState { case idle, generating, readyToPrint }
    @State private var zState: ZState = .idle
    @State private var zResp: ZReportGenerateAPI.Resp? = nil
    @State private var zError: String? = nil

    @State private var xSnapshot: XReportApiResponse? = nil
    @State private var xSnapshotError: String? = nil
    @State private var isLoadingSnapshot = false
    private func formatBusinessDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "he_IL")
        f.timeZone = TimeZone(identifier: "Asia/Jerusalem")
        f.dateFormat = "dd/MM/yyyy"
        return f.string(from: d)
    }
    
    var body: some View {
        VStack(spacing: 12) {

            VStack(alignment: .trailing, spacing: 10) {
                Text("סיכום סוף יום")
                    .font(.system(size: 20, weight: .bold))
                Text("תאריך עסקי: \(formatBusinessDate(businessDate))")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.secondary)

                line("מזומן מערכת (כולל טיפ)", v: formatILS(cashSystemInclTip))
                line("נספר במגירה", v: formatILS(countedCash))
                line("פער", v: formatILS(gap), bad: !gapIsZero && !updateMatchesGap)
                line("עדכון מזומן", v: formatILS(cashUpdate))
                line("עדכון טיפים", v: formatILS(tipsUpdate))
                line("סה״כ עדכון", v: formatILS(cashUpdate + tipsUpdate), bad: !gapIsZero && !updateMatchesGap)

                if isLoadingSnapshot {
                    Text("טוען X…")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                } else if let x = xSnapshot {
                    Text("X snapshot: gross \(formatILS(x.agg.grossTotal)) | cash \(formatILS(x.agg.cashTotal)) | card \(formatILS(x.agg.cardTotal))")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                } else if let xSnapshotError {
                    Text("X snapshot error: \(xSnapshotError)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.red)
                }
            }
            .padding(16)
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            if let zError, !zError.isEmpty {
                Text(zError)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 6)
            } else if let r = zResp, r.ok {
                let idText = r.zReportId.map { "#\($0)" } ?? ""
                Text("✅ דו״ח הופק \(idText)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 6)
            }

            Spacer()

            if zState == .readyToPrint {
                HStack(spacing: 12) {
                    Button { printZFromSnapshot() } label: {
                        Text("הדפס")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                            .background(Color.black)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }

                    Button { dismissWizard() } label: {
                        Text("סגור")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.primary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                            .background(Color(.systemGray5))
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                }
            } else {
                Button {
                    handleZPrimary()
                } label: {
                    Text(zPrimaryTitle)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(Color.black)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .opacity(zState == .generating ? 0.5 : 1.0)
                }
                .disabled(zState == .generating)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .background(Color(UIColor.systemGroupedBackground))
        .navigationTitle("3/3 סיכום")
        .navigationBarTitleDisplayMode(.inline)
        .wizardBackDismiss(dismissWizard)
        .task { await ensureXSnapshot() }
    }

    private func ensureXSnapshot() async {
        guard xSnapshot == nil else { return }
        isLoadingSnapshot = true
        xSnapshotError = nil
        defer { isLoadingSnapshot = false }

        do {
            let x = try await XReportAPI.fetch(miniAppId: miniAppId)
            await MainActor.run {
                xSnapshot = x
                xSnapshotError = nil
            }
        } catch {
            let ns = error as NSError
            let body = ns.userInfo["body"] as? String ?? ""
            await MainActor.run {
                xSnapshotError = body.isEmpty ? error.localizedDescription : body
            }
        }
    }

    private func printZFromSnapshot() {
        guard let x = xSnapshot else {
            Haptics.error()
            return
        }
        let d = salesDataFromSnapshot(x)
        PrinterManager.shared.printSalesReport(d, type: .z, reportDate: Date(), isRestore: false, generatedAt: Date())
        Haptics.success()
    }

    private func salesDataFromSnapshot(_ x: XReportApiResponse) -> PrinterManager.SalesReportData {
        let a = x.agg
        return PrinterManager.SalesReportData(
            ppaRestaurant: 0,
            dinersRestaurant: a.restaurantCount,
            totalRestaurantIncVat: a.restaurantGross,
            ppaRestaurantValue: 0,

            ppaTA: 0,
            dinersTA: a.taCount,
            totalTAIncVat: a.taGross,

            totalSalesIncVat: a.grossTotal,
            tipsTotal: a.tipsTotal,
            grandTotal: a.netTotal,

            cashAmount: a.cashTotal,
            cashCount: a.cashCount,
            cardAmount: a.cardTotal,
            cardCount: a.cardCount,
            collectionsTotalAmount: a.paymentsTotal,
            collectionsTotalCount: a.ordersCount,

            closedDrawersAmount: 0,
            openDrawersAmount: 0,
            depositWithdrawAmount: 0,
            drawerTotalAmount: 0,
            mainDrawerAmount: 0,
            hostStationDrawerAmount: 0,

            tipBaseTotal: a.tipsTotal,
            tipRestaurant: 0,
            tipBarTakeaway: 0,
            extraTipTotal: 0,
            extraTipRestaurant: 0,
            extraTipBar: 0,

            ordersOTHAmount: a.ordersOTHAmount,
            ordersOTHCount: a.ordersOTHCount,
            itemsOTHAmount: 0,
            itemsOTHCount: 0,
            canceledItemsAmount: 0,
            canceledItemsCount: 0,
            refundedItemsAmount: 0,
            refundedItemsCount: 0,
            discountsAmount: a.discountsTotal,
            discountsCount: a.discountsCount,
            discountsRefundAmount: 0,
            discountsRefundCount: 0
        )
    }

    private func line(_ t: String, v: String, bad: Bool = false) -> some View {
        HStack {
            Text(v).font(.system(size: 15, weight: .semibold)).foregroundColor(bad ? .red : .primary).monospacedDigit()
            Spacer()
            Text(t).font(.system(size: 15, weight: .semibold)).foregroundColor(.secondary)
        }
    }

    private func formatILS(_ v: Double) -> String { String(format: "₪%.0f", v) }

    private var zPrimaryTitle: String {
        switch zState {
        case .idle: return "הפק דוח"
        case .generating: return "מפיק…"
        case .readyToPrint: return "הדפס"
        }
    }

    private func handleZPrimary() {
        guard zState == .idle else { return }

        zState = .generating
        Task { await generateZNow() }
    }

    @MainActor
    private func generateZNow() async {
        zError = nil
        zResp = nil
        Haptics.light()

        do {
            let resp = try await ZReportGenerateAPI.generate(
                miniAppId: miniAppId,
                businessDate: businessDate,          // ✅ NEW
                to: "eilamomer@gmail.com"
            )

            zResp = resp
            if resp.ok {
                zState = .readyToPrint
                Haptics.success()
            } else {
                zError = "הפקת הדוח נכשלה"
                zState = .idle
                Haptics.error()
            }
        } catch {
            let ns = error as NSError
            let body = ns.userInfo["body"] as? String ?? ""
            zError = body.isEmpty ? "שגיאה בהפקת דו״ח Z" : body
            zState = .idle
            Haptics.error()
        }
    }
}
// MARK: - Z Report API (debug curl + response)

enum ZReportGenerateAPI {

    struct Resp: Decodable {
        let ok: Bool
        let miniAppId: Int?
        let zReportId: Int?
        let rangeFromUtc: String?
        let rangeToUtc: String?
        let vatRate: Double?
        let businessDate: String?     // ✅ NEW (server returns yyyy-MM-dd)
        let emailedTo: String?
        let subject: String?
    }

    static func generate(miniAppId: Int, businessDate: Date, to: String?) async throws -> Resp {
        var comps = URLComponents(string: "https://minis.studio/api/reports/z")!

        let day = isoBusinessDay(businessDate) // yyyy-MM-dd in Israel TZ

        comps.queryItems = [
            .init(name: "miniAppId", value: String(miniAppId)),
            .init(name: "businessDate", value: day)          // ✅ NEW
        ]

        if let to, !to.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            comps.queryItems?.append(.init(name: "to", value: to.trimmingCharacters(in: .whitespacesAndNewlines)))
        }

        let url = comps.url!

        var req = URLRequest(url: url, timeoutInterval: 90)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = Data()

        print("🧾 Z REPORT cURL:")
        print(#"curl -sS -i -X POST "\#(url.absoluteString)" -H "Accept: application/json" -d "" "#)

        let start = Date()
        let (data, resp) = try await URLSession.shared.data(for: req)
        let ms = Int(Date().timeIntervalSince(start) * 1000)

        guard let http = resp as? HTTPURLResponse else {
            let text = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
            print("❌ Z REPORT no HTTPResponse (\(ms)ms)\n\(text)")
            throw NSError(domain: "ZReportGenerateAPI", code: -2, userInfo: ["body": text])
        }

        let text = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
        print("📥 Z REPORT HTTP \(http.statusCode) (\(ms)ms)")
        print("📦 Z REPORT body:\n\(text)")

        guard (200...299).contains(http.statusCode) else {
            throw NSError(domain: "ZReportGenerateAPI", code: http.statusCode, userInfo: ["body": text])
        }

        return try JSONDecoder().decode(Resp.self, from: data)
    }

    private static func isoBusinessDay(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Jerusalem")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
}

// MARK: - XReport fetch (adjust the endpoint/DTO to match your backend)

enum XReportAPI {

    static func fetch(miniAppId: Int) async throws -> XReportApiResponse {

        let url = URL(string: "https://minis.studio/api/xreport?miniAppId=\(miniAppId)")!

        // ✅ print curl
        print(#"🧾 XREPORT cURL:"#)
        print(#"curl -sS -i -X GET "\#(url.absoluteString)" -H "Accept: application/json""#)

        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let start = Date()
        let (raw, resp) = try await URLSession.shared.data(for: req)
        let ms = Int(Date().timeIntervalSince(start) * 1000)

        guard let http = resp as? HTTPURLResponse else {
            let body = String(data: raw, encoding: .utf8) ?? "<non-utf8 \(raw.count) bytes>"
            print("❌ XREPORT no HTTPResponse (\(ms)ms)\n\(body)")
            throw NSError(domain: "XReportAPI", code: -2, userInfo: ["body": body])
        }

        let body = String(data: raw, encoding: .utf8) ?? "<non-utf8 \(raw.count) bytes>"
        print("📥 XREPORT HTTP \(http.statusCode) (\(ms)ms)")
        if !(200...299).contains(http.statusCode) {
            print("📦 XREPORT body:\n\(body)")
            throw NSError(domain: "XReportAPI", code: http.statusCode, userInfo: ["body": body])
        }

        do {
            return try JSONDecoder().decode(XReportApiResponse.self, from: raw)
        } catch {
            print("❌ XREPORT decode failed:", error)
            print("📦 XREPORT raw:\n\(body)")
            throw error
        }
    }
}

// MARK: - TipsAPI (stub: system cash already includes tip)

enum TipsAPI {
    struct Expected: Equatable {
        var cashInclTip: Double
    }

    static func fetchExpected(miniAppId: Int) async throws -> Expected {
        // ✅ replace with your real endpoint later
        try await Task.sleep(nanoseconds: 180_000_000)
        return .init(cashInclTip: 340) // demo
    }
    
}


enum EODFilter {
    case all
    case teamTablesOnly
    case openOrdersOnly
}


