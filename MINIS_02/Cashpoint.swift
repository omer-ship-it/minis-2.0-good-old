import SwiftUI
import UniformTypeIdentifiers
import Kingfisher



struct CashPointView: View {
    @AppStorage("cashpointID") private var cashpointIDRaw: Int = 2

    var cashpointID: CashpointID {
        CashpointID(rawValue: cashpointIDRaw) ?? .one
    }
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
    @StateObject private var stockToggles = StockToggleStore(
        shopId: 12   // 👈 hard-coded miniAppId
    )
    @State private var showPrintSuccess = false
    @State private var stockText: [Int: String] = [:]   // productId -> "typed value"
    @State private var printSuccessScale: CGFloat = 0.6
    @State private var printSuccessOpacity: Double = 0
    @State private var unpaidOrderId: Int? = nil
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
            // Fallback: if somehow we don't know the original order, go to payment
            if isPhoneLayout {
                showBasketSheetPhone = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    showOrderFlow = true
                }
            } else {
                showOrderFlow = true
            }
            return
        }

        // Snapshot current basket
        let previousLocked = lockedLineIds
        let entriesArray = Array(basket.values)

        // Only new lines: those NOT in previousLocked
        let newEntries = entriesArray.filter { !previousLocked.contains($0.id) }
        guard !newEntries.isEmpty else {
            return
        }

        let total      = finalTotal
        let newTotal   = newEntries.reduce(0.0) { $0 + Double($1.quantity) * $1.unitPrice }
        let mode       = diningMode

        let nameSnapshot: String? =
            posSavedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : posSavedName.trimmingCharacters(in: .whitespacesAndNewlines)

        let phoneSnapshot: String? =
            posSavedPhone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : posSavedPhone.trimmingCharacters(in: .whitespacesAndNewlines)

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
            customerName: nameSnapshot
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
            zcreditMeta: nil
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
    @State private var showOrdersAdmin = false
    @State private var showServiceStep: Bool = true
    @State private var expandedBasketLineId: Int? = nil
    @State private var noteDrafts: [Int: String] = [:]
    @State private var optionSelections: [Int: [String: String]] = [:]   // lineId -> [groupTitle: optionName]
    @State private var additionSelections: [Int: Set<String>] = [:]      // lineId -> Set<additionName>
    
  
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
        if isPayLaterMode && hasAddedLinesInPayLater {
            return isRtl ? "שלח הזמנה" : "Print order"
        } else if isPayLaterMode {
            return isRtl ? "תשלום" : "Pay"
        } else {
            return isRtl ? "הזמנה" : "Order"
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
    @ViewBuilder
    private func basketPanel(inline: Bool) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(isRtl ? "הזמנה" : "Order")
                    .font(.system(size: 20, weight: .bold))

                HStack {
                    Button {
                        withAnimation {
                            if showDiscountPanel {
                                // close & reset
                                showDiscountPanel   = false
                                discountMode        = .none
                                discountAllSelected = true
                                discountedLineIds.removeAll()
                                customDiscountText  = ""
                                customIsPercentage  = false
                            } else if !basket.isEmpty {
                                // open & init
                                showDiscountPanel   = true
                                showExcludePanel    = false
                                discountMode        = .ten      // default to 10%
                                discountAllSelected = true
                                discountedLineIds   = Set(basket.keys)
                                customDiscountText  = ""
                                customIsPercentage  = false
                            }
                        }
                    } label: {
                        Text(isRtl ? "הנחה" : "Discount")
                            .font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color(.systemGray5))
                            .clipShape(Capsule())
                    }
                    .disabled(basket.isEmpty)

                    Button {
                        withAnimation {
                            if showExcludePanel {
                                showExcludePanel    = false
                                excludeAllSelected  = false
                                excludedLineIds.removeAll()
                            } else if !basket.isEmpty {
                                showExcludePanel    = true
                                showDiscountPanel   = false
                                excludeAllSelected  = false
                                excludedLineIds.removeAll()
                            }
                        }
                    } label: {
                        Text(isRtl ? "OTH" : "OTH")
                            .font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color(.systemGray5))
                            .clipShape(Capsule())
                    }
                    .disabled(basket.isEmpty)
                }
                .padding(.leading, 10)

                Spacer()

                if basketTotalQuantity > 0 {
                    Text(isRtl ? "\(basketTotalQuantity) פריטים" : "\(basketTotalQuantity) items")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
                }
            }
            .padding(16)

            // 🔻 DISCOUNT PANEL
            if showDiscountPanel {
                VStack(spacing: 8) {
                    // Discount type pills (first = Cancel)
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
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color(.systemGray6))
                                .foregroundColor(.primary)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)

                        discountPill(title: "10%", mode: .ten)
                        discountPill(title: "15%", mode: .fifteen)
                        discountPill(title: "30%", mode: .thirteen)
                        discountPill(title: isRtl ? "אחר" : "Other", mode: .custom)

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
                                    Button {
                                        customIsPercentage = false
                                    } label: {
                                        Text(isRtl ? "סכום" : "Amount")
                                            .font(.system(size: 13, weight: .semibold))
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 4)
                                            .background(customIsPercentage ? Color(.systemGray6) :.black)
                                            .foregroundColor(customIsPercentage ? .primary : .white)
                                            .clipShape(Capsule())
                                    }
                                    .buttonStyle(.plain)

                                    Button {
                                        customIsPercentage = true
                                    } label: {
                                        Text("%")
                                            .font(.system(size: 13, weight: .semibold))
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 4)
                                            .background(customIsPercentage ?.black : Color(.systemGray6))
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
                            discountedLineIds = Set(basket.keys)
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
                                discountedLineIds   = Set(basket.keys)
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

            // 🔻 OTH / EXCLUDE PANEL
            if showExcludePanel {
                VStack(spacing: 8) {
                    Button {
                        excludeAllSelected.toggle()
                        if excludeAllSelected {
                            excludedLineIds = Set(basket.keys)
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
                                excludedLineIds    = Set(basket.keys)
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
                        withAnimation {
                            showExcludePanel = false
                        }
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

            if isPayLaterMode {
                // 🔹 Pay-later header: New order + unpaid order title
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        startNewOrderFromPayLater()
                    } label: {
                        Text("הזמנה חדשה")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(.black)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }

                    if !currentUnpaidOrderTitle.isEmpty {
                        Text(currentUnpaidOrderTitle)
                                       .font(.system(size: 26, weight: .heavy))
                                       .foregroundColor(.primary)
                                       .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 4)
                .padding(.bottom, 10)

            } else {
                // 🔹 Normal mode: dine-in / take-away picker
                Picker("", selection: $diningMode) {
                    Text(isRtl ? "לשבת" : "Dine in")
                        .tag(DiningMode.dineIn)
                    Text(isRtl ? "לקחת" : "Take away")
                        .tag(DiningMode.takeAway)
                }
                .pickerStyle(.segmented)
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
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                       VStack(spacing: 12) {
                           ForEach(basketSections()) { section in
                               // ⏰ Header – only if we have a server time
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
            }

            Spacer()

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

                Button {
                    guard !basket.isEmpty else { return }

                    if isPayLaterMode && hasAddedLinesInPayLater {
                        // unpaid + added items → print/update existing order
                        printUpdatedUnpaidOrder()
                    } else {
                        // normal / unpaid-without-additions → go to payment
                        if inline {
                            showOrderFlow = true
                        } else {
                            showBasketSheetPhone = false
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                showOrderFlow = true
                            }
                        }
                    }

                } label: {
                    Text(mainActionButtonTitle)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(basket.isEmpty ? Color.gray.opacity(0.4) : .black)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .disabled(basket.isEmpty)
                .padding()
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
    
    struct ServiceModeView: View {
        let isRtl: Bool
        let onSelect: (DiningMode) -> Void
        let onOrdersTap: () -> Void

        var body: some View {
            GeometryReader { geo in
                let isCompact = geo.size.width < 600

                let horizontalPadding: CGFloat = 24
                let spacing: CGFloat = 16

                let buttonWidth: CGFloat = {
                    if isCompact {
                        return (geo.size.width - horizontalPadding * 2 - spacing) / 2
                    } else {
                        return 220
                    }
                }()

                ZStack {
                    Color(hex: "#D2C1A5")
                        .ignoresSafeArea()

                    // 🔹 MAIN CENTERED CONTENT
                    VStack {
                        Spacer()

                        VStack(spacing: 24) {
                            KFImage(URL(string: "https://beithaam.com/wp-content/uploads/2024/12/share.jpg"))
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: 260)
                                .cornerRadius(16)
                                .padding(.bottom, 0)
                                .padding(.top, -180)

                            Text(isRtl ? "איך תרצה להזמין?" : "How would you like to dine?")
                                .font(.system(size: 26, weight: .bold))
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .foregroundColor(Color(hex: "#324E57"))

                            HStack(spacing: spacing) {
                                Button {
                                    onSelect(.dineIn)
                                } label: {
                                    Text(isRtl ? "לשבת" : "Dine in")
                                        .font(.system(size: 18, weight: .bold))
                                        .foregroundColor(.white)
                                        .frame(width: buttonWidth, height: 56)
                                        .background(Color(hex: "#324E57"))
                                        .clipShape(
                                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        )
                                }

                                Button {
                                    onSelect(.takeAway)
                                } label: {
                                    Text(isRtl ? "לקחת" : "Take away")
                                        .font(.system(size: 18, weight: .bold))
                                        .foregroundColor(.white)
                                        .frame(width: buttonWidth, height: 56)
                                        .background(Color(hex: "#324E57"))
                                        .clipShape(
                                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        )
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .center)
                        }
                        .padding(.horizontal, horizontalPadding)
                        .frame(maxWidth: .infinity, alignment: .center)

                        Spacer()
                    }

                    // 🔹 "הזמנות" BUTTON – ALWAYS VISUAL RIGHT
                    VStack {
                        Spacer()
                        HStack {
                              // push button to the right edge (visual)
                            Button {
                                
                                onOrdersTap()
                            } label: {
                                HStack {
                                    Image(systemName: "list.bullet.rectangle")
                                    Text("הזמנות")
                                        .font(.system(size: 16, weight: .semibold))
                                }
                                .padding(.horizontal, 10)
                                .foregroundColor(Color(hex: "#324E57"))
                                .padding(.vertical, 8)
                                .frame(width: 190, height: 48, alignment: .center)
                               
                                .clipShape(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                )
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                    }
                }
            }
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
            modifierGroups: groupDrafts
        )
    }
    
    private var requiresPhoneStep: Bool {
        basket.values.contains { entry in
            let name = entry.item.name
            return name.contains("סלט") || name.contains("טוסט")  || name.contains("מוזלי")
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
                description: draft.description.isEmpty ? nil : draft.description
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
                description: draft.description
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
        let includedIds: Set<Int>
        if discountAllSelected {
            includedIds = Set(basket.keys)
        } else {
            includedIds = discountedLineIds
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

    
    private let productColumns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    private var categories: [String] {
        var ordered: [String] = []
        var seen = Set<String>()
        for item in api.items where !seen.contains(item.category) {
            seen.insert(item.category)
            ordered.append(item.category)
        }
        if !ordered.contains("✏️ הערות") {
            ordered.append("✏️ הערות")
        }
        return ordered
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
                    name: "הערה לוטרינה",   // 👈 NEW bakery note
                    price: 0,
                    category: "✏️ הערות",
                    modifiers: nil,
                    imageURL: nil,
                    description: nil
                )
            ]
        }

        return api.items.filter { $0.category == selectedCategory }
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
        // Exit pay-later context and start fresh
        isPayLaterMode = false
        unpaidOrderId = nil
        lockedLineIds.removeAll()
        lineSessionTime.removeAll()

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
        showServiceStep = true
    }
    private var currentUnpaidOrderTitle: String {
        guard let oid = unpaidOrderId else { return "" }

        let cleanName = posSavedName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "Customer", with: "")

        if cleanName.isEmpty {
            return "הזמנה \(oid)"
        } else {
            return "הזמנה \(oid) \(cleanName)"
        }
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
        // 1) If search is active → global search, ignore categories
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            let q = query
                .folding(options: .diacriticInsensitive, locale: .current)
                .lowercased()

            return api.items.filter { item in
                item.name
                    .folding(options: .diacriticInsensitive, locale: .current)
                    .lowercased()
                    .contains(q)
            }
        }

        // 2) No search → regular category behaviour
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
                    name: "הערה לוטרינה",   // 👈 NEW bakery note
                    price: 0,
                    category: "✏️ הערות",
                    modifiers: nil,
                    imageURL: nil,
                    description: nil
                )
            ]
        }

        return api.items.filter { $0.category == selectedCategory }
    }
    
    @ViewBuilder
    private func posSheet(for item: ShellMenuItem) -> some View {
        let lineId = editingLineId
        let entry = lineId.flatMap { basket[$0] }

        let initialQty = entry?.quantity ?? 1
        let initialOptions = optionsFromSubtitle(entry?.subtitle)
        let isUpdate = (entry != nil)

        // max quantity allowed for this product
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
            isUpdate: isUpdate,
            maxQuantity: remainingForItem
        ) { product, quantity, subtitle, unitPrice in
            if let lineId = lineId {
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
            } else {
                addToBasket(item: product,
                            quantity: quantity,
                            subtitle: subtitle,
                            unitPrice: unitPrice)
            }
            editingLineId = nil
        }
    }
    
    @ViewBuilder
    private func discountPill(title: String, mode: DiscountMode) -> some View {
        let isSelected = (discountMode == mode)
        Button {
            discountMode = mode
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
                                    Text(isRtl ? "קופה" : "Cash Point")
                                        .font(.system(size: 22, weight: .semibold))
                                    
                                    Spacer()
                                    
                                    Button {
                                        isStockEditMode.toggle()
                                        if isStockEditMode {
                                            stockEditWorkItem?.cancel()
                                            stockEditWorkItem = nil
                                            editingStockProductId = nil
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
                                
                                // Row 2: Search + compact "+"
                                HStack(spacing: 10) {
                                    HStack(spacing: 8) {
                                        Image(systemName: "magnifyingglass")
                                            .foregroundColor(.secondary)
                                        
                                        TextField(isRtl ? "חיפוש מוצר…" : "Search product…", text: $searchText)
                                            .textInputAutocapitalization(.none)
                                            .autocorrectionDisabled()
                                            .focused($isSearchFocused)
                                        
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
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                    
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
                                Text(isRtl ? "קופה" : "Cash Point")
                                    .font(.system(size: 22, weight: .semibold))
                                
                                
                                // Spacer before search
                                Spacer()
                                    .frame(maxWidth: 100)
                                
                                // Search field roughly aligned with the middle products column
                                HStack(spacing: 8) {
                                    Image(systemName: "magnifyingglass")
                                        .foregroundColor(.secondary)
                                    
                                    TextField(isRtl ? "חיפוש מוצר…" : "Search product…", text: $searchText)
                                        .textInputAutocapitalization(.none)
                                        .autocorrectionDisabled()
                                        .multilineTextAlignment(.leading)
                                        .focused($isSearchFocused)
                                    
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
                                
                                // Stock mode toggle
                                Button {
                                    isStockEditMode.toggle()
                                    if isStockEditMode {
                                        stockEditWorkItem?.cancel()
                                        stockEditWorkItem = nil
                                        editingStockProductId = nil
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
                        CashCategoryRail(
                            categories: categories,
                            selected: selectedCategory,
                            onTap: { cat in
                                searchText = ""
                                isSearchFocused = false
                                selectedCategory = cat
                            },
                            onOrdersTap: {
                                //showOrdersAdmin = true
                                showOrdersAdmin = true
                            }
                        )
                        .frame(width: 190)
                        Divider()
                        
                        GeometryReader { geo in
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
                                        
                                        let swipeOffset = productSwipeOffsets[item.id] ?? 0    // 👈 NEW
                                        
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
                                                
                                                withAnimation(.spring(response: 0.18,
                                                                      dampingFraction: 0.6,
                                                                      blendDuration: 0.1)) {
                                                    tappedProductId = item.id
                                                }
                                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                                    withAnimation(.spring(response: 0.25,
                                                                          dampingFraction: 0.7,
                                                                          blendDuration: 0.1)) {
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
                                                // Force RTL for EVERYTHING in the menu
                                                Group {
                                                    if selectedCategory != "הודעות" {
                                                        
                                                        // Stock toggle
                                                        if isOut {
                                                            Button("החזר למלאי") {
                                                                stockToggles.binding(for: item.id).wrappedValue = true
                                                            }
                                                        } else {
                                                            Button("חסר במלאי") {
                                                                stockToggles.binding(for: item.id).wrappedValue = false
                                                            }
                                                        }
                                                        
                                                        Divider()
                                                        
                                                        // Stock editor
                                                        Button("עדכן מלאי") {
                                                            editingStockProductId = item.id
                                                            if !isStockEditMode {
                                                                restartStockEditTimer()
                                                            }
                                                        }
                                                        
                                                        Divider()
                                                        
                                                        // Product editor (NO ICON)
                                                        Button("ערוך מוצר") {
                                                            adminDraft = makeAdminDraft(from: item)
                                                        }
                                                    }
                                                }
                                                .environment(\.layoutDirection, .rightToLeft)   // ← THE MAGIC
                                            }
                                            
                                            // 🔹 STOCK UI (unchanged)
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

                                                    // 👇 NEW: editable stock text when editing this product
                                                    if editingStockProductId == item.id {
                                                        TextField(
                                                            "∞",
                                                            text: Binding(
                                                                get: {
                                                                    if let existing = stockText[item.id] {
                                                                        return existing
                                                                    }
                                                                    if let current = remainingStock(for: item) {
                                                                        return String(current)
                                                                    }
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
                                                        .frame(width: 40)
                                                        .padding(.horizontal, 4)
                                                        .padding(.vertical, 4)
                                                        .background(Color(.systemGray6))
                                                        .cornerRadius(6)
                                                    } else {
                                                        // normal read-only label
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
                                        .offset(x: swipeOffset)
                                        .simultaneousGesture(
                                            DragGesture(minimumDistance: 10)
                                                .onChanged { value in
                                                    dismissKeyboard()
                                                    
                                                    let dx = value.translation.width
                                                    let dy = value.translation.height
                                                    let horizontal = abs(dx)
                                                    let vertical = abs(dy)
                                                    let horizontalThreshold: CGFloat = 28   // how much horizontal before we treat as swipe
                                                    
                                                    // Only start treating as swipe if it's clearly horizontal
                                                    guard horizontal > horizontalThreshold,
                                                          horizontal > vertical else {
                                                        productSwipeOffsets[item.id] = 0   // let ScrollView handle vertical drags
                                                        swipingProductId = nil
                                                        return
                                                    }
                                                    
                                                    // Mark this product as being swiped so tap doesn't fire
                                                    swipingProductId = item.id
                                                    
                                                    // Normalize direction:
                                                    // dir = +1 → LTR forward, dir = -1 → RTL forward (right→left)
                                                    let dir: CGFloat = isRtl ? -1 : 1
                                                    productSwipeOffsets[item.id] = dx * dir
                                                }
                                                .onEnded { value in
                                                    let dx = value.translation.width
                                                    let dy = value.translation.height
                                                    let horizontal = abs(dx)
                                                    let vertical = abs(dy)
                                                    let horizontalThreshold: CGFloat = 28
                                                    let dir: CGFloat = isRtl ? -1 : 1
                                                    
                                                    defer {
                                                        // reset swipe tracking
                                                        swipingProductId = nil
                                                    }
                                                    
                                                    // If gesture wasn't clearly horizontal enough, just reset
                                                    guard horizontal > horizontalThreshold,
                                                          horizontal > vertical else {
                                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                                            productSwipeOffsets[item.id] = 0
                                                        }
                                                        return
                                                    }
                                                    
                                                    let translated = dx * dir        // normalized: >0 = forward, <0 = backward
                                                    let commitThreshold: CGFloat = 40
                                                    
                                                    let canAdd = (maxAdditionalQuantity(for: item) ?? 1) > 0 &&
                                                    !isOut &&
                                                    selectedCategory != "✏️ הערות"
                                                    
                                                    let qtyInBasket = quantityInBasket(for: item)
                                                    let canRemove = qtyInBasket > 0
                                                    
                                                    if translated > commitThreshold, canAdd {
                                                        // ✅ FORWARD SWIPE → ADD ONE
                                                        withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                                                            productSwipeOffsets[item.id] = 200 * dir
                                                        }
                                                        
                                                        Haptics.light()
                                                        
                                                        addToBasket(
                                                            item: item,
                                                            quantity: 1,
                                                            subtitle: nil,
                                                            unitPrice: item.price
                                                        )
                                                        
                                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                                                productSwipeOffsets[item.id] = 0
                                                            }
                                                        }
                                                        
                                                    } else if translated < -commitThreshold, canRemove {
                                                        // ✅ BACKWARD SWIPE → REMOVE ONE FROM LAST ADDED
                                                        withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                                                            productSwipeOffsets[item.id] = -200 * dir
                                                        }
                                                        
                                                        Haptics.light()
                                                        
                                                        removeOneFromLastLine(of: item)
                                                        
                                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                                                productSwipeOffsets[item.id] = 0
                                                            }
                                                        }
                                                        
                                                    } else {
                                                        // Not far enough → reset
                                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                                            productSwipeOffsets[item.id] = 0
                                                        }
                                                    }
                                                }
                                        )
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
                                                    sendReorderToServer(
                                                        movedId: movedId,
                                                        newIndex: newIndex,
                                                        category: cat
                                                    )
                                                }
                                            )
                                        )
                                    }
                                }
                                .padding(16)
                            }
                        }
                        .frame(maxWidth: .infinity)
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
                                
                                let item = ShellMenuItem(
                                    id: Int.random(in: -9000 ... -8000),
                                    name: name,
                                    price: price,
                                    category: "הערות",
                                    modifiers: nil,
                                    imageURL: nil,
                                    description: nil
                                )
                                
                                addToBasket(
                                    item: item,
                                    quantity: 1,
                                    subtitle: text,
                                    unitPrice: price
                                )
                                
                                messageTargetIsKitchen = false
                                messageTargetIsBakery = false
                            }
                        }
                        
                        Divider()
                        
                        if !isPhone && !isStockEditMode {
                            Divider()
                            basketPanel(inline: true)
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
                if showPrintSuccess {
                    ZStack {
                        Color.black.opacity(0.35)
                            .ignoresSafeArea()
                        
                        VStack(spacing: 16) {
                            ZStack {
                                Circle()
                                    .fill(Color.green)
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
            .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
            
            .fullScreenCover(isPresented: $showServiceStep) {
                ServiceModeView(
                    isRtl: isRtl,
                    onSelect: { mode in
                        diningMode = mode
                        showServiceStep = false
                    },
                    onOrdersTap: {
                        showServiceStep = false
                        DispatchQueue.main.async {
                            showOrdersAdmin = true
                        }
                    }
                )
                .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
            }
           // .transaction { $0.disablesAnimations = true }
            .onAppear {
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
            .fullScreenCover(isPresented: $showOrdersAdmin) {
                OrdersHostView(
                    onSelectUnpaid: { unpaidOrder in
                        // From AdminOrdersView → restore unpaid to basket
                        restoreUnpaidOrder(unpaidOrder)
                        showOrdersAdmin = false
                    },
                    onRefundFromBone: { bone in
                        // From DigitalBonesView → refund into current basket
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
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button(isRtl ? "סגור" : "Close") {
                                    showBasketSheetPhone = false
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
                if !showOrderFlow && basket.isEmpty {
                    api.load(skipCache: true)
                }
            }
            .fullScreenCover(isPresented: $showOrderFlow) {
                OrderFlowView(
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
                    onCompleted: { phone, name, summary in
                        completeOrder(
                            customerPhone: phone,
                            customerName: name,
                            paymentSummary: summary
                        )
                        if let first = categories.first {
                            selectedCategory = first
                        }
                    },
                    // 👇 NEW
                    allowPayLater: (!isPayLaterMode) || hasAddedLinesInPayLater
                )
            }
            .sheet(item: $adminDraft) { draft in
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
                let items = api.items

                var initialStatus: [Int: Int] = [:]
                var initialAdjustments: [Int: Int] = [:]

                for item in items {
                    let statusValue: Int
                    if let s = item.status {
                        statusValue = s
                    } else if let q = item.stockQuantity, q <= 0 {
                        statusValue = 0
                    } else {
                        statusValue = 1
                    }
                    initialStatus[item.id] = statusValue

                    if let q = item.stockQuantity, q > 0 {
                        initialAdjustments[item.id] = q
                    }
                }

                // ✅ sync ON/OFF immediately
                stockToggles.applyServerStatus(initialStatus)

                // ✅ ALWAYS overwrite local stock map with server values
                stockAdjustments = initialAdjustments

                if selectedCategory.isEmpty, let firstCat = items.first?.category {
                    selectedCategory = firstCat
                }
            }
        }
    }

    private func completeOrder(
        customerPhone: String?,
        customerName: String?,
        paymentSummary: OrderAPI.PaymentSummary?
    ) {
        guard !basket.isEmpty else {
            showOrderFlow = false
            return
        }

        // Persist last used contact details
        if let phone = customerPhone, !phone.isEmpty {
            UserDefaults.standard.set(phone, forKey: "posCustomerPhone")
        }
        if let name = customerName, !name.isEmpty {
            UserDefaults.standard.set(name, forKey: "posCustomerName")
        }

        // 🔄 Reset discount / OTH state so next order starts clean
        showDiscountPanel   = false
        discountMode        = .none
        discountAllSelected = true
        discountedLineIds.removeAll()
        customDiscountText  = ""

        showExcludePanel    = false
        excludeAllSelected  = false
        excludedLineIds.removeAll()

        // (optional) also reset any inline stock editing UI
        stockAdjustments.removeAll()
        editingStockProductId = nil
        stockEditWorkItem?.cancel()
        stockEditWorkItem = nil

        // Snapshot BEFORE we mutate basket
        let entriesArray  = Array(basket.values)
        let total         = finalTotal
        let mode          = diningMode
        let nameSnapshot  = customerName
        let phoneSnapshot = customerPhone

        // If this started as an unpaid order → reuse that id as ticket number
        let existingIdForPayLater: Int? = (isPayLaterMode ? unpaidOrderId : nil)

        let ticketNumber: Int = {
            if let existing = existingIdForPayLater {
                return existing            // keep the same reference for that open tab
            } else {
                return nextLocalTicketNumber()
            }
        }()

        // Decide which lines to print on the ticket
        let printerEntries: [BasketEntry]
        let printerTotal: Double

        if isPayLaterMode, existingIdForPayLater != nil {
            // Pay-later finalization → only print lines that were NOT already sent
            let unsent = entriesArray.filter { !lockedLineIds.contains($0.id) }
            printerEntries = unsent
            printerTotal   = unsent.reduce(0.0) { $0 + Double($1.quantity) * $1.unitPrice }
        } else {
            // Normal order → print everything
            printerEntries = entriesArray
            printerTotal   = total
        }

        // ✅ PRINT *IMMEDIATELY* with the local ticketNumber
        if !printerEntries.isEmpty {
            PrinterManager.shared.printCashPointSplit(
                orderNumber: ticketNumber,
                entries: printerEntries,
                total: printerTotal,
                diningMode: mode,
                customerName: nameSnapshot
            )
        }

        // Clear basket & close the flow immediately in the UI
        basket.removeAll()
        showOrderFlow   = false
        showServiceStep = true

        var meta: [String: Any] = [:]

        if let summary = paymentSummary {
            meta["paymentMethod"] = summary.method.rawValue
            meta["cardAmount"]    = summary.cardAmount
            meta["cashAmount"]    = summary.cashAmount
        }

        let metaToSend = meta.isEmpty ? nil : meta

        // 🔥 Submit to server in the background – we now also send ticketNumber
        OrderAPI.submitOrder(
            orderId: existingIdForPayLater,
            entries: entriesArray,
            total: total,
            diningMode: mode,
            source: "cashpoint",
            customerName: nameSnapshot,
            customerPhone: phoneSnapshot,
            payment: paymentSummary,
            zcreditMeta: metaToSend,
            ticketNumber: ticketNumber
        ) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let serverOrderId):
                    posSavedName  = ""
                    posSavedPhone = ""

                    let snapshot = CashOrderSnapshot(
                        orderNumber: ticketNumber,   // what the slip shows
                        entries: entriesArray,
                        totalPrice: total,
                        diningMode: mode,
                        customerName: nameSnapshot,
                        customerPhone: phoneSnapshot
                    )
                    lastOrder = snapshot
                    showConfirmation = true

                    // Reset pay-later context
                    isPayLaterMode = false
                    unpaidOrderId  = nil
                    lockedLineIds.removeAll()
                    lineSessionTime.removeAll()

                    print("🟢 submitOrder OK → serverOrderId=\(serverOrderId), ticket=\(ticketNumber)")

                case .failure:
                    // ❌ Queue for retry, keep ticketNumber so DB still knows the printed id
                    CashpointOrderQueue.enqueue(
                        entries: entriesArray,
                        total: total,
                        diningMode: mode,
                        ticketNumber: ticketNumber
                    )

                    let snapshot = CashOrderSnapshot(
                        orderNumber: ticketNumber,
                        entries: entriesArray,
                        totalPrice: total,
                        diningMode: mode,
                        customerName: nameSnapshot,
                        customerPhone: phoneSnapshot
                    )
                    lastOrder = snapshot
                    showConfirmation = true
                }
            }
        }
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

        private var canSubmit: Bool {
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            parsedPrice != nil
        }

        private var parsedPrice: Double? {
            let raw = priceText
                .replacingOccurrences(of: ",", with: ".")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let d = Double(raw), d >= 0 else { return nil }
            return d
        }

        var body: some View {
            NavigationStack {
                VStack(spacing: 16) {
                    TextField(isRtl ? "טקסט הערה" : "Message text",
                              text: $text,
                              axis: .vertical)
                        .lineLimit(3, reservesSpace: true)
                        .padding(10)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(10)
                        .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
                        .focused($messageFocused)

                    TextField(isRtl ? "סכום" : "Amount", text: $priceText)
                        .keyboardType(.decimalPad)
                        .padding(10)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(10)
                        .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
                        .focused($priceFocused)
                        .onChange(of: priceFocused) { focused in
                            if focused {
                                // When the price field becomes first responder → select all text
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

                    Button {
                        if let price = parsedPrice {
                            onAdd(text.trimmingCharacters(in: .whitespacesAndNewlines), price)
                            dismiss()
                        }
                    } label: {
                        Text(isRtl ? "הוסף להזמנה" : "Add to order")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(canSubmit ?.black : Color.gray.opacity(0.4))
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
                        Button(isRtl ? "ביטול" : "Cancel") {
                            dismiss()
                        }
                    }
                }
                .onAppear {
                    // Default price to 0 so only text is required
                    if priceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        priceText = "0"
                    }
                    // Auto-focus the message field
                    messageFocused = true
                }
            }
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
    private func basketRow(_ entry: BasketEntry) -> some View {
        let isLocked = lockedLineIds.contains(entry.id)
        let isExpanded = !isLocked && expandedBasketLineId == entry.id
        let swipeOffset = basketSwipeOffsets[entry.id] ?? 0   // 👈 NEW
       
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

        // Main content for this row
        let content = VStack(alignment: .leading, spacing: 6) {
            // MAIN ROW
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.item.name)
                        .font(.system(size: 20, weight: .medium))

                    if let s = entry.subtitle, !s.isEmpty, !isExpanded {
                        Text(s)
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

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
                                        // 🔹 Dynamic rows of up to 3 chips each
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
                                        // 🔸 Single row (no scroll)
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
                                    // Vertical list of additions
                                    VStack(spacing: 6) {
                                        ForEach(g.items) { opt in
                                            let isSelected =
                                                (additionSelections[entry.id] ?? []).contains(opt.name)

                                            HStack {
                                                Text(opt.name)
                                                if opt.extraPrice > 0 {
                                                    Text("+\(Int(opt.extraPrice))")
                                                        .foregroundColor(.secondary)
                                                }
                                                Spacer()
                                                Image(systemName: isSelected
                                                      ? "checkmark.square.fill"
                                                      : "square")
                                                    .foregroundColor(isSelected ? .black : .secondary)
                                            }
                                            .padding(.vertical, 4)
                                            .contentShape(Rectangle())
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
                                    }
                                }
                            }
                        }
                    }
                    .padding(.top, 6)
                }

                // הערות text box
                VStack(alignment: .leading, spacing: 4) {
                    Text(isRtl ? "הערות" : "Notes")
                        .font(.system(size: 13, weight: .semibold))
                    TextField(isRtl ? "הוסף הערה..." : "Add a note…",
                              text: noteBinding,
                              axis: .vertical)
                        .lineLimit(1...3)
                        .padding(8)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(8)
                }
                .padding(.top, 6)
            }
        }

        // Wrap content + product separator
        return VStack(spacing: 0) {
            content
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

            // 🔹 Separator BETWEEN PRODUCTS (rows)
            Rectangle()
                .fill(Color.black.opacity(0.06))
                .frame(height: 1)
                .padding(.leading, 16)   // small indent so it feels light
        }
        .offset(x: swipeOffset)   // 👈 move row with swipe
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 10)   // smaller min distance, we control sensitivity ourselves
                .onChanged { value in
                    if isLocked {
                        basketSwipeOffsets[entry.id] = 0
                        return
                    }
                    let dx = value.translation.width
                    let dy = value.translation.height
                    let horizontal = abs(dx)
                    let vertical = abs(dy)
                    let horizontalThreshold: CGFloat = 32   // 👈 must move at least 32pt sideways

                    // Only treat as swipe if it's clearly horizontal and past threshold
                    guard horizontal > horizontalThreshold,
                          horizontal > vertical else {
                        basketSwipeOffsets[entry.id] = 0    // let vertical scroll work normally
                        return
                    }

                    let dir: CGFloat = isRtl ? -1 : 1
                    basketSwipeOffsets[entry.id] = dx * dir
                }
                .onEnded { value in
                    if isLocked {
                           withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                               basketSwipeOffsets[entry.id] = 0
                           }
                           return
                       }
                    let dx = value.translation.width
                    let dy = value.translation.height
                    let horizontal = abs(dx)
                    let vertical = abs(dy)
                    let horizontalThreshold: CGFloat = 32
                    let dir: CGFloat = isRtl ? -1 : 1

                    // If gesture wasn't clearly horizontal enough → just reset, don't change qty
                    guard horizontal > horizontalThreshold,
                          horizontal > vertical else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            basketSwipeOffsets[entry.id] = 0
                        }
                        return
                    }

                    let translated = dx * dir        // >0 = forward, <0 = backward
                    let commitThreshold: CGFloat = 80   // 👈 need a bigger swipe to trigger

                    let canIncrease = true
                    let canDecrease = entry.quantity > 0

                    if translated > commitThreshold, canIncrease {
                        // ✅ Forward swipe → increase quantity
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                            basketSwipeOffsets[entry.id] = 120 * dir
                        }

                        Haptics.light()
                        incrementEntry(entry.id)

                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                basketSwipeOffsets[entry.id] = 0
                            }
                        }

                    } else if translated < -commitThreshold, canDecrease {
                        // ✅ Backward swipe → decrease quantity
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                            basketSwipeOffsets[entry.id] = -120 * dir
                        }

                        Haptics.light()
                        decrementEntry(entry.id)

                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                basketSwipeOffsets[entry.id] = 0
                            }
                        }

                    } else {
                        // Not far enough → snap back, no change
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            basketSwipeOffsets[entry.id] = 0
                        }
                    }
                }
        )
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
            // Seed options state for this line once
            if optionSelections[entry.id] == nil {
                var map = optionsFromSubtitle(entry.subtitle)

                if let groups = entry.item.modifiers, !groups.isEmpty {
                    // 🔹 Only for real modifier items:
                    //     ensure each options group has a FIRST item selected by default
                    for g in groups where g.type == .options {
                        if map[g.title] == nil {
                            map[g.title] = g.items.first?.name
                        }
                    }
                    optionSelections[entry.id] = map

                    // 🔥 Only recalc price/subtitle when we actually have modifiers
                    updateEntryPricingAndSubtitle(lineId: entry.id)
                } else {
                    // No modifiers on this item (restored unpaid lines) → just keep whatever subtitle we got
                    optionSelections[entry.id] = map
                }
            }

            if additionSelections[entry.id] == nil {
                additionSelections[entry.id] = []
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8),
                   value: expandedBasketLineId)
    }
}
struct CashCategoryRail: View {
    let categories: [String]
    let selected: String
    let onTap: (String) -> Void
    let onOrdersTap: () -> Void        // 👈 NEW

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(categories, id: \.self) { cat in
                        HStack {
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
                                .fill(cat == selected ?.black : Color.clear)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onTap(cat)
                        }
                    }
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            Button {
                onOrdersTap()
            } label: {
                HStack {
                    Image(systemName: "list.bullet.rectangle")
                    Text("הזמנות")
                        .font(.system(size: 16, weight: .semibold))
                }
               
                .frame(maxWidth: .infinity)
                .frame(height: 48)
               
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
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

struct OrderFlowView: View {
    enum Step {
        case phone
        case name
        case charge
    }
    
    struct AppConfig {
        static var isDemoMode: Bool = false   // demo: card always succeeds
    }
    @State private var cashPaid: Bool = false
    @State private var studentDiscountActive: Bool = false
    
  
    @State private var cardPaidTotal: Double = 0
    @State private var cashPaidTotal: Double = 0

    private func playCashSuccessOnly() {
        showSuccess = true
        successScale = 0.6
        successOpacity = 0

        withAnimation(.spring(response: 0.5, dampingFraction: 0.7, blendDuration: 0.1)) {
            successScale = 1.0
            successOpacity = 1.0
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            withAnimation(.easeOut(duration: 0.25)) {
                successOpacity = 0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                showSuccess = false
            }
        }
    }
    // Effective total for this payment step (10% off when active)
    private var effectiveTotal: Double {
        // No student discount → use original total
        guard studentDiscountActive else { return total }

        // 10% discount
        let discounted = total * 0.9

        // Split into shekels + agorot
        let shekels = floor(discounted)
        let agorot = discounted - shekels

        // If more than 50 agorot → round up, else down
        let roundedShekels: Double
        if agorot > 0.5 {
            roundedShekels = shekels + 1
        } else {
            roundedShekels = shekels
        }

        return max(roundedShekels, 0)
    }
    // SPLIT MODEL
    struct SplitPart: Identifiable, Equatable {
        let id: Int          // index
        var amount: Int      // integer currency units
        var isPaid: Bool
    }

    let total: Double
    let isRtl: Bool
    @Binding var diningMode: DiningMode
    let requiresPhoneStep: Bool
    let onCancel: () -> Void
    let onCompleted: (String?, String?, OrderAPI.PaymentSummary) -> Void
    let allowPayLater: Bool
    private func buildPaymentSummary() -> OrderAPI.PaymentSummary {
        let totalPaid = cardPaidTotal + cashPaidTotal

        let method: OrderAPI.PaymentMethod
        if totalPaid <= 0.01 {
            method = .unpaid
        } else if cardPaidTotal > 0 && cashPaidTotal > 0 {
            method = .mixed
        } else if cardPaidTotal > 0 {
            method = .card
        } else {
            method = .cash
        }

        return OrderAPI.PaymentSummary(
            method: method,
            cashAmount: cashPaidTotal,
            cardAmount: cardPaidTotal
        )
    }

    // MARK: - State

    @AppStorage("posSavedName") private var posSavedName: String = ""
    @AppStorage("posSavedPhone") private var posSavedPhone: String = ""

    @State private var name: String = ""
    @State private var phoneDigits: String = ""
    @State private var step: Step = .name

    @State private var isPaying = false
    @State private var payError: String?
    @State private var paymentStarted = false
    @Environment(\.currency) private var currency

    // Cash state
    @State private var payingWithCash: Bool = false
    @State private var cashInput: String = ""
    @State private var hadCardPayment: Bool = false
      @State private var hadCashPayment: Bool = false
    // Split state
    @State private var isSplitMode: Bool = false
    @State private var splitCount: Int = 2
    @State private var splitParts: [SplitPart] = []
    @State private var remainingToPay: Double = 0
    @State private var activeSplitIndex: Int? = nil

    // Split amount pad
    @State private var showSplitAmountPad: Bool = false
    @State private var splitAmountPadIndex: Int? = nil
    @State private var splitAmountInput: String = ""

    // Split sheet (list of rows)
    @State private var showSplitSheet: Bool = false

    // Pay-on-the-bill pad
    @State private var showOnBillPad: Bool = false
    @State private var onBillInput: String = ""

    // Success animation
    @State private var showSuccess: Bool = false
    @State private var successScale: CGFloat = 0.6
    @State private var successOpacity: Double = 0

    // Manual cash target for "Pay on the bill"
    @State private var manualCashTargetAmount: Double? = nil

    // MARK: - Derived

    private var formattedPhone: String {
        formatIL(phoneDigits)
    }

    private var cashAmount: Double {
        Double(cashInput) ?? 0
    }

    private var currentTargetAmount: Double {
        if let manual = manualCashTargetAmount {
            return manual
        }
        if isSplitMode,
           let idx = activeSplitIndex,
           splitParts.indices.contains(idx) {
            return Double(splitParts[idx].amount)
        }
        // 👇 when no split / manual: use student-discounted rounded total
        return effectiveTotal
    }

    private var changeAmount: Double {
        max(cashAmount - currentTargetAmount, 0)
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: 24) {
                // Header
                HStack {
                    Button(action: { cancelAll() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 18, weight: .bold))
                            .padding(10)
                            .background(Color(.systemGray5))
                            .clipShape(Circle())
                    }

                    Spacer()

                    Button(action: { backStep() }) {
                        Image(systemName: isRtl ? "chevron.right" : "chevron.left")
                            .font(.system(size: 18, weight: .bold))
                            .padding(10)
                            .background(Color(.systemGray5))
                            .clipShape(Circle())
                    }
                    .opacity(step == .name ? 0 : 1)
                    .disabled(step == .name)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)

                Spacer()

                switch step {
                case .name:
                    nameStep
                case .phone:
                    phoneStep
                case .charge:
               
                    chargeStep
                        .onAppear {
                                    // Initialize outstanding amount on first visit
                                    if remainingToPay == 0 {
                                        remainingToPay = effectiveTotal
                                    }

                                    // Auto-start ZCredit only for full-card flow (no split, no cash, no manual amount)
                                    if !paymentStarted && !payingWithCash && !isSplitMode && manualCashTargetAmount == nil {
                                        paymentStarted = true
                                        startPayment()
                                    }
                                }
                }

                Spacer()
            }

            // Success overlay
            if showSuccess {
                ZStack {
                    Color.black.opacity(0.35).ignoresSafeArea()

                    VStack(spacing: 16) {
                        ZStack {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 110, height: 110)

                            Image(systemName: "checkmark")
                                .font(.system(size: 52, weight: .bold))
                                .foregroundColor(.white)
                        }
                        .scaleEffect(successScale)
                        .opacity(successOpacity)

                        Text(isRtl ? "ההזמנה אושרה" : "Order approved")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundColor(.white)
                    }
                }
                .transition(.opacity)
            }
        }
        .onAppear {
            // Load from AppStorage
            name = posSavedName
            phoneDigits = posSavedPhone

            let hasName = name.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
            let hasValidPhone = phoneDigits.filter(\.isNumber).count == 10

            if hasName {
                if requiresPhoneStep {
                    if hasValidPhone {
                        step = .charge   // skip name + phone
                    } else {
                        step = .phone    // skip name, ask for phone
                    }
                } else {
                    step = .charge       // only name needed → skip straight to pay
                }
            } else {
                step = .name             // no name yet → ask name
            }
        }
        // Full-screen cash
        .fullScreenCover(isPresented: $payingWithCash) {
            cashFullScreen
        }
        // Split sheet (rows)
        .sheet(isPresented: $showSplitSheet) {
            splitSheetView
        }
        // Split amount pad
        .sheet(isPresented: $showSplitAmountPad) {
            if let idx = splitAmountPadIndex,
               splitParts.indices.contains(idx) {
                SplitAmountPadView(
                    isRtl: isRtl,
                    currency: currency,
                    title: isRtl ? "סכום לתשלום \(idx + 1)" : "Amount for payment \(idx + 1)",
                    input: $splitAmountInput,
                    onDone: { value in
                        applySplitAmount(newValue: value, index: idx)
                        showSplitAmountPad = false
                    },
                    onCancel: {
                        showSplitAmountPad = false
                    }
                )
            }
        }
        // Pay-on-the-bill pad
        .sheet(isPresented: $showOnBillPad) {
            OnBillPadView(
                isRtl: isRtl,
                currency: currency,
                currentRemaining: remainingToPay > 0 ? remainingToPay : total,
                input: $onBillInput,
                onCard: { amount in
                    payOnBillWithCard(amount: amount)
                    showOnBillPad = false
                },
                onCash: { amount in
                    manualCashTargetAmount = amount
                    isSplitMode = false
                    activeSplitIndex = nil

                    cashInput = ""
                    payError = nil
                    isPaying = false
                    paymentStarted = false

                    showOnBillPad = false
                    payingWithCash = true
                },
                onCancel: {
                    showOnBillPad = false
                }
            )
        }
    }

    // MARK: - Inline split panel (like the demo)

    private var splitPanel: some View {
        VStack(spacing: 16) {
            // Header: split count + cancel
            HStack {
                Text(isRtl ? "מספר חלקים" : "Number of parts")
                    .font(.system(size: 18, weight: .semibold))

                Spacer()

                Button {
                    increaseSplitCount(-1)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 22, weight: .semibold))
                }
                .disabled(splitCount <= 2)

                Text("\(splitCount)")
                    .font(.system(size: 18, weight: .bold))
                    .frame(minWidth: 32)

                Button {
                    increaseSplitCount(1)
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 22, weight: .semibold))
                }
                .disabled(splitCount >= 6)

                Button {
                    isSplitMode = false
                    splitParts.removeAll()
                    remainingToPay = 0
                    activeSplitIndex = nil
                } label: {
                    Text(isRtl ? "בטל" : "Cancel")
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(.systemGray5))
                        .clipShape(Capsule())
                }
            }

            // Split rows
            VStack(spacing: 10) {
                ForEach(splitParts.indices, id: \.self) { idx in
                    let part = splitParts[idx]
                    let amount = Double(part.amount)

                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(isRtl ? "תשלום \(idx + 1)" : "Payment \(idx + 1)")
                                .font(.system(size: 16, weight: .medium))

                            // In the demo this just reused the on-bill pad; we keep that
                            Button {
                                onBillInput = String(Int(amount.rounded()))
                                showOnBillPad = true
                            } label: {
                                Text(String(format: "\(currency)%.0f", amount))
                                    .font(.system(size: 24, weight: .bold))
                                    .foregroundColor(.primary)
                            }
                            .buttonStyle(.plain)
                        }

                        Spacer()

                        if part.isPaid {
                            Text(isRtl ? "שולם" : "Paid")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.green)
                        } else {
                            // Credit card for this split row
                            Button {
                                // 1️⃣ Cancel current ZCredit transaction immediately
                                if !AppConfig.isDemoMode {
                                    ZCreditPaymentHandler.shared.cancelCurrent()
                                }

                                // 2️⃣ Prepare new split payment state
                                activeSplitIndex = idx
                                isPaying = true
                                payError = nil

                                // 3️⃣ WAIT 1 second before starting a new transaction
                                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                                    startCardForSplitPart(index: idx)
                                }

                            } label: {
                                Text(isRtl ? "אשראי" : "Credit card")
                                    .font(.system(size: 16, weight: .semibold))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(Color(.systemGray5))
                                    .clipShape(Capsule())
                            }

                            // Cash for this split row
                            Button {
                                if !AppConfig.isDemoMode {
                                    ZCreditPaymentHandler.shared.cancelCurrent()
                                }
                                activeSplitIndex = idx
                                manualCashTargetAmount = nil
                                cashInput = ""
                                payError = nil
                                payingWithCash = true
                            } label: {
                                Text(isRtl ? "מזומן" : "Cash")
                                    .font(.system(size: 16, weight: .semibold))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(Color(.systemGray5))
                                    .clipShape(Capsule())
                            }
                        }
                    }
                    .opacity(part.isPaid ? 0.6 : 1.0)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: 500)
        .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // Toggle split on/off, equal-splitting like in the demo
    private func toggleSplitMode() {
        // 🔹 Always cancel any in-flight ZCredit transaction first
        if !AppConfig.isDemoMode {
            ZCreditPaymentHandler.shared.cancelCurrent()
        }

        if isSplitMode {
            // Turn OFF split – keep outstanding amount as-is
            isSplitMode = false
            splitParts.removeAll()
            activeSplitIndex = nil
            // don't touch remainingToPay – it keeps whatever is still outstanding
        } else {
            // Turn ON split – base on outstanding, or full total if first time
            isSplitMode = true
                    // if 0, sets remainingToPay = total
            splitCount = 2
            splitParts = buildSplitParts()
        }
    }

    private func increaseSplitCount(_ delta: Int) {
        let newCount = splitCount + delta
        guard newCount >= 2, newCount <= 6 else { return }
        splitCount = newCount
       
        splitParts = buildSplitParts()
        // ❌ do NOT touch remainingToPay here
    }
    // MARK: - Step: Charge (card OR cash)
    private func toggleStudentDiscount() {
        // 1️⃣ Flip discount flag
        studentDiscountActive.toggle()

        // 2️⃣ Cancel any in-flight ZCredit payment
        if !AppConfig.isDemoMode {
            ZCreditPaymentHandler.shared.cancelCurrent()
        }

        // 3️⃣ Reset payment UI
        isPaying = false
        payError = nil

        // 4️⃣ Update remainingToPay if we are in a simple non-split flow
        if !isSplitMode,
           manualCashTargetAmount == nil,
           activeSplitIndex == nil {
            remainingToPay = effectiveTotal
        }

        // 5️⃣ Only auto-restart ZCredit if this is a clean full-card flow
        guard !payingWithCash,
              !isSplitMode,
              manualCashTargetAmount == nil else {
            return
        }

        // 6️⃣ ADD 2-second DELAY before restarting payment
        paymentStarted = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            // Start new payment with updated discounted amount
            startPayment()
        }
    }
    private var chargeStep: some View {
        VStack {
            Spacer()

            VStack(spacing: 24) {
                // Title
                Text(isRtl ? "הסכום לתשלום" : "Amount to charge")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.secondary)

                // Big amount (if split mode, show remaining; else effectiveTotal)
                let displayAmount = remainingToPay > 0 ? remainingToPay : effectiveTotal
                let studentDiscountValue = max(total - effectiveTotal, 0)

                VStack(spacing: 4) {
                    Text(String(format: "\(currency)%.2f", displayAmount))
                        .font(.system(size: 34, weight: .heavy))

                    if studentDiscountActive, studentDiscountValue > 0 {
                        Text(
                            isRtl
                            ? String(format: "הנחת סטודנט 10%%  -\(currency)%.2f", studentDiscountValue)
                            : String(format: "Student 10%% discount  -\(currency)%.2f", studentDiscountValue)
                        )
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                    }
                }

                // Row: Split / Pay on the bill / Student discount
                HStack(spacing: 12) {
                    // Split button → inline gray panel
                    Button {
                        toggleSplitMode()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 18, weight: .semibold))
                            Text(isRtl ? "פיצול שווה": "Split")
                                .font(.system(size: 18, weight: .semibold))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(Capsule())
                    }
                    .disabled(total <= 0)

                    // Pay on the bill
                    Button {
                        if !AppConfig.isDemoMode {
                            ZCreditPaymentHandler.shared.cancelCurrent()
                        }

                        // Cancel split when paying on the bill
                        isSplitMode = false
                        splitParts.removeAll()
                        activeSplitIndex = nil

                        // Important: keep remainingToPay as-is if you've already paid partially.
                        // If this is the first payment, remainingToPay is still 0,
                        // and the OnBillPad will use `effectiveTotal` as the base via currentRemaining.
                        onBillInput = ""
                        payError = nil
                        isPaying = false
                        showOnBillPad = true
                    } label: {
                        Text(isRtl ?"תשלום חלקי": "Pay on the bill")
                            .font(.system(size: 18, weight: .semibold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(Capsule())
                    }
                    .disabled(total <= 0)

                    // Student 10% discount
                    Button {
                        toggleStudentDiscount()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "graduationcap.fill")
                                .font(.system(size: 16, weight: .semibold))
                            Text(isRtl ? "הנחת סטודנט 10%" : "Student 10%")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            studentDiscountActive
                            ?.black.opacity(0.15)
                            : Color(.secondarySystemBackground)
                        )
                        .foregroundColor(
                            studentDiscountActive ?.black : .primary
                        )
                        .clipShape(Capsule())
                    }
                    .disabled(total <= 0 || isSplitMode)
                }
                .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)

                // Inline split panel (gray block) like the demo
                if isSplitMode {
                    splitPanel
                }

                // Main card prompt
                Text(isRtl ? "הכנס או הצמד כרטיס" : "Insert or tap card")
                    .font(.system(size: 24, weight: .bold))
                    .padding(.top, 8)

                // Card error
                if let err = payError {
                    Text(err)
                        .foregroundColor(.red)
                        .font(.system(size: 16, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }

                // Card spinner
                if isPaying {
                    ProgressView()
                        .scaleEffect(1.3)
                        .padding(.top, 8)
                }

                // Card / Cash buttons
                // Card / Cash buttons
                VStack(spacing: 12) {
                    // 🔹 Always show "Pay by card" (תשלום באשראי), not only on error
                    Button {
                        // Cancel any in-flight transaction before starting a new one
                        if !AppConfig.isDemoMode {
                            ZCreditPaymentHandler.shared.cancelCurrent()
                        }
                        paymentStarted = true
                        payError = nil
                        startPayment()
                    } label: {
                        Text(isRtl ? "תשלום באשראי" : "Pay by card")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 240, height: 50)
                            .background(.black)
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                    }
                    .disabled(isPaying)   // don't allow double-tap while terminal is busy

                    // Full-amount cash (no split)
                    Button {
                        payingWithCash = true
                        payError = nil
                        isPaying = false
                        paymentStarted = false      // allow card to be started again later
                        cashInput = ""
                        manualCashTargetAmount = nil   // full total

                        if !AppConfig.isDemoMode {
                            ZCreditPaymentHandler.shared.cancelCurrent()
                        }
                    } label: {
                        Text(isRtl ? "תשלום במזומן" : "Pay with cash")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.primary)
                            .frame(width: 220, height: 48)
                            .background(Color(.systemGray5))
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                    }

                    if allowPayLater {
                        Button {
                            completeWithoutPayment()
                        } label: {
                            Text(isRtl ? "תשלום מאוחר יותר" : "Pay later")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.secondary)
                                .frame(width: 220, height: 44)
                        }
                    }

                    Button {
                        cancelPayment()
                    } label: {
                        Text(isRtl ? "ביטול" : "Cancel")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.secondary)
                            .frame(width: 220, height: 44)
                    }
                }
                .padding(.top, 8)
            }
            .padding(.horizontal, 28)

            Spacer()
        }
    }

    // MARK: - Split sheet (rows)

    private var splitSheetView: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text(isRtl ? "פיצול הזמנה" : "Split payment")
                    .font(.system(size: 22, weight: .bold))
                    .padding(.top, 8)

                Text(String(format: "\(currency)%.2f", total))
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.secondary)

                Divider().padding(.top, 4)

                VStack(spacing: 16) {
                    HStack {
                        Button {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                                isSplitMode = false
                                splitParts.removeAll()
                                remainingToPay = 0
                                activeSplitIndex = nil
                            }
                            showSplitSheet = false
                        } label: {
                            Text(isRtl ? "ביטול פיצול" : "Cancel split")
                                .font(.system(size: 14, weight: .semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color(.systemGray5))
                                .clipShape(Capsule())
                        }

                        Spacer()
                    }

                    VStack(spacing: 12) {
                        ForEach(splitParts.indices, id: \.self) { idx in
                            let part = splitParts[idx]
                            let amount = Double(part.amount)

                            HStack {
                                // Amount + tap to change
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(isRtl ? "תשלום \(idx + 1)" : "Payment \(idx + 1)")
                                        .font(.system(size: 16, weight: .medium))

                                    Button {
                                        splitAmountPadIndex = idx
                                        splitAmountInput = String(part.amount)
                                        showSplitAmountPad = true
                                    } label: {
                                        Text(String(format: "\(currency)%.0f", amount))
                                            .font(.system(size: 26, weight: .bold))
                                            .foregroundColor(.primary)
                                            .frame(minWidth: 120, alignment: .leading)
                                    }
                                    .buttonStyle(.plain)
                                }

                                Spacer()

                                if part.isPaid {
                                    Text(isRtl ? "שולם" : "Paid")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundColor(.green)
                                } else {
                                    // Card
                                    Button {
                                        if !AppConfig.isDemoMode {
                                            ZCreditPaymentHandler.shared.cancelCurrent()
                                        }
                                        activeSplitIndex = idx
                                        isPaying = true
                                        payError = nil
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                               startCardForSplitPart(index: idx)
                                           }
                                    } label: {
                                        Text(isRtl ? "אשראי" : "Card")
                                            .font(.system(size: 16, weight: .semibold))
                                            .padding(.horizontal, 14)
                                            .padding(.vertical, 8)
                                            .background(Color(.systemGray5))
                                            .clipShape(Capsule())
                                    }
                                  
                                    // Cash
                                    Button {
                                        if !AppConfig.isDemoMode {
                                            ZCreditPaymentHandler.shared.cancelCurrent()
                                        }
                                        activeSplitIndex = idx
                                        cashInput = ""
                                        payError = nil
                                        manualCashTargetAmount = nil
                                        payingWithCash = true
                                    } label: {
                                        Text(isRtl ? "מזומן" : "Cash")
                                            .font(.system(size: 16, weight: .semibold))
                                            .padding(.horizontal, 14)
                                            .padding(.vertical, 8)
                                            .background(Color(.systemGray5))
                                            .clipShape(Capsule())
                                    }
                                }
                            }
                            .opacity(part.isPaid ? 0.6 : 1.0)
                        }
                    }

                    // Add another equal split
                    Button {
                        splitCount += 1
                        splitParts = buildSplitParts()
                       
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus.circle.fill")
                            Text(isRtl ? "הוסף חלק" : "Add split")
                        }
                        .font(.system(size: 16, weight: .semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(Capsule())
                    }
                }
                .padding(.horizontal, 12)

                Spacer()

                VStack(spacing: 12) {
                    // 1️⃣ Pay-on-the-bill cash (manual amount)
                    if let manual = manualCashTargetAmount {
                        VStack(spacing: 4) {
                            Text(isRtl ? "סכום לתשלום" : "Amount to pay")
                                .font(.system(size: 16))
                                .foregroundColor(.secondary)
                            Text(String(format: "\(currency)%.2f", manual))
                                .font(.system(size: 26, weight: .heavy))
                        }
                    }
                    // 2️⃣ Split mode
                    else if isSplitMode {
                        VStack(spacing: 4) {
                            Text(isRtl ? "יתרה לתשלום" : "Remaining to pay")
                                .font(.system(size: 16))
                                .foregroundColor(.secondary)
                            Text(String(format: "\(currency)%.2f", max(remainingToPay, 0)))
                                .font(.system(size: 24, weight: .heavy))
                        }

                        VStack(spacing: 4) {
                            Text(isRtl ? "סכום לתשלום בתשלום זה" : "Amount for this payment")
                                .font(.system(size: 14))
                                .foregroundColor(.secondary)
                            Text(String(format: "\(currency)%.2f", currentTargetAmount))
                                .font(.system(size: 22, weight: .semibold))
                        }
                    }
                    // 3️⃣ Normal full-order cash
                    else {
                        VStack(spacing: 4) {
                            Text(isRtl ? "סכום לתשלום" : "Amount to pay")
                                .font(.system(size: 16))
                                .foregroundColor(.secondary)
                            Text(String(format: "\(currency)%.2f", currentTargetAmount))
                                .font(.system(size: 26, weight: .heavy))
                        }
                    }
                }
                .padding(.bottom, 16)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isRtl ? "סגור" : "Close") {
                        showSplitSheet = false
                    }
                }
            }
        }
    }

    // MARK: - Split helpers

    private func buildSplitParts() -> [SplitPart] {
        // Use outstanding if we have it, otherwise full total
        let baseTotal = remainingToPay > 0 ? remainingToPay : total
        let totalInt  = Int(baseTotal.rounded())
        guard splitCount > 0 else { return [] }

        let base     = totalInt / splitCount
        let remainder = totalInt % splitCount

        return (0..<splitCount).map { idx in
            let amount = idx < remainder ? base + 1 : base
            return SplitPart(id: idx, amount: amount, isPaid: false)
        }
    }

    private func ensureSplitParts() {
        if splitParts.isEmpty {
            splitParts = buildSplitParts()
            remainingToPay = total
        }
    }

    private func markPartPaid(_ index: Int) {
        guard splitParts.indices.contains(index),
              !splitParts[index].isPaid else { return }

        let amount = Double(splitParts[index].amount)
        splitParts[index].isPaid = true
        remainingToPay = max(remainingToPay - amount, 0)
    }

    /// Two-row style amount application (for now).
    private func applySplitAmount(newValue: String, index: Int) {
        let totalInt = Int(total.rounded())
        let filtered = newValue.filter(\.isNumber)
        let entered = Int(filtered) ?? 0
        let clamped = max(0, min(entered, totalInt))

        guard splitParts.indices.contains(index) else { return }

        if index == 0 {
            splitParts[0].amount = clamped
            let remaining = max(totalInt - clamped, 0)

            if splitParts.count > 1 {
                splitParts[1].amount = remaining
            } else {
                splitParts.append(SplitPart(id: 1, amount: remaining, isPaid: false))
            }
        } else {
            if splitParts.count > 1 {
                let second = clamped
                let first  = max(totalInt - second, 0)
                splitParts[1].amount = second
                splitParts[0].amount = first
            }
        }

        remainingToPay = splitParts
            .enumerated()
            .filter { !$0.element.isPaid }
            .map { Double($0.element.amount) }
            .reduce(0, +)
    }

    // MARK: - Pay on bill helpers

    private func payOnBillWithCard(amount: Double) {
        guard amount > 0 else { return }

        if AppConfig.isDemoMode {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                // 👇 mark card money
                self.cardPaidTotal += amount
                self.remainingToPay = max(self.remainingToPay - amount, 0)
                if self.remainingToPay <= 0 {
                    self.playSuccessAndCompleteOrder()
                }
            }
            return
        }

        isPaying = true
        payError = nil

        ZCreditPaymentHandler.shared.pay(amount: amount, orderId: nil) { result in
            isPaying = false

            if result.approved {
                // 👇 mark card money
                self.cardPaidTotal += amount
                self.remainingToPay = max(self.remainingToPay - amount, 0)

                if self.remainingToPay <= 0 {
                    self.playSuccessAndCompleteOrder()
                }
            } else {
                let fallback = isRtl
                    ? "התשלום נכשל, נסה שוב או בחר אמצעי תשלום אחר."
                    : "Payment failed, please try again or choose another method."
                self.payError = result.message.isEmpty ? fallback : result.message
            }
        }
    }

    // MARK: - Success

    private func playSuccessAndCompleteOrder() {
        let phoneParam = phoneDigits.trimmedIsEmpty ? nil : phoneDigits
        let nameParam  = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : name
        let summary    = buildPaymentSummary()

        // 🧹 Clear saved name/phone **immediately on success**
        posSavedName  = ""
        posSavedPhone = ""
        name          = ""
        phoneDigits   = ""

        showSuccess = true
        successScale = 0.6
        successOpacity = 0

        withAnimation(.spring(response: 0.5, dampingFraction: 0.7, blendDuration: 0.1)) {
            successScale = 1.0
            successOpacity = 1.0
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            withAnimation(.easeOut(duration: 0.25)) {
                successOpacity = 0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                showSuccess = false
                onCompleted(phoneParam, nameParam, summary)
            }
        }
    }

    // MARK: - Navigation / Cancel

    private func backStep() {
        switch step {
        case .name:
            onCancel()
        case .phone:
            step = .name
        case .charge:
            if payingWithCash {
                payingWithCash = false
                cashInput = ""
                payError = nil
            } else {
                isPaying = false
                payError = nil
                paymentStarted = false
                step = .phone
            }
        }
    }

    private func cancelAll() {
        isPaying = false
        payError = nil
        paymentStarted = false
        payingWithCash = false
        cashInput = ""
        manualCashTargetAmount = nil

        if !AppConfig.isDemoMode {
            ZCreditPaymentHandler.shared.cancelCurrent()
        }

        onCancel()
    }

    // MARK: - Phone & name steps (unchanged)

    // ... keep your existing `phoneStep`, `nameStep`, keypad helpers here ...

    // MARK: - Card / cash helpers

    private func cancelPayment() {
        isPaying = false
        payError = nil
        paymentStarted = false
        payingWithCash = false
        cashInput = ""
        manualCashTargetAmount = nil

        if !AppConfig.isDemoMode {
            ZCreditPaymentHandler.shared.cancelCurrent()
        }

        onCancel()
    }

    private func startPayment() {
        isPaying = true
        payError = nil

        if AppConfig.isDemoMode {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.isPaying = false
                // 👇 full card amount
                self.cardPaidTotal += self.effectiveTotal
                self.playSuccessAndCompleteOrder()
            }
            return
        }

        let amountToCharge = effectiveTotal

        ZCreditPaymentHandler.shared.pay(amount: amountToCharge, orderId: nil) { result in
            isPaying = false

            if result.approved {
                // 👇 full card amount
                self.cardPaidTotal += amountToCharge
                self.playSuccessAndCompleteOrder()
            } else {
                let fallback = isRtl
                    ? "התשלום נכשל, נסה שוב או בחר אמצעי תשלום אחר."
                    : "Payment failed, please try again or choose another method."
                self.payError = result.message.isEmpty ? fallback : result.message
            }
        }
    }

    private func completeWithoutPayment() {
        if !AppConfig.isDemoMode {
            ZCreditPaymentHandler.shared.cancelCurrent()
        }
        isPaying = false
        payError = nil
        paymentStarted = false
        payingWithCash = false
        cashInput = ""
        manualCashTargetAmount = nil

        // no money taken
        cardPaidTotal = 0
        cashPaidTotal = 0

        playSuccessAndCompleteOrder()
    }

    private func completeWithCash() {
        if !AppConfig.isDemoMode {
            ZCreditPaymentHandler.shared.cancelCurrent()
        }
        isPaying = false
        payError = nil
        paymentStarted = false
        payingWithCash = false

        // 💵 How much cash did we just take in this action?
        let thisCash: Double
        if let manual = manualCashTargetAmount {
            // Manual "pay on the bill" amount
            thisCash = manual
        } else if isSplitMode,
                  let idx = activeSplitIndex,
                  splitParts.indices.contains(idx) {
            // Cash for a specific split row
            thisCash = Double(splitParts[idx].amount)
        } else {
            // Full-order cash (no split/manual)
            thisCash = effectiveTotal
        }
        cashPaidTotal += thisCash

        // 1️⃣ Manual partial cash (on-the-bill)
        if let manual = manualCashTargetAmount {
            remainingToPay = max(remainingToPay - manual, 0)
            manualCashTargetAmount = nil

            if remainingToPay > 0 {
                // Partially paid → go back to charge, don't finish order yet
                return
            } else {
                // Manual cash covered the rest of the order
                playSuccessAndCompleteOrder()
                return
            }
        }

        // 2️⃣ Split-mode cash (one of the split parts)
        if isSplitMode, let idx = activeSplitIndex {
            markPartPaid(idx)       // this adjusts remainingToPay
            activeSplitIndex = nil

            if remainingToPay <= 0 {
                // Could be pure cash or mixed with card — decided later from totals
                playSuccessAndCompleteOrder()
            }
            return
        }

        // 3️⃣ Full cash, no split / manual
        remainingToPay = max(remainingToPay - thisCash, 0)
        playSuccessAndCompleteOrder()
    }

    // MARK: - Cash full-screen

    private var cashFullScreen: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: 20) {
                HStack {
                    if isRtl { Spacer() }

                    Button {
                        payingWithCash = false
                        cashInput = ""
                        payError = nil
                        manualCashTargetAmount = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 18, weight: .bold))
                            .padding(10)
                            .background(Color(.systemGray5))
                            .clipShape(Circle())
                    }

                    if !isRtl { Spacer() }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)

                Spacer()

                VStack(spacing: 12) {
                    // 1️⃣ Manual "Pay on the bill" cash – ALWAYS show the selected amount
                    if let manual = manualCashTargetAmount {
                        VStack(spacing: 4) {
                            Text(isRtl ? "סכום לתשלום" : "Amount to pay")
                                .font(.system(size: 16))
                                .foregroundColor(.secondary)
                            Text(String(format: "\(currency)%.2f", manual))
                                .font(.system(size: 26, weight: .heavy))
                        }
                    }
                    // 2️⃣ Split mode
                    else if isSplitMode {
                        VStack(spacing: 4) {
                            Text(isRtl ? "יתרה לתשלום" : "Remaining to pay")
                                .font(.system(size: 16))
                                .foregroundColor(.secondary)
                            Text(String(format: "\(currency)%.2f", max(remainingToPay, 0)))
                                .font(.system(size: 24, weight: .heavy))
                        }

                        VStack(spacing: 4) {
                            Text(isRtl ? "סכום לתשלום בתשלום זה" : "Amount for this payment")
                                .font(.system(size: 14))
                                .foregroundColor(.secondary)
                            Text(String(format: "\(currency)%.2f", currentTargetAmount))
                                .font(.system(size: 22, weight: .semibold))
                        }
                    }
                    // 3️⃣ Normal full-order cash
                    else {
                        VStack(spacing: 4) {
                            Text(isRtl ? "סכום לתשלום" : "Amount to pay")
                                .font(.system(size: 16))
                                .foregroundColor(.secondary)
                            Text(String(format: "\(currency)%.2f", currentTargetAmount))
                                .font(.system(size: 26, weight: .heavy))
                        }
                    }
                }

                Text(isRtl ? "כמה מזומן התקבל?" : "Cash received")
                    .font(.system(size: 22, weight: .bold))
                    .padding(.top, 4)

                cashAmountDisplay
                cashKeypad
                    .environment(\.layoutDirection, .leftToRight)
                VStack(spacing: 8) {
                    Text(isRtl ? "עודף ללקוח" : "Change to give")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                    Text(String(format: "\(currency)%.2f", changeAmount))
                        .font(.system(size: 28, weight: .bold))
                }
                .padding(.top, 8)

                // Single toggle button
                Button {
                    if !cashPaid {
                        // 1️⃣ First tap → open drawer
                        PrinterManager.shared.openCashDrawer()
                        cashPaid = true

                        // If this cash payment **fully covers** the order →
                        // finish immediately with the big success flow
                        if remainingToPay <= 0 {
                            completeWithCash()          // will call playSuccessAndCompleteOrder()
                        } else {
                            // Only partial / split → small check animation, stay on screen
                            playCashSuccessOnly()
                        }

                    } else {
                        // 2️⃣ Second tap on "סיים" → actually complete the cash payment flow
                        completeWithCash()              // handles remainingToPay + big success
                    }
                } label: {
                    Text(isRtl
                         ? (cashPaid ? "סיים" : "שולם")
                         : (cashPaid ? "Finish" : "Paid"))
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                .padding(.horizontal, 20)
                .frame(maxWidth: 300)
                .padding(.top, 12)
                .padding(.horizontal, 20)

                Spacer()
            }
        }
        .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
    }

    // MARK: - Pay on the bill pad (no iPhone keyboard)

    private struct OnBillPadView: View {
        let isRtl: Bool
        let currency: String
        let currentRemaining: Double
        @Binding var input: String
        let onCard: (Double) -> Void
        let onCash: (Double) -> Void
        let onCancel: () -> Void

        private var amount: Double {
            let raw = input.filter(\.isNumber)
            let value = Double(raw) ?? 0
            return min(value, currentRemaining)
        }

        var body: some View {
            NavigationStack {
                VStack(spacing: 20) {
                    Text(isRtl ? "תשלום לפי סכום" : "Pay on the bill")
                        .font(.system(size: 24, weight: .bold))

                    Text(
                        String(
                            format: isRtl
                            ? "יתרה: \(currency)%.2f"
                            : "Remaining: \(currency)%.2f",
                            currentRemaining
                        )
                    )
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.secondary)

                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(.secondarySystemBackground))
                        Text(amount == 0 ? "0" : String(Int(amount)))
                            .font(.system(size: 30, weight: .bold, design: .monospaced))
                            .multilineTextAlignment(.center)
                    }
                    .frame(width: 260, height: 60)

                    keypad

                    // 🔹 Side-by-side buttons: Card (brand color) + Cash
                    HStack(spacing: 16) {
                        Button {
                            onCard(amount)   // parent should open cash/charge view for this amount
                        } label: {
                            Text(isRtl ? "כרטיס" : "Card")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 48)
                                .background(.black)   // brand color
                                .clipShape(RoundedRectangle(cornerRadius: 18))
                        }
                        .disabled(amount <= 0)

                        Button {
                            onCash(amount)   // parent should open cash view for this amount
                        } label: {
                            Text(isRtl ? "מזומן" : "Cash")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(.primary)
                                .frame(maxWidth: .infinity)
                                .frame(height: 48)
                                .background(Color(.systemGray5))
                                .clipShape(RoundedRectangle(cornerRadius: 18))
                        }
                        .disabled(amount <= 0)
                    }
                    .frame(width: 260)
                    .padding(.top, 8)

                    Spacer()
                }
                .padding(20)
                .onAppear {
                    input = ""   // start empty
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(isRtl ? "סגור" : "Close") {
                            onCancel()
                        }
                    }
                }
            }
        }

        private var keypad: some View {
            let cols = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)
            let keys = ["1","2","3","4","5","6","7","8","9","C","0","⌫"]

            return LazyVGrid(columns: cols, spacing: 12) {
                ForEach(keys, id: \.self) { key in
                    Button {
                        tapKey(key)
                    } label: {
                        Text(key)
                            .font(.system(size: key == "⌫" ? 22 : 24, weight: .bold))
                            .frame(width: 80, height: 64)
                            .background(Color(.systemGray5))
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                }
            }
            .frame(width: 260)
        }

        private func tapKey(_ key: String) {
            switch key {
            case "C":
                input = ""
            case "⌫":
                if !input.isEmpty { input.removeLast() }
            default:
                if key.allSatisfy(\.isNumber) {
                    if input.count < 7 {
                        input.append(contentsOf: key)
                    }
                }
            }
        }
    }

    // MARK: - Phone / Name steps

    private var phoneStep: some View {
        VStack(spacing: 24) {

            Text(isRtl ? "מה מספר הטלפון שלך?" : "What’s your phone number?")
                .font(.system(size: 26, weight: .bold))
                .multilineTextAlignment(.center)

            Text(isRtl ? "כדי שנעדכן אותך כשההזמנה מוכנה"
                       : "So we can notify you when your order is ready")
                .font(.system(size: 15))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            phoneDisplay

            phonePad

            VStack(spacing: 10) {
                Button {
                    posSavedPhone = phoneDigits
                    step = .charge
                } label: {
                    Text(isRtl ? "המשך לתשלום" : "Next")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 300, height: 52)
                        .background(phoneValid ?.black : Color.gray.opacity(0.4))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .disabled(!phoneValid)

                Button {
                    step = .charge
                } label: {
                    Text(isRtl ? "דלג" : "Skip")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 300, height: 44)
                }
            }
        }
    }

    private var phoneDisplay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.secondarySystemBackground))

            if formattedPhone.isEmpty {
                Rectangle()
                    .fill(Color.gray)
                    .frame(width: 2, height: 24)
            } else {
                Text(formattedPhone)
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .foregroundColor(.primary)
            }
        }
        .frame(width: 300, height: 52)
    }

    private var phonePad: some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)
        return LazyVGrid(columns: cols, spacing: 12) {
            ForEach(["1","2","3","4","5","6","7","8","9","","0","⌫"], id: \.self) { key in
                if key.isEmpty {
                    Color.clear.frame(height: 64)
                } else {
                    Button {
                        tapPhoneKey(key)
                    } label: {
                        Text(key)
                            .font(.system(size: key == "⌫" ? 24 : 26, weight: .bold))
                            .frame(width: 80, height: 64)
                            .background(Color(.systemGray5))
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }
            }
        }
        .frame(width: 300)
    }

    private func tapPhoneKey(_ key: String) {
        if key == "⌫" {
            if !phoneDigits.isEmpty {
                phoneDigits.removeLast()
            }
        } else if key.count == 1, let c = key.first, c.isNumber {
            if phoneDigits.filter(\.isNumber).count < 10 {
                phoneDigits.append(c)
            }
        }
    }

    private var phoneValid: Bool {
        let d = phoneDigits.filter(\.isNumber)
        return d.count == 10 && d.first == "0"
    }

    private func formatIL(_ raw: String) -> String {
        let d = raw.filter(\.isNumber)
        if d.isEmpty { return "" }
        if d.count <= 3 { return d }
        if d.count <= 7 {
            let p1 = d.prefix(3)
            let p2 = d.dropFirst(3)
            return "\(p1)-\(p2)"
        }
        let p1 = d.prefix(3)
        let p2 = d.dropFirst(3).prefix(4)
        let p3 = d.dropFirst(7)
        return "\(p1)-\(p2)-\(p3)"
    }

    private var nameStep: some View {
        VStack(spacing: 24) {
            Text(isRtl ? "מה השם שלך?" : "What’s your name?")
                .font(.system(size: 26, weight: .bold))
                .multilineTextAlignment(.center)

            Text(isRtl ? "נכתוב את זה על ההזמנה" : "We’ll put it on your order")
                .font(.system(size: 15))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.secondarySystemBackground))

                if name.isEmpty {
                    Rectangle()
                        .fill(Color.gray)
                        .frame(width: 2, height: 24)
                } else {
                    Text(name)
                        .font(.system(size: 22, weight: .semibold, design: .monospaced))
                        .foregroundColor(.primary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(width: 300, height: 52)

            nameKeyboard

            VStack(spacing: 10) {
                Button {
                    posSavedName = name.trimmingCharacters(in: .whitespaces)
                    step = requiresPhoneStep ? .phone : .charge
                } label: {
                    Text(isRtl ? "המשך" : "Continue to payment")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 300, height: 52)
                        .background(nameValid ?.black : Color.gray.opacity(0.4))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .disabled(!nameValid)

                Button {
                    // ⬇️ Skip behaves the same: phone only when needed
                    step = requiresPhoneStep ? .phone : .charge
                    paymentStarted = false
                    payError = nil
                } label: {
                    Text(isRtl ? "דלג" : "Skip")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 300, height: 44)
                }
            }
        }
    }

    private var nameValid: Bool {
        name.trimmingCharacters(in: .whitespaces).count >= 2
    }

    private var nameKeyboard: some View {
        let isPhone = UIDevice.current.userInterfaceIdiom == .phone
        let rows = isRtl ? hebrewRowsWide : latinRowsWide

        let phoneMaxWidth: CGFloat = UIScreen.main.bounds.width - 40
        let iPadMaxWidth: CGFloat = 600
        let maxWidth = isPhone ? phoneMaxWidth : iPadMaxWidth

        return VStack(spacing: isPhone ? 10 : 12) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: isPhone ? 6 : 10) {
                    ForEach(row, id: \.self) { key in
                        Button {
                            tapNameKey(key)
                        } label: {
                            Text(keyLabel(key))
                                .font(.system(
                                    size: isPhone ? (key == "⌫" ? 18 : 20) : (key == "⌫" ? 20 : 22),
                                    weight: .semibold
                                ))
                                .frame(
                                    width: keyWidth(for: key, row: row, maxWidth: maxWidth, isPhone: isPhone),
                                    height: isPhone ? 50 : 58
                                )
                                .background(Color(.systemGray5))
                                .clipShape(RoundedRectangle(
                                    cornerRadius: isPhone ? 10 : 12,
                                    style: .continuous
                                ))
                        }
                    }
                }
            }
        }
        .frame(maxWidth: maxWidth)
        .padding(.horizontal, isPhone ? 12 : 20)
    }

    private func keyWidth(for key: String,
                          row: [String],
                          maxWidth: CGFloat,
                          isPhone: Bool) -> CGFloat {
        if key == "Space" || key == "רווח" {
            return isPhone ? maxWidth * 0.60 : maxWidth * 0.55
        }
        if key == "⌫" {
            return isPhone ? maxWidth * 0.15 : maxWidth * 0.18
        }
        let count = row.count
        let spacing = CGFloat((count - 1) * (isPhone ? 6 : 10))
        return (maxWidth - spacing) / CGFloat(count)
    }

    private var hebrewRowsWide: [[String]] {
        [
            // Row 1 – like iOS: ק ר א ט ו ן ם פ + delete
            ["ק","ר","א","ט","ו","ן","ם","פ","⌫"],

            // Row 2 – ends with ך ף
            ["ש","ד","ג","כ","ע","י","ח","ל","ך","ף"],

            // Row 3 – add apostrophe "'" at the end
            ["ז","ס","ב","ה","נ","מ","צ","ת","'"],

            // Space row
            ["רווח"]
        ]
    }
    
    private var latinRowsWide: [[String]] {
        [
            // Row 1: QWERTYUIOP
            ["Q","W","E","R","T","Y","U","I","O","P"],

            // Row 2: ASDFGHJKL
            ["A","S","D","F","G","H","J","K","L"],

            // Row 3: ZXCVBNM + delete at the end (like iPhone/iPad)
            ["Z","X","C","V","B","N","M","⌫"],

            // Space row
            ["Space"]
        ]
    }

    private func keyLabel(_ key: String) -> String {
        switch key {
        case "Space": return "Space"
        case "רווח": return "רווח"
        case "⌫":    return "⌫"
        default:     return key
        }
    }

    private func tapNameKey(_ key: String) {
        switch key {
        case "⌫":
            if !name.isEmpty { name.removeLast() }
        case "Space", "רווח":
            if !name.hasSuffix(" ") { name.append(" ") }
        default:
            if name.count < 32 {
                name.append(key)
            }
        }
    }

    // MARK: - Cash UI pieces

    private var cashAmountDisplay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.secondarySystemBackground))

            if cashInput.isEmpty {
                Text(isRtl ? "0" : "0")
                    .font(.system(size: 26, weight: .bold, design: .monospaced))
                    .foregroundColor(.secondary)
            } else {
                Text(String(format: "\(currency)%.2f", cashAmount))
                    .font(.system(size: 26, weight: .bold, design: .monospaced))
                    .foregroundColor(.primary)
            }
        }
        .frame(width: 260, height: 52)
    }

    private var cashKeypad: some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)
        let keys = ["1","2","3","4","5","6","7","8","9","C","0","⌫"]

        return LazyVGrid(columns: cols, spacing: 12) {
            ForEach(keys, id: \.self) { key in
                Button {
                    tapCashKey(key)
                } label: {
                    Text(key)
                        .font(.system(size: key == "⌫" ? 22 : 24, weight: .bold))
                        .frame(width: 80, height: 64)
                        .background(Color(.systemGray5))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
        }
        .frame(width: 260)
        .padding(.top, 8)
    }

    private func tapCashKey(_ key: String) {
        switch key {
        case "C":
            cashInput = ""
        case "⌫":
            if !cashInput.isEmpty { cashInput.removeLast() }
        default:
            if key.allSatisfy(\.isNumber) {
                if cashInput.count < 7 {
                    cashInput.append(contentsOf: key)
                }
            }
        }
    }

    // MARK: - Split card helper
    private func startCardForSplitPart(index: Int) {
        guard splitParts.indices.contains(index),
              !splitParts[index].isPaid else { return }

        let amount = Double(splitParts[index].amount)

        if AppConfig.isDemoMode {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.isPaying = false
                self.cardPaidTotal += amount      // 👈 NEW
                self.markPartPaid(index)
                if self.remainingToPay <= 0 {
                    self.playSuccessAndCompleteOrder()
                }
            }
            return
        }

        ZCreditPaymentHandler.shared.pay(amount: amount, orderId: nil) { result in
            isPaying = false

            if result.approved {
                self.cardPaidTotal += amount      // 👈 NEW
                self.markPartPaid(index)
                if self.remainingToPay <= 0 {
                    self.playSuccessAndCompleteOrder()
                }
            } else {
                let fallback = isRtl
                    ? "התשלום נכשל, נסה שוב או בחר אמצעי תשלום אחר."
                    : "Payment failed, please try again or choose another method."
                self.payError = result.message.isEmpty ? fallback : result.message
            }
        }
    }
    // MARK: - Split amount pad view

    private struct SplitAmountPadView: View {
        let isRtl: Bool
        let currency: String
        let title: String
        @Binding var input: String
        let onDone: (String) -> Void
        let onCancel: () -> Void

        private var displayValue: String {
            let filtered = input.filter(\.isNumber)
            return filtered.isEmpty ? "0" : filtered
        }

        var body: some View {
            NavigationStack {
                VStack(spacing: 20) {
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
                    .padding(.top, 12)

                    Spacer()

                    Text(title)
                        .font(.system(size: 22, weight: .bold))
                        .multilineTextAlignment(.center)

                    HStack(spacing: 8) {
                        Text(currency)
                            .font(.system(size: 30, weight: .bold))
                        Text(displayValue)
                            .font(.system(size: 34, weight: .bold, design: .monospaced))
                    }

                    keypad

                    Button {
                        onDone(input)
                    } label: {
                        Text(isRtl ? "אישור" : "Confirm")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 220, height: 52)
                            .background(.black)
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                    }
                    .padding(.top, 8)

                    Spacer()
                }
                .padding(.bottom, 20)
                .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
            }
        }

        private var keypad: some View {
            let cols = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)
            let keys = ["1","2","3","4","5","6","7","8","9","C","0","⌫"]

            return LazyVGrid(columns: cols, spacing: 12) {
                ForEach(keys, id: \.self) { key in
                    Button {
                        tapKey(key)
                    } label: {
                        Text(key)
                            .font(.system(size: key == "⌫" ? 22 : 24, weight: .bold))
                            .frame(width: 80, height: 64)
                            .background(Color(.systemGray5))
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                }
            }
            .frame(width: 280)
            .padding(.top, 8)
        }

        private func tapKey(_ key: String) {
            switch key {
            case "C":
                input = ""
            case "⌫":
                if !input.isEmpty { input.removeLast() }
            default:
                if key.allSatisfy(\.isNumber) {
                    if input.count < 7 {
                        input.append(contentsOf: key)
                    }
                }
            }
        }
    }

    // MARK: - Phone & name helpers (keep as in your current file)

    // NOTE: keep your existing `phoneStep`, `nameStep`, `phonePad`, `nameKeyboard`,
    // `formatIL`, etc. from your current OrderFlowView implementation.
}



