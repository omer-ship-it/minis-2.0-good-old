import SwiftUI
import UIKit
import UserNotifications
import StripeApplePay

// MARK: - Reset mini shop defaults



@main
struct MINIS_02App: App {
    
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("admin") private var isAdmin: Bool = false
    // MARK: - App State
    @AppStorage(AppSettings.Key.cashPointMode) private var cashPointMode: Bool = false
    @AppStorage("shopId") private var shopId: String = "12"
    @AppStorage("miniAppId") private var miniAppId: Int = 0
    @AppStorage("launchMenuOnce") private var launchMenuOnce: Bool = false
    @AppStorage("autoPrintEnabled") private var autoPrintEnabled: Bool = true
    @AppStorage("direction") private var direction: String = "ltr"
    @AppStorage("deliveryLoc") private var deliveryLoc: String = ""

    @State private var studentClaim: StudentClaim? = nil

    // MARK: - App Group + Keys
    private let appGroupId = "group.minis"
    private let kPendingUniversalLink = "pendingUniversalLink"
    private let kPendingStudentClaim  = "pendingStudentClaim.v1"
    
    func detectLANIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else {
            return nil
        }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let iface = ptr.pointee

            // We care only about IPv4
            guard iface.ifa_addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }

            let name = String(cString: iface.ifa_name)

            // Wi-Fi / Ethernet / bridge (iOS simulator)
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

    init() {
        UserDefaults.standard.removeObject(forKey: "printers.config.shop13")
        if let ip = detectLANIPv4() {
            print("🌐 LAN IP detected:", ip)
        } else {
            print("🌐 LAN IP detected: none")
        }
       
        UserDefaults.standard.set(13, forKey: "miniAppId")
        UserDefaults.standard.set("13", forKey: "shopId")
        
        STPAPIClient.shared.publishableKey =
        "pk_live_51H5URzFZIwZSNufssK4R7BjLhpqxHVcfmEZVH8Tg74MAHMA20RfkYhIfbwFjDWJ55KzHWkOhEcqVWhIO2VShjOcU00Tslmi1XT"

        let seg = UISegmentedControl.appearance()
        seg.setTitleTextAttributes([.foregroundColor: UIColor.label], for: .normal)
        seg.setTitleTextAttributes([.foregroundColor: UIColor.label], for: .selected)
        seg.selectedSegmentTintColor = UIColor.tertiarySystemFill

        UserDefaults.standard.removeObject(forKey: "posSavedName")
        UserDefaults.standard.removeObject(forKey: "posSavedPhone")

        // ✅ Only set defaults if nothing is saved yet
        let savedMini = UserDefaults.standard.integer(forKey: "miniAppId")
        if savedMini <= 0 {
            miniAppId = 12
            shopId = "12"
            UserDefaults.standard.set(miniAppId, forKey: "miniAppId")
            UserDefaults.standard.set(shopId, forKey: "shopId")
        } else {
            // keep saved
            miniAppId = savedMini
            shopId = UserDefaults.standard.string(forKey: "shopId") ?? String(savedMini)
        }
    }
    
    var body: some Scene {
        WindowGroup {
            Group {
                if isAdmin {
                           DashboardView()
                               .tint(.primary)
                               .environment(\.layoutDirection, .rightToLeft)
                               .environment(\.locale, Locale(identifier: "he_IL"))
                       } else if cashPointMode {
                           CashPointView()
                               .tint(.primary)
                               .environment(\.layoutDirection, .rightToLeft)
                               .environment(\.locale, Locale(identifier: "he_IL"))
                               .preferredColorScheme(.dark)
                       } else {
                           HomeView()
                               .tint(.primary)
                               .environment(\.layoutDirection, .leftToRight)
                               .preferredColorScheme(.dark)
                       }
            }
            .environment(\.isRtl, direction == "rtl")
            .environment(\.layoutDirection, direction == "rtl" ? .rightToLeft : .leftToRight)
            .environment(\.currency, direction == "rtl" ? "₪" : "£")
            .accentColor(.primary)

            // MARK: - Universal Links / Deep Links
            .onOpenURL { url in
                handleIncoming(url: url)
            }
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                if let url = activity.webpageURL {
                    print("🌐 onContinueUserActivity → \(url.absoluteString)")
                    handleIncoming(url: url)
                } else {
                    print("🌐 onContinueUserActivity → nil url")
                }
            }

            // MARK: - Cold launch handling
            .onAppear {
                // 1) If app group has a pending claim (App Clip → Full App), show it
                loadPendingClaimFromAppGroupIfAny()

                // 2) If we stored a pending link (cold launch), process it
                if let s = MinisShared.sharedDefaults.string(forKey: kPendingUniversalLink),
                   let url = URL(string: s) {
                    print("🥶 cold-launch pendingUniversalLink → \(url.absoluteString)")
                    handleIncoming(url: url)

                    MinisShared.sharedDefaults.removeObject(forKey: kPendingUniversalLink)
                    MinisShared.sharedDefaults.synchronize()
                }
            }

            // MARK: - Student (full screen like clip)
          
            // MARK: - Scene phase (auto print + installs ping)
            .onChange(of: scenePhase) { phase in
                switch phase {
                case .active:
                    pingInstallIfNeeded()

                    if isIPad && autoPrintEnabled {
                        print("🖨️ Auto print activated")
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
        print("🔗 handleIncoming → \(url.absoluteString)")
        guard url.host?.lowercased() == "minis.studio" else { return }

        // ✅ Save for attribution + cold-launch fallback
        MinisShared.sharedDefaults.set(url.absoluteString, forKey: kPendingUniversalLink)
        MinisShared.sharedDefaults.synchronize()

        // ✅ 1) STUDENT CLAIM FIRST (menuView will present it)
        if let claim = StudentClaim.from(url: url) {
            print("🎓 Student claim detected → \(claim)")
            saveClaimToAppGroup(claim)

            // ✅ tell menuView (if already running) to load + present
            NotificationCenter.default.post(name: .studentClaimArrived, object: nil)

            return
        }

        // ✅ 2) Normal deep links (shop/fastlane etc.)
        deliveryLoc = ""
        UserDefaults.standard.removeObject(forKey: "deliveryLoc")

        let components = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        guard let last = components.last, let id = Int(last) else {
            print("⚠️ Deep link ignored: no numeric id in path: \(url.path)")
            return
        }

        let miniType = components.dropLast().last ?? "unknown"
        print("🎯 Deep link → type=\(miniType), miniAppId=\(id)")

        miniAppId = id
        UserDefaults.standard.set(id, forKey: "miniAppId")

        let shopIdString = String(id)
        shopId = shopIdString
        UserDefaults.standard.set(shopIdString, forKey: "shopId")

        // optional query ?loc=
        if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let loc = comps.queryItems?.first(where: { $0.name == "loc" })?.value,
           !loc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {

            let clean = loc.trimmingCharacters(in: .whitespacesAndNewlines)
            deliveryLoc = clean
            UserDefaults.standard.set(clean, forKey: "deliveryLoc")
            print("📍 Stored deliveryLoc =", clean)
        }

        // reset shop defaults / force menu mode
        resetShopUserDefaultsToDefaults()
        launchMenuOnce = true
        cashPointMode = false

        // ping with attribution
        pingInstallIfNeeded(force: true)

        print("✅ Deep link handled → miniAppId=\(miniAppId), shopId=\(shopId), deliveryLoc=\(deliveryLoc)")
    }

    // MARK: - Student Claim in App Group

    private func saveClaimToAppGroup(_ claim: StudentClaim) {
        guard let suite = UserDefaults(suiteName: appGroupId) else {
            print("❌ App Group suite is NIL — check App Groups capability / id")
            return
        }
        guard let data = try? JSONEncoder().encode(claim) else {
            print("❌ FAILED to encode StudentClaim")
            return
        }
        suite.set(data, forKey: kPendingStudentClaim)
        suite.synchronize()
        print("✅ Saved \(kPendingStudentClaim) to App Group. bytes=\(data.count)")
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

        print("✅ Loaded pending student claim from App Group → showing")
    }

    // MARK: - Install Ping

    private struct InstallPingPayload: Codable {
        let anonId: String
        let platform: String      // "ios"
        let appVariant: String    // "app"
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
            miniAppId: miniAppId > 0 ? miniAppId : nil,
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
                print("📈 installs/ping error:", err.localizedDescription)
                return
            }
            if let http = resp as? HTTPURLResponse {
                print("📈 installs/ping status:", http.statusCode)
            }
            if let data = data, let s = String(data: data, encoding: .utf8) {
                print("📈 installs/ping resp:", s)
            }
        }.resume()
    }
}

private var isIPad: Bool {
    UIDevice.current.userInterfaceIdiom == .pad
}
