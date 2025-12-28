import SwiftUI
import Kingfisher
import PassKit
import StoreKit
import UIKit
import StripeCore
import StripeApplePay
import StripePayments

private enum MenuTheme {

    // Helper to read miniAppId
    private static var miniId: Int {
        UserDefaults.standard.integer(forKey: "miniAppId")
    }

    // Helper + convenience
    private static func hex(_ hex: String) -> Color {
        Color(Color(hex: hex))
    }

    // MAIN COLORS
    static var accent: Color {
        if miniId == 3 {
            // Beigel Bake red
            return hex("#d71201")
        }

        // Default logic (Fastlane / MiniMe etc.)
        return Color(UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(Color(hex: "#b39d82"))
                : UIColor(Color(hex: "#324E57"))
        })
    }

    static var buttonBackground: Color {
        if miniId == 3 {
            return hex("#d71201")   // always red
        }
        return hex("#324E57")
    }

    static var textColor: Color {
        // If you want text to also change for 3:
        if miniId == 3 {
            return .primary   // or use .white if needed
        }
        return .primary
    }
}
private func alignPreset(
    _ preset: (options: [String:String], additions: Set<String>),
    to item: ShellMenuItem
) -> (options: [String:String], additions: Set<String>) {

    func norm(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{200F}", with: "")
            .replacingOccurrences(of: "\u{200E}", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    var alignedOptions: [String:String] = [:]
    var alignedAdds: Set<String> = []

    guard let groups = item.modifiers else {
        return (preset.options, preset.additions)
    }

    // ✅ Options: re-key using the real group.title
    for g in groups where g.type == .options {
        let k = norm(g.title)
        if let v = preset.options.first(where: { norm($0.key) == k })?.value {
            alignedOptions[g.title] = v
        }
    }

    // ✅ Additions: align by comparing normalized names
    let presetAddsNorm = Set(preset.additions.map(norm))
    for g in groups where g.type == .additions {
        for it in g.items {
            if presetAddsNorm.contains(norm(it.name)) {
                alignedAdds.insert(it.name) // keep original item.name
            }
        }
    }

    return (alignedOptions, alignedAdds)
}
struct ServiceSegment: View {
    @Environment(\.isRtl) private var isRtl
    @Environment(\.colorScheme) private var scheme
    @Binding var intent: ServiceIntent

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial) // ✅ auto light/dark
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(
                            Color.primary.opacity(scheme == .dark ? 0.25 : 0.12),
                            lineWidth: 1
                        )
                )

            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height

                // indicator
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(MenuTheme.buttonBackground)
                    .frame(width: (w / 2) - 6, height: h - 6)
                    .position(x: indicatorCenterX(totalWidth: w), y: h / 2)
                    .animation(.spring(response: 0.28, dampingFraction: 0.9), value: intent)
            }
            .padding(3)

            HStack(spacing: 0) {
                segButton(.sit)
                segButton(.ta)
            }
        }
        .frame(height: 46)
    }

    private func segButton(_ value: ServiceIntent) -> some View {
        Button {
            intent = value
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            Text(labelForIntent(value, isRtl: isRtl))
                .font(.menuRegular(16).weight(.semibold))
                .foregroundColor(intent == value ? .white : .primary.opacity(0.75))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(.plain)
    }

    private func indicatorCenterX(totalWidth w: CGFloat) -> CGFloat {
        // Left half = sit, Right half = ta (RTL/LTR doesn’t matter visually here)
        // If you want RTL to “default highlight right” like kiosk, swap logic here.
        return (intent == .sit) ? (w * 0.25) : (w * 0.75)
    }
}

