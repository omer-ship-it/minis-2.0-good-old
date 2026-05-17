import SwiftUI
import Kingfisher
import StoreKit
import Combine

private struct ShopCategoryOffsetKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

private struct OverlayMeasuredHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 420
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct IdleOverlayViewShop: View {
    let miniAppId: Int
        let countdown: Int
        let onTap: () -> Void

        private let totalSeconds: Double = 8
        private var progress: Double { max(0, min(1, Double(countdown) / totalSeconds)) }

        var body: some View {
            ZStack {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .ignoresSafeArea()

                VStack(spacing: 28) {
                    Spacer()

                    VStack(spacing: 12) {

                        Text("עדיין כאן?")
                            .font(appFont(miniAppId, 44).weight(.heavy))
                            .foregroundColor(.primary)
                            .multilineTextAlignment(.center)

                        Text("גע במסך כדי להמשיך")
                            .font(appFont(miniAppId, 20).weight(.semibold))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    ZStack {

                        Circle()
                            .stroke(Color.primary.opacity(0.15), lineWidth: 10)
                            .frame(width: 160, height: 160)

                        Circle()
                            .trim(from: 0, to: progress)
                            .stroke(Color.primary, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                            .frame(width: 160, height: 160)
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 1.0), value: progress)

                        Text("\(countdown)")
                            .font(appFont(miniAppId, 52).weight(.heavy))
                            .foregroundColor(.primary)
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

struct WelcomeOverlayViewShop: View {
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

private extension View {
    func measureOverlayHeight(_ onChange: @escaping (CGFloat) -> Void) -> some View {
        background(
            GeometryReader { geo in
                Color.clear.preference(key: OverlayMeasuredHeightKey.self, value: geo.size.height)
            }
        )
        .onPreferenceChange(OverlayMeasuredHeightKey.self, perform: onChange)
    }
}

private struct ProductOverlayCard<Content: View>: View {
    let onDismiss: () -> Void
    let content: Content

    @State private var measuredH: CGFloat = 520

    init(onDismiss: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.onDismiss = onDismiss
        self.content = content()
    }

    var body: some View {
        GeometryReader { geo in
            let maxH = geo.size.height * 0.88
            let minH: CGFloat = 320
            let targetH = min(max(measuredH, minH), maxH)
            let cardW = min(550, geo.size.width - 80)

            ZStack {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .ignoresSafeArea()

                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture { onDismiss() }

                content
                    .frame(width: cardW, height: targetH)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 26, y: 16)
                    .scaleEffect(1)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
                    .animation(.spring(response: 0.35, dampingFraction: 0.85), value: measuredH)
                    .onTapGesture { }

                content
                    .fixedSize(horizontal: false, vertical: true)
                    .background(.ultraThinMaterial)
                    .frame(width: cardW)
                    .measureOverlayHeight { h in
                        let rounded = (h * 10).rounded() / 10
                        if abs(measuredH - rounded) > 1 { measuredH = rounded }
                    }
                    .opacity(0.001)
                    .allowsHitTesting(false)
            }
        }
        .zIndex(9999)
        .transition(.opacity)
       
    }
}

private struct ShopTopSentinelKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}



struct LocationPickerSheet: View {
    let options: [String]
    @Binding var selected: String
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Text("Location").font(.system(size: 18, weight: .semibold))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.primary)
                        .frame(width: 34, height: 34)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider().opacity(0.35)

            VStack(spacing: 10) {
                ForEach(options, id: \.self) { opt in
                    Button {
                        selected = opt
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        onClose()
                    } label: {
                        HStack {
                            Text(opt)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.primary)
                            Spacer()
                            if opt == selected {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundColor(.primary)
                            }
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 52)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)

            Spacer(minLength: 0)
        }
        .presentationDetents([.height(320)])
        .presentationDragIndicator(.visible)
    }
}



struct ShopMyItemsRow: View {
    let items: [ShopMyItem]
    let currencyPrefix: String
    let onTap: (ShopMyItem) -> Void

    private let imgSize: CGFloat = 54
    private let corner: CGFloat = 14
    private let minCardW: CGFloat = 160
    private let maxCardW: CGFloat = 260

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Favourites")
                    .font(.system(size: 18, weight: .semibold))
                    .padding(.horizontal, 16)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(items) { it in
                            Button {
                                onTap(it)
                            } label: {
                                HStack(spacing: 10) {
                                    KFImage(it.imageURL)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: imgSize, height: imgSize)
                                        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(it.name)
                                            .font(.system(size: 15, weight: .semibold))
                                            .lineLimit(2)
                                            .fixedSize(horizontal: false, vertical: true)

                                        Text("\(currencyPrefix)\(shopFormatPrice(it.price))")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                    .layoutPriority(1)

                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .frame(minWidth: minCardW, maxWidth: maxCardW, alignment: .leading)
                                .background(Color(.secondarySystemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            .padding(.top, 12)
        }
    }
}

struct ShopCategoryBar: View {
    let categories: [String]
    let selected: String
    let onTap: (String) -> Void

    @Environment(\.colorScheme) private var scheme
    @Namespace private var underlineNS

    private var textIdle: Color { scheme == .dark ? .primary.opacity(0.70) : .primary.opacity(0.72) }
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
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundColor(cat == selected ? .primary : textIdle)
                                        .padding(.horizontal, 2)
                                        .padding(.vertical, 2)

                                    ZStack {
                                        if cat == selected {
                                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                                .fill(underline)
                                                .matchedGeometryEffect(id: "u", in: underlineNS)
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
                .onChange(of: selected) { new in
                    guard !new.isEmpty else { return }
                    withAnimation(.easeInOut(duration: 0.22)) { proxy.scrollTo(new, anchor: .center) }
                }
            }
            Rectangle()
                .fill(Color.primary.opacity(scheme == .dark ? 0.12 : 0.10))
                .frame(height: 1)
        }
        .background(Color(.systemBackground))
    }
}

struct ShopCategoryRail: View {
    let categories: [String]
    let selected: String
    let onTap: (String) -> Void
    let logoURL: URL   // ✅ pass from ShopView

    @Environment(\.colorScheme) private var scheme
    @Namespace private var ns

    private var pill: Color { scheme == .dark ? .white : .black }
    private var textSelected: Color { scheme == .dark ? .black : .white }
    private var textIdle: Color { scheme == .dark ? .primary.opacity(0.78) : .primary.opacity(0.82) }

    var body: some View {
        VStack(spacing: 0) {

            // ✅ centered logo at top
            KFImage(logoURL)
                .resizable()
                .scaledToFill()
                .frame(width: 110, height: 110)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 1))
                .shadow(color: .black.opacity(0.10), radius: 6, y: 3)
                .padding(.top, 14)
                .padding(.bottom, 10)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 10) {
                    ForEach(categories, id: \.self) { cat in
                        ZStack(alignment: .leading) {
                            if cat == selected {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(pill)
                                    .matchedGeometryEffect(id: "pill", in: ns)
                            }

                            HStack {
                                Text(cat)
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundColor(cat == selected ? textSelected : textIdle)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 14)
                            .padding(.horizontal, 14)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { onTap(cat) }
                    }
                }
                .padding(10)
                .padding(.top, 4)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(.systemBackground))
        .zIndex(10)
    }
}


struct ShopProductCard: View {
    let p: ShopProduct
    let selectedLang: String
    private let r: CGFloat = 18

    var body: some View {
        VStack(spacing: 0) {
            KFImage(p.imageURL)
                .resizable()
                .scaledToFill()
                .frame(height: 160)
                .frame(maxWidth: .infinity)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: r, style: .continuous))

            VStack(alignment: .leading, spacing: 0) {
                Text(p.localizedName(lang: selectedLang))
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(2)

                Text("£\(shopFormatPrice(p.price))")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 5)
            .padding(.vertical, 8)
        }
    }
}



struct ShopHighlightCardTall: View {
    let h: ShopHighlight
    private let w: CGFloat = 160
    private let imgH: CGFloat = 220

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            KFImage(h.imageURL)
                .resizable()
                .scaledToFill()
                .frame(width: w, height: imgH)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

            Text(h.name)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(2)
                .frame(width: w, alignment: .leading)

