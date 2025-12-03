import SwiftUI
import Kingfisher
import PassKit
import StoreKit
import UIKit

private enum MenuTheme {
    static var accent: Color {
        Color(UIColor { trait in
            trait.userInterfaceStyle == .dark
            ? UIColor(Color(hex: "#b39d82"))
            : UIColor(Color(hex: "#324E57"))
        })
    }
    static var buttonBackground: Color {
        Color(UIColor { _ in UIColor(Color(hex: "#324E57")) })
    }
    static var textColor: Color { .primary }
}

enum OrderPhase: String, Codable {
    case inProgress
    case ready
}

extension Font {
    static func primariesDemi(_ size: CGFloat) -> Font {
        .custom(primariesFontName, size: size)
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
    @State private var lastOrder: OrderSnapshot?
    @State private var confirmationOrder: OrderSnapshot?
    @State private var categorySyncResumeAt: Date = .distantPast
    @State private var showShareSheet = false
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

    private var items: [ShellMenuItem] { api.items }
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

                                VStack(spacing: 10) {
                                    Text(isRtl ? "תפריט בוקר" : "Breakfast menu")
                                        .padding(.top, 15)
                                        .font(.primariesDemi(28))
                                    Text("הזמינו מהטלפון ונעדכן כשמוכן")
                                        .font(.primariesDemi(15))
                                        .foregroundColor(.secondary)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.bottom, 12)
                            }
                            .padding(.bottom, 8)
                            
