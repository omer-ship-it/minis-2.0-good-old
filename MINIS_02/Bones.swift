import SwiftUI
import AVFoundation

struct DigitalBonesView: View {
    // MARK: - UI Bone model

    struct Bone: Identifiable, Equatable {
        let id = UUID()
        var orderId: Int
        var orderNumber: String      // "650"
        var customerName: String     // "אריאל"
        var items: [String]          // "1 הפוך גדול", "   + חלב סויה"
        var timeText: String         // "12:34   29/11/2025"
        var serviceText: String?     // "לשבת" / "TA" / nil
    }

    // Station selection (for this view only – now visual only)
    enum Station: String, CaseIterable {
        case bar     = "עמדת בר"
        case kitchen = "עמדת מטבח"
    }

    // Internal status
    private enum BoneOrderStatus {
        case received
        case ready
        case collected
    }

    // Internal order model (for mapping/filter/sorting)
    private struct BoneOrder: Identifiable {
        let id: Int
        let bone: Bone
        let status: BoneOrderStatus
        let placedAt: Date
        let stations: Set<Station>
        let invoiceItems: [InvoiceItem]
        let stationItems: [Station: [String]]
        let lines: [BonesLineDTO]
    }

    // MARK: - UI constants

    private let boneWidth: CGFloat = 210
    private let brandColor = Color(red: 50/255, green: 78/255, blue: 87/255)
    private let miniAppId = 12
    private let baseURL   = "https://minis.studio/api/admin/orders"

    // MARK: - External callbacks

    /// Called when the user taps "החזר" on the overlay.
    /// CashPointView can inject a closure that adds these items back to the basket.
    let onRefundToCashPoint: ((Bone) -> Void)?

    init(onRefundToCashPoint: ((Bone) -> Void)? = nil) {
        self.onRefundToCashPoint = onRefundToCashPoint
    }

    // MARK: - Map BoneOrder -> [BasketEntry] for reprinting

    private func makeBasketEntries(from order: BoneOrder) -> [BasketEntry] {
        var entries: [BasketEntry] = []
        var nextLineId = 1

        for ln in order.lines {
            let qty = max(ln.qty, 1)

            // Clean name
            let cleanName = ln.name.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

            // Clean modifiers into a simple " · " separated string
            let modsRaw = (ln.modifiers ?? "").trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            let modsClean = modsRaw
                .components(separatedBy: CharacterSet(charactersIn: "·,"))
                .map { $0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " · ")

            // Minimal ShellMenuItem built from line data
            let item = ShellMenuItem(
                id: ln.productId ?? ln.itemId ?? nextLineId,
                name: cleanName,
                price: 0,                        // not used by printCashPointSplit
                category: ln.category ?? "",
                modifiers: nil,
                imageURL: nil,
                description: nil
            )

            // BasketEntry for printCashPointSplit
            let entry = BasketEntry(
                id: nextLineId,
                item: item,
                quantity: qty,
                subtitle: modsClean.isEmpty ? nil : modsClean,
                unitPrice: 0
            )

            entries.append(entry)
            nextLineId += 1
        }

        return entries
    }
    // MARK: - State

    @State private var selectedStation: Station = .bar
    @State private var showStationPicker = false

    @State private var toPrepare: [Bone] = []      // top row
    @State private var readyBones: [Bone] = []     // flattened ready orders
    @State private var readySlots: [Bone?] = Array(repeating: nil, count: 5)

    @State private var selectedBone: Bone? = nil   // for center overlay
    @Environment(\.dismiss) private var dismiss
    @State private var allOrders: [BoneOrder] = [] // full dataset from API
    @State private var isLoading = false

    // 🔍 search text (order id / name)
    @State private var searchText: String = ""

    // Poll every 10 seconds
    @State private var pollTimer = Timer
        .publish(every: 10, on: .main, in: .common)
        .autoconnect()

    // MARK: - Body