private extension String {
    var trimmedIsEmpty: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
                                        VStack(spacing: 6) {
                                            ForEach(g.items) { opt in
                                                let selected = selectedAdditions.contains(opt.name)
                                                HStack {
                                                    Text(opt.name)
                                                    if opt.extraPrice > 0 {
                                                        Text("+\(Int(opt.extraPrice))")
                                                            .foregroundColor(.secondary)
                                                    }
                                                    Spacer()
                                                    Image(systemName: selected ? "checkmark.square.fill" : "square")
                                                        .foregroundColor(selected ? .black : .secondary)
                                                }
                                                .padding(.vertical, 6)
                                                .contentShape(Rectangle())
                                                .onTapGesture {
                                                    if selected {
                                                        selectedAdditions.remove(opt.name)
                                                    } else {
                                                        selectedAdditions.insert(opt.name)
                                                    }
                                                    Haptics.light()
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

            OrderAPI.submitOrder(
                entries: entries,
                total: queued.total,
                diningMode: DiningMode(rawValue: queued.diningMode) ?? .dineIn,
                source: "cashpoint",
                customerName: nil,
                customerPhone: nil
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
        for (k, v) in UserDefaults.standard.dictionaryRepresentation() where k.hasPrefix(prefix) {
            if let b = v as? Bool, let id = Int(k.replacingOccurrences(of: prefix, with: "")) {
                state[id] = b
            }
        }
    }

    func isOn(_ productId: Int) -> Bool {
        state[productId] ?? true  // default ON
    }

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
                    self.pending.remove(productId)
                    if !ok {
                        self.state[productId] = old
                        UserDefaults.standard.set(old, forKey: self.prefix + String(productId))
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
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return false
            }
            return true
        } catch {
            return false
        }
    }
}


