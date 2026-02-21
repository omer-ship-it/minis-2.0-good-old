import SwiftUI
import Kingfisher

private struct ProductItem: Identifiable {
    let id: Int
    let name: String
    let category: String
    let price: Double
}

private let sampleCategories = ["קפה", "מאפים", "כריכים", "שתייה", "קינוחים"]

private func makeSampleProducts() -> [ProductItem] {
    var items: [ProductItem] = []
    var id = 1
    for category in sampleCategories {
        for i in 1...8 {
            items.append(.init(
                id: id,
                name: "\(category) \(i)",
                category: category,
                price: Double((i % 5) + 1) * 3.5
            ))
            id += 1
        }
    }
    return items
}

private enum ServiceType { case dineIn, pickup }

private func appFontName(for miniAppId: Int) -> String {
    switch miniAppId {
    case 3:  return "Oswald-Regular"
    case 12: return "PrimariesMLAAA-DemiBold"
    case 13: return "Heebo-Regular"
    default: return "System"
    }
}

private func appFont(_ miniAppId: Int, _ size: CGFloat) -> Font {
    let name = appFontName(for: miniAppId)
    return (name == "System") ? .system(size: size) : .custom(name, size: size)
}

private func formattedPrice(_ value: Double, miniAppId: Int) -> String {
    let rounded2 = (value * 100).rounded() / 100
    if miniAppId == 3 { return String(format: "£%.2f", rounded2) }
    let oneDecimal = (rounded2 * 10).rounded() / 10
    let str = String(format: "%.1f", oneDecimal)
    return str.hasSuffix(".0") ? String(str.dropLast(2)) : str
}

private func brandHex(for miniAppId: Int) -> String {
    switch miniAppId {
    case 3:  return "d71201"
    case 12: return "314D56"
    case 13: return "6db95b"
    default: return "000000"
    }
}

private func adjustedBrand(for miniAppId: Int) -> Color {
    let base = Color(hex: brandHex(for: miniAppId))
    if miniAppId == 13 { return base }
    return base.opacity(1.0)
}

private struct CategoryOffsetKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

private func sampleModifiers(for productId: Int) -> [ModifierGroup]? {
    switch productId {
    case 1:
        return [
            ModifierGroup(
                type: .options,
                title: "גודל",
                items: [
                    ModifierItem(name: "קטן", extraPrice: 0),
                    ModifierItem(name: "גדול", extraPrice: 2.0)
                ]
            ),
            ModifierGroup(
                type: .options,
                title: "חלב",
                items: [
                    ModifierItem(name: "רגיל", extraPrice: 0),
                    ModifierItem(name: "שיבולת", extraPrice: 1.0),
                    ModifierItem(name: "שקדים", extraPrice: 1.5)
                ]
            ),
            ModifierGroup(
                type: .additions,
                title: "תוספות",
                items: [
                    ModifierItem(name: "בלי תוספות", extraPrice: 0),
                    ModifierItem(name: "שוט נוסף", extraPrice: 2.0),
                    ModifierItem(name: "סירופ וניל", extraPrice: 1.5)
                ]
            )
        ]

    case 2:
        return [
            ModifierGroup(
                type: .options,
                title: "חימום",
                items: [
                    ModifierItem(name: "קר", extraPrice: 0),
                    ModifierItem(name: "חם", extraPrice: 0)
                ]
            ),
            ModifierGroup(
                type: .additions,
                title: "תוספות",
                items: [
                    ModifierItem(name: "בלי תוספות", extraPrice: 0),
                    ModifierItem(name: "חמאה", extraPrice: 1.0),
                    ModifierItem(name: "ריבה", extraPrice: 1.0)
                ]
            )
        ]

    case 3:
        return [
            ModifierGroup(
                type: .options,
                title: "לחם",
                items: [
                    ModifierItem(name: "בייגל", extraPrice: 0),
                    ModifierItem(name: "לחמניה", extraPrice: 0),
                    ModifierItem(name: "טורטייה", extraPrice: 2.0)
                ]
            ),
            ModifierGroup(
                type: .additions,
                title: "תוספות",
                items: [
                    ModifierItem(name: "בלי תוספות", extraPrice: 0),
                    ModifierItem(name: "גבינה", extraPrice: 2.0),
                    ModifierItem(name: "אבוקדו", extraPrice: 4.0),
                    ModifierItem(name: "חריף", extraPrice: 0)
                ]
            )
        ]

    default:
        return nil
    }
}

private struct ServiceToggle: View {
    @Environment(\.colorScheme) private var scheme
    let isRtl: Bool
    let miniAppId: Int
    @Binding var selection: ServiceType

    private var bg: Color { scheme == .light ? .white : Color(.secondarySystemBackground) }
    private var stroke: Color { scheme == .dark ? .white.opacity(0.18) : .black.opacity(0.10) }
    private var selectedBg: Color { scheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.08) }

    var body: some View {
        let dineText = isRtl ? "לשבת" : "Dine-in"
        let pickupText = isRtl ? "לקחת" : "Pickup"

        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(bg)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(stroke, lineWidth: 1.2)
                )
                .shadow(
                    color: .black.opacity(scheme == .dark ? 0.35 : 0.06),
                    radius: scheme == .dark ? 14 : 10,
                    y: 6
                )

            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height

                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selectedBg)
                    .frame(width: (w / 2) - 6, height: h - 6)
                    .position(x: selection == .dineIn ? w * 0.25 : w * 0.75, y: h / 2)
                    .animation(.spring(response: 0.28, dampingFraction: 0.9), value: selection)
            }
            .padding(3)

            HStack(spacing: 0) {
                Button { selection = .dineIn } label: {
                    Text(dineText)
                        .font(appFont(miniAppId, 16).weight(.semibold))
                        .foregroundColor(selection == .dineIn ? .primary : .primary.opacity(0.7))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button { selection = .pickup } label: {
                    Text(pickupText)
                        .font(appFont(miniAppId, 16).weight(.semibold))
                        .foregroundColor(selection == .pickup ? .primary : .primary.opacity(0.7))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: 52)
    }
}

private struct ProtoCategoryRail: View {
    @Environment(\.colorScheme) private var scheme
    let categories: [String]
    let miniAppId: Int
    @Binding var selectedCategory: String
    let onTap: (String) -> Void

    @Namespace private var ns

    private var pill: Color { scheme == .dark ? .white : .black }
    private var textSelected: Color { scheme == .dark ? .black : .white }
    private var textIdle: Color { scheme == .dark ? .primary.opacity(0.78) : .primary.opacity(0.82) }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 10) {
                ForEach(categories, id: \.self) { cat in
                    Button { onTap(cat) } label: {
                        ZStack(alignment: .leading) {
                            if cat == selectedCategory {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(pill)
                                    .matchedGeometryEffect(id: "pill", in: ns)
                            }

                            HStack {
                                Text(cat)
                                    .font(appFont(miniAppId, 17).weight(.semibold))
                                    .foregroundColor(cat == selectedCategory ? textSelected : textIdle)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 14)
                            .padding(.horizontal, 14)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
        }
        .background(scheme == .light ? .white : Color(.systemBackground))
    }
}

private struct ProtoCategoryBar: View {
    @Environment(\.colorScheme) private var scheme
    let categories: [String]
    let miniAppId: Int
    @Binding var selectedCategory: String
    let onTap: (String) -> Void

    @Namespace private var underlineNS

    private var bg: Color { scheme == .light ? .white : Color(.systemBackground) }
    private var textSelected: Color { .primary }
    private var textIdle: Color { scheme == .dark ? .primary.opacity(0.68) : .primary.opacity(0.72) }
    private var underline: Color { scheme == .dark ? .white : .black }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(categories, id: \.self) { cat in
                            Button { onTap(cat) } label: {
                                VStack(spacing: 8) {
                                    Text(cat)
                                        .font(appFont(miniAppId, 16).weight(.semibold))
                                        .foregroundColor(cat == selectedCategory ? textSelected : textIdle)
                                        .padding(.horizontal, 2)
                                        .padding(.vertical, 2)

                                    ZStack {
                                        if cat == selectedCategory {
                                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                                .fill(underline)
                                                .matchedGeometryEffect(id: "underline", in: underlineNS)
                                        } else {
                                            Color.clear
                                        }
                                    }
                                    .frame(height: 3)
                                }
                                .padding(.vertical, 10)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .id(cat)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .onChange(of: selectedCategory) { new in
                    guard !new.isEmpty else { return }
                    withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(new, anchor: .center) }
                }
            }

            Rectangle()
                .fill(Color.primary.opacity(scheme == .dark ? 0.12 : 0.10))
                .frame(height: 1)
        }
        .background(bg.ignoresSafeArea(edges: .top))
        .zIndex(10)
        .shadow(color: .black.opacity(scheme == .dark ? 0.22 : 0.05), radius: 10, y: 6)
    }
}

private struct IdleOverlayView: View {
    let miniAppId: Int
    let countdown: Int
    let onTap: () -> Void

    private let totalSeconds: Double = 8

