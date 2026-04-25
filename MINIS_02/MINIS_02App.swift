import SwiftUI
import UIKit
import UserNotifications
import StripeApplePay
import Security
import Foundation
import Darwin

@main
struct MINIS_02App: App {

    // MARK: - App Delegate + Scene
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    // MARK: - Core App State
    @AppStorage("admin") private var isAdmin: Bool = false
    @AppStorage(AppSettings.Key.cashPointMode) private var cashPointMode: Bool = false
    @AppStorage(LangKeys.lang) private var appLang: String = "he"

    private var appIsRtl: Bool { appLang == "he" || appLang == "ar" }

    private var appLocale: Locale {
        switch appLang {
        case "ar": return Locale(identifier: "ar")
        case "en": return Locale(identifier: "en_GB")
        default:   return Locale(identifier: "he_IL")
        }
    }
    // ✅ Leave these unset by default (no bootstrap)
    @AppStorage("shopId") private var shopId: String = ""
    @AppStorage("miniAppId") private var miniAppId: Int = 0

    @AppStorage("launchMenuOnce") private var launchMenuOnce: Bool = false
    @AppStorage("autoPrintEnabled") private var autoPrintEnabled: Bool = true
    @AppStorage("direction") private var direction: String = "ltr"
    @AppStorage("deliveryLoc") private var deliveryLoc: String = ""

    // MARK: - Admin pairing / identity
    @AppStorage("admin.role") private var adminRole: String = "cashier"   // cashier/admin/grandManager/owner/kds
    private let principalId: String = PrincipalIdStore.getOrCreate()

    // MARK: - Student
    @State private var studentClaim: StudentClaim? = nil

    // MARK: - App Group + Keys
    private let appGroupId = "group.minis"
    private let kPendingUniversalLink = "pendingUniversalLink"
    private let kPendingStudentClaim  = "pendingStudentClaim.v1"

    // MARK: - MiniAppId presence (true “nil” = key is missing)
    private var storedMiniAppId: Int? {
        let key = "miniAppId"
        guard UserDefaults.standard.object(forKey: key) != nil else { return nil } // ✅ real nil = missing key
        let v = UserDefaults.standard.integer(forKey: key)
        return v > 0 ? v : nil
    }

    private var hasMiniAppContext: Bool {
        storedMiniAppId != nil
    }

    @MainActor
    private func clearMiniAppContext() {
        deliveryLoc = ""
        UserDefaults.standard.removeObject(forKey: "deliveryLoc")

        miniAppId = 0
        shopId = ""
        UserDefaults.standard.removeObject(forKey: "miniApinitpId")
        UserDefaults.standard.removeObject(forKey: "shopId")

        launchMenuOnce = false
        cashPointMode = false

    }
    
    

    @MainActor
    private func applyMiniAppContext(_ id: Int, url: URL) {
        guard id > 0 else {
            clearMiniAppContext()
            return
        }

        deliveryLoc = ""
        UserDefaults.standard.removeObject(forKey: "deliveryLoc")

        miniAppId = id
        UserDefaults.standard.set(id, forKey: "miniAppId")

        let sid = String(id)
        shopId = sid
        UserDefaults.standard.set(sid, forKey: "shopId")

        // optional query ?loc=
        if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let loc = comps.queryItems?.first(where: { $0.name == "loc" })?.value,
           !loc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {

            let clean = loc.trimmingCharacters(in: .whitespacesAndNewlines)
            deliveryLoc = clean
            UserDefaults.standard.set(clean, forKey: "deliveryLoc")
        }

        // keep your existing behavior
        resetShopUserDefaultsToDefaults()
        launchMenuOnce = true

        // ✅ Device rule:
        // iPad should start in CashPoint first (unless admin).
        // iPhone should start Home first.
        cashPointMode = isIPad ? true : false

        pingInstallIfNeeded(force: true)

        
    }

    // MARK: - Init
    init() {
        UserDefaults.standard.set(12, forKey: "miniAppId")

        configureNavBarAppearance()
        configureStripe()
        configureSegmented()

        // Keep your existing init logic
        UserDefaults.standard.removeObject(forKey: "printers.config.shop13")

        if let ip = detectLANIPv4() {
        } else {
        }

        // ✅ Clear drafts on launch (as you wanted)
        UserDefaults.standard.removeObject(forKey: "posSavedName")
        UserDefaults.standard.removeObject(forKey: "posSavedPhone")

        // ✅ NO BOOTSTRAP DEFAULT MINI HERE
        // miniAppId remains NIL (missing key) until a universal link / QR is scanned
        if let mid = storedMiniAppId {
            miniAppId = mid
            shopId = UserDefaults.standard.string(forKey: "shopId") ?? String(mid)
        } else {
            miniAppId = 0
            shopId = ""
        }
    }