            Text("£\(shopFormatPrice(h.price))")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: w, alignment: .leading)
        }
        .frame(width: w, alignment: .leading)
    }
}
private struct SheetMeasuredHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private extension View {
    func measureSheetHeight(_ onChange: @escaping (CGFloat) -> Void) -> some View {
        background(
            GeometryReader { geo in
                Color.clear.preference(key: SheetMeasuredHeightKey.self, value: geo.size.height)
            }
        )
        .onPreferenceChange(SheetMeasuredHeightKey.self, perform: onChange)
    }
}

private struct HugHeightSheet<Content: View>: View {
    let content: Content
    @State private var measuredH: CGFloat = 260
    @State private var selectedDetent: PresentationDetent = .height(260)

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        let screenH = UIScreen.main.bounds.height
        let maxH = screenH * 0.88
        let minH: CGFloat = 220
        let targetH = min(max(measuredH, minH), maxH) + 10

        ZStack {
            content

            content
                .fixedSize(horizontal: false, vertical: true)
                .measureSheetHeight { h in
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

struct OrderConfirmationPayload: Identifiable, Equatable {
    let id = UUID()
    let orderId: String
    let receiptURL: URL?
    let paidTotal: Double
    let tipTotal: Double
    let lines: [BasketLineShop]
    let createdAt: Date
    let contextLabel: String
}
struct ShopView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var vm = ShopVM2()
    @State private var showQRShareSheet = false
    @State private var showInitialContextPicker: Bool = false
    @StateObject private var shopModel = ShopDataModel()
    private let shopName = "Beigel Bake"
    private let logoURL = URL(string: "https://beithaam.com/wp-content/uploads/2024/12/share.jpg")!
    private var shareURL: URL {
        URL(string: "https://minis.studio/shop/\(miniAppId)")!
    }
    @State private var showAppStoreOverlay = false
    private let appStoreAppId = "1234567890"
    private func localizedContextLabel(_ raw: String) -> String {
        switch raw {
        case "Humanities":
            return vm.selectedLang == "he" ? "מדעי הרוח" : "Humanities"
        case "Science Building":
            return vm.selectedLang == "he" ? "מדעי החברה" : "Science Building"
        default:
            return raw
        }
    }

    private func contextLabel(from pickupLocation: String) -> String {
        switch pickupLocation {
        case "humanities":
            return "Humanities"
        case "social":
            return "Science Building"
        default:
            return pickupLocation
        }
    }

    private func persistSelectedContext(_ value: String) {
        guard miniAppId == 13 else { return }
        guard let pickup = canonicalPickupLocation(value) else { return }

        let defaults = UserDefaults.standard
        defaults.set(pickup, forKey: "pickup.location.v2")
        defaults.set(pickup, forKey: "pickup.location")
    }
    
    @State private var showNavTitle = false
    @State private var manualScroll = false
    @State private var syncResumeAt: Date = .distantPast
    @State private var miniAppId: Int = 13
    @State private var reopenBasketAfterSheet = false
    @State private var pushConfirmation = false
    @State private var showOrderFlowFullScreen = false
    @State private var diningMode: DiningMode = .dineIn
    @State private var showWelcome: Bool = false
    @State private var showIdle: Bool = false
    @State private var lastInteractionAt: Date = Date()
    @State private var idleCountdown: Int = 8
    @State private var showMemberCard = false
    @State private var showBasketSheet = false
    @State private var sheetItem: ShellMenuItem? = nil
    @State private var confirmation: OrderConfirmationPayload? = nil
    @State private var pendingCheckoutLines: [BasketLineShop] = []
    @State private var pendingCheckoutTotal: Double = 0
    @State private var pendingCheckoutCreatedAt: Date = .distantPast
    private let idleStartAfter: TimeInterval = 20
    private let idleTick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    
    struct ShopConfirmationView: View {
        var body: some View {
            VStack {
                Text("Confirmation")
                    .font(.system(size: 24, weight: .semibold))
                Spacer()
            }
            .padding(20)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
    
    private func registerInteraction() {
        lastInteractionAt = Date()

        if showIdle {
            showIdle = false
            idleCountdown = 8
        }
    }
    
    struct InitialContextOverlayShop: View {
        let miniAppId: Int
        @Binding var selectedLang: String
        let onSelectLocation: (String) -> Void

        private var titleText: String {
            switch selectedLang {
            case "he": return "בחר מיקום"
            default:   return "Choose location"
            }
        }

        private var humanitiesText: String {
            switch selectedLang {
            case "he": return "מדעי הרוח"
            default:   return "Humanities"
            }
        }

        private var scienceText: String {
            switch selectedLang {
            case "he": return "מדעי החברה"
            default:   return "Science Building"
            }
        }

        var body: some View {
            ZStack {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .ignoresSafeArea()

                VStack(spacing: 22) {
                    Spacer()

                    VStack(spacing: 14) {
                        Text(titleText)
                            .font(appFont(miniAppId, 32).weight(.heavy))
                            .foregroundColor(.primary)
                            .multilineTextAlignment(.center)

                        Picker("", selection: $selectedLang) {
                            Text("EN").tag("en")
                            Text("עב").tag("he")
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 160)
                    }

                    HStack(spacing: 12) {
                        Button {
                            onSelectLocation("Humanities")
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        } label: {
                            Text(humanitiesText)
                                .font(appFont(miniAppId, 18).weight(.semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 56)
                                .background(adjustedBrand(for: miniAppId))
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .buttonStyle(.plain)

                        Button {
                            onSelectLocation("Science Building")
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        } label: {
                            Text(scienceText)
                                .font(appFont(miniAppId, 18).weight(.semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 56)
                                .background(adjustedBrand(for: miniAppId))
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 20)

                    Spacer()
                }
            }
            .interactiveDismissDisabled(true)
        }
    }
    
    @ViewBuilder private var basketOverlayForPad: some View {
        if isPad && showBasketSheet {
            BasketOverlayCard(maxWidth: 500, onDismiss: { showBasketSheet = false }) {
                BasketSheetShop(
                    miniAppId: miniAppId,
                    isRtl: false,
                    lines: basketLinesShop,

                    onClose: { showBasketSheet = false },
                    onClear: { basket.removeAll(); showBasketSheet = false },

                    onIncrement: { id in basket[id, default: 0] += 1 },
                    onDecrement: { id in
                        let q = basket[id, default: 0] - 1
                        if q <= 0 { basket[id] = nil } else { basket[id] = q }
                        if basket.isEmpty { showBasketSheet = false }
                    },

                    onLineTap: { row in
                        reopenBasketAfterSheet = true
                        showBasketSheet = false

                        if let p = shopModel.product(by: row.id) {
                            sheetItem = toShell(p); return
                        }
                        if let h = highlights.first(where: { highlightShellId($0) == row.id }) {
                            let isFirst = (h.id == highlights.first?.id)
                            sheetItem = ShellMenuItem(
                                id: highlightShellId(h),
                                name: h.name,
                                price: h.price,
                                category: "Highlights",
                                modifiers: isFirst ? demoHighlightModifiers : nil,
                                imageURL: h.imageURL.absoluteString,
                                description: isFirst ? "Demo modifiers (only on first highlight)" : nil
                            )
                            return
                        }
                        if let u = upsells.first(where: { $0.id == row.id }) {
                            sheetItem = u; return
                        }
                    },
                    upsells: upsells,
                    onAddUpsell: { it in basket[it.id, default: 0] += 1 },
                    onOpenUpsell: { it in
                        reopenBasketAfterSheet = true
                        showBasketSheet = false
                        sheetItem = it
                    },

                    onBackToShop: { showBasketSheet = false },
                    onContinueToPayment: {
                        basket.removeAll()
                        showBasketSheet = false

                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            showOrderFlowFullScreen = true
                        }
                    },

                    t: { $0 }
                )
            }
            .zIndex(10000)
        }
    }
    @ViewBuilder private var productOverlayForPad: some View {
        if isPad, let it = sheetItem {
            ProductOverlayCard(onDismiss: { sheetItem = nil }) {
                ShopProductSheet(
                    miniAppId: miniAppId,
                    item: it,
                    editingLineId: nil,
                    initialQuantityInBasket: basket[it.id],
                    initialSelectedOptions: [:],
                    initialSelectedAdditions: [],
                    mode: isPad ? .padOverlay : .phone,
                    t: { $0 },
                    onAdd: { product, qty, _, _, _, _ in
                        addToBasket(product.id, qty: qty)

                        let shouldReopen = reopenBasketAfterSheet
                        reopenBasketAfterSheet = false
                        sheetItem = nil

                        if shouldReopen {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    showBasketSheet = true
                                }
                            }
                        }
                    },
                    onClose: {
                        let shouldReopen = reopenBasketAfterSheet
                        reopenBasketAfterSheet = false
                        sheetItem = nil

                        if shouldReopen {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    showBasketSheet = true
                                }
                            }
                        }
                    }
                )
            }
        }
    }
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    private var categories: [String] { shopModel.categories }
    private var locationOptions: [String] { ["Humanities", "Science Building"] }
    
    private var demoHighlightModifiers: [ModifierGroup] {
        [
            ModifierGroup(
                type: .options,
                title: "Size",
                items: [
                    ModifierItem(name: "Regular", extraPrice: 0),
                    ModifierItem(name: "Large",   extraPrice: 2.5)
                ]
            ),
            ModifierGroup(
                type: .additions,
                title: "Extras",
                items: [
                    ModifierItem(name: "No extras", extraPrice: 0),
                    ModifierItem(name: "Cheese",    extraPrice: 1.5),
                    ModifierItem(name: "Avocado",   extraPrice: 3.0),
                    ModifierItem(name: "Chilli",    extraPrice: 0.5)
                ]
            )
        ]
    }
    
    private var productById: [Int: (name: String, price: Double, imageURL: String?)] {
        var dict: [Int: (name: String, price: Double, imageURL: String?)] = [:]

        for p in shopModel.products {
            dict[p.id] = (p.name, p.price, p.imageURL.absoluteString)
        }

        for u in upsells {
            dict[u.id] = (u.name, u.price, u.imageURL)
        }

        for h in highlights {
            dict[highlightShellId(h)] = (h.name, h.price, h.imageURL.absoluteString)
        }

        return dict
    }
    
    private var upsells: [ShellMenuItem] {
        [
            ShellMenuItem(
                id: 9001,
                name: "Butter croissant",
                price: 9.0,
                category: "",
                modifiers: nil,
                imageURL: "https://picsum.photos/seed/upsell-1/800/800",
                description: nil
            ),
            ShellMenuItem(
                id: 9002,
                name: "Orange juice",
                price: 12.0,
                category: "",
                modifiers: nil,
                imageURL: "https://picsum.photos/seed/upsell-2/800/800",
                description: nil
            ),
            ShellMenuItem(
                id: 9003,
                name: "Chocolate cookie",
                price: 7.0,
                category: "",
                modifiers: nil,
                imageURL: "https://picsum.photos/seed/upsell-3/800/800",
                description: nil
            )
        ]
    }
    
    private func toShell(_ it: ShopMyItem) -> ShellMenuItem {
        ShellMenuItem(
            id: it.id,
            name: it.name,
            price: it.price,
            category: "Favourites",
            modifiers: nil,
            imageURL: it.imageURL.absoluteString,
            description: nil
        )
    }
    
    private func toShell(_ p: ShopProduct) -> ShellMenuItem {
        ShellMenuItem(
            id: p.id,
            name: p.localizedName(lang: vm.selectedLang),
            price: p.price,
            category: p.category,
            modifiers: nil,
            imageURL: p.imageURL.absoluteString,
            description: nil
        )
    }
    
    private func languageLabel(_ code: String) -> String {
        switch code {
        case "he": return "עב"
        case "ar": return "AR"
        default: return "EN"
        }
    }

    private var myItems: [ShopMyItem] {
        let names = ["Latte", "Burekas", "Krafin", "Focaccia", "Egg Brioche", "Cookie", "Salad", "Soup"]
        let prices: [Double] = [9, 12, 18, 16, 22, 7, 24, 14]
        return (1...12).map { i in
            ShopMyItem(
                id: i,
                name: names[(i - 1) % names.count] + (i % 3 == 0 ? " Extra long name test" : ""),
                price: prices[(i - 1) % prices.count],
                imageURL: URL(string: "https://picsum.photos/seed/shop-myitem-\(i)/300/300")!
            )
        }
    }

    private var highlights: [ShopHighlight] {
        let names = ["Soup of the day", "New bagel special", "Pistachio krafin", "Chocolate cookie", "Orange juice"]
        let prices: [Double] = [18, 24, 22, 7, 12]
        return (1...10).map { i in
            ShopHighlight(
                id: i,
                name: names[(i - 1) % names.count],
                price: prices[(i - 1) % prices.count],
                imageURL: URL(string: "https://picsum.photos/seed/highlight-\(i)/900/1200")!
            )
        }
    }
    
    @State private var basket: [Int: Int] = [:] // productId -> qty
  
    private var basketQty: Int { basket.values.reduce(0, +) }
    private var basketLinesShop: [BasketLineShop] {
        basket
            .sorted(by: { $0.key < $1.key })
            .compactMap { (id, qty) in
                guard let p = productById[id], qty > 0 else { return nil }
                return BasketLineShop(
                    id: id,
                    name: p.name,
                    imageURL: p.imageURL,
                    qty: qty,
                    unitPrice: p.price,
                    subtitle: nil,
                    opts: [:],
                    adds: []
                )
            }
    }
    
    private var basketTotal: Double {
        basket.reduce(0) { sum, kv in
            let id = kv.key
            let qty = kv.value
            let price = productById[id]?.price ?? 0
            return sum + (Double(qty) * price)
        }
    }
    private func addToBasket(_ productId: Int, qty: Int) {
        if qty <= 0 { basket[productId] = nil }
        else { basket[productId] = qty }
    }
   
    private var products: [ShopProduct] { shopModel.products }

    private var phoneCols: [GridItem] { [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)] }
    private var padCols: [GridItem] { Array(repeating: GridItem(.flexible(), spacing: 12), count: 3) }

    var body: some View {
        ZStack {
            if isPad { padBody } else { phoneBody }
        }
        .fullScreenCover(isPresented: $showOrderFlowFullScreen) {

            let checkoutTotal = pendingCheckoutTotal > 0 ? pendingCheckoutTotal : basketTotal

            OrderFlowView(
                onSendToKitchen: {
                    // placeholder
                },
                total: checkoutTotal,
                isRtl: false,
                diningMode: $diningMode,
                requiresPhoneStep: false,
                onCancel: {
                    showOrderFlowFullScreen = false
                },
                onCompleted: { orderId, receiptUrl, paymentSummary, paidTotal, tipTotal, existingOrderId in
                    // placeholder
                    showOrderFlowFullScreen = false
                },
                onFinish: {
                    showOrderFlowFullScreen = false
                },
                allowPayLater: false,
                skipServiceStep: true,
                onServiceChosen: {
                    // placeholder
                },
                startAtCharge: true
            )
        }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { registerInteraction() })
        .simultaneousGesture(DragGesture(minimumDistance: 12).onEnded { _ in registerInteraction() })
        .overlay {
            if !isPad && showInitialContextPicker {
                InitialContextOverlayShop(
                    miniAppId: miniAppId,
                    selectedLang: $vm.selectedLang
                ) { selected in
                    vm.selectedContext = selected
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showInitialContextPicker = false
                    }
                }
                .zIndex(40000)
                .transition(.opacity)
            }
        }
        .overlay {
            if let payload = confirmation {
                ZStack(alignment: .topTrailing) {
                    ConfirmationOverlayCard(
                        miniAppId: miniAppId,
                        payload: payload,
                        onDone: { withAnimation(.easeInOut(duration: 0.18)) { confirmation = nil } },
                        onTapOutside: { withAnimation(.easeInOut(duration: 0.18)) { confirmation = nil } }
                    )
                    .transition(.opacity)

                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            confirmation = nil
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 20, weight: .regular))
                            .foregroundColor(.primary)
                            .frame(width: 36, height: 36)
                            .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                    }
                    .padding(.top, 20)
                    .padding(.trailing, 20)
                    .zIndex(30001)
                }
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.9), value: confirmation != nil)
        .overlay {
            if isPad && showIdle && !showBasketSheet && sheetItem == nil && !showOrderFlowFullScreen {
                IdleOverlayViewShop(miniAppId: miniAppId, countdown: idleCountdown) {
                    registerInteraction()
                }
                .zIndex(9998)
                .transition(.opacity)
            }
        }
        .overlay {
            if isPad && showWelcome && !showBasketSheet && sheetItem == nil && !showOrderFlowFullScreen {
                WelcomeOverlayViewShop(
                    miniAppId: miniAppId,
                    t: { key in
                        if key == "menu.welcomeTitle" { return "Welcome" }
                        if key == "menu.welcomeSubtitle" { return "Tap anywhere to start ordering" }
                        return key
                    },
                    onDismiss: {
                        withAnimation(.easeOut(duration: 0.25)) { showWelcome = false }
                    }
                )
                .transition(.opacity)
                .zIndex(9999)
            }
        }
        .overlay(alignment: .bottom) {
            if basketQty > 0 {
                GeometryReader { geo in
                    let railW: CGFloat = isPad ? 220 : 0
                    let sidePad: CGFloat = 16
                    let barH: CGFloat = 60

                    VStack(spacing: 0) {
                        Spacer()

                        HStack(spacing: 0) {
                            if isPad { Color.clear.frame(width: railW) }

                            Button {
                                showBasketSheet = true
                            } label: {
                                HStack(spacing: 12) {
                                    Text("\(basketQty)")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundColor(adjustedBrand(for: miniAppId))
                                        .frame(width: 28, height: 28)
                                        .background(Color.white)
                                        .clipShape(Circle())

                                    Text("View order")
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundColor(.white)

                                    Spacer()

                                    Text("£\(shopFormatPrice(basketTotal))")
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundColor(.white)
                                }
                                .padding(.horizontal, 18)
                                .frame(height: barH)
                                .frame(maxWidth: .infinity)
                                .background(adjustedBrand(for: miniAppId))
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, sidePad)
                        }
                        .frame(width: geo.size.width, height: barH, alignment: .bottom)
                        .padding(.bottom, isPad ? 10 : 0)
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.9), value: basketQty)
        .overlay {
            productOverlayForPad
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: sheetItem != nil)
        }
        .overlay {
            basketOverlayForPad
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: sheetItem != nil)
        }
       
        .onChange(of: shopModel.categories) { newCategories in
            guard !newCategories.isEmpty else { return }
            if !newCategories.contains(vm.selectedCategory) {
                vm.selectedCategory = newCategories.first ?? ""
            }
        }
    }
    
    struct MemberCardSheet: View {
        @Environment(\.dismiss) private var dismiss
        @Environment(\.colorScheme) private var scheme

        private let textColor = Color(hex: "#324E57") ?? .primary
        private let bgColor   = Color(.systemBackground)

        private var stamps: Int {
            let profile = UserDefaults.standard.dictionary(forKey: "memberProfileLocal") ?? [:]
            let raw = profile["stamps"] as? Int ?? 0
            return max(0, min(10, raw))
        }

        var body: some View {
            ZStack {
                Color.clear.ignoresSafeArea()

                VStack(spacing: 22) {

                    Spacer().frame(height: 44)

                    Text("כרטיסייה")
                        .font(.primariesDemi(26))
                        .foregroundColor(.primary)

                    VStack(spacing: 14) {

                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 5),
                            spacing: 14
                        ) {
                            ForEach(0..<10, id: \.self) { i in
                                let isEarned = i < stamps
                                let isRewardSlot = (i == 9)

                                let emptyTint: Color = (scheme == .dark)
                                    ? Color.white.opacity(0.55)
                                    : textColor.opacity(0.55)

                                Image(systemName: {
                                    if isRewardSlot {
                                        return isEarned ? "gift.fill" : "gift"
                                    } else {
                                        return isEarned ? "cup.and.saucer.fill" : "cup.and.saucer"
                                    }
                                }())
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundColor(isEarned ? .primary : emptyTint)
                            }
                        }

                        Text("\(stamps)/10")
                            .font(.primariesDemi(16))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 18)

                    Spacer()
                }

                VStack {
                    HStack {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.primary)
                                .frame(width: 34, height: 34)
                                .background(.ultraThinMaterial)
                                .clipShape(Circle())
                        }

                        Spacer()
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 45)

                    Spacer()
                }
            }
            .environment(\.layoutDirection, .rightToLeft)
            .environment(\.locale, Locale(identifier: "he_IL"))
        }
    }
    private var padBody: some View {
        ScrollViewReader { proxy in
            HStack(spacing: 0) {
                ShopCategoryRail(
                    categories: categories,
                    selected: vm.selectedCategory,
                    onTap: { cat in
                        manualScroll = true
                        syncResumeAt = Date().addingTimeInterval(0.9)
                        withAnimation(.easeInOut(duration: 0.25)) { vm.selectedCategory = cat }
                        DispatchQueue.main.async {
                            withAnimation(.easeInOut(duration: 0.55)) { proxy.scrollTo(cat, anchor: .top) }
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { manualScroll = false }
                    },
                    logoURL: logoURL
                )
                .frame(width: 220)

                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        Color.clear.frame(height: 1).id("top")

                        ForEach(categories, id: \.self) { cat in
                            VStack(alignment: .leading, spacing: 12) {
                                Color.clear.frame(height: 20)

                                Text(cat)
                                    .font(.system(size: 22, weight: .semibold))
                                    .padding(.horizontal, 16)
                                    .background(
                                        GeometryReader { geo in
                                            Color.clear.preference(
                                                key: ShopCategoryOffsetKey.self,
                                                value: [cat: geo.frame(in: .named("padScroll")).minY]
                                            )
                                        }
                                    )

                                if cat == "Highlights" {
                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(spacing: 12) {
                                            ForEach(highlights) { h in
                                                Button {
                                                    let isFirstHighlight = (h.id == highlights.first?.id)

                                                    let sid = highlightShellId(h)
                                                 
                                                    sheetItem = ShellMenuItem(
                                                        id: sid,
                                                        name: h.name,
                                                        price: h.price,
                                                        category: "Highlights",
                                                        modifiers: isFirstHighlight ? demoHighlightModifiers : nil,
                                                        imageURL: h.imageURL.absoluteString,
                                                        description: isFirstHighlight ? "Demo modifiers (only on first highlight)" : nil
                                                    )
                                                } label: {
                                                    ShopHighlightCardTall(h: h)
                                                }
                                                .buttonStyle(.plain)
                                            }
                                        }
                                        .padding(.horizontal, 16)
                                        .padding(.bottom, 4)
                                    }
                                } else {
                                    LazyVGrid(columns: padCols, spacing: 12) {
                                        ForEach(shopModel.products(in: cat)) { p in
                                            Button {
                                                sheetItem = toShell(p)
                                            } label: {
                                                ShopProductCard(p: p, selectedLang: vm.selectedLang)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.bottom, 18)
                                }
                            }
                            .id(cat)
                        }

                        Color.clear.frame(height: 80)
                    }
                }
                .coordinateSpace(name: "padScroll")
                .onPreferenceChange(ShopCategoryOffsetKey.self) { offsets in
                    guard Date() >= syncResumeAt, !manualScroll, !offsets.isEmpty else { return }
                    let threshold: CGFloat = 20 + 8 + 100
                    let sorted = offsets.sorted { $0.value < $1.value }
                    guard let match = (sorted.last(where: { $0.value <= threshold }) ?? sorted.first)?.key else { return }
                    if match != vm.selectedCategory {
                        withAnimation(.easeInOut(duration: 0.15)) { vm.selectedCategory = match }
                    }
                }
            }
            .background(Color(.systemBackground).ignoresSafeArea())
            .onAppear {
                lastInteractionAt = Date()
                showWelcome = isPad
                if !categories.contains(vm.selectedCategory) {
                    vm.selectedCategory = categories.first ?? ""
                }
            }
            .onReceive(idleTick) { _ in
                guard isPad else { return }

                // do not interrupt active flows
                if showBasketSheet || sheetItem != nil || showOrderFlowFullScreen { return }

                let idleFor = Date().timeIntervalSince(lastInteractionAt)

                if !showIdle {
                    // if welcome is already showing, we don’t need idle
                    if showWelcome { return }

                    if idleFor >= idleStartAfter {
                        showIdle = true
                        idleCountdown = 8
                    }
                    return
                }

                // we are in idle overlay countdown
                if idleCountdown > 0 {
                    idleCountdown -= 1
                } else {
                    showIdle = false
                    idleCountdown = 8

                    // show welcome (like old code)
                    withAnimation(.easeOut(duration: 0.25)) { showWelcome = true }
                    lastInteractionAt = Date()
                }
            }
        }
        .statusBar(hidden: isPad)
    }

    struct ScrollYProbe: UIViewRepresentable {
        var onChange: (CGFloat) -> Void

        func makeUIView(context: Context) -> ProbeView {
            let v = ProbeView()
            v.onChange = onChange
            return v
        }

        func updateUIView(_ uiView: ProbeView, context: Context) {
            uiView.onChange = onChange
            uiView.attachIfNeeded()
        }

        final class ProbeView: UIView {
            var onChange: ((CGFloat) -> Void)?
            private weak var scrollView: UIScrollView?
            private var obs: NSKeyValueObservation?
            private var didAttach = false

            override func didMoveToWindow() {
                super.didMoveToWindow()
                attachIfNeeded()
            }

            func attachIfNeeded() {
                guard !didAttach else { return }
                DispatchQueue.main.async { [weak self] in
                    self?.attachNow()
                }
            }

            private func attachNow() {
                guard !didAttach else { return }

                if let sv = findScrollViewUpwards(from: self) {
                    didAttach = true
                    scrollView = sv

                    onChange?(sv.contentOffset.y)

                    obs = sv.observe(\.contentOffset, options: [.new]) { [weak self] scrollView, _ in
                        self?.onChange?(scrollView.contentOffset.y)
                    }
                } else {
                    // try again (sometimes hierarchy is late)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                        self?.attachNow()
                    }
                }
            }

            private func findScrollViewUpwards(from view: UIView) -> UIScrollView? {
                var v: UIView? = view
                while let cur = v {
                    if let sv = cur as? UIScrollView { return sv }
                    v = cur.superview
                }
                return nil
            }

            deinit { obs?.invalidate() }
        }
    }
    @State private var debugScrollY: CGFloat = 0

    private var phoneBody: some View {
        
        NavigationStack {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                ZStack {
                    // ✅ Center title layer
                    Text(shopName)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .opacity(showNavTitle ? 1 : 0)
                        .animation(.easeInOut(duration: 0.18), value: showNavTitle)

                    // Buttons layer (always visible)
                    HStack {
                        Button {
                            #if APPCLIP
                            showAppStoreOverlay = true
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            #else
                            dismiss()
                            #endif
                        } label: {
                            Image(systemName: {
                                #if APPCLIP
                                return "arrow.down.app"   // download icon
                                #else
                                return "chevron.left"     // normal back
                                #endif
                            }())
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(.primary)
                            .frame(width: 34, height: 34)
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        HStack(spacing: 22) {
                            Button {
                                showQRShareSheet = true
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            } label: {
                                Image(systemName: "arrowshape.turn.up.forward")
                                    .font(.system(size: 24, weight: .semibold))
                                    .foregroundColor(.primary)
                            }
                            .buttonStyle(.plain)

                            Button { showMemberCard = true } label: {
                                Image(systemName: "cup.and.saucer")
                                    .font(.system(size: 24, weight: .semibold))
                                    .foregroundColor(.primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 0)
                .padding(.vertical, 10)
                .background(Color(.systemBackground))
                .appStoreOverlay(isPresented: $showAppStoreOverlay) {
                    SKOverlay.AppConfiguration(appIdentifier: appStoreAppId, position: .bottom)
                }
                .overlay(Rectangle().fill(Color.primary.opacity(0.10)).frame(height: 1), alignment: .bottom)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(.systemBackground))
                .overlay(Rectangle().fill(Color.primary.opacity(0.10)).frame(height: 1), alignment: .bottom)
                
                ScrollView {
                    ScrollYProbe { y in
                        debugScrollY = y
                    
                        let shouldShow = y > 70

                        if shouldShow != showNavTitle {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                showNavTitle = shouldShow
                            }
                        }
                    }
                    .frame(height: 0)
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                     
                        
                        VStack(spacing: 14) {
                            KFImage(logoURL)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 130, height: 130)
                                .clipShape(Circle())
                                .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 1))
                                .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
                                .padding(.top, 14)
                            
                            Color.clear.frame(height: 18)
                            
                            HStack(spacing: 10) {
                                Button {
                                    vm.showLocationSheet = true
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                } label: {
                                    ZStack {
                                        Text(localizedContextLabel(vm.selectedContext))
                                            .font(.system(size: 16, weight: .semibold))
                                            .frame(maxWidth: .infinity)
                                        HStack {
                                            Spacer()
                                            Image(systemName: "chevron.down")
                                                .font(.system(size: 12, weight: .bold))
                                                .opacity(0.5)
                                                .padding(.trailing, 14)
                                        }
                                    }
                                    .frame(height: 44)
                                    .background(Color(.secondarySystemBackground))
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                                .buttonStyle(.plain)
                                
                                Menu {
                                    Button("EN") { vm.selectedLang = "en" }
                                    Button("עב") { vm.selectedLang = "he" }
                                    Button("AR") { vm.selectedLang = "ar" }
                                } label: {
                                    ZStack {
                                        Text(languageLabel(vm.selectedLang))
                                            .font(.system(size: 15, weight: .semibold))
                                            .frame(maxWidth: .infinity)
                                        HStack {
                                            Spacer()
                                            Image(systemName: "chevron.down")
                                                .font(.system(size: 11, weight: .bold))
                                                .opacity(0.5)
                                                .padding(.trailing, 10)
                                        }
                                    }
                                    .frame(width: 100, height: 44)
                                    .background(Color(.secondarySystemBackground))
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                        .frame(maxWidth: .infinity)
                        
                        ShopMyItemsRow(items: myItems, currencyPrefix: "£") { it in
                            sheetItem = toShell(it)
                        }
                        .padding(.bottom, 12)
                        
                        Section {
                            LazyVStack(alignment: .leading, spacing: 18) {
                                Color.clear.frame(height: 1).id("top")
                                
                                ForEach(categories, id: \.self) { cat in
                                    VStack(alignment: .leading, spacing: 12) {
                                        Color.clear.frame(height: 20)
                                        
                                        Text(cat)
                                            .font(.system(size: 22, weight: .semibold))
                                            .padding(.horizontal, 16)
                                            .background(
                                                GeometryReader { geo in
                                                    Color.clear.preference(
                                                        key: ShopCategoryOffsetKey.self,
                                                        value: [cat: geo.frame(in: .named("phoneScroll")).minY]
                                                    )
                                                }
                                            )
                                        
                                        if cat == "Highlights" {
                                            ScrollView(.horizontal, showsIndicators: false) {
                                                HStack(spacing: 12) {
                                                    ForEach(highlights) { h in
                                                        Button {
                                                            let isFirstHighlight = (h.id == highlights.first?.id)
                                                            
                                                            let sid = highlightShellId(h)
                                                            
                                                            sheetItem = ShellMenuItem(
                                                                id: sid,
                                                                name: h.name,
                                                                price: h.price,
                                                                category: "Highlights",
                                                                modifiers: isFirstHighlight ? demoHighlightModifiers : nil,
                                                                imageURL: h.imageURL.absoluteString,
                                                                description: isFirstHighlight ? "Demo modifiers (only on first highlight)" : nil
                                                            )
                                                        } label: {
                                                            ShopHighlightCardTall(h: h)
                                                        }
                                                        .buttonStyle(.plain)
                                                        
                                                    }
                                                }
                                                .padding(.horizontal, 16)
                                                .padding(.bottom, 4)
                                            }
                                        } else {
                                            LazyVGrid(columns: phoneCols, spacing: 12) {
                                                ForEach(shopModel.products(in: cat)) { p in
                                                    Button {
                                                        sheetItem = toShell(p)
                                                    } label: {
                                                        ShopProductCard(p: p, selectedLang: vm.selectedLang)
                                                    }
                                                    .buttonStyle(.plain)
                                                }
                                            }
                                            .padding(.horizontal, 16)
                                        }
                                    }
                                    .id(cat)
                                }
                                
                                Color.clear.frame(height: 80)
                            }
                        } header: {
                            ShopCategoryBar(categories: categories, selected: vm.selectedCategory) { cat in
                                manualScroll = true
                                syncResumeAt = Date().addingTimeInterval(0.9)
                                withAnimation(.easeInOut(duration: 0.22)) { vm.selectedCategory = cat }
                                
                                DispatchQueue.main.async {
                                    let target = (cat == "Highlights") ? "__scrollTop__" : cat
                                    withAnimation(.easeInOut(duration: 0.55)) {
                                        proxy.scrollTo(target, anchor: UnitPoint(x: 0.5, y: -0.03))
                                    }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                        withAnimation(.easeInOut(duration: 0.25)) {
                                            proxy.scrollTo(target, anchor: UnitPoint(x: 0.5, y: -0.03))
                                        }
                                    }
                                }
                                
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { manualScroll = false }
                            }
                        }
                    }
                }
               
                .coordinateSpace(name: "phoneScroll")
                .onPreferenceChange(ShopTopSentinelKey.self) { y in
                    let shouldShow = y < -70
                    if shouldShow != showNavTitle {
                        withAnimation(.easeInOut(duration: 0.18)) { showNavTitle = shouldShow }
                    }
                }
                .onPreferenceChange(ShopCategoryOffsetKey.self) { offsets in
                    guard Date() >= syncResumeAt, !manualScroll, !offsets.isEmpty else { return }
                    let threshold: CGFloat = 20 + 8 + 100
                    let sorted = offsets.sorted { $0.value < $1.value }
                    guard let match = (sorted.last(where: { $0.value <= threshold }) ?? sorted.first)?.key else { return }
                    if match != vm.selectedCategory {
                        withAnimation(.easeInOut(duration: 0.18)) { vm.selectedCategory = match }
                    }
                }
            }
        }
        .sheet(isPresented: $showQRShareSheet) {
            QRShareSheet(url: shareURL)
                .presentationDetents([.large])
                .presentationCornerRadius(26)
                .presentationDragIndicator(.visible)
        }
        .navigationDestination(isPresented: $pushConfirmation) {
                   ShopConfirmationView()
               }
    }
        .sheet(isPresented: $showMemberCard) {
            MemberCardSheet()
                .presentationDetents([.height(200)])
               
                .presentationCornerRadius(26)
                .presentationDragIndicator(.visible)
        }
        .sheet(item: Binding(
            get: { isPad ? nil : sheetItem },
            set: { if $0 == nil { sheetItem = nil } }
        )) { it in
            HugHeightSheet {
                ShopProductSheet(
                    miniAppId: miniAppId,
                    item: it,
                    editingLineId: nil,
                    initialQuantityInBasket: basket[it.id],
                    initialSelectedOptions: [:],
                    initialSelectedAdditions: [],
                    mode: .phone,
                    t: { $0 },
                    onAdd: { product, qty, _, _, _, _ in
                        addToBasket(product.id, qty: qty)

                        let shouldReopen = reopenBasketAfterSheet
                        reopenBasketAfterSheet = false
                        sheetItem = nil

                        if shouldReopen {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                                withAnimation(.easeInOut(duration: 0.18)) { showBasketSheet = true }
                            }
                        }
                    },
                    onClose: {
                        let shouldReopen = reopenBasketAfterSheet
                        reopenBasketAfterSheet = false
                        sheetItem = nil

                        if shouldReopen {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                                withAnimation(.easeInOut(duration: 0.18)) { showBasketSheet = true }
                            }
                        }
                    }
                )
            }
            .presentationCornerRadius(26)
            .presentationDragIndicator(.visible)
        }

        // iPad: centered overlay card (old style)
        .overlay {
            if isPad, let it = sheetItem {
                ProductOverlayCard(onDismiss: { sheetItem = nil }) {
                    ShopProductSheet(
                        miniAppId: miniAppId,
                        item: it,
                        editingLineId: nil,
                        initialQuantityInBasket: basket[it.id],
                        initialSelectedOptions: [:],
                        initialSelectedAdditions: [],
                        mode: isPad ? .padOverlay : .phone,
                        t: { $0 },
                        onAdd: { product, qty, _, _, _, _ in
                            addToBasket(product.id, qty: qty)

                            let shouldReopen = reopenBasketAfterSheet
                            reopenBasketAfterSheet = false
                            sheetItem = nil

                            if shouldReopen {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                    withAnimation(.easeInOut(duration: 0.18)) {
                                        showBasketSheet = true
                                    }
                                }
                            }
                        },
                        onClose: {
                            let shouldReopen = reopenBasketAfterSheet
                            reopenBasketAfterSheet = false
                            sheetItem = nil

                            if shouldReopen {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                    withAnimation(.easeInOut(duration: 0.18)) {
                                        showBasketSheet = true
                                    }
                                }
                            }
                        }
                    )
                }
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.9), value: basketQty)
        .sheet(isPresented: Binding(
            get: { showBasketSheet && !isPad },
            set: { if !$0 { showBasketSheet = false } }
        )) {
            HugBasketSheet {
                BasketSheetShop(
                    miniAppId: miniAppId,
                    isRtl: false,
                    lines: basketLinesShop,
                    onClose: { showBasketSheet = false },
                    onClear: { basket.removeAll(); showBasketSheet = false },
                    onIncrement: { id in basket[id, default: 0] += 1 },
                    onDecrement: { id in
                        let q = basket[id, default: 0] - 1
                        if q <= 0 { basket[id] = nil } else { basket[id] = q }
                        if basket.isEmpty { showBasketSheet = false }
                    },
                    onLineTap: { row in
                        reopenBasketAfterSheet = true
                        showBasketSheet = false

                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {

                            if let p = shopModel.product(by: row.id) {
                                sheetItem = toShell(p); return
                            }

                            if let h = highlights.first(where: { highlightShellId($0) == row.id }) {
                                let isFirst = (h.id == highlights.first?.id)
                                sheetItem = ShellMenuItem(
                                    id: highlightShellId(h),
                                    name: h.name,
                                    price: h.price,
                                    category: "Highlights",
                                    modifiers: isFirst ? demoHighlightModifiers : nil,
                                    imageURL: h.imageURL.absoluteString,
                                    description: isFirst ? "Demo modifiers (only on first highlight)" : nil
                                )
                                return
                            }

                            if let u = upsells.first(where: { $0.id == row.id }) {
                                sheetItem = u; return
                            }
                        }
                    },
                    upsells: upsells,
                    onAddUpsell: { it in basket[it.id, default: 0] += 1 },
                    onOpenUpsell: { it in
                        reopenBasketAfterSheet = true
                        showBasketSheet = false

                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                            sheetItem = it
                        }
                    },
                    onBackToShop: { showBasketSheet = false },
                    onContinueToPayment: {
                        // ✅ snapshot
                        pendingCheckoutLines = basketLinesShop
                        pendingCheckoutTotal = basketTotal
                        pendingCheckoutCreatedAt = Date()

                        showBasketSheet = false

                        // ✅ iPhone: skip OrderFlow and show confirmation overlay immediately
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            confirmation = OrderConfirmationPayload(
                                orderId: "DEMO-\(Int(Date().timeIntervalSince1970))",   // replace with real id later
                                receiptURL: nil,                                      // set when you have it
                                paidTotal: pendingCheckoutTotal,
                                tipTotal: 0,
                                lines: pendingCheckoutLines,
                                createdAt: Date(),
                                contextLabel: vm.selectedContext
                            )

                            // optional: clear basket now (since checkout is "final" in this flow)
                            basket.removeAll()

                            // reset snapshot
                            pendingCheckoutLines = []
                            pendingCheckoutTotal = 0
                            pendingCheckoutCreatedAt = .distantPast

                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                        }
                    },
                    t: { $0 }
                )
                .presentationBackground(.clear)
                .presentationDragIndicator(.visible)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        }
     
        .animation(.easeInOut(duration: 0.18), value: showBasketSheet)
        .sheet(isPresented: $vm.showLocationSheet) {
            LocationPickerSheet(options: locationOptions, selected: $vm.selectedContext) {
                vm.showLocationSheet = false
            }
        }
        .onAppear {
            if miniAppId == 0 {
                miniAppId = UserDefaults.standard.integer(forKey: "miniAppId")
            }

            if miniAppId == 13 {
                let defaults = UserDefaults.standard
                let storedPickup = (defaults.string(forKey: "pickup.location.v2") ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if !storedPickup.isEmpty {
                    vm.selectedContext = contextLabel(from: storedPickup)
                } else {
                    persistSelectedContext(vm.selectedContext)
                }
            }

            shopModel.load(shopId: miniAppId)

            if !isPad {
                showInitialContextPicker = true
            }
        }
        .onChange(of: vm.selectedContext) { newValue in
            persistSelectedContext(newValue)
        }
        .onChange(of: shopModel.categories) { newCategories in
            guard !newCategories.isEmpty else { return }
            if !newCategories.contains(vm.selectedCategory) {
                vm.selectedCategory = newCategories.first ?? ""
            }
        }
        
    }
}