    private var progress: Double {
        max(0, min(1, Double(countdown) / totalSeconds))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                VStack(spacing: 12) {
                    Text("עדיין כאן?")
                        .font(appFont(miniAppId, 44).weight(.heavy))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)

                    Text("גע במסך כדי להמשיך")
                        .font(appFont(miniAppId, 20).weight(.semibold))
                        .foregroundColor(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }

                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.18), lineWidth: 10)
                        .frame(width: 160, height: 160)

                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(Color.white, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .frame(width: 160, height: 160)
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 1.0), value: progress)

                    Text("\(countdown)")
                        .font(appFont(miniAppId, 52).weight(.heavy))
                        .foregroundColor(.white)
                        .contentTransition(.numericText())
                }

                Spacer()
            }
            .padding(.horizontal, 40)
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }
}

private struct WelcomeOverlayView: View {
    let miniAppId: Int
    let onDismiss: () -> Void

    @State private var page = 0
    @State private var timer: Timer?

    private var slides: [URL] {
        let ids = [101, 202, 303, 404, 505, 606]
        return ids.map { URL(string: "https://picsum.photos/seed/welcome-\($0)/1400/900")! }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $page) {
                ForEach(Array(slides.enumerated()), id: \.offset) { idx, url in
                    GeometryReader { geo in
                        KFImage(url)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                            .tag(idx)
                    }
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            LinearGradient(
                colors: [Color.black.opacity(0.45), Color.black.opacity(0.45)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 14) {
                Spacer()

                Text("ברוכים הבאים")
                    .font(appFont(miniAppId, 52).weight(.heavy))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                Text("געו במסך כדי להתחיל")
                    .font(appFont(miniAppId, 22).weight(.semibold))
                    .foregroundColor(.white.opacity(0.9))
                    .multilineTextAlignment(.center)

                Spacer()
            }
            .padding(.bottom, 40)
        }
        .contentShape(Rectangle())
        .onTapGesture { onDismiss() }
        .onAppear {
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 4.5, repeats: true) { _ in
                withAnimation(.easeInOut(duration: 0.6)) {
                    page = (page + 1) % max(slides.count, 1)
                }
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }
}

fileprivate struct ProductSheetMeasuredHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

fileprivate extension View {
    func measureProductSheetHeight(_ onChange: @escaping (CGFloat) -> Void) -> some View {
        background(
            GeometryReader { geo in
                Color.clear.preference(key: ProductSheetMeasuredHeightKey.self, value: geo.size.height)
            }
        )
        .onPreferenceChange(ProductSheetMeasuredHeightKey.self, perform: onChange)
    }
}

fileprivate struct HugHeightSheet<Content: View>: View {
    let content: Content

    @State private var measuredH: CGFloat = 260
    @State private var selectedDetent: PresentationDetent = .height(260)   // ✅ start hugged

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        let screenH = UIScreen.main.bounds.height
        let maxH = screenH * 0.88
        let minH: CGFloat = 220
        let targetH = min(max(measuredH, minH), maxH) + 20

        ZStack {
            content

            // ✅ intrinsic measurer (does NOT force full height)
            content
                .fixedSize(horizontal: false, vertical: true)
                .measureProductSheetHeight { h in
                    let rounded = (h * 10).rounded() / 10
                    if abs(measuredH - rounded) > 1 { measuredH = rounded }
                }
                .opacity(0.001)
                .allowsHitTesting(false)
        }
        .onAppear {
            selectedDetent = .height(targetH)            // ✅ already a height, so no “large flash”
        }
        .onChange(of: measuredH) { _ in
            selectedDetent = .height(targetH)
        }
        .presentationDetents([.height(targetH), .large], selection: $selectedDetent)
        .presentationDragIndicator(.visible)
    }
}

struct MenuPrototypeView: View {
    @Environment(\.isRtl) private var isRtl
    @Environment(\.colorScheme) private var scheme
    private let forceRTL = true

    @State private var miniAppId: Int = 12
    @State private var showWelcome: Bool = false
    @State private var sheetItem: ShellMenuItem? = nil
    @State private var basketPhoneDetent: PresentationDetent = .height(420)

    private func basketPhoneHeightEstimate(screenH: CGFloat) -> CGFloat {
        let rows = basketLines.count

        let basketIds = Set(basketLines.map(\.id))
        let hasVisibleUpsells = upsells.contains { !basketIds.contains($0.id) }

        let headerH: CGFloat = 56
        let rowH: CGFloat = 76
        let upsellsH: CGFloat = hasVisibleUpsells ? 190 : 0
        let bottomH: CGFloat = 132
        let extra: CGFloat = 80

        let raw = headerH + (CGFloat(rows) * rowH) + upsellsH + bottomH + extra

        let minH: CGFloat = 320
        let maxH: CGFloat = max(480, screenH * 0.88)   // avoid too small on weird layouts
        return min(max(raw, minH), maxH)
    }
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    private struct LocalLine: Codable, Equatable {
        var qty: Int
        var unitPrice: Double
        var subtitle: String?
        var opts: [String:String]
        var adds: Set<String>
    }
    @State private var reopenBasketAfterProductSheet = false

    private func basketModifiersSubtitle(
        item: ShellMenuItem?,
        opts: [String:String],
        adds: Set<String>,
        isRtl: Bool
    ) -> String? {

        func norm(_ s: String) -> String {
            s.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\u{200F}", with: "")
                .replacingOccurrences(of: "\u{200E}", with: "")
                .replacingOccurrences(of: "\u{00A0}", with: " ")
        }

        guard let groups = item?.modifiers, !groups.isEmpty else {
            // Fallback (no schema): show whatever was selected, but still try to hide obvious empty/default noise
            let optValues = opts.values.map(norm).filter { !$0.isEmpty }
            let addValues = adds.map(norm).filter { !$0.isEmpty }
            let parts = (optValues + addValues)
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        }

        var parts: [String] = []

        // ✅ OPTIONS: include only if selected != first item
        for g in groups where g.type == .options {
            guard let first = g.items.first else { continue }
            let gKey = norm(g.title)

            // your opts keys are usually normalized titles
            let selected = norm(opts[gKey] ?? "")
            let defaultVal = norm(first.name)

            if !selected.isEmpty, selected != defaultVal {
                parts.append(selected)
            }
        }

        // ✅ ADDITIONS: include only non-default selections (default = first item)
        for g in groups where g.type == .additions {
            guard let first = g.items.first else { continue }

            let defaultNorm = norm(first.name)
            let groupNormNames = Set(g.items.map { norm($0.name) })

            // what user picked in THIS group
            let picked = adds.map(norm).filter { groupNormNames.contains($0) }

            // hide default, show non-defaults
            let nonDefault = picked.filter { $0 != defaultNorm }

            if !nonDefault.isEmpty {
                // keep menu order (optional)
                let ordered = g.items
                    .map { norm($0.name) }
                    .filter { nonDefault.contains($0) }

                parts.append(contentsOf: ordered)
            }
        }

        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
    private var itemsById: [Int: ShellMenuItem] {
        Dictionary(uniqueKeysWithValues: products.map { p in
            (p.id, ShellMenuItem(
                id: p.id,
                name: p.name,
                price: p.price,
                category: p.category,
                modifiers: sampleModifiers(for: p.id),
                imageURL: "https://picsum.photos/seed/\(p.id)/800/800",
                description: p.id <= 3 ? "מוצר לדוגמה עם תוספות" : nil
            ))
        })
    }

    private var basketLines: [BasketLine] {
        localBasket
            .sorted(by: { $0.key < $1.key })
            .map { (id, l) in
                let item = itemsById[id]
                return BasketLine(
                    id: id,
                    name: item?.name ?? (l.subtitle ?? (forceRTL ? "פריט" : "Item")),
                    imageURL: item?.imageURL ?? "https://picsum.photos/seed/\(id)/800/800",
                    qty: l.qty,
                    unitPrice: l.unitPrice,
                    subtitle: l.subtitle,      // ✅ modifiers text lives here
                    opts: l.opts,
                    adds: l.adds
                )
            }
    }

    private var upsells: [ShellMenuItem] {
        [
            ShellMenuItem(id: 9001, name: "קרואסון חמאה", price: 9.0,  category: "", modifiers: nil, imageURL: "https://picsum.photos/seed/upsell-1/800/800", description: nil),
            ShellMenuItem(id: 9002, name: "מיץ תפוזים",    price: 12.0, category: "", modifiers: nil, imageURL: "https://picsum.photos/seed/upsell-2/800/800", description: nil),
            ShellMenuItem(id: 9003, name: "עוגיית שוקולד", price: 7.0,  category: "", modifiers: nil, imageURL: "https://picsum.photos/seed/upsell-3/800/800", description: nil)
        ]
    }
    
    private func openProductFromBasket(_ item: ShellMenuItem) {
        reopenBasketAfterProductSheet = true

        // close basket first (avoid modal stacking)
        showBasketSheet = false

        // open product sheet on next runloop
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            sheetItem = item
        }
    }

