import SwiftUI
import StripeCore
import UIKit
import NetworkExtension

@main
struct MiniApp: App {

    @AppStorage("direction") private var direction: String = "ltr"

    // ✅ Beit Ha’am guest Wi-Fi
    private let wifiSSID = "Beit Ha Am"
    private let wifiPass = "10203040"

    // ✅ Throttle Wi-Fi prompt (avoid re-prompting every launch)
    private let kDidTryJoinWiFi = "didTryJoinWiFi.v1"

    // ✅ Present ONLY when we actually have a claim
    @State private var studentClaim: StudentClaim? = nil

    // ✅ MUST be the SAME in App Clip + Full App capabilities
    private let appGroupId = "group.minis"

    // ✅ Shared keys
    private let kPendingUniversalLink = "pendingUniversalLink"
    private let kPendingStudentClaim  = "pendingStudentClaim.v1"

    init() {
        STPAPIClient.shared.publishableKey =
        "pk_live_51H5URzFZIwZSNufssK4R7BjLhpqxHVcfmEZVH8Tg74MAHMA20RfkYhIfbwFjDWJ55KzHWkOhEcqVWhIO2VShjOcU00Tslmi1XT"

        let std = UserDefaults.standard
        let miniId = std.integer(forKey: "miniAppId")
        let shopId = std.string(forKey: "shopId")

        if miniId == 0 && (shopId == nil || shopId!.isEmpty) {
            std.set(12, forKey: "miniAppId")
            std.set("12", forKey: "shopId")
            std.set("rtl", forKey: "direction")
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if direction == "rtl" {
                    ForceRTL {
                        NavigationStack {
                            menuView()
                                .environment(\.isRtl, true)
                                .environment(\.layoutDirection, .rightToLeft)
                        }
                    }
                } else {
                    NavigationStack {
                        menuView()
                            .environment(\.isRtl, false)
                            .environment(\.layoutDirection, .leftToRight)
                    }
                }
            }
            .onAppear {
                // ✅ Wi-Fi join (App Clip will show the system “Join Wi-Fi” prompt once)
                joinBeitHaAmWiFiIfNeeded()

                parseMiniIfNeeded()

                // ✅ 1) Full App / App Clip can both pick up a pending claim saved in App Group
                loadPendingClaimFromAppGroupIfAny()

                // ✅ 2) Cold-launch fallback: if you previously saved a link
                if let s = UserDefaults.standard.string(forKey: kPendingUniversalLink),
                   let url = URL(string: s) {
                    processIncoming(url)
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    pingInstall()
                }
            }

            // ✅ While already running (most important)
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                if let url = activity.webpageURL {
                    processIncoming(url)
                }
            }

            // ✅ Backup
            .onOpenURL { url in
                processIncoming(url)
            }

            // ✅ Present ONLY if claim exists -> never blank
            .fullScreenCover(item: $studentClaim) { claim in
                StudentDiscountView(
                    miniAppId: claim.miniAppId,
                    campaignId: claim.campaignId,
                    discountPercent: claim.discountPercent,
                    durationMonths: claim.durationMonths
                )
                .interactiveDismissDisabled(true)
                .onDisappear {
                    // ✅ one-time show per received claim
                    studentClaim = nil
                }
            }
        }
    }

    // MARK: - Universal Link handling
    private func processIncoming(_ url: URL) {
        UserDefaults.standard.set(url.absoluteString, forKey: kPendingUniversalLink)

        guard let claim = StudentClaim.from(url: url) else { return }

        saveClaimToAppGroup(claim)
        studentClaim = claim

        UserDefaults.standard.removeObject(forKey: kPendingUniversalLink)
        UserDefaults.standard.synchronize()

        // ✅ ping again now that we definitely have a referrer/source context
        pingInstall()
    }

    // MARK: - App Group claim handoff

    private func saveClaimToAppGroup(_ claim: StudentClaim) {
        guard let suite = UserDefaults(suiteName: appGroupId) else { return }
        guard let data = try? JSONEncoder().encode(claim) else { return }
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

        // ✅ Present (Full App will show it on first open after install)
        studentClaim = claim

        // ✅ Clear so it is one-time
        suite.removeObject(forKey: kPendingStudentClaim)
        suite.synchronize()
    }

    // MARK: - Mini JSON customization
    private func parseMiniIfNeeded() {
        let std = UserDefaults.standard
        let id = String(std.integer(forKey: "miniAppId"))
        let t = Int(Date().timeIntervalSince1970)

        guard let url = URL(string: "https://minis.studio/json/\(id).json?\(t)") else { return }

        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data else { return }
            applyMiniCustomization(from: data)
        }.resume()
    }

    private struct InstallPingPayload: Codable {
        let anonId: String
        let platform: String      // "appclip"
        let appVariant: String    // "appclip"
        let miniAppId: Int?
        let source: String?
        let campaign: String?
        let referrer: String?
    }

    private func getOrCreateAnonId() -> String {
        // Prefer App Group so App Clip → Full App keeps same id
        if let suite = UserDefaults(suiteName: appGroupId) {
            if let existing = suite.string(forKey: "anonUUID"), !existing.isEmpty {
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

    private func buildInstallAttribution() -> (source: String?, campaign: String?, referrer: String?) {
        if let s = UserDefaults.standard.string(forKey: kPendingUniversalLink),
           let url = URL(string: s) {

            let host = url.host?.lowercased()
            let path = url.path.lowercased()

            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let q = comps?.queryItems ?? []
            let utmSource = q.first(where: { $0.name.lowercased() == "utm_source" })?.value
            let utmCampaign = q.first(where: { $0.name.lowercased() == "utm_campaign" })?.value

            let source =
                utmSource
                ?? (host == "minis.studio" && path.contains("shop") ? "shop_link" : nil)
                ?? "universal_link"

            let campaign = utmCampaign

            let ref = (host ?? "link") + url.path
            return (source, campaign, ref)
        }

        return (nil, nil, nil)
    }

    private func pingInstall() {
        let anonId = getOrCreateAnonId()
        let miniId = UserDefaults.standard.integer(forKey: "miniAppId")
        let attrib = buildInstallAttribution()

        let payload = InstallPingPayload(
            anonId: anonId,
            platform: "appclip",
            appVariant: "appclip",
            miniAppId: miniId > 0 ? miniId : nil,
            source: attrib.source,
            campaign: attrib.campaign,
            referrer: attrib.referrer
        )

        guard let url = URL(string: "https://minis.studio/api/installs/ping") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        guard let data = try? JSONEncoder().encode(payload) else { return }
        req.httpBody = data

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

    // MARK: - Wi-Fi join (Guest Wi-Fi with password)
    private func joinBeitHaAmWiFiIfNeeded() {
        // ✅ Prevent repeated prompts
        let std = UserDefaults.standard
        if std.bool(forKey: kDidTryJoinWiFi) { return }
        std.set(true, forKey: kDidTryJoinWiFi)

        let config = NEHotspotConfiguration(
            ssid: wifiSSID,
            passphrase: wifiPass,
            isWEP: false
        )
        config.joinOnce = true

        NEHotspotConfigurationManager.shared.apply(config) { error in
            if let error = error as NSError? {
                if error.domain == NEHotspotConfigurationErrorDomain,
                   error.code == NEHotspotConfigurationError.alreadyAssociated.rawValue {
                    print("📶 Wi-Fi: already associated")
                    return
                }
                print("📶 Wi-Fi join error:", error.localizedDescription)
            } else {
                print("📶 Wi-Fi: joined \(self.wifiSSID)")
            }
        }
    }
}
