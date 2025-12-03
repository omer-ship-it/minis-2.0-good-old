import Combine
import SwiftUI
import Kingfisher

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
struct HomeView: View {
    @State private var referrals: [MiniReferral] = []
    @State private var selectedFilter: TabFilter = .all
    @State private var selectedIndex: Int = 0
    @State private var showStudio = false
    @State private var showMenu = false
    @State private var provisionalReloadCancellable: AnyCancellable?
    @State private var showWelcome = false
    @AppStorage("launchStudioOnce") private var launchStudioOnce: Bool = false
    @AppStorage("launchMenuOnce") private var launchMenuOnce: Bool = false
    @AppStorage("shopId") private var shopId: String = "0"
    @State private var openedDefaultMiniOnce = false
    @State private var showQR = false
    @Namespace private var underlineNS
    @State private var openedFallbackOnce = false

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
        ZStack {
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
                                onOpen: { r in
                                    resetShopUserDefaultsToDefaults()
                                    UserDefaults.standard.set(String(r.miniAppId), forKey: "shopId")
                                    withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                                        let isMiniMe = (r.kind == .miniMe)
                                        showStudio = isMiniMe
                                        showMenu   = !isMiniMe
                                    }
                                }
                            )
                            .tag(idx)
                        }
                    }
                    .ignoresSafeArea(edges: .bottom)
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .animation(.interactiveSpring(response: 0.35, dampingFraction: 0.9), value: selectedIndex)
                    .onChange(of: selectedIndex) { selectedFilter = tab(at: $0) }
                    .onChange(of: selectedFilter) {
                        let idx = index(of: $0)
                        if idx != selectedIndex {
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) {
                                selectedIndex = idx
                            }
                        }
                    }
                }
            }

            
        }
        .environment(\.layoutDirection, .leftToRight)
        .onAppear {
            reloadReferrals()

            if launchStudioOnce { showStudio = true; launchStudioOnce = false }
            if launchMenuOnce  { showMenu  = true; launchMenuOnce  = false }

            // 👇 Open MiniApp 12 automatically on first launch of HomeView
            if !openedDefaultMiniOnce {
                openedDefaultMiniOnce = true

                resetShopUserDefaultsToDefaults()
                shopId = "12"
                UserDefaults.standard.set("12", forKey: "shopId")

                withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                    showMenu = true
                }
            }

            selectedIndex = index(of: selectedFilter)
        }
        .onChange(of: launchStudioOnce) { if $0 { showStudio = true; launchStudioOnce = false } }
        .onChange(of: launchMenuOnce)  { if $0 { showMenu  = true; launchMenuOnce  = false } }
        .onChange(of: referrals.map { "\($0.miniAppId)#\($0.kind.rawValue)#\($0.title)" }) { _ in
            let idx = min(selectedIndex, max(0, tabs.count - 1))
            selectedIndex = idx
            selectedFilter = tab(at: idx)
        }
        .onChange(of: showStudio) { $0 ? startProvisionalReloads() : stopProvisionalReloads() }
        .onChange(of: showMenu)   { $0 ? startProvisionalReloads() : stopProvisionalReloads() }
       

        .fullScreenCover(isPresented: $showMenu, onDismiss: {
            stopProvisionalReloads()
            reloadReferrals()
        }) {
            ForceRTL {
                NavigationStack {
                    HomeView()   // or MenuCanvasContainer(header: { MenuHeaderView() })
                        .navigationBarTitleDisplayMode(.inline)
                        .environment(
                            \.layoutDirection,
                            (UserDefaults.standard.string(forKey: "direction") == "rtl")
                            ? .rightToLeft
                            : .leftToRight
                        )
                }
            }
        }
    }

    private func reloadReferrals() {
        self.referrals = loadAllMiniReferralsFromAppGroup()
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

private struct TabsBarView: View {
    let tabs: [TabFilter]
    @Binding var selectedIndex: Int
    @Binding var selectedFilter: TabFilter
    let underlineNS: Namespace.ID
    @Binding var showQR: Bool

    var body: some View {
        let selectedColor: Color = .black
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

private struct TabPageView: View {
    let items: [MiniReferral]
    let onOpen: (MiniReferral) -> Void

    var body: some View {
        ScrollView {
            if items.isEmpty {
                VStack(spacing: 8) {
                    Spacer(minLength: 40)
                    Text("No items")
                        .foregroundColor(.secondary)
                        .font(.system(size: 16, weight: .regular))
                    Spacer(minLength: 40)
                }
            } else {
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

private struct RoundedCorners: Shape {
    var tl: CGFloat = 0
    var tr: CGFloat = 0
    var bl: CGFloat = 0
    var br: CGFloat = 0
    
    func path(in rect: CGRect) -> Path {
        var path = Path()

        let w = rect.width
        let h = rect.height

        let tr = min(min(self.tr, h/2), w/2)
        let tl = min(min(self.tl, h/2), w/2)
        let bl = min(min(self.bl, h/2), w/2)
        let br = min(min(self.br, h/2), w/2)

        path.move(to: CGPoint(x: w/2.0, y: 0))
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
        Button {
            onOpen(referral)
        } label: {
            VStack(spacing: 0) {
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
                .background(Color(.systemBackground))
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
}

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
            if !seen.contains(key) { seen.insert(key); unique.append(r) }
        }
        return unique
    }

    if let data = defaults?.data(forKey: "lastMiniReferralJSON"),
       let single = try? JSONDecoder().decode(MiniReferral.self, from: data) {
        return [single]
    }
    return []
}



struct ForceRTL<Content: View>: View {
    let content: Content
    init(@ViewBuilder _ content: () -> Content) { self.content = content() }

    var body: some View {
        content
            .environment(\.layoutDirection, .rightToLeft)
            .background(SemanticHost())
    }

    private struct SemanticHost: UIViewControllerRepresentable {
        func makeUIViewController(context: Context) -> UIViewController {
            Controller()
        }
        func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
        final class Controller: UIViewController {
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
