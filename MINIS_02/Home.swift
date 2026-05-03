import Combine
import SwiftUI
import Kingfisher

// MARK: - Tabs

private enum TabFilter: Hashable {
    case all
    case kind(MiniKind)

    var title: String {
        switch self {
        case .all: return "All"
        case .kind(let k): return k.displayTitle
        }
    }
}

enum MiniKind: String, Codable, CaseIterable, Identifiable {
    case miniMe, ticket, portfolio, fastlane, minitel
    var id: String { rawValue }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self).lowercased()
        switch raw {
        case "minime": self = .miniMe
        case "fastlane": self = .fastlane
        case "ticket": self = .ticket
        case "portfolio": self = .portfolio
        case "minitel": self = .minitel
        default: self = .miniMe
        }
    }

    var displayTitle: String {
        switch self {
        case .miniMe:    return "Minime"
        case .fastlane:  return "Fastlane"
        case .ticket:    return "Tickets"
        case .portfolio: return "Portfolios"
        case .minitel:   return "Minitel"
        }
    }
}

// MARK: - Home

struct HomeView: View {
    @State private var referrals: [MiniReferral] = []

    @State private var selectedFilter: TabFilter = .all
    @State private var selectedIndex: Int = 0

    @State private var showStudio = false
    @State private var showMenu = false

    @State private var provisionalReloadCancellable: AnyCancellable?

    @AppStorage("launchStudioOnce") private var launchStudioOnce: Bool = false
    @AppStorage("launchMenuOnce") private var launchMenuOnce: Bool = false

    @AppStorage("shopId") private var shopId: String = "0"
    @AppStorage("miniAppId") private var miniAppId: Int = 0

    @State private var openedDefaultMiniOnce = false
    @State private var openedFallbackOnce = false

    @State private var showQR = false
    @Namespace private var underlineNS

    @AppStorage(AppSettings.Key.cashPointMode) private var cashPointMode: Bool = AppSettings.Defaults.cashPointMode

    // ✅ iPad “no saved mini” fallback (your existing behavior)
    private let fallbackMiniShopId: Int = 12

    // ✅ NEW: when no minis exist at all in app-group → open this mini
    private let emptyStateMiniAppId: Int = 3

    private var kinds: [MiniKind] {
        Array(Set(referrals.map { $0.kind })).sorted { $0.rawValue < $1.rawValue }
    }

    private var tabs: [TabFilter] { [.all] + kinds.map { .kind($0) } }

    private func items(for tab: TabFilter) -> [MiniReferral] {
        switch tab {
        case .all: return referrals
        case .kind(let k): return referrals.filter { $0.kind == k }
        }
    }

    private func index(of tab: TabFilter) -> Int {
        tabs.firstIndex(of: tab) ?? 0
    }

    private func tab(at index: Int) -> TabFilter {
        tabs[min(max(0, index), max(0, tabs.count - 1))]
    }