    var body: some View {
        GeometryReader { geo in
            let halfHeight = geo.size.height / 2

            let topHeaderHeight: CGFloat = 40
            let bottomHeaderHeight: CGFloat = 34

            let topMaxTicketHeight    = max(90, halfHeight - topHeaderHeight - 16)
            let bottomMaxTicketHeight = max(80, halfHeight - bottomHeaderHeight - 16)
            let maxColumns = 5
               let hSpacing: CGFloat = 20
               let horizontalPadding: CGFloat = 10
               let availableWidth = geo.size.width
                   - horizontalPadding * 2
                   - hSpacing * CGFloat(maxColumns - 1)

               // Never wider than boneWidth (210),
               // shrink as needed to fit all 5 in a row.
               let cardWidth = min(boneWidth, availableWidth / CGFloat(maxColumns))

           

            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    // ===== TOP HALF (selector + search + "בהכנה" + incoming bones) =====
                    VStack(spacing: 0) {
                        // Header row (now includes search + station pill)
                        HStack(spacing: 12) {
                            // Close chevron
                            Button {
                                dismiss()
                            } label: {
                                Image(systemName: "chevron.right")
                                    .foregroundColor(.white)
                                    .font(.system(size: 18, weight: .semibold))
                                    .padding(.trailing, 4)
                            }

                            // Title
                            Text("בהכנה")
                                .font(.system(size: 22, weight: .bold))
                                .foregroundColor(.white)

                            Spacer()

                            // 🔍 Small search bar, integrated in header
                            HStack(spacing: 8) {
                                Image(systemName: "magnifyingglass")
                                    .foregroundColor(.white.opacity(0.7))

                                TextField("חיפוש הזמנה…", text: $searchText)
                                    .textFieldStyle(.plain)
                                    .foregroundColor(.white)
                                    .accentColor(.white)              // white cursor
                                    .disableAutocorrection(true)
                                    .textInputAutocapitalization(.never)

                                if !searchText.isEmpty {
                                    Button {
                                        searchText = ""
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(.white.opacity(0.6))
                                            .font(.system(size: 16, weight: .semibold))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .frame(width: 220)
                            .background(Color.white.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                            // Station picker – purely visual for now
                            Button {
                                showStationPicker = true
                            } label: {
                                HStack(spacing: 6) {
                                    Text(selectedStation.rawValue)
                                        .font(.system(size: 16, weight: .semibold))
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 13, weight: .semibold))
                                }
                                .foregroundColor(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .fill(Color.white.opacity(0.16))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                                .stroke(Color.white.opacity(0.25), lineWidth: 1)
                                        )
                                )
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 8)
                        .padding(.bottom, 6)

                        if isLoading && toPrepare.isEmpty && readyBones.isEmpty {
                            Spacer()
                            ProgressView().tint(.white)
                            Spacer()
                        } else {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(alignment: .top, spacing: 20) {
                                    ForEach(toPrepare) { bone in
                                        BoneCardView(
                                            bone: bone,
                                            slotLabel: nil,
                                            actionTitle: "שליחת SMS",
                                            actionColor: brandColor,
                                            maxTicketHeight: topMaxTicketHeight
                                        ) {
                                            markReadyUI(bone)
                                        }
                                        .frame(width: cardWidth)
                                        .onTapGesture {
                                            withAnimation(.easeInOut(duration: 0.2)) {
                                                selectedBone = bone
                                            }
                                        }
                                    }
                                }
                                .padding(.horizontal, 24)
                            }
                        }

                        Spacer()
                    }
                    .frame(height: halfHeight)

                    Divider()
                        .background(Color.white.opacity(0.2))

                    // ===== BOTTOM HALF ("מוכן לאיסוף" + ready slots) =====
                    VStack(spacing: 0) {
                        HStack {
                            Text("מוכן לאיסוף")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundColor(.white)
                            Spacer()
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 8)
                        .padding(.bottom, 4)

                        HStack(alignment: .top, spacing: hSpacing) {
                            ForEach(readySlots.indices, id: \.self) { index in
                                if let bone = readySlots[index] {
                                    BoneCardView(
                                        bone: bone,
                                        slotLabel: "עמדה \(index + 1)",
                                        actionTitle: "נאסף",
                                        actionColor: brandColor,
                                        maxTicketHeight: bottomMaxTicketHeight
                                    ) {
                                        markCollectedUI(at: index)
                                    }
                                    .frame(width: cardWidth)
                                    .onTapGesture {
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            selectedBone = bone
                                        }
                                    }
                                } else {
                                    EmptySlotView(index: index, width: cardWidth)
                                }
                            }
                        }
                        .padding(.horizontal, horizontalPadding)
                      

                        Spacer()
                    }
                    .frame(height: halfHeight)
                }

                // ===== Center overlay for selected bone =====
                // ===== Center overlay for selected bone =====
                if let bone = selectedBone {
                    ZStack {
                        Color.black.opacity(0.45)
                            .ignoresSafeArea()
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    selectedBone = nil
                                }
                            }

                        // Center the overlay in BOTH directions
                        VStack {
                            Spacer()

                            InvoiceOverlayView(
                                bone: bone,
                                brandColor: brandColor,
                                onPrint: {
                                    guard let fullOrder = allOrders.first(where: { $0.id == bone.orderId }) else {
                                        print("❌ DigitalBonesView: no full order found for bone \(bone.orderId)")
                                        return
                                    }

                                    let entriesArray = makeBasketEntries(from: fullOrder)
                                    let total = fullOrder.invoiceItems.reduce(0) { $0 + $1.lineTotal }

                                    let mode: DiningMode = {
                                        if fullOrder.bone.serviceText == "**TA**" {
                                            return .takeAway
                                        } else {
                                            return .dineIn
                                        }
                                    }()

                                    let nameSnapshot = fullOrder.bone.customerName

                                    PrinterManager.shared.printCashPointSplit(
                                        orderNumber: fullOrder.id,
                                        entries: entriesArray,
                                        total: total,
                                        diningMode: mode,
                                        customerName: nameSnapshot
                                    )
                                },
                                onPrintInvoice: {
                                    if let fullOrder = allOrders.first(where: { $0.id == bone.orderId }) {
                                        PrinterManager.shared.printTaxInvoice(
                                            invoiceNumber: fullOrder.id,
                                            date: fullOrder.placedAt,
                                            customerName: fullOrder.bone.customerName,
                                            items: fullOrder.invoiceItems,
                                            vatRate: 0.17
                                        )
                                    } else {
                                        print("❌ No BoneOrder found for invoice \(bone.orderId)")
                                    }
                                },
                                onRefund: {
                                    onRefundToCashPoint?(bone)
                                    dismiss()
                                },
                                onClose: {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        selectedBone = nil
                                    }
                                }
                            )
                            .frame(
                                maxWidth: min(geo.size.width * 0.55, 420),
                                maxHeight: min(geo.size.height * 0.8, 500)
                            )
                            .padding(.horizontal, 24)
                            .transition(.scale.combined(with: .opacity))

                            Spacer()
                        }
                    }
                }
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .confirmationDialog(
            "בחר עמדה",
            isPresented: $showStationPicker,
            titleVisibility: .visible
        ) {
            Button("עמדת בר") { selectedStation = .bar; rebuildBonesFromOrders() }
            Button("עמדת מטבח") { selectedStation = .kitchen; rebuildBonesFromOrders() }
        }
        .task {
            await loadOrders(showSpinner: true)
        }
        .onReceive(pollTimer) { _ in
            Task { await loadOrders(showSpinner: false) }
        }
        // 🔄 Re-filter when search changes
        .onChange(of: searchText) { _ in
            rebuildBonesFromOrders()
        }
    }

    // MARK: - UI-only transitions

    private func markReadyUI(_ bone: Bone) {
        if let idx = toPrepare.firstIndex(of: bone) {
            toPrepare.remove(at: idx)
        }

        if let emptyIndex = readySlots.firstIndex(where: { $0 == nil }) {
            readySlots[emptyIndex] = bone
        } else {
            print("⚠️ אין מקום פנוי עבור הזמנה \(bone.orderNumber)")
        }

        Task {
            let ok = await setStatus(orderId: bone.orderId, to: 4, miniAppId: miniAppId)
            if !ok {
                print("❌ Failed to setStatus READY for order \(bone.orderId)")
            }
        }
    }

    private func markCollectedUI(at index: Int) {
        guard readySlots.indices.contains(index),
              let bone = readySlots[index] else { return }

        readySlots[index] = nil

        Task {
            let ok = await setStatus(orderId: bone.orderId, to: 5, miniAppId: miniAppId)
            if !ok {
                print("❌ Failed to setStatus COLLECTED for order \(bone.orderId)")
            }
        }
    }

    // MARK: - Rebuild bones arrays from allOrders (show ALL stations, filtered by search)

    private func rebuildBonesFromOrders() {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // 1️⃣ Only orders that have at least one line for the selected station
        let stationFilteredBase = allOrders.filter { order in
            order.stations.contains(selectedStation)
        }

        // 2️⃣ Search filter (by order id or customer name)
        let relevant: [BoneOrder]
        if q.isEmpty {
            relevant = stationFilteredBase
        } else {
            relevant = stationFilteredBase.filter { order in
                let idMatch = "\(order.id)".contains(q)
                let nameMatch = order.bone.customerName
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                    .contains(q)
                return idMatch || nameMatch
            }
        }

        // Helper → return Bone with items filtered to selected station
        func stationBone(from order: BoneOrder) -> Bone {
            var b = order.bone
            b.items = order.stationItems[selectedStation] ?? order.bone.items
            return b
        }

        // 3️⃣ Split to received / ready
        let received = relevant
            .filter { $0.status == .received }
            .sorted { $0.placedAt > $1.placedAt }

        let ready = relevant
            .filter { $0.status == .ready }
            .sorted { $0.placedAt > $1.placedAt }

        // 4️⃣ Bind to UI with station-specific items

        // Top row – בהכנה
        toPrepare = received.map { stationBone(from: $0) }

        // Bottom row – first 5 ready slots – מוכן לאיסוף
        readySlots = Array(repeating: nil, count: 5)
        for (i, order) in ready.prefix(5).enumerated() {
            readySlots[i] = stationBone(from: order)
        }

        readyBones = ready.map { stationBone(from: $0) }
    }

    // MARK: - API DTOs, mapping, loadOrders (unchanged from your version)

    private struct BonesAdminOrdersApiResponse: Decodable {
        let ok: Bool
        let count: Int
        let orders: [BonesOrderDTO]
    }

    private struct BonesLineDTO: Decodable {
        let itemId: Int?
        let productId: Int?
        let name: String
        let qty: Int
        let category: String?
        let status: Int
        let station: String?
        let modifiers: String?
    }

    private struct BonesOrderDTO: Decodable {
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
        let lines: [BonesLineDTO]
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
            lines        = try c.decode([BonesLineDTO].self, forKey: .lines)

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

    private func normalizeCategory(_ s: String?) -> String {
        let raw = (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.letters
            .union(.decimalDigits)
            .union(.whitespaces)

        return String(raw.unicodeScalars.filter { allowed.contains($0) }).lowercased()
    }

    private func classifyStation(for line: BonesLineDTO) -> Station {
        let rawCat  = (line.category ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let rawName = line.name.trimmingCharacters(in: .whitespacesAndNewlines)

        let cat  = normalizeCategory(rawCat)
        let name = rawName.lowercased()

        if rawName.contains("הערה למטבח") {
            return .kitchen
        }
        if rawName.contains("הערה לבר") || rawName.contains("הערה לוטרינה") {
            return .bar
        }

        let isSaladCategory = cat.contains("סלט")
        let isToastProduct  = name.contains("טוסט")

        if isSaladCategory || isToastProduct {
            return .kitchen
        }

        return .bar
    }

    private func mapOrder(_ dto: BonesOrderDTO) -> BoneOrder {
        // Map overall status
        let status: BoneOrderStatus = {
            switch dto.status ?? 0 {
            case 4:  return .ready
            case 5:  return .collected
            default: return .received
            }
        }()

        // Display name
        let displayName: String = {
            if let dn = dto.customerDisplayName, !dn.isEmpty {
                return dn
            }
            return dto.customerName
        }()

        // Time text
        let df = DateFormatter()
        df.locale = Locale(identifier: "he_IL")
        df.timeZone = .current
        df.dateFormat = "HH:mm   dd/MM/yyyy"
        let israelTime = Calendar.current.date(byAdding: .hour, value: 2, to: dto.placedAt) ?? dto.placedAt
        let timeText = df.string(from: israelTime)

        // Service text (TA or sit)
        let serviceText: String? = dto.itemSummary.contains("לקחת") ? "**TA**" : nil

        // --- Build raw entries for: all, and per-station ---

        struct RawEntry {
            var name: String
            var qty: Int
            var modifiers: [String]
        }

        var rawEntriesAll: [RawEntry] = []
        var rawEntriesByStation: [Station: [RawEntry]] = [
            .bar: [],
            .kitchen: []
        ]

        for l in dto.lines {
            let qty = max(l.qty, 1)

            let modsRaw = l.modifiers ?? ""
            let separators = CharacterSet(charactersIn: "•·")
            let modifierParts = modsRaw
                .components(separatedBy: separators)
                .map { $0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            let hasSizeWord = modsRaw.contains("גודל")
            let baseName = l.name.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

            let adjustedName: String = {
                if baseName == "אספרסו", !hasSizeWord {
                    return "אספרסו קצר"
                }
                if baseName == "הפוך", !hasSizeWord {
                    return "הפוך קטן"
                }
                return baseName
            }()

            let entry = RawEntry(name: adjustedName, qty: qty, modifiers: modifierParts)

            // For whole-order view (invoice etc.)
            rawEntriesAll.append(entry)

            // For per-station view
            let st = classifyStation(for: l)
            rawEntriesByStation[st, default: []].append(entry)
        }

        func mergedEntries(from entries: [RawEntry]) -> [RawEntry] {
            var merged: [RawEntry] = []
            for entry in entries {
                if entry.modifiers.isEmpty {
                    if let idx = merged.firstIndex(where: {
                        $0.name == entry.name && $0.modifiers.isEmpty
                    }) {
                        merged[idx].qty += entry.qty
                    } else {
                        merged.append(entry)
                    }
                } else {
                    merged.append(entry)
                }
            }
            return merged
        }

        func buildItemLines(from entries: [RawEntry]) -> [String] {
            var lines: [String] = []
            for entry in entries {
                lines.append("\(entry.qty) \(entry.name)")
                for mod in entry.modifiers {
                    lines.append("MOD:\(mod)")
                }
            }
            return lines
        }

        // Merge for "all" and for each station
        let mergedAll     = mergedEntries(from: rawEntriesAll)
        let mergedBar     = mergedEntries(from: rawEntriesByStation[.bar] ?? [])
        let mergedKitchen = mergedEntries(from: rawEntriesByStation[.kitchen] ?? [])

        var stationItems: [Station: [String]] = [:]
        stationItems[.bar]     = buildItemLines(from: mergedBar)
        stationItems[.kitchen] = buildItemLines(from: mergedKitchen)

        // Invoice items use the mergedAll (whole order)
        let totalQty = max(1, dto.lines.reduce(0) { $0 + max($1.qty, 1) })
        let perUnit = totalQty > 0 ? dto.totalGBP / Double(totalQty) : 0

        var invoiceItems: [InvoiceItem] = []
        for entry in mergedAll {
            invoiceItems.append(
                InvoiceItem(
                    name: entry.name,
                    quantity: entry.qty,
                    unitPrice: perUnit
                )
            )
        }

        // Stations set (which stations are involved)
        let stationsSet = Set(dto.lines.map { classifyStation(for: $0) })

        // Default bone items = full order (used for e.g. invoice overlay if you want)
        let boneAllItems = buildItemLines(from: mergedAll)

        let bone = Bone(
            orderId: dto.id,
            orderNumber: String(dto.id),
            customerName: displayName.replacingOccurrences(of: "Customer", with: ""),
            items: boneAllItems,
            timeText: timeText,
            serviceText: serviceText
        )

        return BoneOrder(
            id: dto.id,
            bone: bone,
            status: status,
            placedAt: dto.placedAt,
            stations: stationsSet,
            invoiceItems: invoiceItems,
            stationItems: stationItems,
            lines: dto.lines                      // 👈 pass the DTO lines in

        )
    }

    @MainActor
    private func loadOrders(showSpinner: Bool) async {
        guard miniAppId > 0 else { return }

        if showSpinner { isLoading = true }
        defer { if showSpinner { isLoading = false } }

        guard let url = URL(string: "\(baseURL)?miniAppId=\(miniAppId)") else {
            print("❌ DigitalBonesView: bad URL")
            return
        }

        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                print("❌ bones: no HTTPURLResponse")
                return
            }
            guard http.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
                print("❌ bones HTTP \(http.statusCode)\n\(body)")
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
                for format in ["yyyy-MM-dd'T'HH:mm:ss.SSS",
                               "yyyy-MM-dd'T'HH:mm:ss"] {
                    df.dateFormat = format
                    if let d = df.date(from: s) { return d }
                }

                throw DecodingError.dataCorruptedError(
                    in: c,
                    debugDescription: "Unrecognized date: \(s)"
                )
            }

            let parsed = try decoder.decode(BonesAdminOrdersApiResponse.self, from: data)
            guard parsed.ok else {
                print("❌ bones ok=false")
                return
            }

            let oldIds = Set(allOrders.map { $0.id })
            let mappedOrders = parsed.orders.map(mapOrder(_:))

            let newIncoming = mappedOrders.filter { order in
                order.status == .received && !oldIds.contains(order.id)
            }

            if !newIncoming.isEmpty {
                playBeep()
            }

            allOrders = mappedOrders
            rebuildBonesFromOrders()
        } catch {
            print("❌ bones network error:", error.localizedDescription)
        }
    }
}