private func parseSelectionSubtitle(_ subtitle: String?) -> (options: [String:String], additions: Set<String>) {
    guard let subtitle, !subtitle.isEmpty else { return ([:], []) }

    var options: [String:String] = [:]
    var additions: Set<String> = []

    subtitle.split(separator: ",").forEach { part in
        let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
        let comps = trimmed.split(separator: ":", maxSplits: 1)
        if comps.count == 2 {
            let key = comps[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = comps[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty, !value.isEmpty { options[key] = value }
        } else if !trimmed.isEmpty {
            additions.insert(trimmed)
        }
    }

    return (options, additions)
}

enum OrderPhase: String, Codable {
    case inProgress
    case ready
}

fileprivate func menuFontName() -> String {
    // 1) JSON customization → "Oswald", "Primaries DemiBold", etc.
    if let stored = UserDefaults.standard.string(forKey: "fontName"),
       !stored.isEmpty,
       stored != "System" {
        return stored
    }
    // 2) Fallback to your original Primaries font
    return primariesFontName
}

extension Font {
    static func primariesDemi(_ size: CGFloat) -> Font {
        .custom(menuFontName(), size: size)
    }

    // Optional helper for regular weight (where you used primariesFontName directly)
    static func menuRegular(_ size: CGFloat) -> Font {
        .custom(menuFontName(), size: size)
    }
}
private func anchorId(for category: String) -> String { "anchor-\(category)" }
private let stickyHeaderHeight: CGFloat = 60

struct menuView: View {
    @Environment(\.isRtl) var isRtl
    @Environment(\.dismiss) private var dismiss
    @StateObject private var api = MenuApiModel()
    @State private var selectedBasketLineId: Int? = nil
    @State private var selectedCategory: String = ""
    @State private var selectedItem: ShellMenuItem? = nil
    @State private var basket: [Int: BasketEntry] = [:]
    @State private var nextBasketLineId = 1
    @State private var showBasketSheet = false
    @State private var showConfirmation = false
    @AppStorage("miniAppId") private var miniAppId: Int = 0    // 👈 Use this instead of shopId
    @State private var lastOrder: OrderSnapshot?
    @State private var confirmationOrder: OrderSnapshot?
    @State private var categorySyncResumeAt: Date = .distantPast
    @State private var showShareSheet = false
    @AppStorage("deliveryLoc") private var deliveryLoc: String = ""
    @State private var showDiscountToast = false
    @State private var toastText = ""
    @State private var myItems: [MyItem] = []
    @State private var myItemsPreset: (options: [String:String], additions: Set<String>)? = nil
    @State private var productSheetNonce: Int = 0
    @AppStorage("checkout.intent") private var checkoutIntentRaw: String = ""
    @State private var serviceIntent: ServiceIntent = .ta
    @AppStorage(CheckoutKeys.didShowWelcome) private var didShowWelcome: Bool = false
    @State private var showWelcome: Bool = false
    
    private func reloadMyItems() {
        myItems = MyItemsStore.load()
    }
    
    
    private var forceDark: Bool {
        !deliveryLoc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    @AppStorage("isLastOrderReady") private var isLastOrderReady: Bool = false  // 👈 ADD THIS
    private func quantityInBasket(for item: ShellMenuItem) -> Int {
        basket.values.filter { $0.item.id == item.id }.reduce(0) { $0 + $1.quantity }
    }

    private func markLastOrderReadyIfMatches(orderNumber readyId: Int) {
        print("🔁 markLastOrderReadyIfMatches called with readyId =", readyId,
              "current lastOrder =", lastOrder?.orderNumber as Any)

        guard var snapshot = lastOrder else {
            print("⚠️ No lastOrder snapshot active, ignoring ready state")
            return
        }
        snapshot.phase = .ready
        lastOrder = snapshot
        saveLastOrderPersisted(snapshot)
        print("✅ lastOrder.phase updated to .ready")
    }
    
    private func optionsFromSubtitle(_ subtitle: String?) -> [String: String] {
        guard let subtitle, !subtitle.isEmpty else { return [:] }
        var result: [String: String] = [:]
        subtitle.split(separator: ",").forEach { part in
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            let comps = trimmed.split(separator: ":", maxSplits: 1)
            if comps.count == 2 {
                let key = comps[0].trimmingCharacters(in: .whitespaces)
                let value = comps[1].trimmingCharacters(in: .whitespaces)
                result[key] = value
            }
        }
        return result
    }
    
    struct OrderSnapshot: Identifiable {
        let id = UUID()
        let orderNumber: Int
        let entries: [BasketEntry]
        let totalPrice: Double
        let diningMode: DiningMode
        var phase: OrderPhase        // 👈 NEW
    }

    private struct PersistedEntry: Codable {
        let name: String
        let quantity: Int
        let unitPrice: Double
        let subtitle: String?
    }
    // 🔹 Only for saving to UserDefaults (minimal payload)
    private struct PersistedLastOrder: Codable {
        let orderNumber: Int
        let totalPrice: Double
        let diningModeRaw: String
        let entries: [PersistedEntry]
        let phaseRaw: String         // 👈 NEW
        let expiresAt: Date
    }
    private let lastOrderDefaultsKey = "menu.lastOrderBanner"

    
    private func saveLastOrderPersisted(_ snapshot: OrderSnapshot) {
        let expiresAt = Date().addingTimeInterval(30 * 60)   // 30 minutes

        let persistedEntries: [PersistedEntry] = snapshot.entries.map {
            PersistedEntry(
                name: $0.item.name,
                quantity: $0.quantity,
                unitPrice: $0.unitPrice,
                subtitle: $0.subtitle
            )
        }

        let persisted = PersistedLastOrder(
            orderNumber: snapshot.orderNumber,
            totalPrice: snapshot.totalPrice,
            diningModeRaw: snapshot.diningMode.rawValue,
            entries: persistedEntries,
            phaseRaw: snapshot.phase.rawValue,   // 👈 NEW
            expiresAt: expiresAt
        )

        if let data = try? JSONEncoder().encode(persisted) {
            UserDefaults.standard.set(data, forKey: lastOrderDefaultsKey)
        }
    }
    

    private func loadLastOrderPersistedIfValid() {
        guard
            let data = UserDefaults.standard.data(forKey: lastOrderDefaultsKey),
            let persisted = try? JSONDecoder().decode(PersistedLastOrder.self, from: data)
        else { return }

        if persisted.expiresAt < Date() {
            UserDefaults.standard.removeObject(forKey: lastOrderDefaultsKey)
            return
        }

        let mode = DiningMode(rawValue: persisted.diningModeRaw) ?? .dineIn
        let phase = OrderPhase(rawValue: persisted.phaseRaw) ?? .inProgress

        var rebuiltEntries: [BasketEntry] = []
        for (index, e) in persisted.entries.enumerated() {
            let shell = ShellMenuItem(
                id: index,
                name: e.name,
                price: e.unitPrice,
                category: "",
                modifiers: nil,
                imageURL: nil,
                description: nil
            )
            let entry = BasketEntry(
                id: index,
                item: shell,
                quantity: e.quantity,
                subtitle: e.subtitle,
                unitPrice: e.unitPrice
            )
            rebuiltEntries.append(entry)
        }

        let snapshot = OrderSnapshot(
            orderNumber: persisted.orderNumber,
            entries: rebuiltEntries,
            totalPrice: persisted.totalPrice,
            diningMode: mode,
            phase: phase                               // 👈 restore phase
        )

        lastOrder = snapshot
    }

    private func clearPersistedLastOrder() {
        UserDefaults.standard.removeObject(forKey: lastOrderDefaultsKey)
    }
    
    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    private var items: [ShellMenuItem] {
        api.items.filter { $0.isAvailable }
    }
    private var basketTotalQuantity: Int { basket.values.reduce(0) { $0 + $1.quantity } }
    private var basketTotalPrice: Double { basket.values.reduce(0) { $0 + Double($1.quantity) * $1.unitPrice } }

    private func addToBasket(_ item: ShellMenuItem, quantity: Int, subtitle: String?, unitPrice: Double) {
        let hasModifiers = !(item.modifiers?.isEmpty ?? true)

        if let lineId = selectedBasketLineId {
            if quantity <= 0 {
                basket[lineId] = nil
            } else if let existing = basket[lineId] {
                basket[lineId] = BasketEntry(id: lineId, item: existing.item, quantity: quantity, subtitle: subtitle, unitPrice: unitPrice)
            }
            selectedBasketLineId = nil
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            return
        }

        if hasModifiers {
            guard quantity > 0 else { return }
            let lineId = nextBasketLineId
            nextBasketLineId += 1
            basket[lineId] = BasketEntry(id: lineId, item: item, quantity: quantity, subtitle: subtitle, unitPrice: unitPrice)
        } else {
            if let (lineId, existing) = basket.first(where: { $0.value.item.id == item.id }) {
                if quantity <= 0 {
                    basket[lineId] = nil
                } else {
                    basket[lineId] = BasketEntry(id: lineId, item: existing.item, quantity: quantity, subtitle: subtitle, unitPrice: unitPrice)
                }
            } else {
                guard quantity > 0 else { return }
                let lineId = nextBasketLineId
                nextBasketLineId += 1
                basket[lineId] = BasketEntry(id: lineId, item: item, quantity: quantity, subtitle: subtitle, unitPrice: unitPrice)
            }
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
    
    private struct MyItemsStrip: View {
        let items: [MyItem]
        let isRtl: Bool
        let onTap: (Int) -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text(isRtl ? "הפריטים שלי" : "My items")
                    .font(.menuRegular(15).weight(.semibold))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 2)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(items.prefix(8)) { it in
                            Button { onTap(it.id) } label: {
                                MyItemChip(item: it, isRtl: isRtl)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 2)
                }
                .scrollIndicators(.hidden)
            }
            .padding(.top, 2)
            .padding(.bottom, 4)
        }
    }

    private struct MyItemChip: View {
        let item: MyItem
        let isRtl: Bool

        var body: some View {
            HStack(spacing: 10) {
                if let s = item.imageURL, let url = URL(string: s) {
                    KFImage(url)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(.systemGray5))
                        .frame(width: 44, height: 44)
                        .overlay(
                            Image(systemName: "fork.knife")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.secondary)
                        )
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.menuRegular(14).weight(.semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    // subtle price (optional)
                    Text(isRtl ? String(Int(item.lastPrice)) : "£\(String(format: "%.2f", item.lastPrice))")
                        .font(.menuRegular(13))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func incrementEntry(_ id: Int) {
        guard let entry = basket[id] else { return }
        basket[id]?.quantity = entry.quantity + 1
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func decrementEntry(_ id: Int) {
        guard let entry = basket[id] else { return }
        let newQty = entry.quantity - 1
        if newQty <= 0 {
            basket[id] = nil
        } else {
            basket[id]?.quantity = newQty
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private var availableCategories: [String] {
        var ordered: [String] = []
        var seen = Set<String>()
        for item in items where !seen.contains(item.category) {
            seen.insert(item.category)
            ordered.append(item.category)
        }
        return ordered
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemBackground).ignoresSafeArea()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                            VStack(spacing: 8) {
                                HStack {
                                    // Leading back chevron (left for LTR, right for RTL)
#if !APPCLIP
   // Leading back button (only in full app)
   Button {
       dismiss()
   } label: {
       Image(systemName: isRtl ? "chevron.right" : "chevron.left")
           .font(.system(size: 17, weight: .semibold))
           .foregroundColor(.primary)
           .frame(width: 32, height: 32)
           .background(.ultraThinMaterial)
           .clipShape(Circle())
   }
   #endif

                                    Spacer()

                                    // Trailing share button
                                    HStack(spacing: 20) {
                                        Button { showShareSheet = true } label: {
                                            Image(systemName: "arrowshape.turn.up.forward")
                                                .font(.system(size: 22, weight: .semibold))
                                        }
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.top, 8)

                                VStack(spacing: 5) {
                                    Text(isRtl ? "תפריט בוקר" : "Beigel Bake · Brick Ln")
                                        .padding(.top, 15)
                                        .font(.menuRegular(28).weight(.semibold))   // medium / bold

                                    Text(isRtl ? "הזמינו מהטלפון ונעדכן כשמוכן" : "Delivered in around 20 minutes")
                                        .font(.primariesDemi(isRtl ? 15 : 18))
                                        .foregroundColor(
                                            Color(UIColor { trait in
                                                trait.userInterfaceStyle == .dark
                                                    ? UIColor(Color.primary)      // dark → primary
                                                    : UIColor.secondaryLabel      // light → secondary
                                            })
                                        )
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.bottom, 12)
                            }
                            .padding(.bottom, 8)
                            
                            ServiceSegment(intent: $serviceIntent)
                                .padding(.horizontal, 16)
                                .padding(.top, 8)
                                .padding(.bottom, 20)
                                .onChange(of: serviceIntent) { new in
                                    checkoutIntentRaw = new.rawValue
                                    UserDefaults.standard.set(new == .sit ? "לשבת" : "לקחת", forKey: "serviceModeLabel")
                                }
                                
                            
                            if let order = lastOrder {
                                OrderInProcessBanner(orderNumber: order.orderNumber, phase: order.phase) {
                                    confirmationOrder = order
                                    showConfirmation = true
                                }
                                .padding(.horizontal, 16)
                                .padding(.bottom, 12)
                            }
                            
                            if !myItems.isEmpty {
                                MyItemsStrip(
                                    items: myItems,
                                    isRtl: isRtl
                                ) { productId in
                                    // open product sheet
                                 

                                    if let item = items.first(where: { $0.id == productId }) {
                                        selectedBasketLineId = nil

                                        if let saved = myItems.first(where: { $0.id == productId }) {
                                            let parsed = parseSelectionSubtitle(saved.lastSubtitle)

                                            // ✅ real fix: map saved preset to live modifier group titles + item names
                                            let aligned = alignPreset(parsed, to: item)
                                            myItemsPreset = aligned

                                            print("⭐️ MyItem subtitle:", saved.lastSubtitle as Any)
                                            print("⭐️ Parsed options:", parsed.options)
                                            print("⭐️ Parsed additions:", parsed.additions)
                                            print("✅ Aligned options:", aligned.options)
                                            print("✅ Aligned additions:", aligned.additions)
                                        } else {
                                            myItemsPreset = nil
                                        }
                                        productSheetNonce += 1

                                        DispatchQueue.main.async {
                                            selectedItem = item
                                        }
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.bottom, 12)
                            }
                            
                            

                            Section {
                                ForEach(availableCategories, id: \.self) { category in
                                    GeometryReader { geo in
                                        Color.clear.preference(
                                            key: CategoryPositionKey.self,
                                            value: [category: geo.frame(in: .named("menuScroll")).minY]
                                        )
                                    }
                                    .frame(height: 0)
                                    Color.clear
                                        .frame(height: stickyHeaderHeight)
                                        .padding(.bottom, 15)
                                        .id(anchorId(for: category))
                                    VStack(alignment: .leading, spacing: 12) {
                                        Text(category)
                                            .font(.menuRegular(20).weight(.semibold))   // medium / bold
                                            .padding(.horizontal, 16)
                                        LazyVGrid(columns: columns, spacing: 12) {
                                            ForEach(items.filter { $0.category == category }) { item in
                                                let qty = quantityInBasket(for: item)
                                                let badgeQty: Int? = qty > 0 ? qty : nil
                                                Button {
                                                    selectedBasketLineId = nil
                                                    productSheetNonce += 1

                                                    selectedItem = item
                                                } label: {
                                                    ProductCard(item: item, quantityInBasket: badgeQty)
                                                }
                                                .buttonStyle(CardPressStyle())
                                            }
                                        }
                                        .padding(.horizontal, 16)
                                        .padding(.bottom, 16)
                                        
                                    }
                                    .padding(.top, -stickyHeaderHeight + 50)
                                }
                            } header: {
                                CategoryBar(
                                    categories: availableCategories,
                                    selected: selectedCategory,
                                    onTap: { cat in
                                        categorySyncResumeAt = Date().addingTimeInterval(2)
                                        selectedCategory = cat
                                        withAnimation(.easeInOut) {
                                            proxy.scrollTo(anchorId(for: cat), anchor: .top)
                                        }
                                    }
                                )
                            }
                        }
                        .padding(.bottom, 60)
                    }
                    .coordinateSpace(name: "menuScroll")
                }
                .onPreferenceChange(CategoryPositionKey.self) { positions in
                    guard Date() >= categorySyncResumeAt, !positions.isEmpty else { return }
                    let sorted = positions.sorted { $0.value < $1.value }
                    if let visible = sorted.first(where: { $0.value >= 0 }) ?? sorted.first {
                        if visible.key != selectedCategory {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                selectedCategory = visible.key
                            }
                        }
                    }
                }
                NavigationLink("", isActive: $showConfirmation) {
                    Group {
                        if let order = confirmationOrder ?? lastOrder {
                            OrderConfirmationView(
                                orderNumber: order.orderNumber,
                                entries: order.entries,
                                totalPrice: order.totalPrice,
                                diningMode: order.diningMode
                            )
                            .environment(\.isRtl, isRtl)
                            .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
                        } else {
                            EmptyView()
                        }
                    }
                }
                .hidden()
                .navigationTitle("")
                .navigationBarHidden(true)
            }
        }
        .foregroundColor(MenuTheme.textColor)
        .onReceive(NotificationCenter.default.publisher(for: .myItemsChanged)) { _ in
            reloadMyItems()
        }
        .onChange(of: checkoutIntentRaw) { newValue in
            serviceIntent = ServiceIntent(rawValue: newValue) ?? .ta
        }
        .onChange(of: api.items.count) { count in
            guard count > 0 else { return }   // ✅ menu finished loading

            if !didShowWelcome &&
               checkoutIntentRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {

                // ensure it's not during layout pass
                DispatchQueue.main.async {
                    showWelcome = true
                }
            }
        }
        .onAppear {
           
            serviceIntent = ServiceIntent(rawValue: checkoutIntentRaw) ?? .ta
               if !api.items.isEmpty {
                   let first = api.items[0]
                   print("🧭 menuView.onAppear → first item: \(first.name) [\(first.category)] (total \(api.items.count))")
               } else {
                   print("🧭 menuView.onAppear → api.items is empty at appear")
               }

            saveReferralForCurrentShop(kind: .fastlane)
            api.load()
            reloadMyItems()
            //loadLastOrderPersistedIfValid()
            // ✅ One-time toast when discount becomes active
            if let disc = MinisShared.loadActiveDiscount(),
               disc.percent > 0,
               !DiscountToast.alreadyShown(campaignId: disc.campaignId) {

                toastText = isRtl ? "הנחת סטודנט הופעלה ✓" : "Student discount applied ✓"
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    showDiscountToast = true
                }

                DiscountToast.markShown(campaignId: disc.campaignId)

                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                    withAnimation(.easeOut(duration: 0.25)) {
                        showDiscountToast = false
                    }
                }
            }

           
        }
        
        .onReceive(NotificationCenter.default.publisher(for: .orderReady)) { note in
            guard let userInfo = note.userInfo else { return }

            // 👇 Read status sent from the server ("ready" or "collected")
            let status = userInfo["status"] as? String

            if status == "collected" {
                // 🔻 Second (status=5) silent notification → hide banner
                print("🧹 Collected notification received, hiding banner. userInfo =", userInfo)

                // Option A: completely hide the banner
                lastOrder = nil
                clearPersistedLastOrder()

                // If you're using isLastOrderReady, also reset it:
                UserDefaults.standard.set(false, forKey: "isLastOrderReady")

                return
            }

            // For "ready" (status=4) or legacy behavior – keep your existing ready logic:
            let idFromInt  = userInfo["orderId"] as? Int
            let idFromString = (userInfo["orderId"] as? String).flatMap(Int.init)

            if let orderId = idFromInt ?? idFromString {
                print("✅ OrderReadyNotification received in view with orderId:", orderId,
                      "status =", status ?? "nil")
                markLastOrderReadyIfMatches(orderNumber: orderId)
            } else {
                print("⚠️ OrderReadyNotification received without valid orderId:", userInfo)
            }
        }
        .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
        .sheet(isPresented: $showShareSheet) {
            let shopId = UserDefaults.standard.string(forKey: "shopId") ?? "12"
            if let url = URL(string: "https://minis.studio/shop/\(shopId)") {
                QRShareSheet(url: url)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
        .overlay(alignment: .top) {
            GeometryReader { geo in
                Color(.systemBackground)
                    .frame(height: geo.safeAreaInsets.top)
                    .ignoresSafeArea(edges: .top)
            }
            .frame(height: 0)
        }
        .safeAreaInset(edge: .bottom) {
            if !basket.isEmpty {
                BasketBar(totalQuantity: basketTotalQuantity, totalPrice: basketTotalPrice) {
                    showBasketSheet = true
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(item: $selectedItem) { item in
            let existingQty = selectedBasketLineId.flatMap { basket[$0]?.quantity } ?? quantityInBasket(for: item)
            let existingOrNil = existingQty > 0 ? existingQty : nil
            let initialOptions: [String: String] = {
                if let lineId = selectedBasketLineId, let entry = basket[lineId] {
                    return optionsFromSubtitle(entry.subtitle)
                }
                return [:]
            }()
            let preset = myItemsPreset

            ProductSheet(
                item: item,
                initialQuantityInBasket: existingOrNil,
                initialSelectedOptions: preset?.options ?? initialOptions,
                initialSelectedAdditions: preset?.additions ?? [],
                useInitialQuantity: selectedBasketLineId != nil
            ) { product, qty, subtitle, unitPrice in
                addToBasket(product, quantity: qty, subtitle: subtitle, unitPrice: unitPrice)
            }
            .onDisappear {
                myItemsPreset = nil   // ✅ don’t leak to the next product
            }
            .id(productSheetNonce)
            .preferredColorScheme(forceDark ? .dark : nil)
            .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
        }
        .fullScreenCover(isPresented: $showWelcome) {
            KioskWelcomeView()
                .environment(\.isRtl, isRtl)
                .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
        }
        .sheet(isPresented: $showBasketSheet) {
            BasketSheet(
                entries: Array(basket.values),
                totalPrice: basketTotalPrice,
                onIncrement: { id in incrementEntry(id) },
                onDecrement: { id in decrementEntry(id) },
                onConfirm: { orderNumber, diningMode in
                    let snapshot = OrderSnapshot(
                        orderNumber: orderNumber,
                        entries: Array(basket.values),
                        totalPrice: basketTotalPrice,
                        diningMode: diningMode,
                        phase: .inProgress
                    )

                    // clear basket immediately
                    basket.removeAll()

                    // ensure Apple Pay + sheet animations finish
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        // 1) close basket sheet
                        showBasketSheet = false

                        // 2) go to confirmation
                        confirmationOrder = snapshot
                        showConfirmation = true

                        // 3) show ongoing banner later
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            lastOrder = snapshot
                            saveLastOrderPersisted(snapshot)
                        }
                    }
                },
                onProductTap: { lineId, item in
                    selectedBasketLineId = lineId
                    productSheetNonce += 1
                    selectedItem = item
                    showBasketSheet = false
                }
            )
            .preferredColorScheme(forceDark ? .dark : nil)
            .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
        }
    }
    
    private struct ToastBanner: View {
        let text: String
        var body: some View {
            Text(text)
                .font(.menuRegular(15).weight(.semibold))
                .foregroundColor(.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(radius: 10, y: 6)
        }
    }

    private enum DiscountToast {
        static func key(for campaignId: String) -> String { "toastShown.discount.\(campaignId)" }

        static func alreadyShown(campaignId: String) -> Bool {
            MinisShared.sharedDefaults.bool(forKey: key(for: campaignId))
        }

        static func markShown(campaignId: String) {
            MinisShared.sharedDefaults.set(true, forKey: key(for: campaignId))
            MinisShared.sharedDefaults.synchronize()
        }
    }
}

struct CategoryBar: View {
    let categories: [String]
    let selected: String
    let onTap: (String) -> Void
    @Namespace private var underlineNS
    private let highlightColor = MenuTheme.accent
    @Environment(\.isRtl) private var isRtl
    
    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(categories, id: \.self) { cat in
                            Button { onTap(cat) } label: {
                                VStack(spacing: 0) {
                                    Text(cat)
                                        .font(.primariesDemi(isRtl ? 15 : 17))
                                        .foregroundColor(
                                            Color(UIColor { trait in
                                                if cat == selected {
                                                    return trait.userInterfaceStyle == .dark
                                                        ? UIColor(Color.primary)
                                                        : UIColor(highlightColor)
                                                } else {
                                                    return UIColor(Color.primary)   // ✅ always primary
                                                }
                                            })
                                        )
                                    if cat == selected {
                                        Rectangle()
                                            .fill(
                                                Color(UIColor { trait in
                                                    trait.userInterfaceStyle == .dark
                                                    ? UIColor.label          // or .white / .primary-equivalent
                                                    : UIColor(highlightColor)
                                                })
                                            )
                                            .frame(height: 2)
                                            .padding(.top, 15)
                                            .matchedGeometryEffect(id: "underline", in: underlineNS)
                                    } else {
                                        Rectangle()
                                            .fill(Color.clear)
                                            .frame(height: 2)
                                            .padding(.top, 15)
                                    }
                                }
                                .padding(.horizontal, 4)
                                .padding(.top, 4)
                            }
                            .buttonStyle(.plain)
                            .id(cat)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                }
                .onChange(of: selected) { new in
                    guard !new.isEmpty else { return }
                    withAnimation(.easeInOut) { proxy.scrollTo(new, anchor: .center) }
                }
                .onAppear {
                    guard !selected.isEmpty else { return }
                    proxy.scrollTo(selected, anchor: .center)
                }
            }
            Rectangle()
                .fill(Color.black.opacity(0.06))
                .frame(height: 1)
        }
        .background(
            Color(.systemBackground)
                .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
        )
    }
}

struct RoundedCornerShape: Shape {
    var radius: CGFloat
    var corners: UIRectCorner
    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}

struct ProductCard: View {
    let item: ShellMenuItem
    let quantityInBasket: Int?
    @State private var badgeBounce = false
    @Environment(\.isRtl) private var isRtl
    
    private var priceLabel: String {
        if isRtl {
            // Existing Hebrew/RTL behavior
            return String(format: "%.0f", item.price)
        } else {
            // English / LTR → Pound sign with 2 decimals
            return String(format: "£%.2f", item.price)
        }
    }
    var body: some View {
        GeometryReader { geo in
            let cellWidth = geo.size.width
            ZStack(alignment: .topTrailing) {
                VStack(alignment: .leading, spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 18)
                            .fill(Color(.systemGray5))
                            .frame(width: cellWidth, height: cellWidth)
                        KFImage(item.img)
                            .placeholder { Color.clear }
                            .resizable()
                            .scaledToFill()
                            .frame(width: cellWidth, height: cellWidth)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                    }
                    Text(item.name)
                        .font(.menuRegular(17).weight(.semibold))   // medium / bold
                        .lineLimit(2)
                        .padding(.leading, 5)
                    Text(priceLabel)
                        .padding(.leading, 5)
                        .font(.menuRegular(15))   // or .custom(menuFontName(), size: 15)
                        .foregroundColor(
                            Color(UIColor { trait in
                                trait.userInterfaceStyle == .dark
                                    ? UIColor(Color.primary).withAlphaComponent(0.8)       // dark → primary
                                    : UIColor(MenuTheme.accent)     // light → accent
                            })
                        )
                }
              
                .frame(width: cellWidth, alignment: .topLeading)
                if let qty = quantityInBasket, qty > 0 {
                    Text("\(qty)")
                        .font(.menuRegular(15).weight(.semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedCornerShape(
                                radius: 16,
                                corners: isRtl ? [.topRight, .bottomLeft] : [.topRight, .bottomLeft]
                            )
                            .fill(MenuTheme.buttonBackground)
                        )
                        .padding(.top, 0)
                        .padding(.leading, 8)
                        .zIndex(1)
                }
            }
        }
        .frame(height: UIScreen.main.bounds.width / 2 + 40)
    }
}
struct FlowLayout<Data: RandomAccessCollection, Content: View>: View
where Data.Element: Identifiable {

    let data: Data
    let spacing: CGFloat
    let rowSpacing: CGFloat
    let content: (Data.Element) -> Content

    init(
        data: Data,
        spacing: CGFloat = 8,
        rowSpacing: CGFloat = 8,
        @ViewBuilder content: @escaping (Data.Element) -> Content
    ) {
        self.data = data
        self.spacing = spacing
        self.rowSpacing = rowSpacing
        self.content = content
    }

    var body: some View {
        GeometryReader { geo in
            generateContent(in: geo)
        }
    }

    private func generateContent(in geo: GeometryProxy) -> some View {
        var x: CGFloat = 0
        var y: CGFloat = 0

        return ZStack(alignment: .topLeading) {
            ForEach(data) { element in
                content(element)
                    .alignmentGuide(.leading) { d in
                        if x + d.width > geo.size.width {
                            x = 0
                            y += d.height + rowSpacing
                        }
                        let result = x
                        x += d.width + spacing
                        return result
                    }
                    .alignmentGuide(.top) { _ in y }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@available(iOS 16.0, *)
struct Flow: Layout {
    var spacing: CGFloat = 10
    var rowSpacing: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? UIScreen.main.bounds.width
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for s in subviews {
            let size = s.sizeThatFits(.unspecified)

            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + rowSpacing
                rowHeight = 0
            }

            x += size.width + (x == 0 ? 0 : spacing)
            rowHeight = max(rowHeight, size.height)
        }

        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for s in subviews {
            let size = s.sizeThatFits(.unspecified)

            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + rowSpacing
                rowHeight = 0
            }

            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))

            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}


struct ModifierListView: View {
    let groups: [ModifierGroup]
    @Environment(\.isRtl) private var isRtl
    @Binding var selectedOptions: [String: String]
    @Binding var selectedAdditions: Set<String>

    private func norm(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{200F}", with: "")
            .replacingOccurrences(of: "\u{200E}", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: " ") // nbsp -> space
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 10) {

                        Text(displayTitle(for: group))
                            .font(.menuRegular(18).weight(.semibold))
                            .padding(.horizontal, 18)
                            .padding(.bottom, 5)

                        if #available(iOS 16.0, *) {
                            Flow(spacing: 10, rowSpacing: 10) {
                                ForEach(group.items) { item in
                                    pill(group: group, item: item)
                                }
                            }
                            .padding(.horizontal, 18)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 76), spacing: 10, alignment: .leading)],
                                alignment: .leading,
                                spacing: 10
                            ) {
                                ForEach(group.items) { item in
                                    pill(group: group, item: item)
                                }
                            }
                            .padding(.horizontal, 18)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.bottom, group.type == .additions ? 40 : 0)
                }
            }
            .padding(.vertical, 12)
        }
    }

    private func pill(group: ModifierGroup, item: ModifierItem) -> some View {
        let gKey = norm(group.title)
        let iName = norm(item.name)

        let isSelected: Bool = {
            switch group.type {
            case .options:
                return norm(selectedOptions[gKey] ?? "") == iName
            case .additions:
                return selectedAdditions.contains(iName)
            }
        }()

        return Text(item.extraPrice > 0 ? "\(item.name) +\(Int(item.extraPrice))" : item.name)
            .font(.menuRegular(isRtl ? 15 : 17))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .fixedSize(horizontal: true, vertical: false)
            .background(isSelected ? MenuTheme.accent : Color(.systemGray5))
            .foregroundColor(isSelected ? .white : MenuTheme.textColor)
            .clipShape(Capsule())
            .onTapGesture {
                handleTap(group: group, item: item)
                Haptics.light()
            }
    }

    private func handleTap(group: ModifierGroup, item: ModifierItem) {
        let gKey = norm(group.title)
        let iName = norm(item.name)

        switch group.type {
        case .options:
            selectedOptions[gKey] = iName
        case .additions:
            if selectedAdditions.contains(iName) {
                selectedAdditions.remove(iName)
            } else {
                selectedAdditions.insert(iName)
            }
        }
    }

    private func displayTitle(for group: ModifierGroup) -> String {
        switch group.type {
        case .additions: return isRtl ? group.title : "Choose additions"
        case .options:   return group.title
        }
    }
}

