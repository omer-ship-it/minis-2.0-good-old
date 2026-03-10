import SwiftUI

// ✅ FINAL (as agreed):
// 1) Executive Brief (page 0): KEEP clean (hero + your Manager Summary / AI Insights). NO story list here.
//    - You can keep the setup card here.
//    - (Optional) Keep the 2-circle controls row (Menu + Cashpoint) near the hero.
// 2) Live Control (page 1): SHOW the TeslaStoryList (Cashpoint / Self Service / Mini App / Full App / Devices / Team).
// 3) Each row NAVIGATES to its own EMPTY module view (placeholders) — we’ll build each later.
//    - Cashpoint still goes to CashPointPushWrapper (real view).
//    - Menu stays accessible via setup card + optional controls row (real view).
//
// NOTE: This file assumes AnalyticsV1View, CashPointView, menuView, DashboardVM, ShopOption, MiniTint,
//       ordersPerHourSince8amIsrael(...) exist in your project.

struct Tesla3: View {

    let embedded: Bool
    init(embedded: Bool = false) { self.embedded = embedded }
    @State private var showCreateShopFlow = false
    @State private var showAnalytics = false

    // real flows
    @State private var showCashpoint = false
    @State private var showMenu = false

    // module placeholders (to build later)
    @State private var showSelfService = false
    @State private var showMiniApp = false
    @State private var showFullApp = false
    @State private var showDevices = false
    @State private var showTeam = false

    @Environment(\.dismiss) private var dismiss

    @AppStorage("dashboard.showSetupFromOnboarding")
    private var showSetupFromOnboarding: Bool = false

    var body: some View {
        Group {
            if embedded {
                content
                    .toolbar(.visible, for: .navigationBar)
                    .navigationBarBackButtonHidden(true)
            } else {
                NavigationStack {
                    content
                        .toolbar(.hidden, for: .navigationBar)
                }
            }
        }
    }

    private var content: some View {
        ZStack {

            RestaurantControlCenterMock(
                onOpenAnalytics: { showAnalytics = true },

                onOpenMenu: { showMenu = true },
                onOpenCashpoint: { showCashpoint = true },

                onCreateShop: { showCreateShopFlow = true },   // ✅ ADD THIS

                onOpenSelfService: { showSelfService = true },
                onOpenMiniApp: { showMiniApp = true },
                onOpenFullApp: { showFullApp = true },
                onOpenDevices: { showDevices = true },
                onOpenTeam: { showTeam = true },

                showSetupFromOnboarding: showSetupFromOnboarding,
                onDismissSetup: { showSetupFromOnboarding = false }
            )
            .preferredColorScheme(.dark)
            .padding(.top, embedded ? 60 : 0)

            // ✅ PUSH Analytics
            NavigationLink(
                destination: AnalyticsV1View().preferredColorScheme(.dark),
                isActive: $showAnalytics
            ) { EmptyView() }
            .hidden()

            // ✅ PUSH CashPoint (real)
            NavigationLink(
                destination: CashPointPushWrapper().preferredColorScheme(.dark),
                isActive: $showCashpoint
            ) { EmptyView() }
            .hidden()

            // ✅ PUSH Menu (real)
            NavigationLink(
                destination: menuView()
                    .preferredColorScheme(.dark)
                    .toolbar(.hidden, for: .navigationBar),
                isActive: $showMenu
            ) { EmptyView() }
            .hidden()
            NavigationLink(
                destination: FastlaneOnboardingMock {
                    // ✅ onExitOnboarding: for now just go back
                    showCreateShopFlow = false
                }
                .preferredColorScheme(.dark)
                .toolbar(.hidden, for: .navigationBar),
                isActive: $showCreateShopFlow
            ) { EmptyView() }
            .hidden()

            // ✅ EMPTY MODULE VIEWS (to build later)
            NavigationLink(destination: SelfServiceCashpointsView().preferredColorScheme(.dark), isActive: $showSelfService) { EmptyView() }
            NavigationLink(destination: MiniAppModuleView().preferredColorScheme(.dark), isActive: $showMiniApp) { EmptyView() }.hidden()
            NavigationLink(destination: FullAppModuleView().preferredColorScheme(.dark), isActive: $showFullApp) { EmptyView() }.hidden()
            NavigationLink(destination: DevicesModuleView().preferredColorScheme(.dark), isActive: $showDevices) { EmptyView() }.hidden()
            NavigationLink(destination: TeamModuleView().preferredColorScheme(.dark), isActive: $showTeam) { EmptyView() }.hidden()

            // ✅ Back button only when embedded (coming from onboarding)
            if embedded {
                VStack {
                    HStack {
                        Button { dismiss() } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.9))
                                .frame(width: 44, height: 44)
                                .background(.ultraThinMaterial)
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)

                        Spacer()
                    }
                    .padding(.leading, 14)
                    .padding(.top, 10)

                    Spacer()
                }
                .zIndex(9999)
            }
        }
    }
}

// MARK: - Root Dashboard


struct RestaurantControlCenterMock: View {

    let onOpenAnalytics: () -> Void

    // page 0 helpers
    let onOpenMenu: () -> Void
    let onOpenCashpoint: () -> Void
    let onCreateShop: () -> Void   // ✅ move here

    // page 1 (Live Control list)
    let onOpenSelfService: () -> Void
    let onOpenMiniApp: () -> Void
    let onOpenFullApp: () -> Void
    let onOpenDevices: () -> Void
    let onOpenTeam: () -> Void

    let showSetupFromOnboarding: Bool
    let onDismissSetup: () -> Void
    

    @State private var page: Int = 0
    @Namespace private var magic
    @StateObject private var vm = DashboardVM()

    @State private var shops: [ShopOption] = []
    @State private var selectedShop: ShopOption = .init(id: 12, name: "My shop")
    
