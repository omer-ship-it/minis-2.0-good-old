import SwiftUI
import AVFoundation
import UIKit
import Combine

struct DigitalBonesView: View {
    // MARK: - UI Bone model

    enum Tab: String, CaseIterable {
        case active
        case history

        var title: String {
            switch self {
            case .active:  return "פעיל"
            case .history: return "היסטוריה"
            }
        }
    }
    @AppStorage("DigitalBones.selectedStation")
    private var selectedStationRaw: String = Station.kitchen.rawValue

    @State private var selectedStation: Station = .kitchen
    @State private var toastText: String? = nil
    private func resolvePrinter(for line: BonesLineDTO) -> String? {
        // 1) station from server
        if let s = line.station?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            return s
        }
        // 2) printer from menu JSON by productId
        return MenuCatalog.shared.printer(for: line.productId)
    }
    
    private func showToast(_ text: String) {
        withAnimation(.easeInOut(duration: 0.15)) { toastText = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation(.easeInOut(duration: 0.15)) { toastText = nil }
        }
    }

    private func normalizeILPhoneToE164(_ raw: String?) -> String? {
        let s = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if s.hasPrefix("+") { return s }
        let digits = s.replacingOccurrences(of: "[^0-9]", with: "", options: .regularExpression)
        if digits.hasPrefix("0"), digits.count >= 9 { return "+972" + digits.dropFirst() }
        if digits.hasPrefix("972") { return "+" + digits }
        return nil
    }

    private func callCustomer(_ bone: Bone) {
        guard let toRaw = normalizeILPhoneToE164(bone.customerPhone) else {
            showToast("אין טלפון")
            return
        }

        // ✅ IMPORTANT: force-encode "+" so server doesn't treat it as space
        let encodedTo = toRaw.replacingOccurrences(of: "+", with: "%2B")

        guard let url = URL(string: "https://minis.studio/api/admin/voice/call?to=\(encodedTo)") else {
            showToast("Bad URL")
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = Data() // avoids IIS 411
        req.setValue("application/json", forHTTPHeaderField: "Accept")


        Task {
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)

                let http = resp as? HTTPURLResponse
                let code = http?.statusCode ?? -1
                let body = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"


                if code == 200 {
                    showToast("Called")
                } else {
                    showToast("Call failed (\(code))")
                }
            } catch {
                showToast("Call failed")
            }
        }
    }

    private func stationFromPrinter(_ p: String?) -> Station {
        switch (p ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "kitchen": return .kitchen
        case "bar":     return .bar
        case "bakery":  return .bar   // bones UI has only bar/kitchen; treat bakery as bar here
        default:        return .bar
        }
    }
    struct Bone: Identifiable, Equatable {
        let id: Int          // 👈 stable id == orderId
        var orderId: Int
        var orderNumber: String
        var customerName: String
        var customerPhone: String?
        var items: [String]
        var timeText: String
        var serviceText: String?
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
        let rawStatus: Int    // 🆕 (2026-05-10): keep raw DB status for strict Status==1 filtering
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

        let segmented = UISegmentedControl.appearance()

        // Background of whole control (keeps it dark)
        segmented.backgroundColor = UIColor.white.withAlphaComponent(0.10)

        // Selected tab background (brighter dark-mode highlight)
        segmented.selectedSegmentTintColor = UIColor.white.withAlphaComponent(0.25)

        // Unselected text
        segmented.setTitleTextAttributes([
            .foregroundColor: UIColor.white.withAlphaComponent(0.7),
            .font: UIFont.systemFont(ofSize: 15, weight: .regular)
        ], for: .normal)

        // Selected text
        segmented.setTitleTextAttributes([
            .foregroundColor: UIColor.white,
            .font: UIFont.systemFont(ofSize: 15, weight: .semibold)
        ], for: .selected)
    }

    // MARK: - Map BoneOrder -> [BasketEntry] for reprinting

    private func makeBasketEntries(from order: BoneOrder) -> [BasketEntry] {
        var entries: [BasketEntry] = []
        var nextLineId = 1


        for ln in order.lines {
            let stationRaw = (ln.station ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let catalogPrinterRaw = MenuCatalog.shared.printer(for: ln.productId)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            let resolved = resolvePrinter(for: ln)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? ""

            let productIdText = ln.productId.map(String.init) ?? "nil"

            // ✅ strict Kitchen-only
            let isKitchen = (resolved == "kitchen")

            if !isKitchen {
                continue
            }


            let qty = max(ln.qty, 1)
            let cleanName = ln.name.trimmingCharacters(in: .whitespacesAndNewlines)

            let modsRaw = (ln.modifiers ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let modsClean = modsRaw
                .components(separatedBy: CharacterSet(charactersIn: "·,"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " · ")

            // Prefer MenuCatalog item (has printer/price if loaded)
            let item: ShellMenuItem = {
                if let menuItem = MenuCatalog.shared.item(for: ln.productId) {
                    return menuItem
                }
                return ShellMenuItem(
                    id: ln.productId ?? ln.itemId ?? nextLineId,
                    name: cleanName,
                    price: 0,
                    category: ln.category ?? "",
                    modifiers: nil,
                    imageURL: nil,
                    description: nil,
                    status: nil,
                    stockQuantity: nil,
                    printer: "kitchen"
                )
            }()

            let unit = MenuCatalog.shared.price(for: ln.productId)

            entries.append(
                BasketEntry(
                    id: nextLineId,
                    item: item,
                    quantity: qty,
                    subtitle: modsClean.isEmpty ? nil : modsClean,
                    unitPrice: unit
                )
            )
            nextLineId += 1
        }

        return entries
    }
    // MARK: - State

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
    @State private var selectedTab: Tab = .active
       @State private var historyBones: [Bone] = []

    // Poll every 10 seconds
    @State private var pollTimer = Timer
        .publish(every: 10, on: .main, in: .common)
        .autoconnect()

    // MARK: - Body
    
    private func normalizedPrinterKey(_ raw: String?) -> String {
        let s = (raw ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        // ✅ support hebrew / variants
        if s.contains("מטבח") { return "kitchen" }
        if s.contains("kitchen") { return "kitchen" }

        if s.contains("בר") { return "bar" }
        if s.contains("bar") { return "bar" }

        if s.contains("bakery") || s.contains("מאפה") || s.contains("ווטרינה") || s.contains("ויטרינה") {
            return "bakery"
        }

        return s
    }

    private func isKitchenLine(_ line: BonesLineDTO) -> Bool {
        // ✅ STRICT: use Product.printer from MenuCatalog (menu JSON)
        let productPrinterRaw: String? = {
            if let pid = line.productId,
               let item = MenuCatalog.shared.item(for: pid) {
                return item.printer
            }
            // fallback if item(for:) not available
            return MenuCatalog.shared.printer(for: line.productId)
        }()

        let productKey = normalizedPrinterKey(productPrinterRaw)

        // ✅ If we have a productId, we enforce catalog printer strictly
        if line.productId != nil {
            let ok = (productKey == "kitchen")

            if !ok {
                let pid = line.productId.map(String.init) ?? "nil"
              //  print("⏭️ [BONES UI SKIP - STRICT] pid=\(pid) name=\(line.name) productPrinter=\(productKey)")
            } else {
                let pid = line.productId.map(String.init) ?? "nil"
            }

            return ok
        }

        // ✅ If productId is missing, fallback to your old resolve logic (best-effort)
        let resolvedKey = normalizedPrinterKey(resolvePrinter(for: line))
        let ok = (resolvedKey == "kitchen")

        if !ok {
        } else {
        }

        return ok
    }

    var body: some View {
        GeometryReader { geo in
            let pickerHeight: CGFloat = 50     // height of segmented picker row
            let adjustedHeight = geo.size.height - pickerHeight
            let halfHeight = max( adjustedHeight / 2, 150 )    // prevents collapse
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
                let cardWidth = min(boneWidth, availableWidth / CGFloat(maxColumns))

                ZStack {
                    Color.black.ignoresSafeArea()

                    VStack(spacing: 0) {
                        // 🔹 Tab picker
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
                            
                            // Segmented tabs
                            Picker("", selection: $selectedTab) {
                                ForEach(Tab.allCases, id: \.self) { tab in
                                    Text(tab.title).tag(tab)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(maxWidth: .infinity)   // 👈 take all remaining width
                            .layoutPriority(1)
                            
                            Spacer(minLength: 8)
                            
                            // 🔍 Search bar (global for both tabs)
                            HStack(spacing: 8) {
                                Image(systemName: "magnifyingglass")
                                    .foregroundColor(.white.opacity(0.7))
                                
                                ZStack(alignment: .leading) {
                                    if searchText.isEmpty {
                                        Text("חיפוש הזמנה")
                                            .foregroundColor(.white.opacity(0.55))  // 👈 visible placeholder
                                            .padding(.leading, 2)
                                    }
                                    
                                    TextField("", text: $searchText)
                                        .textFieldStyle(.plain)
                                        .foregroundColor(.white)
                                        .accentColor(.white)
                                        .keyboardType(.default)                 // normal keyboard
                                        .textInputAutocapitalization(.never)    // no auto-cap
                                        .autocorrectionDisabled(true)           // iOS 15+ – disable autocorrect & suggestions
                                        .textContentType(.none)
                                        .disableAutocorrection(true)
                                        .textInputAutocapitalization(.never)
                                        .tint(.white)
                                }
                                
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
                            
                            // Station picker (also shared for active & history)
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
                                .frame(width: 130)
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
                        
                        let hasQuery = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        
                        if hasQuery {
                            // ============================
                            // SEARCH MODE: show both active + history results
                            // ============================
                            VStack(alignment: .leading, spacing: 8) {
                                
                                // --- ACTIVE RESULTS (received/ready) ---
                                if !toPrepare.isEmpty || !readyBones.isEmpty {
                                    HStack {
                                        Text("פעיל – תוצאות חיפוש")
                                            .font(.system(size: 18, weight: .bold))
                                            .foregroundColor(.white)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 24)
                                    .padding(.top, 4)
                                    
                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(alignment: .top, spacing: hSpacing) {
                                            // received / בהכנה
                                            ForEach(readySlots.indices, id: \.self) { slotIndex in
                                                if let bone = readySlots[slotIndex] {
                                                    BoneCardView(
                                                        bone: bone,
                                                        slotLabel: "עמדה \(slotIndex + 1)",
                                                        actionTitle: "נאסף",
                                                        actionColor: brandColor,
                                                        maxTicketHeight: bottomMaxTicketHeight,
                                                        action: { markCollectedUI(at: slotIndex) },
                                                        secondaryTitle: "התקשר",
                                                        secondaryAction: { callCustomer(bone) }
                                                    )
                                                    .frame(width: cardWidth)
                                                    .onTapGesture {
                                                        withAnimation(.easeInOut(duration: 0.2)) {
                                                            selectedBone = bone
                                                        }
                                                    }
                                                } else {
                                                    EmptySlotView(index: slotIndex, width: cardWidth)
                                                }
                                            }
                                            // ready (if you want, but it's already flattened into readyBones)
                                            ForEach(readyBones) { bone in
                                                BoneCardView(
                                                    bone: bone,
                                                    slotLabel: nil,
                                                    actionTitle: "פרטים",
                                                    actionColor: brandColor,
                                                    maxTicketHeight: max(topMaxTicketHeight, bottomMaxTicketHeight)
                                                ) {
                                                    withAnimation {
                                                        selectedBone = bone
                                                    }
                                                }
                                                .frame(width: cardWidth)
                                                .onTapGesture {
                                                    withAnimation {
                                                        selectedBone = bone
                                                    }
                                                }
                                            }
                                        }
                                        .padding(.horizontal, horizontalPadding)
                                        .padding(.vertical, 12)
                                    }
                                }
                                
                                // --- HISTORY RESULTS (collected) ---
                                if !historyBones.isEmpty {
                                    HStack {
                                        Text("היסטוריה – תוצאות חיפוש")
                                            .font(.system(size: 18, weight: .bold))
                                            .foregroundColor(.white)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 24)
                                    .padding(.top, 4)
                                    
                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(alignment: .top, spacing: hSpacing) {
                                            ForEach(historyBones) { bone in
                                                BoneCardView(
                                                    bone: bone,
                                                    slotLabel: nil,
                                                    actionTitle: "פרטים",
                                                    actionColor: brandColor,
                                                    maxTicketHeight: max(topMaxTicketHeight, bottomMaxTicketHeight)
                                                ) {
                                                    withAnimation {
                                                        selectedBone = bone
                                                    }
                                                }
                                                .frame(width: cardWidth)
                                                .onTapGesture {
                                                    withAnimation {
                                                        selectedBone = bone
                                                    }
                                                }
                                            }
                                        }
                                        .padding(.horizontal, horizontalPadding)
                                        .padding(.vertical, 12)
                                    }
                                }
                                
                                // --- No results ---
                                if toPrepare.isEmpty && readyBones.isEmpty && historyBones.isEmpty {
                                    Text("אין תוצאות חיפוש")
                                        .font(.system(size: 16))
                                        .foregroundColor(.white.opacity(0.6))
                                        .padding(.horizontal, 24)
                                        .padding(.top, 16)
                                }
                                
                                Spacer()
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            
                        } else if selectedTab == .active {
                            // ============================
                            // ACTIVE TAB (as we had before, with BAR/KITCHEN split)
                            // ============================
                            if selectedStation == .bar {
                                // --- BAR: single full-height row ---
                                VStack(spacing: 0) {
                                    HStack {
                                        Text("פתוחים")
                                            .font(.system(size: 22, weight: .bold))
                                            .foregroundColor(.white)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 24)
                                    .padding(.top, 4)
                                    .padding(.bottom, 4)
                                    
                                    if isLoading && toPrepare.isEmpty && readyBones.isEmpty {
                                        Spacer()
                                        ProgressView().tint(.white)
                                        Spacer()
                                    } else {
                                        ScrollView(.horizontal, showsIndicators: false) {
                                            // all open bones: ready + received
                                            let openBones = (readyBones + toPrepare)
                                                .sorted { $0.orderId > $1.orderId }   // newest first, optional

                                            HStack(alignment: .top, spacing: hSpacing) {
                                                ForEach(openBones) { bone in
                                                    BoneCardView(
                                                        bone: bone,
                                                        slotLabel: nil,
                                                        actionTitle: "מוכן",
                                                        actionColor: brandColor,          // 👈 single brand color
                                                        maxTicketHeight: geo.size.height
                                                    ) {
                                                        markBarReadyAndCollected(bone)   // 👈 new helper
                                                    }
                                                    .frame(width: cardWidth)
                                                    .frame(maxHeight: .infinity)
                                                    .onTapGesture {
                                                        withAnimation(.easeInOut(duration: 0.25)) {
                                                            selectedBone = bone
                                                        }
                                                    }
                                                }
                                            }
                                            .padding(.horizontal, horizontalPadding)
                                            .padding(.vertical, 12)
                                        }
                                    }
                                    
                                    Spacer(minLength: 0)
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                
                            } else {
                                // --- KITCHEN: original 2-row layout ---
                                VStack(spacing: 0) {
                                    // TOP HALF – בהכנה
                                    VStack(spacing: 0) {
                                        HStack {
                                            Text("בהכנה")
                                                .font(.system(size: 22, weight: .bold))
                                                .foregroundColor(.white)
                                            Spacer()
                                        }
                                        .padding(.horizontal, 24)
                                        .padding(.top, 4)
                                        .padding(.bottom, 4)
                                        
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
                                                            maxTicketHeight: topMaxTicketHeight,
                                                            action: {
                                                                // READY (4) – send SMS / notifications
                                                                markReadyUI(bone)
                                                            },
                                                            secondaryTitle: "נאסף",
                                                            secondaryAction: {
                                                                // DIRECT COLLECTED (5)
                                                                markKitchenCollectedDirect(bone)
                                                            }
                                                        )
                                                        .frame(width: cardWidth)
                                                        .onTapGesture {
                                                            withAnimation(.easeInOut(duration: 0.2)) {
                                                                selectedBone = bone
                                                            }
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
                                    
                                    // BOTTOM HALF – מוכן לאיסוף
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
                                            ForEach(readySlots.indices, id: \.self) { slotIndex in
                                                if let bone = readySlots[slotIndex] {
                                                    BoneCardView(
                                                        bone: bone,
                                                        slotLabel: "עמדה \(slotIndex + 1)",
                                                        actionTitle: "נאסף",
                                                        actionColor: brandColor,
                                                        maxTicketHeight: bottomMaxTicketHeight,
                                                        action: { markCollectedUI(at: slotIndex) },
                                                        secondaryTitle: "התקשר",
                                                        secondaryAction: { callCustomer(bone) }
                                                    )
                                                    .frame(width: cardWidth)
                                                    .onTapGesture {
                                                        withAnimation(.easeInOut(duration: 0.2)) {
                                                            selectedBone = bone
                                                        }
                                                    }
                                                } else {
                                                    EmptySlotView(index: slotIndex, width: cardWidth)
                                                }
                                            }
                                        }
                                        .padding(.horizontal, horizontalPadding)
                                        
                                        Spacer()
                                    }
                                    .frame(height: halfHeight)
                                }
                            }
                            
                        } else {
                            // ============================
                            // HISTORY TAB (same as before, just using full height)
                            // ============================
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("הסטוריית הזמנות")
                                        .font(.system(size: 18, weight: .bold))
                                        .foregroundColor(.white)
                                    Spacer()
                                }
                                .padding(.horizontal, 24)
                                .padding(.top, 8)
                                
                                if historyBones.isEmpty {
                                    Text("אין הזמנות בהיסטוריה לעמדה זו")
                                        .font(.system(size: 16))
                                        .foregroundColor(.white.opacity(0.6))
                                        .padding(.horizontal, 24)
                                        .padding(.top, 16)
                                    Spacer()
                                } else {
                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(alignment: .top, spacing: hSpacing) {
                                            ForEach(historyBones) { bone in
                                                BoneCardView(
                                                    bone: bone,
                                                    slotLabel: nil,
                                                    actionTitle: "פרטים",
                                                    actionColor: brandColor,
                                                    maxTicketHeight: geo.size.height
                                                ) {
                                                    withAnimation { selectedBone = bone }
                                                }
                                                .frame(width: cardWidth)
                                                .frame(maxHeight: .infinity)
                                                .onTapGesture {
                                                    withAnimation { selectedBone = bone }
                                                }
                                            }
                                        }
                                        .padding(.horizontal, horizontalPadding)
                                        .padding(.vertical, 12)
                                    }
                                    Spacer()
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    if let t = toastText {
                        VStack {
                            Spacer()
                            Text(t)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(Color.black.opacity(0.75))
                                .clipShape(Capsule())
                                .padding(.bottom, 26)
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    // Overlay only in active tab (or in both, if you like)
                    if let bone = selectedBone {
                        ZStack {
                            Color.black.opacity(0.45)
                                .ignoresSafeArea()
                                .onTapGesture {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        selectedBone = nil
                                    }
                                }

                            VStack {
                                Spacer()
                                InvoiceOverlayView(
                                    bone: bone,
                                    brandColor: brandColor,
                                    onPrint: {
                                        guard let fullOrder = allOrders.first(where: { $0.id == bone.orderId }) else {
                                            return
                                        }

                                        let entriesArray = makeBasketEntries(from: fullOrder)
                                        let total = fullOrder.invoiceItems.reduce(0) { $0 + $1.lineTotal }

                                        let mode: DiningMode = {
                                            if fullOrder.bone.serviceText?.uppercased() == "TA" {
                                                return .takeAway
                                            } else {
                                                return .dineIn
                                            }
                                        }()

                                        let nameSnapshot = fullOrder.bone.customerName

                                        // You may want ticketNumber here – for now this still uses DB id:
                                        Task {
                                            let ok = await PrinterManager.shared.printCashPointSplit(
                                                orderNumber: fullOrder.id,
                                                entries: entriesArray,
                                                total: total,
                                                diningMode: mode,
                                                customerName: nameSnapshot,
                                                customerPhone: nil
                                            )

                                            if !ok {
                                            }
                                        }
                                    },
                                    onResendMessage: {
                                        // 🔁 Re-trigger the same READY status → will resend WA + push
                                        Task {
                                            let ok = await setStatus(orderId: bone.orderId, to: 4, miniAppId: miniAppId)
                                            if !ok {
                                            } else {
                                            }
                                        }
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
            Button("עמדת בר") {
                selectedStation = .bar
                selectedStationRaw = Station.bar.rawValue     // persist
                rebuildBonesFromOrders()
            }

            Button("עמדת מטבח") {
                selectedStation = .kitchen
                selectedStationRaw = Station.kitchen.rawValue // persist
                rebuildBonesFromOrders()
            }
        }
        .onAppear {
            selectedStation = Station(rawValue: selectedStationRaw) ?? .kitchen
            selectedStationRaw = Station.kitchen.rawValue
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
        }

        Task {
            let ok = await setStatus(orderId: bone.orderId, to: 4, miniAppId: miniAppId)
            if !ok {
            }
        }
    }

    private func markCollectedUI(at index: Int) {
        guard readySlots.indices.contains(index),
              let bone = readySlots[index] else { return }

        // 1) Remove from ready slots immediately
        readySlots[index] = nil

        // 2) Update local allOrders status → .collected
        if let orderIndex = allOrders.firstIndex(where: { $0.id == bone.orderId }) {
            let order = allOrders[orderIndex]

            let updated = BoneOrder(
                id: order.id,
                bone: order.bone,
                status: .collected,          // 👈 move to collected
                rawStatus: 5,                // 🆕 (2026-05-10) collected = DB Status=5
                placedAt: order.placedAt,
                stations: order.stations,
                invoiceItems: order.invoiceItems,
                stationItems: order.stationItems,
                lines: order.lines
            )

            allOrders[orderIndex] = updated
        }

        // 3) Rebuild UI lists so it appears in history immediately
        rebuildBonesFromOrders()

        // 4) Tell backend (async, doesn't block UI)
        Task {
            let ok = await setStatus(orderId: bone.orderId, to: 5, miniAppId: miniAppId)
            if !ok {
            }
        }
    }
    private func markBarReadyAndCollected(_ bone: Bone) {
        // 1) Update local model → treat as collected so it jumps to history immediately
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            if let idx = allOrders.firstIndex(where: { $0.id == bone.orderId }) {
                let order = allOrders[idx]

                let updated = BoneOrder(
                    id: order.id,
                    bone: order.bone,
                    status: .collected,      // 👈 go straight to history in UI
                    rawStatus: 5,            // 🆕 (2026-05-10) collected = DB Status=5
                    placedAt: order.placedAt,
                    stations: order.stations,
                    invoiceItems: order.invoiceItems,
                    stationItems: order.stationItems,
                    lines: order.lines
                )

                allOrders[idx] = updated
            }

            // Rebuild lists: removed from toPrepare/readyBones, added to historyBones
            rebuildBonesFromOrders()
        }

        // 2) Backend: first READY (4) so notifications fire, then after 1s mark COLLECTED (5)
        Task {
            let ok4 = await setStatus(orderId: bone.orderId, to: 4, miniAppId: miniAppId)
            if !ok4 {
            } else {
            }

            // wait 1 second
            try? await Task.sleep(nanoseconds: 1_000_000_000)

            let ok5 = await setStatus(orderId: bone.orderId, to: 5, miniAppId: miniAppId)
            if !ok5 {
            } else {
            }
        }
    }
    private func markBarSetReady(_ bone: Bone) {
        // 1) Update local allOrders → status = .ready
        if let idx = allOrders.firstIndex(where: { $0.id == bone.orderId }) {
            let order = allOrders[idx]

            let updated = BoneOrder(
                id: order.id,
                bone: order.bone,
                status: .ready,
                rawStatus: 4,                // 🆕 (2026-05-10) ready = DB Status=4
                placedAt: order.placedAt,
                stations: order.stations,
                invoiceItems: order.invoiceItems,
                stationItems: order.stationItems,
                lines: order.lines
            )

            allOrders[idx] = updated
        }

        // 2) Rebuild lists so this order moves from toPrepare → readyBones
        rebuildBonesFromOrders()

        // 3) Backend: set status 4 (READY) so notifications go out
        Task {
            let ok = await setStatus(orderId: bone.orderId, to: 4, miniAppId: miniAppId)
            if !ok {
            } else {
            }
        }
    }

    private func markBarSetCollected(_ bone: Bone) {
        // 1) Update local allOrders → status = .collected
        if let idx = allOrders.firstIndex(where: { $0.id == bone.orderId }) {
            let order = allOrders[idx]

            let updated = BoneOrder(
                id: order.id,
                bone: order.bone,
                status: .collected,
                rawStatus: 5,                // 🆕 (2026-05-10) collected = DB Status=5
                placedAt: order.placedAt,
                stations: order.stations,
                invoiceItems: order.invoiceItems,
                stationItems: order.stationItems,
                lines: order.lines
            )

            allOrders[idx] = updated
        }

        // 2) Rebuild lists so this order moves from readyBones → historyBones
        rebuildBonesFromOrders()

        // 3) Backend: set status 5 (COLLECTED)
        Task {
            let ok = await setStatus(orderId: bone.orderId, to: 5, miniAppId: miniAppId)
            if !ok {
            } else {
            }
        }
    }
    // MARK: - Rebuild bones arrays from allOrders (show ALL stations, filtered by search)

    private static let bonesTimeWindowMinutes: Int = 120

    private func rebuildBonesFromOrders() {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let stationFilteredBase = allOrders.filter { order in
            let items = order.stationItems[.kitchen] ?? []
            return !items.isEmpty
        }

        let searchFiltered: [BoneOrder]
        if q.isEmpty {
            searchFiltered = stationFilteredBase
        } else {
            searchFiltered = stationFilteredBase.filter { order in
                let idMatch = "\(order.id)".contains(q)
                let nameMatch = order.bone.customerName
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                    .contains(q)
                return idMatch || nameMatch
            }
        }

        func stationBone(from order: BoneOrder) -> Bone {
            var b = order.bone
            b.items = order.stationItems[.kitchen] ?? []
            return b
        }

        // 🆕 (2026-05-10): STRICT 2-state filter by raw DB status.
        //   Active = ONLY rawStatus == 1 (paid). Everything else (rawStatus 0,
        //   2, 3, 4, 5, etc.) → History. No time filter on either side.
        //   Replaces the previous 3-bucket model (received/ready/collected with
        //   time-windowed history) which broke after the server clock change.
        let active = searchFiltered
            .filter { $0.rawStatus == 1 }
            .sorted { $0.id > $1.id }

        let history = searchFiltered
            .filter { $0.rawStatus != 1 }
            .sorted { $0.id > $1.id }

        toPrepare = active.map { stationBone(from: $0) }

        // readySlots is now empty — no orders are categorized as "ready slot"
        // anymore (Status=4 goes to history per new spec).
        readySlots = Array(repeating: nil, count: 5)
        readyBones = []

        historyBones = history.map { stationBone(from: $0) }

        // 🆕 (2026-05-10): print logs to verify what landed where
        print("[Bones-rebuild] allOrders=\(allOrders.count) stationFiltered=\(stationFilteredBase.count) searchFiltered=\(searchFiltered.count) searchQuery=\(q.isEmpty ? "<empty>" : q)")
        print("[Bones-rebuild] ACTIVE: count=\(active.count) ids=\(active.map(\.id)) (rawStatus==1 only)")
        print("[Bones-rebuild] HISTORY: count=\(history.count) ids=\(history.map(\.id)) (rawStatus != 1, NO time filter)")
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
        let ticketNumber: Int?
        let source: String
        let bucket: String
        let stage: String
        let placedAt: Date
        let scheduledFor: Date?
        let customerName: String
        let customerDisplayName: String?
        let customerPhone: String?          // ✅ NEW
        let totalGBP: Double
        let itemSummary: String
        let isDelivery: Bool
        let shortCode: String?
        let lines: [BonesLineDTO]
        let status: Int?

        // existing extras
        let currency: String?
        let service: String?
        let paymentMethod: String?

        enum CodingKeys: String, CodingKey {
            case id, ticketNumber, source, bucket, stage, placedAt, scheduledFor,
                 customerName, customerDisplayName, customerPhone, totalGBP, itemSummary,
                 isDelivery, shortCode, lines, status
            case Status = "Status"
            case currency
            case service
            case paymentMethod
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)

            id           = try c.decode(Int.self, forKey: .id)
            ticketNumber = try c.decodeIfPresent(Int.self, forKey: .ticketNumber)
            source       = try c.decode(String.self, forKey: .source)
            bucket       = try c.decode(String.self, forKey: .bucket)
            stage        = try c.decode(String.self, forKey: .stage)
            placedAt     = try c.decode(Date.self, forKey: .placedAt)
            scheduledFor = try c.decodeIfPresent(Date.self, forKey: .scheduledFor)

            customerName        = try c.decode(String.self, forKey: .customerName)
            customerDisplayName = try c.decodeIfPresent(String.self, forKey: .customerDisplayName)
            customerPhone       = try c.decodeIfPresent(String.self, forKey: .customerPhone)

            totalGBP     = try c.decode(Double.self, forKey: .totalGBP)
            itemSummary  = try c.decode(String.self, forKey: .itemSummary)
            isDelivery   = try c.decode(Bool.self, forKey: .isDelivery)
            shortCode    = try c.decodeIfPresent(String.self, forKey: .shortCode)
            lines        = try c.decode([BonesLineDTO].self, forKey: .lines)

            // status fallback logic (kept exactly)
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

            currency      = try c.decodeIfPresent(String.self, forKey: .currency)
            service       = try c.decodeIfPresent(String.self, forKey: .service)
            paymentMethod = try c.decodeIfPresent(String.self, forKey: .paymentMethod)
        }
    }
    
    private func markKitchenCollectedDirect(_ bone: Bone) {
        // 1) Remove from toPrepare
        if let idx = toPrepare.firstIndex(of: bone) {
            toPrepare.remove(at: idx)
        }

        // 2) Also remove from readyBones / slots if it happens to be there
        if let idx = readyBones.firstIndex(of: bone) {
            readyBones.remove(at: idx)
        }
        for i in readySlots.indices {
            if readySlots[i]?.orderId == bone.orderId {
                readySlots[i] = nil
            }
        }

        // 3) Update local allOrders → status = .collected
        if let orderIndex = allOrders.firstIndex(where: { $0.id == bone.orderId }) {
            let order = allOrders[orderIndex]

            let updated = BoneOrder(
                id: order.id,
                bone: order.bone,
                status: .collected,
                rawStatus: 5,                // 🆕 (2026-05-10) collected = DB Status=5
                placedAt: order.placedAt,
                stations: order.stations,
                invoiceItems: order.invoiceItems,
                stationItems: order.stationItems,
                lines: order.lines
            )

            allOrders[orderIndex] = updated
        }

        // 4) Rebuild UI so it moves to history
        rebuildBonesFromOrders()

        // 5) Backend: status 5 (COLLECTED)
        Task {
            let ok = await setStatus(orderId: bone.orderId, to: 5, miniAppId: miniAppId)
            if !ok {
            } else {
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
        stationFromPrinter(resolvePrinter(for: line))
    }

    private func mapOrder(_ dto: BonesOrderDTO) -> BoneOrder {
        // Map overall status
        
        let rawStatus = dto.status ?? 0
        let status: BoneOrderStatus = {
            switch rawStatus {
            case 4:  return .ready
            case 5:  return .collected
            default: return .received
            }
        }()
        print("[Bones] order #\(dto.id) rawStatus=\(rawStatus) mapped=\(status == .received ? "received" : status == .ready ? "ready" : "collected")")

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
        df.timeZone = TimeZone(identifier: "Asia/Jerusalem") ?? .current
        df.dateFormat = "HH:mm   dd/MM/yyyy"
        let timeText = df.string(from: dto.placedAt)

        // Service text (TA or sit)
        // Service text (TA / delivery etc.) based on dto.service
        let serviceText: String? = {
            let raw = dto.service?.lowercased() ?? ""

            if raw == "ta" || raw == "takeaway" {
                return "TA"
            }

            // If you ever want a label for delivery:
            if dto.isDelivery {
                return "DELIVERY"
            }

            // Sit-in → no label
            return nil
        }()

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

            // ✅ HARD FILTER: kitchen lines only
            guard isKitchenLine(l) else { continue }

            let qty = max(l.qty, 1)

            let modsRaw = l.modifiers ?? ""
            let separators = CharacterSet(charactersIn: "•·")
            let modifierParts = modsRaw
                .components(separatedBy: separators)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            let hasSizeWord = modsRaw.contains("גודל")
            let baseName = l.name.trimmingCharacters(in: .whitespacesAndNewlines)

            let adjustedName: String = {
                if baseName == "אספרסו", !hasSizeWord { return "אספרסו קצר" }
                if baseName == "הפוך",   !hasSizeWord { return "הפוך קטן" }
                return baseName
            }()

            let entry = RawEntry(name: adjustedName, qty: qty, modifiers: modifierParts)

            rawEntriesAll.append(entry)
            rawEntriesByStation[.kitchen, default: []].append(entry)  // ✅ only kitchen
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
        stationItems[.kitchen] = buildItemLines(from: mergedKitchen)
        stationItems[.bar] = []   // ✅ keep empty so nothing leaks

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
        let stationsSet: Set<Station> = mergedKitchen.isEmpty ? [] : [.kitchen]

        // Default bone items = full order (used for e.g. invoice overlay if you want)
        let boneAllItems = buildItemLines(from: mergedKitchen)
        let displayNumber = dto.ticketNumber ?? dto.id

        let bone = Bone(
            id: dto.id,   // 👈 stable
            orderId: dto.id,
            orderNumber: String(displayNumber),
            customerName: displayName.replacingOccurrences(of: "Customer", with: ""),
            customerPhone: dto.customerPhone, items: boneAllItems,
            timeText: timeText,
            serviceText: serviceText
        )
        return BoneOrder(
            id: dto.id,
            bone: bone,
            status: status,
            rawStatus: rawStatus,                 // 🆕 (2026-05-10): keep raw DB status
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

        // 🚫 Cache-bust: append a millisecond timestamp so any intermediary
        //    (CDN, NSURLCache, server-side response cache) treats every poll
        //    as a unique request. Without this, bones would occasionally
        //    show yesterday's orders because a stale cached response was
        //    being served back to the iPad.
        let ts = Int(Date().timeIntervalSince1970 * 1000)
        guard let url = URL(string: "\(baseURL)?miniAppId=\(miniAppId)&_ts=\(ts)") else {
            return
        }

        var req = URLRequest(url: url, timeoutInterval: 15)
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        req.setValue("no-cache", forHTTPHeaderField: "Pragma")

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                return
            }
            guard http.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
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

            let rawValue = String(raw.dropFirst("MOD:".count)).trimmingCharacters(in: .whitespaces)

            // NEW: strip title before colon → keep only the value
            if let colonIndex = rawValue.firstIndex(of: ":") {
                let afterColon = rawValue[rawValue.index(after: colonIndex)...]
                displayText = afterColon.trimmingCharacters(in: .whitespaces)
            } else {
                displayText = rawValue
            }
        }else {
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

    // 👇 NEW – optional secondary button
    var secondaryTitle: String? = nil
    var secondaryAction: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 8) {
            if let slotLabel {
                Text(slotLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .trailing, spacing: 6) {
                    if bone.serviceText?.uppercased() == "TA" {
                        Text("** TA **")
                            .font(.system(size: 24, weight: .heavy, design: .monospaced))
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.bottom, 4)
                    }

                    let name = bone.customerName.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "Customer", with: "")
                    Text(name.isEmpty ? "שם לקוח" : name)
                        .font(.system(size: 24, weight: .bold, design: .monospaced))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .multilineTextAlignment(.center)

                    Text("#\(bone.orderNumber)")
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .multilineTextAlignment(.center)

                    Text(bone.timeText)
                        .font(.system(size: 16, weight: .regular, design: .monospaced))
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
                                    .font(.system(size: 20, weight: .regular, design: .monospaced))
                                    .foregroundColor(.black.opacity(1.0))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .multilineTextAlignment(.leading)
                                    .padding(.leading, 25)
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

            // 👇 NEW: one or two buttons horizontally
            if let secondaryTitle, let secondaryAction {
                HStack(spacing: 8) {
                    Button(action: action) {
                        Text(actionTitle)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 35)
                            .background(actionColor)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }

                    Button(action: secondaryAction) {
                        Text(secondaryTitle)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 35)
                            .background(Color.gray.opacity(0.9))
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
            } else {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 35)
                        .background(actionColor)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
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
    let onResendMessage: () -> Void    // 👈 NEW
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
                    if bone.serviceText?.uppercased() == "TA" {
                        Text("** TA **")
                            .font(.system(size: 28, weight: .heavy, design: .monospaced))
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.bottom, 6)
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
                // Print ticket
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

                // 🔁 Resend message (same status → WA + push again)
                Button {
                    onResendMessage()
                    onClose()
                } label: {
                    Text("שלח הודעה שוב")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color(.secondarySystemBackground))
                        .foregroundColor(.primary)
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
        customerPhone: bone.customerPhone,   // ✅ ADD THIS
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