// MARK: - Render Line model

private struct RenderLine: Identifiable {
    let id = UUID()
    let isSeparator: Bool
    let isModifier: Bool
    let text: String
}


private func playBeep() {
    // System printer-like beep – you can tweak the ID if you like
    AudioServicesPlaySystemSound(1057)
}

private func makeRenderLines(from items: [String]) -> [RenderLine] {
    var lines: [RenderLine] = []
    var firstProduct = true

    for raw in items {
        // Detect modifier lines either by "MOD:" prefix (new) or old "+ ..." style
        var isModifier = false
        var displayText = raw

        if raw.hasPrefix("MOD:") {
            isModifier = true
            displayText = String(raw.dropFirst("MOD:".count))
                .trimmingCharacters(in: .whitespaces)
        } else {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("+") {
                isModifier = true
                displayText = String(trimmed.dropFirst())
                    .trimmingCharacters(in: .whitespaces)
            } else {
                displayText = raw
            }
        }

        // Products → add separator before every product after the first
        if !isModifier {
            if !firstProduct {
                lines.append(
                    RenderLine(
                        isSeparator: true,
                        isModifier: false,
                        text: ""
                    )
                )
            }
            firstProduct = false
        }

        // Actual display line
        lines.append(
            RenderLine(
                isSeparator: false,
                isModifier: isModifier,
                text: displayText    // 👈 already cleaned (no "MOD:", no "+", no spaces)
            )
        )
    }

    return lines
}