    var body: some View {
        ZStack {
            LinearGradient(
                colors: page == 0
                ? [Color.black.opacity(0.98), Color.black.opacity(0.92)]
                : [Color.black.opacity(0.985), Color.black.opacity(0.88)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            LinearGradient(
                colors: [Color.black.opacity(0.45), .clear],
                startPoint: .top,
                endPoint: .center
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .opacity(page == 0 ? 0.9 : 1.0)
            .animation(.easeInOut(duration: 0.45), value: page)

            TabView(selection: $page) {

                // ✅ PAGE 0: Executive Brief (no story list here)
                ExecutiveBriefMock(
                    onTapAnalytics: onOpenAnalytics,
                    onTapMenu: onOpenMenu,
                    onTapCashpoint: onOpenCashpoint,
                    showSetupFromOnboarding: showSetupFromOnboarding,
                    onDismissSetup: onDismissSetup,
                    onCreateShop: onCreateShop,
                    magic: magic,
                    page: $page,
                    turnover: vm.turnover,
                    orders: vm.orders,
                    aov: vm.aov,
                    lastUpdatedAt: vm.lastUpdatedAt,
                    selectedShop: $selectedShop,
                    shops: shops
                )
                .tag(0)

                // ✅ PAGE 1: Live Control (Tesla story list lives here)
                LiveControlMock(
                    onTapAnalytics: onOpenAnalytics,

                    onTapCashpoint: onOpenCashpoint,
                    onTapSelfService: onOpenSelfService,
                    onTapMiniApp: onOpenMiniApp,
                    onTapFullApp: onOpenFullApp,
                    onTapDevices: onOpenDevices,
                    onTapTeam: onOpenTeam
                )
                .tag(1)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(.spring(response: 0.55, dampingFraction: 0.86), value: page)
        }
        .onAppear {
            let loadedOwner = OwnerShopsStore.load()

            // convert OwnerShop -> ShopOption (keep stable IDs if you want)
            let loaded: [ShopOption] = loadedOwner.enumerated().map { idx, s in
                ShopOption(id: 12 + idx, name: s.name)
            }

            if loaded.isEmpty {
                // create default only once
                let created = OwnerShopsStore.addShop(name: "My shop")
                shops = [ShopOption(id: 12, name: created.name)]
                selectedShop = shops[0]
            } else {
                shops = loaded
                // keep current selection if still exists; otherwise pick first
                if let match = loaded.first(where: { $0.name == selectedShop.name }) {
                    selectedShop = match
                } else {
                    selectedShop = loaded[0]
                }
            }

            vm.startPolling(miniAppId: selectedShop.id)
        }
       
        .onDisappear { vm.stopPolling() }
    }
}

// MARK: - PAGE 0: Executive Brief (keep clean)

private struct ExecutiveBriefMock: View {

    let onTapAnalytics: () -> Void
    let onTapMenu: () -> Void
    let onTapCashpoint: () -> Void

    let showSetupFromOnboarding: Bool
    let onDismissSetup: () -> Void
    let onCreateShop: () -> Void   // ✅ move here (after onDismissSetup)

    let magic: Namespace.ID
    @Binding var page: Int

    let turnover: Int
    let orders: Int
    let aov: Double
    let lastUpdatedAt: Date?

    @Binding var selectedShop: ShopOption
    let shops: [ShopOption]

    private let secondary = Color.white.opacity(0.86)

    var metaLine: String {
        let aovInt = Int(aov.rounded(.toNearestOrAwayFromZero))
        let oph = ordersPerHourSince8amIsrael(orders: orders)
        return "\(orders) orders · ₪\(aovInt) Avg  · \(String(format: "%.0f", oph))/hr"
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 18) {

                ShopTopBar(
                    selectedShop: $selectedShop,
                    shops: shops,
                    onCreateShop: onCreateShop
                )

                // ✅ One-time setup card (menu first)
                if showSetupFromOnboarding {
                    GlassCard(corner: 26) {
                        VStack(alignment: .leading, spacing: 12) {

                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Finish setup")
                                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                                        .foregroundStyle(.white.opacity(0.92))

                                    Text("Step 1 — Add your products")
                                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                                        .foregroundStyle(.white.opacity(0.70))
                                }

                                Spacer()

                                Button {
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    onDismissSetup()
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(.white.opacity(0.75))
                                        .frame(width: 28, height: 28)
                                        .background(.white.opacity(0.06))
                                        .clipShape(Circle())
                                }
                                .buttonStyle(.plain)
                            }

                            Text("Add 3–5 items and your Mini App + kiosks become ready.")
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.72))

                            HStack(spacing: 12) {

                                Button {
                                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                    onTapMenu()
                                    onDismissSetup()
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "menucard.fill")
                                            .font(.system(size: 14, weight: .bold))
                                        Text("Create Menu")
                                            .font(.system(size: 15, weight: .bold, design: .rounded))
                                    }
                                    .foregroundStyle(.black)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 48)
                                    .background(.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                }
                                .buttonStyle(.plain)

                                Button {
                                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                    onTapCashpoint()
                                    onDismissSetup()
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "hand.point.up.braille.fill")
                                            .font(.system(size: 14, weight: .bold))
                                        Text("Cashpoint")
                                            .font(.system(size: 15, weight: .bold, design: .rounded))
                                    }
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 48)
                                    .background(.white.opacity(0.10))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .stroke(.white.opacity(0.12), lineWidth: 1)
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                // ✅ HERO stays here
                FancyHeroHeader(
                    magic: magic,
                    turnover: turnover,
                    meta: metaLine,
                    monthlyText: "Projected 439k vs 372k",
                    deltaText: "+18%"
                )
                .padding(.top, 8)

                TeslaControlsRow(
                    onMenu: onTapMenu,
                    onCashpoint: onTapCashpoint,
                    onAnalytics: onTapAnalytics   // ✅ ADD
                )
                .padding(.top, 6)
                ManagerDailySummaryCard()
                    .padding(.top, 20)
                InsightsCard()
                    .padding(.top, 20)
                
                // ✅ your Manager Summary / AI Insights remain here (not included)

                Text("Swipe → Live Control")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(secondary)
                    .padding(.top, 6)
                    .padding(.bottom, 18)
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
        }
    }
}

// MARK: - PAGE 1: Live Control (Tesla list lives here)

private struct LiveControlMock: View {
    let onTapAnalytics: () -> Void

    let onTapCashpoint: () -> Void
    let onTapSelfService: () -> Void
    let onTapMiniApp: () -> Void
    let onTapFullApp: () -> Void
    let onTapDevices: () -> Void
    let onTapTeam: () -> Void

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 16) {

                MiniTopBar(title: "Live Control", onTapAnalytics: onTapAnalytics)

                TeslaStoryList(
                    onCashpoint: onTapCashpoint,
                    onSelfService: onTapSelfService,
                    onMiniApp: onTapMiniApp,
                    onFullApp: onTapFullApp,
                    onDevices: onTapDevices,
                    onTeam: onTapTeam,
                    cashpointSubtitle: "Ready • 2 iPads paired",
                    selfServiceSubtitle: "3 kiosks • locked mode",
                    miniAppSubtitle: "App Clip live • 1,240 opens",
                    fullAppSubtitle: "85 installed users",
                    devicesSubtitle: "3 devices • kiosk locked",
                    teamSubtitle: "Owner • 2 managers • 4 cashiers"
                )

                Spacer(minLength: 20)
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
        }
    }
}

// MARK: - Tesla Story List (conversion narrative + infrastructure)