    private func finishProductSheetAndMaybeReopenBasket() {
        sheetItem = nil

        guard reopenBasketAfterProductSheet else { return }
        reopenBasketAfterProductSheet = false

        // reopen basket after sheet fully dismisses
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            showBasketSheet = true
        }
    }
    @State private var localBasket: [Int: LocalLine] = [:]
    @State private var showBasketSheet: Bool = false
    private var shouldShowBasketBar: Bool {
        basketBarVisible && !(showWelcome || showIdle)
    }
    private var basketQty: Int {
        localBasket.values.reduce(0) { $0 + max(0, $1.qty) }
    }

    private var basketTotal: Double {
        localBasket.values.reduce(0) { $0 + (Double(max(0, $1.qty)) * $1.unitPrice) }
    }

    private var basketBarVisible: Bool {
        basketQty > 0
    }
    
    
    private func toShell(_ p: ProductItem) -> ShellMenuItem {
        ShellMenuItem(
            id: p.id,
            name: p.name,
            price: p.price,
            category: p.category,
            modifiers: sampleModifiers(for: p.id),
            imageURL: "https://picsum.photos/seed/\(p.id)/800/800",
            description: p.id <= 3 ? "מוצר לדוגמה עם תוספות לבדיקת ModifierListView" : nil
        )
    }

    private func openProduct(_ p: ProductItem) {
        sheetItem = toShell(p)
    }

    private let products = makeSampleProducts()
    private let categories = sampleCategories

    @State private var selectedCategory = sampleCategories.first ?? ""
    @State private var manualScroll = false
    @State private var syncResumeAt: Date = .distantPast
    @State private var lastInteractionAt: Date = Date()
    @State private var showIdle: Bool = false
    @State private var idleCountdown: Int = 8

    private let idleStartAfter: TimeInterval = 30
    private let idleTick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private func registerInteraction() {
        lastInteractionAt = Date()
        if showIdle {
            showIdle = false
            idleCountdown = 8
        }
    }

    @AppStorage("checkout.intent") private var checkoutIntentRaw: String = "sit"
    @AppStorage("serviceModeLabel") private var serviceModeLabel: String = ""

    private let headerOffsetPad: CGFloat = 20
    private let headerOffsetPhone: CGFloat = 20
    private let detectionOffset: CGFloat = 100

    
    private var headerOffset: CGFloat { isPad ? headerOffsetPad : headerOffsetPhone }

