//
//  MenuPrototypeView.swift
//  MINIS_02
//
//  ✅ VIEW FILE ONLY
import SwiftUI
import Kingfisher

// MARK: - Tiny UI-only DTOs

private struct CategoryOffsetKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]

    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

struct ProductItem: Identifiable, Equatable {
    let id: Int
    let name: String
    let category: String   // ✅ categoryId (not display title)
    let price: Double
}

enum ServiceType { case dineIn, pickup }

func appFontName(for miniAppId: Int) -> String {
    switch miniAppId {
    case 3:  return "Oswald-Regular"
    case 12: return primariesFontName
    case 13: return "Heebo-Regular"
    default: return "System"
    }
}

func appFont(_ miniAppId: Int, _ size: CGFloat) -> Font {
    let name = appFontName(for: miniAppId)
    return (name == "System") ? .system(size: size) : .custom(name, size: size)
}

func formattedPrice(_ value: Double, miniAppId: Int) -> String {
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

func adjustedBrand(for miniAppId: Int) -> Color {
    let base = Color(hex: brandHex(for: miniAppId))
    if miniAppId == 13 { return base }
    return base.opacity(1.0)
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

fileprivate struct BasketSheetMeasuredHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

fileprivate extension View {
    func measureBasketSheetHeight(_ onChange: @escaping (CGFloat) -> Void) -> some View {
        background(
            GeometryReader { geo in
                Color.clear.preference(key: BasketSheetMeasuredHeightKey.self, value: geo.size.height)
            }
        )
        .onPreferenceChange(BasketSheetMeasuredHeightKey.self, perform: onChange)
    }
}

fileprivate struct HugBasketSheet<Content: View>: View {
    let content: Content

    @State private var measuredH: CGFloat = 420
    @State private var selectedDetent: PresentationDetent = .height(420)

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        let screenH = UIScreen.main.bounds.height
        let maxH = screenH * 0.90
        let minH: CGFloat = 320
        let targetH = min(max(measuredH, minH), maxH) + 12

        // 🆕 (2026-05-08): when the measured basket content would overflow maxH
        //    (too many items), the ViewThatFits inside BasketSheetPrototype
        //    cannot choose a layout under the dynamic .height(targetH) detent
        //    — it renders BLANK. Switch to the .large detent in that case so
        //    the user gets a full-height sheet with normal scroll behavior.
        let preferredDetent: PresentationDetent =
            measuredH > maxH ? .large : .height(targetH)

        ZStack {
            content

            content
                .fixedSize(horizontal: false, vertical: true)
                .measureBasketSheetHeight { h in
                    let rounded = (h * 10).rounded() / 10
                    if abs(measuredH - rounded) > 1 { measuredH = rounded }
                }
                .opacity(0.001)
                .allowsHitTesting(false)
        }
        .onAppear { selectedDetent = preferredDetent }
        .onChange(of: measuredH) { _ in selectedDetent = preferredDetent }
        .presentationDetents([.height(targetH), .large], selection: $selectedDetent)
        .presentationDragIndicator(.visible)
    }
}


fileprivate struct HugHeightSheet<Content: View>: View {
    let content: Content

    @State private var measuredH: CGFloat = 240   // was 260
    @State private var selectedDetent: PresentationDetent = .height(240)

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        let screenH = UIScreen.main.bounds.height
        let maxH = screenH * 0.88

        let minH: CGFloat = 200   // ⬅️ reduce base height
        let targetH = min(max(measuredH, minH), maxH) + 10   // ⬅️ reduce extra padding from +20 to +10

        ZStack {
            content

            content
                .fixedSize(horizontal: false, vertical: true)
                .measureProductSheetHeight { h in
                    let rounded = (h * 10).rounded() / 10
                    if abs(measuredH - rounded) > 1 { measuredH = rounded }
                }
                .opacity(0.001)
                .allowsHitTesting(false)
        }
        .onAppear { selectedDetent = .height(targetH) }
        .onChange(of: measuredH) { _ in selectedDetent = .height(targetH) }
        .presentationDetents([.height(targetH), .large], selection: $selectedDetent)
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Service Toggle

struct ServiceToggle: View {
    @Environment(\.colorScheme) private var scheme
    let miniAppId: Int
    @Binding var selection: ServiceType
    let t: (String) -> String

    private var bg: Color { scheme == .light ? .white : Color(.secondarySystemBackground) }
    private var stroke: Color { scheme == .dark ? .white.opacity(0.18) : .black.opacity(0.10) }
    private var selectedBg: Color { scheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.08) }

    var body: some View {
        let dineText = t("service.dinein")
        let pickupText = t("service.pickup")

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

// MARK: - Category rail + bar

struct ProtoCategoryRail: View {
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

struct ProtoCategoryBar: View {
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

// MARK: - Idle + Welcome overlays

struct IdleOverlayView: View {
    let miniAppId: Int
    let countdown: Int
    let onTap: () -> Void

    private let totalSeconds: Double = 8
    private var progress: Double { max(0, min(1, Double(countdown) / totalSeconds)) }

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

struct WelcomeOverlayView: View {
    let miniAppId: Int
    let t: (String) -> String
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

                Text(t("menu.welcomeTitle"))
                    .font(appFont(miniAppId, 52).weight(.heavy))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                Text(t("menu.welcomeSubtitle"))
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


struct ProtoScrollContent<TopContent: View>: View {
    let categories: [String]          // display titles
    let products: [ProductItem]       // product.category is display title here
    let columns: [GridItem]
    let miniAppId: Int
    let headerOffset: CGFloat
    let detectionOffset: CGFloat
    let onTapProduct: (ProductItem) -> Void

    @ViewBuilder let topContent: () -> TopContent

    @Binding var selectedCategory: String
    @Binding var manualScroll: Bool
    @Binding var syncResumeAt: Date

    init(
        categories: [String],
        products: [ProductItem],
        columns: [GridItem],
        miniAppId: Int,
        headerOffset: CGFloat,
        detectionOffset: CGFloat,
        onTapProduct: @escaping (ProductItem) -> Void,
        @ViewBuilder topContent: @escaping () -> TopContent,
        selectedCategory: Binding<String>,
        manualScroll: Binding<Bool>,
        syncResumeAt: Binding<Date>
    ) {
        self.categories = categories
        self.products = products
        self.columns = columns
        self.miniAppId = miniAppId
        self.headerOffset = headerOffset
        self.detectionOffset = detectionOffset
        self.onTapProduct = onTapProduct
        self.topContent = topContent
        _selectedCategory = selectedCategory
        _manualScroll = manualScroll
        _syncResumeAt = syncResumeAt
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 18) {

                    // ✅ TOP (scrolls with content)
                    topContent()
                        .id("top")

                    ForEach(Array(categories.enumerated()), id: \.element) { idx, category in
                        let isPromoHeader = (idx == 0)   // ✅ first entry is "Today soups"

                        VStack(alignment: .leading, spacing: isPromoHeader ? 6 : 12) {

                            Color.clear.frame(height: isPromoHeader ? 6 : headerOffset)

                            if isPromoHeader {
                                // ✅ invisible anchor for offset tracking (still updates CategoryOffsetKey)
                                Color.clear
                                    .frame(height: 0)
                                    .padding(.horizontal, 16)
                                    .background(
                                        GeometryReader { geo in
                                            Color.clear.preference(
                                                key: CategoryOffsetKey.self,
                                                value: [category: geo.frame(in: .named("scroll")).minY]
                                            )
                                        }
                                    )
                            } else {
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
                            }

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
                        .id(category)
                    }

                    Color.clear.frame(height: 120)
                }
            }
            .coordinateSpace(name: "scroll")

            .onChange(of: selectedCategory) { value in
                guard manualScroll else { return }
                guard !value.isEmpty else { return }

                let target = (value == "__today_soup__") ? "top" : value

                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.55)) {
                        proxy.scrollTo(target, anchor: .top)
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

struct ProductCardView: View {
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



struct HighlightProductCardTall: View {
    let miniAppId: Int
    let item: ShellMenuItem

    private let w: CGFloat = 150
    private let imgH: CGFloat = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            KFImage(item.img)
                .resizable()
                .scaledToFill()
                .frame(width: w, height: imgH)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

            Text(item.name)
                .font(appFont(miniAppId, 14).weight(.semibold))
                .foregroundColor(.white)
                .lineLimit(2)
                .frame(width: w, alignment: .leading)

            Text(formatPrice(item.price))
                .font(appFont(miniAppId, 13).weight(.semibold))
                .foregroundColor(.white.opacity(0.7))
                .frame(width: w, alignment: .leading)
        }
        .frame(width: w, alignment: .leading)
    }
}

// MARK: - Basket UI (bar + sheets)  ✅ view only

fileprivate struct BasketBarPrototype: View {
    let miniAppId: Int
    let isRtl: Bool
    let totalQuantity: Int
    let totalPrice: Double
    let onTap: () -> Void
    let t: (String) -> String

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

                Text(t("basket.view"))
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
            .background(adjustedBrand(for: miniAppId))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
    }
}

fileprivate struct BasketLine: Identifiable, Equatable {
    let id: Int
    let name: String
    let imageURL: String?
    let qty: Int
    let unitPrice: Double
    let subtitle: String?
    let opts: [String:String]
    let adds: Set<String>
}

// NOTE: BasketSheetPrototype and MenuProductSheet are still in this view file in your current code.
// To keep this response focused (and because they are huge), we’ll leave them as-is for now.
// ✅ When you say “continue”, I’ll paste the cleaned BasketSheetPrototype + MenuProductSheet into this view file too,
// with ONLY view logic (no model structs), matching your current working version.

// MARK: - MAIN VIEW

struct MenuPrototypeView: View {
    @Environment(\.colorScheme) private var scheme
    @StateObject private var store = MockShopStore()   // ✅ comes from MODEL file
    @AppStorage("menu.myItems.v1") private var myItemsRaw: String = "[]"

    @State private var miniAppId: Int = 12
    @State private var showWelcome: Bool = false
    @State private var sheetItem: ShellMenuItem? = nil
    @State private var showContextPicker: Bool = false
    
    // basket (you already have this logic; keep it)
    private struct LocalLine: Codable, Equatable {
        var qty: Int
        var unitPrice: Double
        var subtitle: String?
        var opts: [String:String]
        var adds: Set<String>
    }
  
    // decoded ids (most recent first)
    private var myItemIds: [Int] {
        (try? JSONDecoder().decode([Int].self, from: Data(myItemsRaw.utf8))) ?? []
    }
    
    private struct TopHeaderBar: View {
        let miniAppId: Int
        let isPad: Bool
        let isRtl: Bool

        let languagePill: AnyView
        let contextTitle: String?
        let contextValue: String?

        // ✅ NEW: provide context menu options (already localized strings)
        // Example: store.contextOptions.map { ($0.id, $0.label.resolve(...)) }
        let contextOptions: [(id: String, label: String)]
        let selectedContextId: String

        let onSelectContext: (String) -> Void
        let onClearContext: () -> Void
        let onTapLoyalty: () -> Void

        @Environment(\.colorScheme) private var scheme

        private var chipBg: Color {
            scheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.06)
        }
        private var chipStroke: Color {
            scheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.10)
        }

        private var hPad: CGFloat { isPad ? 14 : 10 }   // ✅ tighter than 16
        private var topPad: CGFloat { isPad ? 10 : 6 }
        private var bottomPad: CGFloat { 6 }

        private var contextText: String? {
            let v = (contextValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty { return v }
            let t = (contextTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }

        var body: some View {
            HStack(spacing: 10) {
                languagePill

                Spacer(minLength: 6)

                if let text = contextText {
                    Menu {
                        ForEach(contextOptions, id: \.id) { opt in
                            Button {
                                onSelectContext(opt.id)
                                Haptics.selection()
                            } label: {
                                if opt.id == selectedContextId {
                                    Label(opt.label, systemImage: "checkmark")
                                } else {
                                    Text(opt.label)
                                }
                            }
                        }

                        if !selectedContextId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Divider()
                            Button(role: .destructive) {
                                onClearContext()
                                Haptics.selection()
                            } label: {
                                Label("Clear", systemImage: "xmark.circle")
                            }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "mappin.and.ellipse")
                                .font(.system(size: 13, weight: .semibold))

                            Text(text)
                                .font(appFont(miniAppId, 13).weight(.semibold))
                                .lineLimit(1)

                            Image(systemName: "chevron.down")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.primary.opacity(0.35))
                        }
                        .foregroundColor(.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 999, style: .continuous)
                                .fill(chipBg)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 999, style: .continuous)
                                        .stroke(chipStroke, lineWidth: 1)
                                )
                        )
                    }
                    .menuStyle(.button)
                }

                Button(action: onTapLoyalty) {
                    Image(systemName: "wallet.pass")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.primary)
                        .frame(width: 34, height: 34)
                        .background(
                            Circle()
                                .fill(chipBg)
                                .overlay(Circle().stroke(chipStroke, lineWidth: 1))
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, hPad)
            .padding(.top, topPad)
            .padding(.bottom, bottomPad)
            .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
        }
    }
    
    private var contextTitle: String? {
        let t = store.contextTitleText.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private var contextValue: String? {
        // show selected option label if selected
        let id = store.selectedContextId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        guard let opt = store.contextOptions.first(where: { $0.id == id }) else { return nil }
        let v = opt.label.resolve(lang: store.lang, fallback: store.defaultLang)
        let trimmed = v.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var languagePillView: AnyView {
        AnyView(languagePill)
    }

    private func saveMyItemIds(_ ids: [Int]) {
        if let data = try? JSONEncoder().encode(ids),
           let s = String(data: data, encoding: .utf8) {
            myItemsRaw = s
        }
    }

    // call this whenever a product is added/updated (qty > 0)
    private func pushMyItem(_ productId: Int) {
        var ids = myItemIds
        ids.removeAll(where: { $0 == productId })      // de-dupe
        ids.insert(productId, at: 0)                   // newest first
        if ids.count > 9 { ids = Array(ids.prefix(9)) } // cap 9
        saveMyItemIds(ids)
    }

    // resolved items for UI (skip ids not in menu json)
    private var myItems: [ShellMenuItem] {
        myItemIds.compactMap { itemsById[$0] }
    }
    
  
    private struct MyItemsHeaderTiles: View {

            let miniAppId: Int

            let isRtl: Bool

            let title: String

            let items: [ShellMenuItem]

            let maxItems: Int

            let onTap: (ShellMenuItem) -> Void



            private let w: CGFloat = 160

            private let imgH: CGFloat = 110



            var body: some View {

                let shown = Array(items.prefix(maxItems))

                if !shown.isEmpty {

                    VStack(alignment: .leading, spacing: 12) {

                        Text(title)

                            .font(appFont(miniAppId, 22).weight(.semibold))

                            .foregroundColor(.primary)

                            .padding(.horizontal, 16)



                        ScrollView(.horizontal, showsIndicators: false) {

                            HStack(spacing: 12) {

                                ForEach(shown) { it in

                                    Button { onTap(it) } label: {

                                        VStack(alignment: .leading, spacing: 8) {

                                            KFImage(it.img)

                                                .resizable()

                                                .scaledToFill()

                                                .frame(width: w, height: imgH)

                                                .clipped()

                                                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))



                                            Text(it.name)

                                                .font(appFont(miniAppId, 16).weight(.semibold))

                                                .foregroundColor(.primary)

                                                .lineLimit(1)

                                                .frame(width: w, alignment: .leading)



                                            Text(formatPrice(it.price))

                                                .font(appFont(miniAppId, 14).weight(.semibold))

                                                .foregroundColor(.secondary)

                                                .frame(width: w, alignment: .leading)

                                        }

                                        .frame(width: w, alignment: .leading)

                                    }

                                    .buttonStyle(.plain)

                                }

                            }

                            .padding(.horizontal, 16)

                        }

                    }

                    .padding(.top, 6)

                    .padding(.bottom, 10)

                    .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)

                }

            }

        }
    private struct MyItemsHeaderDiscoverGrid: View {
        let miniAppId: Int
        let isRtl: Bool
        let title: String
        let items: [ShellMenuItem]          // most recent first
        let maxRows: Int                    // 3
        let maxColumns: Int                 // 3
        let onTap: (ShellMenuItem) -> Void

        private let thumb: CGFloat = 44
        private let rowSpacing: CGFloat = 18
        private let colSpacing: CGFloat = 18

        private var capped: [ShellMenuItem] {
            Array(items.prefix(maxRows * maxColumns))
        }

        private var columns: [[ShellMenuItem]] {
            stride(from: 0, to: capped.count, by: maxRows).map { start in
                let end = min(start + maxRows, capped.count)
                return Array(capped[start..<end])
            }
            .prefix(maxColumns)
            .map { $0 }
        }

        var body: some View {
            if !capped.isEmpty {
                GeometryReader { geo in
                    let pageW = geo.size.width * 0.70
                    let sidePeek = (geo.size.width - pageW) / 2

                    VStack(alignment: .leading, spacing: 14) {

                        Text(title)
                            .font(appFont(miniAppId, 22).weight(.semibold))
                            .foregroundColor(.primary)
                            .padding(.horizontal, 8)

                        if #available(iOS 17.0, *) {
                            ScrollView(.horizontal) {
                                LazyHStack(spacing: colSpacing) {
                                    ForEach(Array(columns.enumerated()), id: \.offset) { _, col in
                                        columnView(col)
                                            .frame(width: pageW, alignment: .leading)
                                            .scrollTargetLayout() // each column becomes a paging target
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                            .scrollIndicators(.hidden)
                            .scrollTargetBehavior(.paging)          // ✅ real paging + snap
                            .safeAreaPadding(.leading, 8)          // small fixed leading padding
                            .safeAreaPadding(.trailing, sidePeek)   // keep peek on the right
                        } else {
                            // Fallback (no true paging on iOS 16): still shows peek + scroll
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: colSpacing) {
                                    ForEach(Array(columns.enumerated()), id: \.offset) { _, col in
                                        columnView(col)
                                            .frame(width: pageW, alignment: .leading)
                                    }
                                }
                                .padding(.horizontal, sidePeek)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, 8)
                    .padding(.bottom, 10)
                    .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
                }
                .frame(height: headerHeight) // keeps it from stealing vertical space
            }
        }

        private var headerHeight: CGFloat {
            // title + rows (approx). tweak if you want.
            22 + 14 + (CGFloat(maxRows) * thumb) + (CGFloat(maxRows - 1) * rowSpacing) + 18
        }

        private func columnView(_ col: [ShellMenuItem]) -> some View {
            VStack(alignment: .leading, spacing: rowSpacing) {
                ForEach(col) { item in
                    Button { onTap(item) } label: { row(item) }
                        .buttonStyle(.plain)
                }

                if col.count < maxRows {
                    ForEach(0..<(maxRows - col.count), id: \.self) { _ in
                        Color.clear.frame(height: thumb)
                    }
                }
            }
        }

        private func row(_ item: ShellMenuItem) -> some View {
            HStack(spacing: 14) {
                KFImage(item.img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: thumb, height: thumb)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                Text(item.name)
                    .font(appFont(miniAppId, 14).weight(.regular))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
    }
    
    private func displayCategoryTitle(_ id: String) -> String {
        if id == "__today_soup__" { return store.t("promo.soups") } // or store.t("promo.todaySoupTitle")
        return store.categoryTitle(for: id)
    }
    
    @State private var localBasket: [Int: LocalLine] = [:]
    @State private var showBasketSheet: Bool = false
    @State private var basketPhoneDetent: PresentationDetent = .height(420)

    // idle
    @State private var lastInteractionAt: Date = Date()
    @State private var showIdle: Bool = false
    @State private var idleCountdown: Int = 8
    private let idleStartAfter: TimeInterval = 30
    private let highlightsAnchorId = "__highlights__"
    private let idleTick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    // MARK: - Basket helpers (MISSING)

    
    private var basketLines: [BasketLine] {
        localBasket
            .sorted(by: { $0.key < $1.key })
            .map { (id, l) in
                let item = itemsById[id]
                return BasketLine(
                    id: id,
                    name: item?.name ?? (l.subtitle ?? (effectiveIsRtl ? "פריט" : "Item")),
                    imageURL: item?.imageURL,
                    qty: l.qty,
                    unitPrice: l.unitPrice,
                    subtitle: l.subtitle,
                    opts: l.opts,
                    adds: l.adds
                )
            }
    }

    // MARK: - Upsells (MISSING)
    private var upsells: [ShellMenuItem] {
        [
            ShellMenuItem(
                id: 9001,
                name: "קרואסון חמאה",
                price: 9.0,
                category: "",
                modifiers: nil,
                imageURL: "https://picsum.photos/seed/upsell-1/800/800",
                description: nil
            ),
            ShellMenuItem(
                id: 9002,
                name: "מיץ תפוזים",
                price: 12.0,
                category: "",
                modifiers: nil,
                imageURL: "https://picsum.photos/seed/upsell-2/800/800",
                description: nil
            ),
            ShellMenuItem(
                id: 9003,
                name: "עוגיית שוקולד",
                price: 7.0,
                category: "",
                modifiers: nil,
                imageURL: "https://picsum.photos/seed/upsell-3/800/800",
                description: nil
            )
        ]
    }

    // MARK: - Basket actions (MISSING)

    private func onLineTap(_ row: BasketLine) {
        // open product sheet for editing this line
        if let it = itemsById[row.id] {
            sheetItem = it
        }
    }

    private func onAddUpsell(_ item: ShellMenuItem) {
        // add 1 instantly, no modifiers
        if var existing = localBasket[item.id] {
            existing.qty += 1
            localBasket[item.id] = existing
        } else {
            localBasket[item.id] = LocalLine(
                qty: 1,
                unitPrice: item.price,
                subtitle: nil,
                opts: [:],
                adds: []
            )
        }
    }

    private func onOpenUpsell(_ item: ShellMenuItem) {
        sheetItem = item
    }
    private var basketPreferredHeight: CGFloat {
        let rowCount = basketLines.count
        let headerH: CGFloat = 56
        let rowH: CGFloat = 84
        let bottomH: CGFloat = 175
        let upsellBlockH: CGFloat = upsells.isEmpty ? 0 : 260
        return headerH + (CGFloat(rowCount) * rowH) + upsellBlockH + bottomH + 56
    }

    @ViewBuilder
    private var basketPadCover: some View {
        BasketOverlayCard(
            onDismiss: { showBasketSheet = false },
            preferredHeight: basketPreferredHeight
        ) {
            BasketSheetPrototype(
                miniAppId: miniAppId,
                isRtl: effectiveIsRtl,
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
                onLineTap: { row in onLineTap(row) },
                upsells: upsells,
                onAddUpsell: { item in onAddUpsell(item) },
                onOpenUpsell: { item in onOpenUpsell(item) },
                onBackToShop: { showBasketSheet = false },
                onContinueToPayment: { showBasketSheet = false },
                t: store.t
            )
            .environment(\.layoutDirection, effectiveIsRtl ? .rightToLeft : .leftToRight)
            .environment(\.locale, effectiveLocale)
            .environment(\.isRtl, effectiveIsRtl)
        }
    }

    @ViewBuilder
    private var basketPhoneSheet: some View {
        BasketSheetPrototype(
            miniAppId: miniAppId,
            isRtl: effectiveIsRtl,
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
                if localBasket.isEmpty { showBasketSheet = false }
            },
            onLineTap: { row in onLineTap(row) },
            upsells: upsells,
            onAddUpsell: { item in onAddUpsell(item) },
            onOpenUpsell: { item in onOpenUpsell(item) },
            onBackToShop: { showBasketSheet = false },
            onContinueToPayment: { showBasketSheet = false },
            t: store.t
        )
      
        .presentationDragIndicator(.visible)
        .presentationBackground(Color(.systemBackground))
        .environment(\.layoutDirection, effectiveIsRtl ? .rightToLeft : .leftToRight)
        .environment(\.locale, effectiveLocale)
        .environment(\.isRtl, effectiveIsRtl)
    }
    private var basketQty: Int {
        localBasket.values.reduce(0) { $0 + max(0, $1.qty) }
    }

    private var basketTotal: Double {
        localBasket.values.reduce(0) { $0 + (Double(max(0, $1.qty)) * $1.unitPrice) }
    }

    private var shouldShowBasketBar: Bool {
        basketQty > 0 && !showWelcome && !showIdle
    }
    // category scrolling
    @State private var selectedCategory: String = ""
    @State private var manualScroll = false
    @State private var syncResumeAt: Date = .distantPast
    private let headerOffsetPad: CGFloat = 20
    private let headerOffsetPhone: CGFloat = 20
    private let detectionOffset: CGFloat = 100

    // service
    @AppStorage("checkout.intent") private var checkoutIntentRaw: String = "sit"
    @AppStorage("serviceModeLabel") private var serviceModeLabel: String = ""

    // MARK: - Derived

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    private var headerOffset: CGFloat { isPad ? headerOffsetPad : headerOffsetPhone }
    private var bg: Color { scheme == .light ? .white : Color(.systemBackground) }
    private var brand: Color { adjustedBrand(for: miniAppId) }

    private var effectiveIsRtl: Bool { store.isRtl }
    private var effectiveLocale: Locale {
        let l = store.lang.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if l == "en" { return Locale(identifier: "en_GB") }
        if l == "he" { return Locale(identifier: "he_IL") }
        return Locale(identifier: l)
    }

    private var columns: [GridItem] {
        let count = isPad ? 3 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 12), count: count)
    }

    private var showServiceToggle: Bool { miniAppId == 12 }

    private var serviceBinding: Binding<ServiceType> {
        Binding(
            get: {
                let v = checkoutIntentRaw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return (v == "ta" || v == "pickup") ? .pickup : .dineIn
            },
            set: { newValue in
                checkoutIntentRaw = (newValue == .pickup) ? "ta" : "sit"
                if effectiveIsRtl {
                    serviceModeLabel = (newValue == .pickup) ? "לקחת" : "לשבת"
                } else {
                    serviceModeLabel = (newValue == .pickup) ? "Pickup" : "Dine-in"
                }
            }
        )
    }

    // MARK: - Products / categories from store.shop

    private var products: [ProductItem] {
        guard let shop = store.shop else { return [] }
        return shop.products.map { p in
            ProductItem(
                id: p.id,
                name: p.displayName(lang: store.lang, fallback: store.defaultLang),
                category: p.categoryId,
                price: p.price
            )
        }
    }

    private var categoryIds: [String] {
        guard let shop = store.shop else { return [] }

        let base = shop.categoryOrder ?? shop.categories.map(\.id)

        // Inject virtual category at top
        return ["__today_soup__"] + base
    }

    private var categoryTitles: [String] {
        categoryIds.map(displayCategoryTitle)
    }

    // MARK: - Shell mapping (sheet + highlights)

    private func toShell(_ p: ProductItem) -> ShellMenuItem {
        let realImage = store.shop?.products.first(where: { $0.id == p.id })?.image
        let img = (realImage?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? realImage
            : "https://picsum.photos/seed/\(p.id)/800/800"

        return ShellMenuItem(
            id: p.id,
            name: p.name,
            price: p.price,
            category: store.categoryTitle(for: p.category),
            modifiers: nil, // ✅ leave nil in prototype (or keep your sampleModifiers)
            imageURL: img,
            description: nil
        )
    }

    private var itemsById: [Int: ShellMenuItem] {
        Dictionary(uniqueKeysWithValues: products.map { ($0.id, toShell($0)) })
    }

    // MARK: - Highlights (top-only + 5 tiles)

    private struct Highlight: Identifiable {
        let id: String
        let titleKey: String
        let productIds: [Int]
        let fromHour: Int?
        let toHour: Int?
        let priority: Int
    }

    private func nowHourIL() -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Jerusalem") ?? .current
        return cal.component(.hour, from: Date())
    }

    private func isActive(_ h: Highlight, nowHour: Int) -> Bool {
        let from = h.fromHour
        let to = h.toHour
        if from == nil && to == nil { return true }
        if let from, let to {
            if from == to { return true }
            if from < to { return nowHour >= from && nowHour < to }
            return (nowHour >= from || nowHour < to)
        }
        if let from { return nowHour >= from }
        if let to { return nowHour < to }
        return true
    }

    private var highlights: [Highlight] {
        [
            .init(id: "soups",    titleKey: "promo.soups",    productIds: [744, 755], fromHour: 12, toHour: 15, priority: 30),
            .init(id: "pastries", titleKey: "promo.pastries", productIds: [744],      fromHour: 16, toHour: 18, priority: 20),
            .init(id: "shabbat",  titleKey: "promo.shabbat",  productIds: [755],      fromHour: 8,  toHour: 12, priority: 10)
        ]
    }

    private func makeHighlightTiles(for h: Highlight, desiredCount: Int) -> [ShellMenuItem] {
        var base = h.productIds.compactMap { itemsById[$0] }
        if base.isEmpty { base = Array(itemsById.values) }
        guard !base.isEmpty else { return [] }

        // ✅ NO REPEAT. Just shuffle + take up to desiredCount.
        base.shuffle()
        return Array(base.prefix(desiredCount))
    }

    @ViewBuilder
    private var todayHighlightsGrid: some View {
        let now = nowHourIL()

        let sorted = highlights.sorted { $0.priority > $1.priority }
        let active = sorted.filter { isActive($0, nowHour: now) }

        // ✅ If nothing is active right now, still show the top promo
        if let top = (active.first ?? sorted.first) {
            let title = store.t(top.titleKey)
            let items = makeHighlightTiles(for: top, desiredCount: 5)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(title)
                        .font(appFont(miniAppId, 22).weight(.semibold))
                        .foregroundColor(.white)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(items) { item in
                            Button { sheetItem = item } label: {
                                HighlightProductCardTall(miniAppId: miniAppId, item: item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
                }
            }
            .background(Color.clear)
        } else {
            EmptyView()
        }
    }
    // MARK: - Language pill

    private var languagePill: some View {
        HStack(spacing: 6) {

            langButton("EN", code: "en")
            Divider().frame(height: 14).opacity(0.25)

            langButton("ع", code: "ar")
            Divider().frame(height: 14).opacity(0.25)

            langButton("עב", code: "he")
            Divider().frame(height: 14).opacity(0.25)

            langButton("IT", code: "it")
        }
        .font(.system(size: 13, weight: .bold))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
    }

    @ViewBuilder
    private func langButton(_ title: String, code: String) -> some View {
        Button(title) {
            store.lang = code
        }
        .foregroundColor(
            store.lang == code
            ? .primary
            : .primary.opacity(0.35)
        )
    }

    // MARK: - Interaction

    private func registerInteraction() {
        lastInteractionAt = Date()
        if showIdle {
            showIdle = false
            idleCountdown = 8
        }
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            bg.ignoresSafeArea()

            if store.shop == nil {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Loading mock JSON…")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .onAppear { store.loadMock() }

            } else {

                if isPad {

                    HStack(spacing: 0) {

                        // LEFT rail
                        VStack(spacing: 10) {
                            if showServiceToggle {
                                ServiceToggle(miniAppId: miniAppId, selection: serviceBinding, t: store.t)
                                    .padding(.horizontal, 10)
                                    .padding(.top, 12)
                                    .padding(.bottom, 6)
                            } else {
                                Color.clear.frame(height: 12)
                            }

                            ProtoCategoryRail(
                                categories: categoryIds.map(displayCategoryTitle),
                                miniAppId: miniAppId,
                                selectedCategory: Binding(
                                    get: { displayCategoryTitle(selectedCategory) },
                                    set: { _ in }
                                ),
                                onTap: { tappedTitle in
                                    // map title -> id
                                    let tappedId =
                                        tappedTitle == displayCategoryTitle("__today_soup__")
                                        ? "__today_soup__"
                                        : (categoryIds.first(where: { displayCategoryTitle($0) == tappedTitle }) ?? selectedCategory)

                                    manualScroll = true
                                    syncResumeAt = Date().addingTimeInterval(0.9)

                                    withAnimation(.spring(response: 0.22, dampingFraction: 0.92)) {
                                        selectedCategory = tappedId
                                    }
                                }
                            )

                            Spacer(minLength: 0)
                        }
                        .frame(width: 220)
                        .background(bg)

                        // RIGHT content
                        VStack(spacing: 0) {
                          

                            ProtoScrollContent(
                                categories: categoryTitles,
                                products: products.map { p in
                                    ProductItem(
                                        id: p.id,
                                        name: p.name,
                                        category: store.categoryTitle(for: p.category),
                                        price: p.price
                                    )
                                },
                                columns: columns,
                                miniAppId: miniAppId,
                                headerOffset: headerOffset,
                                detectionOffset: detectionOffset,
                                onTapProduct: { p in
                                    if let real = products.first(where: { $0.id == p.id }) {
                                        sheetItem = toShell(real)
                                    }
                                },
                                topContent: {
                                    // ✅ scrolls with grid
                                   
                                },
                                selectedCategory: Binding(
                                    get: { store.categoryTitle(for: selectedCategory) },
                                    set: { newTitle in
                                        if let id = categoryIds.first(where: { store.categoryTitle(for: $0) == newTitle }) {
                                            selectedCategory = id
                                        }
                                    }
                                ),
                                manualScroll: $manualScroll,
                                syncResumeAt: $syncResumeAt
                            )
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }

                } else {

                    ScrollViewReader { proxy in
                        ScrollView {
                            Color.clear.frame(height: 0).id("__scrollTop__")
                            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {

                                VStack(spacing: 12) {
                                    TopHeaderBar(
                                        miniAppId: miniAppId,
                                        isPad: false,
                                        isRtl: effectiveIsRtl,

                                        languagePill: languagePillView,

                                        contextTitle: contextTitle,
                                        contextValue: contextValue,

                                        contextOptions: (store.contextOptions.map {
                                            (id: $0.id, label: $0.label.resolve(lang: store.lang, fallback: store.defaultLang))
                                        }),

                                        selectedContextId: store.selectedContextId,

                                        onSelectContext: { id in
                                            store.setSelectedContext(id)
                                            // if you still keep this for debug, you can close it:
                                            showContextPicker = false
                                        },

                                        onClearContext: {
                                            store.clearSelectedContext()
                                            // optional:
                                            showContextPicker = false
                                        },

                                        onTapLoyalty: {
                                            // TODO: open loyalty / pass
                                        }
                                    )
                                    if !isPad {

                                                                           MyItemsHeaderTiles(

                                                                               miniAppId: miniAppId,

                                                                               isRtl: effectiveIsRtl,

                                                                               title: (store.t("myitems.title") == "myitems.title")

                                                                                     ? (effectiveIsRtl ? "הפריטים שלי" : "My items")

                                                                                     : store.t("myitems.title"),

                                                                               items: myItems,           // ✅ persisted list (up to 9)

                                                                               maxItems: 9,

                                                                               onTap: { it in

                                                                                   sheetItem = it        // ✅ opens product sheet

                                                                               }

                                                                           )


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
                                    
                                    todayHighlightsGrid
                                        .id(highlightsAnchorId)
                                      
                                    
                                    LazyVStack(alignment: .leading, spacing: 18) {
                                        Color.clear.frame(height: 1).id("top")

                                        ForEach(categoryIds, id: \.self) { categoryId in
                                            let categoryTitle = store.categoryTitle(for: categoryId)

                                            VStack(alignment: .leading, spacing: 12) {
                                                Color.clear.frame(height: headerOffset)

                                                // ✅ keep the text headers inside the list
                                                if categoryId != "__today_soup__" {
                                                    Text(categoryTitle)
                                                        .font(appFont(miniAppId, 22))
                                                        .padding(.horizontal, 16)
                                                        .background(
                                                            GeometryReader { geo in
                                                                Color.clear.preference(
                                                                    key: CategoryOffsetKey.self,
                                                                    value: [categoryId: geo.frame(in: .named("scroll")).minY]
                                                                )
                                                            }
                                                        )
                                                } else {
                                                    // ✅ invisible header for offset tracking
                                                    Color.clear
                                                        .frame(height: 0)
                                                        .padding(.horizontal, 16)
                                                        .background(
                                                            GeometryReader { geo in
                                                                Color.clear.preference(
                                                                    key: CategoryOffsetKey.self,
                                                                    value: [categoryId: geo.frame(in: .named("scroll")).minY]
                                                                )
                                                            }
                                                        )
                                                }

                                                LazyVGrid(columns: columns, spacing: 12) {
                                                    let sectionProducts: [ProductItem] = {
                                                        if categoryId == "__today_soup__" {
                                                            let active = highlights
                                                                .filter { isActive($0, nowHour: nowHourIL()) }
                                                                .sorted { $0.priority > $1.priority }
                                                            guard let top = active.first else { return [] }
                                                            let items = top.productIds.compactMap { itemsById[$0] }

                                                            return items.map {
                                                                ProductItem(id: $0.id, name: $0.name, category: "__today_soup__", price: $0.price)
                                                            }
                                                        } else {
                                                            return products.filter { $0.category == categoryId }
                                                        }
                                                    }()

                                                    ForEach(sectionProducts) { p in
                                                        Button {
                                                            if categoryId == "__today_soup__" {
                                                                sheetItem = itemsById[p.id]
                                                            } else if let real = products.first(where: { $0.id == p.id }) {
                                                                sheetItem = toShell(real)
                                                            }
                                                        } label: {
                                                            ProductCardView(item: p, miniAppId: miniAppId)
                                                        }
                                                        .buttonStyle(.plain)
                                                    }
                                                }
                                                .padding(.horizontal, 16)
                                            }
                                            .id(categoryId)
                                        }

                                        Color.clear.frame(height: 40)
                                    }

                                } header: {
                                    ProtoCategoryBar(
                                        categories: categoryIds.map(displayCategoryTitle),
                                        miniAppId: miniAppId,
                                        selectedCategory: Binding(
                                            get: { displayCategoryTitle(selectedCategory) },
                                            set: { _ in }
                                        ),
                                        onTap: { tappedTitle in
                                            let tappedId =
                                            tappedTitle == displayCategoryTitle("__today_soup__")
                                            ? "__today_soup__"
                                            : (categoryIds.first(where: { displayCategoryTitle($0) == tappedTitle }) ?? selectedCategory)
                                            
                                            manualScroll = true
                                            syncResumeAt = Date().addingTimeInterval(0.9)
                                            selectedCategory = tappedId
                                            
                                            DispatchQueue.main.async {
                                                withAnimation(.easeInOut(duration: 0.45)) {
                                                    proxy.scrollTo(tappedId == "__today_soup__" ? "__scrollTop__" : tappedId, anchor: .top)
                                                }
                                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                                    withAnimation(.easeInOut(duration: 0.25)) {
                                                        proxy.scrollTo(tappedId == "__today_soup__" ? "__scrollTop__" : tappedId, anchor: .top)
                                                    }
                                                }
                                            }
                                            
                                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                                                manualScroll = false
                                            }
                                        }
                                    )
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
                    IdleOverlayView(miniAppId: miniAppId, countdown: idleCountdown) { registerInteraction() }
                        .ignoresSafeArea()
                        .zIndex(9998)
                        .transition(.opacity)
                }

                if isPad && showWelcome && !showBasketSheet {
                    WelcomeOverlayView(miniAppId: miniAppId, t: store.t) {
                        withAnimation(.easeOut(duration: 0.25)) { showWelcome = false }
                    }
                    .ignoresSafeArea()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
                    .zIndex(9999)
                }
            }
        }
        .overlay(alignment: .top) {
            GeometryReader { geo in
                (scheme == .light ? Color.white : Color(.systemBackground))
                    .frame(height: geo.safeAreaInsets.top)
                    .frame(maxWidth: .infinity)
                    .ignoresSafeArea(edges: .top)
            }
            .frame(height: 0)
            .zIndex(9999)
        }
        .overlay(alignment: .top) {
            if isPad {
                TopHeaderBar(
                    miniAppId: miniAppId,
                    isPad: true,
                    isRtl: effectiveIsRtl,

                    // Hide language pill while welcome overlay is up.
                    languagePill: showWelcome ? AnyView(EmptyView()) : languagePillView,

                    contextTitle: contextTitle,
                    contextValue: contextValue,

                    contextOptions: store.contextOptions.map {
                        (id: $0.id, label: $0.label.resolve(lang: store.lang, fallback: store.defaultLang))
                    },
                    selectedContextId: store.selectedContextId,

                    onSelectContext: { id in
                        store.setSelectedContext(id)
                    },
                    onClearContext: {
                        store.clearSelectedContext()
                    },

                    onTapLoyalty: {
                        // TODO
                    }
                )
                .padding(.top, 6)   // optional tweak for iPad safe area
            }
        }

        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { registerInteraction() })
        .simultaneousGesture(DragGesture(minimumDistance: 12).onEnded { _ in registerInteraction() })
        .overlay(alignment: .bottom) {
            if shouldShowBasketBar {
                GeometryReader { geo in
                    let railW: CGFloat = isPad ? 220 : 0          // ✅ same as your left rail width
                    let sidePad: CGFloat = 16
                    let buttonH: CGFloat = 60

                    VStack(spacing: 0) {
                        Spacer()

                        HStack(spacing: 0) {
                            if isPad {
                                // ✅ reserve space for the left rail so the bar starts AFTER it
                                Color.clear.frame(width: railW)
                            }

                            BasketBarPrototype(
                                miniAppId: miniAppId,
                                isRtl: effectiveIsRtl,
                                totalQuantity: basketQty,
                                totalPrice: basketTotal,
                                onTap: { showBasketSheet = true },
                                t: store.t
                            )
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .padding(.horizontal, sidePad)
                        }
                        .frame(width: geo.size.width, height: buttonH, alignment: .trailing)
                        .padding(.bottom, isPad ? 10 : 0)
                    }
                }
                .transition(.move(edge: .bottom))
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.9), value: shouldShowBasketBar)
        .statusBar(hidden: true)

        .onReceive(idleTick) { _ in
            guard isPad else { return }
            guard !showWelcome else { return }
            guard !showBasketSheet else { return }

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
                if !showBasketSheet { showWelcome = true }
                lastInteractionAt = Date()
            }
        }

        .onChange(of: store.lang) { _ in
            if selectedCategory.isEmpty, let first = categoryIds.first {
                selectedCategory = first
            }
        }

        .onAppear {
            showContextPicker = true
            store.loadMock()

            if selectedCategory.isEmpty, let first = categoryIds.first {
                selectedCategory = first
            }

            let v = checkoutIntentRaw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if effectiveIsRtl {
                serviceModeLabel = (v == "ta" || v == "pickup") ? "לקחת" : "לשבת"
            } else {
                serviceModeLabel = (v == "ta" || v == "pickup") ? "Pickup" : "Dine-in"
            }

            if isPad { showWelcome = true }

            if let mid = store.shop?.mini.miniAppId {
                miniAppId = mid
            }
        }

        .environment(\.layoutDirection, effectiveIsRtl ? .rightToLeft : .leftToRight)
        .environment(\.locale, effectiveLocale)
        .environment(\.isRtl, effectiveIsRtl)

        .font(appFont(miniAppId, 16))
        .tint(brand)
        .sheet(isPresented: Binding(
            get: { showBasketSheet && !isPad },
            set: { if !$0 { showBasketSheet = false } }
        )) {
            HugBasketSheet {
                basketPhoneSheet
                    .id(basketLines.count)
            }
        }
       
        .animation(.easeInOut(duration: 0.18), value: showContextPicker)
       
        .fullScreenCover(isPresented: Binding(
            get: { showBasketSheet && isPad },
            set: { if !$0 { showBasketSheet = false } }
        )) { basketPadCover }
        .sheet(item: $sheetItem) { it in
            let existing = localBasket[it.id]

            HugHeightSheet {
                MenuProductSheet(
                    miniAppId: miniAppId,
                    item: it,
                    editingLineId: nil,
                    initialQuantityInBasket: existing?.qty,
                    initialSelectedOptions: existing?.opts ?? [:],
                    initialSelectedAdditions: existing?.adds ?? [],
                    onAdd: { product, qty, subtitle, unitPrice, opts, adds in
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
                            pushMyItem(product.id)   // ✅ persist “My items”
                        }
                        sheetItem = nil
                    },
                    onClose: {
                        sheetItem = nil
                    },
                    mode: isPad ? .padOverlay : .phone,
                    t: store.t
                )
                .environment(\.layoutDirection, effectiveIsRtl ? .rightToLeft : .leftToRight)
                .environment(\.locale, effectiveLocale)
                .environment(\.isRtl, effectiveIsRtl)
            }
        }
        // ✅ Keep your existing product sheet presentation wiring
        // (You can keep your current MenuProductSheet + BasketSheetPrototype here or move them to separate view files later)
    }
}

struct ContextPickerOverlay: View {
    @ObservedObject var store: MockShopStore

    let miniAppId: Int
    let brand: Color
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var scheme

    private var titleText: String {
        guard let ctx = store.context else { return "" }
        return ctx.title?.resolve(lang: store.lang, fallback: store.defaultLang) ?? ""
    }

    private var options: [ShopPayloadV2.Context.Option] {
        store.context?.options ?? []
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack {
                Spacer()

                Text(titleText)
                    .font(appFont(miniAppId, 48).weight(.light))
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 20)

                HStack(spacing: 18) {
                    ForEach(options.prefix(2)) { opt in
                        Button {
                            store.setSelectedContext(opt.id)
                            Haptics.selection()
                            onDismiss()
                        } label: {

                            VStack(spacing: 14) {

                                Text(opt.label.resolve(
                                    lang: store.lang,
                                    fallback: store.defaultLang
                                ))
                                .font(appFont(miniAppId, 20).weight(.semibold))
                                .foregroundColor(.white)
                                .multilineTextAlignment(.center)

                            }
                            .frame(width: 180, height: 70)
                            .background(
                                RoundedRectangle(cornerRadius: 26, style: .continuous)
                                    .fill(Color.black.opacity(0.75))
                            )
                            .shadow(
                                color: .black.opacity(scheme == .dark ? 0.45 : 0.18),
                                radius: 18,
                                y: 10
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                Spacer()
            }
        }
        .environment(\.layoutDirection, store.isRtl ? .rightToLeft : .leftToRight)
        .environment(\.locale, Locale(identifier: store.isRtl ? "he_IL" : "en_GB"))
        .environment(\.isRtl, store.isRtl)
    }

    private func sfSymbol(for icon: String?) -> String? {
        let v = (icon ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if v.isEmpty { return nil }

        switch v {
        case "mappin", "pin", "location":
            return "mappin.and.ellipse"
        case "bag", "takeaway", "pickup":
            return "bag"
        case "chair", "dinein", "sit":
            return "chair.lounge"
        default:
            return v
        }
    }
}

enum MenuProductSheetMode { case padOverlay, phone }

struct MenuProductSheet: View {
    let miniAppId: Int
    let item: ShellMenuItem
    let editingLineId: Int?
    let initialQuantityInBasket: Int?
    let initialSelectedOptions: [String: String]
    let initialSelectedAdditions: Set<String>
    let onAdd: (ShellMenuItem, Int, String?, Double, [String: String], Set<String>) -> Void
    let onClose: () -> Void
    let mode: MenuProductSheetMode
    let t: (String) -> String

    @Environment(\.colorScheme) private var scheme
    @Environment(\.isRtl) private var isRtl
    

    @State private var quantity: Int
    @State private var frozenHero: KFCrossPlatformImage? = nil
    @State private var selectedOptions: [String: String]
    @State private var selectedAdditions: Set<String>

   
    
    private let heroH: CGFloat = 280
    private let barH: CGFloat = 60
    private let sidePad: CGFloat = 14
    private let topPad: CGFloat = 14

    init(
        miniAppId: Int,
        item: ShellMenuItem,
        editingLineId: Int?,
        initialQuantityInBasket: Int?,
        initialSelectedOptions: [String: String],
        initialSelectedAdditions: Set<String> = [],
        onAdd: @escaping (ShellMenuItem, Int, String?, Double, [String: String], Set<String>) -> Void,
        onClose: @escaping () -> Void,
        mode: MenuProductSheetMode = .padOverlay,
        t: @escaping (String) -> String
    ) {
        self.miniAppId = miniAppId
        self.item = item
        self.editingLineId = editingLineId
        self.initialQuantityInBasket = initialQuantityInBasket
        self.initialSelectedOptions = initialSelectedOptions
        self.initialSelectedAdditions = initialSelectedAdditions
        self.onAdd = onAdd
        self.onClose = onClose
        self.mode = mode
        self.t = t

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

    var body: some View {
        Group {
            if mode == .padOverlay { padOverlayBody }
            else { phoneSheetBody }
        }
        .statusBar(hidden: true)
    }

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

    private var phoneSheetBody: some View {
        VStack(spacing: 0) {

            // ✅ hero (same as before, but NOT inside a detent/measure system)
            heroView(padOverlay: false)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.horizontal, sidePad)
                .padding(.top, topPad)

            // ✅ content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerBlock
                    modifiersBlock

                    // space for the bottom bar so it doesn't cover content
                    Color.clear.frame(height: barH + 16)
                }
                .padding(.horizontal, sidePad)
                .padding(.top, 14)
            }

            // ✅ bottom bar pinned
            bottomBar
                .padding(.horizontal, sidePad)
                .padding(.bottom, 10)
                .background(Color(.systemBackground))
        }
    }

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
            .padding(10)
        }
        .frame(height: heroH)
        .frame(maxWidth: .infinity)
        .clipped()
        .padding(.horizontal, padOverlay ? -18 : 0)
        .padding(.top, padOverlay ? -18 : 0)
    }

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
            ModifierListView2(
                groups: groups,
                selectedOptions: $selectedOptions,
                selectedAdditions: $selectedAdditions,
                t: t
            )
            .padding(.top, 6)
        }
    }

    private var unitWithExtras: Double {
        item.price + extraPricePerUnit()
    }

    private var unitPriceLabel: String {
        isRtl ? formatPrice(unitWithExtras) : "£\(formatPrice(unitWithExtras))"
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
                    Text(isRemoveMode ? t("cta.remove") : isUpdateMode ? t("cta.update") : t("cta.add"))
                        .font(appFont(miniAppId, 18).weight(.semibold))
                    Spacer()
                    Text(totalPriceLabel)
                        .font(appFont(miniAppId, 18).weight(.semibold))
                }
                .padding(.horizontal, 20)
                .foregroundColor(.white)
                .frame(height: barH)
                .frame(maxWidth: .infinity)
                .background(isRemoveMode ? .red : adjustedBrand(for: miniAppId))
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

        var parts: [String] = []

        for g in groups where g.type == .options {
            guard let first = g.items.first else { continue }
            let gKey = norm(g.title)
            let selected = norm(selectedOptions[gKey] ?? "")
            let def = norm(first.name)
            if !selected.isEmpty, selected != def { parts.append(selected) }
        }

        for g in groups where g.type == .additions {
            guard let first = g.items.first else { continue }
            let defaultNorm = norm(first.name)
            let groupNormNames = Set(g.items.map { norm($0.name) })

            let pickedInGroup = selectedAdditions
                .map(norm)
                .filter { groupNormNames.contains($0) }

            let nonDefault = pickedInGroup.filter { $0 != defaultNorm }

            if !nonDefault.isEmpty {
                let ordered = g.items
                    .map { norm($0.name) }
                    .filter { nonDefault.contains($0) }
                parts.append(contentsOf: ordered)
            }
        }

        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