private struct TeslaStoryList: View {
    let onCashpoint: () -> Void
    let onSelfService: () -> Void
    let onMiniApp: () -> Void
    let onFullApp: () -> Void
    let onDevices: () -> Void
    let onTeam: () -> Void

    let cashpointSubtitle: String
    let selfServiceSubtitle: String
    let miniAppSubtitle: String
    let fullAppSubtitle: String
    let devicesSubtitle: String
    let teamSubtitle: String

    var body: some View {
        VStack(spacing: 10) {
            ModuleRow(title: "Cashpoint", subtitle: cashpointSubtitle, icon: "hand.point.up.braille.fill", onTap: onCashpoint)
            ModuleRow(title: "Self Service Cashpoints", subtitle: selfServiceSubtitle, icon: "rectangle.and.hand.point.up.left.fill", onTap: onSelfService)
            ModuleRow(title: "Mini App", subtitle: miniAppSubtitle, icon: "qrcode", onTap: onMiniApp)
            ModuleRow(title: "Full App", subtitle: fullAppSubtitle, icon: "person.crop.circle.fill", onTap: onFullApp)

            Divider().background(Color.white.opacity(0.08)).padding(.vertical, 6)

            ModuleRow(title: "Devices", subtitle: devicesSubtitle, icon: "ipad.and.iphone", onTap: onDevices)
            ModuleRow(title: "Team", subtitle: teamSubtitle, icon: "person.3.fill", onTap: onTeam)
        }
    }
}
// MARK: - Dashboard Models

private struct ManagerEntry {
    let badge: RowBadge
    let title: String
    let message: String
}
private struct ManagerDailySummaryCard: View {

    private let secondary = Color.white.opacity(0.86)
    private let titleColor = Color.white

    // 🔹 Replace this later with real data from backend
    private let entries: [ManagerEntry] = []   // ← empty = show placeholder

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            HStack {
                Text("MANAGER SUMMARY")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(titleColor)

                Spacer()

                Text("Last 3 days")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(secondary)
            }

            if entries.isEmpty {

                // ✅ Elegant empty state
                VStack(alignment: .leading, spacing: 6) {

                    Text("No summaries yet.")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.75))

                    Text("Daily manager insights will appear here automatically as your system runs.")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .padding(.vertical, 8)

            } else {

                VStack(spacing: 10) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                        BriefRow(
                            badge: entry.badge,
                            title: entry.title,
                            message: entry.message,
                            rightLabel: "Read more ›"
                        )

                        if index < entries.count - 1 {
                            DividerHairline()
                        }
                    }
                }
            }
        }
    }
}
private struct AIInsight {
    let badge: RowBadge
    let title: String
    let message: String
}

private struct InsightsCard: View {

    private let secondary = Color.white.opacity(0.86)
    private let titleColor = Color.white

    // 🔹 Replace with real backend data later
    private let insights: [AIInsight] = []   // ← empty = show placeholder

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            HStack {
                Text("AI INSIGHTS")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(titleColor)

                Spacer()

                Text("Newest 3")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(secondary)
            }

            if insights.isEmpty {

                // ✅ Premium empty state
                VStack(alignment: .leading, spacing: 6) {

                    Text("System learning in progress.")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.75))

                    Text("AI insights will appear once enough activity is detected.")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .padding(.vertical, 8)

            } else {

                VStack(spacing: 10) {
                    ForEach(Array(insights.enumerated()), id: \.offset) { index, insight in
                        BriefRow(
                            badge: insight.badge,
                            title: insight.title,
                            message: insight.message,
                            rightLabel: "Read more ›"
                        )

                        if index < insights.count - 1 {
                            DividerHairline()
                        }
                    }
                }
            }
        }
    }
}

private enum RowBadge {
    case neutral
    case accent
    case warning

    var color: Color {
        switch self {
        case .neutral: return .white.opacity(0.10)
        case .accent:  return MiniTint.accent.opacity(0.22)
        case .warning: return Color(red: 1.00, green: 0.75, blue: 0.30).opacity(0.22)
        }
    }

    var stroke: Color {
        switch self {
        case .neutral: return .white.opacity(0.10)
        case .accent:  return MiniTint.accent.opacity(0.30)
        case .warning: return Color(red: 1.00, green: 0.75, blue: 0.30).opacity(0.30)
        }
    }
}

private struct BriefRow: View {
    let badge: RowBadge
    let title: String
    let message: String
    let rightLabel: String

    private let secondary = Color.white.opacity(0.86)
    private let bodyColor = Color.white.opacity(0.78)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {

                // tiny tint indicator (jewelry touch)
             
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(secondary)

                Spacer()

                Text(rightLabel)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(secondary)
            }

            Text(message)
                .font(.system(size: 13, weight: .regular, design: .rounded))
                .foregroundStyle(bodyColor)
                .lineLimit(3)
        }
    }
}




private struct ModuleRow: View {
    let title: String
    let subtitle: String
    let icon: String
    let onTap: () -> Void

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onTap()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 34, height: 34)
                    .background(.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))

                    Text(subtitle)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.30))
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .background(.white.opacity(0.06))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.white.opacity(0.08), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct DividerHairline: View {
    var body: some View {
        Rectangle()
            .fill(.white.opacity(0.10))
            .frame(height: 1)
            .padding(.vertical, 2)
    }
}


// MARK: - Empty module views (we will build later)


struct SelfServiceCashpointsView: View {
    @Environment(\.dismiss) private var dismiss

    // ✅ The only important control
    @State private var selfServiceEnabled: Bool = true

    // Mock states
    @State private var idleSeconds: Double = 30

