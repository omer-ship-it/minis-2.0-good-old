import SwiftUI

// MARK: - Station enums (TOP LEVEL)

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

struct AdminOrderLineItem: Identifiable, Hashable {
    let id: Int
    let productId: Int?
    var name: String
    var quantity: Int
    var unitPrice: Double
    var category: String?
    var modifiersText: String?
    var rowTotal: Double {
        Double(quantity) * unitPrice
    }
    var updatedAt: Date?
}

struct AdminOrderItem: Identifiable, Hashable {
    let id: Int
    var orderId: String          // string order id
    var customerName: String
    var subtitle: String
    var source: String           // קופה / קיוסק / מיני …
    var status: AdminOrderStatus
    var placedAt: Date
    var items: [AdminOrderLineItem]
    var total: Double            // order total
    var stations: Set<AdminStation>   // 👈 which stations this order touches
    var isUnpaid: Bool                // 👈 NEW
}

// MARK: - API DTOs

private struct AdminOrdersApiResponse: Decodable {
    let ok: Bool
    let count: Int
    let orders: [OrderDTO]
}

private struct LineDTO: Decodable {
    let itemId: Int?
    let productId: Int?
    var name: String
    var qty: Int
    var category: String?
    var status: Int
    var station: String?
    var modifiers: String?

    var updatedAt: Date?   // 👈 new
}

private struct OrderDTO: Decodable {
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
    let lines: [LineDTO]
    let status: Int?
    let paymentMethod: String?    // 👈 NEW

    enum CodingKeys: String, CodingKey {
        case id, source, bucket, stage, placedAt, scheduledFor,
             customerName, customerDisplayName, totalGBP, itemSummary,
             isDelivery, shortCode, lines, status, paymentMethod
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
        lines        = try c.decode([LineDTO].self, forKey: .lines)
        paymentMethod = try? c.decodeIfPresent(String.self, forKey: .paymentMethod)

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



struct AdminOrdersView: View {
    @AppStorage("AdminOrders.stationMode")
    private var stationModeRaw: String = StationViewMode.bar.rawValue
    let onSelectUnpaid: ((AdminOrderItem) -> Void)?
    init(onSelectUnpaid: ((AdminOrderItem) -> Void)? = nil) {
           self.onSelectUnpaid = onSelectUnpaid
       }
    enum Tab: String, CaseIterable {
        case active
        case history

        var title: String {
            switch self {
            case .active:  return "פעיל"
            case .history: return "סגור"
            }
        }
    }
    
    private func toBasketEntries(from order: AdminOrderItem) -> [BasketEntry] {
        order.items.map { li in
            BasketEntry(
                id: li.id,
                item: makeShellMenuItem(from: li),
                quantity: li.quantity,
                subtitle: nil,
                unitPrice: li.unitPrice
            )
        }
    }
    
    // MARK: - Minimal POS-compatible structs for printing

  
    
    private func diningMode(for order: AdminOrderItem) -> DiningMode {
        if order.subtitle.contains("לקחת") { return .takeAway }
        return .dineIn
    }

    @State private var allowAutoPrint = true

    private let baseURL = "https://minis.studio/api/admin/orders"
    private let miniAppId = 12

    @Environment(\.dismiss) private var dismiss
    @Environment(\.isRtl)   private var isRtl
    @State private var printedOrderIds: Set<Int> = []
    @State private var selectedTab: Tab = .active
    @State private var orders: [AdminOrderItem] = []
    @State private var selectedOrder: AdminOrderItem? = nil
    @State private var isLoading = false
    @State private var stationMode: StationViewMode = .bar   // 👈 this was missing

