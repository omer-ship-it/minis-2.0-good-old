import SwiftUI
import UserNotifications
import UIKit
import StripeApplePay

// MARK: - Reset mini shop defaults


@main
struct MINIS_02App: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("cashPointMode") private var cashPointMode: Bool = true
    @AppStorage("shopId") private var shopId: String = "12"
    @AppStorage("miniAppId") private var miniAppId: Int = 0
    @AppStorage("launchMenuOnce") private var launchMenuOnce: Bool = false
    @AppStorage("autoPrintEnabled") private var autoPrintEnabled: Bool = true
    @AppStorage("direction") private var direction: String = "ltr"
    @AppStorage("deliveryLoc") private var deliveryLoc: String = ""

    @State private var studentClaim: StudentClaim? = nil
    
    init() {
        UserDefaults.standard.set("12", forKey: "miniAppId")
        STPAPIClient.shared.publishableKey = "pk_live_51H5URzFZIwZSNufssK4R7BjLhpqxHVcfmEZVH8Tg74MAHMA20RfkYhIfbwFjDWJ55KzHWkOhEcqVWhIO2VShjOcU00Tslmi1XT"
      //  PrinterManager.shared.setPrinterSet(.ron)
        let demoData = PrinterManager.SalesReportData(
            ppaRestaurant: 52,
            dinersRestaurant: 269,
            totalRestaurantIncVat: 14025,
            ppaRestaurantValue: 0,

            ppaTA: 38,
            dinersTA: 139,
            totalTAIncVat: 5362,

            // 🔄 REVERSED VALUES
            totalSalesIncVat: 19487,   // was 692.2
            tipsTotal: 24,
            grandTotal: 19511,         // was 699.9

            cashAmount: 1912,
            cashCount: 356,
            cardAmount: 17595,
            cardCount: 314,
            collectionsTotalAmount: 361,
            collectionsTotalCount: 19487,

            closedDrawersAmount: 0,
            openDrawersAmount: 0,
            depositWithdrawAmount: 0,
            drawerTotalAmount: 0,
            mainDrawerAmount: 1916,
            hostStationDrawerAmount: 0,

            tipBaseTotal: 24,
            tipRestaurant: 0,
            tipBarTakeaway: 0,
            extraTipTotal: 0,
            extraTipRestaurant: 0,
            extraTipBar: 0,

            ordersOTHAmount: 0, ordersOTHCount: 0,
            itemsOTHAmount: 0, itemsOTHCount: 0,
            canceledItemsAmount: 0, canceledItemsCount: 0,
            refundedItemsAmount: 0, refundedItemsCount: 0,
            discountsAmount: 0, discountsCount: 0,
            discountsRefundAmount: 0, discountsRefundCount: 0
        )
     //   PrinterManager.shared.printHebrewCodepageProbe(to: "10.100.10.232")
         //  PrinterManager.shared.printSalesDebugReport(demoData)
        UIView.appearance().tintColor = nil

        // 🔥 Global RTL for UIKit (menus, alerts, etc.)
        //UIView.appearance().semanticContentAttribute = .forceRightToLeft

        UISegmentedControl.appearance().setTitleTextAttributes(
            [.foregroundColor: UIColor.black],
            for: .selected
        )

     
        

        // Clear saved POS name/phone on fresh launch
        UserDefaults.standard.removeObject(forKey: "posSavedName")
        UserDefaults.standard.removeObject(forKey: "posSavedPhone")
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if cashPointMode {
                    CashPointView()
                        .tint(.primary)
                        .environment(\.layoutDirection, .rightToLeft)
                        .environment(\.locale, Locale(identifier: "he_IL"))
                } else {
                    HomeView()
                        .environment(\.layoutDirection, .leftToRight)
                }
            }
            .environment(\.isRtl, direction == "rtl")
            .environment(\.layoutDirection, direction == "rtl" ? .rightToLeft : .leftToRight)
            .environment(\.currency, direction == "rtl" ? "₪" : "£")
            .accentColor(.primary)
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
            .onAppear {
                if let s = MinisShared.sharedDefaults.string(forKey: "pendingUniversalLink"),
                   let url = URL(string: s) {
                    print("🥶 cold-launch pendingUniversalLink → \(url.absoluteString)")
                    handleIncoming(url: url)
                    MinisShared.sharedDefaults.removeObject(forKey: "pendingUniversalLink")
                    MinisShared.sharedDefaults.synchronize()
                }
            }
            .sheet(item: $studentClaim) { claim in
                StudentDiscountView(
                    miniAppId: claim.miniAppId,
                    campaignId: claim.campaignId,
                    discountPercent: claim.discountPercent,
                    durationMonths: claim.durationMonths
                )
            }
            .onChange(of: scenePhase) { phase in
                switch phase {
                case .active:
                    pingInstallIfNeeded()
                    if cashPointMode && autoPrintEnabled {
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

    private func handleIncoming(url: URL) {
        print("🔗 onOpenURL → \(url.absoluteString)")
        guard url.host == "minis.studio" else { return }

        // ✅ 1) STUDENT CLAIM FIRST (so it launches from HomeView / anywhere)
        if let claim = StudentClaim.from(url: url) {
            print("🎓 Student claim detected → \(claim)")
            studentClaim = claim
            if let suite = UserDefaults(suiteName: "group.minis") {
                let enc = JSONEncoder()
                if let data = try? enc.encode(claim) {
                    suite.set(data, forKey: "pendingStudentClaim.v1")
                    suite.synchronize()
                    print("✅ SAVED pendingStudentClaim.v1 to App Group. bytes=\(data.count)")
                } else {
                    print("❌ FAILED to encode StudentClaim")
                }

                // quick verify read-back
                if let check = suite.data(forKey: "pendingStudentClaim.v1") {
                    print("🔎 READBACK pendingStudentClaim.v1 bytes=\(check.count)")
                } else {
                    print("❌ READBACK failed — key not present after save")
                }
            } else {
                print("❌ App Group suite is NIL — App Groups capability not set / wrong group id")
            }
            return
        }

        
        // ✅ 2) Normal deep links (shop/fastlane etc.)
        deliveryLoc = ""
        UserDefaults.standard.removeObject(forKey: "deliveryLoc")

        let components = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        guard let last = components.last, let id = Int(last) else { return }

        let miniType = components.dropLast().last ?? "unknown"
        print("🎯 Deep link → type=\(miniType), miniAppId=\(id)")

        miniAppId = id
        UserDefaults.standard.set(id, forKey: "miniAppId")

        let shopIdString = String(id)
        shopId = shopIdString
        UserDefaults.standard.set(shopIdString, forKey: "shopId")
        pingInstallIfNeeded(force: true)

        if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let loc = comps.queryItems?.first(where: { $0.name == "loc" })?.value,
           !loc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let clean = loc.trimmingCharacters(in: .whitespacesAndNewlines)
            deliveryLoc = clean
            UserDefaults.standard.set(clean, forKey: "deliveryLoc")
            print("📍 Stored deliveryLoc =", clean)
        }

        resetShopUserDefaultsToDefaults()
        launchMenuOnce = true
        cashPointMode = false

        print("✅ Deep link handled → miniAppId=\(miniAppId), shopId=\(shopId), deliveryLoc=\(deliveryLoc)")
    }
    private let appGroupId = "group.minis"

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
        // You already store this in the app group on cold launch
        if let s = MinisShared.sharedDefaults.string(forKey: "pendingUniversalLink"),
           let url = URL(string: s) {

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

        return (nil, nil, nil)
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
        // ✅ avoid spamming (once per day per device)
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