    @State private var kiosks: [KioskDevice] = [
        .init(name: "Kiosk iPad 1",
              location: "Front counter",
              isOnline: true,
              battery: 0.78,
              lastSeen: Date(),
              locked: true),

        .init(name: "Kiosk iPad 2",
              location: "Entrance",
              isOnline: true,
              battery: 0.54,
              lastSeen: Date().addingTimeInterval(-120),
              locked: true),

        .init(name: "Kiosk iPad 3",
              location: "Patio",
              isOnline: false,
              battery: 0.21,
              lastSeen: Date().addingTimeInterval(-3600),
              locked: false)
    ]

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.black.opacity(0.98), Color.black.opacity(0.88)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 14) {

                    topBar
                    header
                    statsGrid
                    primaryControls
                    deviceList

                    Spacer(minLength: 24)
                }
                .padding(.horizontal, 18)
                .padding(.top, 10)
            }
        }
        
        .toolbar(.hidden, for: .navigationBar)
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            Spacer()

            Text("Self Service")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.88))

            Spacer()

            Image(systemName: "gearshape.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 44, height: 44)
                .opacity(0.9)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Self Service Cashpoints")
                .font(.system(size: 26, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)

            Text("Turn terminals on/off and manage kiosk iPads.")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.62))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }

    // MARK: - Stats

    private var statsGrid: some View {
        let cols = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
        let active = kiosks.filter(\.isOnline).count

        return LazyVGrid(columns: cols, spacing: 12) {
            StatCard(title: "Status", value: selfServiceEnabled ? "LIVE" : "OFF", icon: selfServiceEnabled ? "bolt.fill" : "bolt.slash.fill")
            StatCard(title: "Active kiosks", value: "\(active)/\(kiosks.count)", icon: "ipad.and.iphone")
            StatCard(title: "Orders today", value: selfServiceEnabled ? "143" : "—", icon: "cart.fill")
            StatCard(title: "Last activity", value: selfServiceEnabled ? "2m ago" : "—", icon: "clock.fill")
        }
    }

    // MARK: - Controls

    private var primaryControls: some View {
        GlassCard(corner: 22) {
            VStack(alignment: .leading, spacing: 14) {

                HStack {
                    Text("Controls")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))
                    Spacer()
                }

                // ✅ Main switch: Self Service ON/OFF
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Self Service")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.9))

                        Text(selfServiceEnabled ? "Accepting orders on kiosks" : "Kiosks are disabled")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.55))
                    }

                    Spacer()

                    Toggle("", isOn: $selfServiceEnabled)
                        .labelsHidden()
                        .tint(.blue)
                        .onChange(of: selfServiceEnabled) { _ in
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        }
                }

                // Pair / Add kiosk (still allowed; or you can disable when OFF)
                HStack(spacing: 12) {
                    ControlButton(
                        title: "Pair new kiosk",
                        icon: "qrcode.viewfinder",
                        style: .secondary
                    ) {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        
                        kiosks.insert(
                            KioskDevice(
                                name: "Kiosk iPad \(kiosks.count + 1)",
                                location: "Unassigned",
                                isOnline: true,
                                battery: 0.66,
                                lastSeen: Date(),
                                locked: true
                            ),
                            at: 0
                        )
                    }
                    // Idle timeout (only relevant when enabled)
                 
                }
            }
        }
    }

    // MARK: - Device list

    private var deviceList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Kiosks")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                Spacer()
                Text("\(kiosks.count)")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
            }

            ForEach(kiosks) { d in
                DeviceRow(device: d)
            }
        }
        .padding(.top, 2)
    }
}


// MARK: - Models

struct KioskDevice: Identifiable {
    let id = UUID()

    var name: String
    var location: String
    var isOnline: Bool
    var battery: Double
    var lastSeen: Date

    var locked: Bool   // ✅ ADD THIS
}

// MARK: - UI components

private struct GlassCard<Content: View>: View {
    var corner: CGFloat = 22
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(.white.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: corner, style: .continuous)
                            .stroke(.white.opacity(0.08), lineWidth: 1)
                    )
            )
    }
}

private struct StatCard: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        GlassCard(corner: 20) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 34, height: 34)
                    .background(.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                    Text(value)
                        .font(.system(size: 18, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))
                }

                Spacer()
            }
        }
    }
}

private enum ControlButtonStyle { case primary, secondary }

private struct ControlButton: View {
    let title: String
    let icon: String
    let style: ControlButtonStyle
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .bold))
                Text(title)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                Spacer()
            }
            .foregroundStyle(style == .primary ? .black : .white.opacity(0.9))
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(style == .primary ? .white : .white.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.white.opacity(style == .primary ? 0.0 : 0.10), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }
}

private struct DeviceRow: View {
    let device: KioskDevice

    private var statusText: String { device.isOnline ? "Online" : "Offline" }
    private var statusColor: Color { device.isOnline ? .green : .white.opacity(0.35) }
    private var batteryPct: Int { Int((device.battery * 100).rounded()) }

    private func relativeTime(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated   // "2m ago", "1h ago"
        return formatter.localizedString(for: date, relativeTo: Date())
    }
    var body: some View {
        GlassCard(corner: 20) {
            HStack(spacing: 12) {

                // status dot
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(device.name)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.92))

                        Text(statusText)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(device.isOnline ? 0.65 : 0.45))
                    }

                    Text("\(device.location) • last seen \(relativeTime(from: device.lastSeen))")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: device.locked ? "lock.fill" : "lock.open")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.75))

                        Text("\(batteryPct)%")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.75))
                    }

                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.25))
                }
            }
        }
    }
}



struct MiniAppModuleView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var isLive: Bool = true
    @State private var installOverlayEnabled: Bool = true
    @State private var link: String = "https://minis.studio/shop/12"

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.black.opacity(0.98), Color.black.opacity(0.88)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 14) {

                    topBar
                    header
                    statsGrid
                    controlsCard
                    conversionCard
                    linkCard

                    Spacer(minLength: 24)
                }
                .padding(.horizontal, 18)
                .padding(.top, 10)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            Button(action: { dismiss() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            Spacer()

            Text("Mini App")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.88))

            Spacer()

            Image(systemName: "qrcode")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 44, height: 44)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Customer Ordering Channel")
                .font(.system(size: 26, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)

            Text("App Clip / QR / link. Track opens → orders → installs.")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.62))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }

    // MARK: - Stats

    private var statsGrid: some View {
        let cols = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

        // mock numbers
        let opensToday = 1240
        let ordersToday = 380
        let conversion = Int((Double(ordersToday) / Double(max(opensToday, 1))) * 100)
        let installsToday = 85

        return LazyVGrid(columns: cols, spacing: 12) {
            MiniAppStatCard(title: "Status", value: isLive ? "LIVE" : "PAUSED", icon: isLive ? "bolt.fill" : "bolt.slash.fill")
            MiniAppStatCard(title: "Opens today", value: "\(opensToday)", icon: "eye.fill")
            MiniAppStatCard(title: "Orders today", value: "\(ordersToday)", icon: "cart.fill")
            MiniAppStatCard(title: "Conversion", value: "\(conversion)%", icon: "arrow.up.right.circle.fill")
            MiniAppStatCard(title: "Installs", value: "\(installsToday)", icon: "square.and.arrow.down.fill")
            MiniAppStatCard(title: "Top source", value: "QR", icon: "qrcode")
        }
    }

    // MARK: - Controls

    private var controlsCard: some View {
        MiniAppGlassCard(corner: 22) {
            VStack(alignment: .leading, spacing: 14) {

                HStack {
                    Text("Controls")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))
                    Spacer()
                }

                // Publish / Pause
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Mini App")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.9))
                        Text(isLive ? "Customers can order now" : "Ordering is paused")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.55))
                    }

                    Spacer()

                    Toggle("", isOn: $isLive)
                        .labelsHidden()
                        .tint(.blue)
                        .onChange(of: isLive) { _ in
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        }
                }

                // Primary actions
               

                // Full row action
                MiniAppControlButton(title: "Share Mini App", icon: "square.and.arrow.up", style: MiniAppControlButtonStyle.secondary) {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }
        }
    }

    // MARK: - Conversion

    private var conversionCard: some View {
        MiniAppGlassCard(corner: 22) {
            VStack(alignment: .leading, spacing: 14) {

                HStack {
                    Text("Convert to Full App")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))
                    Spacer()
                }

                Text("Goal: move customers from Cashpoints & App Clip → installed app for loyalty & push.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.65))

               
                MiniAppControlButton(title: "Set install incentive", icon: "gift.fill", style: MiniAppControlButtonStyle.secondary) {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }
        }
    }

    // MARK: - Link card

    private var linkCard: some View {
        MiniAppGlassCard(corner: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Mini App link")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))

                Text(link)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(2)

                Text("Tip: print QR on tables to multiply cashpoints across phones.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
    }
}

// MARK: - Mini App scoped components (no name collisions)

private struct MiniAppGlassCard<Content: View>: View {
    var corner: CGFloat = 22
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(.white.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: corner, style: .continuous)
                            .stroke(.white.opacity(0.08), lineWidth: 1)
                    )
            )
    }
}