struct ProductSheet: View {
    let item: ShellMenuItem
    let initialQuantityInBasket: Int?
    let initialSelectedOptions: [String: String]
    let initialSelectedAdditions: Set<String>
    let useInitialQuantity: Bool
    let onAdd: (ShellMenuItem, Int, String?, Double) -> Void

    @State private var quantity: Int
    @State private var contentHeight: CGFloat = 500
    @State private var heroFrozenImage: KFCrossPlatformImage? = nil
    @State private var selectedOptions: [String: String] = [:]
    @State private var selectedAdditions: Set<String> = []

    @Environment(\.dismiss) private var dismiss
    @Environment(\.isRtl) private var isRtl

    @State private var inMyItems = false

    private func norm(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{200F}", with: "")
            .replacingOccurrences(of: "\u{200E}", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    init(
        item: ShellMenuItem,
        initialQuantityInBasket: Int?,
        initialSelectedOptions: [String: String],
        initialSelectedAdditions: Set<String> = [],
        useInitialQuantity: Bool,
        onAdd: @escaping (ShellMenuItem, Int, String?, Double) -> Void
    ) {
        self.item = item
        self.initialQuantityInBasket = initialQuantityInBasket
        self.initialSelectedOptions = initialSelectedOptions
        self.initialSelectedAdditions = initialSelectedAdditions
        self.useInitialQuantity = useInitialQuantity
        self.onAdd = onAdd

        let hasModifiers = !(item.modifiers?.isEmpty ?? true)
        let baseQty = initialQuantityInBasket ?? 1
        let startQty = (hasModifiers && !useInitialQuantity) ? 1 : baseQty
        _quantity = State(initialValue: startQty)

        // ✅ OPTIONS: default to first item (then normalize keys/values)
        var defaults: [String: String] = initialSelectedOptions
        if initialSelectedOptions.isEmpty, let groups = item.modifiers {
            for group in groups where group.type == .options {
                if let first = group.items.first {
                    defaults[group.title] = first.name
                }
            }
        }

        let normalizedDefaults: [String: String] =
            Dictionary(uniqueKeysWithValues: defaults.map { (norm($0.key), norm($0.value)) })
        _selectedOptions = State(initialValue: normalizedDefaults)

        // ✅ ADDITIONS: normalize
        _selectedAdditions = State(initialValue: Set(initialSelectedAdditions.map(norm)))
    }

    private var hasModifiers: Bool { !(item.modifiers?.isEmpty ?? true) }
    private var isUpdateMode: Bool { (initialQuantityInBasket ?? 0) > 0 }
    private var isRemoveMode: Bool { isUpdateMode && useInitialQuantity && quantity == 0 }

    private func extraPricePerUnit() -> Double {
        guard let groups = item.modifiers else { return 0 }
        return groups.reduce(0) { total, group in
            switch group.type {
            case .options:
                let gKey = norm(group.title)
                if let selectedName = selectedOptions[gKey] {
                    if let opt = group.items.first(where: { norm($0.name) == norm(selectedName) }) {
                        return total + opt.extraPrice
                    }
                }
                return total

            case .additions:
                let selectedSet = Set(selectedAdditions.map(norm))
                return total + group.items
                    .filter { selectedSet.contains(norm($0.name)) }
                    .map { $0.extraPrice }
                    .reduce(0, +)
            }
        }
    }

    private var totalPriceLabel: String {
        let extras = extraPricePerUnit()
        let total = (item.price + extras) * Double(max(quantity, 0))
        return isRtl ? String(format: "%.2f", total) : String(format: "£%.2f", total)
    }

    private var detents: Set<PresentationDetent> {
        let screenH = UIScreen.main.bounds.height
        return [.height(min(contentHeight + 40, screenH * 0.88)), .large]
    }

    private var unitPriceLabel: String {
        if isRtl { return String(format: "%.0f", item.price) }
        return String(format: "£%.2f", item.price)
    }

    private func subtitleFromSelection() -> String? {
        guard let groups = item.modifiers else { return nil }

        var parts: [String] = []

        for group in groups where group.type == .options {
            let gKey = norm(group.title)
            guard let selected = selectedOptions[gKey],
                  let first = group.items.first
            else { continue }

            if norm(selected) != norm(first.name) {
                parts.append("\(norm(group.title)): \(norm(selected))")
            }
        }

        let addNames = selectedAdditions
            .map(norm)
            .sorted()
            .filter { !$0.isEmpty }

        if !addNames.isEmpty {
            parts.append(addNames.joined(separator: ", "))
        }

        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color(.systemBackground).ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ZStack {
                        if let img = heroFrozenImage {
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFill()
                        } else {
                            KFImage(item.img)
                                .onSuccess { heroFrozenImage = $0.image }
                                .placeholder {
                                    Rectangle()
                                        .fill(Color(.systemGray5))
                                        .overlay(ProgressView())
                                }
                                .resizable()
                                .scaledToFill()
                        }
                    }
                    .frame(width: UIScreen.main.bounds.width, height: 320)
                    .clipped()
                    .ignoresSafeArea(edges: .top)

                    VStack(alignment: .leading, spacing: 10) {
                        Text(item.name)
                            .font(.menuRegular(20).weight(.semibold))

                        Text(unitPriceLabel)
                            .font(.menuRegular(20).weight(.regular))
                            .foregroundColor(
                                Color(UIColor { trait in
                                    trait.userInterfaceStyle == .dark
                                    ? UIColor(Color.primary)
                                    : UIColor(MenuTheme.accent)
                                })
                            )

                        if let desc = item.description, !desc.isEmpty {
                            Text(desc)
                                .font(.menuRegular(16).weight(.regular))
                                .foregroundColor(.secondary)
                                .padding(.top, 6)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 6)

                    if inMyItems {
                        Button {
                            MyItemsStore.remove(productId: item.id)
                            inMyItems = false
                            Haptics.light()
                        } label: {
                            Text(isRtl ? "הסר מהפריטים שלי" : "Remove from My items")
                                .font(.menuRegular(14))
                                .foregroundColor(.secondary)
                                .padding(.top, 4)
                        }
                        .padding(.horizontal, 18)
                    }

                    if let groups = item.modifiers {
                        ModifierListView(
                            groups: groups,
                            selectedOptions: $selectedOptions,
                            selectedAdditions: $selectedAdditions
                        )
                        .padding(.top, 15)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.bottom, 60)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: SheetContentHeightKey.self, value: proxy.size.height)
                    }
                )
            }

            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.primary)
                    .frame(width: 32, height: 32)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
            }
            .padding(.top, 14)
            .padding(.trailing, 16)
        }
        .navigationBarHidden(true)
        .onAppear {
            inMyItems = MyItemsStore.load().contains(where: { $0.id == item.id })
        }
        .onPreferenceChange(SheetContentHeightKey.self) { contentHeight = $0 }
        .presentationDetents(detents)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                bottomBar.padding(.horizontal, 24)
            }
            .background(Color(.systemBackground))
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 16) {
            HStack(spacing: 22) {
                Button {
                    if useInitialQuantity {
                        if quantity > 0 { quantity -= 1 }
                    } else {
                        if hasModifiers {
                            if quantity > 1 { quantity -= 1 }
                        } else {
                            if quantity > 0 { quantity -= 1 }
                        }
                    }
                    Haptics.light()
                } label: {
                    Circle()
                        .fill(Color(.systemGray5))
                        .frame(width: 44, height: 44)
                        .overlay(
                            Image(systemName: "minus")
                                .font(.system(size: 18, weight: .bold))
                        )
                        .foregroundColor(.primary)
                }

                Text("\(quantity)")
                    .font(.custom(primariesFontName, size: 22))

                Button {
                    quantity += 1
                    Haptics.light()
                } label: {
                    Circle()
                        .fill(Color(.systemGray5))
                        .frame(width: 44, height: 44)
                        .overlay(
                            Image(systemName: "plus")
                                .font(.system(size: 18, weight: .bold))
                        )
                        .foregroundColor(.primary)
                }
            }
            .frame(height: 60)

            Button {
                let subtitle = subtitleFromSelection()
                let unit = item.price + extraPricePerUnit()

                if quantity > 0 {
                    MyItemsStore.touch(
                        productId: item.id,
                        name: item.name,
                        imageURL: item.imageURL,
                        price: unit,
                        subtitle: subtitle
                    )
                    inMyItems = true
                    print("🧪 MyItems DEBUG touch:", item.id, item.name, "subtitle:", subtitle as Any)
                }

                onAdd(item, quantity, subtitle, unit)
                Haptics.success()
                dismiss()
            } label: {
                HStack {
                    if isRtl {
                        Text(isRemoveMode ? "הסר" : (isUpdateMode ? "עדכן" : "הוסף"))
                            .font(.menuRegular(18).weight(.semibold))
                        Spacer()
                        Text(totalPriceLabel)
                            .font(.primariesDemi(18))
                    } else {
                        Text(isRemoveMode ? "Remove" : (isUpdateMode ? "Update" : "Add"))
                            .font(.system(size: 18, weight: .bold))
                        Spacer()
                        Text(totalPriceLabel)
                            .font(.primariesDemi(18))
                    }
                }
                .padding(.horizontal, 20)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 60)
                .background(isRemoveMode ? Color.red : MenuTheme.buttonBackground)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .frame(height: 60)
    }
}