    private var columns: [GridItem] {
        let count = isPad ? 3 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 12), count: count)
    }

    private var bg: Color { scheme == .light ? .white : Color(.systemBackground) }
    private var brand: Color { adjustedBrand(for: miniAppId) }
    private var showServiceToggle: Bool { miniAppId == 12 }

    private var serviceBinding: Binding<ServiceType> {
        Binding(
            get: {
                let v = checkoutIntentRaw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return (v == "ta" || v == "pickup") ? .pickup : .dineIn
            },
            set: { newValue in
                checkoutIntentRaw = (newValue == .pickup) ? "ta" : "sit"
                if isRtl {
                    serviceModeLabel = (newValue == .pickup) ? "לקחת" : "לשבת"
                } else {
                    serviceModeLabel = (newValue == .pickup) ? "Pickup" : "Dine-in"
                }
            }
        )
    }

    private var basketPreferredHeight: CGFloat {
        let rowCount = basketLines.count

        let basketIds = Set(basketLines.map(\.id))
        let hasVisibleUpsells = upsells.contains { u in
            !basketIds.contains(u.id)
        }

        let headerH: CGFloat = 56
        let rowH: CGFloat = 84
        let upsellBlockH: CGFloat = hasVisibleUpsells ? 260 : 0
        let bottomH: CGFloat = 175
        let extra: CGFloat = 36 + 20   // ✅ add your +20px here

        return headerH + (CGFloat(rowCount) * rowH) + upsellBlockH + bottomH + extra
    }
    

    @ViewBuilder
    private var basketPadCover: some View {
        BasketOverlayCard(
            onDismiss: { showBasketSheet = false },
            preferredHeight: basketPreferredHeight
        ) {
            BasketSheetPrototype(
                miniAppId: miniAppId,
                isRtl: true,
                lines: basketLines,
                onClose: { showBasketSheet = false },
                onClear: { localBasket.removeAll(); showBasketSheet = false },

                onIncrement: { id in
                    guard var l = localBasket[id] else { return }
                    l.qty += 1
                    localBasket[id] = l
                },
                onDecrement: { id in
                    guard var l = localBasket[id] else { return }
                    l.qty -= 1
                    if l.qty <= 0 { localBasket[id] = nil } else { localBasket[id] = l }
                },

                onLineTap: { row in
                    if let it = itemsById[row.id] { openProductFromBasket(it) }
                },

                upsells: upsells,
                onAddUpsell: { item in
                    if var existing = localBasket[item.id] {
                        existing.qty += 1
                        localBasket[item.id] = existing
                    } else {
                        localBasket[item.id] = LocalLine(qty: 1, unitPrice: item.price, subtitle: nil, opts: [:], adds: [])
                    }
                },
                onOpenUpsell: { item in
                    openProductFromBasket(item)
                },

                onBackToShop: { showBasketSheet = false },
                onContinueToPayment: { showBasketSheet = false }
            )
            .environment(\.layoutDirection, .rightToLeft)
            .environment(\.locale, Locale(identifier: "he_IL"))
        }
        .environment(\.layoutDirection, .rightToLeft)
        .environment(\.locale, Locale(identifier: "he_IL"))
    }
    
    @ViewBuilder
    private var basketPhoneSheet: some View {
        BasketSheetPrototype(
            miniAppId: miniAppId,
            isRtl: true,
            lines: basketLines,
            onClose: { showBasketSheet = false },
            onClear: { localBasket.removeAll(); showBasketSheet = false },

            onIncrement: { productId in
                guard var l = localBasket[productId] else { return }
                l.qty += 1
                localBasket[productId] = l
            },
            onDecrement: { productId in
                guard var l = localBasket[productId] else { return }
                l.qty -= 1
                if l.qty <= 0 { localBasket[productId] = nil } else { localBasket[productId] = l }
                if localBasket.isEmpty { showBasketSheet = false }
            },

            onLineTap: { row in
                if let it = itemsById[row.id] { openProductFromBasket(it) }
            },

            upsells: upsells,
            onAddUpsell: { item in
                if var existing = localBasket[item.id] {
                    existing.qty += 1
                    localBasket[item.id] = existing
                } else {
                    localBasket[item.id] = LocalLine(qty: 1, unitPrice: item.price, subtitle: nil, opts: [:], adds: [])
                }
            },
            onOpenUpsell: { item in
                openProductFromBasket(item)
            },

            onBackToShop: { showBasketSheet = false },
            onContinueToPayment: { showBasketSheet = false }
        )
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color(.systemBackground))
        .environment(\.layoutDirection, .rightToLeft)
        .environment(\.locale, Locale(identifier: "he_IL"))
    }
    
    var body: some View {
        ZStack {
            bg.ignoresSafeArea()

            if isPad {
                HStack(spacing: 0) {
                    VStack(spacing: 10) {
                        if showServiceToggle {
                            ServiceToggle(isRtl: isRtl, miniAppId: miniAppId, selection: serviceBinding)
                                .padding(.horizontal, 10)
                                .padding(.top, 12)
                                .padding(.bottom, 6)
                        } else {
                            Color.clear.frame(height: 12)
                        }

                        
                        ProtoCategoryRail(
                            categories: categories,
                            miniAppId: miniAppId,
                            selectedCategory: $selectedCategory,
                            onTap: { cat in
                                manualScroll = true
                                syncResumeAt = Date().addingTimeInterval(0.9)
                                withAnimation(.spring(response: 0.22, dampingFraction: 0.92)) {
                                    selectedCategory = cat
                                }
                            }
                        )

                        Spacer(minLength: 0)
                    }
                    .frame(width: 220)
                    .background(bg)

                    ProtoScrollContent(
                        categories: categories,
                        products: products,
                        columns: columns,
                        miniAppId: miniAppId,
                        headerOffset: headerOffset,
                        detectionOffset: detectionOffset,
                        onTapProduct: { p in openProduct(p) }, selectedCategory: $selectedCategory,
                        manualScroll: $manualScroll,
                        syncResumeAt: $syncResumeAt
                    )
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {

                            VStack(spacing: 12) {
                                if showServiceToggle {
                                    ServiceToggle(isRtl: isRtl, miniAppId: miniAppId, selection: serviceBinding)
                                }

                                Picker("", selection: $miniAppId) {
                                    Text("3").tag(3)
                                    Text("12").tag(12)
                                    Text("13").tag(13)
                                }
                                .pickerStyle(.segmented)
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                            .padding(.bottom, 10)

                            Section {
                                LazyVStack(alignment: .leading, spacing: 18) {
                                    Color.clear.frame(height: 1).id("top")

                                    ForEach(categories, id: \.self) { category in
                                        VStack(alignment: .leading, spacing: 12) {

                                            Color.clear.frame(height: headerOffset)
                                            Text(category)
                                                .font(appFont(miniAppId, 22))
                                                .padding(.horizontal, 16)
                                                .background(
                                                    GeometryReader { geo in
                                                        Color.clear.preference(
                                                            key: CategoryOffsetKey.self,
                                                            value: [category: geo.frame(in: .named("scroll")).minY]
                                                        )
                                                    }
                                                )

                                            LazyVGrid(columns: columns, spacing: 12) {
                                                ForEach(products.filter { $0.category == category }) { item in
                                                    Button { openProduct(item) } label: {
                                                        ProductCardView(item: item, miniAppId: miniAppId)
                                                    }
                                                    .buttonStyle(.plain)
                                                }
                                            }
                                            .padding(.horizontal, 16)
                                        }
                                        .id(category)
                                    }

                                    Color.clear.frame(height: 40)
                                }
                            } header: {
                                ProtoCategoryBar(
                                    categories: categories,
                                    miniAppId: miniAppId,
                                    selectedCategory: $selectedCategory,
                                    onTap: { cat in
                                        manualScroll = true
                                        syncResumeAt = Date().addingTimeInterval(0.9)

                                        // set selected without heavy animation (avoids churn)
                                        selectedCategory = cat

                                        // ✅ scroll to the REAL id (cat)
                                        DispatchQueue.main.async {
                                            withAnimation(.easeInOut(duration: 0.45)) {
                                                proxy.scrollTo(cat, anchor: .top)
                                            }

                                            // optional: tiny “second poke” makes it rock solid
                                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                                withAnimation(.easeInOut(duration: 0.25)) {
                                                    proxy.scrollTo(cat, anchor: .top)
                                                }
                                            }
                                        }

                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                                            manualScroll = false
                                        }
                                    }                                )
                            }
                        }
                    }
                    .coordinateSpace(name: "scroll")
                    .onPreferenceChange(CategoryOffsetKey.self) { offsets in
                        guard Date() >= syncResumeAt else { return }
                        guard !manualScroll else { return }
                        guard !offsets.isEmpty else { return }

                        let threshold = headerOffset + 8 + detectionOffset
                        let sorted = offsets.sorted { $0.value < $1.value }
                        guard let match = (sorted.last(where: { $0.value <= threshold }) ?? sorted.first)?.key else { return }
                        guard match != selectedCategory else { return }

                        withAnimation(.spring(response: 0.22, dampingFraction: 0.92)) {
                            selectedCategory = match
                        }
                    }
                }
            }

            if isPad && showIdle {
                IdleOverlayView(miniAppId: miniAppId, countdown: idleCountdown) {
                    registerInteraction()
                }
                .ignoresSafeArea()
                .zIndex(9998)
                .transition(.opacity)
            }

            if isPad && showWelcome && !showBasketSheet {
                WelcomeOverlayView(miniAppId: miniAppId) {
                    withAnimation(.easeOut(duration: 0.25)) { showWelcome = false }
                }
                .ignoresSafeArea()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
                .zIndex(9999)
            }
        }
        .overlay(alignment: .bottom) {
            if shouldShowBasketBar {
                GeometryReader { geo in
                    let railW: CGFloat = isPad ? 220 : 0
                    let sidePad: CGFloat = 16
                    let buttonH: CGFloat = 60

                    VStack(spacing: 0) {
                        Spacer()

                        HStack(spacing: 0) {
                            if isPad { Color.clear.frame(width: railW) }

                            HStack {
                                BasketBarPrototype(
                                    miniAppId: miniAppId,
                                    isRtl: forceRTL, // see next section
                                    totalQuantity: basketQty,
                                    totalPrice: basketTotal,
                                    onTap: { showBasketSheet = true }
                                )
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                            .padding(.horizontal, sidePad)
                            .frame(width: max(0, geo.size.width - railW), alignment: .trailing)
                        }
                        .frame(height: buttonH)
                        .padding(.bottom, isPad ? 8 : 0)          // ✅ no safeAreaInsets.bottom here
                    }
                }
                .transition(.move(edge: .bottom))
                .animation(.spring(response: 0.28, dampingFraction: 0.9), value: shouldShowBasketBar)
            }
        }
        .sheet(isPresented: Binding(
            get: { showBasketSheet && !isPad },
            set: { if !$0 { showBasketSheet = false } }
        )) {
            let screenH = UIScreen.main.bounds.height
            let h = basketPhoneHeightEstimate(screenH: screenH)

            basketPhoneSheet
                .presentationDetents([.height(h), .large], selection: $basketPhoneDetent)
                .presentationDragIndicator(.visible)
                .presentationBackground(Color(.systemBackground))
                .onAppear {
                    // set AFTER detents exist, and never allow 0
                    basketPhoneDetent = .height(max(320, h))
                }
                .onChange(of: basketLines.count) { _ in
                    basketPhoneDetent = .height(max(320, basketPhoneHeightEstimate(screenH: screenH)))
                }
                .onChange(of: localBasket.count) { _ in
                    basketPhoneDetent = .height(max(320, basketPhoneHeightEstimate(screenH: screenH)))
                }
        }
        .fullScreenCover(isPresented: Binding(
            get: { showBasketSheet && isPad },
            set: { if !$0 { showBasketSheet = false } }
        )) {
            basketPadCover
        }
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture().onEnded { registerInteraction() }
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 12).onEnded { _ in registerInteraction() }
        )
        .overlay(alignment: .top) {
            GeometryReader { geo in
                bg
                    .frame(height: geo.safeAreaInsets.top)
                    .ignoresSafeArea(edges: .top)
            }
            .frame(height: 0)
        }
        .statusBar(hidden: true)
        
        .onReceive(idleTick) { _ in
            guard isPad else { return }
            guard !showWelcome else { return }
            guard !showBasketSheet else { return }   // ✅ NEW

            let idleFor = Date().timeIntervalSince(lastInteractionAt)

            if !showIdle {
                if idleFor >= idleStartAfter {
                    showIdle = true
                    idleCountdown = 8
                }
                return
            }

            if idleCountdown > 0 {
                idleCountdown -= 1
            } else {
                showIdle = false
                idleCountdown = 8
                if !showBasketSheet {
                    showWelcome = true
                }
                lastInteractionAt = Date()
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 12)
                .onEnded { _ in registerInteraction() }
        )
        .onChange(of: showWelcome) { shown in
            lastInteractionAt = Date()
            if shown {
                showIdle = false
                idleCountdown = 8
            }
        }
        .onChange(of: miniAppId) { newValue in
            UserDefaults.standard.set(newValue, forKey: "miniAppId")
        }
        .onAppear {
            let v = checkoutIntentRaw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if isRtl {
                serviceModeLabel = (v == "ta" || v == "pickup") ? "לקחת" : "לשבת"
            } else {
                serviceModeLabel = (v == "ta" || v == "pickup") ? "Pickup" : "Dine-in"
            }

            if isPad { showWelcome = true }
        }
        .font(appFont(miniAppId, 16))
        .tint(brand)
        .sheet(item: Binding(
            get: { isPad ? nil : sheetItem },
            set: { newValue in if !isPad { sheetItem = newValue } }
        )) { it in
            let existing = localBasket[it.id]

            // ✅ Force RTL for the whole sheet content
            let forceRTL = true

            HugHeightSheet {
                MenuProductSheet(
                    item: it,
                    editingLineId: nil,
                    initialQuantityInBasket: existing?.qty,
                    initialSelectedOptions: existing?.opts ?? [:],
                    initialSelectedAdditions: existing?.adds ?? [],
                    onAdd: { product, qty, subtitle, unitPrice, opts, adds in
                        if qty <= 0 {
                            localBasket[product.id] = nil
                        } else {
                            localBasket[product.id] = LocalLine(qty: qty, unitPrice: unitPrice, subtitle: subtitle, opts: opts, adds: adds)
                        }
                        finishProductSheetAndMaybeReopenBasket()
                    },
                    onClose: {
                        finishProductSheetAndMaybeReopenBasket()
                    }
                )
               
                // ✅ THESE THREE LINES fix “sheet is LTR/English”
                .environment(\.layoutDirection, forceRTL ? .rightToLeft : .leftToRight)
                .environment(\.locale, Locale(identifier: forceRTL ? "he_IL" : "en_GB"))
                .environment(\.isRtl, forceRTL)
                // ✅ make sheet fully opaque
                .presentationBackground(Color(.systemBackground))
            }
        }
        .fullScreenCover(item: Binding(
            get: { isPad ? sheetItem : nil },
            set: { newValue in if isPad { sheetItem = newValue } }
        )) { it in
            let existing = localBasket[it.id]

            GlossyOverlayCard(onDismiss: { sheetItem = nil }) {
                MenuProductSheet(
                    item: it,
                    editingLineId: nil,
                    initialQuantityInBasket: existing?.qty,
                    initialSelectedOptions: existing?.opts ?? [:],
                    initialSelectedAdditions: existing?.adds ?? []
                ) { product, qty, subtitle, unitPrice, opts, adds in
                    if qty <= 0 {
                        localBasket[product.id] = nil
                    } else {
                        localBasket[product.id] = LocalLine(
                            qty: qty,
                            unitPrice: unitPrice,
                            subtitle: subtitle,
                            opts: opts,
                            adds: adds
                        )
                    }
                    sheetItem = nil
                    finishProductSheetAndMaybeReopenBasket()
                } onClose: {
                    sheetItem = nil
                    finishProductSheetAndMaybeReopenBasket()
                }
            }
            .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
            .environment(\.locale, Locale(identifier: isRtl ? "he_IL" : "en_GB"))
        }
    }
}