// MARK: - Small Bone card in rows

private struct BoneCardView: View {
    let bone: DigitalBonesView.Bone
    var slotLabel: String? = nil
    let actionTitle: String
    let actionColor: Color
    let maxTicketHeight: CGFloat
    let action: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            if let slotLabel {
                Text(slotLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .trailing, spacing: 6) {
                    if let service = bone.serviceText,
                       !service.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(service)
                            .font(.system(size: 20, weight: .bold, design: .monospaced))
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .multilineTextAlignment(.center)
                    }

                    let name = bone.customerName.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "Customer", with: "")
                    Text(name.isEmpty ? "שם לקוח" : name)
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .multilineTextAlignment(.center)

                    Text("#\(bone.orderNumber)")
                        .font(.system(size: 24, weight: .bold, design: .monospaced))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .multilineTextAlignment(.center)

                    Text(bone.timeText)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)

                    Rectangle()
                        .fill(Color.black.opacity(0.2))
                        .frame(height: 1)
                        .overlay(
                            Rectangle()
                                .stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                                .foregroundColor(.black.opacity(0.3))
                        )
                        .padding(.vertical, 4)

                    let renderLines = makeRenderLines(from: bone.items)

                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(renderLines) { line in
                            if line.isSeparator {
                                HStack(spacing: 4) {
                                    ForEach(0..<20) { _ in
                                        Text("·")
                                            .font(.system(size: 18, weight: .regular, design: .monospaced))
                                            .foregroundColor(.black.opacity(0.35))
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 2)
                            } else if line.isModifier {
                                Text(verbatim: line.text)
                                    .font(.system(size: 16, weight: .regular, design: .monospaced))
                                    .foregroundColor(.black.opacity(0.85))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .multilineTextAlignment(.leading)
                            } else {
                                Text(verbatim: line.text)
                                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                                    .foregroundColor(.black)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }

                        Spacer().frame(height: 6)

                        Text("····")
                            .font(.system(size: 12, weight: .regular, design: .monospaced))
                            .foregroundColor(.black.opacity(0.3))
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.bottom, 2)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            .frame(maxHeight: maxTicketHeight)
            .background(Color.white)
            .overlay(
                Rectangle()
                    .stroke(Color.black.opacity(0.3), lineWidth: 1)
            )

            Button(action: action) {
                Text(actionTitle)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)
                    .background(actionColor)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
    }
}