    private func stationButton(title: String, mode: StationViewMode) -> some View {
        Button {
            stationMode = mode
        } label: {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(stationMode == mode ? .white : .primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    stationMode == mode
                    ? Color.black
                    : Color.clear
                )
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
    // 🔁 Poll every 10 seconds
    @State private var pollTimer = Timer
        .publish(every: 10, on: .main, in: .common)
        .autoconnect()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {

                // Tabs
                Picker("", selection: $selectedTab) {
                    ForEach(Tab.allCases, id: \.self) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
                .padding(.horizontal)
                .padding(.top, 8)

                Divider().padding(.top, 8)

                if isLoading && orders.isEmpty {
                    Spacer()
                    ProgressView()
                    Spacer()
                } else {
                    ScrollView {
                        let list   = currentOrders

                        if selectedTab == .active {
                            // 🔹 ACTIVE TAB: split into unpaid / paid
                            let unpaid = list.filter { $0.isUnpaid }
                            let paid   = list.filter { !$0.isUnpaid }

                            LazyVStack(spacing: 16) {
                                // 1️⃣ Not paid yet
                                if !unpaid.isEmpty {
                                    HStack {
                                        Text("פתוח")
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundColor(.secondary)
                                        Spacer()
                                    }
                                    .padding(.horizontal)

                                    ForEach(unpaid) { order in
                                        AdminOrderRow(
                                            item: order,
                                            onAdvance: { newStatus in
                                                update(order: order, to: newStatus)
                                            }
                                        )
                                        .padding(.horizontal)
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                                // If in Active tab and this is unpaid → bounce to CashPoint
                                                if selectedTab == .active, order.isUnpaid, let cb = onSelectUnpaid {
                                                    cb(order)
                                                } else {
                                                    selectedOrder = order
                                                }
                                            }
                                    }

                                    Divider()
                                        .padding(.horizontal)
                                }

                                // 2️⃣ Paid (but still active, e.g. ready/awaiting collection)
                                if !paid.isEmpty {
                                    HStack {
                                        Text("סגור")
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundColor(.secondary)
                                        Spacer()
                                    }
                                    .padding(.horizontal)

                                    ForEach(paid) { order in
                                        AdminOrderRow(
                                            item: order,
                                            onAdvance: { newStatus in
                                                update(order: order, to: newStatus)
                                            }
                                        )
                                        .padding(.horizontal)
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                                if selectedTab == .active, order.isUnpaid, let cb = onSelectUnpaid {
                                                    cb(order)
                                                } else {
                                                    selectedOrder = order
                                                }
                                            }
                                    }
                                }

                                if list.isEmpty {
                                    Text("אין הזמנות פעילות כרגע")
                                        .foregroundColor(.secondary)
                                        .padding(.top, 40)
                                }
                            }
                            .padding(.vertical, 16)

                        } else {
                            // 🔹 HISTORY TAB: regular flat list
                            LazyVStack(spacing: 16) {
                                ForEach(list) { order in
                                    AdminOrderRow(
                                        item: order,
                                        onAdvance: { newStatus in
                                            update(order: order, to: newStatus)
                                        }
                                    )
                                    .padding(.horizontal)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        selectedOrder = order
                                    }
                                }

                                if list.isEmpty {
                                    Text("אין הזמנות בהיסטוריה")
                                        .foregroundColor(.secondary)
                                        .padding(.top, 40)
                                }
                            }
                            .padding(.vertical, 16)
                        }
                    }
                }
            }
            .navigationTitle("הזמנות")
            .toolbar {
                // Leading dismiss chevron
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: isRtl ? "chevron.right" : "chevron.left")
                            .font(.system(size: 18, weight: .semibold))
                    }
                }