    var body: some View {
        VStack(spacing: 0) {
            if !tabs.isEmpty {
                TabsBarView(
                    tabs: tabs,
                    selectedIndex: $selectedIndex,
                    selectedFilter: $selectedFilter,
                    underlineNS: underlineNS,
                    showQR: $showQR
                )
            }

            if tabs.isEmpty {
                GeometryReader { geo in
                    VStack {
                        Text("No recent Minis yet")
                            .foregroundColor(.secondary)
                            .font(.system(size: 18, weight: .medium))
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }
            } else {
                TabView(selection: $selectedIndex) {
                    ForEach(Array(tabs.enumerated()), id: \.offset) { idx, tab in
                        TabPageView(
                            items: items(for: tab),
                            onOpen: openReferral(_: )
                        )
                        .tag(idx)
                    }
                }
                .ignoresSafeArea(edges: .bottom)
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.interactiveSpring(response: 0.35, dampingFraction: 0.9), value: selectedIndex)
                .onChange(of: selectedIndex) { selectedFilter = tab(at: $0) }
                .onChange(of: selectedFilter) { newFilter in
                    let idx = index(of: newFilter)
                    guard idx != selectedIndex else { return }
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) {
                        selectedIndex = idx
                    }
                }
            }
        }
        .onAppear(perform: handleAppear)
        .onChange(of: launchStudioOnce) { if $0 { showStudio = true; launchStudioOnce = false } }
        .onChange(of: launchMenuOnce) { newValue in
            guard newValue else { return }
            saveCurrentMiniToHomeReferrals(kind: .fastlane)
            showMenu = true
            launchMenuOnce = false
        }
        .onChange(of: referrals.map { "\($0.miniAppId)#\($0.kind.rawValue)#\($0.title)" }) { _ in
            let idx = min(selectedIndex, max(0, tabs.count - 1))
            selectedIndex = idx
            selectedFilter = tab(at: idx)
        }
        .onChange(of: showStudio) { $0 ? startProvisionalReloads() : stopProvisionalReloads() }
        .onChange(of: showMenu)   { $0 ? startProvisionalReloads() : stopProvisionalReloads() }
        .onChange(of: miniAppId, perform: handleMiniAppChange(_:))
        .fullScreenCover(isPresented: $showMenu, onDismiss: {
            stopProvisionalReloads()
            reloadReferrals()
        }) {
            MenuCover()
        }
    }

    // MARK: - Actions

    private func openReferral(_ r: MiniReferral) {
        // Reset style to base before applying new mini’s customization
        resetShopUserDefaultsToDefaults()

        // 🔥 Update BOTH miniAppId and shopId
        miniAppId = r.miniAppId
        shopId = String(r.miniAppId)

        UserDefaults.standard.set(r.miniAppId, forKey: "miniAppId")
        UserDefaults.standard.set(String(r.miniAppId), forKey: "shopId")

        print("🏠 HomeView.onOpen → tapped miniAppId=\(r.miniAppId), kind=\(r.kind)")

        withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
            let isMiniMe = (r.kind == .miniMe)
            showStudio = isMiniMe
            showMenu = !isMiniMe
        }
    }

    private func openMiniAppId(_ id: Int) {
        miniAppId = id
        shopId = String(id)

        UserDefaults.standard.set(id, forKey: "miniAppId")
        UserDefaults.standard.set(String(id), forKey: "shopId")

        resetShopUserDefaultsToDefaults()

        withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
            showMenu = true
        }
    }

    // MARK: - Lifecycle

    private func handleAppear() {
        reloadReferrals()

        // ✅ NEW: if NO minis exist yet → open miniAppId=3 once
        if referrals.isEmpty && !openedFallbackOnce {
            openedFallbackOnce = true
            openMiniAppId(emptyStateMiniAppId)
            return
        }

        if launchStudioOnce { showStudio = true; launchStudioOnce = false }
        if launchMenuOnce  { showMenu  = true; launchMenuOnce  = false }

        // ✅ iPad: jump straight into Menu using saved miniAppId
        if UIDevice.current.userInterfaceIdiom == .pad, !cashPointMode, !openedDefaultMiniOnce {
            openedDefaultMiniOnce = true

            if miniAppId <= 0 {
                openMiniAppId(fallbackMiniShopId)
            } else {
                resetShopUserDefaultsToDefaults()
                showMenu = true
            }
        }

        selectedIndex = index(of: selectedFilter)
    }

    private func handleMiniAppChange(_ newValue: Int) {
        guard newValue != 0 else { return }

        print("🎯 HomeView saw miniAppId change → \(newValue)")

        shopId = String(newValue)
        resetShopUserDefaultsToDefaults()

        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
            showMenu = true
        }
    }

    // MARK: - Menu Cover

    @ViewBuilder
    private func MenuCover() -> some View {
        @AppStorage("deliveryLoc") var deliveryLoc: String = ""

        let isRtlDirection = (UserDefaults.standard.string(forKey: "direction") == "rtl")
        let forceDark = !deliveryLoc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        Group {
            if isRtlDirection {
                ForceRTL {
                    NavigationStack {
                        menuView()
                            .environment(\.isRtl, true)
                            .navigationBarTitleDisplayMode(.inline)
                            .environment(\.layoutDirection, .rightToLeft)
                    }
                }
            } else {
                NavigationStack {
                    menuView()
                        .environment(\.isRtl, false)
                        .navigationBarTitleDisplayMode(.inline)
                        .environment(\.layoutDirection, .leftToRight)
                }
            }
        }
        .preferredColorScheme(forceDark ? .dark : nil)
    }

    // MARK: - Referrals Persistence

    private func saveCurrentMiniToHomeReferrals(kind: MiniKind = .fastlane) {
        guard miniAppId > 0 else { return }
        guard let suite = UserDefaults(suiteName: "group.minis") else { return }

        let referral = MiniReferral(
            title: "Mini \(miniAppId)",
            subtitle: kind.displayTitle,
            miniAppId: miniAppId,
            imageURL: nil,
            sharedAt: Date(),
            kind: kind
        )

        if let data = try? JSONEncoder().encode(referral) {
            suite.set(data, forKey: "lastMiniReferralJSON")
        }

        var arr: [MiniReferral] = []
        if let data = suite.data(forKey: "miniReferralsJSON"),
           let decoded = try? JSONDecoder().decode([MiniReferral].self, from: data) {
            arr = decoded
        }

        arr.removeAll { $0.miniAppId == referral.miniAppId && $0.kind == referral.kind }
        arr.insert(referral, at: 0)

        if arr.count > 30 { arr = Array(arr.prefix(30)) }

        if let data = try? JSONEncoder().encode(arr) {
            suite.set(data, forKey: "miniReferralsJSON")
        }

        suite.synchronize()
        print("✅ HomeView saved referral → miniAppId=\(miniAppId), kind=\(kind.rawValue)")
    }

    private func reloadReferrals() {
        referrals = loadAllMiniReferralsFromAppGroup()
        selectedIndex = index(of: selectedFilter)
    }

    private func startProvisionalReloads() {
        provisionalReloadCancellable?.cancel()
        provisionalReloadCancellable = Timer.publish(every: 0.7, on: .main, in: .common)
            .autoconnect()
            .scan(0) { count, _ in count + 1 }
            .prefix(3)
            .sink { _ in reloadReferrals() }
    }

    private func stopProvisionalReloads() {
        provisionalReloadCancellable?.cancel()
        provisionalReloadCancellable = nil
    }
}

