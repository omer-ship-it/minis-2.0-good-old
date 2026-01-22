import SwiftUI
import Kingfisher
import PassKit
import StoreKit
import UIKit
import StripeCore
import StripeApplePay
import StripePayments
import Combine
import UIKit


enum PickupLocation: String, CaseIterable, Identifiable {
    case cafeteria
    case scienceBuilding

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cafeteria:       return "מדעי הרוח"
        case .scienceBuilding: return "מדעי החברה"
        }
    }
}
extension UIColor {
    convenience init(hex: String) {
        var hex = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hex = hex.replacingOccurrences(of: "#", with: "")

        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)

        let r, g, b, a: UInt64
        switch hex.count {
        case 6: // RRGGBB
            (r, g, b, a) = (
                (int >> 16) & 0xFF,
                (int >> 8) & 0xFF,
                int & 0xFF,
                0xFF
            )
        case 8: // AARRGGBB
            (a, r, g, b) = (
                (int >> 24) & 0xFF,
                (int >> 16) & 0xFF,
                (int >> 8) & 0xFF,
                int & 0xFF
            )
        default:
            (r, g, b, a) = (0, 0, 0, 0xFF)
        }

        self.init(
            red: CGFloat(r) / 255,
            green: CGFloat(g) / 255,
            blue: CGFloat(b) / 255,
            alpha: CGFloat(a) / 255
        )
    }
}
enum MenuTheme {
    
    // Helper to read miniAppId
     static var miniId: Int {
        UserDefaults.standard.integer(forKey: "miniAppId")
    }

    // Helper + convenience
    private static func hex(_ hex: String) -> Color {
        Color(uiColor: UIColor(hex: hex))
    }
    
    