struct BasketBar: View {
    @Environment(\.isRtl) private var isRtl
    let totalQuantity: Int
    let totalPrice: Double
    let onTap: () -> Void

    private var priceLabel: String {
        if isRtl {
            // RTL – no currency symbol
            return String(format: "%.2f", totalPrice)
        } else {
            // LTR – Pound, 2 decimals
            return String(format: "£%.2f", totalPrice)
        }
    }

    var body: some View {
        HStack {
            Button(action: onTap) {
                HStack {
                    // 👇 LEFT SIDE: badge + label (same order in both modes)
                    HStack(spacing: 12) {
                        Text("\(totalQuantity)")
                            .font(.menuRegular(15).weight(.semibold))
                            .foregroundColor(MenuTheme.buttonBackground)
                            .frame(width: 28, height: 28)
                            .background(Color.white)
                            .clipShape(Circle())

                        Text(isRtl ? "צפה בהזמנה" : "View order")
                            .font(.primariesDemi(18))
                            .foregroundColor(.white)
                    }

                    Spacer()

                    // 👇 RIGHT SIDE: price
                    Text(priceLabel)
                        .font(.menuRegular(18).weight(.semibold))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 20)
                .frame(height: 60)
                .frame(maxWidth: .infinity)
                .background(MenuTheme.buttonBackground)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, -12)
    }
}

struct ApplePayButtonView: UIViewRepresentable {
    func makeUIView(context: Context) -> PKPaymentButton {
        PKPaymentButton(paymentButtonType: .plain, paymentButtonStyle: .black)
    }
    func updateUIView(_ uiView: PKPaymentButton, context: Context) {}
}


struct BasketSheet: View {
    let entries: [BasketEntry]
    let totalPrice: Double
    let onIncrement: (Int) -> Void
    let onDecrement: (Int) -> Void
    let onConfirm: (Int, DiningMode) -> Void
    let onProductTap: (Int, ShellMenuItem) -> Void