//productSheet



private enum ShopProductSheetSeed {
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

struct ShopProductSheet: View {
    let miniAppId: Int
    let item: ShellMenuItem
    let editingLineId: Int?
    let initialQuantityInBasket: Int?
    let initialSelectedOptions: [String: String]
    let initialSelectedAdditions: Set<String>
    let onAdd: (ShellMenuItem, Int, String?, Double, [String: String], Set<String>) -> Void
    let onClose: () -> Void
    let mode: ShopProductSheetMode
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
        editingLineId: Int? = nil,
        initialQuantityInBasket: Int?,
        initialSelectedOptions: [String: String],
        initialSelectedAdditions: Set<String> = [],
        mode: ShopProductSheetMode = .phone,
        t: @escaping (String) -> String,
        onAdd: @escaping (ShellMenuItem, Int, String?, Double, [String: String], Set<String>) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.miniAppId = miniAppId
        self.item = item
        self.editingLineId = editingLineId
        self.initialQuantityInBasket = initialQuantityInBasket
        self.initialSelectedOptions = initialSelectedOptions
        self.initialSelectedAdditions = initialSelectedAdditions
        self.mode = mode
        self.t = t
        self.onAdd = onAdd
        self.onClose = onClose

        _quantity = State(initialValue: initialQuantityInBasket ?? 1)

