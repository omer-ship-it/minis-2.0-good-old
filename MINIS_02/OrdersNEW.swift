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
    var name: String
    var quantity: Int
    var unitPrice: Double
    var category: String?

    var rowTotal: Double {
        Double(quantity) * unitPrice
    }
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
    let name: String
    let qty: Int
    let category: String?
    let status: Int
    let station: String?
    let modifiers: String?
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
        lines        = try c.decode([LineDTO].self, forKey: .lines)

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

private func makeShellMenuItem(from line: AdminOrderLineItem) -> ShellMenuItem {
    let cat = line.category ?? ""
    print("🧩 makeShellMenuItem: name='\(line.name)' category='\(cat)'")

    return ShellMenuItem(
        id: line.id,
        name: line.name,
        price: line.unitPrice,
        category: cat,       // 👈 keep real category, e.g. "🥗 סלטים"
        modifiers: nil,
        imageURL: nil,
        description: nil
    )
}

struct AdminOrdersView: View {
    @AppStorage("AdminOrders.stationMode")
    private var stationModeRaw: String = StationViewMode.bar.rawValue
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
                        LazyVStack(spacing: 16) {
                            ForEach(currentOrders) { order in
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

                            if currentOrders.isEmpty {
                                Text(selectedTab == .active
                                     ? "אין הזמנות פעילות כרגע"
                                     : "אין הזמנות בהיסטוריה")
                                    .foregroundColor(.secondary)
                                    .padding(.top, 40)
                            }
                        }
                        .padding(.vertical, 16)
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
                    printOrder(order)
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

        // 2) Filter by station view mode
        switch stationMode {
        case .bar:
            // Orders that have ANY bar items
            return base
                .filter { $0.stations.contains(.bar) }
                .sorted(by: sortRule)

        case .kitchen:
            // Orders that have ANY kitchen items
            return base
                .filter { $0.stations.contains(.kitchen) }
                .sorted(by: sortRule)
        }
    }

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
                        name: l.name,
                        quantity: max(l.qty, 1),
                        unitPrice: perUnit,
                        category: l.category        // 👈 pass category from API
                        
                    )
                }
                
                for l in dto.lines {
                    print("🧾 API line dto: name='\(l.name)' category='\(l.category ?? "nil")'")
                }

                // 👇 derive which stations this order touches
                let stationSet = Set(dto.lines.map { classifyAdminStation(for: $0) })

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
                    stations: stationSet
                )
            }

            if allowAutoPrint {

                let newOrders = mapped.filter { order in
                    let src = order.source.lowercased()
                    let isCash = (src == "קופה" || src == "cashpoint")
                    return !isCash && !printedOrderIds.contains(order.id)
                }

                for order in newOrders {
                    print("🖨 AUTO PRINT #\(order.id) (src=\(order.source))")

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

                        Button {
                            onPrint()
                        } label: {
                            HStack {
                                Image(systemName: "printer")
                                Text("הדפס")
                            }
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(.primary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(Color(UIColor.systemGray5))
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