private struct ProtoScrollContent: View {
    let categories: [String]
    let products: [ProductItem]
    let columns: [GridItem]
    let miniAppId: Int
    let headerOffset: CGFloat
    let detectionOffset: CGFloat
    let onTapProduct: (ProductItem) -> Void

    @Binding var selectedCategory: String
    @Binding var manualScroll: Bool
    @Binding var syncResumeAt: Date

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 18) {
                    Color.clear.frame(height: 1).id("top")

                    ForEach(categories, id: \.self) { category in
                        VStack(alignment: .leading, spacing: 12) {

                            // keep your top offset space if you want
                            Color.clear.frame(height: headerOffset)

                            Text(category)
                                .font(appFont(miniAppId, 22))
                                .padding(.horizontal, 16)
                                .background(
                                    GeometryReader { geo in
                                        Color.clear.preference(
                                            key: CategoryOffsetKey.self,
                                            value: [category: geo.frame(in: .named("scroll")).minY]
                                        )
                                    }
                                )

                            LazyVGrid(columns: columns, spacing: 12) {
                                ForEach(products.filter { $0.category == category }) { item in
                                    Button { onTapProduct(item) } label: {
                                        ProductCardView(item: item, miniAppId: miniAppId)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                        .id(category) // ✅ IMPORTANT: stable id on the direct child
                    }

                    Color.clear.frame(height: 120)
                }
            }
            .coordinateSpace(name: "scroll")
            .onChange(of: selectedCategory) { value in
                guard manualScroll else { return }
                guard !value.isEmpty else { return }

                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.55)) {
                        proxy.scrollTo(value, anchor: .top) // ✅ scroll to category id
                    }
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                    manualScroll = false
                }
            }
            .onPreferenceChange(CategoryOffsetKey.self) { offsets in
                guard Date() >= syncResumeAt else { return }
                guard !manualScroll else { return }
                guard !offsets.isEmpty else { return }

                let threshold = headerOffset + 8 + detectionOffset
                let sorted = offsets.sorted { $0.value < $1.value }
                guard let match = (sorted.last(where: { $0.value <= threshold }) ?? sorted.first)?.key else { return }
                guard match != selectedCategory else { return }

                withAnimation(.spring(response: 0.22, dampingFraction: 0.92)) {
                    selectedCategory = match
                }
            }
        }
    }
}

private struct ProductCardView: View {
    let item: ProductItem
    let miniAppId: Int

    private let radius: CGFloat = 18

    private var imageURL: URL {
        URL(string: "https://picsum.photos/seed/\(item.id)/600/600")!
    }

    var body: some View {
        VStack(spacing: 0) {
            KFImage(imageURL)
                .resizable()
                .scaledToFill()
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))

            VStack(alignment: .leading, spacing: 8) {
                Text(item.name)
                    .font(appFont(miniAppId, 17).weight(.semibold))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(formattedPrice(item.price, miniAppId: miniAppId))
                    .font(appFont(miniAppId, 14))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
        }
    }
}

//Part 2 MenuProductSheet
enum MenuProductSheetMode { case padOverlay, phone }

struct MenuProductSheet: View {
    let item: ShellMenuItem
    let editingLineId: Int?
    let initialQuantityInBasket: Int?
    let initialSelectedOptions: [String: String]
    let initialSelectedAdditions: Set<String>
    let onAdd: (ShellMenuItem, Int, String?, Double, [String: String], Set<String>) -> Void
    let onClose: () -> Void
    let mode: MenuProductSheetMode

    @Environment(\.colorScheme) private var scheme
    @Environment(\.isRtl) private var isRtl
    @AppStorage("miniAppId") private var miniAppId: Int = 0

    @State private var quantity: Int
    @State private var frozenHero: KFCrossPlatformImage? = nil
    @State private var selectedOptions: [String: String]
    @State private var selectedAdditions: Set<String>

    // iPhone detent hugging
    @State private var measuredContentH: CGFloat = 420
    @State private var selectedDetent: PresentationDetent = .large

    private let heroH: CGFloat = 280
    private let barH: CGFloat = 60
    private let sidePad: CGFloat = 14
    private let topPad: CGFloat = 14

    init(
        item: ShellMenuItem,
        editingLineId: Int?,
        initialQuantityInBasket: Int?,
        initialSelectedOptions: [String: String],
        initialSelectedAdditions: Set<String> = [],
        onAdd: @escaping (ShellMenuItem, Int, String?, Double, [String: String], Set<String>) -> Void,
        onClose: @escaping () -> Void,
        mode: MenuProductSheetMode = .padOverlay
    ) {
        self.item = item
        self.editingLineId = editingLineId
        self.initialQuantityInBasket = initialQuantityInBasket
        self.initialSelectedOptions = initialSelectedOptions
        self.initialSelectedAdditions = initialSelectedAdditions
        self.onAdd = onAdd
        self.onClose = onClose
        self.mode = mode

        _quantity = State(initialValue: initialQuantityInBasket ?? 1)

        let seeded = MenuProductSheetSeed.seed(
            item: item,
            initialOptions: initialSelectedOptions,
            initialAdditions: initialSelectedAdditions
        )
        _selectedOptions = State(initialValue: seeded.options)
        _selectedAdditions = State(initialValue: seeded.additions)
    }

    private var existsInBasket: Bool { initialQuantityInBasket != nil }
    private var isRemoveMode: Bool { existsInBasket && quantity == 0 }
    private var isUpdateMode: Bool { editingLineId != nil }

    // MARK: - Body

    var body: some View {
        Group {
            if mode == .padOverlay {
                padOverlayBody
            } else {
                phoneSheetBody
            }
        }
        .statusBar(hidden: true)
    }

    // MARK: - iPad overlay (keep your existing vibe)