        let seeded = ShopProductSheetSeed.seed(
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
            if mode == .padOverlay { padOverlayBody } else { phoneSheetBody }
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
            heroView(padOverlay: false)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.horizontal, sidePad)
                .padding(.top, topPad)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerBlock
                    modifiersBlock
                    Color.clear.frame(height: barH + 16)
                }
                .padding(.horizontal, sidePad)
                .padding(.top, 14)
            }

            bottomBar
                .padding(.horizontal, sidePad)
                .padding(.bottom, 10)
                
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
            .padding(isPad ? 30:10)
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
            ModifierListViewShop(
                groups: groups,
                selectedOptions: $selectedOptions,
                selectedAdditions: $selectedAdditions,
                t: t
            )
            .padding(.top, 6)
        }
    }

    private var unitWithExtras: Double { item.price + extraPricePerUnit() }

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

            let pickedInGroup = selectedAdditions.map(norm).filter { groupNormNames.contains($0) }
            let nonDefault = pickedInGroup.filter { $0 != defaultNorm }

            if !nonDefault.isEmpty {
                let ordered = g.items.map { norm($0.name) }.filter { nonDefault.contains($0) }
                parts.append(contentsOf: ordered)
            }
        }

        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

private struct ModifierListViewShop: View {
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

//basketSheet
 
struct BasketSheetShop: View {
    let miniAppId: Int
    let isRtl: Bool
    let lines: [BasketLineShop]