private struct MiniAppStatCard: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        MiniAppGlassCard(corner: 20) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 34, height: 34)
                    .background(.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                    Text(value)
                        .font(.system(size: 18, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))
                }

                Spacer()
            }
        }
    }
}

private enum MiniAppControlButtonStyle { case primary, secondary }

private struct MiniAppControlButton: View {
    let title: String
    let icon: String
    let style: MiniAppControlButtonStyle
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .bold))
                Text(title)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                Spacer()
            }
            .foregroundStyle(style == .primary ? .black : .white.opacity(0.9))
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(style == .primary ? .white : .white.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.white.opacity(style == .primary ? 0.0 : 0.10), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }
}



struct FullAppModuleView: View {
    @Environment(\.dismiss) private var dismiss

    // Mock state
    @State private var fullAppLive: Bool = true
    @State private var loyaltyEnabled: Bool = true
    @State private var pushEnabled: Bool = true
    @State private var referralEnabled: Bool = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.black.opacity(0.98), Color.black.opacity(0.88)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 14) {
                    topBar
                    header
                    statsGrid
                    controlsCard
                    loyaltyCard
                  

                    Spacer(minLength: 24)
                }
                .padding(.horizontal, 18)
                .padding(.top, 10)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            Button(action: { dismiss() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            Spacer()

            Text("Full App")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.88))

            Spacer()

            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 44, height: 44)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Installed Users & Retention")
                .font(.system(size: 26, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)

            Text("Loyalty, repeat orders, and push engagement.")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.62))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }

    // MARK: - Stats

    private var statsGrid: some View {
        let cols = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

        // mock numbers
        let installed = 85
        let dau = 18
        let repeatRate = 41
        let pushOptIn = 58
        let members = 62

        return LazyVGrid(columns: cols, spacing: 12) {
            FullAppStatCard(title: "Status", value: fullAppLive ? "LIVE" : "OFF", icon: fullAppLive ? "bolt.fill" : "bolt.slash.fill")
            FullAppStatCard(title: "Installed users", value: "\(installed)", icon: "square.and.arrow.down.fill")
            FullAppStatCard(title: "DAU", value: "\(dau)", icon: "waveform.path.ecg")
            FullAppStatCard(title: "Members", value: "\(members)", icon: "person.2.fill")
            FullAppStatCard(title: "Repeat rate", value: "\(repeatRate)%", icon: "arrow.triangle.2.circlepath")
            FullAppStatCard(title: "Push opt-in", value: "\(pushOptIn)%", icon: "bell.badge.fill")
        }
    }

    // MARK: - Controls

    private var controlsCard: some View {
        FullAppGlassCard(corner: 22) {
            VStack(alignment: .leading, spacing: 14) {

                HStack {
                    Text("Controls")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))
                    Spacer()
                }

                // Full app live switch
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Full App")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.9))
                        Text(fullAppLive ? "Installed app is active" : "Full app features disabled")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.55))
                    }

                    Spacer()

                    Toggle("", isOn: $fullAppLive)
                        .labelsHidden()
                        .tint(.blue)
                        .onChange(of: fullAppLive) { _ in
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        }
                }

                // Push toggle
                FullAppControlButton(
                    title: "Push notification",
                    icon: "paperplane.fill",
                    style: FullAppControlButtonStyle.secondary
                ) {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }
        }
    }

    // MARK: - Loyalty

    private var loyaltyCard: some View {
        FullAppGlassCard(corner: 22) {
            VStack(alignment: .leading, spacing: 14) {

                HStack {
                    Text("Loyalty")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))
                    Spacer()
                }

                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Members program")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.9))
                        Text(loyaltyEnabled ? "Stamps / vouchers active" : "Off")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.55))
                    }

                    Spacer()

                    Toggle("", isOn: $loyaltyEnabled)
                        .labelsHidden()
                        .tint(.blue)
                        .onChange(of: loyaltyEnabled) { _ in
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                }

                // Full row action
                FullAppControlButton(
                    title: "Configure rewards",
                    icon: "gift.fill",
                    style: FullAppControlButtonStyle.secondary
                ) {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }
        }
    }

    // MARK: - Retention / Growth

   
}

// MARK: - Full App scoped components (no name collisions)

private struct FullAppGlassCard<Content: View>: View {
    var corner: CGFloat = 22
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(.white.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: corner, style: .continuous)
                            .stroke(.white.opacity(0.08), lineWidth: 1)
                    )
            )
    }
}

private struct FullAppStatCard: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        FullAppGlassCard(corner: 20) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 34, height: 34)
                    .background(.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                    Text(value)
                        .font(.system(size: 18, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))
                }

                Spacer()
            }
        }
    }
}

private enum FullAppControlButtonStyle { case primary, secondary }

private struct FullAppControlButton: View {
    let title: String
    let icon: String
    let style: FullAppControlButtonStyle
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .bold))
                Text(title)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                Spacer()
            }
            .foregroundStyle(style == .primary ? .black : .white.opacity(0.9))
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(style == .primary ? .white : .white.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.white.opacity(style == .primary ? 0.0 : 0.10), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }
}