                            if let order = lastOrder {
                                OrderInProcessBanner(orderNumber: order.orderNumber, phase: order.phase) {
                                    confirmationOrder = order
                                    showConfirmation = true
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
                                            .font(.primariesDemi(20))
                                            .padding(.horizontal, 16)
                                        LazyVGrid(columns: columns, spacing: 12) {
                                            ForEach(items.filter { $0.category == category }) { item in
                                                let qty = quantityInBasket(for: item)
                                                let badgeQty: Int? = qty > 0 ? qty : nil
                                                Button {
                                                    selectedBasketLineId = nil
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
        .onAppear {
            saveReferralForCurrentShop(kind: .fastlane)
            api.load()
            loadLastOrderPersistedIfValid()

            if isLastOrderReady {
                if let currentOrderNumber = lastOrder?.orderNumber {
                    print("🎯 onAppear: isLastOrderReady == true, marking lastOrder as ready")
                    markLastOrderReadyIfMatches(orderNumber: currentOrderNumber)
                } else {
                    print("⚠️ onAppear: isLastOrderReady == true but no lastOrder snapshot")
                }
                isLastOrderReady = false      // 👈 consume the flag
            }
        }
        .onChange(of: isLastOrderReady) { newValue in
            guard newValue == true else { return }
            print("🎯 isLastOrderReady changed in view →", newValue)

            if let currentOrderNumber = lastOrder?.orderNumber {
                markLastOrderReadyIfMatches(orderNumber: currentOrderNumber)
            } else {
                print("⚠️ isLastOrderReady == true but no lastOrder snapshot")
            }
            isLastOrderReady = false          // 👈 consume the flag here too
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
            ProductSheet(
                item: item,
                initialQuantityInBasket: existingOrNil,
                initialSelectedOptions: initialOptions,
                useInitialQuantity: selectedBasketLineId != nil
            ) { product, qty, subtitle, unitPrice in
                addToBasket(
                    product,
                    quantity: qty,
                    subtitle: subtitle,
                    unitPrice: unitPrice
                )
            }
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
                    selectedItem = item
                    showBasketSheet = false
                }
            )
            .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
        }
    }
}

struct CategoryBar: View {
    let categories: [String]
    let selected: String
    let onTap: (String) -> Void
    @Namespace private var underlineNS
    private let highlightColor = MenuTheme.accent

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(categories, id: \.self) { cat in
                            Button { onTap(cat) } label: {
                                VStack(spacing: 0) {
                                    Text(cat)
                                        .font(.primariesDemi(15))
                                        .foregroundColor(
                                            cat == selected ? highlightColor : Color.primary.opacity(0.7)
                                        )
                                    if cat == selected {
                                        Rectangle()
                                            .fill(highlightColor)
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
                        .font(.custom(primariesFontName, size: 15))
                        .lineLimit(2)
                    Text(String(format: "%.0f", item.price))
                        .font(.custom(primariesFontName, size: 15))
                        .foregroundColor(MenuTheme.accent)
                }
                .frame(width: cellWidth, alignment: .topLeading)
                if let qty = quantityInBasket, qty > 0 {
                    Text("\(qty)")
                        .font(.custom(primariesFontName, size: 15))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedCornerShape(
                                radius: 16,
                                corners: isRtl ? [.topRight, .bottomLeft] : [.bottomRight]
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

struct ModifierListView: View {
    let groups: [ModifierGroup]
    @Binding var selectedOptions: [String: String]
    @Binding var selectedAdditions: Set<String>

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.title)
                            .font(.custom(primariesFontName, size: 16))
                        if group.type == .options {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(group.items) { item in
                                        let isSelected = selectedOptions[group.title] == item.name
                                        Text(item.extraPrice > 0 ? "\(item.name) +\(Int(item.extraPrice))" : item.name)
                                            .font(.custom(primariesFontName, size: 14))
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 8)
                                            .background(isSelected ? MenuTheme.accent : Color(.systemGray6))
                                            .foregroundColor(isSelected ? .white : MenuTheme.textColor)
                                            .clipShape(Capsule())
                                            .onTapGesture {
                                                selectedOptions[group.title] = item.name
                                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                            }
                                    }
                                }
                                .padding(.top, 2)
                            }
                        } else {
                            VStack(spacing: 6) {
                                ForEach(group.items) { item in
                                    modifierRow(group: group, item: item)
                                }
                            }
                            .padding(.top, 2)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .onAppear {
                for group in groups where group.type == .options {
                    if selectedOptions[group.title] == nil,
                       let first = group.items.first {
                        selectedOptions[group.title] = first.name
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func modifierRow(group: ModifierGroup, item: ModifierItem) -> some View {
        let isSelected = selectedAdditions.contains(item.name)
        HStack(spacing: 10) {
            Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                .foregroundColor(isSelected ? MenuTheme.accent : .secondary)
                .font(.system(size: 18, weight: .semibold))
            HStack(spacing: 4) {
                Text(item.name)
                if item.extraPrice > 0 {
                    Text(String(format: " %.0f + ", item.extraPrice))
                        .foregroundColor(MenuTheme.accent)
                }
            }
            .font(.custom(primariesFontName, size: 15))
            Spacer()
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Color.black.opacity(0.04) : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if selectedAdditions.contains(item.name) {
                selectedAdditions.remove(item.name)
            } else {
                selectedAdditions.insert(item.name)
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }
}

struct ProductSheet: View {
    let item: ShellMenuItem
    let initialQuantityInBasket: Int?
    let initialSelectedOptions: [String: String]
    let useInitialQuantity: Bool
    let onAdd: (ShellMenuItem, Int, String?, Double) -> Void

    @State private var quantity: Int
    @State private var contentHeight: CGFloat = 500
    @State private var heroFrozenImage: KFCrossPlatformImage? = nil
    @State private var selectedOptions: [String: String] = [:]
    @State private var selectedAdditions: Set<String> = []

    @Environment(\.dismiss) private var dismiss
    @Environment(\.isRtl) private var isRtl

    init(
        item: ShellMenuItem,
        initialQuantityInBasket: Int?,
        initialSelectedOptions: [String: String],
        useInitialQuantity: Bool,
        onAdd: @escaping (ShellMenuItem, Int, String?, Double) -> Void
    ) {
        self.item = item
        self.initialQuantityInBasket = initialQuantityInBasket
        self.initialSelectedOptions = initialSelectedOptions
        self.useInitialQuantity = useInitialQuantity
        self.onAdd = onAdd

        let hasModifiers = !(item.modifiers?.isEmpty ?? true)
        let baseQty = initialQuantityInBasket ?? 1
        let startQty = (hasModifiers && !useInitialQuantity) ? 1 : baseQty

        _quantity = State(initialValue: startQty)
        _selectedOptions = State(initialValue: initialSelectedOptions)
    }

    private var hasModifiers: Bool { !(item.modifiers?.isEmpty ?? true) }
    private var isUpdateMode: Bool { (initialQuantityInBasket ?? 0) > 0 }
    private var isRemoveMode: Bool { isUpdateMode && useInitialQuantity && quantity == 0 }
    
    private func extraPricePerUnit() -> Double {
        guard let groups = item.modifiers else { return 0 }
        return groups.reduce(0) { total, group in
            switch group.type {
            case .options:
                if let selectedName = selectedOptions[group.title],
                   let opt = group.items.first(where: { $0.name == selectedName }) {
                    return total + opt.extraPrice
                }
                return total
            case .additions:
                return total + group.items
                    .filter { selectedAdditions.contains($0.name) }
                    .map { $0.extraPrice }
                    .reduce(0, +)
            }
        }
    }

    private var totalPriceLabel: String {
        let extras = extraPricePerUnit()
        let total = (item.price + extras) * Double(max(quantity, 0))
        return String(format: "%.2f", total)
    }

    private var detents: Set<PresentationDetent> {
        let screenH = UIScreen.main.bounds.height
        return [.height(min(contentHeight + 40, screenH * 0.88)), .large]
    }

    private func subtitleFromSelection() -> String? {
        guard let groups = item.modifiers else { return nil }
        let parts = groups.compactMap { group -> String? in
            guard group.type == .options else { return nil }
            guard let selected = selectedOptions[group.title],
                  let first = group.items.first,
                  selected != first.name else { return nil }
            return "\(group.title): \(selected)"
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
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
                            .font(.custom(primariesFontName, size: 26))
                        Text(String(format: "%.0f", item.price))
                            .font(.custom(primariesFontName, size: 20))
                            .foregroundColor(MenuTheme.accent)
                        if let desc = item.description, !desc.isEmpty {
                            Text(desc)
                                .font(.custom(primariesFontName, size: 15))
                                .foregroundColor(.secondary)
                                .padding(.top, 6)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 6)
                    if let groups = item.modifiers {
                        ModifierListView(
                            groups: groups,
                            selectedOptions: $selectedOptions,
                            selectedAdditions: $selectedAdditions
                        )
                        .padding(.horizontal, 18)
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
                        if quantity > 0 { quantity -= 1 }       // editing basket row → allow 0
                    } else {
                        if hasModifiers {
                            if quantity > 1 { quantity -= 1 }   // from grid + modifiers → min 1
                        } else {
                            if quantity > 0 { quantity -= 1 }   // from grid + no modifiers → min 0
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
                onAdd(item, quantity, subtitle, unit)
                Haptics.success()
                dismiss()
            } label: {
                HStack {
                    if isRtl {
                        if isRemoveMode {
                            Text("הסר")
                                .font(.custom(primariesFontName, size: 18))
                        } else {
                            Text(isUpdateMode ? "עדכן" : "הוסף")
                                .font(.custom(primariesFontName, size: 18))
                        }
                        Spacer()
                        Text(totalPriceLabel)
                            .font(.primariesDemi(18))
                    } else {
                        if isRemoveMode {
                            Text("Remove")
                                .font(.system(size: 18, weight: .bold))
                        } else {
                            Text(isUpdateMode ? "Update" : "Add")
                                .font(.system(size: 18, weight: .bold))
                        }
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

    var body: some View {
        HStack {
            Button(action: onTap) {
                HStack {
                    if isRtl {
                        HStack(spacing: 12) {
                            Text("\(totalQuantity)")
                                .font(.custom(primariesFontName, size: 15))
                                .foregroundColor(MenuTheme.buttonBackground)
                                .frame(width: 28, height: 28)
                                .background(Color.white)
                                .clipShape(Circle())
                            Text("הזמנה")
                                .font(.primariesDemi(18))
                                .foregroundColor(.white)
                        }
                        Spacer()
                        Text(String(format: "%.2f", totalPrice))
                            .font(.custom(primariesFontName, size: 18))
                            .foregroundColor(.white)
                    } else {
                        Text(String(format: "₪%.0f", totalPrice))
                            .font(.custom(primariesFontName, size: 18))
                            .foregroundColor(.white)
                        Spacer()
                        HStack(spacing: 12) {
                            Text("Order")
                                .font(.primariesDemi(18))
                                .foregroundColor(.white)
                            Text("\(totalQuantity)")
                                .font(.custom(primariesFontName, size: 15))
                                .foregroundColor(MenuTheme.buttonBackground)
                                .frame(width: 28, height: 28)
                                .background(Color.white)
                                .clipShape(Circle())
                        }
                    }
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
    @State private var applePayHandler: ZCreditApplePayHandler? = nil
    
    private var skipApplePay: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "debugSkipApplePay")
        #else
        return false
        #endif
    }
    private let diningModeKey = "basket.diningMode"

    private var detents: Set<PresentationDetent> {
        let screenH = UIScreen.main.bounds.height
        let maxCustom = screenH * 0.9
        let fitted = min(contentHeight + 160, maxCustom)
        return fitted < maxCustom ? [.height(fitted), .large] : [.large]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Picker("", selection: $diningMode) {
                        Text(isRtl ? "לשבת" : "Dine in").tag(DiningMode.dineIn)
                        Text(isRtl ? "לקחת" : "Take away").tag(DiningMode.takeAway)
                    }
                    .pickerStyle(.segmented)
                    .segmentedFontPrimaries()
                    .tint(MenuTheme.buttonBackground)
                    .padding(.horizontal, 18)
                    .padding(.top, 4)
                    .padding(.bottom, 10)
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
                        .font(.custom(primariesFontName, size: 18))
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
                UserDefaults.standard.set(false, forKey: "debugSkipApplePay")
                if let raw = UserDefaults.standard.string(forKey: diningModeKey),
                   let saved = DiningMode(rawValue: raw) {
                    diningMode = saved
                }
            }
            .onChange(of: diningMode) { newValue in
                UserDefaults.standard.set(newValue.rawValue, forKey: diningModeKey)
            }
        }
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
            NameSheetView(name: $tempName, isRtl: isRtl) { finalName in
                let trimmed = finalName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }

                // 1️⃣ Save the name
                UserDefaults.standard.set(trimmed, forKey: "userName")

                // 2️⃣ Dismiss the name sheet
                showNameSheet = false

                // 3️⃣ After dismissal animation finishes, start Apple Pay
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    startApplePay()
                }
            }
        }
    }

    private var bottomArea: some View {
        VStack(spacing: 12) {
            HStack {
                if isRtl {
                    Text("סה\"כ").font(.custom(primariesFontName, size: 17))
                    Spacer()
                    Text(String(format: "%.2f", totalPrice)).font(.custom(primariesFontName, size: 17))
                } else {
                    Text("Total").font(.custom(primariesFontName, size: 17))
                    Spacer()
                    Text(String(format: "$%.2f", totalPrice)).font(.custom(primariesFontName, size: 17))
                }
            }
            .foregroundColor(MenuTheme.textColor)
            .padding(.horizontal, 24)
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
                        let existingName = (UserDefaults.standard.string(forKey: "userName") ?? "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if existingName.isEmpty {
                            tempName = ""
                            showNameSheet = true
                        } else {
                            startApplePay()
                        }
                    }
            }
            
        }
        .background(Color(.systemBackground))
    }

    private func startApplePay() {
        isSubmitting = true
        submitError = nil

        if skipApplePay {
               startSubmitOrder()          // no zcreditMeta
               return
           }
        
        let totalDecimal = Decimal(totalPrice)
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
                    let meta = payObj
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

        OrderAPI.submitOrder(
            entries: entries,
            total: totalPrice,
            diningMode: diningMode,
            source: source,
            customerName: UserDefaults.standard.string(forKey: "userName"),
            customerPhone: nil,
            zcreditMeta: zcreditMeta
        ) { result in
            DispatchQueue.main.async {
                self.isSubmitting = false
                self.showOrderProgress = false

                switch result {
                case .success(let orderId):
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    Haptics.light()
                    onConfirm(orderId, diningMode)

                case .failure(let error):
                    self.submitError = error.localizedDescription
                    Haptics.error()
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                }
            }
        }
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
                    .font(.custom(primariesFontName, size: 15))
                if let subtitle = entry.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                Text(String(format: "%.0f", lineTotal))
                    .font(.custom(primariesFontName, size: 15))
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
                    .font(.custom(primariesFontName, size: 16))
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
    let isRtl: Bool
    let onDone: (String) -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 20) {
            Text(isRtl ? "השם שלך" : "Your name")
                .font(.custom(primariesFontName, size: 22))
                .frame(maxWidth: .infinity, alignment: isRtl ? .trailing : .leading)
            TextField(isRtl ? "שם מלא" : "Full name", text: $name)
                .font(.custom(primariesFontName, size: 16))
                .padding(12)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .focused($isFocused)
                .multilineTextAlignment(isRtl ? .trailing : .leading)
                .textInputAutocapitalization(.words)
            Button {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                onDone(trimmed)
            } label: {
                Text(isRtl ? "המשך" : "Continue")
                    .font(.custom(primariesFontName, size: 17))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(MenuTheme.buttonBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 16)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isFocused = true
            }
        }
        .presentationDetents([.medium])
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
    
    var body: some View {
        ScrollView {
            VStack(spacing: 40) {
                let cleanOrderId = String(orderNumber)
                VStack(spacing: 12) {
                    Text(isRtl ? "תודה!" : "Thank you!")
                        .font(.custom(primariesFontName, size: 28))
                    Text(isRtl ? "מספר ההזמנה שלך" : "Your order number")
                        .font(.custom(primariesFontName, size: 20))
                        .foregroundColor(.secondary)
                    Text(cleanOrderId)
                        .font(.custom(primariesFontName, size: 40))
                        .padding(.top, 4)
                    Text(isRtl ? "נשלח הודעה כשיהיה מוכן" : "We will notify you when it’s ready")
                        .font(.custom(primariesFontName, size: 15))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 30)
                VStack(alignment: .leading, spacing: 22) {
                    Text(isRtl ? "פרטי הזמנה" : "Order details")
                        .font(.custom(primariesFontName, size: 20))
                    VStack(spacing: 14) {
                        ForEach(entries) { entry in
                            let lineTotal = entry.unitPrice * Double(entry.quantity)
                            HStack {
                                Text("\(entry.item.name) × \(entry.quantity)")
                                    .font(.custom(primariesFontName, size: 15))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(String(format: "%.0f", lineTotal))
                                    .font(.custom(primariesFontName, size: 15))
                                    .foregroundColor(MenuTheme.accent)
                            }
                            if let subtitle = entry.subtitle, !subtitle.isEmpty {
                                Text(subtitle)
                                    .font(.custom(primariesFontName, size: 14))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    HStack {
                        Text(isRtl ? "סה״כ" : "Total")
                            .font(.custom(primariesFontName, size: 15))
                        Spacer()
                        Text(String(format: "%.2f", totalPrice))
                            .font(.custom(primariesFontName, size: 15))
                    }
                    .padding(.top, 4)
                }
                .padding(.horizontal, 20)
                VStack(alignment: .leading, spacing: 16) {
                    Text(isRtl ? "שלח חשבונית" : "Send invoice")
                        .font(.custom(primariesFontName, size: 20))

                    HStack(spacing: 10) {
                        TextField(isRtl ?  "Email" : "Email", text: $email)
                            .font(.custom(primariesFontName, size: 16))
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
                            .font(.custom(primariesFontName, size: 15))
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
                    .font(.custom(primariesFontName, size: 18))
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
                        .font(.custom(primariesFontName, size: 16))

                    Text(isRtl ? "מס' הזמנה \(orderNumberText)" :
                                 "Order #\(orderNumberText)")
                        .font(.custom(primariesFontName, size: 14))
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