    let onClose: () -> Void
    let onClear: () -> Void

    let onIncrement: (Int) -> Void
    let onDecrement: (Int) -> Void
    let onLineTap: (BasketLineShop) -> Void

    let upsells: [ShellMenuItem]
    let onAddUpsell: (ShellMenuItem) -> Void
    let onOpenUpsell: (ShellMenuItem) -> Void

    let onBackToShop: () -> Void
    let onContinueToPayment: () -> Void

    let t: (String) -> String

    @Environment(\.colorScheme) private var scheme
    @State private var hiddenUpsellIds: Set<Int> = []

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

    private var brandBg: Color { adjustedBrand(for: miniAppId) }
    private var brandFg: Color { .white }

    var body: some View {
        let isPhone = UIDevice.current.userInterfaceIdiom == .phone
        let isPad = UIDevice.current.userInterfaceIdiom == .pad

        VStack(spacing: 0) {
            headerBar

            ViewThatFits(in: .vertical) {
                VStack(spacing: 0) {
                    contentStack(isPhone: isPhone)
                    bottomBar(isPhone: isPhone, isPad: isPad)
                }

                VStack(spacing: 0) {
                    ScrollView(showsIndicators: true) { contentStack(isPhone: isPhone) }
                    bottomBar(isPhone: isPhone, isPad: isPad)
                }
            }
        }
        
        .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
    }

