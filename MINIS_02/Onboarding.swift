import SwiftUI

// MARK: - Fastlane Instagram-Style Onboarding (Single File Mock)
// ✅ Uses in-file NavigationLink pushes (no root routing needed).
// ✅ One trailing closure only: `onExitOnboarding()`
// ✅ Tappable routes push to:
//    - Dashboard  -> Tesla3()
//    - Menu       -> menuView()
//    - Cashpoint  -> CashPointView()   (or swap to CashPointPushWrapper if you prefer)
//    - Self Order -> menuView()        (same view; sets menu.mode = "self")
//
// NOTE: This file assumes Tesla3, menuView, CashPointView exist in your project.

struct FastlaneOnboardingMock: View {

    /// Called ONCE when user leaves onboarding by tapping any route button.
    /// Use this to persist "didFinishOnboarding = true" etc.
    let onExitOnboarding: () -> Void

    @State private var step: Int = 0

    // captured info (for later backend wiring)
    @State private var businessName: String = ""
    @State private var category: BusinessCategory? = nil

    // ✅ route push
    private enum Route: Hashable { case dashboard, menu, cashpoint, selfOrder }
    @State private var route: Route? = nil

    // ✅ optional: tell menuView what “mode” to run in
    // "owner" | "self" | "kiosk" etc (you can choose your own values)
    @AppStorage("menu.mode") private var menuMode: String = "owner"

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                Group {
                    switch step {
                    case 0:
                        WelcomeStep { next() }

                    case 1:
                        BusinessNameStep(name: $businessName) { next() }

                    case 2:
                        CategoryStep(selected: $category) { next() }

                    case 3:
                        CreatingSystemStep(
                            businessName: businessName.isEmpty ? "Your business" : businessName,
                            category: category?.title ?? "Cafe"
                        ) { next() }

                   

                    default:
                        EmptyView()
                    }
                }
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .trailing)),
                    removal: .opacity.combined(with: .move(edge: .leading))
                ))
                .animation(.easeInOut(duration: 0.32), value: step)

                // ✅ Hidden push navigation (bulletproof; same pattern as Tesla3)
                Group {
                    NavigationLink(
                        tag: Route.dashboard,
                        selection: $route
                    ) {
                        Tesla3()
                            .preferredColorScheme(.dark)
                            .toolbar(.hidden, for: .navigationBar)
                    } label: { EmptyView() }
                    .hidden()

                    NavigationLink(
                        tag: Route.menu,
                        selection: $route
                    ) {
                        menuView()
                            .preferredColorScheme(.dark)
                            .toolbar(.hidden, for: .navigationBar)
                    } label: { EmptyView() }
                    .hidden()

                    NavigationLink(
                        tag: Route.cashpoint,
                        selection: $route
                    ) {
                        // If you prefer your safe wrapper, swap this to CashPointPushWrapper()
                        CashPointView()
                            .preferredColorScheme(.dark)
                            .toolbar(.hidden, for: .navigationBar)
                    } label: { EmptyView() }
                    .hidden()

                    NavigationLink(
                        tag: Route.selfOrder,
                        selection: $route
                    ) {
                        menuView()
                            .preferredColorScheme(.dark)
                            .toolbar(.hidden, for: .navigationBar)
                    } label: { EmptyView() }
                    .hidden()
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
    }

    private func next() {
        withAnimation {
            if step == 3 {
                // ✅ Append (or keep existing if same name) instead of overwriting
                _ = OwnerShopsStore.addShop(name: businessName)

                go(.dashboard)   // ✅ auto-enter dashboard after “Creating System”
            } else {
                step = min(step + 1, 4)
            }
        }
    }

    private func go(_ r: Route) {
        // ✅ mark onboarding done ONCE the user leaves it
        onExitOnboarding()

        // ✅ set menu mode depending on which route they chose
        switch r {
        case .menu:
            menuMode = "owner"
        case .selfOrder:
            menuMode = "self"
        default:
            break
        }

        route = r
    }
}

// MARK: - Models

enum BusinessCategory: String, CaseIterable, Identifiable {
    case cafe
    case restaurant
    case bakery
    case bar
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cafe: return "Cafe"
        case .restaurant: return "Restaurant"
        case .bakery: return "Bakery"
        case .bar: return "Bar"
        case .other: return "Other"
        }
    }

    var systemImage: String {
        switch self {
        case .cafe: return "cup.and.saucer.fill"
        case .restaurant: return "fork.knife"
        case .bakery: return "birthday.cake.fill"
        case .bar: return "wineglass.fill"
        case .other: return "sparkles"
        }
    }
}

// MARK: - Step 0: Welcome

private struct WelcomeStep: View {
    let onNext: () -> Void
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 26) {
            Spacer()

            VStack(spacing: 10) {
                Text("FASTLANE")
                    .font(.system(size: 46, weight: .heavy, design: .rounded))
                    .foregroundColor(.white)
                    .tracking(1.5)

                Text("Build your full iOS business system in minutes.")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 34)

                Text("Cashpoint • Self Service • MiniApps")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.45))
                    .padding(.top, 6)
            }

            Spacer()

            FLPrimaryButton(title: "Get Started", enabled: true) {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                onNext()
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 34)

            Text("Swipe-free • One tap per step")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.35))
                .padding(.bottom, 10)
                .scaleEffect(pulse ? 1.02 : 0.98)
                .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: pulse)
        }
        .onAppear { pulse = true }
    }
}