    // MAIN COLORS
    static var accent: Color {
        if miniId == 3 { return hex("#d71201") }

        if miniId == 13 {
                return Color(UIColor { trait in
                    trait.userInterfaceStyle == .dark
                        ? UIColor.white   // 🌙 dark mode
                        : UIColor.black   // ☀️ light mode
                })
            }
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
        if miniId == 13 {
            return hex("#6db95b")   // always red
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
private func normalizePresetForSheet(
    _ preset: (options: [String:String], additions: Set<String>)
) -> (options: [String:String], additions: Set<String>) {

    func norm(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{200F}", with: "")
            .replacingOccurrences(of: "\u{200E}", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    var o: [String:String] = [:]
    for (k, v) in preset.options {
        o[norm(k)] = norm(v)
    }

    let a = Set(preset.additions.map(norm))
    return (o, a)
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
struct LocationSegment: View {
    @Environment(\.colorScheme) private var scheme
    @Binding var location: PickupLocation

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(
                            Color.primary.opacity(scheme == .dark ? 0.25 : 0.12),
                            lineWidth: 1
                        )
                )

            HStack(spacing: 4) {
                ForEach(PickupLocation.allCases) { loc in
                    Button {
                        location = loc
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        Text(loc.title)
                            .font(.menuRegular(15).weight(.semibold))
                            .foregroundColor(
                                location == loc
                                ? (scheme == .dark ? .black : .white)
                                : .primary.opacity(0.75)
                            )
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                            .background(
                                location == loc
                                ? Color.primary
                                : Color.clear
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
        }
        .frame(height: 46)
    }
}
struct ServiceSegment: View {
    @Environment(\.isRtl) private var isRtl
    @Environment(\.colorScheme) private var scheme
    @Binding var intent: ServiceIntent

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
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
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous)) // important
        .highPriorityGesture(
            LongPressGesture(minimumDuration: 1.2)
                .onEnded { _ in
                    UserDefaults.standard.set(true, forKey: "cashPointMode")
                    UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                }
        )
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

fileprivate func menuFontScale() -> CGFloat {
    let miniId = UserDefaults.standard.integer(forKey: "miniAppId")
    return miniId == 13 ? 1.1 : 0.9
}

func menuFontName() -> String {
    let miniId = UserDefaults.standard.integer(forKey: "miniAppId")

    // ✅ Vitamin: force Heebo
    if miniId == 13 {
        // IMPORTANT: this must be the internal font name (from debugAllFonts())
        return "Heebo-Regular"
        // or "Heebo-VariableFont_wght" if that's what your debug prints
    }

    // 1) JSON customization → "Oswald", etc.
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
           let scaled = size * menuFontScale()
           return .custom(menuFontName(), size: scaled)
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
    @AppStorage(AppSettings.Key.cashPointMode) private var cashPointMode: Bool = AppSettings.Defaults.cashPointMode
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
    @State private var showMembers = false
    @State private var showCardSheet = false
    @AppStorage(MembersKeys.didPrompt) private var didPromptMembers: Bool = false
    @State private var showMembersSheet = false
    @State private var showMemberCard = false
    @State private var showJoinMembers = false
    @State private var cardContentHeight: CGFloat = 0
    @State private var basketCardContentHeight: CGFloat = 0
    @State private var showOrderFlow = false
    @State private var orderFlowEntries: [BasketEntry] = []
    @State private var orderFlowTotal: Double = 0
    @State private var orderFlowDiningMode: DiningMode = .takeAway
    @State private var orderFlowIsSubmitting = false
    @State private var orderFlowShowProgress = false
    @State private var orderFlowSubmitError: String? = nil
    @State private var isManualCategoryScroll = false
    @State private var manualScrollToken: UUID = UUID()
    
    @State private var scrollToTopToken: Int = 0
    @StateObject private var scrollVM = MenuScrollCoordinator()
    // MARK: - Idle reset (customer mode only)
    @State private var lastInteractionAt: Date = Date()
    @State private var showIdleSheet: Bool = false
    @State private var idleCountdown: Int = 5

    private let idleTimeout: TimeInterval = 30
    private let idleCountdownStart: Int = 5
    private let basketBarH: CGFloat = 76
    @State private var studentClaim: StudentClaim? = nil
    private let appGroupId = "group.minis"
    private let kPendingStudentClaim  = "pendingStudentClaim.v1"
    @AppStorage("members.updatedAt") private var membersUpdatedAt: Double = 0
    @AppStorage("admin") private var isAdmin: Bool = false
    @State private var now: Date = Date()
    private let clock = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    private let idleClock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @AppStorage("pickup.location")
    private var pickupLocationRaw: String = PickupLocation.cafeteria.rawValue
    @State private var menuPollTask: Task<Void, Never>? = nil
    @State private var lastMenuFetchAt: Date = .distantPast
    @State private var stampsClaim: StampsClaim? = nil
    private let kPendingStampsClaim = "pendingStampsClaim.v1"

    private struct StampsClaim: Identifiable, Codable, Equatable {
        var id: String { "\(miniAppId)-\(stamps)" }
        let miniAppId: Int
        let stamps: Int
    }
    private var serviceIntentBinding: Binding<ServiceIntent> {
        Binding(
            get: { ServiceIntent(rawValue: checkoutIntentRaw) ?? .sit },
            set: { newValue in
                checkoutIntentRaw = newValue.rawValue
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        )
    }
    private var pickupLocation: PickupLocation {
        get { PickupLocation(rawValue: pickupLocationRaw) ?? .cafeteria }
        nonmutating set { pickupLocationRaw = newValue.rawValue }
    }
    private var birthdayMonth: Int? {
        let p = UserDefaults.standard.dictionary(forKey: "memberProfileLocal") ?? [:]
        if let m = p["birthMonth"] as? Int { return m }

        // fallback if only MM-DD exists
        if let mmdd = p["birthdayMMDD"] as? String {
            let parts = mmdd.split(separator: "-")
            if parts.count == 2 { return Int(parts[0]) }
        }
        return nil
    }

    private func shouldPollMenu() -> Bool {
        // Don’t hammer while sheets / flows are open (optional but recommended)
        if showOrderFlow { return false }
        if showBasketSheet { return false }
        if selectedItem != nil { return false }   // product sheet open
        if showWelcome { return false }           // kiosk welcome open
        if showIdleSheet { return false }
        return true
    }

    private func startMenuPolling() {
        menuPollTask?.cancel()

        menuPollTask = Task {
            while !Task.isCancelled {

                if shouldPollMenu() {
                    // Optional throttle so we never reload more often than every 30s
                    let elapsed = Date().timeIntervalSince(lastMenuFetchAt)
                    if elapsed >= 30 {
                        await MainActor.run {
                            // ✅ FORCE network + re-parse
                            // Use whichever signature you have:
                            // api.load(skipCache: true)
                            api.load(skipCache: true)

                            lastMenuFetchAt = Date()
                        }
                    }
                }

                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    private func stopMenuPolling() {
        menuPollTask?.cancel()
        menuPollTask = nil
    }
    
    private var currentMonthIL: Int {
        var cal = Calendar.current
        cal.timeZone = TimeZone(identifier: "Asia/Jerusalem") ?? .current
        return cal.component(.month, from: Date())
    }

    private var currentYearIL: Int {
        var cal = Calendar.current
        cal.timeZone = TimeZone(identifier: "Asia/Jerusalem") ?? .current
        return cal.component(.year, from: Date())
    }

    private var birthdayVoucherRedeemedThisYear: Bool {
        let key = "birthdayVoucherRedeemedYear"
        return UserDefaults.standard.integer(forKey: key) == currentYearIL
    }

    private var birthdayVoucherAvailableNow: Bool {
        guard isMember else { return false }
        guard let bm = birthdayMonth else { return false }
        guard bm == currentMonthIL else { return false }
        return !birthdayVoucherRedeemedThisYear
    }
    
    private var isMember: Bool {
        UserDefaults.standard.dictionary(forKey: "memberProfileLocal") != nil
    }
    
    private var isItalyRegion: Bool {
        // Works well for App Store region/device locale
        (Locale.current.region?.identifier ?? Locale.current.regionCode ?? "").uppercased() == "IT"
    }
    
    private var shouldAutoShowMembersForMini12: Bool {
        miniAppId == 12 &&
        UserDefaults.standard.dictionary(forKey: MembersKeys.profile) == nil
    }
   
    private func loadPendingStudentClaimIfAny() {
        guard let suite = UserDefaults(suiteName: appGroupId),
              let data = suite.data(forKey: kPendingStudentClaim),
              let claim = try? JSONDecoder().decode(StudentClaim.self, from: data)
        else { return }

        // one-time
        suite.removeObject(forKey: kPendingStudentClaim)
        suite.synchronize()

        studentClaim = claim
    }
    
    private func registerInteraction() {
        lastInteractionAt = Date()
        if showIdleSheet {
            showIdleSheet = false
        }
    }

    private func startNewOrderFromIdle() {
        // ✅ clear persisted customer details
        UserDefaults.standard.removeObject(forKey: "userName")
        UserDefaults.standard.removeObject(forKey: "userPhone")
        UserDefaults.standard.removeObject(forKey: "userEmail")

        // if you also keep POS drafts
        UserDefaults.standard.removeObject(forKey: "posSavedName")
        UserDefaults.standard.removeObject(forKey: "posSavedPhone")

        // reset order state
        basket.removeAll()
        selectedBasketLineId = nil
        nextBasketLineId = 1
        showBasketSheet = false
        selectedItem = nil
        selectedCategory = availableCategories.first ?? ""
        showWelcome = true

        // reset idle state
        showIdleSheet = false
        lastInteractionAt = Date()
    }
    private var hasMemberProfile: Bool {
        UserDefaults.standard.dictionary(forKey: MembersKeys.profile) != nil
    }
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
    
    private func resetMenuToTop(proxy: ScrollViewProxy) {
        categorySyncResumeAt = Date().addingTimeInterval(1.2)   // ✅ pause detector
        selectedCategory = ""                                  // ✅ clear highlight immediately

        withAnimation(.easeInOut(duration: 0.35)) {
            proxy.scrollTo("TOP", anchor: .top)                // ✅ jump to top anchor you already added
        }

        // ✅ after scroll settles, choose the first category as the new default
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            if let first = availableCategories.first {
                selectedCategory = first
            }
        }
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
    
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    private var gridColumns: [GridItem] {
        let count = isPad ? 3 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 12), count: count)
    }
    private var items: [ShellMenuItem] {
        api.items.filter { $0.isAvailable && $0.isWithinActiveHours(now: now) }
    }
    private var basketTotalQuantity: Int { basket.values.reduce(0) { $0 + $1.quantity } }
    private var basketTotalPrice: Double { basket.values.reduce(0) { $0 + Double($1.quantity) * $1.unitPrice } }

    private func addToBasket(
        _ item: ShellMenuItem,
        quantity: Int,
        subtitle: String?,
        unitPrice: Double,
        selectedOptions: [String: String] = [:],
        selectedAdditions: Set<String> = []
    ) {
        if quantity <= 0 {
            let idsToRemove = basket
                .filter { $0.value.item.id == item.id }
                .map(\.key)

            idsToRemove.forEach { basket[$0] = nil }

            selectedBasketLineId = nil
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            return
        }
        
        let hasModifiers = !(item.modifiers?.isEmpty ?? true)

        if let lineId = selectedBasketLineId {
            if quantity <= 0 {
                basket[lineId] = nil
            } else if let existing = basket[lineId] {
                basket[lineId] = BasketEntry(
                    id: lineId,
                    item: existing.item,
                    quantity: quantity,
                    subtitle: subtitle,
                    unitPrice: unitPrice,
                    selectedOptions: selectedOptions,
                    selectedAdditions: selectedAdditions
                )
            }
            selectedBasketLineId = nil
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            return
        }

        if hasModifiers {
            guard quantity > 0 else { return }
            let lineId = nextBasketLineId
            nextBasketLineId += 1

            basket[lineId] = BasketEntry(
                id: lineId,
                item: item,
                quantity: quantity,
                subtitle: subtitle,
                unitPrice: unitPrice,
                selectedOptions: selectedOptions,
                selectedAdditions: selectedAdditions
            )
        } else {
            // no modifiers => keep classic “same product merges”
            if let (lineId, existing) = basket.first(where: { $0.value.item.id == item.id }) {
                if quantity <= 0 {
                    basket[lineId] = nil
                } else {
                    basket[lineId] = BasketEntry(
                        id: lineId,
                        item: existing.item,
                        quantity: quantity,
                        subtitle: subtitle,
                        unitPrice: unitPrice,
                        selectedOptions: [:],
                        selectedAdditions: []
                    )
                }
            } else {
                guard quantity > 0 else { return }
                let lineId = nextBasketLineId
                nextBasketLineId += 1

                basket[lineId] = BasketEntry(
                    id: lineId,
                    item: item,
                    quantity: quantity,
                    subtitle: subtitle,
                    unitPrice: unitPrice,
                    selectedOptions: [:],
                    selectedAdditions: []
                )
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
                    Text(
                        isRtl
                        ? formatPrice(item.lastPrice)
                        : "£\(formatPrice(item.lastPrice))"
                    )
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
    
    private struct SheetHKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }

   

    private func incrementEntry(_ id: Int) {
        guard let entry = basket[id] else { return }
        basket[id]?.quantity = entry.quantity + 1
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    
    private var memberStamps: Int {
        let profile = UserDefaults.standard.dictionary(forKey: "memberProfileLocal") ?? [:]
        let raw = profile["stamps"] as? Int ?? 0
        return max(0, min(10, raw))
    }
    
    private var hasFreeCoffee: Bool {
        memberStamps >= 10
    }

    private enum MembersKeys {
        static let didPrompt = "members.didPrompt"
        static let profile   = "memberProfileLocal"
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

        // ✅ If basket is now empty → close the basket sheet (works for iPhone sheet + iPad fullScreenCover)
        if basket.isEmpty {
            DispatchQueue.main.async {
                showBasketSheet = false
            }
        }
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
                    
                    if isPad {
                        // ✅ iPad layout: content + right rail
                        HStack(spacing: 0) {
                            
                            CategoryRail(
                                categories: availableCategories,
                                selected: selectedCategory,
                                onTap: { cat in
                                    // ✅ freeze detector for exactly ~1.3s
                                    isManualCategoryScroll = true
                                    manualScrollToken = UUID()          // new token for this tap
                                    let token = manualScrollToken

                                    categorySyncResumeAt = Date().addingTimeInterval(1.3)
                                    selectedCategory = cat

                                    // scroll (next runloop is more reliable)
                                    DispatchQueue.main.async {
                                        withAnimation(.easeInOut(duration: 0.55)) {
                                            proxy.scrollTo(anchorId(for: cat), anchor: .top)
                                        }
                                    }

                                    // ✅ unfreeze exactly once (not extended by any other updates)
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
                                        guard token == manualScrollToken else { return }
                                        isManualCategoryScroll = false
                                    }
                                },
                                intent: serviceIntentBinding,
                                onServiceLongPress: {
                                    guard isAdmin else { return }
                                    print("✅ LONG PRESS on ServiceSegment → cashPointMode true")
                                    cashPointMode = true
                                }
                            )
                            // MAIN CONTENT
                            ScrollView {
                                Color.clear
                                    .frame(height: 1)
                                    .id("TOP")
                                LazyVStack(spacing: 0) {
                                    
                                    // ✅ keep your existing top header stack / service segment / banners / myItems etc.
                                    // (everything you already have above Section)
                                    
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
                                                .font(.menuRegular(22).weight(.semibold))
                                                .padding(.horizontal, 16)
                                            
                                            LazyVGrid(columns: gridColumns, spacing: 12) {
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
                                            .padding(.bottom, 18)
                                        }
                                        .padding(.top, -stickyHeaderHeight + 50)
                                    }
                                }
                                .padding(.bottom, 60)
                                
                            }
                            .coordinateSpace(name: "menuScroll")
                            
                            // ✅ RIGHT CATEGORY RAIL
                            
                        }
                        .onReceive(scrollVM.$scrollToTop) { shouldScroll in
                            guard shouldScroll else { return }
                            
                            categorySyncResumeAt = Date().addingTimeInterval(1.2) // pause detector
                            selectedCategory = "" // clear highlight so it won’t “snap back”
                            
                            withAnimation(.easeInOut(duration: 0.35)) {
                                proxy.scrollTo("TOP", anchor: .top)
                            }
                            
                            // pick first category after scroll settles
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                                if let first = availableCategories.first {
                                    selectedCategory = first
                                }
                                scrollVM.scrollToTop = false
                            }
                        }
                        .onPreferenceChange(CategoryPositionKey.self) { positions in
                            guard Date() >= categorySyncResumeAt, !positions.isEmpty else { return }
                            
                            let targetY: CGFloat = stickyHeaderHeight + 8
                            let sorted = positions.sorted { $0.value < $1.value }
                            
                            // the category your current logic thinks is active
                            guard let picked = (sorted.last(where: { $0.value <= targetY }) ?? sorted.first)?.key else { return }
                            
                            // ✅ iPad hack: shift back by 1
                            let finalKey: String = {
                                guard isPad else { return picked }
                                guard let i = availableCategories.firstIndex(of: picked) else { return picked }
                                let prev = max(i - 1, 0)
                                return availableCategories[prev]
                            }()
                            
                            if finalKey != selectedCategory {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    selectedCategory = finalKey
                                }
                            }
                        }
                        
                    }  else {
                        ScrollView {
                            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {

                                // ✅ ORIGINAL HEADER (put it back here)
                                VStack(spacing: 8) {
                                    HStack {
                        #if !APPCLIP
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

                                        HStack(spacing: 18) {

                                            // ☕ MEMBERS CARD BUTTON
#if !APPCLIP
if miniAppId == 12  || miniAppId == 13 {
    Button {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        if isMember {
            showCardSheet = true          // ✅ always open card once joined
        } else {
            showMembersSheet = true       // ✅ join flow only if not a member
        }
    } label: {
        Image(systemName: hasFreeCoffee ? "cup.and.saucer.fill" : "cup.and.saucer")
            .font(.system(size: 22, weight: .semibold))
            .foregroundColor(hasFreeCoffee ? MenuTheme.buttonBackground : .primary)
    }
    .buttonStyle(.plain)
}
#endif
                                            // 🔗 SHARE
                                            Button {
                                                showShareSheet = true
                                            } label: {
                                                Image(systemName: "arrowshape.turn.up.forward")
                                                    .font(.system(size: 22, weight: .semibold))
                                            }
                                        }
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.top, 8)

                                    VStack(spacing: 3) {

                                        // TITLE
                                        Text(
                                            miniAppId == 13
                                            ? "vitamin"
                                            : (isRtl ? "תפריט בוקר" : "Beigel Bake · Brick Ln")
                                        )
                                        .padding(.top, 15)
                                        .font(
                                            miniAppId == 13
                                            ? .system(size: 35, weight: .heavy)
                                            : .menuRegular(28)
                                        )
                                        .contentShape(Rectangle()) // whole area tappable
                                        .onLongPressGesture(minimumDuration: 1.2) {
                                            guard isAdmin else { return }
                                            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                                            cashPointMode = true
                                        }

                                        // SUBTITLE
                                        Text(
                                            miniAppId == 13
                                            ? "בריא · מהיר · טבעי"
                                            : (isRtl
                                                ? "הזמינו מהטלפון ונעדכן כשמוכן"
                                                : "Delivered in around 20 minutes")
                                        )
                                        .font(.menuRegular(isRtl ? 15 : 18))
                                        .foregroundColor(
                                            Color(UIColor { trait in
                                                trait.userInterfaceStyle == .dark
                                                    ? UIColor(Color.primary)
                                                    : UIColor.secondaryLabel
                                            })
                                        )
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.bottom, 12)
                                }
                                .padding(.bottom, 8)

                                if miniAppId == 13 {
                                    LocationSegment(location: Binding(
                                        get: { pickupLocation },
                                        set: { pickupLocation = $0 }
                                    ))
                                    .padding(.horizontal, 16)
                                    .padding(.top, 8)
                                    .padding(.bottom, 20)

                                } else if miniAppId == 12 {
                                    ServiceSegment(intent: serviceIntentBinding)
                                        .padding(.horizontal, 16)
                                        .padding(.top, 8)
                                        .padding(.bottom, 20)
                                }

                                if let order = lastOrder {
                                    OrderInProcessBanner(orderNumber: order.orderNumber, phase: order.phase) {
                                        confirmationOrder = order
                                        showConfirmation = true
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.bottom, 12)
                                }

                                if birthdayVoucherAvailableNow {
                                    BirthdayVoucherBanner(isRtl: isRtl)
                                        .padding(.horizontal, 16)
                                        .padding(.bottom, 10)
                                }
                                
                                if !myItems.isEmpty {
                                    MyItemsStrip(items: myItems, isRtl: isRtl) { productId in
                                        if let item = items.first(where: { $0.id == productId }) {
                                            selectedBasketLineId = nil

                                            if let saved = myItems.first(where: { $0.id == productId }) {
                                                let opts = saved.lastSelectedOptions ?? [:]
                                                let adds = Set(saved.lastSelectedAdditions ?? [])
                                                myItemsPreset = (options: opts, additions: adds)
                                            } else {
                                                myItemsPreset = nil
                                            }

                                            productSheetNonce += 1
                                            DispatchQueue.main.async { selectedItem = item }
                                        } else {
                                            // product exists in history but hidden now (out of hours / out of stock)
                                            Haptics.error()
                                        }
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.bottom, 12)
                                }

                                // ✅ NOW the pinned category bar + products
                                Section {
                                    // IMPORTANT: this must contain your per-category content
                                    ForEach(availableCategories, id: \.self) { category in

                                        // ✅ Make the ID live on the *direct child* of the LazyVStack
                                        VStack(alignment: .leading, spacing: 0) {

                                            // ✅ Scroll target spacer (lands header below pinned CategoryBar)
                                            Color.clear
                                                .frame(height: stickyHeaderHeight + 8)

                                            // ✅ Content
                                            VStack(alignment: .leading, spacing: 12) {

                                                // ✅ REAL header (stable geometry for auto-select while scrolling)
                                                Text(category)
                                                    .font(.menuRegular(22).weight(.semibold))
                                                    .padding(.horizontal, 16)
                                                    .padding(.top, 6)
                                                    .background(
                                                        GeometryReader { geo in
                                                            Color.clear.preference(
                                                                key: CategoryPositionKey.self,
                                                                value: [category: geo.frame(in: .named("menuScroll")).minY]
                                                            )
                                                        }
                                                    )

                                                LazyVGrid(columns: gridColumns, spacing: 12) {
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
                                                .padding(.bottom, 18)
                                            }
                                            .padding(.top, 8)
                                        }
                                        .id(anchorId(for: category)) // ✅ IMPORTANT: ID on the direct child
                                    }
                                } header: {
                                    CategoryBar(
                                        categories: availableCategories,
                                        selected: selectedCategory,
                                        onTap: { cat in
                                            // ✅ freeze detector for exactly ~1.3s
                                            isManualCategoryScroll = true
                                            manualScrollToken = UUID()          // new token for this tap
                                            let token = manualScrollToken

                                            categorySyncResumeAt = Date().addingTimeInterval(1.3)
                                            selectedCategory = cat

                                            // scroll (next runloop is more reliable)
                                            DispatchQueue.main.async {
                                                withAnimation(.easeInOut(duration: 0.55)) {
                                                    proxy.scrollTo(anchorId(for: cat), anchor: .top)
                                                }
                                            }

                                            // ✅ unfreeze exactly once (not extended by any other updates)
                                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
                                                guard token == manualScrollToken else { return }
                                                isManualCategoryScroll = false
                                            }
                                        }
                                    )
                                }
                            }
                            .padding(.bottom, 60)
                        }
                        .coordinateSpace(name: "menuScroll")
                    }
            
                }
                
                .onPreferenceChange(CategoryPositionKey.self) { positions in
                    // ✅ prevent iPad branch from being overridden by the global handler
                    guard !isPad else { return }
                    guard Date() >= categorySyncResumeAt, !positions.isEmpty else { return }
                    guard !isManualCategoryScroll else { return }
                    let targetY: CGFloat = stickyHeaderHeight + 8
                    let sorted = positions.sorted { $0.value < $1.value }

                    guard let picked =
                        (sorted.last(where: { $0.value <= targetY }) ?? sorted.first)?.key
                    else { return }

                    guard picked != selectedCategory else { return }

                    // ✅ adjacency guard (no jumping across multiple categories)
                    if let curI = availableCategories.firstIndex(of: selectedCategory),
                       let newI = availableCategories.firstIndex(of: picked),
                       abs(newI - curI) > 1 {
                        return
                    }

                    // ✅ no animation = less churn/jitter
                    var t = Transaction()
                    t.disablesAnimations = true
                    withTransaction(t) {
                        selectedCategory = picked
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
                    if isPad{
                        showWelcome = true
                    }
                }
            }
        }

#if APPCLIP
.fullScreenCover(item: $studentClaim) { claim in
    StudentDiscountView(
        miniAppId: claim.miniAppId,
        campaignId: claim.campaignId,
        discountPercent: claim.discountPercent,
        durationMonths: claim.durationMonths
    )
    .interactiveDismissDisabled(true)
}
#else
.sheet(item: $studentClaim) { claim in
    StudentDiscountView(
        miniAppId: claim.miniAppId,
        campaignId: claim.campaignId,
        discountPercent: claim.discountPercent,
        durationMonths: claim.durationMonths
    )
    .presentationDetents([.height(380)])
    .presentationDragIndicator(.visible)
}
#endif
        .onReceive(
            NotificationCenter.default.publisher(for: Notification.Name.studentClaimArrived)
                .receive(on: RunLoop.main)
        ) { (note: Notification) in
            print("🎓 studentClaimArrived received in menuView", note.name.rawValue)
            loadPendingStudentClaimIfAny()
        }
        .onAppear {
            
           // loadPendingStudentClaimIfAny()   // ✅ cold start / app clip handoff


           
            serviceIntent = ServiceIntent(rawValue: checkoutIntentRaw) ?? .ta
               if !api.items.isEmpty {
                   let first = api.items[0]
                   print("🧭 menuView.onAppear → first item: \(first.name) [\(first.category)] (total \(api.items.count))")
               } else {
                   print("🧭 menuView.onAppear → api.items is empty at appear")
               }

            saveReferralForCurrentShop(kind: .fastlane)
            api.load(skipCache: false)
            lastMenuFetchAt = Date()
            now = Date()
            reloadMyItems()
            startMenuPolling()
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
        .onDisappear {
            stopMenuPolling()            // ✅ stop polling
        }
        .onReceive(clock) { _ in
            now = Date()
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
        // ✅ any tap/drag anywhere counts as interaction (without breaking scroll)
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !cashPointMode else { return }
                    registerInteraction()
                }
        )
        .onChange(of: showWelcome) { isShown in
           
                lastInteractionAt = Date()
            
        }
        .onChange(of: showBasketSheet, perform: { open in
            if open {
                showIdleSheet = false
                idleCountdown = idleCountdownStart
                lastInteractionAt = Date()
            } else {
                lastInteractionAt = Date()
            }
        })
        .onChange(of: showOrderFlow, perform: { open in
            if open {
                showIdleSheet = false
                idleCountdown = idleCountdownStart
                lastInteractionAt = Date()
            } else {
                lastInteractionAt = Date()
            }
        })
        .onReceive(idleClock) { _ in
            guard isPad else { return }
            guard !cashPointMode else { return }          // only customer mode
            guard !showWelcome else { return }
            guard !showOrderFlow else { return }          // don’t interrupt payment flow
            guard !showBasketSheet else { return }        // gcoptional
            guard selectedItem == nil else { return }     // optional
            guard !showIdleSheet else { return }

            let idle = Date().timeIntervalSince(lastInteractionAt)
            if idle >= idleTimeout {
                idleCountdown = idleCountdownStart
                showIdleSheet = true
            }
        }
        .sheet(isPresented: $showIdleSheet) {
            IdleResetSheet(
                countdown: $idleCountdown,
                onKeep: {
                    registerInteraction()
                },
                onStartNew: {
                    startNewOrderFromIdle()
                }
            )
            .presentationDetents([.height(260)])
            .presentationDragIndicator(.hidden)
        }
        
#if !APPCLIP
        
        .fullScreenCover(isPresented: $showOrderFlow) {

            let entriesToSend = orderFlowEntries
            let totalToSend   = orderFlowTotal
            let dm            = orderFlowDiningMode

            // ✅ if total is 0, skip payment UI entirely (free order)
            if totalToSend <= 0.0001 {
                VStack {
                    Text("0.00")
                    Text("Free order – skipping payment")
                }
                .onAppear {
                    // call your submit-free-order path here if you want
                    showOrderFlow = false
                }
            } else {

                OrderFlowView(
                    onSendToKitchen: {
                        let ticket = nextMenuTicketNumber()

                        Task {
                            let ok = await PrinterManager.shared.printCashPointSplit(
                                orderNumber: ticket,
                                entries: entriesToSend,
                                total: totalToSend,
                                diningMode: dm,
                                customerName: UserDefaults.standard.string(forKey: "userName"),
                                customerPhone: UserDefaults.standard.string(forKey: "userPhone")
                            )

                            if !ok {
                                print("❌ printCashPointSplit failed for order \(ticket)")
                            }
                        }
                    },
                    total: totalToSend,
                    isRtl: true,
                    diningMode: .constant(dm),
                    requiresPhoneStep: (miniAppId == 3),
                    onCancel: { showOrderFlow = false },
                    onCompleted: { phone, name, summary, discountOff, tip in
                        // ✅ 0) Scroll request (fine to do early)
                        scrollVM.scrollToTop = true

                        // ✅ 1) Persist contact (same as you had)
                        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            UserDefaults.standard.set(name, forKey: "userName")
                        }
                        if miniAppId == 3,
                           let phone, !phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            UserDefaults.standard.set(phone, forKey: "userPhone")
                        }

                        // ✅ 2) PRINT FIRST (critical) — use a local ticket so it prints once
                        let ticket = nextMenuTicketNumber()
                        UserDefaults.standard.set(ticket, forKey: "lastTicketNumber")
                        let safeName: String? = {
                            let n = (UserDefaults.standard.string(forKey: "userName") ?? "")
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            return n.isEmpty ? nil : n
                        }()

                        let safePhone: String? = {
                          
                            let p = (UserDefaults.standard.string(forKey: "userPhone") ?? "")
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            return p.isEmpty ? nil : p
                        }()

                        Task {
                            let ok = await PrinterManager.shared.printCashPointSplit(
                                orderNumber: ticket,
                                entries: entriesToSend,
                                total: totalToSend,
                                diningMode: dm,
                                customerName: safeName,
                                customerPhone: safePhone
                            )

                            if !ok {
                                print("❌ printCashPointSplit failed for order \(ticket)")
                            }
                        }

                        // ✅ 3) Submit using snapshot (same as you had)
                        orderFlowIsSubmitting = true
                        orderFlowShowProgress = true
                        orderFlowSubmitError = nil

                        var meta: [String: Any] = [:]
                        meta["paymentMethod"]   = summary.method.rawValue
                        meta["cashAmount"]      = summary.cashAmount
                        meta["cardAmount"]      = summary.cardAmount
                        meta["discountedTotal"] = totalToSend
                        meta["originalTotal"]   = totalToSend
                        meta["discountOff"]     = discountOff
                        meta["tip"]             = tip
                        meta["printedTicket"]   = ticket   // ✅ useful for debugging

                        OrderAPI.submitOrder(
                            entries: entriesToSend,
                            total: totalToSend,
                            diningMode: dm,
                            source: "menu-ipad-orderflow",
                            customerName: safeName,
                            customerPhone: safePhone,
                            payment: summary,
                            zcreditMeta: meta
                        ) { result in
                            DispatchQueue.main.async {
                                orderFlowIsSubmitting = false
                                orderFlowShowProgress = false

                                switch result {
                                case .success(let orderId):
                                    Haptics.success()
                                   // showOrderFlow = false
                                    scrollToTopToken += 1

                                    let snap = OrderSnapshot(
                                        orderNumber: orderId,
                                        entries: entriesToSend,
                                        totalPrice: totalToSend,
                                        diningMode: dm,
                                        phase: .inProgress
                                    )

                                    basket.removeAll()
                                    selectedBasketLineId = nil
                                    nextBasketLineId = 1
                                    showBasketSheet = false

                                    if cashPointMode {
                                        confirmationOrder = snap
                                        showConfirmation = true
                                    } else {
                                        if isPad{
                                            showWelcome = true
                                            UserDefaults.standard.removeObject(forKey: "userName")
                                            UserDefaults.standard.removeObject(forKey: "userPhone")
                                        }
                                    }

                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                        lastOrder = snap
                                        saveLastOrderPersisted(snap)
                                    }

                                case .failure(let err):
                                    orderFlowSubmitError = err.localizedDescription
                                    Haptics.error()
                                }
                            }
                        }
                    },
                    onFinish: { showOrderFlow = false },
                    allowPayLater: true,
                    skipServiceStep: false,
                    onServiceChosen: { },
                    startAtCharge: false
                )
                .environment(\.layoutDirection, .rightToLeft)
                .environment(\.locale, Locale(identifier: "he_IL"))
                .tint(.primary)
            }
        }
        #endif
        .sheet(isPresented: $showCardSheet) {
            MemberCardSheet()
                .presentationDetents([.height(200), .large])
                .presentationDragIndicator(.visible)
                .environment(\.layoutDirection, .rightToLeft)
                .environment(\.locale, Locale(identifier: "he_IL"))
        }
        .onAppear {
#if !APPCLIP
guard !UserDefaults.standard.bool(forKey: "didShowMembersOnce") else { return }

DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
    showMembersSheet = true
    UserDefaults.standard.set(true, forKey: "didShowMembersOnce")   // ✅ move here
}
#endif
        }
        .sheet(isPresented: $showMembersSheet) {
            MembersClubView(
                miniAppId: UserDefaults.standard.integer(forKey: "miniAppId"),
                campaignId: "members",
                stampEarnedNow: 0  // full app first launch doesn't need "earned now"
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
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
            ZStack {
                // Always reserve space (prevents jump)
                Color.clear.frame(height: basketBarH)

                // Show/hide the real bar without changing layout
                Group {
                    if isPad {
                        HStack(spacing: 0) {
                            // 👈 reserve the rail space so the bar starts under the grid
                            Color.clear.frame(width: 200)

                            BasketBar(
                                totalQuantity: basketTotalQuantity,
                                totalPrice: basketTotalPrice,
                                onTap: { showBasketSheet = true },
                                isPad: isPad,
                                onNewOrder: {
                                    basket.removeAll()
                                    selectedBasketLineId = nil
                                    nextBasketLineId = 1
                                    Haptics.light()
                                    showWelcome = true
                                }
                            )
                        }
                    } else {
                        BasketBar(
                            totalQuantity: basketTotalQuantity,
                            totalPrice: basketTotalPrice,
                            onTap: { showBasketSheet = true },
                            isPad: isPad,
                            onNewOrder: {
                                basket.removeAll()
                                selectedBasketLineId = nil
                                nextBasketLineId = 1
                                Haptics.light()
                            }
                        )
                    }
                }
                .frame(height: basketBarH)
                .opacity(basket.isEmpty ? 0 : 1)
                .allowsHitTesting(!basket.isEmpty)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.9), value: basket.isEmpty)
    
        .sheet(item: Binding(
            get: { isPad ? nil : selectedItem },
            set: { newValue in
                if !isPad { selectedItem = newValue }
            }
        )) { item in
            ProductSheet(
                item: item,
                editingLineId: selectedBasketLineId,
                initialQuantityInBasket: basket.values.first(where: { $0.item.id == item.id })?.quantity,
                initialSelectedOptions: myItemsPreset?.options ?? [:],
                initialSelectedAdditions: myItemsPreset?.additions ?? []
            ) { product, qty, subtitle, unitPrice, opts, adds in
                addToBasket(
                    product,
                    quantity: qty,
                    subtitle: subtitle,
                    unitPrice: unitPrice,
                    selectedOptions: opts,
                    selectedAdditions: adds
                )
                selectedBasketLineId = nil
                selectedItem = nil
            }
           
            .presentationCornerRadius(20)
            .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
            .environment(\.locale, Locale(identifier: "he_IL"))
        }

        // ✅ iPad: keep your centered overlay
        .fullScreenCover(item: Binding(
            get: { isPad ? selectedItem : nil },
            set: { newValue in
                if isPad { selectedItem = newValue }
            }
        )) { item in
            GeometryReader { geo in
                let maxCardH = geo.size.height * 1.0
                let minCardH: CGFloat = 260
                let targetH = min(max(cardContentHeight, minCardH), maxCardH)

                ZStack {
                    Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()

                    Color.black.opacity(0.001)
                        .ignoresSafeArea()
                        .onTapGesture { selectedItem = nil }

                    ScrollView(showsIndicators: cardContentHeight > maxCardH) {
                        ProductSheetContent(
                            item: item,
                            initialQuantityInBasket: selectedBasketLineId.flatMap { basket[$0]?.quantity },
                            initialSelectedOptions: myItemsPreset?.options ?? [:],
                            initialSelectedAdditions: myItemsPreset?.additions ?? [],
                            useInitialQuantity: selectedBasketLineId != nil
                        ) { product, qty, subtitle, unitPrice, opts, adds in
                            addToBasket(
                                product,
                                quantity: qty,
                                subtitle: subtitle,
                                unitPrice: unitPrice,
                                selectedOptions: opts,
                                selectedAdditions: adds
                            )
                            selectedBasketLineId = nil
                            selectedItem = nil
                        }
                        .padding(.vertical, 18)
                        .padding(.horizontal, 18)
                        .readHeight { h in
                            let rounded = (h * 10).rounded() / 10
                            if abs(cardContentHeight - rounded) > 1 { cardContentHeight = rounded }
                        }
                    }
                    .scrollDisabled(cardContentHeight <= maxCardH)
                    .frame(width: min(500, geo.size.width - 40), height: targetH)
                    .background(Color(.systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .shadow(color: .black.opacity(0.12), radius: 24, y: 14)
                }
            }
            .presentationBackground(.clear)
            .environment(\.layoutDirection, .rightToLeft)
            .environment(\.locale, Locale(identifier: "he_IL"))
            .tint(.primary)
        }
        .fullScreenCover(isPresented: $showMembers) {
            MembersClubView(
                miniAppId: UserDefaults.standard.integer(forKey: "miniAppId"),
                campaignId: "members",
                stampEarnedNow: 1
                
            )
            
        }
        .fullScreenCover(isPresented: $showWelcome) {
            KioskWelcomeView()
                .environment(\.isRtl, isRtl)
                .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
        }
        // ✅ iPhone: normal sheet
        .sheet(isPresented: Binding(
            get: { showBasketSheet && !isPad },
            set: { newValue in
                if !newValue { showBasketSheet = false }
            }
        )) {
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

                    basket.removeAll()
                    if isPad{
                        showWelcome = true
                    }

                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        showBasketSheet = false

                        confirmationOrder = snapshot
                        showConfirmation = true

                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            lastOrder = snapshot
                            saveLastOrderPersisted(snapshot)
                        }
                    }
                },
                onProductTap: { lineId, item in
                    selectedBasketLineId = lineId

                    // ✅ restore selection from that basket line
                    if let entry = basket[lineId] {
                        myItemsPreset = (options: entry.selectedOptions, additions: entry.selectedAdditions)
                    } else {
                        myItemsPreset = nil
                    }

                    productSheetNonce += 1
                    selectedItem = item
                    showBasketSheet = false
                }
            )
            
            .preferredColorScheme(forceDark ? .dark : nil)
            .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
        }

        // ✅ iPad: fullscreen overlay with material backdrop + centered card
        .fullScreenCover(isPresented: Binding(
            get: { showBasketSheet && isPad },
            set: { if !$0 { showBasketSheet = false } }
        )) {
            GeometryReader { geo in
                let maxCardH = geo.size.height * 0.88
                let minCardH: CGFloat = 280
                let targetH = min(max(basketCardContentHeight, minCardH), maxCardH)

                ZStack {
                    Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()

                    Color.black.opacity(0.001)
                        .ignoresSafeArea()
                        .onTapGesture { showBasketSheet = false }

                    // ✅ If too tall -> scroll the whole content inside the card
                    Group {
                        if basketCardContentHeight > maxCardH {
                            ScrollView {
                            
                            }
                        } else {
                            let maxCardH = geo.size.height * 0.88

                            BasketSheetCardContent(
                                entries: Array(basket.values),
                                payableTotal: basketTotalPrice,
                                maxCardH: maxCardH,
                                onIncrement: { incrementEntry($0) },
                                onDecrement: { decrementEntry($0) },
                                onContinue: { payable in
                                    let dm: DiningMode = {
                                        let intent = ServiceIntent(rawValue: checkoutIntentRaw) ?? .ta
                                        return (intent == .sit) ? .dineIn : .takeAway
                                    }()

                                    orderFlowEntries = Array(basket.values)
                                    orderFlowTotal = payable
                                    orderFlowDiningMode = dm

                                    showBasketSheet = false
                                    showWelcome = false

                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                        showOrderFlow = true
                                    }
                                },
                                onProductTap: { lineId, item in
                                    selectedBasketLineId = lineId
                                    selectedItem = item
                                    showBasketSheet = false
                                },
                                onClose: { showBasketSheet = false }
                            )
                            .padding(18)
                            .readHeight { basketCardContentHeight = $0 }
                           
                            .readHeight { h in
                                let rounded = (h * 10).rounded() / 10
                                if abs(basketCardContentHeight - rounded) > 1 {
                                    basketCardContentHeight = rounded
                                }
                            }
                        }
                    }
                    
                    .frame(width: min(520, geo.size.width - 40), height: targetH)
                    .background(Color(.systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .shadow(color: .black.opacity(0.12), radius: 24, y: 14)
                }
            }
            .presentationBackground(.clear)
            .environment(\.layoutDirection, .rightToLeft)
            .environment(\.locale, Locale(identifier: "he_IL"))
            .tint(.primary)
        }
    }
    
    private struct BasketSheetCardContent: View {
        let entries: [BasketEntry]
        let payableTotal: Double
        let maxCardH: CGFloat

        let onIncrement: (Int) -> Void
        let onDecrement: (Int) -> Void
        let onContinue: (Double) -> Void
        let onProductTap: (Int, ShellMenuItem) -> Void
        let onClose: () -> Void

        @Environment(\.isRtl) private var isRtl

        @State private var rowsHeight: CGFloat = 0

        private let headerTop: CGFloat = 16
        private let headerBottom: CGFloat = 10
        private let barH: CGFloat = 110
        private let sidePad: CGFloat = 18

        private var headerEstimatedH: CGFloat { 44 + headerTop + headerBottom } // close enough
        private var neededTotalH: CGFloat { headerEstimatedH + rowsHeight + barH }

        private var shouldScroll: Bool { neededTotalH > maxCardH }

        var body: some View {
            ZStack(alignment: .top) {

                VStack(spacing: 0) {

                    // ✅ HEADER
                    HStack {
                        Text(isRtl ? "ההזמנה שלך" : "Your order")
                            .font(.menuRegular(24).weight(.semibold))

                        Spacer()

                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(.primary)
                                .frame(width: 32, height: 32)
                                .background(.ultraThinMaterial)
                                .clipShape(Circle())
                        }
                    }
                    .padding(.horizontal, sidePad)
                    .padding(.top, headerTop)
                    .padding(.bottom, headerBottom)

                    // ✅ BODY: measure the STACK (not the scrollview)
                    Group {
                        if shouldScroll {
                            ScrollView {
                                rowsStack
                                    .padding(.horizontal, sidePad)
                                    .padding(.top, 6)
                                    .padding(.bottom, barH + 20)
                            }
                        } else {
                            rowsStack
                                .padding(.horizontal, sidePad)
                                .padding(.top, 6)
                                .padding(.bottom, barH + 20)
                        }
                    }
                }

                // ✅ BOTTOM BAR (fixed)
                VStack(spacing: 12) {
                    HStack {
                        Text(isRtl ? "סה\"כ" : "Total")
                            .font(.menuRegular(18).weight(.semibold))
                        Spacer()
                        Text(
                            isRtl
                            ? formatPrice(payableTotal)
                            : "£\(formatPrice(payableTotal))"
                        )
                        .font(.menuRegular(18).weight(.semibold))
                    }

                    Button {
                        onContinue(payableTotal)
                    } label: {
                        Text(isRtl ? "המשך להזמנה" : "Continue")
                            .font(.menuRegular(17).weight(.semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                            .background(MenuTheme.buttonBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
                .padding(.horizontal, sidePad)
                .padding(.top, 12)
                .padding(.bottom, 14)
                .background(Color(.systemBackground))
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }

        private var rowsStack: some View {
            VStack(spacing: 16) {
                ForEach(entries) { entry in
                    BasketRowInline(
                        entry: entry,
                        onIncrement: onIncrement,
                        onDecrement: onDecrement,
                        onTap: { onProductTap(entry.id, entry.item) }
                    )
                }
            }
            .readHeight { h in
                let rounded = (h * 10).rounded() / 10
                if abs(rowsHeight - rounded) > 1 { rowsHeight = rounded }
            }
        }
    }
    
    private struct IdleResetSheet: View {
        @Binding var countdown: Int
        let onKeep: () -> Void
        let onStartNew: () -> Void

        @State private var timer: Timer?

        var body: some View {
            VStack(spacing: 14) {
                Text("הקופה לא היתה בשימוש")
                    .font(.system(size: 20, weight: .bold))

                Text("נפתח הזמנה חדשה בעוד \(countdown) שניות")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.secondary)

                Spacer().frame(height: 6)

                HStack(spacing: 12) {

                  

                    Button {
                        onStartNew()
                    } label: {
                        Text("הזמנה חדשה")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(MenuTheme.buttonBackground) // ✅ requested
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    
                    Button {
                        onKeep()
                    } label: {
                        Text("להשאיר את ההזמנה")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(MenuTheme.buttonBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 8)
            }
            .padding(18)
            .onAppear {
                
                timer?.invalidate()
                timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                    DispatchQueue.main.async {
                        countdown -= 1
                        if countdown <= 0 {
                            timer?.invalidate()
                            timer = nil
                            onStartNew()
                        }
                    }
                }
            }
            .onDisappear {
                timer?.invalidate()
                timer = nil
            }
        }
    }
    
    
    private struct BasketRowInline: View {
        let entry: BasketEntry
        let onIncrement: (Int) -> Void
        let onDecrement: (Int) -> Void
        let onTap: () -> Void

        var body: some View {
            HStack(spacing: 12) {
                KFImage(entry.item.img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 50, height: 50)
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.item.name).font(.menuRegular(17).weight(.semibold))
                    if let subtitle = entry.subtitle, !subtitle.isEmpty {
                        Text(subtitle).font(.menuRegular(15)).foregroundColor(.secondary)
                    }
                }

                Spacer()

                HStack(spacing: 12) {
                    Button { onDecrement(entry.id) } label: {
                        Circle().fill(Color(.systemGray5))
                            .frame(width: 32, height: 32)
                            .overlay(Image(systemName: "minus").font(.system(size: 16, weight: .bold)))
                    }

                    Text("\(entry.quantity)")
                        .font(.menuRegular(18).weight(.semibold))
                        .frame(minWidth: 20)

                    Button { onIncrement(entry.id) } label: {
                        Circle().fill(Color(.systemGray5))
                            .frame(width: 32, height: 32)
                            .overlay(Image(systemName: "plus").font(.system(size: 16, weight: .bold)))
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { onTap() }
        }
    }
    
    private struct ProductSheetContent: View {
        let item: ShellMenuItem
        let initialQuantityInBasket: Int?
        let initialSelectedOptions: [String: String]
        let initialSelectedAdditions: Set<String>
        let useInitialQuantity: Bool

        // ✅ UPDATED: also return modifiers selection so basket can restore it later (without titles)
        let onAdd: (ShellMenuItem, Int, String?, Double, [String:String], Set<String>) -> Void

        @Environment(\.isRtl) private var isRtl

        @State private var quantity: Int
        @State private var heroFrozenImage: KFCrossPlatformImage? = nil
        @State private var selectedOptions: [String: String]
        @State private var selectedAdditions: Set<String>
        @State private var note: String
        @FocusState private var noteFocused: Bool
        private let barH: CGFloat = 92   // height incl padding

        private func extraPricePerUnit() -> Double {
            guard let groups = item.modifiers else { return 0 }

            return groups.reduce(0) { total, group in
                switch group.type {

                case .options:
                    let gKey = norm(group.title)
                    if let selectedName = selectedOptions[gKey],
                       let opt = group.items.first(where: { norm($0.name) == norm(selectedName) }) {
                        return total + opt.extraPrice
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
            initialSelectedAdditions: Set<String>,
            useInitialQuantity: Bool,
            onAdd: @escaping (ShellMenuItem, Int, String?, Double, [String:String], Set<String>) -> Void
        ) {
            // ✅ local norm() so we don't use self before init completes
            func norm(_ s: String) -> String {
                s.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\u{200F}", with: "")
                    .replacingOccurrences(of: "\u{200E}", with: "")
                    .replacingOccurrences(of: "\u{00A0}", with: " ")
            }

            self.item = item
            self.initialQuantityInBasket = initialQuantityInBasket
            self.initialSelectedOptions = initialSelectedOptions
            self.initialSelectedAdditions = initialSelectedAdditions
            self.useInitialQuantity = useInitialQuantity
            self.onAdd = onAdd

            let startQty = initialQuantityInBasket ?? 1
            _quantity = State(initialValue: startQty)

            // ✅ Build defaults: if an options-group missing -> select its first item
            var defaults: [String: String] = initialSelectedOptions

            if let groups = item.modifiers {
                for g in groups where g.type == .options {
                    let k = norm(g.title)
                    let existing = defaults.first(where: { norm($0.key) == k })?.value ?? ""
                    if existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       let first = g.items.first {
                        defaults[g.title] = first.name   // keep original title/name
                    }
                }
            }

            // ✅ Normalize the dictionary keys/values exactly like ModifierListView expects
            var normalizedDefaults: [String: String] = [:]
            for (k, v) in defaults {
                normalizedDefaults[norm(k)] = norm(v)
            }
            _selectedOptions = State(initialValue: normalizedDefaults)

            // ✅ ADDITIONS: normalized + default-first behavior
            var additionsSeed = Set(initialSelectedAdditions.map(norm))

            if let groups = item.modifiers {
                for g in groups where g.type == .additions {
                    guard let first = g.items.first else { continue }

                    let groupNormNames = Set(g.items.map { norm($0.name) })
                    let defaultNorm = norm(first.name)

                    let hasAnyInGroup = additionsSeed.contains { groupNormNames.contains($0) }

                    if !hasAnyInGroup {
                        additionsSeed.insert(defaultNorm)
                    } else {
                        let hasNonDefault = additionsSeed.contains {
                            groupNormNames.contains($0) && $0 != defaultNorm
                        }
                        if hasNonDefault {
                            additionsSeed.remove(defaultNorm)
                        }
                    }
                }
            }

            _selectedAdditions = State(initialValue: additionsSeed)
            _note = State(initialValue: "")
        }

        var body: some View {
            ZStack(alignment: .bottom) {

                // ✅ SCROLLS UNDER
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {

                        // Image
                        ZStack {
                            if let img = heroFrozenImage {
                                Image(uiImage: img).resizable().scaledToFill()
                            } else {
                                KFImage(item.img)
                                    .onSuccess { heroFrozenImage = $0.image }
                                    .resizable()
                                    .scaledToFill()
                            }
                        }
                        .frame(height: 280)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                        // Title + price + desc
                        VStack(alignment: .leading, spacing: 8) {
                            Text(item.name)
                                .font(.menuRegular(20).weight(.semibold))

                            Text(isRtl ? String(format: "%.0f", item.price)
                                       : String(format: "£%.2f", item.price))
                                .font(.menuRegular(18))
                                .foregroundColor(.secondary)

                            if let desc = item.description,
                               !desc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text(desc)
                                    .font(.menuRegular(16))
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        // Modifiers
                        if let groups = item.modifiers, !groups.isEmpty {
                            ModifierListView(
                                groups: groups,
                                selectedOptions: $selectedOptions,
                                selectedAdditions: $selectedAdditions
                            )
                        }

                        /*
                        VStack(alignment: .leading, spacing: 8) {
                            Text(isRtl ? "הערה לפריט" : "Item note")
                                .font(.menuRegular(16).weight(.semibold))
                                .foregroundColor(.secondary)

                            TextField(isRtl ? "למשל: בלי בצל / חם במיוחד…" : "E.g. no onion / extra hot…",
                                      text: $note,
                                      axis: .vertical)
                                .font(.menuRegular(16))
                                .lineLimit(3, reservesSpace: true)
                                .padding(12)
                                .background(Color(.secondarySystemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .multilineTextAlignment(isRtl ? .leading : .leading)
                                .focused($noteFocused)
                        }
                        .environment(\.layoutDirection, .rightToLeft)
                        .padding(.top, 10)
                        */
                    }
                    .padding(.bottom, barH) // ✅ critical so content doesn’t hide behind bar
                }

                // ✅ FIXED BAR (Z-LAYER)
                bottomBar
                    .frame(maxWidth: .infinity)
                    .background(Color(.systemBackground))
            }
        }

        private var isUpdateMode: Bool {
            (initialQuantityInBasket ?? 0) > 0   // ✅ if it already exists in basket -> allow 0
        }

        private var isRemoveMode: Bool {
            isUpdateMode && quantity == 0
        }

        private var actionTitle: String {
            if isRemoveMode { return isRtl ? "הסר" : "Remove" }
            if isUpdateMode { return isRtl ? "עדכן" : "Update" }
            return isRtl ? "הוסף" : "Add"
        }

        private var actionBackground: Color {
            isRemoveMode ? .red : MenuTheme.buttonBackground
        }

        // ✅ subtitle for display only (no titles, no defaults, deduped)
        private func subtitleFromSelection() -> String? {
            guard let groups = item.modifiers else {
                let clean = note.trimmingCharacters(in: .whitespacesAndNewlines)
                return clean.isEmpty ? nil : (isRtl ? "הערה: \(clean)" : "Note: \(clean)")
            }

            var parts: [String] = []

            // options: value only (and only if not default)
            for g in groups where g.type == .options {
                let gKey = norm(g.title)
                guard let selected = selectedOptions[gKey],
                      let first = g.items.first else { continue }

                if norm(selected) != norm(first.name) {
                    parts.append(norm(selected))
                }
            }

            // default additions (first item) hidden
            let defaultAdditionsNorm: Set<String> = Set(
                groups
                    .filter { $0.type == .additions }
                    .compactMap { $0.items.first?.name }
                    .map(norm)
            )

            // normalize → exclude default → dedupe → sort
            let addNames: [String] = Array(
                Set(
                    selectedAdditions
                        .map(norm)
                        .filter { !$0.isEmpty }
                        .filter { !defaultAdditionsNorm.contains($0) }
                )
            )
            .sorted()

            if !addNames.isEmpty {
                parts.append(addNames.joined(separator: ", "))
            }

            let clean = note.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty {
                parts.append(isRtl ? "הערה: \(clean)" : "Note: \(clean)")
            }

            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        }

        private var bottomBar: some View {
            HStack(spacing: 16) {

                // Qty controls
                HStack(spacing: 18) {
                    Button {
                        if isUpdateMode {
                            if quantity > 0 { quantity -= 1 }     // ✅ allow down to 0
                        } else {
                            if quantity > 1 { quantity -= 1 }     // ✅ normal add flow: keep >= 1
                        }
                    } label: {
                        Circle()
                            .fill(Color(.systemGray5))
                            .frame(width: 44, height: 44)
                            .overlay(Image(systemName: "minus").font(.system(size: 18, weight: .bold)))
                    }

                    Text("\(quantity)")
                        .font(.menuRegular(20).weight(.semibold))

                    Button { quantity += 1 } label: {
                        Circle()
                            .fill(Color(.systemGray5))
                            .frame(width: 44, height: 44)
                            .overlay(Image(systemName: "plus").font(.system(size: 18, weight: .bold)))
                    }
                }

                // Action button
                Button {
                    if isRemoveMode {
                        // ✅ remove line (also pass selection so caller can clear if needed)
                        onAdd(item, 0, nil, item.price, selectedOptions, selectedAdditions)
                        return
                    }

                    guard quantity > 0 else { return }
                    let unit = item.price + extraPricePerUnit()

                    // ✅ pass selection payload for basket restore
                    onAdd(item, quantity, subtitleFromSelection(), unit, selectedOptions, selectedAdditions)

                } label: {
                    Text(actionTitle)
                        .font(.menuRegular(18).weight(.semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(actionBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
    }
    struct ProductSheetOverlay<Content: View>: View {
        let isRtl: Bool
        let content: Content

        @State private var measuredHeight: CGFloat = 0
        @Environment(\.dismiss) private var dismiss

        init(isRtl: Bool, @ViewBuilder content: () -> Content) {
            self.isRtl = isRtl
            self.content = content()
        }

        var body: some View {
            GeometryReader { geo in
                ZStack {

                    // ✅ Tap outside to close
                    Color.clear
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { dismiss() }

                    // ✅ Card (taps inside should NOT close)
                    content
                        .padding(.bottom,20)
                        .background(
                            GeometryReader { proxy in
                                Color.clear
                                    .preference(key: SheetContentHeightKey.self, value: proxy.size.height)
                            }
                        )
                        .frame(
                            width: min(500, geo.size.width - 40),
                            height: clampedHeight(in: geo)
                        )
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .shadow(color: .black.opacity(0.1), radius: 24, y: 14)
                        .contentShape(Rectangle())
                        .onTapGesture { } // ✅ swallow taps
                        .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
                }
                .onPreferenceChange(SheetContentHeightKey.self) { measuredHeight = $0 }
                
            }
        }

        private func clampedHeight(in geo: GeometryProxy) -> CGFloat {
            let maxHeight = geo.size.height * 0.9
            let minHeight: CGFloat = 220
            return min(max(measuredHeight, minHeight), maxHeight)
        }
    }
    
    private struct BirthdayVoucherBanner: View {
        let isRtl: Bool

        var body: some View {
            HStack(spacing: 12) {
                Image(systemName: "gift.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.primary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(isRtl ? "מתנת יום הולדת זמינה 🎉" : "Birthday voucher available 🎉")
                        .font(.menuRegular(16).weight(.semibold))

                    Text(isRtl ? "50% הנחה עד 200 — לחצו על סל הקניות כדי לממש"
                               : "50% off up to ₪200 — open your basket to redeem")
                        .font(.menuRegular(14))
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
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
    struct MemberCardSheet: View {
        @Environment(\.dismiss) private var dismiss
        @Environment(\.colorScheme) private var scheme   // ✅ ADD

        private let textColor = Color(hex: "#324E57") ?? .primary
        private let bgColor   = Color(.systemBackground)

        private var stamps: Int {
            let profile = UserDefaults.standard.dictionary(forKey: "memberProfileLocal") ?? [:]
            let raw = profile["stamps"] as? Int ?? 0
            return max(0, min(10, raw))
        }

        var body: some View {
            ZStack {
                bgColor.ignoresSafeArea()

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

                                // ✅ empty slots: white tint in dark mode, your old tint in light
                                let emptyTint: Color = (scheme == .dark)
                                    ? Color.white.opacity(0.55)
                                    : textColor.opacity(0.55)

                                ZStack {
                                    Image(systemName: {
                                        if isRewardSlot {
                                            return isEarned ? "gift.fill" : "gift"
                                        } else {
                                            return isEarned ? "cup.and.saucer.fill" : "cup.and.saucer"
                                        }
                                    }())
                                    .font(.system(size: 22, weight: .semibold))
                                    .foregroundColor(
                                        isEarned
                                            ? .primary          // ✅ earned = primary (cups + gift)
                                            : emptyTint
                                    )
                                    .opacity(isRewardSlot && !isEarned ? 1.0 : 1.0)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)

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
                    HStack(spacing: 11) {
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
            VStack(spacing: 0) {
                Color(.systemBackground)

                // 👇 bottom-only shadow
                LinearGradient(
                    colors: [
                        Color.black.opacity(0.12),
                        Color.black.opacity(0.06),
                        Color.clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 1)
            }
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

func formatPrice(_ value: Double) -> String {
    let rounded = (value * 100).rounded() / 100   // avoid floating-point junk
    let str = String(format: "%.2f", rounded)

    // remove trailing zeros + optional dot
    return str
        .replacingOccurrences(of: #"(\.0+)$"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"(\.\d*[1-9])0+$"#, with: "$1", options: .regularExpression)
}
struct ProductCard: View {
    let item: ShellMenuItem
    let quantityInBasket: Int?
    @State private var badgeBounce = false
    @Environment(\.isRtl) private var isRtl

    func formatPrice(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100   // avoid floating-point junk
        let str = String(format: "%.2f", rounded)

        // remove trailing zeros + optional dot
        return str
            .replacingOccurrences(of: #"(\.0+)$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(\.\d*[1-9])0+$"#, with: "$1", options: .regularExpression)
    }
    
    private var priceLabel: String {
        if isRtl {
            return formatPrice(item.price)
        } else {
            return "£\(formatPrice(item.price))"
        }
    }

    var body: some View {
        GeometryReader { geo in
            let cellWidth = geo.size.width

            ZStack(alignment: .topTrailing) {
                VStack(alignment: .leading, spacing: 6) {

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
                        .font(.menuRegular(17).weight(.semibold))
                        .lineLimit(2)
                        .padding(.leading, 5)

                    Text(priceLabel)
                        .padding(.leading, 5)
                        .font(.menuRegular(15))
                        .foregroundColor(
                            Color(UIColor { trait in
                                trait.userInterfaceStyle == .dark
                                    ? UIColor(Color.primary).withAlphaComponent(0.8)
                                    : UIColor(MenuTheme.accent)
                            })
                        )
                }
                .frame(width: cellWidth, alignment: .topLeading)

                if let qty = quantityInBasket, qty > 0 {
                    Text("\(qty)")
                        .font(.menuRegular(14).weight(.black))     // like CSS font-weight:900, font-size:14px
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedCornerShape(
                                radius: 16,                        // var(--r)
                                corners: isRtl
                                    ? [.topLeft, .bottomRight]     // rtl: r 0 r 0
                                    : [.topRight, .bottomLeft]     // ltr: 0 r 0 r
                            )
                            .fill(MenuTheme.buttonBackground)
                        )
                        .zIndex(1)
                }
            }
        }
        // ✅ ONLY CHANGE: clamp height
        .frame(
            height: min(
                UIScreen.main.bounds.width / 2 + 40,
                270   // 👈 hard cap for iPad Air 11"
            )
        )
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
    @Environment(\.colorScheme) private var colorScheme
    
    private func norm(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{200F}", with: "")
            .replacingOccurrences(of: "\u{200E}", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: " ") // nbsp -> space
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 10) {
                    Text(displayTitle(for: group))
                        .font(.menuRegular(18).weight(.semibold))
                        .padding(.horizontal, 0)
                        .padding(.bottom, 5)

                    if #available(iOS 16.0, *) {
                        Flow(spacing: 10, rowSpacing: 10) {
                            ForEach(group.items) { item in
                                pill(group: group, item: item)
                            }
                        }
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
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.bottom, group.type == .additions ? 18 : 0)
            }
        }
    }
    private func modifierLabel(_ item: ModifierItem) -> String {
        guard item.extraPrice > 0 else { return item.name }
        return "\(item.name) +\(String(format: "%.1f", item.extraPrice))"
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
            .font(.menuRegular(isRtl ? 15 : 17))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .fixedSize(horizontal: true, vertical: false)
            .background(isSelected ? MenuTheme.accent : Color(.systemGray5))
            .foregroundColor(
                isSelected
                ? (colorScheme == .dark ? .white : .white)
                : (colorScheme == .dark ? .white : .black)
            )
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
                // ✅ selecting default wipes other selections in THIS group
                removeAllInGroup()
                selectedAdditions.insert(defaultNorm)
                return
            }

            // toggle tapped non-default
            if selectedAdditions.contains(tapped) {
                selectedAdditions.remove(tapped)
            } else {
                selectedAdditions.insert(tapped)
            }

            // ✅ any non-default selected => default must be off
            selectedAdditions.remove(defaultNorm)

            // ✅ if user removed last non-default => fall back to default
            let hasAnyInGroup = selectedAdditions.contains(where: { groupNames.contains($0) })
            if !hasAnyInGroup {
                selectedAdditions.insert(defaultNorm)
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
    let editingLineId: Int?                 // ✅ NEW: source of truth for “editing”
    let initialQuantityInBasket: Int?
    let initialSelectedOptions: [String: String]
    let initialSelectedAdditions: Set<String>

    // ✅ return selection payload so basket can restore modifiers later
    let onAdd: (ShellMenuItem, Int, String?, Double, [String:String], Set<String>) -> Void

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    @State private var quantity: Int
    @State private var heroFrozenImage: KFCrossPlatformImage? = nil
    @State private var selectedOptions: [String: String] = [:]
    @State private var selectedAdditions: Set<String> = []
    @State private var note: String = ""
    @FocusState private var noteFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isRtl) private var isRtl

    @State private var inMyItems = false

    // ✅ dynamic detent measurement
    @State private var measuredContentH: CGFloat = 520
    @State private var selectedDetent: PresentationDetent = .large

    private let heroH: CGFloat = 300
    private let bottomBarH: CGFloat = 60
    private let bottomBarExtraPad: CGFloat = 50

    private struct SheetHKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }

    private func norm(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{200F}", with: "")
            .replacingOccurrences(of: "\u{200E}", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    init(
        item: ShellMenuItem,
        editingLineId: Int?,                  // ✅ NEW
        initialQuantityInBasket: Int?,
        initialSelectedOptions: [String: String],
        initialSelectedAdditions: Set<String> = [],
        onAdd: @escaping (ShellMenuItem, Int, String?, Double, [String:String], Set<String>) -> Void
    ) {
        self.item = item
        self.editingLineId = editingLineId
        self.initialQuantityInBasket = initialQuantityInBasket
        self.initialSelectedOptions = initialSelectedOptions
        self.initialSelectedAdditions = initialSelectedAdditions
        self.onAdd = onAdd

        // ✅ Quantity init:
        // - Editing an existing line → use its quantity (even if it’s 1)
        // - New add flow → default 1
        let baseQty = initialQuantityInBasket ?? 1
        _quantity = State(initialValue: baseQty)

        // ✅ OPTIONS defaults
        var defaults: [String: String] = initialSelectedOptions
        if let groups = item.modifiers {
            for group in groups where group.type == .options {
                let key = norm(group.title)

                let existing =
                    defaults.first(where: { norm($0.key) == key })?.value
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? ""

                if existing.isEmpty, let first = group.items.first {
                    defaults[group.title] = first.name   // keep ORIGINAL title/name
                }
            }
        }

        // normalize keys/values to match ModifierListView comparisons
        var normalizedDefaults: [String: String] = [:]
        for (k, v) in defaults {
            normalizedDefaults[norm(k)] = norm(v)
        }
        _selectedOptions = State(initialValue: normalizedDefaults)

        // ✅ ADDITIONS defaults
        var adds = Set(initialSelectedAdditions.map(norm))
        if let groups = item.modifiers {
            for g in groups where g.type == .additions {
                guard let first = g.items.first else { continue }
                let groupNames = Set(g.items.map { norm($0.name) })
                let defaultNorm = norm(first.name)

                let hasAny = adds.contains(where: { groupNames.contains($0) })
                if !hasAny {
                    adds.insert(defaultNorm)
                } else {
                    let hasNonDefault = adds.contains(where: { groupNames.contains($0) && $0 != defaultNorm })
                    if hasNonDefault { adds.remove(defaultNorm) }
                }
            }
        }
        _selectedAdditions = State(initialValue: adds)
    }

    // ✅ NEW: edit mode is based on lineId, not quantity
    private var isUpdateMode: Bool { editingLineId != nil }
    private var existsInBasket: Bool { initialQuantityInBasket != nil }
    private var isRemoveMode: Bool { existsInBasket && quantity == 0 }

    private var actionTitle: String {
        if isRemoveMode { return isRtl ? "הסר" : "Remove" }
        if isUpdateMode { return isRtl ? "עדכן" : "Update" }
        return isRtl ? "הוסף" : "Add"
    }

    private var actionBackground: Color {
        isRemoveMode ? .red : MenuTheme.buttonBackground
    }

    private func extraPricePerUnit() -> Double {
        guard let groups = item.modifiers else { return 0 }
        return groups.reduce(0) { total, group in
            switch group.type {
            case .options:
                let gKey = norm(group.title)
                if let selectedName = selectedOptions[gKey],
                   let opt = group.items.first(where: { norm($0.name) == norm(selectedName) }) {
                    return total + opt.extraPrice
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
        let total = (item.price + extraPricePerUnit()) * Double(max(quantity, 0))
        return isRtl ? formatPrice(total) : "£\(formatPrice(total))"
    }

    private var unitPriceLabel: String {
        isRtl ? formatPrice(item.price) : "£\(formatPrice(item.price))"
    }

    private func subtitleFromSelection() -> String? {
        guard let groups = item.modifiers else {
            let clean = note.trimmingCharacters(in: .whitespacesAndNewlines)
            return clean.isEmpty ? nil : (isRtl ? "הערה: \(clean)" : "Note: \(clean)")
        }

        var parts: [String] = []

        for g in groups where g.type == .options {
            let gKey = norm(g.title)
            guard let selected = selectedOptions[gKey],
                  let first = g.items.first else { continue }
            if norm(selected) != norm(first.name) {
                parts.append(norm(selected))
            }
        }

        let defaultAdditionsNorm: Set<String> = Set(
            groups.filter { $0.type == .additions }
                .compactMap { $0.items.first?.name }
                .map(norm)
        )

        let addNames: [String] = Array(
            Set(
                selectedAdditions
                    .map(norm)
                    .filter { !$0.isEmpty }
                    .filter { !defaultAdditionsNorm.contains($0) }
            )
        ).sorted()

        if !addNames.isEmpty { parts.append(addNames.joined(separator: ", ")) }

        let clean = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.isEmpty { parts.append(isRtl ? "הערה: \(clean)" : "Note: \(clean)") }

        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private var computedDetents: Set<PresentationDetent> {
        let screenH = UIScreen.main.bounds.height
        let maxH = screenH * 0.88
        let minH: CGFloat = 420
        let target = min(max(measuredContentH + bottomBarH + bottomBarExtraPad, minH), maxH)
        return [.height(target), .large]
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color(.systemBackground).ignoresSafeArea(edges: .bottom)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {

                    // HERO
                    GeometryReader { geo in
                        let w = geo.size.width

                        ZStack(alignment: isRtl ? .topLeading : .topTrailing) {

                            Group {
                                if let img = heroFrozenImage {
                                    Image(uiImage: img)
                                        .resizable()
                                        .scaledToFill()
                                } else {
                                    KFImage(item.img)
                                        .onSuccess { heroFrozenImage = $0.image }
                                        .resizable()
                                        .scaledToFill()
                                }
                            }
                            .frame(width: w, height: heroH)
                            .clipped()

                            Button { dismiss() } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(.primary)
                                    .frame(width: 34, height: 34)
                                    .background(.ultraThinMaterial)
                                    .clipShape(Circle())
                            }
                            .padding(12)
                            .zIndex(10)
                            .opacity(isPad ? 0 : 1)
                            .allowsHitTesting(!isPad)
                        }
                        .frame(width: w, height: heroH)
                    }
                    .frame(height: heroH)
                    .clipped()
                    .clipShape(RoundedCorner(radius: 16, corners: [.topLeft, .topRight]))
                    .padding(.horizontal, 0)

                    // CONTENT
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.name)
                            .font(.menuRegular(20).weight(.semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text(unitPriceLabel)
                            .font(.menuRegular(18))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if let desc = item.description,
                           !desc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(desc)
                                .font(.menuRegular(16))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 16)

                    if inMyItems && !isPad {
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
                        .buttonStyle(.plain)
                        .padding(.horizontal, 18)
                    }

                    if let groups = item.modifiers, !groups.isEmpty {
                        ModifierListView(
                            groups: groups,
                            selectedOptions: $selectedOptions,
                            selectedAdditions: $selectedAdditions
                        )
                        .padding(.horizontal, 16)
                    }
                }
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: SheetHKey.self, value: geo.size.height)
                    }
                )
                .padding(.bottom, bottomBarH + 50) // ✅ requested extra bottom padding
            }

            bottomBar
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity)
                .background(Color(.systemBackground))
        }
        .onAppear {
            inMyItems = MyItemsStore.load().contains(where: { $0.id == item.id })
            selectedDetent = .height(min(max(measuredContentH + bottomBarH + bottomBarExtraPad, 420),
                                         UIScreen.main.bounds.height * 0.88))
        }
        .onPreferenceChange(SheetHKey.self) { h in
            let rounded = (h * 10).rounded() / 10
            if abs(measuredContentH - rounded) > 1 {
                measuredContentH = rounded
            }
        }
        .presentationDetents(computedDetents, selection: $selectedDetent)
        .presentationDragIndicator(.visible)
    }

    struct RoundedCorner: Shape {
        var radius: CGFloat
        var corners: UIRectCorner
        func path(in rect: CGRect) -> Path {
            Path(UIBezierPath(
                roundedRect: rect,
                byRoundingCorners: corners,
                cornerRadii: CGSize(width: radius, height: radius)
            ).cgPath)
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 16) {

            HStack(spacing: 22) {
                Button {
                    if existsInBasket {
                           if quantity > 0 { quantity -= 1 }     // ✅ allow 0
                       } else {
                           if quantity > 1 { quantity -= 1 }     // ✅ keep >= 1
                       }
                       Haptics.light()
                } label: {
                    Circle()
                        .fill(Color(.systemGray5))
                        .frame(width: 44, height: 44)
                        .overlay(Image(systemName: "minus").font(.system(size: 18, weight: .bold)))
                        .foregroundColor(.primary)
                }

                Text("\(quantity)")
                    .font(.menuRegular(20).weight(.semibold))

                Button {
                    quantity += 1
                    Haptics.light()
                } label: {
                    Circle()
                        .fill(Color(.systemGray5))
                        .frame(width: 44, height: 44)
                        .overlay(Image(systemName: "plus").font(.system(size: 18, weight: .bold)))
                        .foregroundColor(.primary)
                }
            }
            .frame(height: bottomBarH)

            Button {
                if isRemoveMode {
                    onAdd(item, 0, nil, item.price, selectedOptions, selectedAdditions)
                    Haptics.success()
                    dismiss()
                    return
                }

                guard quantity > 0 else { return }

                let subtitle = subtitleFromSelection()
                let unit = item.price + extraPricePerUnit()

                if quantity > 0 {
                    MyItemsStore.touch(
                        productId: item.id,
                        name: item.name,
                        imageURL: item.imageURL,
                        price: unit,
                        subtitle: subtitle,
                        selectedOptions: selectedOptions,
                        selectedAdditions: selectedAdditions
                    )
                    inMyItems = true
                }

                onAdd(item, quantity, subtitle, unit, selectedOptions, selectedAdditions)

                Haptics.success()
                dismiss()
            } label: {
                HStack {
                    if isRtl {
                        Text(actionTitle)
                            .font(.menuRegular(18).weight(.semibold))
                        Spacer()
                        Text(totalPriceLabel)
                            .font(.primariesDemi(18))
                    } else {
                        Text(actionTitle)
                            .font(.system(size: 18, weight: .bold))
                        Spacer()
                        Text(totalPriceLabel)
                            .font(.primariesDemi(18))
                    }
                }
                .padding(.horizontal, 20)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: bottomBarH)
                .background(actionBackground)  // ✅ red when remove
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .frame(height: bottomBarH)
        .padding(.bottom, isPad ? 10 : 0)
    }
}

struct BasketBar: View {
    @Environment(\.isRtl) private var isRtl
    let totalQuantity: Int
    let totalPrice: Double
    let onTap: () -> Void
    let isPad: Bool
    let onNewOrder: () -> Void

    private var priceLabel: String {
        if isRtl {
            return formatPrice(totalPrice)
        } else {
            return "£\(formatPrice(totalPrice))"
        }
    }

    var body: some View {
        // ✅ lock layout so "New Order" is visually on the RIGHT
        HStack(spacing: 12) {

            Button(action: onTap) {
                HStack {
                    HStack(spacing: 12) {
                        Text("\(totalQuantity)")
                            .font(.menuRegular(15).weight(.semibold))
                            .foregroundColor(MenuTheme.buttonBackground)
                            .frame(width: 28, height: 28)
                            .background(Color.white)
                            .clipShape(Circle())

                        Text(isRtl ? "המשך להזמנה" : "View order")
                            .font(.primariesDemi(18))
                            .foregroundColor(.white)
                    }

                    Spacer()

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
            .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight) // ✅ KEY LINE
            
            if isPad && 1==2 {
                Button(action: onNewOrder) {
                    Text("הזמנה חדשה")
                        .font(.menuRegular(17).weight(.semibold))
                        .foregroundColor(.white)
                        .frame(width: 160, height: 60)
                        .background(MenuTheme.buttonBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .environment(\.layoutDirection, .leftToRight) // ✅ keeps second button on the RIGHT
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
    @State private var birthdayVoucherApplied: Bool = UserDefaults.standard.bool(forKey: "birthdayVoucherApplied")
  
    private let appGroupId = "group.minis"
    private let membersUpdatedAtKey = "members.updatedAt"
    
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
        return (baseTotalForDiscounts * Double(discountPercent) / 100.0)
    }
    
    private func markBirthdayVoucherRedeemedThisYear() {
        var cal = Calendar.current
        cal.timeZone = TimeZone(identifier: "Asia/Jerusalem") ?? .current
        let y = cal.component(.year, from: Date())

        // ✅ global (your current checks)
        UserDefaults.standard.set(y, forKey: "birthdayVoucherRedeemedYear")

        // ✅ also mirror into memberProfileLocal.wallet
        var p = UserDefaults.standard.dictionary(forKey: "memberProfileLocal") ?? [:]
        var wallet = (p["wallet"] as? [String: Any]) ?? [:]
        wallet["birthdayVoucherRedeemedYear"] = y
        p["wallet"] = wallet
        UserDefaults.standard.set(p, forKey: "memberProfileLocal")

        // ✅ clear applied flag
        UserDefaults.standard.set(false, forKey: "birthdayVoucherApplied")
    }
    private var birthdayVoucherAvailableNow: Bool {
        let p = UserDefaults.standard.dictionary(forKey: "memberProfileLocal") ?? [:]
        let isMember = !p.isEmpty

        func monthNowIL() -> Int {
            var cal = Calendar.current
            cal.timeZone = TimeZone(identifier: "Asia/Jerusalem") ?? .current
            return cal.component(.month, from: Date())
        }
        func yearNowIL() -> Int {
            var cal = Calendar.current
            cal.timeZone = TimeZone(identifier: "Asia/Jerusalem") ?? .current
            return cal.component(.year, from: Date())
        }

        let redeemedYear = UserDefaults.standard.integer(forKey: "birthdayVoucherRedeemedYear")
        if redeemedYear == yearNowIL() { return false }

        let birthMonth = (p["birthMonth"] as? Int)
            ?? ( (p["birthdayMMDD"] as? String).flatMap { Int($0.prefix(2)) } )

        guard isMember, let bm = birthMonth else { return false }
        return bm == monthNowIL()
    }

    private var birthdayDiscountCap: Double { 200.0 }     // ₪200
    private var birthdayDiscountPercent: Double { 0.5 }   // 50%

    private var birthdayDiscountAmount: Double {
        guard birthdayVoucherApplied else { return 0 }
        // apply to subtotal AFTER free coffee / happy hour removal base (same base you already use)
        let base = max(0, baseTotalForDiscounts) // you already compute this
        return min(birthdayDiscountCap, base * birthdayDiscountPercent)
    }
    
    
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
   

    private var discountedTotal: Double {
        let raw = max(0, baseTotalForDiscounts - discountAmount - birthdayDiscountAmount)
        return roundTotal(raw)
    }

    private var shownDiscountAmount: Double {
        max(0, roundTotal(baseTotalForDiscounts) - discountedTotal)
    }

    private func roundTotal(_ value: Double) -> Double {
        // ✅ Vitamin: no rounding
        if miniAppId == 13 { return value }

        // existing behavior for others
        let floorValue = floor(value)
        let fraction = value - floorValue
        return fraction >= 0.5 ? ceil(value) : floorValue
    }

 

  
    private var skipApplePay: Bool {
      
        return UserDefaults.standard.bool(forKey: "debugSkipApplePay")
        
    }

    private var detents: Set<PresentationDetent> {
        let screenH = UIScreen.main.bounds.height
        let maxCustom = screenH * 0.9

        let discountExtra: CGFloat = (discountPercent > 0) ? 60 : 0

        let coffeeRedeemExtra: CGFloat = canRedeemCoffeeNow ? 60 : 0

        // ✅ birthday button OR birthday discount row
        let birthdayExtra: CGFloat = (birthdayVoucherAvailableNow && !birthdayVoucherApplied) ? 60 : 0
        let birthdayLineExtra: CGFloat = birthdayVoucherApplied ? 34 : 0

        let fitted = min(
            contentHeight
            + 160
            + discountExtra
            + coffeeRedeemExtra
            + birthdayExtra
            + birthdayLineExtra,
            maxCustom
        )

        return fitted < maxCustom
            ? [.height(fitted), .large]
            : [.large]
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
                    .padding(.bottom, isPad ? 100 : 15)
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
                    ToolbarItem(placement: .topBarLeading) {
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
                .onDisappear {
                    UserDefaults.standard.removeObject(forKey: "member.freeCoffeeLineId")
                }
                .onAppear {
                   
                    UserDefaults.standard.removeObject(forKey: "member.freeCoffeeLineId")
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
                    @AppStorage("checkout.intent")  var checkoutIntentRaw: String = "ta"

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
    
    private var happyHourEligibleLineIds: Set<Int> {
        guard isHappyHourNow() else { return [] }

        return Set(entries.compactMap { e in
            let cat = normName(e.item.category)
            let name = normName(e.item.name)

            // include categories
            let inCat = cat.contains("מאפים") || cat.contains("כריכים")
            if !inCat { return nil }

            // exclude toast products
            if name.contains("טוסטים") || name.contains("טוסט") { return nil }

            // exclude gift line
            if freeCoffeeLineId != 0 && e.id == freeCoffeeLineId { return nil }

            return e.id
        })
    }

    private func hasHappyHour(for entry: BasketEntry) -> Bool {
        happyHourEligibleLineIds.contains(entry.id)
    }
    
    private var happyHourPercent: Double { 0.30 }

    // 16:00–16:59 (London). Change TZ if needed.
    private func isHappyHourNow() -> Bool {
        let tz = TimeZone(identifier: "Asia/Jerusalem") ?? .current
        var cal = Calendar.current
        cal.timeZone = tz

        let hour = cal.component(.hour, from: Date())
        return hour == 16
    }

    private func isExcludedToast(_ name: String) -> Bool {
        let n = normName(name)
        return n.contains("טוסטים") || n.contains("טוסט")
    }

    func nextMenuTicketNumber() -> Int {
       let key = "menu.localTicketNumber"
       let v = UserDefaults.standard.integer(forKey: key) + 1
       UserDefaults.standard.set(v, forKey: key)
       return v
   }

    
    private func isHappyHourEligible(_ entry: BasketEntry) -> Bool {
        guard isHappyHourNow() else { return false }
        let cat = normName(entry.item.category)
        guard cat.contains("מאפים") || cat.contains("כריכים") else { return false }
        guard !isExcludedToast(entry.item.name) else { return false }

        // don’t discount the free coffee line
        let freeId = freeCoffeeLineId
        if freeId != 0 && entry.id == freeId { return false }

        return true
    }

    private func unitPriceAfterHappyHour(for entry: BasketEntry) -> Double {
        guard isHappyHourEligible(entry) else { return entry.unitPrice }
        return entry.unitPrice * (1.0 - happyHourPercent)
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
                            ? String(Int(roundTotal(totalAfterFreeCoffee)))
                            : "£\(Int(roundTotal(totalAfterFreeCoffee)))"
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
                
                if birthdayVoucherApplied {
                    HStack {
                        Text("שובר יום הולדת 50% (עד ₪200)")
                            .font(.menuRegular(17).weight(.semibold))
                        Spacer()
                        Text(isRtl ? "-\(String(format: "%.0f", birthdayDiscountAmount))"
                                   : "-₪\(String(format: "%.0f", birthdayDiscountAmount))")
                            .font(.menuRegular(17).weight(.semibold))
                    }
                    .foregroundColor(.secondary)
                }

                HStack {
                    Text(isRtl ? "סה\"כ" : "Total")
                        .font(.menuRegular(18).weight(.semibold))
                    Spacer()
                    Text(formatPrice(discountedTotal))
                        .font(.menuRegular(18).weight(.semibold))
                }
                if birthdayVoucherAvailableNow && !birthdayVoucherApplied {
                    Button {
                        birthdayVoucherApplied = true
                        UserDefaults.standard.set(true, forKey: "birthdayVoucherApplied")
                        Haptics.success()
                    } label: {
                        Text("ממש שובר יום הולדת 🎁")
                            .font(.menuRegular(17).weight(.semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(MenuTheme.buttonBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                   
                }
                
                if canRedeemCoffeeNow {
                    Button {
                        let coffeesNow = coffeeUnitsInOrder(coffeeEntries)
                        applyFreeCoffeeToBasket()
                        redeemFreeCoffeeAndAdjustStamps(coffeesEarned: coffeesNow)
                        Haptics.success()
                    } label: {
                        Text("ממש קפה חינם ☕️")
                            .font(.menuRegular(17).weight(.semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(MenuTheme.buttonBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
            }
            .foregroundColor(.primary)
            .padding(.horizontal, 24)
            .padding(.top, 6)

            if isZeroPayableTotal {
                Button {
                    submitFreeOrderFlow()
                } label: {
                    Text(isRtl ? "שלח הזמנה" : "Send order")
                        .font(.menuRegular(17).weight(.semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(MenuTheme.buttonBackground.opacity(isSubmitting ? 0.5 : 1))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .disabled(isSubmitting)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            } else {

                if isPad {

                    Button {
                        
                      
                       
                        Haptics.light()
                    } label: {
                        Text("המשך להזמנה")
                            .font(.menuRegular(17).weight(.semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                            .background(MenuTheme.buttonBackground.opacity(isSubmitting ? 0.5 : 1))
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .disabled(isSubmitting)
                    .padding(.horizontal, 16)
                    .padding(.bottom, isPad ? 20 : 8)

                } else {

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
            }
        }
        .background(Color(.systemBackground))
      
    }

    
    private func redeemFreeCoffeeAndAdjustStamps(coffeesEarned: Int) {
        let before = currentStamps()
        let after  = before + coffeesEarned - 10
        setStamps(max(0, after))
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

    private let coffeeStampNames: Set<String> = [
        "אספרסו",
        "הפוך",
        "אמריקנו",
        "מקיאטו",
        "קורטדו",
        "קפה שחור"
    ]
    
    private func normName(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{200F}", with: "")
            .replacingOccurrences(of: "\u{200E}", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    private var happyHourDiscountAmount: Double {
        guard isHappyHourNow() else { return 0 }

        return entries.reduce(0.0) { sum, e in
            guard happyHourEligibleLineIds.contains(e.id) else { return sum }
            let full = e.unitPrice * Double(e.quantity)
            let disc = (e.unitPrice * (1.0 - happyHourPercent)) * Double(e.quantity)
            return sum + (full - disc)
        }
    }
    
    private func isCoffeeProduct(_ name: String) -> Bool {
        let n = normName(name)
        return coffeeStampNames.contains(where: { n == $0 || n.hasPrefix($0) })
    }
    private var baseTotalForDiscounts: Double {
        max(0, totalPrice - freeCoffeeDiscount - happyHourDiscountAmount)
    }
    private func currentStamps() -> Int {
        let p = UserDefaults.standard.dictionary(forKey: "memberProfileLocal") ?? [:]
        return max(0, min(10, p["stamps"] as? Int ?? 0))
    }

    private func setStamps(_ v: Int) {
        var p = UserDefaults.standard.dictionary(forKey: "memberProfileLocal") ?? [:]
        p["stamps"] = max(0, min(10, v))
        UserDefaults.standard.set(p, forKey: "memberProfileLocal")
    }
    private var coffeeEntries: [BasketEntry] {
        entries.filter { isCoffeeProduct($0.item.name) && $0.quantity > 0 }
    }

    private var canRedeemCoffeeNow: Bool {
        let freeId = UserDefaults.standard.integer(forKey: "member.freeCoffeeLineId")
        guard freeId == 0 else { return false }
        guard !coffeeEntries.isEmpty else { return false }

        let stampsBefore = currentStamps()
        let coffeesNow   = coffeeUnitsInOrder(coffeeEntries)

        // ✅ 10th coffee is free
        return stampsBefore + coffeesNow >= 10
    }
    
    private func applyFreeCoffeeToBasket() {
        guard canRedeemCoffeeNow else { return }

        // pick the cheapest coffee line (by unitPrice)
        guard let target = coffeeEntries.min(by: { $0.unitPrice < $1.unitPrice }) else { return }

        // ✅ We cannot mutate `entries` here because it's a let (passed in).
        // So: store a "free coffee lineId" locally, and render price as 0 for that line.
        UserDefaults.standard.set(target.id, forKey: "member.freeCoffeeLineId")
    }
    private func effectiveUnitPrice(for entry: BasketEntry) -> Double {
        let freeId = UserDefaults.standard.integer(forKey: "member.freeCoffeeLineId")
        if freeId != 0 && entry.id == freeId && isCoffeeProduct(entry.item.name) {
            return 0
        }
        return entry.unitPrice
    }
    private func coffeeUnitsInOrder(_ entries: [BasketEntry]) -> Int {
        let targets = Set(coffeeStampNames.map(normName))

        var count = 0
        for e in entries {
            let name = normName(e.item.name)

            // ✅ exact match OR starts-with (in case your products come like "הפוך גדול")
            let isCoffee = targets.contains(name) || targets.contains(where: { name.hasPrefix($0) })

            if isCoffee {
                count += max(0, e.quantity)
            }
        }
        return count
    }
    
    private func addCoffeeStampsLocally(from entries: [BasketEntry]) {
        let earned = coffeeUnitsInOrder(entries)
        guard earned > 0 else { return }

        var profile = UserDefaults.standard.dictionary(forKey: "memberProfileLocal") ?? [:]
        let current = profile["stamps"] as? Int ?? 0

        guard current < 10 else { return }

        let newValue = min(10, current + earned)
        profile["stamps"] = newValue

        // ✅ Save to standard defaults (current behavior)
        UserDefaults.standard.set(profile, forKey: "memberProfileLocal")
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: membersUpdatedAtKey)

        // ✅ App Clip → also save into App Group so full app can read it
        #if APPCLIP
        if let suite = UserDefaults(suiteName: appGroupId) {
            suite.set(profile, forKey: "memberProfileLocal")
            suite.set(Date().timeIntervalSince1970, forKey: membersUpdatedAtKey)
            suite.synchronize()
        }
        #endif

        // optional: keep in sync if you use it
        UserDefaults.standard.set(profile, forKey: "pendingMemberJoin")
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
                    addCoffeeStampsLocally(from: entries)
                    
                    if UserDefaults.standard.bool(forKey: "birthdayVoucherApplied") {
                        markBirthdayVoucherRedeemedThisYear()
                    }
                    
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
        if isRtl {
            return formatPrice(value)
        } else {
            return "£\(formatPrice(value))"
        }
    }

    private var freeCoffeeDiscount: Double {
        let freeId = UserDefaults.standard.integer(forKey: "member.freeCoffeeLineId")
        guard freeId != 0 else { return 0 }
        guard let entry = entries.first(where: { $0.id == freeId }) else { return 0 }
        guard isCoffeeProduct(entry.item.name) else { return 0 }
        return entry.unitPrice * Double(entry.quantity)   // make the whole line free
    }

    private var isZeroPayableTotal: Bool {
        // discountedTotal is already rounded in your logic
        return discountedTotal <= 0.0001
    }
    private func submitFreeOrderFlow() {
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

        // ✅ skip payment and just submit
        startSubmitOrder()
    }
    private var freeCoffeeLineId: Int {
        UserDefaults.standard.integer(forKey: "member.freeCoffeeLineId")   // 0 = none
    }
    private var totalAfterFreeCoffee: Double {
        max(0, totalPrice - freeCoffeeDiscount)
    }
    @ViewBuilder
    private func basketRow(_ entry: BasketEntry) -> some View {

        let unit = effectiveUnitPrice(for: entry)
        let lineTotal = unit * Double(entry.quantity)

        let isGift = (freeCoffeeLineId != 0 && entry.id == freeCoffeeLineId && isCoffeeProduct(entry.item.name))
        let hh = hasHappyHour(for: entry) && !isGift

        let fullLineTotal = entry.unitPrice * Double(entry.quantity)
        let hhLineTotal = (entry.unitPrice * (1.0 - happyHourPercent)) * Double(entry.quantity)

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

                if isGift {
                    Text("מתנה")
                        .font(.menuRegular(16).weight(.semibold))
                        .foregroundColor(.green)

                } else if hh {
                    HStack(spacing: 8) {
                        Text(formatLineTotal(fullLineTotal))
                            .font(.menuRegular(15).weight(.semibold))
                            .foregroundColor(.secondary)
                            .strikethrough(true, color: .primary.opacity(0.6))

                        Text(formatLineTotal(hhLineTotal))
                            .font(.menuRegular(16).weight(.semibold))
                            .foregroundColor(MenuTheme.buttonBackground)
                    }

                } else {
                    Text(formatLineTotal(lineTotal))
                        .font(.menuRegular(16).weight(.semibold))
                        .foregroundColor(.secondary)
                }
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
        .onTapGesture { onProductTap(entry.id, entry.item) }
    
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
                TextField(isRtl ? "טלפון" : "Phone", text: $phone)
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
#if APPCLIP
@State private var showStoreSheet = false
#endif
    
#if APPCLIP
@State private var showInstallOverlay = false
#endif
    
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
    
    private var stampsEarnedNow: Int {
        let coffeeNames: Set<String> = [
            "אספרסו",
            "הפוך",
            "אמריקנו",
            "מקיאטו",
            "קורטדו",
            "תה",
            "תה חורף"
            
        ]

        func norm(_ s: String) -> String {
            s.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\u{200F}", with: "")
                .replacingOccurrences(of: "\u{200E}", with: "")
                .replacingOccurrences(of: "\u{00A0}", with: " ")
        }

        return entries.reduce(0) { total, entry in
            let name = norm(entry.item.name)
            let isCoffee = coffeeNames.contains { name == $0 || name.hasPrefix($0) }
            return total + (isCoffee ? entry.quantity : 0)
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
                        ? "נשלח הודעה כשמוכן"
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
                                Text(
                                    isRtl
                                    ? "\(entry.item.name) × \(entry.quantity)" :
                                    "\(entry.quantity) × \(entry.item.name)"
                                   
                                )
                                    .font(.menuRegular(16).weight(.regular))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(formatPrice(lineTotal))

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
                        Text(formatPrice(totalPrice))
                            .font(.menuRegular(15).weight(.semibold))
                    }
                    .padding(.top, 4)
                }
                .padding(.horizontal, 20)
                
                
                
#if APPCLIP
                if MenuTheme.miniId != 3{
                    MembersUpsellCard(
                        isRtl: isRtl,
                        stampsEarnedNow:stampsEarnedNow ,
                        onDownloadTap: {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            
                            // ✅ Present App Store sheet (no SwiftUI sheet)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                StoreProductPresenter.shared.present(appId: 6737725110)
                            }
                        }
                    )
                    .padding(.horizontal, 20)
                }

// This attaches the overlay presenter


#endif
                
                
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


        .navigationTitle(isRtl ? "אישור" : "Confirmation")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(isRtl ? "אישור" : "Confirmation")
                    .font(.menuRegular(18))
            }
        }
#if APPCLIP
        .sheet(isPresented: $showStoreSheet) {
            AppStoreSheet(appId: 6737725110, isPresented: $showStoreSheet)
                .ignoresSafeArea()
        }
#endif
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
    @Environment(\.isRtl) private var isRtl   // app-wide (from root)

    @AppStorage(CheckoutKeys.intent) private var checkoutIntentRaw: String = ""
    @AppStorage(CheckoutKeys.serviceLabel) private var serviceModeLabel: String = ""
    @AppStorage(CheckoutKeys.didShowWelcome) private var didShowWelcome: Bool = false

    // ✅ Language + global RTL (single source of truth is app.isRtl)
    @AppStorage("app.langOverride") private var langOverride: String = "he"
    @AppStorage("app.isRtl") private var appIsRtl: Bool = true

    // ✅ Optional legacy sync (if you still use "direction" elsewhere)
    @AppStorage("direction") private var direction: String = "rtl"

    @State private var page = 0
    @State private var timer: Timer?

    private let images: [String] = [
        "https://minis.studio/images/wallpaper_bh3.jpg",
        "https://minis.studio/images/wallpaper_bh2.jpg",
        "https://minis.studio/images/wallpaper_bh1.png"
    ]

    private var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    // ✅ Responsive sizing
    private var titleFont: CGFloat { isPhone ? 44 : 70 }
    private var subtitleFont: CGFloat { isPhone ? 22 : 32 }
    private var subtitleTopPad: CGFloat { isPhone ? 18 : 40 }

    private var buttonWidth: CGFloat { isPhone ? 160 : 230 }
    private var buttonHeight: CGFloat { isPhone ? 72 : 100 }
    private var buttonCorner: CGFloat { isPhone ? 28 : 40 }
    private var buttonFont: CGFloat { isPhone ? 22 : 28 }

    private var sidePadding: CGFloat { isPhone ? 18 : 20 }
    private var bottomSpacer: CGFloat { isPhone ? 26 : 40 }

    // ✅ Push the dine-in / takeaway buttons down a bit
    private var buttonsTopPad: CGFloat { isPhone ? 22 : 30 }

    // ✅ Effective language
    private var effectiveLang: String {
        if langOverride == "en" || langOverride == "he" { return langOverride }
        let code = Locale.preferredLanguages.first?.prefix(2).lowercased() ?? "en"
        return (code == "he") ? "he" : "en"
    }

    // ✅ The ONLY RTL decision inside this view (drives the whole app)
    private var effectiveIsRtl: Bool { effectiveLang == "he" }

    // ✅ Locale for this view (root can also set it; doing it here makes welcome perfect)
    private var effectiveLocale: Locale {
        Locale(identifier: effectiveIsRtl ? "he_IL" : "en_GB")
    }

    // ✅ Labels
    private var welcomeTitle: String { effectiveIsRtl ? "ברוכים הבאים" : "Welcome" }
    private var welcomeSubtitle: String { effectiveIsRtl ? "לחצו להזמנה" : "Tap to order" }
    private var dineInLabel: String { effectiveIsRtl ? "לשבת" : "Dine-in" }
    private var takeawayLabel: String { effectiveIsRtl ? "לקחת" : "Takeaway" }

    var body: some View {
        ZStack {

            // ✅ Background slider (DO NOT intercept touches)
            TabView(selection: $page) {
                ForEach(Array(images.enumerated()), id: \.offset) { idx, urlStr in
                    GeometryReader { geo in
                        KFImage(URL(string: urlStr))
                            .resizable()
                            .scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                            .tag(idx)
                    }
                    .ignoresSafeArea()
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            .allowsHitTesting(false)

            // ✅ Dark overlay (also DO NOT intercept touches)
            LinearGradient(
                colors: [Color.black.opacity(0.40), Color.black.opacity(0.40)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            // ✅ Content (tap targets)
            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: isPhone ? 14 : 18) {
                    Text(welcomeTitle)
                        .font(.menuRegular(titleFont).weight(.heavy))
                        .foregroundColor(.white)
                        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                        .multilineTextAlignment(.center)

                    Text(welcomeSubtitle)
                        .font(.menuRegular(subtitleFont).weight(.bold))
                        .foregroundColor(.white.opacity(0.92))
                        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                        .multilineTextAlignment(.center)
                        .padding(.top, subtitleTopPad)

                    HStack(spacing: 14) {
                        kioskButton(title: dineInLabel) { choose(intent: "sit") }
                        kioskButton(title: takeawayLabel) { choose(intent: "ta") }
                    }
                    .padding(.top, isPhone ? 26 : 34)
                }
                .padding(.horizontal, sidePadding)

                Spacer(minLength: bottomSpacer)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }

        // ✅ Place pill safely under top bars
        .safeAreaInset(edge: .top) {
            HStack {
                Spacer()
               // languagePill
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 6)
            .background(Color.clear)
            .zIndex(999)
        }

        .toolbar(.hidden, for: .navigationBar)
        .navigationBarHidden(true)

        // ✅ Timer
        .onAppear {
            // Make sure global state matches current language
            syncGlobalLanguageState()

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

        // ✅ When language changes -> flip RTL for the WHOLE APP instantly
        .onChange(of: langOverride) { _ in
            syncGlobalLanguageState()
        }

        // ✅ Ensure the welcome view itself always renders correctly
        .environment(\.layoutDirection, effectiveIsRtl ? .rightToLeft : .leftToRight)
        .environment(\.locale, effectiveLocale)
    }

    // MARK: - Global sync

    private func syncGlobalLanguageState() {
        let rtl = effectiveIsRtl

        // ✅ The key you inject from MINIS_02App root
        appIsRtl = rtl

        // ✅ Optional legacy sync
        direction = rtl ? "rtl" : "ltr"

        // If you also want to ensure any environment(\.isRtl) reads instantly in the stack:
        // (Root will re-inject anyway, but syncing doesn't hurt)
        UserDefaults.standard.set(rtl, forKey: "app.isRtl")
        UserDefaults.standard.set(direction, forKey: "direction")
    }

    // MARK: - Actions

    private func choose(intent: String) {
        checkoutIntentRaw = intent

        // ✅ Keep stored labels aligned with language
        if effectiveIsRtl {
            serviceModeLabel = (intent == "sit") ? "לשבת" : "לקחת"
        } else {
            serviceModeLabel = (intent == "sit") ? "Dine-in" : "Takeaway"
        }

        didShowWelcome = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        dismiss()
    }

    // MARK: - UI bits

    private var languagePill: some View {
        HStack(spacing: 6) {
            langButton(title: "EN", value: "en")
            Divider().frame(height: 16).opacity(0.25)
            langButton(title: "עב", value: "he")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
    }

    private func langButton(title: String, value: String) -> some View {
        let selected = (effectiveLang == value)

        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            langOverride = value   // ✅ triggers onChange -> syncGlobalLanguageState()
        } label: {
            Text(title)
                .font(.menuRegular(15).weight(.bold))
                .foregroundColor(selected ? .white : .white.opacity(0.85))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    selected
                    ? (Color(hex: "#324E57") ?? .black).opacity(0.85)
                    : Color.clear
                )
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func kioskButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.menuRegular(buttonFont).weight(.bold))
                .foregroundColor(Color(hex: "#324e57") ?? .black)
                .frame(width: buttonWidth, height: buttonHeight)
                .background(Color(hex: "#d2c1a5") ?? Color(.systemGray5))
                .clipShape(RoundedRectangle(cornerRadius: buttonCorner, style: .continuous))
                .shadow(color: .black.opacity(0.22), radius: 24, y: 10)
        }
        .buttonStyle(.plain)
    }
}


// MARK: - App Clip → Full App install overlay (native Apple sheet)
struct AppInstallOverlay: UIViewControllerRepresentable {
    let appId: String
    let position: SKOverlay.Position

    func makeUIViewController(context: Context) -> UIViewController {
        let vc = UIViewController()
        vc.view.backgroundColor = .clear
        return vc
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        guard let scene = uiViewController.view.window?.windowScene else {
            // If not attached yet, try again next runloop
            DispatchQueue.main.async { self.updateUIViewController(uiViewController, context: context) }
            return
        }

        // Avoid stacking overlays
        if let existing = scene.windows.first?.subviews.first(where: { String(describing: type(of: $0)).contains("SKOverlay") }) {
            _ = existing
        }

        let config = SKOverlay.AppConfiguration(appIdentifier: appId, position: position)
        let overlay = SKOverlay(configuration: config)
        overlay.present(in: scene)
    }
}

// MARK: - Members upsell card (App Clip only)
private struct MembersUpsellCard: View {
    let isRtl: Bool
    let stampsEarnedNow: Int
    let onDownloadTap: () -> Void
    private func stampsEarnedText(_ count: Int) -> String {
        guard count > 0 else { return "" }

        if count == 1 {
            return "הרווחת חותמת אחת לקפה 10 עלינו ☕️"
        } else {
            return "הרווחת \(count) חותמות לקפה 10 עלינו ☕️"
        }
    }
    private var shopName: String {
        let miniId = UserDefaults.standard.integer(forKey: "miniAppId")

        if miniId == 12 { return "בית העם" }
        if miniId == 13 { return "Vitamin" }

        // fallback (important)
        return UserDefaults.standard.string(forKey: "miniTitle")
            ?? "החנות"
    }
    
    var body: some View {
        VStack(spacing: 16) {

            // 👆 Earned message ABOVE the card
            if stampsEarnedNow > 0 {
                Text(stampsEarnedText(stampsEarnedNow))
                    .font(.menuRegular(16).weight(.semibold))
                    .foregroundColor(.primary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            // 🎁 Members card
            
            VStack(spacing: 18) {

                // Centered title
                Text(
                    isRtl
                    ? "החברים של \(shopName)"
                    : "Members club"
                )
                    .font(.menuRegular(20).weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .center)

                // Benefits list (left-aligned for readability)
                VStack(alignment: .leading, spacing: 15) {
                    bullet(isRtl ? "כל קפה 10 חינם ☕️"  : "Every 10th coffee is free")
                    bullet(isRtl ? "30% סוף יום על מאפים וכריכים" : "30% end-of-day discount on baked goods")
                   
                    bullet(isRtl ? "50% שובר יום הולדת" : "50% birthday voucher")
                 
                }
                .font(.menuRegular(15))
                .foregroundColor(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)

                // Centered button (no chevron)
                Button(action: onDownloadTap) {
                    Text(isRtl ? "הורד את האפליקציה" : "Download the full app")
                        .font(.menuRegular(17).weight(.semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(MenuTheme.buttonBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(18)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("•")
                .font(.menuRegular(16).weight(.bold))
            Text(text)
        }
    }
}

private enum MembersKeys {
    static let didPrompt = "members.didPrompt"
    static let profile   = "memberProfileLocal"
}

struct CategoryRail: View {
    let categories: [String]
    let selected: String
    let onTap: (String) -> Void

    @Binding var intent: ServiceIntent

    // ✅ NEW
    var showServiceSegment: Bool = true

    // ✅ existing
    var onServiceLongPress: (() -> Void)? = nil

    @Environment(\.colorScheme) private var scheme
    @Environment(\.isRtl) private var isRtl

    var body: some View {
        VStack(spacing: 10) {

            
            if MenuTheme.miniId == 12 {
                ServiceSegment(intent: $intent)
                    .frame(height: 46)
                    .padding(.horizontal, 10)
                    .padding(.top, 10)
            } else {
                Color.clear
                    .frame(height: 40)
                    .contentShape(Rectangle()) // ✅ makes the whole area tappable
                    .onLongPressGesture(minimumDuration: 1.2) {
                        UserDefaults.standard.set(true, forKey: "cashPointMode")
                        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                    }
            }
            
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 10) {
                    ForEach(categories, id: \.self) { cat in
                        Button { onTap(cat) } label: {

                            // ✅ Full-width hit area
                            HStack(spacing: 0) {
                                Text(cat)
                                    .font(.menuRegular(16).weight(.semibold))
                                    .foregroundColor(cat == selected ? .white : .primary.opacity(0.85))
                                    .multilineTextAlignment(.leading)

                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 10)
                            .padding(.horizontal, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(cat == selected ? MenuTheme.buttonBackground : Color.clear)
                            )
                            .contentShape(Rectangle()) // ✅ THIS is the key

                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(10)
                .padding(.top, 2)
            }
        }
        .frame(width: 200)
        .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
    }
}

extension View {
    @ViewBuilder func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition { transform(self) } else { self }
    }
}
 
// MARK: - Height reader helper

private struct HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension View {
    func readHeight(_ onChange: @escaping (CGFloat) -> Void) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear
                    .preference(key: HeightKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(HeightKey.self, perform: onChange)
    }
}



extension Notification.Name {
    static let productSheetContentHeight = Notification.Name("productSheetContentHeight")
}
extension Notification.Name {
    static let studentClaimArrived = Notification.Name("studentClaimArrived")
}

