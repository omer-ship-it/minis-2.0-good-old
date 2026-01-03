import SwiftUI
import StripeCore
import UIKit
import NetworkExtension

@main
struct MiniApp: App {

    @AppStorage("direction") private var direction: String = "ltr"
    @State private var studentClaim: StudentClaim? = nil

    private let wifiSSID = "Beit Ha Am"
    private let wifiPass = "10203040"
    private let kDidTryJoinWiFi = "didTryJoinWiFi.v1"

    private let appGroupId = "group.minis"
    private let kPendingUniversalLink = "pendingUniversalLink"
    private let kPendingStudentClaim  = "pendingStudentClaim.v1"

    init() {
        STPAPIClient.shared.publishableKey =
        "pk_live_51H5URzFZIwZSNufssK4R7BjLhpqxHVcfmEZVH8Tg74MAHMA20RfkYhIfbwFjDWJ55KzHWkOhEcqVWhIO2VShjOcU00Tslmi1XT"

        let std = UserDefaults.standard
        let miniId = std.integer(forKey: "miniAppId")
        let shopId = (std.string(forKey: "shopId") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        if miniId == 0 && shopId.isEmpty {
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
                joinBeitHaAmWiFiIfNeeded()
                parseMiniIfNeeded()
                loadPendingClaimFromAppGroupIfAny()

                if let s = suite()?.string(forKey: kPendingUniversalLink),
                   let url = URL(string: s) {
                    processIncoming(url)
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    pingInstall()
                }
            }
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                if let url = activity.webpageURL {
                    processIncoming(url)
                }
            }
            .onOpenURL { url in
                processIncoming(url)
            }
            .fullScreenCover(item: $studentClaim) { claim in
                StudentDiscountView(
                    miniAppId: claim.miniAppId,
                    campaignId: claim.campaignId,
                    discountPercent: claim.discountPercent,
                    durationMonths: claim.durationMonths
                )
                .interactiveDismissDisabled(true)
                .onDisappear { studentClaim = nil }
            }
        }
    }

    private func suite() -> UserDefaults? {
        UserDefaults(suiteName: appGroupId)
    }

    private func processIncoming(_ url: URL) {
        suite()?.set(url.absoluteString, forKey: kPendingUniversalLink)
        suite()?.synchronize()

        guard let claim = StudentClaim.from(url: url) else { return }

        saveClaimToAppGroup(claim)
        studentClaim = claim

        suite()?.removeObject(forKey: kPendingUniversalLink)
        suite()?.synchronize()

        pingInstall()
    }

    private func saveClaimToAppGroup(_ claim: StudentClaim) {
        guard let s = suite(), let data = try? JSONEncoder().encode(claim) else { return }
        s.set(data, forKey: kPendingStudentClaim)
        s.synchronize()
    }

    private func loadPendingClaimFromAppGroupIfAny() {
        guard let s = suite(), let data = s.data(forKey: kPendingStudentClaim) else { return }
        guard let claim = try? JSONDecoder().decode(StudentClaim.self, from: data) else {
            s.removeObject(forKey: kPendingStudentClaim)
            s.synchronize()
            return
        }
        studentClaim = claim
        s.removeObject(forKey: kPendingStudentClaim)
        s.synchronize()
    }

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
        let platform: String
        let appVariant: String
        let miniAppId: Int?
        let source: String?
        let campaign: String?
        let referrer: String?
    }

    private func getOrCreateAnonId() -> String {
        if let s = suite() {
            if let existing = s.string(forKey: "anonUUID"), !existing.isEmpty {
                UserDefaults.standard.set(existing, forKey: "anonUUID")
                return existing
            }
            let id = UUID().uuidString
            s.set(id, forKey: "anonUUID")
            s.synchronize()
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
        guard let s = suite()?.string(forKey: kPendingUniversalLink),
              let url = URL(string: s)
        else { return (nil, nil, nil) }

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
        req.httpBody = try? JSONEncoder().encode(payload)

        URLSession.shared.dataTask(with: req) { _, _, _ in }.resume()
    }

    private func joinBeitHaAmWiFiIfNeeded() {
        let std = UserDefaults.standard
        if std.bool(forKey: kDidTryJoinWiFi) { return }
        std.set(true, forKey: kDidTryJoinWiFi)

        let config = NEHotspotConfiguration(ssid: wifiSSID, passphrase: wifiPass, isWEP: false)
        config.joinOnce = true

        NEHotspotConfigurationManager.shared.apply(config) { _ in }
    }
}