    private var headerBar: some View {
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
                            Circle().fill(scheme == .dark ? Color.white.opacity(0.16) : Color.black.opacity(0.08))
                        )
                        .overlay(
                            Circle().stroke(scheme == .dark ? Color.white.opacity(0.22) : Color.black.opacity(0.10), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
        }
        .frame(height: 56)
       
        .overlay(Divider().opacity(0.25), alignment: .bottom)
    }

    private func contentStack(isPhone: Bool) -> some View {
        VStack(spacing: 18) {
            VStack(spacing: 14) {
                ForEach(lines, id: \.id) { (row: BasketLineShop) in
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
                        .foregroundColor(brandFg)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(brandBg)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
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
                            .foregroundColor(brandFg)
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                            .background(brandBg)
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
      
    }

    private struct BasketRowInline: View {
        let miniAppId: Int
        let isRtl: Bool
        let row: BasketLineShop

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
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct BasketSheetMeasuredHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private extension View {
    func measureBasketSheetHeight(_ onChange: @escaping (CGFloat) -> Void) -> some View {
        background(
            GeometryReader { geo in
                Color.clear.preference(key: BasketSheetMeasuredHeightKey.self, value: geo.size.height)
            }
        )
        .onPreferenceChange(BasketSheetMeasuredHeightKey.self, perform: onChange)
    }
}

private struct HugBasketSheet<Content: View>: View {
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
private struct BasketOverlayCard<Content: View>: View {
    let onDismiss: () -> Void
    let maxWidth: CGFloat
    let content: Content

    @State private var measuredH: CGFloat = 520

    init(
        maxWidth: CGFloat = 500,
        onDismiss: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.maxWidth = maxWidth
        self.onDismiss = onDismiss
        self.content = content()
    }

    var body: some View {
        GeometryReader { geo in
            let maxH = geo.size.height * 0.88
            let minH: CGFloat = 320
            let targetH = min(max(measuredH, minH), maxH)
            let cardW = min(maxWidth, geo.size.width - 80)

            ZStack {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .ignoresSafeArea()

                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture { onDismiss() }

                content
                    .frame(width: cardW, height: targetH)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 26, y: 16)
                    .animation(.spring(response: 0.28, dampingFraction: 0.9), value: targetH)

                content
                    .fixedSize(horizontal: false, vertical: true)
                
                    .frame(width: cardW)
                    .measureBasketSheetHeight { h in
                        let rounded = (h * 10).rounded() / 10
                        if abs(measuredH - rounded) > 1 { measuredH = rounded }
                    }
                    .opacity(0.001)
                    .allowsHitTesting(false)
            }
        }
        .zIndex(9999)
        .transition(.opacity)
    }
}


//shopModel
final class ShopVM2: ObservableObject {
    @Published var selectedContext: String = "Humanities"
    @Published var selectedLang: String = "en"
    @Published var showLocationSheet: Bool = false
    @Published var selectedCategory: String = "Highlights"
}

struct ShopMyItem: Identifiable, Equatable {
    let id: Int
    let name: String
    let price: Double
    let imageURL: URL
}


struct ShopProduct: Identifiable, Equatable {
    let id: Int
    let name: String
    let nameHe: String?
    let nameEn: String?
    let category: String
    let price: Double
    let imageURL: URL

    func localizedName(lang: String) -> String {
        switch lang {
        case "he":
            let v = (nameHe ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return v.isEmpty ? name : v
        default:
            let v = (nameEn ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return v.isEmpty ? name : v
        }
    }
}

struct ShopHighlight: Identifiable, Equatable {
    let id: Int
    let name: String
    let price: Double
    let imageURL: URL
}

struct BasketLineShop: Identifiable, Equatable {
   let id: Int                 // productId
   let name: String
   let imageURL: String?
   let qty: Int
   let unitPrice: Double
   let subtitle: String?
   let opts: [String: String]
   let adds: Set<String>

   init(
       id: Int,
       name: String,
       imageURL: String? = nil,
       qty: Int,
       unitPrice: Double,
       subtitle: String? = nil,
       opts: [String: String] = [:],
       adds: Set<String> = []
   ) {
       self.id = id
       self.name = name
       self.imageURL = imageURL
       self.qty = qty
       self.unitPrice = unitPrice
       self.subtitle = subtitle
       self.opts = opts
       self.adds = adds
   }
}

enum ShopProductSheetMode { case padOverlay, phone }

private func shopFormatPrice(_ v: Double) -> String {
    let rounded = (v * 100).rounded() / 100
    let s = String(format: "%.2f", rounded)
    return s
        .replacingOccurrences(of: #"(\.0+)$"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"(\.\d*[1-9])0+$"#, with: "$1", options: .regularExpression)
}

private func highlightShellId(_ h: ShopHighlight) -> Int {
    900000 + h.id
}
private struct ConfirmationOverlayCard: View {
    let miniAppId: Int
    let payload: OrderConfirmationPayload
    let onDone: () -> Void
    let onTapOutside: () -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.openURL) private var openURL

    private var cardMaxW: CGFloat { UIDevice.current.userInterfaceIdiom == .pad ? 560 : 420 }

    private func priceText(_ v: Double) -> String {
        let s = shopFormatPrice(v)
        return (miniAppId == 3) ? "£\(s)" : s
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // ✅ fullscreen glass that keeps shop vixqsible behind
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .ignoresSafeArea()

                // tap outside to dismiss (optional). you can disable this if you want “Done only”
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture { onTapOutside() }

                VStack(spacing: 16) {
                    // header
                    VStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 54, weight: .semibold))
                            .foregroundColor(.green)

                        Text("Order confirmed")
                            .font(appFont(miniAppId, 26).weight(.heavy))
                            .multilineTextAlignment(.center)

                        Text("#\(payload.orderId)")
                            .font(appFont(miniAppId, 16).weight(.semibold))
                            .foregroundColor(.secondary)

                        // context / location
                        Text(payload.contextLabel)
                            .font(appFont(miniAppId, 15).weight(.semibold))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }

                    // totals
                    HStack {
                        Text("Total")
                            .font(appFont(miniAppId, 16).weight(.semibold))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(priceText(payload.paidTotal))
                            .font(appFont(miniAppId, 18).weight(.heavy))
                    }

                    if payload.tipTotal > 0.001 {
                        HStack {
                            Text("Tip")
                                .font(appFont(miniAppId, 16).weight(.semibold))
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(priceText(payload.tipTotal))
                                .font(appFont(miniAppId, 16).weight(.semibold))
                        }
                    }

                    // mini “order summary” (compact)
                    if !payload.lines.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Items")
                                .font(appFont(miniAppId, 16).weight(.semibold))
                                .foregroundColor(.secondary)

                            VStack(spacing: 8) {
                                ForEach(payload.lines.prefix(5)) { row in
                                    HStack(spacing: 10) {
                                        Text("\(max(0,row.qty))×")
                                            .font(appFont(miniAppId, 15).weight(.semibold))
                                            .foregroundColor(.secondary)
                                            .frame(width: 28, alignment: .leading)

                                        Text(row.name)
                                            .font(appFont(miniAppId, 15).weight(.semibold))
                                            .lineLimit(1)

                                        Spacer()

                                        let lineTotal = Double(max(0,row.qty)) * row.unitPrice
                                        Text(priceText(lineTotal))
                                            .font(appFont(miniAppId, 15).weight(.semibold))
                                            .foregroundColor(.secondary)
                                    }
                                }

                                if payload.lines.count > 5 {
                                    Text("+ \(payload.lines.count - 5) more")
                                        .font(appFont(miniAppId, 14).weight(.semibold))
                                        .foregroundColor(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.top, 2)
                                }
                            }
                        }
                    }

                    // actions
                    VStack(spacing: 12) {

                        if let url = payload.receiptURL {
                            Button {
                                openURL(url)
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            } label: {
                                HStack {
                                    Image(systemName: "doc.text")
                                        .font(.system(size: 16, weight: .semibold))
                                    Text("View receipt")
                                        .font(appFont(miniAppId, 17).weight(.semibold))
                                    Spacer()
                                    Image(systemName: "arrow.up.right")
                                        .font(.system(size: 14, weight: .bold))
                                        .opacity(0.6)
                                }
                                .padding(.horizontal, 16)
                                .frame(height: 52)
                                .frame(maxWidth: .infinity)
                                .background(Color(.secondarySystemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }

                       
                    }
                }
                .padding(18)
                .frame(width: min(cardMaxW, geo.size.width - 40))
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 28, y: 18)
                .transition(.scale(scale: 0.92).combined(with: .opacity))
            }
        }
        .zIndex(20000) // above everything
    }
}



@MainActor
final class ShopDataModel: ObservableObject {
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var products: [ShopProduct] = []
    @Published var categories: [String] = []

    private let api = MenuApiModel()
    private var cancellables = Set<AnyCancellable>()

    init() {
        api.$items
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applyFromAPI()
            }
            .store(in: &cancellables)

        api.$categoryOrder
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applyFromAPI()
            }
            .store(in: &cancellables)

        api.$isLoading
            .receive(on: DispatchQueue.main)
            .sink { [weak self] loading in
                self?.isLoading = loading
            }
            .store(in: &cancellables)

        api.$errorMessage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                self?.errorMessage = message
            }
            .store(in: &cancellables)
    }