private struct ModifierListView2: View {
    let groups: [ModifierGroup]
    @Binding var selectedOptions: [String: String]
    @Binding var selectedAdditions: Set<String>
    let t: (String) -> String

    @Environment(\.isRtl) private var isRtl
    @AppStorage("miniAppId") private var miniAppId: Int = 0

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
            return isRtl ? group.title : t("modifiers.additionsTitle")
        case .options:
            return group.title
        }
    }
}

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

    let t: (String) -> String
    private var brandBg: Color { adjustedBrand(for: miniAppId) }
    private var brandFg: Color { .white }
    @State private var hiddenUpsellIds: Set<Int> = []
    @Environment(\.colorScheme) private var scheme

    fileprivate struct BasketSheetMeasuredHeightKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }

    
    fileprivate struct HugBasketSheet<Content: View>: View {
        let content: Content

        @State private var measuredH: CGFloat = 420
        @State private var selectedDetent: PresentationDetent = .height(420)

        init(@ViewBuilder content: () -> Content) {
            self.content = content()
        }

        var body: some View {
            let screenH = UIScreen.main.bounds.height
            let maxH = screenH * 0.90
            let minH: CGFloat = 320
            let targetH = min(max(measuredH, minH), maxH) + 12

            ZStack {
                content

                content
                    .fixedSize(horizontal: false, vertical: true)
                    .measureBasketSheetHeight { h in
                        let rounded = (h * 10).rounded() / 10
                        if abs(measuredH - rounded) > 1 { measuredH = rounded }
                    }
                    .opacity(0.001)
                    .allowsHitTesting(false)
            }
            .onAppear { selectedDetent = .height(targetH) }
            .onChange(of: measuredH) { _ in selectedDetent = .height(targetH) }
            .presentationDetents([.height(targetH), .large], selection: $selectedDetent)
            .presentationDragIndicator(.visible)
        }
    }
    
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

    private var primaryCtaBg: Color { brandBg }
    private var primaryCtaFg: Color { brandFg }
    var body: some View {
        let isPhone = UIDevice.current.userInterfaceIdiom == .phone
        let isPad = UIDevice.current.userInterfaceIdiom == .pad

        VStack(spacing: 0) {
            headerBar()

            ViewThatFits(in: .vertical) {
                VStack(spacing: 0) {
                    contentStack(isPhone: isPhone)
                    bottomBar(isPhone: isPhone, isPad: isPad)
                }

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
    }

    private func headerBar() -> some View {
        ZStack {
            Text(t("basket.title"))
                .font(appFont(miniAppId, 22).weight(.semibold))
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)

            HStack {
                Button(action: onClear) {
                    Text(t("basket.clear"))
                        .font(appFont(miniAppId, 15).weight(.semibold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color(.systemGray5))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)

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
        .background(Color(.systemBackground))
        .overlay(Divider().opacity(0.25), alignment: .bottom)
    }

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
                    Text(t("basket.upsellTitle"))
                        .font(appFont(miniAppId, 16).weight(.semibold))
                        .padding(.horizontal, 18)

                    if isPhone {
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 12) {
                                ForEach(visibleUpsells.prefix(10)) { it in
                                    UpsellStripCard(
                                        miniAppId: miniAppId,
                                        isRtl: isRtl,
                                        item: it,
                                        onAdd: {
                                            hiddenUpsellIds.insert(it.id)
                                            onAddUpsell(it)
                                            
                                        },
                                        onOpen: { onOpenUpsell(it) },
                                        t: t
                                    )
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 2)
                        }

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
                                    onOpen: { onOpenUpsell(it) },
                                    t: t
                                )
                            }
                        }
                        .frame(maxWidth: 700, alignment: .leading)
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

    private func bottomBar(isPhone: Bool, isPad: Bool) -> some View {
        VStack(spacing: 14) {
            Divider().opacity(scheme == .dark ? 0.18 : 0.35)

            HStack {
                Text(t("basket.total"))
                    .font(appFont(miniAppId, 18).weight(.semibold))
                Spacer()
                Text(priceText(totalPrice))
                    .font(appFont(miniAppId, 18).weight(.semibold))
            }
            .padding(.horizontal, 20)

            if isPhone {
                Button { onContinueToPayment() } label: {
                    Text(t("basket.checkout"))
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
                        Text(t("basket.backToShop"))
                            .font(appFont(miniAppId, 17).weight(.semibold))
                            .foregroundColor(brandFg)
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                            .background(brandBg)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    Button { onContinueToPayment() } label: {
                        Text(t("basket.checkout"))
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
        .background(Color(.systemBackground))
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

    private struct UpsellStripCard: View {
        let miniAppId: Int
        let isRtl: Bool
        let item: ShellMenuItem
        let onAdd: () -> Void
        let onOpen: () -> Void
        let t: (String) -> String

        private let w: CGFloat = 170
        private let imgH: CGFloat = 120

        private var addBg: Color { adjustedBrand(for: miniAppId) }
        private var addFg: Color { .white }
        
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
                        Text(t("cta.add"))
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

    private struct UpsellGridCard: View {
        let miniAppId: Int
        let isRtl: Bool
        let item: ShellMenuItem
        let onAdd: () -> Void
        let onOpen: () -> Void
        let t: (String) -> String

        private var addBg: Color { adjustedBrand(for: miniAppId) }
        private var addFg: Color { .white }
        
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
                        Text(t("cta.add"))
                            .font(appFont(miniAppId, 14).weight(.semibold))
                            .foregroundColor(addFg)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(addBg)
                            .clipShape(Capsule())
                            //.overlay(Capsule().stroke(Color.primary.opacity(miniAppId == 13 ? 0.18 : 0), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
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
            let targetH = min(max(preferredHeight, minH), maxH)
            let cardW = min(720, geo.size.width - 80)

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