    private var padOverlayBody: some View {
        VStack(spacing: 0) {
            heroView(padOverlay: true)

            ZStack(alignment: .bottom) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        headerBlock
                        modifiersBlock
                        Color.clear.frame(height: barH + 12)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                }

                bottomBar
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            }
        }
    }

    // MARK: - iPhone sheet (true “hug content”)

    private var phoneSheetBody: some View {
        GeometryReader { geo in
            let maxH = geo.size.height * 0.88
            let minH: CGFloat = 260
            let targetH = min(max(measuredContentH, minH), maxH)

            ZStack(alignment: .bottom) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        heroView(padOverlay: false)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                        VStack(alignment: .leading, spacing: 16) {
                            headerBlock
                            modifiersBlock
                        }
                        .padding(.horizontal, sidePad)
                        .padding(.top, topPad)

                        Color.clear.frame(height: barH + 16)
                    }
                }

                bottomBar
                    .padding(.horizontal, sidePad)
                    .padding(.bottom, 8)
                    .background(Color(.systemBackground))
            }
            // ✅ measure an intrinsic clone WITHOUT ScrollView
            .overlay {
                VStack(alignment: .leading, spacing: 16) {
                    heroView(padOverlay: false)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                    VStack(alignment: .leading, spacing: 16) {
                        headerBlock
                        modifiersBlock
                    }
                    .padding(.horizontal, sidePad)
                    .padding(.top, topPad)

                    // bottom bar space (so detent includes it)
                    Color.clear.frame(height: barH + 16)
                }
                .fixedSize(horizontal: false, vertical: true)
                .measurePhoneSheetHeight { h in
                    // clamp a bit to avoid jitter
                    let rounded = (h * 10).rounded() / 10
                    if abs(measuredContentH - rounded) > 1 { measuredContentH = rounded }
                }
                .opacity(0.001)
                .allowsHitTesting(false)
            }
            .onAppear {
                selectedDetent = .height(targetH)
            }
            .onChange(of: measuredContentH) { _ in
                selectedDetent = .height(targetH)
            }
            .presentationDetents([.height(targetH), .large], selection: $selectedDetent)
            .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Hero

    private func heroView(padOverlay: Bool) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let img = frozenHero {
                    Image(uiImage: img).resizable().scaledToFill()
                } else {
                    KFImage(item.img)
                        .onSuccess { frozenHero = $0.image }
                        .resizable()
                        .scaledToFill()
                }
            }
            .frame(height: heroH)
            .frame(maxWidth: .infinity)
            .clipped()

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.primary)
                    .frame(width: 34, height: 34)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
            }
            .padding(30)
        }
        .frame(height: heroH)
        .frame(maxWidth: .infinity)
        .clipped()
        .padding(.horizontal, padOverlay ? -18 : 0)
        .padding(.top, padOverlay ? -18 : 0)
    }

    // MARK: - Header / modifiers blocks

    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.name)
                .font(appFont(miniAppId, 20).weight(.semibold))
                .foregroundColor(MenuTheme.textColor)

            Text(unitPriceLabel)
                .font(appFont(miniAppId, 18))
                .foregroundColor(scheme == .dark ? .white : MenuTheme.accent)

            if let d = item.description,
               !d.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(d)
                    .font(appFont(miniAppId, 16))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var modifiersBlock: some View {
        if let groups = item.modifiers, !groups.isEmpty {
            ModifierListView(
                groups: groups,
                selectedOptions: $selectedOptions,
                selectedAdditions: $selectedAdditions
            )
            .padding(.top, 6)
        }
    }

    // MARK: - Pricing helpers

    private var unitWithExtras: Double {
        item.price + extraPricePerUnit()
    }

    private var unitPriceLabel: String {
        isRtl ? formatPrice(unitWithExtras) : "£\(formatPrice(unitWithExtras))"
    }

    private var actionTitle: String {
        if isRemoveMode { return isRtl ? "הסר" : "Remove" }
        if isUpdateMode { return isRtl ? "עדכן" : "Update" }
        return isRtl ? "הוסף" : "Add"
    }

    private var totalPriceLabel: String {
        let total = unitWithExtras * Double(max(quantity, 0))
        return isRtl ? formatPrice(total) : "£\(formatPrice(total))"
    }

    private var bottomBar: some View {
        HStack(spacing: 16) {
            HStack(spacing: 22) {
                Button {
                    if existsInBasket {
                        if quantity > 0 { quantity -= 1 }
                    } else {
                        if quantity > 1 { quantity -= 1 }
                    }
                    Haptics.light()
                } label: {
                    Circle()
                        .fill(Color(.systemGray5))
                        .frame(width: 44, height: 44)
                        .overlay(Image(systemName: "minus").font(.system(size: 18, weight: .bold)))
                }
                .buttonStyle(.plain)

                Text("\(quantity)")
                    .font(appFont(miniAppId, 20).weight(.semibold))
                    .foregroundColor(MenuTheme.textColor)

                Button {
                    quantity += 1
                    Haptics.light()
                } label: {
                    Circle()
                        .fill(Color(.systemGray5))
                        .frame(width: 44, height: 44)
                        .overlay(Image(systemName: "plus").font(.system(size: 18, weight: .bold)))
                }
                .buttonStyle(.plain)
            }

            Button {
                if isRemoveMode {
                    onAdd(item, 0, nil, item.price, selectedOptions, selectedAdditions)
                    onClose()
                    return
                }

                let subtitle = selectionSubtitle()
                onAdd(item, quantity, subtitle, unitWithExtras, selectedOptions, selectedAdditions)
                onClose()
            } label: {
                HStack {
                    Text(actionTitle)
                        .font(appFont(miniAppId, 18).weight(.semibold))
                    Spacer()
                    Text(totalPriceLabel)
                        .font(appFont(miniAppId, 18).weight(.semibold))
                }
                .padding(.horizontal, 20)
                .foregroundColor(.white)
                .frame(height: barH)
                .frame(maxWidth: .infinity)
                .background(isRemoveMode ? .red : MenuTheme.buttonBackground)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .frame(height: barH)
    }

    private func norm(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{200F}", with: "")
            .replacingOccurrences(of: "\u{200E}", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    private func extraPricePerUnit() -> Double {
        guard let groups = item.modifiers else { return 0 }

        return groups.reduce(0) { total, group in
            switch group.type {
            case .options:
                let key = norm(group.title)
                if let selected = selectedOptions[key],
                   let opt = group.items.first(where: { norm($0.name) == norm(selected) }) {
                    return total + opt.extraPrice
                }
                return total

            case .additions:
                let selectedSet = Set(selectedAdditions.map(norm))
                return total + group.items
                    .filter { selectedSet.contains(norm($0.name)) }
                    .map(\.extraPrice)
                    .reduce(0, +)
            }
        }
    }

    private func selectionSubtitle() -> String? {
        guard let groups = item.modifiers, !groups.isEmpty else { return nil }

        func norm(_ s: String) -> String {
            s.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\u{200F}", with: "")
                .replacingOccurrences(of: "\u{200E}", with: "")
                .replacingOccurrences(of: "\u{00A0}", with: " ")
        }

        var parts: [String] = []

        // ✅ Options: show only if NOT the first (default)
        for g in groups where g.type == .options {
            guard let first = g.items.first else { continue }
            let gKey = norm(g.title)
            let selected = norm(selectedOptions[gKey] ?? "")
            let def = norm(first.name)

            if !selected.isEmpty, selected != def {
                parts.append(selected)
            }
        }

        // ✅ Additions: show only non-defaults (default = first item)
        for g in groups where g.type == .additions {
            guard let first = g.items.first else { continue }
            let defaultNorm = norm(first.name)
            let groupNormNames = Set(g.items.map { norm($0.name) })

            let pickedInGroup = selectedAdditions
                .map(norm)
                .filter { groupNormNames.contains($0) }

            let nonDefault = pickedInGroup.filter { $0 != defaultNorm }

            if !nonDefault.isEmpty {
                // keep the menu order
                let ordered = g.items
                    .map { norm($0.name) }
                    .filter { nonDefault.contains($0) }

                parts.append(contentsOf: ordered)
            }
        }

        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    // MARK: - Private ModifierListView (your existing one, unchanged)

    private struct ModifierListView: View {
        let groups: [ModifierGroup]

        @Environment(\.isRtl) private var isRtl
        @AppStorage("miniAppId") private var miniAppId: Int = 0

        @Binding var selectedOptions: [String: String]
        @Binding var selectedAdditions: Set<String>

        private func norm(_ s: String) -> String {
            s.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\u{200F}", with: "")
                .replacingOccurrences(of: "\u{200E}", with: "")
                .replacingOccurrences(of: "\u{00A0}", with: " ")
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(displayTitle(for: group))
                            .font(appFont(miniAppId, 18).weight(.semibold))
                            .foregroundColor(MenuTheme.textColor)

                        if #available(iOS 16.0, *) {
                            Flow(spacing: 10, rowSpacing: 10) {
                                ForEach(group.items) { item in
                                    pill(group: group, item: item)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 76), spacing: 10)],
                                alignment: .leading,
                                spacing: 10
                            ) {
                                ForEach(group.items) { item in
                                    pill(group: group, item: item)
                                }
                            }
                        }
                    }
                }
            }
        }

        private func modifierLabel(_ item: ModifierItem) -> String {
            guard item.extraPrice > 0 else { return item.name }
            return "\(item.name) +\(formatPrice(item.extraPrice))"
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

            return Text(modifierLabel(item))
                .font(appFont(miniAppId, isRtl ? 15 : 17))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .fixedSize(horizontal: true, vertical: false)
                .background(
                    isSelected
                    ? Color(UIColor { trait in
                        trait.userInterfaceStyle == .dark
                        ? UIColor(Color(hex: "#b39d82"))
                        : UIColor(MenuTheme.buttonBackground)
                    })
                    : Color(.systemGray5)
                )
                .foregroundColor(isSelected ? .white : MenuTheme.textColor)
                .clipShape(Capsule())
                .onTapGesture {
                    handleTap(group: group, item: item)
                    Haptics.light()
                }
        }

        private func handleTap(group: ModifierGroup, item: ModifierItem) {
            let gKey = norm(group.title)
            let tapped = norm(item.name)

            switch group.type {
            case .options:
                selectedOptions[gKey] = tapped

            case .additions:
                guard let first = group.items.first else { return }

                let defaultNorm = norm(first.name)
                let groupNames = Set(group.items.map { norm($0.name) })

                func removeAllInGroup() {
                    selectedAdditions = Set(selectedAdditions.filter { !groupNames.contains($0) })
                }

                if tapped == defaultNorm {
                    removeAllInGroup()
                    selectedAdditions.insert(defaultNorm)
                    return
                }

                if selectedAdditions.contains(tapped) {
                    selectedAdditions.remove(tapped)
                } else {
                    selectedAdditions.insert(tapped)
                }

                selectedAdditions.remove(defaultNorm)

                let hasAnyInGroup = selectedAdditions.contains(where: { groupNames.contains($0) })
                if !hasAnyInGroup {
                    selectedAdditions.insert(defaultNorm)
                }
            }
        }

        private func displayTitle(for group: ModifierGroup) -> String {
            switch group.type {
            case .additions:
                return isRtl ? group.title : "Choose additions"
            case .options:
                return group.title
            }
        }
    }
}

// MARK: - iPhone measurement helper (intrinsic)

fileprivate struct PhoneSheetHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