    @State private var showOrderProgress = false
    @Environment(\.isRtl) private var isRtl
    @Environment(\.dismiss) private var dismiss
    @State private var contentHeight: CGFloat = 400
    @State private var diningMode: DiningMode = .dineIn
    @State private var isSubmitting = false
    @State private var submitError: String? = nil
    @State private var showNameSheet = false
    @State private var tempName: String = UserDefaults.standard.string(forKey: "userName") ?? ""
    @State private var tempPhone: String = UserDefaults.standard.string(forKey: "userPhone") ?? ""
    @State private var applePayHandler: ZCreditApplePayHandler? = nil
    @AppStorage("miniAppId") private var miniAppId: Int = 0
    @State private var stripeController: PKPaymentAuthorizationController? = nil
    

    // ✅ Discount from App Group
    @State private var activeDiscount: ActiveDiscount? = nil

    @State private var stripeTokenToSend: String? = nil
    @State private var stripeApplePay = StripeApplePayHandler()

    // ✅ Shared intent (read-only in basket)
    @AppStorage("checkout.intent") private var checkoutIntentRaw: String = ""

    private var stripeMerchantId: String { "merchant.hood23" }   // <-- replace

    private var discountPercent: Int { activeDiscount?.percent ?? 0 }

    private var discountAmount: Double {
        guard discountPercent > 0 else { return 0 }
        return (totalPrice * Double(discountPercent) / 100.0)
    }

    private func roundTotal(_ value: Double) -> Double {
        let floorValue = floor(value)
        let fraction = value - floorValue
        return fraction >= 0.5 ? ceil(value) : floorValue
    }

    private var discountedTotal: Double {
        let raw = max(0, totalPrice - discountAmount)
        return roundTotal(raw)
    }

    private var shownDiscountAmount: Double {
        max(0, roundTotal(totalPrice) - discountedTotal)
    }