                // Center station selector as Menu (harder to toggle)
                ToolbarItem(placement: .principal) {
                    Menu {
                        Button {
                            stationMode = .bar
                        } label: {
                            Label("עמדת בר",
                                  systemImage: stationMode == .bar ? "checkmark" : "")
                        }

                        Button {
                            stationMode = .kitchen
                        } label: {
                            Label("עמדת מטבח",
                                  systemImage: stationMode == .kitchen ? "checkmark" : "")
                        }
                    } label: {
                        // Capsule-style selector, no chevron
                        Text(stationMode.title)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.primary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(Color(.systemGray5))
                            .clipShape(Capsule())
                    }
                }
            }
            // 🔹 First load – show spinner
            .task {
                stationMode = StationViewMode(rawValue: stationModeRaw) ?? .bar
                await loadOrders(showSpinner: true)
            }
            // 🔹 Poll every 10 seconds – quiet refresh (no spinner)
            .onReceive(pollTimer) { _ in
                Task {
                    await loadOrders(showSpinner: false)
                }
            }
        }
        .onChange(of: stationMode) { newValue in
            stationModeRaw = newValue.rawValue
        }
        .sheet(item: $selectedOrder) { order in
            AdminOrderDetailSheet(
                order: order,
                onAdvance: { newStatus in
                    update(order: order, to: newStatus)
                },
                onPrint: {
                    printOrder(order)          // kitchen/bar ticket
                },
                onPrintInvoice: {
                    printInvoice(for: order)   // tax invoice re-print
                }
            )
        }
    }

    // MARK: - Station helpers (instance methods)

    private func normalizeAdminCategory(_ s: String?) -> String {
        let raw = (s ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let allowed = CharacterSet.letters
            .union(.decimalDigits)
            .union(.whitespaces)

        return String(
            raw.unicodeScalars.filter { allowed.contains($0) }
        )
        .lowercased()
    }

    private func classifyAdminStation(for line: LineDTO) -> AdminStation {
        let rawCat  = (line.category ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let rawName = line.name.trimmingCharacters(in: .whitespacesAndNewlines)

        let cat  = normalizeAdminCategory(rawCat)   // emoji-safe, lowercased
        let name = rawName.lowercased()

        // 🔔 Hard-coded notes by name
        if rawName.contains("הערה למטבח") {
            return .kitchen
        }
        if rawName.contains("הערה לבר") {
            return .bar
        }
        if rawName.contains("הערה לוטרינה") {
            // For the admin view, vitrine notes should behave like bar
            return .bar
        }

        // 🥗 Kitchen if category contains "סלט" (covers any "…סלט…")
        let isSaladCategory = cat.contains("סלט")

        // 🥪 Kitchen if product name contains "טוסט"
        let isToastProduct  = name.contains("טוסט")

        if isSaladCategory || isToastProduct {
            return .kitchen
        }

        // 🥤 EVERYTHING else → BAR
        return .bar
    }
    // MARK: - Helpers

    private func sortRule(_ a: AdminOrderItem, _ b: AdminOrderItem) -> Bool {
       

       
        return a.placedAt > b.placedAt       // time DESC (newest first)
    }

    private var currentOrders: [AdminOrderItem] {
        // 1) Filter by tab (active vs history)
        let base: [AdminOrderItem]
        switch selectedTab {
        case .active:
            base = orders.filter { $0.status != .collected }
        case .history:
            base = orders.filter { $0.status == .collected }
        }

        // 2) 🔧 NEW: no station filtering – show all orders
        return base.sorted(by: sortRule)
    }

    // Build invoice line items from AdminOrderItem
    private func makeInvoiceItems(from order: AdminOrderItem) -> [InvoiceItem] {
        order.items.map { li in
            // If you want to include modifiers text on the invoice line, append it:
            let fullName: String
            if let mods = li.modifiersText, !mods.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                fullName = "\(li.name) (\(mods))"
            } else {
                fullName = li.name
            }

            return InvoiceItem(
                name: fullName,
                quantity: li.quantity,
                unitPrice: li.unitPrice
            )
        }
    }

    private func printInvoice(for order: AdminOrderItem) {
       // PrinterManager.shared.printSalesDebugDemo()
    }//
    
    private func printOrder(_ order: AdminOrderItem) {
        let entries = toBasketEntries(from: order)
        let mode    = diningMode(for: order)

        PrinterManager.shared.printCashPointSplit(
            orderNumber: order.id,
            entries: entries,
            total: order.total,
            diningMode: mode,
            customerName: order.customerName
        )
    }
    
    private func update(order: AdminOrderItem, to newStatus: AdminOrderStatus) {
        guard let idx = orders.firstIndex(where: { $0.id == order.id }) else { return }

        // Optimistic local update
        orders[idx].status = newStatus
        if let so = selectedOrder, so.id == order.id {
            selectedOrder?.status = newStatus
        }

        // Map enum → numeric code for the API
        let statusCode: Int
        switch newStatus {
        case .received:
            statusCode = 1
        case .ready:
            statusCode = 4      // READY
        case .collected:
            statusCode = 5      // COLLECTED
        }

        Task {
            let ok = await setStatus(orderId: order.id,
                                     to: statusCode,
                                     miniAppId: miniAppId)
            if !ok {
                print("❌ Failed to update status on server for order \(order.id) → \(statusCode)")
            }
        }
    }

    // MARK: - API Load (with polling flag)

    @MainActor
    private func loadOrders(showSpinner: Bool) async {
        guard miniAppId > 0 else { return }

        if showSpinner {
            isLoading = true
        }
        defer {
            if showSpinner {
                isLoading = false
            }
        }

        guard let url = URL(string: "\(baseURL)?miniAppId=\(miniAppId)") else {
            print("❌ admin/orders: bad URL")
            return
        }

        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                print("❌ admin/orders: no HTTPURLResponse")
                return
            }
            guard http.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
                print("❌ admin/orders HTTP \(http.statusCode)\n\(body)")
                return
            }

            // 🔧 Decoder with robust date handling
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

            let parsed: AdminOrdersApiResponse
            do {
                parsed = try decoder.decode(AdminOrdersApiResponse.self, from: data)
            } catch {
                let body = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
                print("❌ Decode failed: \(error)\nBody:\n\(body)")
                return
            }

            guard parsed.ok else {
                print("❌ admin/orders returned ok=false")
                return
            }

            let mapped: [AdminOrderItem] = parsed.orders.map { dto in

                let status: AdminOrderStatus = {
                    switch dto.status ?? 0 {
                    case 4:  return .ready
                    case 5:  return .collected
                    default: return .received
                    }
                }()

                let displayName: String = {
                    if let dn = dto.customerDisplayName, !dn.isEmpty {
                        return dn
                    }
                    return dto.customerName
                }()

                let sourceHe: String = {
                    switch dto.source.lowercased() {
                    case "cashpoint": return "קופה"
                    case "kiosk":     return "קיוסק"
                    case "mini", "appclip", "web": return "מיני"
                    default:          return dto.source
                    }
                }()

                let totalQty = max(1, dto.lines.reduce(0) { $0 + max($1.qty, 1) })
                let perUnit = dto.totalGBP / Double(totalQty)

                let lineItems: [AdminOrderLineItem] = dto.lines.enumerated().map { idx, l in
                    AdminOrderLineItem(
                        id: l.itemId ?? l.productId ?? idx,
                        productId: l.productId,
                        name: l.name,
                        quantity: max(l.qty, 1),
                        unitPrice: perUnit,
                        category: l.category,
                        modifiersText: l.modifiers,
                        updatedAt: l.updatedAt    // 👈 new field from DTO
                    )
                }
                
                let stationSet = Set(dto.lines.map { classifyAdminStation(for: $0) })

                // 👇 Define what counts as "unpaid"
                let bucketLower = dto.bucket.lowercased()
                let stageLower  = dto.stage.lowercased()

                let isUnpaid =
                    bucketLower.contains("unpaid")
                    || bucketLower.contains("open")
                    || bucketLower.contains("tab")
                    || stageLower.contains("unpaid")

                return AdminOrderItem(
                    id: dto.id,
                    orderId: String(dto.id),
                    customerName: displayName,
                    subtitle: dto.itemSummary,
                    source: sourceHe,
                    status: status,
                    placedAt: dto.placedAt,
                    items: lineItems,
                    total: dto.totalGBP,
                    stations: stationSet,
                    isUnpaid: isUnpaid          // 👈 NEW
                )
            }

            
            self.orders = mapped
        } catch {
            print("❌ admin/orders network error:", error.localizedDescription)
        }
        
    }
}

