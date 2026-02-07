import SwiftUI
import UserNotifications
import UIKit

extension Notification.Name {
    static let orderReady = Notification.Name("OrderReadyNotification")

    // Optional: react immediately in SwiftUI
    static let pendingUniversalLink = Notification.Name("PendingUniversalLink")
    static let studentClaimReceived = Notification.Name("StudentClaimReceived")


 
   
}

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    private let lastReadyOrderKey    = "lastReadyOrderId"
    private let isLastOrderReadyKey  = "isLastOrderReady"
  
    // ✅ New: stash universal links for SwiftUI to drain
    private let pendingUniversalLinkKey = "pendingUniversalLink"

    // ✅ New: student payload stored for Full App (and App Clip if shared)
    private let pendingStudentDiscountKey = "pendingStudentDiscount"

    
  
    // MARK: - App launch
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil
    ) -> Bool {

        print("🚀 AppDelegate didFinishLaunching")

        let center = UNUserNotificationCenter.current()
        center.delegate = self

        // ✅ Ask permission FIRST (fresh install gets prompt here)
       

        // ✅ Keep your launchOptions push handling as-is
        if let remote = launchOptions?[.remoteNotification] as? [AnyHashable: Any] {
            print("🚀 Launched from remote notification:", remote)
            storeOrderIdIfPresent(remote)
            UserDefaults.standard.set(true, forKey: isLastOrderReadyKey)
            NotificationCenter.default.post(name: .orderReady, object: nil, userInfo: remote)
        } else {
            print("ℹ️ No remote notification in launchOptions")
        }

        // ✅ Print token from canonical store (may be empty on first launch)
        let saved = loadApnsToken()
        if saved.isEmpty {
            print("⚠️ No saved APNs token yet")
        } else {
            print("🔎 Saved APNs token (from last launch):", saved)
        }

        // ✅ Universal link cold launch support (unchanged)
        if let s = UserDefaults.standard.string(forKey: pendingUniversalLinkKey),
           let url = URL(string: s) {
            handleUniversalLink(url)
        }

        return true
    }

    // MARK: - Universal Links / Handoff (Advanced Experience, Notes links, etc.)
    func application(
        _ application: UIApplication,
        continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void
    ) -> Bool {

        if userActivity.activityType == NSUserActivityTypeBrowsingWeb,
           let url = userActivity.webpageURL {

            print("🧩 continueUserActivity (Universal Link):", url.absoluteString)

            // Store for SwiftUI to consume (cold launch safe)
            UserDefaults.standard.set(url.absoluteString, forKey: pendingUniversalLinkKey)
            UserDefaults.standard.synchronize()

            // Optional immediate signal (if your SwiftUI listens)
            NotificationCenter.default.post(
                name: .pendingUniversalLink,
                object: nil,
                userInfo: ["url": url.absoluteString]
            )

            // ✅ ALSO: parse student claim immediately
            handleUniversalLink(url)

            return true
        }

        print("ℹ️ continueUserActivity ignored:", userActivity.activityType)
        return false
    }

    // MARK: - Universal link handler
    // MARK: - Universal link handler
    private func handleUniversalLink(_ url: URL) {

        print("🔗 handleUniversalLink CALLED")
        print("🔗 url =", url.absoluteString)

        // Log path + query
        print("🔗 path =", url.path)
        print("🔗 query =", url.query ?? "<nil>")

        if let claim = StudentClaim.from(url: url) {

            print("🎓 STUDENT CLAIM PARSED ✅")
            print("🎓 miniAppId =", claim.miniAppId)
            print("🎓 campaignId =", claim.campaignId)
            print("🎓 discountPercent =", claim.discountPercent)
            print("🎓 durationMonths =", claim.durationMonths)

            persistStudentDiscount(claim)

            print("📣 Posting Notification.studentClaimReceived")

            NotificationCenter.default.post(
                name: .studentClaimReceived,
                object: nil,
                userInfo: [
                    "miniAppId": claim.miniAppId,
                    "campaignId": claim.campaignId,
                    "discountPercent": claim.discountPercent,
                    "durationMonths": claim.durationMonths
                ]
            )

        } else {
            print("❌ NOT a student claim URL")
        }
    }

    // MARK: - Persist student discount payload for Full App
    private func persistStudentDiscount(_ claim: StudentClaim) {
        let expiresAt = Calendar.current.date(
            byAdding: .month,
            value: claim.durationMonths,
            to: Date()
        ) ?? Date().addingTimeInterval(60 * 60 * 24 * 30 * Double(claim.durationMonths))

        let payload: [String: Any] = [
            "miniAppId": claim.miniAppId,
            "campaignId": claim.campaignId,
            "discountPercent": claim.discountPercent,
            "expiresAt": expiresAt.timeIntervalSince1970
        ]

        UserDefaults.standard.set(payload, forKey: pendingStudentDiscountKey)
        UserDefaults.standard.synchronize()

        print("✅ Saved pendingStudentDiscount:", payload)
    }

   
    // MARK: - APNs token registration
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let tokenString = deviceToken.map { String(format: "%02x", $0) }.joined()
        let name = UIDevice.current.name

        registerAdminDevice(
            token: tokenString,
            displayName: name,
            isPrinterManager: false
        )

        print("📬 APNs token (hex): \(tokenString)")

        UserDefaults.standard.set(tokenString, forKey: DeviceKeys.apnsToken)

        if let suite = UserDefaults(suiteName: "group.minis") {
            suite.set(tokenString, forKey: DeviceKeys.apnsToken)
            suite.synchronize()
        }

        UserDefaults.standard.synchronize()
    }
   
    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("❌ Failed to register for push notifications:", error.localizedDescription)
    }

    // MARK: - Foreground push
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo
        print("📬 Foreground push:", userInfo)

        storeOrderIdIfPresent(userInfo)
        UserDefaults.standard.set(true, forKey: isLastOrderReadyKey)

        completionHandler([.banner, .badge, .sound])

        NotificationCenter.default.post(name: .orderReady, object: nil, userInfo: userInfo)
    }

    // MARK: - User tapped notification
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo

        print("📲 User tapped notification:", userInfo)

        storeOrderIdIfPresent(userInfo)
        UserDefaults.standard.set(true, forKey: isLastOrderReadyKey)

        NotificationCenter.default.post(name: .orderReady, object: nil, userInfo: userInfo)

        completionHandler()
    }

    // MARK: - Silent push (background)
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable : Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        print("📡 [fetch] Silent/background push:", userInfo)

        storeOrderIdIfPresent(userInfo)
        UserDefaults.standard.set(true, forKey: isLastOrderReadyKey)
        print("✅ isLastOrderReady = true (from silent/background push)")

        NotificationCenter.default.post(name: .orderReady, object: nil, userInfo: userInfo)