// MARK: - Tabs Bar

private struct TabsBarView: View {
    let tabs: [TabFilter]
    @Binding var selectedIndex: Int
    @Binding var selectedFilter: TabFilter
    let underlineNS: Namespace.ID
    @Binding var showQR: Bool

    var body: some View {
        let selectedColor: Color = .primary
        let unselectedColor: Color = Color(.darkGray)

        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(Array(tabs.enumerated()), id: \.offset) { idx, tab in
                            let isSelected = (idx == selectedIndex)
                            VStack(spacing: 10) {
                                Text(tab.title)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(isSelected ? selectedColor : unselectedColor)
                                    .onTapGesture {
                                        withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.9)) {
                                            selectedIndex = idx
                                            selectedFilter = tab
                                            proxy.scrollTo(idx, anchor: .center)
                                        }
                                    }

                                ZStack {
                                    if isSelected {
                                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                                            .fill(selectedColor)
                                            .frame(height: 2)
                                            .matchedGeometryEffect(id: "tabs-underline", in: underlineNS)
                                    } else {
                                        Color.clear.frame(height: 2)
                                    }
                                }
                            }
                            .id(idx)
                        }
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 10)
                }
                .onChange(of: selectedIndex) { newIdx in
                    withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.9)) {
                        proxy.scrollTo(newIdx, anchor: .center)
                    }
                }
            }

            Spacer(minLength: 8)

            // QR button intentionally commented out (keeping your original)
            /*
            Button { showQR = true } label: {
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 10)
            .padding(.top, -10)
            */
        }
        .padding(.horizontal, 10)
        .background(Color(.systemBackground))
        .animation(.interactiveSpring(response: 0.35, dampingFraction: 0.9), value: selectedIndex)
    }
}

// MARK: - Page

private struct TabPageView: View {
    let items: [MiniReferral]
    let onOpen: (MiniReferral) -> Void

    var body: some View {
        if items.isEmpty {
            VStack(spacing: 10) {
                Text("No Minis yet")
                    .foregroundColor(.secondary)
                    .font(.system(size: 18, weight: .medium))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(spacing: 16) {
                    ForEach(items.indices, id: \.self) { i in
                        ReferralCardView(referral: items[i], onOpen: onOpen)
                            .padding(.horizontal, 16)
                    }
                }
                .padding(.vertical, 20)
            }
        }
    }
}

// MARK: - Card

private struct RoundedCorners: Shape {
    var tl: CGFloat = 0
    var tr: CGFloat = 0
    var bl: CGFloat = 0
    var br: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height

        let tr = min(min(self.tr, h / 2), w / 2)
        let tl = min(min(self.tl, h / 2), w / 2)
        let bl = min(min(self.bl, h / 2), w / 2)
        let br = min(min(self.br, h / 2), w / 2)

        path.move(to: CGPoint(x: w / 2.0, y: 0))
        path.addLine(to: CGPoint(x: w - tr, y: 0))
        path.addArc(center: CGPoint(x: w - tr, y: tr), radius: tr,
                    startAngle: Angle(degrees: -90), endAngle: Angle(degrees: 0), clockwise: false)

