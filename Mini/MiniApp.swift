import SwiftUI
import StripeCore
import UIKit
import NetworkExtension

@main
struct MiniApp: App {

    @AppStorage("direction") private var direction: String = "rtl"
    @State private var studentClaim: StudentClaim? = nil
    @State private var didLoadMini = false

    private let wifiSSID = "Beit Ha Am"
    private let wifiPass = "10203040"
    private let kDidTryJoinWiFi = "didTryJoinWiFi.v1"

    private let appGroupId = "group.minis"
    private let kPendingUniversalLink = "pendingUniversalLink"
    private let kPendingStudentClaim  = "pendingStudentClaim.v1"

    private let kMiniAppId = "miniAppId"
    private let kShopId    = "shopId"
    private let kDirection = "direction"
    private let kDeliveryLoc = "delivery.loc"
    private let kOpenedViaLink = "openedViaLink.v1"

    init() {
        STPAPIClient.shared.publishableKey =
        "pk_live_51H5URzFZIwZSNufssK4R7BjLhpqxHVcfmEZVH8Tg74MAHMA20RfkYhIfbwFjDWJ55KzHWkOhEcqVWhIO2VShjOcU00Tslmi1XT"

        let std = UserDefaults.standard
        _ = std.integer(forKey: kMiniAppId)
        _ = (std.string(forKey: kShopId) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if !didLoadMini {
                    LoadingSplashView()
                } else {
                    NavigationStack {
                        if direction == "rtl" {
                            ForceRTL {
                                menuView()
                                    .environment(\.isRtl, true)
                                    .environment(\.layoutDirection, .rightToLeft)
                            }
                        } else {
                            menuView()
                                .environment(\.isRtl, false)
                                .environment(\.layoutDirection, .leftToRight)
                        }
                    }
                }
            }
            .onAppear {
                joinBeitHaAmWiFiIfNeeded()
                applyMiniFallbackIfNotOpenedViaLink()
                loadPendingClaimFromAppGroupIfAny()

                didLoadMini = false
                enforceDirectionPolicy()

                parseMiniIfNeeded { _ in
                    DispatchQueue.main.async { self.didLoadMini = true }
                }

                if let s = suite()?.string(forKey: kPendingUniversalLink),
                   let url = URL(string: s) {
                    processIncoming(url)
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    pingInstall()
                }
            }
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                if let url = activity.webpageURL { processIncoming(url) }
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

    private func setDirection(_ value: String) {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let final = (v == "rtl") ? "rtl" : "ltr"
        let std = UserDefaults.standard
        let grp = suite()
        std.set(final, forKey: kDirection)
        grp?.set(final, forKey: kDirection)
        grp?.synchronize()
        DispatchQueue.main.async { self.direction = final }
    }

    // ✅ Policy:
    // - If opened via URL AND miniAppId == 3 -> force LTR
    // - Otherwise -> force RTL
    private func enforceDirectionPolicy() {
        let std = UserDefaults.standard
        let grp = suite()

        let openedViaLink = std.bool(forKey: kOpenedViaLink) || (grp?.bool(forKey: kOpenedViaLink) ?? false)

        let grpMini = grp?.integer(forKey: kMiniAppId) ?? 0
        let stdMini = std.integer(forKey: kMiniAppId)
        let miniId = (grpMini > 0) ? grpMini : stdMini

        if openedViaLink && miniId == 3 {
            setDirection("ltr")
        } else {
            setDirection("rtl")
        }
    }

    private func applyMiniFallbackIfNotOpenedViaLink() {
        let std = UserDefaults.standard
        let grp = suite()

        let openedViaLink = std.bool(forKey: kOpenedViaLink) || (grp?.bool(forKey: kOpenedViaLink) ?? false)

        if !openedViaLink {
            std.set(12, forKey: kMiniAppId)
            std.set("12", forKey: kShopId)

            grp?.set(3, forKey: kMiniAppId)
            grp?.set("12", forKey: kShopId)
            grp?.synchronize()
        }

        std.set(false, forKey: kOpenedViaLink)
        grp?.set(false, forKey: kOpenedViaLink)
        grp?.synchronize()
    }

    private func processIncoming(_ url: URL) {
        let std = UserDefaults.standard
        let grp = suite()

        std.set(true, forKey: kOpenedViaLink)
        grp?.set(true, forKey: kOpenedViaLink)
        grp?.synchronize()

        suite()?.set(url.absoluteString, forKey: kPendingUniversalLink)
        suite()?.synchronize()

        let host = (url.host ?? "").lowercased()
        guard host == "minis.studio" || host.hasSuffix(".minis.studio") else { return }

        func queryValue(_ key: String, in url: URL) -> String? {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            return items.first(where: { $0.name.lowercased() == key.lowercased() })?.value
        }

        func isStudentLink(_ url: URL) -> Bool {
            let path = url.path.lowercased()
            if path == "/student" || path == "/student/" { return true }
            let q = (queryValue("student", in: url) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return q == "1" || q == "true" || q == "yes"
        }

        func makeStudentClaimForMini(_ miniId: Int) -> StudentClaim? {
            guard miniId > 0 else { return nil }
            return StudentClaim(
                miniAppId: miniId,
                campaignId: "student",
                discountPercent: 10,
                durationMonths: 6
            )
        }

        func saveStudentClaim(_ claim: StudentClaim) {
            saveClaimToAppGroup(claim)
            studentClaim = claim
            suite()?.removeObject(forKey: kPendingUniversalLink)
            suite()?.synchronize()
            pingInstall()
        }

        let comps = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        var incomingMiniId: Int? = nil

        if comps.count >= 2, comps[0].lowercased() == "shop", let id = Int(comps[1]) {
            incomingMiniId = id

            std.set(id, forKey: kMiniAppId)
            std.set(String(id), forKey: kShopId)

            grp?.set(id, forKey: kMiniAppId)
            grp?.set(String(id), forKey: kShopId)
            grp?.synchronize()

            let loc = (queryValue("loc", in: url) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !loc.isEmpty {
                std.set(loc, forKey: kDeliveryLoc)
                grp?.set(loc, forKey: kDeliveryLoc)
                grp?.synchronize()
            } else {
                if id == 3 {
                    std.set("mikkeller", forKey: kDeliveryLoc)
                    grp?.set("mikkeller", forKey: kDeliveryLoc)
                    grp?.synchronize()
                } else {
                    std.removeObject(forKey: kDeliveryLoc)
                    grp?.removeObject(forKey: kDeliveryLoc)
                    grp?.synchronize()
                }
            }

            didLoadMini = false
            enforceDirectionPolicy()

            parseMiniIfNeeded { _ in
                DispatchQueue.main.async { self.didLoadMini = true }
            }

            pingInstall()
        }

        if let claim = StudentClaim.from(url: url) {
            saveStudentClaim(claim)
            return
        }

        if isStudentLink(url) {
            let miniId =
                incomingMiniId
                ?? (grp?.integer(forKey: kMiniAppId) ?? 0)
                ?? std.integer(forKey: kMiniAppId)

            if let claim = makeStudentClaimForMini(miniId) {
                saveStudentClaim(claim)
                return
            }
        }

        if incomingMiniId == nil {
            pingInstall()
        }
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

    private func parseMiniIfNeeded(completion: @escaping (Bool) -> Void = { _ in }) {
        let std = UserDefaults.standard
        let id = String(std.integer(forKey: kMiniAppId))
        let t = Int(Date().timeIntervalSince1970)

        guard let url = URL(string: "https://minis.studio/json/\(id).json?\(t)") else {
            completion(false)
            return
        }

        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data else {
                completion(false)
                return
            }

            applyMiniCustomization(from: data)

            // ✅ Ignore JSON "direction" completely; enforce our rule.
            self.enforceDirectionPolicy()

            completion(true)
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
        let miniId = UserDefaults.standard.integer(forKey: kMiniAppId)
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

private struct LoadingSplashView: View {
    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading…")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