fileprivate extension View {
    func measurePhoneSheetHeight(_ onChange: @escaping (CGFloat) -> Void) -> some View {
        background(
            GeometryReader { geo in
                Color.clear.preference(key: PhoneSheetHeightKey.self, value: geo.size.height)
            }
        )
        .onPreferenceChange(PhoneSheetHeightKey.self, perform: onChange)
    }
}
private enum MenuProductSheetSeed {
    static func norm(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{200F}", with: "")
            .replacingOccurrences(of: "\u{200E}", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    static func seed(
        item: ShellMenuItem,
        initialOptions: [String: String],
        initialAdditions: Set<String>
    ) -> (options: [String: String], additions: Set<String>) {
        var defaults = initialOptions

        if let groups = item.modifiers {
            for g in groups where g.type == .options {
                let k = norm(g.title)
                let existing = defaults.first(where: { norm($0.key) == k })?.value ?? ""
                if existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let first = g.items.first {
                    defaults[g.title] = first.name
                }
            }
        }

        var normalized: [String: String] = [:]
        for (k, v) in defaults {
            normalized[norm(k)] = norm(v)
        }

        var adds = Set(initialAdditions.map(norm))

        if let groups = item.modifiers {
            for g in groups where g.type == .additions {
                guard let first = g.items.first else { continue }
                let groupNames = Set(g.items.map { norm($0.name) })
                let def = norm(first.name)

                let hasAny = adds.contains(where: { groupNames.contains($0) })
                if !hasAny {
                    adds.insert(def)
                } else {
                    let hasNonDefault = adds.contains(where: { groupNames.contains($0) && $0 != def })
                    if hasNonDefault { adds.remove(def) }
                }
            }
        }

        return (normalized, adds)
    }
}


private struct OverlayHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private extension View {
    func measureHeight(_ onChange: @escaping (CGFloat) -> Void) -> some View {
        background(
            GeometryReader { geo in
                Color.clear.preference(key: OverlayHeightKey.self, value: geo.size.height)
            }
        )
        .onPreferenceChange(OverlayHeightKey.self, perform: onChange)
    }
}



fileprivate struct BasketOverlayCard<Content: View>: View {
    let onDismiss: () -> Void
    let preferredHeight: CGFloat
    let content: Content

    init(
        onDismiss: @escaping () -> Void,
        preferredHeight: CGFloat,
        @ViewBuilder content: () -> Content
    ) {
        self.onDismiss = onDismiss
        self.preferredHeight = preferredHeight
        self.content = content()
    }

    var body: some View {
        GeometryReader { geo in
            let maxH = geo.size.height * 0.88
            let minH: CGFloat = 320
            let targetH = min(max(preferredHeight, minH), maxH) + 0
            let cardW = min(600, geo.size.width - 80)

            ZStack {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .ignoresSafeArea()

                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture { onDismiss() }

                content
                    .frame(width: cardW, height: targetH)
                    .background(Color(.systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .shadow(color: .black.opacity(0.12), radius: 24, y: 14)
                    .onTapGesture { }
            }
        }
        .presentationBackground(.clear)
    }
}

struct GlossyOverlayCard<Content: View>: View {
    let onDismiss: () -> Void
    let content: Content

    @State private var contentH: CGFloat = 420

    init(onDismiss: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.onDismiss = onDismiss
        self.content = content()
    }

    var body: some View {
        GeometryReader { geo in
            let maxH = geo.size.height * 0.90
            let minH: CGFloat = 260
            let targetH = min(max(contentH, minH), maxH)
            let cardW = min(520, geo.size.width - 40)

            ZStack {
                // ✅ glossy background
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .ignoresSafeArea()

                // ✅ tap outside to close
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture { onDismiss() }

                // ✅ centered card
                ScrollView(showsIndicators: contentH > maxH) {
                    content
                        .padding(0)
                        .measureHeight { h in
                            let rounded = (h * 10).rounded() / 10
                            if abs(contentH - rounded) > 1 { contentH = rounded }
                        }
                }
                .scrollDisabled(contentH <= maxH)
                .frame(width: cardW, height: targetH)
                .background(Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 24, y: 14)
                .onTapGesture { } // swallow taps (don’t dismiss)
            }
        }
        .presentationBackground(.clear)
    }
}
  
//part 3 basket sheet

fileprivate struct BasketBarPrototype: View {
    let miniAppId: Int
    let isRtl: Bool
    let totalQuantity: Int
    let totalPrice: Double
    let onTap: () -> Void

    private var priceText: String {
        if miniAppId == 3 { return String(format: "£%.2f", totalPrice) }
        let rounded = (totalPrice * 100).rounded() / 100
        let oneDecimal = (rounded * 10).rounded() / 10
        let str = String(format: "%.1f", oneDecimal)
        return str.hasSuffix(".0") ? String(str.dropLast(2)) : str
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Text("\(totalQuantity)")
                    .font(appFont(miniAppId, 15).weight(.semibold))
                    .foregroundColor(adjustedBrand(for: miniAppId))
                    .frame(width: 28, height: 28)
                    .background(Color.white)
                    .clipShape(Circle())

                Text(isRtl ? "צפה בהזמנה" : "View basket")
                    .font(appFont(miniAppId, 18).weight(.semibold))
                    .foregroundColor(.white)

                Spacer()

                Text(priceText)
                    .font(appFont(miniAppId, 18).weight(.semibold))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 18)
            .frame(height: 60)
            .frame(maxWidth: .infinity)
            .background(adjustedBrand(for: miniAppId))   // solid, no transparency
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
    }
}

fileprivate struct BasketLine: Identifiable, Equatable {
    let id: Int              // productId
    let name: String
    let imageURL: String?
    let qty: Int
    let unitPrice: Double
    let subtitle: String?
    let opts: [String:String]
    let adds: Set<String>
}
 
fileprivate struct BasketSheetPrototype: View {
    let miniAppId: Int
    let isRtl: Bool
    let lines: [BasketLine]

    let onClose: () -> Void
    let onClear: () -> Void

    let onIncrement: (Int) -> Void
    let onDecrement: (Int) -> Void
    let onLineTap: (BasketLine) -> Void

    let upsells: [ShellMenuItem]
    let onAddUpsell: (ShellMenuItem) -> Void
    let onOpenUpsell: (ShellMenuItem) -> Void

    let onBackToShop: () -> Void
    let onContinueToPayment: () -> Void

    @State private var hiddenUpsellIds: Set<Int> = []
    @Environment(\.colorScheme) private var scheme

    private var basketProductIds: Set<Int> { Set(lines.map(\.id)) }

    private var visibleUpsells: [ShellMenuItem] {
        upsells.filter { u in !basketProductIds.contains(u.id) && !hiddenUpsellIds.contains(u.id) }
    }

    private var totalQty: Int { lines.reduce(0) { $0 + max(0, $1.qty) } }

    private var totalPrice: Double {
        lines.reduce(0) { $0 + (Double(max(0, $1.qty)) * $1.unitPrice) }
    }

    private func priceText(_ v: Double) -> String {
        let s = formatPrice(v)
        if isRtl { return s }
        return (miniAppId == 3) ? "£\(s)" : s
    }

    private var primaryCtaBg: Color { miniAppId == 13 ? .white : MenuTheme.buttonBackground }
    private var primaryCtaFg: Color { miniAppId == 13 ? .black : .white }

    var body: some View {
        let isPhone = UIDevice.current.userInterfaceIdiom == .phone
        let isPad = UIDevice.current.userInterfaceIdiom == .pad

        VStack(spacing: 0) {

            headerBar(isPhone: isPhone)

            ViewThatFits(in: .vertical) {

                // ✅ 1) Hug content (NO forced height, NO scroll)
                VStack(spacing: 0) {
                    contentStack(isPhone: isPhone)
                    bottomBar(isPhone: isPhone, isPad: isPad)
                }

                // ✅ 2) Fallback: scroll ONLY when needed
                VStack(spacing: 0) {
                    ScrollView(showsIndicators: true) {
                        contentStack(isPhone: isPhone)
                    }
                    bottomBar(isPhone: isPhone, isPad: isPad)
                }
            }
        }
        .background(Color(.systemBackground))
        .presentationBackground(Color(.systemBackground))
        .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
        .environment(\.locale, Locale(identifier: isRtl ? "he_IL" : "en_GB"))
    }

    private struct UpsellStripCard: View {
        let miniAppId: Int
        let isRtl: Bool
        let item: ShellMenuItem
        let onAdd: () -> Void
        let onOpen: () -> Void

        private let w: CGFloat = 170
        private let imgH: CGFloat = 120

        private var addBg: Color { miniAppId == 13 ? .white : MenuTheme.buttonBackground }
        private var addFg: Color { miniAppId == 13 ? .black : .white }

        private func priceText(_ v: Double) -> String {
            let s = formatPrice(v)
            if isRtl { return s }
            return (miniAppId == 3) ? "£\(s)" : s
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                Button(action: onOpen) {
                    KFImage(item.img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: w, height: imgH)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)

                Text(item.name)
                    .font(appFont(miniAppId, 16).weight(.semibold))
                    .lineLimit(2)
                    .frame(width: w, alignment: .leading)

                HStack(spacing: 10) {
                    Text(priceText(item.price))
                        .font(appFont(miniAppId, 14).weight(.semibold))

                    Spacer()

                    Button(action: onAdd) {
                        Text(isRtl ? "הוסף" : "Add")
                            .font(appFont(miniAppId, 14).weight(.semibold))
                            .foregroundColor(addFg)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(addBg)
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(Color.primary.opacity(miniAppId == 13 ? 0.18 : 0), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                .frame(width: w)
            }
            .frame(width: w)
        }
    }

    @ViewBuilder
    private func headerBar(isPhone: Bool) -> some View {
        ZStack {
            Text(isRtl ? "ההזמנה שלך" : "Your order")
                .font(appFont(miniAppId, 22).weight(.semibold))
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)

            HStack {
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.primary)
                        .frame(width: 34, height: 34)
                        .background(
                            Circle().fill(
                                scheme == .dark ? Color.white.opacity(0.16) : Color.black.opacity(0.08)
                            )
                        )
                        .overlay(
                            Circle().stroke(
                                scheme == .dark ? Color.white.opacity(0.22) : Color.black.opacity(0.10),
                                lineWidth: 1
                            )
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
        }
        .frame(height: 56)
        .background(Color(.systemBackground))          // ✅ opaque
        .overlay(Divider().opacity(0.25), alignment: .bottom)
    }

    @ViewBuilder
    private func contentStack(isPhone: Bool) -> some View {
        VStack(spacing: 18) {

            VStack(spacing: 14) {
                ForEach(lines) { row in
                    BasketRowInline(
                        miniAppId: miniAppId,
                        isRtl: isRtl,
                        row: row,
                        onIncrement: { onIncrement(row.id) },
                        onDecrement: { onDecrement(row.id) },
                        onTap: { onLineTap(row) }
                    )
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)

            if !visibleUpsells.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text(isRtl ? "אולי תרצו להוסיף" : "You may also like")
                        .font(appFont(miniAppId, 16).weight(.semibold))
                        .padding(.horizontal, 18)

                    if isPhone {
                        let maxItems = 10
                        let data = Array(visibleUpsells.prefix(maxItems))
                        let ordered = isRtl ? data.reversed() : data
                        let endId = "upsell-rtl-end"

                        ScrollViewReader { proxy in
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(spacing: 12) {
                                    ForEach(Array(ordered), id: \.id) { it in
                                        UpsellStripCard(
                                            miniAppId: miniAppId,
                                            isRtl: isRtl,
                                            item: it,
                                            onAdd: {
                                                hiddenUpsellIds.insert(it.id)
                                                onAddUpsell(it)
                                                if isRtl {
                                                    DispatchQueue.main.async {
                                                        proxy.scrollTo(endId, anchor: .trailing)
                                                    }
                                                }
                                            },
                                            onOpen: { onOpenUpsell(it) }
                                        )
                                        .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
                                    }

                                    if isRtl { Color.clear.frame(width: 1).id(endId) }
                                }
                                .padding(.vertical, 2)
                            }
                            .environment(\.layoutDirection, .leftToRight)
                            .onAppear {
                                guard isRtl else { return }
                                DispatchQueue.main.async { proxy.scrollTo(endId, anchor: .trailing) }
                            }
                        }
                        .padding(.horizontal, 10)

                    } else {
                        let colsCount = 3
                        let gridCols = Array(repeating: GridItem(.flexible(), spacing: 12), count: colsCount)

                        LazyVGrid(columns: gridCols, spacing: 12) {
                            ForEach(visibleUpsells.prefix(colsCount)) { it in
                                UpsellGridCard(
                                    miniAppId: miniAppId,
                                    isRtl: isRtl,
                                    item: it,
                                    onAdd: {
                                        hiddenUpsellIds.insert(it.id)
                                        onAddUpsell(it)
                                    },
                                    onOpen: { onOpenUpsell(it) }
                                )
                            }
                        }
                        .frame(maxWidth: 600, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18)
                    }
                }
                .padding(.top, 6)
            }

            Color.clear.frame(height: 10)
        }
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private func bottomBar(isPhone: Bool, isPad: Bool) -> some View {
        VStack(spacing: 14) {
            Divider().opacity(scheme == .dark ? 0.18 : 0.35)

            HStack {
                Text(isRtl ? "סה\"כ" : "Total")
                    .font(appFont(miniAppId, 18).weight(.semibold))
                Spacer()
                Text(priceText(totalPrice))
                    .font(appFont(miniAppId, 18).weight(.semibold))
            }
            .padding(.horizontal, 20)

            if isPhone {
                Button { onContinueToPayment() } label: {
                    Text(isRtl ? "המשך לתשלום" : "Checkout")
                        .font(appFont(miniAppId, 17).weight(.semibold))
                        .foregroundColor(primaryCtaFg)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(primaryCtaBg)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(lines.isEmpty || totalQty == 0)
                .opacity((lines.isEmpty || totalQty == 0) ? 0.45 : 1.0)
                .padding(.horizontal, 18)
                .padding(.bottom, 10)

            } else if isPad {
                HStack(spacing: 12) {
                    Button { onBackToShop() } label: {
                        Text(isRtl ? "חזרה להזמנה" : "Back to shop")
                            .font(appFont(miniAppId, 17).weight(.semibold))
                            .foregroundColor(.primary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                            .background(Color(.systemGray5))
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    Button { onContinueToPayment() } label: {
                        Text(isRtl ? "המשך לתשלום" : "Checkout")
                            .font(appFont(miniAppId, 17).weight(.semibold))
                            .foregroundColor(primaryCtaFg)
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                            .background(primaryCtaBg)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(lines.isEmpty || totalQty == 0)
                    .opacity((lines.isEmpty || totalQty == 0) ? 0.45 : 1.0)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 12)
            }
        }
        .background(Color(.systemBackground))  // ✅ opaque
    }
    
    private struct BasketRowInline: View {
        let miniAppId: Int
        let isRtl: Bool
        let row: BasketLine

        let onIncrement: () -> Void
        let onDecrement: () -> Void
        let onTap: () -> Void

        private var imageURL: URL? {
            if let s = row.imageURL?.trimmingCharacters(in: .whitespacesAndNewlines),
               !s.isEmpty,
               let url = URL(string: s) { return url }
            return nil
        }

        private var lineTotal: Double { row.unitPrice * Double(max(0, row.qty)) }

        private func formatLineTotal(_ value: Double) -> String {
            let s = formatPrice(value)
            if isRtl { return s }
            return (miniAppId == 3) ? "£\(s)" : s
        }

        var body: some View {
            let qty = max(0, row.qty)

            HStack(spacing: 12) {
                Group {
                    if let url = imageURL {
                        KFImage(url).resizable().scaledToFill()
                    } else {
                        Color(.systemGray5).overlay(
                            Image(systemName: "fork.knife")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.secondary)
                        )
                    }
                }
                .frame(width: 50, height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(row.name)
                        .font(appFont(miniAppId, 17).weight(.semibold))

                    if let s = row.subtitle, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(s)
                            .font(appFont(miniAppId, 15))
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }

                    Text(formatLineTotal(lineTotal))
                        .font(appFont(miniAppId, 15).weight(.semibold))
                }

                Spacer()

                HStack(spacing: 12) {
                    Button {
                        onDecrement()
                        Haptics.selection()
                    } label: {
                        Circle()
                            .fill(Color(.systemGray5))
                            .frame(width: 32, height: 32)
                            .overlay(Image(systemName: "minus").font(.system(size: 16, weight: .bold)))
                    }
                    .buttonStyle(.plain)

                    Text("\(qty)")
                        .font(appFont(miniAppId, 18).weight(.semibold))
                        .frame(minWidth: 20)

                    Button {
                        onIncrement()
                        Haptics.selection()
                    } label: {
                        Circle()
                            .fill(Color(.systemGray5))
                            .frame(width: 32, height: 32)
                            .overlay(Image(systemName: "plus").font(.system(size: 16, weight: .bold)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .foregroundColor(MenuTheme.textColor)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { onTap() }
        }
    }

    private struct UpsellGridCard: View {
        let miniAppId: Int
        let isRtl: Bool
        let item: ShellMenuItem
        let onAdd: () -> Void
        let onOpen: () -> Void

        private var addBg: Color { miniAppId == 13 ? .white : MenuTheme.buttonBackground }
        private var addFg: Color { miniAppId == 13 ? .black : .white }

        private func priceText(_ v: Double) -> String {
            let s = formatPrice(v)
            if isRtl { return s }
            return (miniAppId == 3) ? "£\(s)" : s
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                Button(action: onOpen) {
                    KFImage(item.img)
                        .resizable()
                        .scaledToFill()
                        .frame(height: 140)
                        .frame(maxWidth: .infinity)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)

                Text(item.name)
                    .font(appFont(miniAppId, 16).weight(.semibold))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 10) {
                    Text(priceText(item.price))
                        .font(appFont(miniAppId, 14).weight(.semibold))

                    Spacer()

                    Button(action: onAdd) {
                        Text(isRtl ? "הוסף" : "Add")
                            .font(appFont(miniAppId, 14).weight(.semibold))
                            .foregroundColor(addFg)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(addBg)
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(Color.primary.opacity(miniAppId == 13 ? 0.18 : 0), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
