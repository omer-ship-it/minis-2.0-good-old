import SwiftUI

extension Notification.Name {
    static let orderReady = Notification.Name("OrderReadyNotification")
}

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    private let lastReadyOrderKey    = "lastReadyOrderId"
    private let isLastOrderReadyKey  = "isLastOrderReady"
    private let apnsTokenKey         = "apnsDeviceToken"   // 👈 stored for printing & debugging

    // MARK: - App launch
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil
    ) -> Bool {

        print("🚀 AppDelegate didFinishLaunching")

        let center = UNUserNotificationCenter.current()
        center.delegate = self

        // 🔇 Removed the automatic prompt:
        // center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
        //     print("🔐 Notification auth granted:", granted, "error:", String(describing: error))
        // }

        application.registerForRemoteNotifications()

        // If app opened due to remote notification
        if let remote = launchOptions?[.remoteNotification] as? [AnyHashable: Any] {
            print("🚀 Launched from remote notification:", remote)
            storeOrderIdIfPresent(remote)
            UserDefaults.standard.set(true, forKey: isLastOrderReadyKey)

            NotificationCenter.default.post(name: .orderReady, object: nil, userInfo: remote)
        } else {
            print("ℹ️ No remote notification in launchOptions")
        }

        if let savedToken = UserDefaults.standard.string(forKey: apnsTokenKey) {
            print("🔎 Saved APNs token (from last launch):", savedToken)
        }

        return true
    }

    // MARK: - APNs token registration
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        // Convert binary token → 64 char hex
        let tokenString = deviceToken.map { String(format: "%02x", $0) }.joined()
        let name = UIDevice.current.name

           registerAdminDevice(
               token: tokenString,
               displayName: name,
               isPrinterManager: false
           )

        print("📬 APNs token (hex): \(tokenString)")

        // Persist
        UserDefaults.standard.set(tokenString, forKey: apnsTokenKey)
        UserDefaults.standard.synchronize()

        // Optional: send token to server
        // sendTokenToServer(tokenString)
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

        // Store last ready order (your existing logic)
        storeOrderIdIfPresent(userInfo)

        // Mark the last order as ready (for your UI)
        UserDefaults.standard.set(true, forKey: isLastOrderReadyKey)
        print("✅ isLastOrderReady = true (from silent/background push)")

        // Notify any listeners in the app
        NotificationCenter.default.post(name: .orderReady, object: nil, userInfo: userInfo)

        // 🔥 Trigger auto-printer fetch+print
#if !APPCLIP    // 👈 Skip printing logic inside App Clip
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
            let (data, resp) = try await URLSession.shared.data(for: req)
            print("📡 registerAdminDevice:", String(data: data, encoding: .utf8) ?? "")
        } catch {
            print("❌ registerAdminDevice error:", error.localizedDescription)
        }
    }
}