// MARK: - Row

struct AdminOrderRow: View {
    let item: AdminOrderItem
    let onAdvance: (AdminOrderStatus) -> Void

    private var timeString: String {
        DateTimeFormatter.cachedFormatter.string(from: item.placedAt)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            Text(timeString)
                .font(.system(size: 20, weight: .bold))
                .frame(width: 80, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("#\(item.orderId)")
                        .font(.system(size: 30, weight: .bold))

                    Text(item.customerName.replacingOccurrences(of: "Customer", with: ""))
                        .font(.system(size: 30, weight: .semibold))
                }

                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(.system(size: 15))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Text(item.source)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color(.systemGray6))
                    .clipShape(Capsule())
            }

            Spacer()

            if !nextButtonTitle.isEmpty {
                Button {
                    let nextStatus: AdminOrderStatus =
                        item.status == .received ? .ready :
                        item.status == .ready    ? .collected :
                                                   .collected
                    Haptics.light()
                    onAdvance(nextStatus)
                } label: {
                    Text(nextButtonTitle)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(buttonColor)
                        .cornerRadius(12)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 16)
    }

    private var nextButtonTitle: String {
        switch item.status {
        case .received:  return "מוכן"
        case .ready:     return "נאסף"
        case .collected: return ""
        }
    }

    private var buttonColor: Color {
        switch item.status {
        case .received:  return .green
        case .ready:     return .black
        case .collected: return .gray
        }
    }
}