    private var skipApplePay: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "debugSkipApplePay")
        #else
        return false
        #endif
    }

    private var detents: Set<PresentationDetent> {
        let screenH = UIScreen.main.bounds.height
        let maxCustom = screenH * 0.9
        let extra: CGFloat = (discountPercent > 0) ? 60 : 0
        let fitted = min(contentHeight + 160 + extra, maxCustom)
        return fitted < maxCustom ? [.height(fitted), .large] : [.large]
    }

    private enum ServiceIntent: String { case sit, ta }

    private var serviceLabel: String {
        let intent = ServiceIntent(rawValue: checkoutIntentRaw) ?? .ta
        if isRtl {
            return intent == .sit ? "לשבת" : "לקחת"
        } else {
            return intent == .sit ? "Dine-in" : "Takeaway"
        }
    }

    private func syncDiningModeFromIntent() {
        let intent = ServiceIntent(rawValue: checkoutIntentRaw) ?? .ta
        diningMode = (intent == .sit) ? .dineIn : .takeAway
    }

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            NavigationStack {
                ScrollView {
                    VStack(spacing: 16) {

                        // ✅ Read-only service row (no change from basket)
                       
                        ForEach(entries) { entry in
                            basketRow(entry)
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(key: BasketContentHeightKey.self, value: geo.size.height)
                        }
                    )
                }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Text(isRtl ? "ההזמנה שלך" : "Your order")
                            .font(.menuRegular(24).weight(.semibold))
                            .foregroundColor(MenuTheme.textColor)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(.primary)
                                .frame(width: 32, height: 32)
                                .background(.ultraThinMaterial)
                                .clipShape(Circle())
                        }
                    }
                }
                .onPreferenceChange(BasketContentHeightKey.self) { contentHeight = $0 }
                .onAppear {
                    activeDiscount = MinisShared.loadActiveDiscount()

                    if activeDiscount == nil, let claim = StudentDiscountHandoff.pullPendingClaim() {
                        let expires = Calendar.current.date(byAdding: .month, value: claim.durationMonths, to: Date())
                            ?? Date().addingTimeInterval(60 * 60 * 24 * 30 * Double(claim.durationMonths))

                        let disc = ActiveDiscount(
                            campaignId: claim.campaignId,
                            percent: claim.discountPercent,
                            expiresAt: expires
                        )

                        MinisShared.saveActiveDiscount(disc)
                        activeDiscount = disc
                    }

                    print("🎟️ BasketSheet discount:", activeDiscount as Any)

                    UserDefaults.standard.set(false, forKey: "debugSkipApplePay")

                    // ✅ always derive diningMode from the shared intent
                    syncDiningModeFromIntent()
                }
                .onChange(of: checkoutIntentRaw) { _ in
                    // ✅ if header changed while basket is open, keep this in sync
                    syncDiningModeFromIntent()
                }
            }
            .font(.menuRegular(15))
            .presentationDetents(detents)
            .safeAreaInset(edge: .bottom) { bottomArea }
            .overlay(
                Group {
                    if showOrderProgress {
                        OrderProgressView()
                            .transition(.opacity)
                            .zIndex(2)
                    }
                }
            )
            .sheet(isPresented: $showNameSheet) {
                NameSheetView(
                    name: $tempName,
                    phone: $tempPhone,
                    isRtl: isRtl,
                    needsPhone: (miniAppId == 3)
                ) { finalName, finalPhone in
                    let n = finalName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !n.isEmpty else { return }
                    UserDefaults.standard.set(n, forKey: "userName")

                    if miniAppId == 3 {
                        let p = finalPhone.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !p.isEmpty else { return }
                        UserDefaults.standard.set(p, forKey: "userPhone")
                    }

                    showNameSheet = false

                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        if miniAppId == 3 {
                            startStripeApplePay()
                        } else {
                            startZCreditApplePay()
                        }
                    }
                }
            }
        }
    }

    private func formatBasketTotal(_ value: Double) -> String {
        if isRtl { return String(format: "%.2f", value) }
        return String(format: "£%.2f", value)
    }

    private var bottomArea: some View {
        VStack(spacing: 14) {

            VStack(spacing: 12) {

                if discountPercent > 0 {
                    HStack {
                        Text(isRtl ? "סכום ביניים" : "Subtotal")
                            .font(.menuRegular(17).weight(.semibold))
                        Spacer()
                        Text(
                            isRtl
                            ? String(Int(roundTotal(totalPrice)))
                            : "£\(Int(roundTotal(totalPrice)))"
                        )
                        .font(.menuRegular(17).weight(.semibold))
                    }
                    .foregroundColor(.secondary)
                }

                if discountPercent > 0 {
                    HStack {
                        Text(isRtl ? "הנחה \(discountPercent)%" : "Discount \(discountPercent)%")
                            .font(.menuRegular(17).weight(.semibold))
                        Spacer()
                        Text(isRtl
                             ? "-\(String(format: "%.0f", shownDiscountAmount))"
                             : "-£\(String(format: "%.0f", shownDiscountAmount))")
                            .font(.menuRegular(17).weight(.semibold))
                    }
                    .foregroundColor(.secondary)
                }

                HStack {
                    Text(isRtl ? "סה\"כ" : "Total")
                        .font(.menuRegular(18).weight(.semibold))
                    Spacer()
                    Text(formatBasketTotal(discountedTotal))
                        .font(.menuRegular(18).weight(.semibold))
                }
            }
            .foregroundColor(.primary)
            .padding(.horizontal, 24)
            .padding(.top, 6)

            ZStack {
                ApplePayButtonView()
                    .frame(height: 56)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)

                Color.clear
                    .contentShape(Rectangle())
                    .frame(height: 56)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
                    .onTapGesture {
                        guard !isSubmitting else { return }

                        let storedName = (UserDefaults.standard.string(forKey: "userName") ?? "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)

                        let storedPhone = (UserDefaults.standard.string(forKey: "userPhone") ?? "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)

                        let needsPhone = (miniAppId == 3)
                        let missing = storedName.isEmpty || (needsPhone && storedPhone.isEmpty)

                        if missing {
                            tempName = storedName
                            tempPhone = storedPhone
                            showNameSheet = true
                            return
                        }

                        if miniAppId == 3 {
                            startStripeApplePay()
                        } else {
                            startZCreditApplePay()
                        }
                    }
            }
        }
        .background(Color(.systemBackground))
    }

    // MARK: - Payments (unchanged)

    private func startStripeApplePay() {
        isSubmitting = true
        submitError = nil

        if skipApplePay {
            showOrderProgress = false
            isSubmitting = false
            startSubmitOrder()
            return
        }

        let amountMinor = Int((discountedTotal * 100).rounded())
        let currency = "gbp"
        let label = "Beigel Bake"

        stripeApplePay.start(
            merchantId: stripeMerchantId,
            countryCode: "GB",
            currencyCode: "GBP",
            label: label,
            total: discountedTotal
        ) { result in
            DispatchQueue.main.async {
                switch result {
                case .failure(let err):
                    self.isSubmitting = false
                    self.showOrderProgress = false
                    self.submitError = err.localizedDescription
                    Haptics.error()
                    UINotificationFeedbackGenerator().notificationOccurred(.error)

                case .success(let pkPayment):
                    self.showOrderProgress = true
                    STPAPIClient.shared.createPaymentMethod(with: pkPayment) { pm, error in
                        DispatchQueue.main.async {
                            if let error = error {
                                self.isSubmitting = false
                                self.showOrderProgress = false
                                self.submitError = error.localizedDescription
                                Haptics.error()
                                UINotificationFeedbackGenerator().notificationOccurred(.error)
                                return
                            }

                            guard let pmId = pm?.stripeId else {
                                self.isSubmitting = false
                                self.showOrderProgress = false
                                self.submitError = "Stripe PaymentMethod missing"
                                Haptics.error()
                                UINotificationFeedbackGenerator().notificationOccurred(.error)
                                return
                            }

                            chargeStripePaymentIntent(
                                amountMinor: amountMinor,
                                currency: currency,
                                paymentMethodId: pmId
                            )
                        }
                    }
                }
            }
        }
    }

    private func chargeStripePaymentIntent(amountMinor: Int, currency: String, paymentMethodId: String) {
        let url = URL(string: "https://minis.studio/create-payment-intent")!

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let customerName = (UserDefaults.standard.string(forKey: "userName") ?? "Customer")
        let customerEmail = (UserDefaults.standard.string(forKey: "userEmail") ?? "customer@example.com")
        let customerUuid = (UserDefaults.standard.string(forKey: "anonUUID") ?? UUID().uuidString)

        let payload: [String: Any] = [
            "amount": amountMinor,
            "currency": currency,
            "paymentMethod": paymentMethodId,
            "customerUuid": customerUuid,
            "customerEmail": customerEmail,
            "customerName": customerName,
            "description": "Beigel Bake order"
        ]

        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        URLSession.shared.dataTask(with: req) { data, resp, err in
            DispatchQueue.main.async {
                if let err = err {
                    self.isSubmitting = false
                    self.showOrderProgress = false
                    self.submitError = err.localizedDescription
                    Haptics.error()
                    return
                }

                guard let http = resp as? HTTPURLResponse, let data = data else {
                    self.isSubmitting = false
                    self.showOrderProgress = false
                    self.submitError = "No response"
                    Haptics.error()
                    return
                }

                let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
                print("💳 Stripe PI response \(http.statusCode):", obj)

                if (200...299).contains(http.statusCode),
                   let status = obj["status"] as? String,
                   (status == "succeeded" || status == "requires_capture" || status == "processing") {

                    self.isSubmitting = false
                    self.showOrderProgress = false
                    self.startSubmitOrder()

                } else {
                    self.isSubmitting = false
                    self.showOrderProgress = false
                    self.submitError = (obj["error"] as? String) ?? "Payment failed"
                    Haptics.error()
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                }
            }
        }.resume()
    }

    private func startZCreditApplePay() {
        isSubmitting = true
        submitError = nil

        if skipApplePay {
            startSubmitOrder()
            return
        }

        let totalDecimal = Decimal(discountedTotal)
        let merchantId = UserDefaults.standard.string(forKey: "zcreditMerchantId")
            ?? "merchant.minis.zcredit"

        let handler = ZCreditApplePayHandler(countryCode: "IL", currencyCode: "ILS")
        applePayHandler = handler

        handler.present(total: totalDecimal, merchantId: merchantId) { result in
            DispatchQueue.main.async {
                switch result {
                case .failure(let err):
                    self.applePayHandler = nil
                    self.isSubmitting = false
                    self.submitError = err.localizedDescription
                    Haptics.error()
                    UINotificationFeedbackGenerator().notificationOccurred(.error)

                case .success(let payObj):
                    var meta = payObj

                    if let d = self.activeDiscount, d.percent > 0 {
                        meta["discountPercent"] = d.percent
                        meta["discountCampaignId"] = d.campaignId
                        meta["discountedTotal"] = self.discountedTotal
                        meta["originalTotal"] = self.totalPrice
                    }

                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.0) {
                        self.applePayHandler = nil
                        self.startSubmitOrder(zcreditMeta: meta)
                    }
                }
            }
        }
    }

    private func startSubmitOrder(zcreditMeta: [String: Any]? = nil) {
        isSubmitting = true
        showOrderProgress = true
        submitError = nil

        #if APPCLIP
        let source = "appclip-applepay-zcredit"
        #else
        let source = "mini-applepay-zcredit"
        #endif

        var finalMeta = zcreditMeta ?? [:]
        if let d = activeDiscount, d.percent > 0 {
            finalMeta["discountPercent"] = d.percent
            finalMeta["discountCampaignId"] = d.campaignId
            finalMeta["discountedTotal"] = discountedTotal
            finalMeta["originalTotal"] = totalPrice
        }

        OrderAPI.submitOrder(
            entries: entries,
            total: discountedTotal,
            diningMode: diningMode,
            source: source,
            customerName: UserDefaults.standard.string(forKey: "userName"),
            customerPhone: (miniAppId == 3)
                ? UserDefaults.standard.string(forKey: "userPhone")
                : "+447522552608",
            zcreditMeta: finalMeta.isEmpty ? nil : finalMeta
        ) { result in
            DispatchQueue.main.async {
                self.isSubmitting = false
                self.showOrderProgress = false

                switch result {
                case .success(let orderId):
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    Haptics.light()
                    onConfirm(orderId, diningMode)

                    for entry in entries {
                        MyItemsStore.touch(
                            productId: entry.item.id,
                            name: entry.item.name,
                            imageURL: entry.item.imageURL,
                            price: entry.unitPrice,
                            subtitle: entry.subtitle
                        )
                    }

                case .failure(let error):
                    self.submitError = error.localizedDescription
                    Haptics.error()
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                }
            }
        }
    }

    private func formatLineTotal(_ value: Double) -> String {
        if isRtl { return String(format: "%.0f", value) }
        return String(format: "£%.2f", value)
    }

    @ViewBuilder
    private func basketRow(_ entry: BasketEntry) -> some View {
        let lineTotal = entry.unitPrice * Double(entry.quantity)

        HStack(spacing: 12) {
            KFImage(entry.item.img)
                .resizable()
                .scaledToFill()
                .frame(width: 50, height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.item.name)
                    .font(.menuRegular(17).weight(.semibold))

                if let subtitle = entry.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.menuRegular(15).weight(.regular))
                        .foregroundColor(.secondary)
                }

                Text(formatLineTotal(lineTotal))
                    .font(.menuRegular(16).weight(.semibold))
                    .foregroundColor(.secondary)
            }

            Spacer()

            HStack(spacing: 12) {
                Button {
                    onDecrement(entry.id)
                    Haptics.selection()
                } label: {
                    Circle()
                        .fill(Color(.systemGray5))
                        .frame(width: 32, height: 32)
                        .overlay(
                            Image(systemName: "minus")
                                .font(.system(size: 16, weight: .bold))
                        )
                }

                Text("\(entry.quantity)")
                    .font(.menuRegular(18).weight(.semibold))
                    .frame(minWidth: 20)

                Button {
                    onIncrement(entry.id)
                    Haptics.selection()
                } label: {
                    Circle()
                        .fill(Color(.systemGray5))
                        .frame(width: 32, height: 32)
                        .overlay(
                            Image(systemName: "plus")
                                .font(.system(size: 16, weight: .bold))
                        )
                }
            }
        }
        .foregroundColor(MenuTheme.textColor)
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            onProductTap(entry.id, entry.item)
        }
    }
}
struct NameSheetView: View {
    @Binding var name: String
    @Binding var phone: String
    