    func load(shopId: Int) {
        guard shopId > 0 else { return }

        isLoading = true
        errorMessage = nil
        products = []
        categories = []

        api.load(shopId: String(shopId))
    }

    func refreshFromAPI() {
        applyFromAPI()
    }

    private func applyFromAPI() {
        let now = Date()
        let mappedProducts: [ShopProduct] = api.items
            .filter {
                $0.isAvailable
                && $0.isWithinActiveHours(now: now)
                && $0.isAvailableOnWeekday(now: now)   // ✅ NEW: per-weekday hour limit
            }
            .compactMap { item in
                guard
                    let s = item.imageURL,
                    let url = URL(string: s)
                else {
                    return nil
                }

                let category = item.category.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !category.isEmpty else { return nil }

                return ShopProduct(
                    id: item.id,
                    name: item.name,
                    nameHe: item.nameI18n?.he,
                    nameEn: item.nameI18n?.en,
                    category: category,
                    price: item.price,
                    imageURL: url
                )
            }

        let visibleCategorySet = Set(
            mappedProducts
                .map(\.category)
                .filter { !$0.isEmpty }
        )

        let orderedCategoriesFromAPI = api.categoryOrder
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { visibleCategorySet.contains($0) }

        let fallbackCategories = Array(visibleCategorySet).sorted()

        let mergedCategories: [String]
        if orderedCategoriesFromAPI.isEmpty {
            mergedCategories = fallbackCategories
        } else {
            mergedCategories =
                orderedCategoriesFromAPI +
                fallbackCategories.filter { !orderedCategoriesFromAPI.contains($0) }
        }

        products = mappedProducts
        categories = mergedCategories
        isLoading = api.isLoading

    }

    func products(in category: String) -> [ShopProduct] {
        products.filter { $0.category == category }
    }

    func product(by id: Int) -> ShopProduct? {
        products.first { $0.id == id }
    }

    var productById: [Int: ShopProduct] {
        Dictionary(uniqueKeysWithValues: products.map { ($0.id, $0) })
    }
}