#if !APPCLIP
        Task {
            await OrdersAutoPrinter.shared.handleSilentPush(userInfo: userInfo)
            completionHandler(.newData)
        }
#else
        completionHandler(.noData)
#endif
    }

    // MARK: - Store Order ID Helper
    private func storeOrderIdIfPresent(_ userInfo: [AnyHashable: Any]) {
        let idFromInt    = userInfo["orderId"] as? Int
        let idFromString = (userInfo["orderId"] as? String).flatMap(Int.init)

        guard let orderId = idFromInt ?? idFromString else {
            print("⚠️ No valid orderId in push payload:", userInfo)
            return
        }

        print("📦 Saving received orderId:", orderId)
        UserDefaults.standard.set(orderId, forKey: lastReadyOrderKey)
    }
}

let WELCOME_KEY = "welcome"


// MARK: - RTL env
struct IsRtlKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isRtl: Bool {
        get { self[IsRtlKey.self] }
        set { self[IsRtlKey.self] = newValue }
    }
}

func registerAdminDevice(token: String, displayName: String, isPrinterManager: Bool) {
    struct RegisterAdminDeviceDto: Codable {
        let miniAppId: Int
        let token: String
        let displayName: String
        let isPrinterManager: Bool
    }

    let miniAppId = Int(UserDefaults.standard.string(forKey: "shopId") ?? "12") ?? 12

    let dto = RegisterAdminDeviceDto(
        miniAppId: miniAppId,
        token: token,
        displayName: displayName,
        isPrinterManager: isPrinterManager
    )

    guard let url = URL(string: "https://minis.studio/api/admin/registerAdminDevice") else { return }
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try? JSONEncoder().encode(dto)

    Task {
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            print("📡 registerAdminDevice:", String(data: data, encoding: .utf8) ?? "")
        } catch {
            print("❌ registerAdminDevice error:", error.localizedDescription)
        }
    }
}
struct ActiveDiscount: Codable, Equatable {
    let campaignId: String
    let percent: Int
    let expiresAt: Date
}

enum StudentDiscountHandoff {
    static let pendingClaimKey = "pendingStudentClaim.v1"

    static func pullPendingClaim() -> StudentClaim? {
        let d = MinisShared.sharedDefaults
        guard let data = d.data(forKey: pendingClaimKey),
              let claim = try? JSONDecoder().decode(StudentClaim.self, from: data)
        else { return nil }

        // ✅ one-time
        d.removeObject(forKey: pendingClaimKey)
        d.synchronize()
        return claim
    }
}

enum MinisShared {
    static let groupId = "group.minis"
    static var sharedDefaults: UserDefaults { UserDefaults(suiteName: groupId)! }

    // Keys
    static let activeDiscountKey = "activeDiscount.v1"

    static func loadActiveDiscount() -> ActiveDiscount? {
        let d = sharedDefaults
        guard let data = d.data(forKey: activeDiscountKey),
              let disc = try? JSONDecoder().decode(ActiveDiscount.self, from: data)
        else { return nil }

        if disc.expiresAt < Date() {
            d.removeObject(forKey: activeDiscountKey)
            d.synchronize()
            return nil
        }
        return disc
    }

    static func saveActiveDiscount(_ disc: ActiveDiscount?) {
        let d = sharedDefaults
        if let disc, let data = try? JSONEncoder().encode(disc) {
            d.set(data, forKey: activeDiscountKey)
        } else {
            d.removeObject(forKey: activeDiscountKey)
        }
        d.synchronize()
    }
}

extension Notification.Name {
    static let myItemsChanged = Notification.Name("myItemsChanged")
}

func getOrCreateAnonId(appGroupId: String) -> String {
    if let suite = UserDefaults(suiteName: appGroupId),
       let existing = suite.string(forKey: "anonUUID"),
       !existing.isEmpty {
        return existing
    }

    if let existing = UserDefaults.standard.string(forKey: "anonUUID"),
       !existing.isEmpty {
        return existing
    }

    let id = UUID().uuidString

    UserDefaults.standard.set(id, forKey: "anonUUID")
    UserDefaults(suiteName: appGroupId)?.set(id, forKey: "anonUUID")

    return id
}


enum AppSettings {
    enum Key {
        static let cashPointMode = "cashPointMode"
    }

    enum Defaults {
        static let cashPointMode = false
    }

    static func bootstrap() {
        let d = UserDefaults.standard
        if d.object(forKey: Key.cashPointMode) == nil {
            d.set(Defaults.cashPointMode, forKey: Key.cashPointMode)
        }
    }
}