// MARK: - Invoice overlay (center popup)

private struct InvoiceOverlayView: View {
    let bone: DigitalBonesView.Bone
    let brandColor: Color
    let onPrint: () -> Void
    let onPrintInvoice: () -> Void
    let onRefund: () -> Void      // 👈 NEW
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Spacer()
                Text("הזמנה #\(bone.orderNumber)")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.primary)
                Spacer()
            }

            ScrollView {
                VStack(alignment: .trailing, spacing: 6) {
                    if let service = bone.serviceText,
                       !service.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(service)
                            .font(.system(size: 26, weight: .bold, design: .monospaced))
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }

                    let name = bone.customerName.trimmingCharacters(in: .whitespacesAndNewlines)
                    Text(name.isEmpty ? "שם לקוח" : name)
                        .font(.system(size: 26, weight: .bold, design: .monospaced))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity, alignment: .center)

                    Text("#\(bone.orderNumber)")
                        .font(.system(size: 30, weight: .bold, design: .monospaced))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity, alignment: .center)

                    Text(bone.timeText)
                        .font(.system(size: 14, weight: .regular, design: .monospaced))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Rectangle()
                        .fill(Color.black.opacity(0.2))
                        .frame(height: 1)
                        .overlay(
                            Rectangle()
                                .stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                                .foregroundColor(.black.opacity(0.3))
                        )
                        .padding(.vertical, 6)

                    let renderLines = makeRenderLines(from: bone.items)

                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(renderLines) { line in
                            if line.isSeparator {
                                Rectangle()
                                    .fill(Color.black.opacity(0.15))
                                    .frame(height: 1)
                                    .overlay(
                                        Rectangle()
                                            .stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                                            .foregroundColor(.black.opacity(0.25))
                                    )
                                    .padding(.vertical, 3)
                            } else if line.isModifier {
                                Text(verbatim: line.text)
                                    .font(.system(size: 18, weight: .regular, design: .monospaced))
                                    .foregroundColor(.black.opacity(0.85))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                Text(verbatim: line.text)
                                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                                    .foregroundColor(.black)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }

                        Spacer().frame(height: 8)

                        Text("····")
                            .font(.system(size: 18, weight: .regular, design: .monospaced))
                            .foregroundColor(.black.opacity(0.4))
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.bottom, 4)
                    }
                }
                .padding(16)
                .background(Color.white)
                .cornerRadius(12)
                
            }

            HStack(spacing: 10) {
                Button {
                    onPrint()
                    onClose()
                } label: {
                    Text("הדפס")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(brandColor)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }

                Button {
                    onPrintInvoice()
                    onClose()
                } label: {
                    Text("הדפס חשבונית")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color(.secondarySystemBackground))
                        .foregroundColor(.primary)
                        .cornerRadius(10)
                }

                // 👇 NEW REFUND BUTTON
                Button {
                    onRefund()   // CashPoint will handle adding back to basket
                    onClose()
                } label: {
                    Text("החזר")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color(.secondarySystemBackground))
                        
                        .cornerRadius(10)
                }
            }
        }
        .padding(20)
        .background(Color(.systemBackground))
        .cornerRadius(20)
        .shadow(color: .black.opacity(0.4), radius: 20, x: 0, y: 10)
        .environment(\.layoutDirection, .rightToLeft)
    }
}