    let isRtl: Bool
    let needsPhone: Bool
    let onDone: (String, String) -> Void
    
    @FocusState private var focusedField: Field?
    private enum Field { case name, phone }
    
    private func digitsOnly(_ s: String) -> String {
        s.filter(\.isNumber)
    }
    
    private var phoneDigits: String {
        digitsOnly(phone)
    }
    
    private var isValidUkMobile: Bool {
        phoneDigits.hasPrefix("07") && phoneDigits.count == 11
    }
    
    private var normalizedUkPhone: String {
        guard isValidUkMobile else { return "" }
        return "+44" + phoneDigits.dropFirst(1)
    }
    
    private var canContinue: Bool {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty { return false }
        if !needsPhone { return true }
        return isValidUkMobile
    }
    
    var body: some View {
        ZStack{
        Color(.systemBackground).ignoresSafeArea()
        
        VStack(spacing: 16) {
            Text(isRtl ? "הפרטים שלך" : "Your details")
                .font(.menuRegular(22).weight(.semibold))
                .frame(maxWidth: .infinity, alignment: isRtl ? .trailing : .leading)
            
            // 👇 NAME
            TextField(isRtl ? "שם מלא" : "Full name", text: $name)
                .font(.menuRegular(16))
                .padding(12)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .multilineTextAlignment(isRtl ? .trailing : .leading)
                .textInputAutocapitalization(.words)
                .focused($focusedField, equals: .name)
            
            // 👇 PHONE (only when needed)
            if needsPhone {
                TextField(isRtl ? "טלפון" : "Phone (07xxxxxxxxx)", text: $phone)
                    .font(.menuRegular(16))
                    .padding(12)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .multilineTextAlignment(isRtl ? .trailing : .leading)
                    .keyboardType(.phonePad)
                    .focused($focusedField, equals: .phone)
            }
            
            Button {
                let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !n.isEmpty else { return }
                
                if needsPhone {
                    let p = normalizedUkPhone
                    guard !p.isEmpty else { return }
                    onDone(n, p)
                } else {
                    onDone(n, "")
                }
            } label: {
                Text(isRtl ? "המשך" : "Continue")
                    .font(.menuRegular(17).weight(.semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(MenuTheme.buttonBackground.opacity(canContinue ? 1 : 0.4))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(!canContinue)
        }
        .padding(.horizontal, 24)
        .padding(.top, 30)
        .padding(.bottom, 16)
        .presentationDetents([.height(needsPhone ? 340 : 300)])
        
        // ✅ THIS IS THE KEY PART
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                focusedField = .name
            }
        }
    }
}
}

struct OrderConfirmationView: View {
    let orderNumber: Int
    let entries: [BasketEntry]
    let totalPrice: Double
    let diningMode: DiningMode
    @Environment(\.isRtl) private var isRtl
    @State private var email: String = ""
    @State private var didSendInvoice = false
    
    private func sendInvoice() {
        // 1️⃣ Dismiss keyboard
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)

        // 2️⃣ Trim & save
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        UserDefaults.standard.set(trimmed, forKey: "lastInvoiceEmail")

        // 3️⃣ Fire-and-forget API call
        if let url = URL(string: "https://minis.studio/invoices/\(orderNumber)/send") {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let payload: [String: Any] = ["email": trimmed]
            req.httpBody = try? JSONSerialization.data(withJSONObject: payload)

            URLSession.shared.dataTask(with: req) { data, resp, err in
                if let err = err {
                    print("❌ send invoice error:", err.localizedDescription)
                    return
                }
                if let http = resp as? HTTPURLResponse {
                    print("📧 /invoices/\(orderNumber)/send →", http.statusCode)
                }
            }.resume()
        }

        // 4️⃣ UI feedback
        withAnimation {
            didSendInvoice = true
        }

        // 5️⃣ Clear field
        email = ""