private struct DevicesModuleView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var devices: [PairedDevice] = [
        .init(name: "iPad Front Counter", status: .online, lastSeen: Date().addingTimeInterval(-25), pairingCode: PairCode.make()),
        .init(name: "iPad Entrance",      status: .online, lastSeen: Date().addingTimeInterval(-120), pairingCode: PairCode.make()),
        .init(name: "iPad Patio",         status: .offline, lastSeen: Date().addingTimeInterval(-3600), pairingCode: PairCode.make())
    ]

    @State private var editingIndex: Int? = nil
    @State private var showDeviceSheet = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.black.opacity(0.98), Color.black.opacity(0.88)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 14) {

                    topBar
                    header

                    GlassCard(corner: 22) {
                        VStack(alignment: .leading, spacing: 10) {

                            HStack {
                                Text("Devices")
                                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.85))
                                Spacer()
                                Text("\(devices.count)")
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.55))
                            }

                            ForEach(Array(devices.enumerated()), id: \.element.id) { idx, d in
                                DevicesRow(device: d) {
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    editingIndex = idx
                                    showDeviceSheet = true
                                }
                            }

                            if devices.isEmpty {
                                Text("No devices yet. Tap + to add one.")
                                    .font(.system(size: 13, weight: .medium, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.55))
                                    .padding(.vertical, 8)
                            }
                        }
                    }

                    Spacer(minLength: 24)
                }
                .padding(.horizontal, 18)
                .padding(.top, 10)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showDeviceSheet) {
            DeviceEditPairSheet(
                // If editingIndex is nil => new device
                initialName: editingIndex.map { devices[$0].name } ?? "",
                initialCode: editingIndex.map { devices[$0].pairingCode } ?? PairCode.make(),
                onSave: { name, code in
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }

                    if let idx = editingIndex {
                        devices[idx].name = trimmed
                        devices[idx].pairingCode = code
                    } else {
                        devices.insert(
                            PairedDevice(
                                name: trimmed,
                                status: .offline,
                                lastSeen: Date(),
                                pairingCode: code
                            ),
                            at: 0
                        )
                    }

                    editingIndex = nil
                    showDeviceSheet = false
                },
                onDelete: {
                    if let idx = editingIndex {
                        devices.remove(at: idx)
                    }
                    editingIndex = nil
                    showDeviceSheet = false
                }
            )
            .presentationDetents([.height(520), .large])
            .presentationDragIndicator(.visible)
            .onDisappear {
                // reset draft context if user swipes down
                editingIndex = nil
            }
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            Spacer()

            Text("Devices")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.88))

            Spacer()

            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                editingIndex = nil // ✅ new device
                showDeviceSheet = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Pair iPads")
                .font(.system(size: 26, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)

            Text("Any iPad can be Cashpoint or Self Service.")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.62))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }
}

// MARK: - Device row

private struct DevicesRow: View {
    let device: PairedDevice
    let onTap: () -> Void

    private func relativeTime(from date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }

    private var dot: Color {
        switch device.status {
        case .online: return .green
        case .offline: return .white.opacity(0.35)
        }
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Circle().fill(dot).frame(width: 10, height: 10)

                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))

                    Text("Tap to pair • \(relativeTime(from: device.lastSeen))")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.25))
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .background(.white.opacity(0.06))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.white.opacity(0.08), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Edit + Pair sheet (ONE SHEET)

private struct DeviceEditPairSheet: View {
    @Environment(\.dismiss) private var dismiss

    let initialName: String
    let initialCode: String
    let onSave: (String, String) -> Void
    let onDelete: () -> Void

    @State private var name: String = ""
    @State private var code: String = ""
    @State private var method: Method = .qr

    @FocusState private var focusName: Bool

    enum Method: String, CaseIterable, Identifiable {
        case qr = "QR"
        case code = "Code"
        var id: String { rawValue }
    }

    private var isEditingExisting: Bool { !initialName.isEmpty }

    var body: some View {
        ZStack {
            Color.black.opacity(0.94).ignoresSafeArea()

            VStack(spacing: 14) {

                // Top bar
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(width: 40, height: 40)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Text(isEditingExisting ? "Device" : "Add device")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))

                    Spacer()

                    Button {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        onSave(name, code)
                    } label: {
                        Text("Save")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 14)
                            .frame(height: 40)
                            .background(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.white.opacity(0.25) : Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)

                GlassCard(corner: 18) {
                    VStack(alignment: .leading, spacing: 12) {

                        Text("Name")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.70))

                        DevicesNameField(text: $name)
                            .focused($focusName)

                        Divider().background(Color.white.opacity(0.08)).padding(.vertical, 6)

                        Text("Pairing")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.70))

                        PairingSegment(method: $method)

                        if method == .qr {
                            QRBox(code: code)
                        } else {
                            CodeBox(
                                code: code,
                                onCopy: {
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    UIPasteboard.general.string = code
                                },
                                onRegenerate: {
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    code = PairCode.make()
                                }
                            )
                        }

                        if isEditingExisting {
                            Divider().background(Color.white.opacity(0.08)).padding(.vertical, 6)

                            Button {
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                onDelete()
                            } label: {
                                Text("Remove device")
                                    .font(.system(size: 14, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 44)
                                    .background(Color.red.opacity(0.25))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .stroke(Color.red.opacity(0.35), lineWidth: 1)
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 16)

                Spacer()
            }
        }
        .onAppear {
            name = initialName.isEmpty ? "" : initialName
            code = initialCode.isEmpty ? PairCode.make() : initialCode
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { focusName = !isEditingExisting }
        }
    }
}

// MARK: - Sheet UI bits (scoped names)

private struct DevicesNameField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "ipad")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.65))

            TextField("Device name (e.g. iPad Front Counter)", text: $text)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled(true)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(.white.opacity(0.06))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.white.opacity(0.10), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct PairingSegment: View {
    @Binding var method: DeviceEditPairSheet.Method

    var body: some View {
        HStack(spacing: 10) {
            ForEach(DeviceEditPairSheet.Method.allCases) { m in
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    method = m
                } label: {
                    Text(m.rawValue)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(method == m ? .black : .white.opacity(0.85))
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(method == m ? Color.white : Color.white.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.white.opacity(0.10), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct QRBox: View {
    let code: String

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.white.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(.white.opacity(0.10), lineWidth: 1)
                    )

                VStack(spacing: 10) {
                    Image(systemName: "qrcode")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))

                    Text(code)
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.65))
                }
            }
            .frame(width: 150, height: 150)

            VStack(alignment: .leading, spacing: 8) {
                Text("Scan to pair")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.75))

                Text("On the iPad: Fastlane → Pair Device → Scan.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)

                Text("If camera is blocked, use Code.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
            }

            Spacer()
        }
        .padding(.top, 2)
    }
}