        path.addLine(to: CGPoint(x: w, y: h - br))
        path.addArc(center: CGPoint(x: w - br, y: h - br), radius: br,
                    startAngle: Angle(degrees: 0), endAngle: Angle(degrees: 90), clockwise: false)

        path.addLine(to: CGPoint(x: bl, y: h))
        path.addArc(center: CGPoint(x: bl, y: h - bl), radius: bl,
                    startAngle: Angle(degrees: 90), endAngle: Angle(degrees: 180), clockwise: false)

        path.addLine(to: CGPoint(x: 0, y: tl))
        path.addArc(center: CGPoint(x: tl, y: tl), radius: tl,
                    startAngle: Angle(degrees: 180), endAngle: Angle(degrees: 270), clockwise: false)

        return path
    }
}

private struct ReferralCardView: View {
    let referral: MiniReferral
    let onOpen: (MiniReferral) -> Void

    var body: some View {
        Button { onOpen(referral) } label: {
            VStack(spacing: 0) {
                headerImage

                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(referral.title)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(.primary)

                        Text(referral.subtitle)
                            .font(.system(size: 15))
                            .foregroundColor(.primary)
                            .lineLimit(2)
                            .truncationMode(.tail)
                    }
                    Spacer()
                }
                .padding(16)
                .background(Color(.systemGray6))
                .clipShape(RoundedCorners(tl: 0, tr: 0, bl: 18, br: 18))
            }
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(.systemBackground))
            )
            .shadow(color: Color.black.opacity(0.1), radius: 14, x: 0, y: 8)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var headerImage: some View {
        if let s = referral.imageURL, let url = URL(string: s) {
            KFImage(url)
                .placeholder { Color(.systemGray5) }
                .resizable()
                .scaledToFill()
                .frame(height: 210)
                .clipShape(RoundedCorners(tl: 18, tr: 18, bl: 0, br: 0))
                .clipped()
        } else {
            Color(.systemGray5)
                .frame(height: 210)
                .clipShape(RoundedCorners(tl: 18, tr: 18, bl: 0, br: 0))
        }
    }
}

// MARK: - App Group Load

private func loadAllMiniReferralsFromAppGroup() -> [MiniReferral] {
    let defaults = UserDefaults(suiteName: "group.minis")

    if let data = defaults?.data(forKey: "miniReferralsJSON"),
       var arr = try? JSONDecoder().decode([MiniReferral].self, from: data),
       !arr.isEmpty {
        arr.sort { $0.sharedAt > $1.sharedAt }

        var seen = Set<String>()
        var unique: [MiniReferral] = []
        unique.reserveCapacity(arr.count)

        for r in arr {
            let key = "\(r.miniAppId)#\(r.kind.rawValue)#\(r.title)"
            if !seen.contains(key) {
                seen.insert(key)
                unique.append(r)
            }
        }
        return unique
    }

    if let data = defaults?.data(forKey: "lastMiniReferralJSON"),
       let single = try? JSONDecoder().decode(MiniReferral.self, from: data) {
        return [single]
    }

    return []
}

// MARK: - RTL Helper

struct ForceRTL<Content: View>: View {
    let content: Content
    init(@ViewBuilder _ content: () -> Content) { self.content = content() }

    var body: some View {
        content
            .environment(\.layoutDirection, .rightToLeft)
            .background(SemanticHost())
    }

    private struct SemanticHost: UIViewControllerRepresentable {
        func makeUIViewController(context: Context) -> UIViewController { Controller() }
        func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

        final class Controller: UIViewController {
            // Explicit, optimizer-exempt deinit. The synthesized deinit of this
            // nested-generic UIViewController subclass triggers a Swift 6.3.1 SIL
            // crash in EarlyPerfInliner ("isCallerAndCalleeLayoutConstraintsCompatible")
            // when this file is compiled with -O or -Osize for the Mini AppClip
            // target. Annotating an explicit deinit with @_optimize(none) keeps
            // the rest of the module optimized while skipping the inliner pass
            // for this one function. Safe to remove on a future Swift toolchain.
            @_optimize(none)
            deinit {}

            override func viewDidAppear(_ animated: Bool) {
                super.viewDidAppear(animated)
                view.semanticContentAttribute = .forceRightToLeft
                navigationController?.view.semanticContentAttribute = .forceRightToLeft
            }

            override func viewWillDisappear(_ animated: Bool) {
                super.viewWillDisappear(animated)
                navigationController?.view.semanticContentAttribute = .unspecified
            }
        }
    }
}