        // 6️⃣ Hide success after 2 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation {
                didSendInvoice = false
            }
        }
    }
    
    private func formatLineTotal(_ value: Double) -> String {
        if isRtl {
            // Hebrew style – no symbol
            return String(format: "%.0f", value)
        } else {
            // LTR – Pound with 2 decimals
            return String(format: "£%.2f", value)
        }
    }

    private func formatGrandTotal(_ value: Double) -> String {
        if isRtl {
            // Hebrew style – no symbol
            return String(format: "%.2f", value)
        } else {
            // LTR – Pound with 2 decimals
            return String(format: "£%.2f", value)
        }
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 40) {
                let cleanOrderId = String(orderNumber)
                VStack(spacing: 12) {
                    Text(isRtl ? "תודה!" : "Thank you!")
                        .font(.menuRegular(28).weight(.semibold))
                    Text(isRtl ? "מספר ההזמנה שלך" : "Your order number")
                        .font(.menuRegular(20).weight(.semibold))
                        .foregroundColor(.secondary)
                    Text(cleanOrderId)
                        .font(.menuRegular(40).weight(.semibold))
                        .padding(.top, 4)
                    Text(
                        isRtl
                        ? "השליח יעדכן כשיגיע"
                        : "The driver will notify you when they arrive"
                    )
                        .font(.menuRegular(17).weight(.regular))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 30)
                VStack(alignment: .leading, spacing: 22) {
                    Text(isRtl ? "פרטי הזמנה" : "Order details")
                        .font(.menuRegular(20).weight(.regular))
                    VStack(spacing: 14) {
                        ForEach(entries) { entry in
                            let lineTotal = entry.unitPrice * Double(entry.quantity)
                            HStack {
                                Text("\(entry.quantity) × \(entry.item.name)")
                                    .font(.menuRegular(16).weight(.regular))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(formatLineTotal(lineTotal))

                                    .font(.menuRegular(16).weight(.regular))
                                    //.foregroundColor(MenuTheme.accent)
                            }
                            if let subtitle = entry.subtitle, !subtitle.isEmpty {
                                Text(subtitle)
                                    .font(.menuRegular(15).weight(.regular))
                                    .foregroundColor(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    HStack {
                        Text(isRtl ? "סה״כ" : "Total")
                            .font(.menuRegular(16).weight(.regular))
                        Spacer()
                        Text(formatGrandTotal(totalPrice))
                            .font(.menuRegular(15).weight(.semibold))
                    }
                    .padding(.top, 4)
                }
                .padding(.horizontal, 20)
                VStack(alignment: .leading, spacing: 16) {
                    Text(isRtl ? "שלח חשבונית" : "Send invoice")
                        .font(.menuRegular(20).weight(.regular))

                    HStack(spacing: 10) {
                        TextField(isRtl ?  "Email" : "Email", text: $email)
                            .font(.menuRegular(16).weight(.regular))
                            .textInputAutocapitalization(.never)
                            .keyboardType(.emailAddress)
                            .padding(12)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 10))

                        Button {
                            sendInvoice()
                        } label: {
                            Image(systemName: "paperplane.fill")
                                .font(.system(size: 18, weight: .bold))
                                .rotationEffect(.degrees(isRtl ? 90 : 0))
                                .foregroundColor(.white)
                                .padding(12)
                                .background(MenuTheme.buttonBackground)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }

                    // ✅ green success message
                    if didSendInvoice {
                        Text(isRtl ? "נשלח בהצלחה ✓" : "Sent successfully ✓")
                            .font(.menuRegular(16).weight(.regular))
                            .foregroundColor(.green)
                            .transition(.opacity)
                            .padding(.top, -6)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 30)
                .padding(.top, 20)
            }
        }
        .onAppear {
            email = UserDefaults.standard.string(forKey: "lastInvoiceEmail") ?? ""
        }
        .navigationTitle(isRtl ? "אישור" : "Confirmation")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(isRtl ? "אישור" : "Confirmation")
                    .font(.menuRegular(18))
            }
        }
    }
}

struct CardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

struct OrderInProcessBanner: View {
    let orderNumber: Int
    let phase: OrderPhase         // 👈 NEW
    let onTap: () -> Void
    @Environment(\.isRtl) private var isRtl

    private var orderNumberText: String { String(orderNumber) }

    private var titleText: String {
        if isRtl {
            return phase == .ready ? "ההזמנה שלך מוכנה" : "ההזמנה שלך על האש"
        } else {
            return phase == .ready ? "Your order is ready" : "Your order is being prepared"
        }
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: phase == .ready ? "checkmark.seal.fill" : "flame.fill")
                    .font(.system(size: 20))
                    .foregroundColor(phase == .ready ? .green : .orange)

                VStack(alignment: .leading, spacing: 4) {
                    Text(titleText)
                        .font(.menuRegular(17).weight(.semibold))

                    Text(isRtl ? "מס' הזמנה \(orderNumberText)" :
                                 "Order #\(orderNumberText)")
                        .font(.menuRegular(16).weight(.semibold))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: isRtl ? "chevron.left" : "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
        }
        .buttonStyle(.plain)
        .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
    }
}


struct OrderProgressView: View {
    @Environment(\.isRtl) private var isRtl
    @AppStorage("brandColor") private var brandColorHex: String = "#324E57"

    private var brandColor: Color {
        Color(hex: brandColorHex) ?? MenuTheme.buttonBackground
    }

    @State private var spin = false
    @State private var pulse = false
    @State private var msgIndex = 0
    @State private var timer: Timer?

    private var messages: [String] {
        if isRtl {
            return [
                "מכינים את ההזמנה שלך… 🍳",
                "שולחים למטבח… 🛎️",
                "כמעט מוכן… 🚀"
            ]
        } else {
            return [
                "Cooking up your order… 🍳",
                "Sending to the kitchen… 🛎️",
                "Almost there… 🚀"
            ]
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()

            VStack(spacing: 20) {
                ZStack {
                    // Spinning ring
                    Circle()
                        .trim(from: 0.18, to: 0.82)
                        .stroke(brandColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .frame(width: 96, height: 96)
                        .rotationEffect(.degrees(spin ? 360 : 0))
                        .animation(.linear(duration: 1.0).repeatForever(autoreverses: false), value: spin)

                    // Bag icon with gentle pulse
                    Image(systemName: "takeoutbag.and.cup.and.straw.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.white)
                        .scaleEffect(pulse ? 1.06 : 0.96)
                        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
                }

                // Cycling status text
                Text(messages[msgIndex])
                    .font(.headline)
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .id(msgIndex)
                    .transition(.opacity.animation(.easeInOut(duration: 0.25)))
            }
            .padding(24)
        }
        .onAppear {
            spin = true
            pulse = true

            timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
                withAnimation {
                    msgIndex = (msgIndex + 1) % messages.count
                }
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isRtl ? "מעבד את ההזמנה שלך" : "Processing your order")
        .accessibilityHint(isRtl ? "אנא המתן" : "Please wait")
    }
}


import SwiftUI

// MARK: - Storage keys (match kiosk)
private enum CheckoutKeys {
    static let intent = "checkout.intent"          // "sit" | "ta"
    static let serviceLabel = "serviceModeLabel"   // "לשבת" | "לקחת"
    static let didShowWelcome = "didShowWelcome"   // Bool
}

// MARK: - Welcome View (fullscreen, kiosk style)
struct KioskWelcomeView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isRtl) private var isRtl

    @AppStorage(CheckoutKeys.intent) private var checkoutIntentRaw: String = ""
    @AppStorage(CheckoutKeys.serviceLabel) private var serviceModeLabel: String = ""
    @AppStorage(CheckoutKeys.didShowWelcome) private var didShowWelcome: Bool = false

    @State private var page = 0
    @State private var timer: Timer?

    // Same images as kiosk
    private let images: [String] = [
        "https://minis.studio/images/wallpaper_bh3.jpg",
        "https://minis.studio/images/wallpaper_bh2.jpg",
        "https://minis.studio/images/wallpaper_bh1.png"
    ]

    var body: some View {
        ZStack {
            // Background slider
            TabView(selection: $page) {
                ForEach(Array(images.enumerated()), id: \.offset) { idx, urlStr in
                    RemoteFullscreenImage(urlStr: urlStr)
                        .tag(idx)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            // Dark overlay like kiosk
            LinearGradient(
                colors: [
                    Color.black.opacity(0.20),
                    Color.black.opacity(0.20)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            // Content
            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 18) {
                    Text(isRtl ? "ברוכים הבאים" : "Welcome")
                        .font(.menuRegular(48).weight(.heavy)) // kiosk huge; iPhone-safe
                        .foregroundColor(.white)
                        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                        .multilineTextAlignment(.center)

                    Text(isRtl ? "לחצו להזמנה" : "Tap to order")
                        .font(.menuRegular(22).weight(.bold))
                        .foregroundColor(.white.opacity(0.92))
                        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                        .multilineTextAlignment(.center)

                    HStack(spacing: 14) {
                        kioskButton(title: isRtl ? "לשבת" : "Dine-in") {
                            choose(intent: "sit")
                        }
                        kioskButton(title: isRtl ? "לקחת" : "Takeaway") {
                            choose(intent: "ta")
                        }
                    }
                    .padding(.top, 8)
                }
                .padding(.horizontal, 20)

                Spacer(minLength: 40)
            }

            // Close button (like kiosk X)
            Button {
                // If user closes without choosing, we still mark "shown" so it won't annoy them.
                didShowWelcome = true
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 46, height: 46)
                    .background(Color.black.opacity(0.28))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.top, 16)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: isRtl ? .topLeading : .topTrailing)
        }
        .onAppear {
            // Auto-slide every 3.5s (kiosk feel)
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 7.5, repeats: true) { _ in
                withAnimation(.easeInOut(duration: 0.6)) {
                    page = (page + 1) % max(images.count, 1)
                }
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
        .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
    }

    private func choose(intent: String) {
        checkoutIntentRaw = intent
        serviceModeLabel = (intent == "sit") ? "לשבת" : "לקחת"
        didShowWelcome = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        dismiss()
    }

    private func kioskButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.menuRegular(18).weight(.bold))
                .foregroundColor(Color(hex: "#324e57") ?? .black) // kiosk text color
                .frame(maxWidth: .infinity)
                .frame(height: 72)
                .background(Color(hex: "#d2c1a5") ?? Color(.systemGray5)) // kiosk button bg
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: .black.opacity(0.22), radius: 24, y: 10)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Remote image helper (no Kingfisher needed here)
private struct RemoteFullscreenImage: View {
    let urlStr: String

    var body: some View {
        AsyncImage(url: URL(string: urlStr)) { phase in
            switch phase {
            case .success(let img):
                img.resizable()
                    .scaledToFill()
                    .clipped()
            case .failure:
                Color.black.opacity(0.15)
            case .empty:
                Color.black.opacity(0.10)
                    .overlay(ProgressView().tint(.white))
            @unknown default:
                Color.black.opacity(0.15)
            }
        }
        .ignoresSafeArea()
    }
}