    // MARK: - Body
    var body: some Scene {
        WindowGroup {
            Group {
                // ✅ 1) Admin always goes Tesla3
                if isAdmin {
                    Tesla3()
                        .tint(.primary)
                        .environment(\.layoutDirection, .leftToRight)

                // ✅ 2) No miniAppId stored => must scan QR / open minis.studio/<id>
                } else if !hasMiniAppContext {
                    MiniQRScanGateView(
                        onPasteLink: { s in
                            guard let url = URL(string: s) else { return }
                            handleIncoming(url: url)
                        }
                    )

                // ✅ 3) Has miniAppId:
                // iPad starts CashPoint, iPhone starts Home
                } else if cashPointMode {
                    CashPointView()
                        .tint(.primary)
                        .preferredColorScheme(.dark)
                        .
                    environment(\.locale, appLocale)
                        .environment(\.isRtl, appIsRtl)
                } else {
                    Tesla3()
                               .environment(\.layoutDirection, .leftToRight)
                               .environment(\.locale, appLocale)
                                  .environment(\.isRtl, appIsRtl)   // your custom env key
                }
                
            }
            .environment(\.isRtl, true)
            .environment(\.layoutDirection, .leftToRight)
            .environment(\.currency, "₪")
          // .environment(\.isRtl, direction == "rtl")
          //  .environment(\.layoutDirection, direction == "rtl" ? .rightToLeft : .leftToRight)
          //  .environment(\.currency, direction == "rtl" ? "₪" : "£")
            .accentColor(.primary)

            // MARK: - Universal Links / Deep Links
            .onOpenURL { url in
                handleIncoming(url: url)
            }
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                if let url = activity.webpageURL {
                    handleIncoming(url: url)
                } else {
                }
            }

            // MARK: - Cold launch handling
            .onAppear {
                loadPendingClaimFromAppGroupIfAny()

                // ✅ Enforce device-first rule at runtime too
                if !isAdmin, hasMiniAppContext {
                    cashPointMode = isIPad
                }

                if let s = MinisShared.sharedDefaults.string(forKey: kPendingUniversalLink),
                   let url = URL(string: s) {
                    handleIncoming(url: url)

                    MinisShared.sharedDefaults.removeObject(forKey: kPendingUniversalLink)
                    MinisShared.sharedDefaults.synchronize()
                }
            }

            // MARK: - Scene phase
            .onChange(of: scenePhase) { phase in
                switch phase {
                case .active:
                    pingInstallIfNeeded()

                    if isIPad && autoPrintEnabled {
                        OrdersAutoPrinter.shared.startPolling(interval: 10)
                    } else {
                        OrdersAutoPrinter.shared.stopPolling()
                    }

                case .inactive, .background:
                    OrdersAutoPrinter.shared.stopPolling()

                @unknown default:
                    break
                }
            }
            .onChange(of: autoPrintEnabled) { enabled in
                guard scenePhase == .active, cashPointMode else {
                    OrdersAutoPrinter.shared.stopPolling()
                    return
                }
                enabled
                ? OrdersAutoPrinter.shared.startPolling(interval: 10)
                : OrdersAutoPrinter.shared.stopPolling()
            }
        }
    }

    // MARK: - Incoming URL Router

    private func handleIncoming(url: URL) {
        guard url.host?.lowercased() == "minis.studio" else { return }

        // Save for attribution + cold-launch fallback
        MinisShared.sharedDefaults.set(url.absoluteString, forKey: kPendingUniversalLink)
        MinisShared.sharedDefaults.synchronize()

        // ✅ 1) STUDENT CLAIM FIRST
        if let claim = StudentClaim.from(url: url) {
            saveClaimToAppGroup(claim)
            NotificationCenter.default.post(name: .studentClaimArrived, object: nil)
            return
        }

        // Parse components once
        let pathParts = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }

        // ✅ 2) PAIR (admin/device claim) — uses same miniAppId rules
        // https://minis.studio/pair?miniAppId=12&token=GUID
        if url.path.lowercased().hasPrefix("/pair") {
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let miniStr = comps?.queryItems?.first(where: { $0.name == "miniAppId" })?.value
            let tokStr  = comps?.queryItems?.first(where: { $0.name == "token" })?.value

            let mid = Int(miniStr ?? "") ?? 0
            let tok = (tokStr ?? "").trimmingCharacters(in: .whitespacesAndNewlines)


            guard mid > 0, !tok.isEmpty else {
                return
            }

            Task { @MainActor in
                applyMiniAppContext(mid, url: url)
            }

            Task { await claimAdminInvite(miniAppId: mid, token: tok) }
            return
        }

        // ✅ 3) NORMAL shop links
        // https://minis.studio/12
        // https://minis.studio/shop/12
        // https://minis.studio/mini/12
        if let last = pathParts.last, let id = Int(last) {
            let miniType = pathParts.dropLast().last ?? "root"
            Task { @MainActor in
                applyMiniAppContext(id, url: url)
            }
            return
        }

    }

    // MARK: - Admin claim (pairing)

    @MainActor
    private func claimAdminInvite(miniAppId: Int, token: String) async {
        let base = UserDefaults.standard.string(forKey: "apiBase") ?? "https://minis.studio"
        guard let url = URL(string: "\(base)/api/admin/invites/claim") else { return }

        struct Req: Encodable {
            let miniAppId: Int
            let inviteToken: String
            let principalId: String
            let deviceName: String?
        }

        let payload = Req(
            miniAppId: miniAppId,
            inviteToken: token,
            principalId: principalId,
            deviceName: UIDevice.current.name
        )

        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        req.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-Id")
        req.httpBody = try? JSONEncoder().encode(payload)


        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let text = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"

            guard (200...299).contains(code) else {
                UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                return
            }

            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let ok = (obj?["ok"] as? Bool) ?? false
            guard ok else {
                UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                return
            }

            let role = (obj?["role"] as? String ?? "admin")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()

            adminRole = role
            UserDefaults.standard.set(role, forKey: "admin.role")

            if role == "admin" || role == "owner" || role == "grandmanager" {
                isAdmin = true
                cashPointMode = false
            } else if role == "cashier" {
                isAdmin = false
                // ✅ iPad cashier: start cashpoint. iPhone cashier: still starts Home (your rule)
                cashPointMode = isIPad
            } else if role == "kds" {
                isAdmin = false
                cashPointMode = false
            } else {
                isAdmin = false
                cashPointMode = isIPad
            }

            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        } catch {
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        }
    }

    // MARK: - Student Claim in App Group

    private func saveClaimToAppGroup(_ claim: StudentClaim) {
        guard let suite = UserDefaults(suiteName: appGroupId) else {
            return
        }
        guard let data = try? JSONEncoder().encode(claim) else {
            return
        }
        suite.set(data, forKey: kPendingStudentClaim)
        suite.synchronize()
    }

    private func loadPendingClaimFromAppGroupIfAny() {
        guard let suite = UserDefaults(suiteName: appGroupId) else { return }
        guard let data = suite.data(forKey: kPendingStudentClaim) else { return }

        guard let claim = try? JSONDecoder().decode(StudentClaim.self, from: data) else {
            suite.removeObject(forKey: kPendingStudentClaim)
            suite.synchronize()
            return
        }

        studentClaim = claim

        suite.removeObject(forKey: kPendingStudentClaim)
        suite.synchronize()

    }

    // MARK: - Install Ping

    private struct InstallPingPayload: Codable {
        let anonId: String
        let platform: String
        let appVariant: String
        let miniAppId: Int?
        let source: String?
        let campaign: String?
        let referrer: String?
    }

    private func getOrCreateAnonId() -> String {
        if let suite = UserDefaults(suiteName: appGroupId) {
            if let existing = suite.string(forKey: "anonUUID"), !existing.isEmpty {
                UserDefaults.standard.set(existing, forKey: "anonUUID")
                return existing
            }
            let id = UUID().uuidString
            suite.set(id, forKey: "anonUUID")
            suite.synchronize()
            UserDefaults.standard.set(id, forKey: "anonUUID")
            return id
        }

        if let existing = UserDefaults.standard.string(forKey: "anonUUID"), !existing.isEmpty {
            return existing
        }

        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "anonUUID")
        return id
    }

    private func buildAttributionFromPendingLink() -> (source: String?, campaign: String?, referrer: String?) {
        guard let s = MinisShared.sharedDefaults.string(forKey: kPendingUniversalLink),
              let url = URL(string: s)
        else { return (nil, nil, nil) }

        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let q = comps?.queryItems ?? []

        func qv(_ name: String) -> String? {
            q.first(where: { $0.name.lowercased() == name.lowercased() })?.value?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let utmSource = qv("utm_source")
        let utmCampaign = qv("utm_campaign")
        let utmMedium = qv("utm_medium")

        let host = url.host ?? ""
        let path = url.path
        let ref = ([host + path, utmMedium.map { "m:\($0)" }].compactMap { $0 }).joined(separator: "|")

        let source = (utmSource?.isEmpty == false) ? utmSource : "universal_link"
        let campaign = (utmCampaign?.isEmpty == false) ? utmCampaign : nil

        return (source, campaign, ref.isEmpty ? nil : ref)
    }

    private func shouldPingToday() -> Bool {
        let key = "installs.ping.lastDay"
        let day = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        let last = UserDefaults.standard.double(forKey: key)
        if last == day { return false }
        UserDefaults.standard.set(day, forKey: key)
        return true
    }

    private func pingInstallIfNeeded(force: Bool = false) {
        if !force && !shouldPingToday() { return }

        let anonId = getOrCreateAnonId()
        let attrib = buildAttributionFromPendingLink()

        let payload = InstallPingPayload(
            anonId: anonId,
            platform: "ios",
            appVariant: "app",
            miniAppId: (storedMiniAppId != nil) ? miniAppId : nil,
            source: attrib.source,
            campaign: attrib.campaign,
            referrer: attrib.referrer
        )

        guard let url = URL(string: "https://minis.studio/api/installs/ping") else { return }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(payload)

        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err = err {
                return
            }
            if let http = resp as? HTTPURLResponse {
            }
            if let data = data, let s = String(data: data, encoding: .utf8) {
            }
        }.resume()
    }

    // MARK: - UI Config

    private func configureStripe() {
        STPAPIClient.shared.publishableKey =
        "pk_live_51H5URzFZIwZSNufssK4R7BjLhpqxHVcfmEZVH8Tg74MAHMA20RfkYhIfbwFjDWJ55KzHWkOhEcqVWhIO2VShjOcU00Tslmi1XT"
    }

    private func configureSegmented() {
        let seg = UISegmentedControl.appearance()
        seg.setTitleTextAttributes([.foregroundColor: UIColor.label], for: .normal)
        seg.setTitleTextAttributes([.foregroundColor: UIColor.label], for: .selected)
        seg.selectedSegmentTintColor = UIColor.tertiarySystemFill
    }

    private func configureNavBarAppearance() {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.backgroundColor = .clear
        appearance.shadowColor = .clear

        appearance.backButtonAppearance.normal.titleTextAttributes = [.foregroundColor: UIColor.clear]
        appearance.backButtonAppearance.highlighted.titleTextAttributes = [.foregroundColor: UIColor.clear]

        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance

        UIBarButtonItem.appearance().setBackButtonTitlePositionAdjustment(
            UIOffset(horizontal: -1000, vertical: 0),
            for: .default
        )
    }

    // MARK: - Network Utils

    private func detectLANIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let iface = ptr.pointee

            guard iface.ifa_addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }

            let name = String(cString: iface.ifa_name)
            guard name == "en0" || name == "bridge100" else { continue }

            var addr = iface.ifa_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                $0.pointee.sin_addr
            }

            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN))
            return String(cString: buffer)
        }

        return nil
    }
}