// MARK: - Detail Sheet

struct AdminOrderDetailSheet: View {
    @State var order: AdminOrderItem
    let onAdvance: (AdminOrderStatus) -> Void
    let onPrint: () -> Void
    let onPrintInvoice: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isRtl)   private var isRtl

    private var timeString: String {
        DateTimeFormatter.cachedFormatter.string(from: order.placedAt)
    }

    private var nextStatus: AdminOrderStatus? {
        switch order.status {
        case .received:  return .ready
        case .ready:     return .collected
        case .collected: return nil
        }
    }

    private var nextStatusButtonTitle: String {
        switch nextStatus {
        case .some(.ready):     return "סמן כמוכן"
        case .some(.collected): return "סמן כנאסף"
        default: return ""
        }
    }

    private var orderTotal: Double {
        order.total
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    VStack(alignment: .leading, spacing: 8) {
                        Text("הזמנה #\(order.orderId)")
                            .font(.system(size: 28, weight: .bold))

                        Text(timeString)
                            .font(.system(size: 20))

                        Text(order.customerName)
                            .font(.system(size: 22, weight: .semibold))

                        if !order.subtitle.isEmpty {
                            Text(order.subtitle)
                                .font(.system(size: 16))
                                .foregroundColor(.secondary)
                        }

                        Text("מקור: \(order.source)")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.secondary)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(order.items) { line in
                            HStack {
                                Text("\(line.name) ×\(line.quantity)")
                                    .font(.system(size: 30))
                                    .lineLimit(1)
                                    .truncationMode(.tail)

                                Spacer()

                                if line.unitPrice > 0 {
                                    Text(String(format: "₪%.2f", line.rowTotal))
                                        .font(.system(size: 18, weight: .bold))
                                } else {
                                    Text("₪–")
                                        .font(.system(size: 18))
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }

                    Divider()

                    HStack {
                        Text("סה״כ")
                            .font(.system(size: 20, weight: .bold))
                        Spacer()
                        Text(String(format: "₪%.2f", orderTotal))
                            .font(.system(size: 22, weight: .bold))
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        if let target = nextStatus {
                            Button {
                                order.status = target
                                onAdvance(target)
                            } label: {
                                Text(nextStatusButtonTitle)
                                    .font(.system(size: 20, weight: .bold))
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 52)
                                    .background(target == .ready ? Color.green : Color.black)
                                    .cornerRadius(16)
                            }
                        }

                        // 🔹 Re-print kitchen/bar ticket
                        Button {
                            onPrint()
                        } label: {
                            HStack {
                                Image(systemName: "printer")
                                Text("הדפס הזמנה")
                            }
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(.primary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(Color(UIColor.systemGray5))
                            .cornerRadius(14)
                        }

                        // 🔹 Re-print tax invoice (like in DigitalBonesView)
                        Button {
                            onPrintInvoice()
                        } label: {
                            HStack {
                                Image(systemName: "doc.text")
                                Text("הדפס חשבונית")
                            }
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(.primary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(Color(UIColor.systemGray6))
                            .cornerRadius(14)
                        }

                        Button("סגור") {
                            dismiss()
                        }
                        .foregroundColor(.secondary)
                        .padding(.top, 4)
                    }
                }
                .padding(24)
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
    }
}

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
    let onSelectUnpaid: ((AdminOrderItem) -> Void)?
    let onRefundFromBone: ((DigitalBonesView.Bone) -> Void)?

    @Environment(\.isRtl) private var isRtl

    var body: some View {
        GeometryReader { proxy in
            let isPad        = UIDevice.current.userInterfaceIdiom == .pad
            let isLandscape  = proxy.size.width > proxy.size.height

            Group {
                if isPad && isLandscape {
                    // 🧾 Kitchen "bones" view (KDS style)
                    DigitalBonesView(onRefundToCashPoint: { bone in
                        onRefundFromBone?(bone)
                    })
                    .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)

                } else {
                    // 📋 Classic admin orders list
                    AdminOrdersView(onSelectUnpaid: onSelectUnpaid)
                        .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
                }
            }
        }
    }
}