// MARK: - Step 1: Business name

private struct BusinessNameStep: View {
    @Binding var name: String
    let onNext: () -> Void
    @FocusState private var focusName: Bool

    var body: some View {
        VStack(spacing: 18) {
            Spacer()

            VStack(spacing: 10) {
                Text("What’s your business called?")
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)

                Text("This will appear on your menu, receipts & kiosk.")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 34)
            }

            FLTextField(placeholder: "Business name", text: $name)
                .padding(.horizontal, 22)
                .focused($focusName)

            Spacer()

            FLPrimaryButton(
                title: "Continue",
                enabled: !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ) {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                onNext()
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 34)
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { focusName = true }
        }
    }
}

// MARK: - Step 2: Category

private struct CategoryStep: View {
    @Binding var selected: BusinessCategory?
    let onNext: () -> Void

    private let cols = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            VStack(spacing: 10) {
                Text("Choose a category")
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .foregroundColor(.white)

                Text("We’ll generate a starter menu you can edit.")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.6))
            }
            .padding(.horizontal, 22)

            LazyVGrid(columns: cols, spacing: 12) {
                ForEach(BusinessCategory.allCases) { cat in
                    CategoryCard(cat: cat, selected: selected == cat)
                        .onTapGesture {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                                selected = cat
                            }
                        }
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 6)

            Spacer()

            FLPrimaryButton(title: "Continue", enabled: selected != nil) {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                onNext()
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 34)
        }
    }

    private struct CategoryCard: View {
        let cat: BusinessCategory
        let selected: Bool

        var body: some View {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(selected ? 0.16 : 0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.white.opacity(selected ? 0.22 : 0.10), lineWidth: 1)
                    )

                VStack(spacing: 10) {
                    Image(systemName: cat.systemImage)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.white.opacity(0.92))

                    Text(cat.title)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(.white.opacity(0.92))
                }

                if selected {
                    VStack {
                        HStack {
                            Spacer()
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(.green)
                        }
                        Spacer()
                    }
                    .padding(12)
                }
            }
            .frame(height: 120)
            .scaleEffect(selected ? 1.02 : 1.0)
            .animation(.spring(response: 0.28, dampingFraction: 0.86), value: selected)
        }
    }
}

// MARK: - Step 3: Creating System (animated)

private struct CreatingSystemStep: View {
    let businessName: String
    let category: String
    let onComplete: () -> Void

    @State private var spin = false
    @State private var step = 0

    private var steps: [String] {
        [
            "Creating dashboard…",
            "Creating menu…",
            "Creating Cashpoint…",
            "Creating Self Service mode…",
            "Publishing MiniApp…"
        ]
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            ZStack {
                Circle()
                    .trim(from: 0.15, to: 0.85)
                    .stroke(.white.opacity(0.18), lineWidth: 8)
                    .frame(width: 110, height: 110)

                Circle()
                    .trim(from: 0.20, to: 0.62)
                    .stroke(.white, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .frame(width: 110, height: 110)
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(.linear(duration: 1.0).repeatForever(autoreverses: false), value: spin)

                Image(systemName: "sparkles")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundColor(.white)
            }

            VStack(spacing: 8) {
                Text(businessName)
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                    .foregroundColor(.white)

                Text("\(category) • Fastlane OS")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.6))
            }
            .padding(.top, 6)

            VStack(spacing: 10) {
                ForEach(steps.indices, id: \.self) { i in
                    HStack(spacing: 10) {
                        Image(systemName: i < step ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(i < step ? .green : .white.opacity(0.25))

                        Text(steps[i])
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundColor(.white.opacity(i <= step ? 0.9 : 0.35))

                        Spacer()
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 10)

            Spacer()

            Text("Mock only. Wire your create-shop API here.")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.28))
                .padding(.bottom, 22)
        }
        .onAppear {
            spin = true
            let tick: Double = 0.7

            for i in 1...steps.count {
                DispatchQueue.main.asyncAfter(deadline: .now() + (Double(i) * tick)) {
                    withAnimation(.easeInOut(duration: 0.22)) { step = i }
                    if i == steps.count {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            onComplete()
                        }
                    }
                }
            }
        }
    }
}



// MARK: - Shared UI components

private struct FLTextField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "building.2.fill")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white.opacity(0.55))

            TextField(placeholder, text: $text)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled(true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color.white.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct FLPrimaryButton: View {
    let title: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(enabled ? Color.white : Color.white.opacity(0.25))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.9)
    }
}

struct OwnerShop: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
}

enum OwnerShopsStore {
    private static let key = "owner.shops.v1"

    static func load() -> [OwnerShop] {
        guard
            let data = UserDefaults.standard.data(forKey: key),
            let arr = try? JSONDecoder().decode([OwnerShop].self, from: data)
        else {
            return []
        }
        return arr
    }

    static func save(_ shops: [OwnerShop]) {
        guard let data = try? JSONEncoder().encode(shops) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// ✅ The important part: append without wiping existing shops
    static func addShop(name: String) -> OwnerShop {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let newShop = OwnerShop(name: trimmed.isEmpty ? "בית העם" : trimmed)

        var existing = load()

        // avoid duplicates by name (optional)
        if existing.contains(where: { $0.name.caseInsensitiveCompare(newShop.name) == .orderedSame }) {
            return existing.first(where: { $0.name.caseInsensitiveCompare(newShop.name) == .orderedSame })!
        }

        existing.append(newShop)
        save(existing)
        return newShop
    }
}