private struct CodeBox: View {
    let code: String
    let onCopy: () -> Void
    let onRegenerate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {

            HStack(spacing: 10) {
                Text(code)
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    .background(.white.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(.white.opacity(0.10), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                Button(action: onCopy) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(width: 44, height: 44)
                        .background(.white.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(.white.opacity(0.10), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)

                Button(action: onRegenerate) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(width: 44, height: 44)
                        .background(.white.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(.white.opacity(0.10), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            Text("Enter this code on the iPad to pair.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
        }
        .padding(.top, 2)
    }
}

// MARK: - Model

private struct PairedDevice: Identifiable {
    let id = UUID()
    var name: String
    var status: PairedDeviceStatus
    var lastSeen: Date
    var pairingCode: String
}

private enum PairedDeviceStatus {
    case online, offline
}

// MARK: - Pair code generator
private enum PairCode {
    static func make() -> String {
        let chars = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<6).compactMap { _ in chars.randomElement() })
    }
}

import SwiftUI
import UIKit

// MARK: - Team (Minimal + Pairing like Devices)

private struct TeamModuleView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var members: [TeamMember] = [
        .init(name: "Omer", role: .admin, lastActive: Date().addingTimeInterval(-60), inviteCode: TeamInviteCode.make()),
        .init(name: "Yael", role: .manager, lastActive: Date().addingTimeInterval(-600), inviteCode: TeamInviteCode.make()),
        .init(name: "Noam", role: .teamMember, lastActive: Date().addingTimeInterval(-3600), inviteCode: TeamInviteCode.make())
    ]

    @State private var editingIndex: Int? = nil
    @State private var showSheet = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.black.opacity(0.98), Color.black.opacity(0.88)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 14) {

                    topBar
                    header

                    GlassCard(corner: 22) {
                        VStack(alignment: .leading, spacing: 10) {

                            HStack {
                                Text("Team")
                                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.85))
                                Spacer()
                                Text("\(members.count)")
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.55))
                            }

                            ForEach(Array(members.enumerated()), id: \.element.id) { idx, m in
                                TeamRow(member: m) {
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    editingIndex = idx
                                    showSheet = true
                                }
                            }

                            if members.isEmpty {
                                Text("No team members yet. Tap + to add.")
                                    .font(.system(size: 13, weight: .medium, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.55))
                                    .padding(.vertical, 8)
                            }
                        }
                    }

                    Spacer(minLength: 24)
                }
                .padding(.horizontal, 18)
                .padding(.top, 10)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showSheet) {
            TeamEditPairSheet(
                initialName: editingIndex.map { members[$0].name } ?? "",
                initialRole: editingIndex.map { members[$0].role } ?? .teamMember,
                initialCode: editingIndex.map { members[$0].inviteCode } ?? TeamInviteCode.make(),
                isEditing: editingIndex != nil,
                onSave: { name, role, code in
                    let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !clean.isEmpty else { return }

                    if let idx = editingIndex {
                        members[idx].name = clean
                        members[idx].role = role
                        members[idx].inviteCode = code
                        members[idx].lastActive = Date()
                    } else {
                        members.insert(
                            TeamMember(name: clean, role: role, lastActive: Date(), inviteCode: code),
                            at: 0
                        )
                    }

                    editingIndex = nil
                    showSheet = false
                },
                onDelete: {
                    if let idx = editingIndex {
                        members.remove(at: idx)
                    }
                    editingIndex = nil
                    showSheet = false
                }
            )
            .presentationDetents([.height(560), .large])
            .presentationDragIndicator(.visible)
            .onDisappear { editingIndex = nil }
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            Spacer()

            Text("Team")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.88))

            Spacer()

            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                editingIndex = nil
                showSheet = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Roles & Pairing")
                .font(.system(size: 26, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)

            Text("Pair admins and staff with QR or code.")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.62))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }
}

// MARK: - Row

private struct TeamRow: View {
    let member: TeamMember
    let onTap: () -> Void

    private func relativeTime(from date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: member.role.icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 34, height: 34)
                    .background(.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(member.name)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))

                    Text("\(member.role.title) • active \(relativeTime(from: member.lastActive))")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.25))
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .background(.white.opacity(0.06))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.white.opacity(0.08), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Sheet (Name + Role + Pairing)

private struct TeamEditPairSheet: View {
    let initialName: String
    let initialRole: TeamRole
    let initialCode: String
    let isEditing: Bool
    let onSave: (String, TeamRole, String) -> Void
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var role: TeamRole = .teamMember
    @State private var code: String = ""
    @State private var method: Method = .qr

    @FocusState private var focusName: Bool

    enum Method: String, CaseIterable, Identifiable {
        case qr = "QR"
        case code = "Code"
        var id: String { rawValue }
    }

    private var canSave: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        ZStack {
            Color.black.opacity(0.94).ignoresSafeArea()

            VStack(spacing: 14) {

                // Top bar
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(width: 40, height: 40)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Text(isEditing ? "Member" : "Add member")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))

                    Spacer()

                    Button {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        onSave(name, role, code)
                    } label: {
                        Text("Save")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 14)
                            .frame(height: 40)
                            .background(canSave ? Color.white : Color.white.opacity(0.25))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSave)
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)

                GlassCard(corner: 18) {
                    VStack(alignment: .leading, spacing: 12) {

                        // Name
                        Text("Name")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.70))

                        TeamNameField(text: $name)
                            .focused($focusName)

                        Divider().background(Color.white.opacity(0.08)).padding(.vertical, 6)

                        // Role
                        Text("Role")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.70))

                        RoleChips(selected: $role)

                        Text(role.help)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.55))

                        Divider().background(Color.white.opacity(0.08)).padding(.vertical, 6)

                        // Pairing
                        Text("Pairing")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.70))

                        PairingChips(method: $method)

                        if method == .qr {
                            TeamQRBox(code: code)
                        } else {
                            TeamCodeBox(
                                code: code,
                                onCopy: {
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    UIPasteboard.general.string = code
                                },
                                onRegenerate: {
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    code = TeamInviteCode.make()
                                }
                            )
                        }

                        if isEditing {
                            Divider().background(Color.white.opacity(0.08)).padding(.vertical, 6)

                            Button {
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                onDelete()
                            } label: {
                                Text("Remove member")
                                    .font(.system(size: 14, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 44)
                                    .background(Color.red.opacity(0.25))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .stroke(Color.red.opacity(0.35), lineWidth: 1)
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 16)

                Spacer()
            }
        }
        .onAppear {
            name = initialName
            role = initialRole
            code = initialCode.isEmpty ? TeamInviteCode.make() : initialCode
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                focusName = !isEditing
            }
        }
    }
}

// MARK: - Sheet components