// MARK: - QR Gate (no extra libs; scanning via iOS Camera opens the universal link)

private struct MiniQRScanGateView: View {
    let onPasteLink: (String) -> Void
    @State private var pasted: String = ""

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 14) {
                Text("Scan Minis QR")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(.white)

                Text("No miniAppId is set on this device.\nScan a QR like: minis.studio/12\n(Using the iOS Camera is enough.)")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white.opacity(0.75))
                    .multilineTextAlignment(.center)

                VStack(spacing: 10) {
                    TextField("Paste link (debug)", text: $pasted)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .keyboardType(.URL)
                        .padding(12)
                        .background(Color.white.opacity(0.10))
                        .cornerRadius(12)
                        .foregroundColor(.white)

                    Button {
                        let s = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !s.isEmpty else { return }
                        onPasteLink(s)
                    } label: {
                        Text("Apply Link")
                            .font(.system(size: 16, weight: .bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.white.opacity(0.16))
                            .cornerRadius(14)
                            .foregroundColor(.white)
                    }
                }
                .padding(.top, 6)
                .padding(.horizontal, 22)
            }
            .padding(.horizontal, 22)
        }
    }
}

// MARK: - PrincipalId (Keychain)

enum PrincipalIdStore {
    private static let account = "minis.principalId.v1"

    static func getOrCreate() -> String {
        if let existing = load(), !existing.isEmpty { return existing }
        let created = "device:" + UUID().uuidString.uppercased()
        save(created)
        return created
    }

    private static func load() -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let s = String(data: data, encoding: .utf8)
        else { return nil }
        return s
    }

    private static func save(_ value: String) {
        let data = Data(value.utf8)

        let del: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(del as CFDictionary)

        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ]
        SecItemAdd(add as CFDictionary, nil)

        UserDefaults.standard.set(value, forKey: "admin.principalId")
    }
}

private var isIPad: Bool {
    UIDevice.current.userInterfaceIdiom == .pad
}
