import SwiftUI
import StripeCore
import UIKit
import NetworkExtension

@main
struct MiniApp: App {

    @AppStorage("direction") private var direction: String = "ltr"
    @State private var studentClaim: StudentClaim? = nil

    // ✅ Gate UI until JSON customization applied
    @State private var didLoadMini = false

    private let wifiSSID = "Beit Ha Am"
    private let wifiPass = "10203040"
    private let kDidTryJoinWiFi = "didTryJoinWiFi.v1"

    private let appGroupId = "group.minis"
    private let kPendingUniversalLink = "pendingUniversalLink"
    private let kPendingStudentClaim  = "pendingStudentClaim.v1"

    // ✅ NEW: stamps claim handoff
    private let kPendingStampsClaim   = "pendingStampsClaim.v1"

    // ✅ canonical keys
    private let kMiniAppId = "miniAppId"
    private let kShopId    = "shopId"
    private let kDirection = "direction"
    private let kDeliveryLoc = "delivery.loc"   // ✅ use one stable key everywhere

    // ✅ launch attribution flag (consumed on launch)
    private let kOpenedViaLink = "openedViaLink.v1"

    init() {
        STPAPIClient.shared.publishableKey =
        "pk_live_51H5URzFZIwZSNufssK4R7BjLhpqxHVcfmEZVH8Tg74MAHMA20RfkYhIfbwFjDWJ55KzHWkOhEcqVWhIO2VShjOcU00Tslmi1XT"

        let std = UserDefaults.standard
        let miniId = std.integer(forKey: kMiniAppId)
        let shopId = (std.string(forKey: kShopId) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        _ = miniId
        _ = shopId
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if !didLoadMini {
                    LoadingSplashView()
                } else {
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
            }
            .onAppear {
                joinBeitHaAmWiFiIfNeeded()

                // ✅ If NOT opened via link → force miniAppId = 12
                applyMiniFallbackIfNotOpenedViaLink()

                loadPendingClaimFromAppGroupIfAny()

                // ✅ Load customization for current mini and ONLY then show HomeView
                didLoadMini = false
                parseMiniIfNeeded { _ in
                    DispatchQueue.main.async {
                        self.didLoadMini = true
                    }
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

    // MARK: - ✅ Fallback: if not opened via link, force miniAppId = 12

    private func applyMiniFallbackIfNotOpenedViaLink() {
        let std = UserDefaults.standard
        let grp = suite()

        let openedViaLink = std.bool(forKey: kOpenedViaLink) || (grp?.bool(forKey: kOpenedViaLink) ?? false)

        if !openedViaLink {
            std.set(12, forKey: kMiniAppId)
            std.set("12", forKey: kShopId)

            // ✅ (your original code had grp set to 3; keep shopId consistent)
            grp?.set(12, forKey: kMiniAppId)
            grp?.set("12", forKey: kShopId)
            grp?.synchronize()
        }

        // ✅ consume immediately so next cold launch without a link falls back again
        std.set(false, forKey: kOpenedViaLink)
        grp?.set(false, forKey: kOpenedViaLink)
        grp?.synchronize()
    }

    // MARK: - URL parsing helpers

    private func queryValue(_ name: String, in url: URL) -> String? {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return items.first(where: { $0.name.lowercased() == name.lowercased() })?.value
    }

    private func isStudentLink(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        if path == "/student" || path == "/student/" { return true }

        if let v = queryValue("student", in: url)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() {
            if v == "1" || v == "true" || v == "yes" { return true }
        }

        return false
    }

    private func makeStudentClaimForCurrentMini() -> StudentClaim? {
        let mini = UserDefaults.standard.integer(forKey: kMiniAppId)
        guard mini > 0 else { return nil }
        return StudentClaim(
            miniAppId: mini,
            campaignId: "student",
            discountPercent: 10,
            durationMonths: 6
        )
    }

    // MARK: - ✅ STAMPS CLAIM (App Group + Notification)

    private struct StampsClaim: Identifiable, Codable, Equatable {
        var id: String { "\(miniAppId)-\(stamps)" }
        let miniAppId: Int
        let stamps: Int
    }

    private func isStampsLink(_ url: URL) -> (miniId: Int, stamps: Int)? {
        let host = (url.host ?? "").lowercased()
        guard host == "minis.studio" || host.hasSuffix(".minis.studio") else { return nil }

        // ✅ Trigger if:
        // - path contains /stamps
        // OR
        // - query contains stamps= (your current /shop/12?stamps=2 use-case)
        let path = url.path.lowercased()
        let stampsQ = (queryValue("stamps", in: url) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        let hasPathTrigger = path.contains("/stamps")
        let hasQueryTrigger = !stampsQ.isEmpty

        guard hasPathTrigger || hasQueryTrigger else { return nil }

        // stamps
        let s = Int(stampsQ) ?? 0
        let stamps = max(1, min(10, s == 0 ? 1 : s))

        // miniId preference:
        // 1) explicit miniAppId query
        // 2) /shop/{id} in path
        // 3) current stored miniAppId
        let explicitMini = Int((queryValue("miniAppId", in: url) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0

        var miniIdFromPath: Int = 0
        let comps = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        if comps.count >= 2, comps[0].lowercased() == "shop", let id = Int(comps[1]) {
            miniIdFromPath = id
        }

        let fallbackMini = UserDefaults.standard.integer(forKey: kMiniAppId)
        let miniId = (explicitMini > 0 ? explicitMini : (miniIdFromPath > 0 ? miniIdFromPath : fallbackMini))

        guard miniId > 0 else { return nil }
        return (miniId, stamps)
    }

    private func saveStampsClaimToAppGroup(_ claim: StampsClaim) {
        guard let s = suite(), let data = try? JSONEncoder().encode(claim) else { return }
        s.set(data, forKey: kPendingStampsClaim)
        s.synchronize()
    }

    // MARK: - Incoming URL Router

    private func processIncoming(_ url: URL) {
        // ✅ mark that we were opened via a link (so we DON'T force mini=12 on next launch)
        let std = UserDefaults.standard
        let grp = suite()
        std.set(true, forKey: kOpenedViaLink)
        grp?.set(true, forKey: kOpenedViaLink)
        grp?.synchronize()

        // MARK: - Persist incoming link (for attribution)
        suite()?.set(url.absoluteString, forKey: kPendingUniversalLink)
        suite()?.synchronize()

        // ✅ Only handle minis.studio links
        let host = (url.host ?? "").lowercased()
        guard host == "minis.studio" || host.hasSuffix(".minis.studio") else { return }

        // ✅ 0) STAMPS CLAIM FIRST (so it can be /shop/12?stamps=2)
        if let hit = isStampsLink(url) {
            let claim = StampsClaim(miniAppId: hit.miniId, stamps: hit.stamps)

            // ensure mini/shop stored (so menu loads correct shop)
            std.set(hit.miniId, forKey: kMiniAppId)
            std.set(String(hit.miniId), forKey: kShopId)
            grp?.set(hit.miniId, forKey: kMiniAppId)
            grp?.set(String(hit.miniId), forKey: kShopId)
            grp?.synchronize()

            // save claim + notify UI
            saveStampsClaimToAppGroup(claim)

            NotificationCenter.default.post(name: .stampsArrived, object: nil)

            // clean pending link (optional)
            suite()?.removeObject(forKey: kPendingUniversalLink)
            suite()?.synchronize()

            pingInstall()
            return
        }

        // MARK: - 1) Shop deep link: /shop/{id}
        let comps = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        var incomingMiniId: Int? = nil

        if comps.count >= 2, comps[0].lowercased() == "shop", let id = Int(comps[1]) {
            incomingMiniId = id

            // ✅ Write BOTH: standard + app group (prevents "loc missing" bug)
            std.set(id, forKey: kMiniAppId)
            std.set(String(id), forKey: kShopId)

            grp?.set(id, forKey: kMiniAppId)
            grp?.set(String(id), forKey: kShopId)
            grp?.synchronize()

            // ✅ loc from URL (or fallback for mini 3)
            let loc = (queryValue("loc", in: url) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if !loc.isEmpty {
                std.set(loc, forKey: kDeliveryLoc)
                grp?.set(loc, forKey: kDeliveryLoc)
                grp?.synchronize()
                print("📍 \(kDeliveryLoc) from URL =", loc)
            } else {
                if id == 3 {
                    std.set("mikkeller", forKey: kDeliveryLoc)
                    grp?.set("mikkeller", forKey: kDeliveryLoc)
                    grp?.synchronize()
                    print("📍 \(kDeliveryLoc) fallback = mikkeller (miniAppId=3)")
                } else {
                    std.removeObject(forKey: kDeliveryLoc)
                    grp?.removeObject(forKey: kDeliveryLoc)
                    grp?.synchronize()
                }
            }

            // ✅ Hold UI while refreshing customization for the new mini
            DispatchQueue.main.async { self.didLoadMini = false }
            parseMiniIfNeeded { _ in
                DispatchQueue.main.async { self.didLoadMini = true }
            }

            pingInstall()
        }

        // MARK: - 2) Student triggers
        if let claim = StudentClaim.from(url: url) {
            saveClaimToAppGroup(claim)
            studentClaim = claim

            suite()?.removeObject(forKey: kPendingUniversalLink)
            suite()?.synchronize()

            pingInstall()
            return
        }

        if isStudentLink(url) {
            let miniId =
                incomingMiniId
                ?? (grp?.integer(forKey: kMiniAppId) ?? 0)
                ?? std.integer(forKey: kMiniAppId)

            if let claim = StudentClaim(
                miniAppId: miniId,
                campaignId: "student",
                discountPercent: 10,
                durationMonths: 6
            ) as StudentClaim? {
                saveClaimToAppGroup(claim)
                studentClaim = claim

                suite()?.removeObject(forKey: kPendingUniversalLink)
                suite()?.synchronize()

                pingInstall()
                return
            }
        }

        // MARK: - 3) If it wasn't /shop/{id} above, still ping attribution
        if incomingMiniId == nil {
            pingInstall()
        }
    }

    // MARK: - Student Claim in App Group

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

    // MARK: - Mini customization fetch

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
            // ✅ Your existing function (assumed to set direction/theme/etc)
            applyMiniCustomization(from: data)

            completion(true)
        }.resume()
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

    // MARK: - WiFi (unchanged)

    private func joinBeitHaAmWiFiIfNeeded() {
        let std = UserDefaults.standard
        if std.bool(forKey: kDidTryJoinWiFi) { return }
        std.set(true, forKey: kDidTryJoinWiFi)

        let config = NEHotspotConfiguration(ssid: wifiSSID, passphrase: wifiPass, isWEP: false)
        config.joinOnce = true

        NEHotspotConfigurationManager.shared.apply(config) { _ in }
    }
}

// MARK: - Simple loading view while mini JSON loads

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

// MARK: - Notification used by menuView
extension Notification.Name {
    static let stampsArrived = Notification.Name("stampsArrived")
}