private struct TeamNameField: View {
    @Binding var text: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.65))

            TextField("Full name", text: $text)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled(true)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(.white.opacity(0.06))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.white.opacity(0.10), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct RoleChips: View {
    @Binding var selected: TeamRole
    var body: some View {
        HStack(spacing: 10) {
            ForEach(TeamRole.allCases) { r in
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    selected = r
                } label: {
                    Text(r.short)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(selected == r ? .black : .white.opacity(0.85))
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(selected == r ? Color.white : Color.white.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.white.opacity(0.10), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct PairingChips: View {
    @Binding var method: TeamEditPairSheet.Method
    var body: some View {
        HStack(spacing: 10) {
            ForEach(TeamEditPairSheet.Method.allCases) { m in
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    method = m
                } label: {
                    Text(m.rawValue)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(method == m ? .black : .white.opacity(0.85))
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(method == m ? Color.white : Color.white.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.white.opacity(0.10), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct TeamQRBox: View {
    let code: String
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.white.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(.white.opacity(0.10), lineWidth: 1)
                    )

                VStack(spacing: 10) {
                    Image(systemName: "qrcode")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))

                    Text(code)
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.65))
                }
            }
            .frame(width: 150, height: 150)

            VStack(alignment: .leading, spacing: 8) {
                Text("Scan to join")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.75))

                Text("On the iPhone: open Fastlane → Join Team → Scan.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)

                Text("If camera blocked, use Code.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
            }

            Spacer()
        }
        .padding(.top, 2)
    }
}

private struct TeamCodeBox: View {
    let code: String
    let onCopy: () -> Void
    let onRegenerate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(code)
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    .background(.white.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(.white.opacity(0.10), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                Button(action: onCopy) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(width: 44, height: 44)
                        .background(.white.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(.white.opacity(0.10), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)

                Button(action: onRegenerate) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(width: 44, height: 44)
                        .background(.white.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(.white.opacity(0.10), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            Text("Enter this code to join as \(codeRoleHint).")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
        }
        .padding(.top, 2)
    }

    private var codeRoleHint: String { "team" }
}

// MARK: - Models

private struct TeamMember: Identifiable {
    let id = UUID()
    var name: String
    var role: TeamRole
    var lastActive: Date
    var inviteCode: String
}

private enum TeamRole: String, CaseIterable, Identifiable {
    case admin
    case manager
    case teamMember

    var id: String { rawValue }

    var title: String {
        switch self {
        case .admin: return "Admin"
        case .manager: return "Manager"
        case .teamMember: return "Team member"
        }
    }

    var short: String {
        switch self {
        case .admin: return "Admin"
        case .manager: return "Manager"
        case .teamMember: return "Team"
        }
    }

    var icon: String {
        switch self {
        case .admin: return "sparkles"
        case .manager: return "briefcase.fill"
        case .teamMember: return "person.fill"
        }
    }

    var help: String {
        switch self {
        case .admin: return "Can change settings, pair devices, and manage permissions."
        case .manager: return "Can run shifts and operate Cashpoint."
        case .teamMember: return "Can take orders on Cashpoint (limited access)."
        }
    }
}

// MARK: - Invite code generator
private enum TeamInviteCode {
    static func make() -> String {
        let chars = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<6).compactMap { _ in chars.randomElement() })
    }
}

// MARK: - CashPoint wrapper (your existing)
struct CashPointPushWrapper: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("cashpoint.pushMode") private var cashpointPushMode: Bool = false

    var body: some View {
        ZStack {
            CashPointView()
                .preferredColorScheme(.dark)

            VStack {
                HStack {
                    Button(action: {
                        cashpointPushMode = false
                        dismiss()
                    }) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.86))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    Spacer()
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
        }
        .onAppear { cashpointPushMode = true }
        .onDisappear { cashpointPushMode = false }
    }
}

// MARK: - Top bars + hero + shared card

private struct ShopTopBar: View {
    @Binding var selectedShop: ShopOption
    let shops: [ShopOption]
    let onCreateShop: () -> Void   // ✅ ADD

    private let secondary = Color.white.opacity(0.86)

    var body: some View {
        HStack(alignment: .center) {

            Menu {
                ForEach(shops) { shop in
                    Button {
                        selectedShop = shop
                    } label: {
                        Text(shop.name)
                    }
                }

                Divider()

                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onCreateShop()
                } label: {
                    Label("Create a shop", systemImage: "plus")
                }
            } label: {
                HStack(spacing: 6) {
                    Text("\(selectedShop.name) today")
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundStyle(secondary)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 6)
    }
}

private struct MiniTopBar: View {
    let title: String
    let onTapAnalytics: () -> Void

    private let secondary = Color.white.opacity(0.86)

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(secondary)

            Spacer()

            Button { onTapAnalytics() } label: {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(secondary)
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 6)
    }
}

private struct FancyHeroHeader: View {
    let magic: Namespace.ID
    let turnover: Int
    let meta: String
    let monthlyText: String
    let deltaText: String

    private let secondary = Color.white.opacity(0.86)
    private let bodySoft  = Color.white.opacity(0.74)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(turnover, format: .number)
                .font(.system(size: 66, weight: .regular, design: .rounded))
                .monospacedDigit()
                .tracking(-0.9)
                .foregroundStyle(.white)
                .contentTransition(.numericText())
                .animation(.easeInOut(duration: 0.25), value: turnover)

            Text(meta)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(secondary)

            Text(deltaText)
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .foregroundStyle(MiniTint.delta(deltaText))
                .padding(.top, 10)

            HStack(spacing: 20) { Text(monthlyText) }
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(bodySoft)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PlaceholderModuleView: View {
    let title: String
    let subtitle: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 14) {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)

                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)

                Spacer()

                Text(title)
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)

                Text(subtitle)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                Spacer()
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}

private struct TeslaControlsRow: View {
    let onMenu: () -> Void
    let onCashpoint: () -> Void
    let onAnalytics: () -> Void   // ✅ ADD

    var body: some View {
        HStack(spacing: 34) {
            TeslaControlButton(title: "MENU", systemImage: "menucard.fill", action: onMenu)
            TeslaControlButton(title: "CASHPOINT", systemImage: "hand.point.up.braille.fill", action: onCashpoint)
            TeslaControlButton(title: "ANALYTICS", systemImage: "chart.line.uptrend.xyaxis", action: onAnalytics) // ✅ ADD
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }
}

private struct TeslaControlButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            VStack(spacing: 8) {

                // TEXT ABOVE (smaller)
                Text(title)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.65))
                    .tracking(1.0)

                // TESLA-STYLE CIRCLE
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.05))

                    Circle()
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)

                    Image(systemName: systemImage)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                }
                .frame(width: 56, height: 56)
            }
        }
        .buttonStyle(.plain)
    }
}