// MARK: - Empty slot

private struct EmptySlotView: View {
    let index: Int
    let width: CGFloat

    var body: some View {
        VStack(spacing: 8) {
            Text("עמדה \(index + 1)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))

            Rectangle()
                .strokeBorder(Color.white.opacity(0.4), lineWidth: 1)
                .frame(width: width)
                .frame(minHeight: 120)
                .overlay(
                    Text("ריק")
                        .font(.system(size: 14, weight: .regular, design: .monospaced))
                        .foregroundColor(.white.opacity(0.4))
                )

            Spacer().frame(height: 32)
        }
    }
}

/// Build a KDSAdminOrder from a DigitalBonesView.Bone so we can reuse PrinterManager's makeJob logic.
fileprivate func makeKDSAdminOrder(from bone: DigitalBonesView.Bone) -> KDSAdminOrder {
    // Parse bone.items back into lines:
    // non-MOD: = product ("2 הפוך קטן"), following "MOD:" rows = modifiers.
    var kdsLines: [KDSOrderLine] = []

    var i = 0
    while i < bone.items.count {
        let raw = bone.items[i]
        if raw.hasPrefix("MOD:") {
            // shouldn't happen: modifiers should follow a product line; skip defensively
            i += 1
            continue
        }

        // Parse "qty name" from line, e.g. "2 הפוך קטן"
        let parts = raw.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let qty: Int
        let name: String

        if parts.count == 2, let q = Int(parts[0]) {
            qty = max(q, 1)
            name = String(parts[1])
        } else {
            qty = 1
            name = raw
        }

        // Collect following MOD: lines as modifiers
        var mods: [String] = []
        var j = i + 1
        while j < bone.items.count, bone.items[j].hasPrefix("MOD:") {
            let modRaw = bone.items[j]
            let cleaned = modRaw.dropFirst("MOD:".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                mods.append(cleaned)
            }
            j += 1
        }

        let modifiersString = mods.joined(separator: " · ")

        let line = KDSOrderLine(
            itemId: nil,
            productId: nil,
            name: name,
            qty: qty,
            category: nil,
            status: 1,
            station: nil,
            modifiers: modifiersString.isEmpty ? nil : modifiersString
        )
        kdsLines.append(line)

        i = j
    }

    // Map serviceText ("TA" or nil) to service key ("ta"/"sit")
    let serviceKey: String = {
        if let s = bone.serviceText?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           s == "ta" || s.contains("take") {
            return "ta"
        }
        return "sit"
    }()

    // Total is not really needed for station tickets → use 0
    let totalGBP: Double = 0

    // Build a minimal KDSAdminOrder mirroring your printCashPointSplit initializer
    let order = KDSAdminOrder(
        id: bone.orderId,
        source: .kiosk,
        tableLabel: nil,
        bucket: .active,
        stage: .received,
        placedAt: Date(),
        scheduledFor: nil,
        customerName: bone.customerName,
        totalGBP: totalGBP,
        itemSummary: "",
        isDelivery: false,
        shortCode: nil,
        lines: kdsLines,
        service: serviceKey,
        name: bone.customerName
    )

    return order
}
