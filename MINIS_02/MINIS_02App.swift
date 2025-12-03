import SwiftUI
import UserNotifications
import UIKit

// MARK: - Reset mini shop defaults
func resetShopUserDefaultsToDefaults() {
    let defaults = UserDefaults.standard
    defaults.set("#f7f5f1", forKey: "bg")
    defaults.set("#000000", forKey: "categorySelectedTextColor")
    defaults.set("#000000", forKey: "categoryTextColor")
    defaults.removeObject(forKey: "priceColor")
    defaults.removeObject(forKey: "selectedCategoryColor")
    defaults.set("#000000", forKey: "brandColor")
    defaults.set("ltr", forKey: "direction")
    defaults.set("#000000", forKey: "basketBadgeTextColor")
    defaults.set("#000000", forKey: "priceTextColor")
    defaults.set("#FFFFFF", forKey: "basketBadgeBackground")
    defaults.set("#FFFFFF", forKey: "badgeTextColor")
    defaults.set("#000000", forKey: "buttonColor")
    defaults.set("#FFFFFF", forKey: "buttonTextColor")
    defaults.set("System", forKey: "fontName")
    defaults.set("false", forKey: "isDelivery")
    defaults.set("GBP", forKey: "currency")
}

@main
struct MINIS_02App: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @State var isRtl = true
    @Environment(\.scenePhase) private var scenePhase        // 👈 ADD THIS
    @AppStorage("cashPointMode") private var cashPointMode: Bool = true
    @AppStorage("shopId") private var shopId: String = "0"
    @AppStorage("launchMenuOnce") private var launchMenuOnce: Bool = false

    init() {
         UIView.appearance().tintColor = UIColor.label

         // 🔥 Global RTL for UIKit (menus, alerts, etc.)
         UIView.appearance().semanticContentAttribute = .forceRightToLeft
        UserDefaults.standard.removeObject(forKey: "posSavedName")
          UserDefaults.standard.removeObject(forKey: "posSavedPhone")
     }
    
    var body: some Scene {
        WindowGroup {
            Group {
                if cashPointMode {
                    CashPointView()
                        .tint(.primary)
                } else {
                    menuView()
                }
            }
            .environment(\.isRtl, isRtl)
            .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
            .environment(\.currency, isRtl ? "₪" : "£")
            .accentColor(.primary)
            .onOpenURL { url in
                handleIncoming(url: url)
            }

            // 🔥 ADD THIS BLOCK (scenePhase listener)
            .onChange(of: scenePhase) { phase in
                switch phase {
                case .active:
                    print("📡 App active → start polling")
                    OrdersAutoPrinter.shared.startPolling(interval: 10)   // or 30 seconds
                case .inactive, .background:
                    print("🛑 App inactive/background → stop polling")
                    OrdersAutoPrinter.shared.stopPolling()
                @unknown default:
                    break
                }
            }
        }
    }

    private func handleIncoming(url: URL) {
        guard url.host == "minis.studio" else { return }
        let lastComponent = url.lastPathComponent
        guard !lastComponent.isEmpty, Int(lastComponent) != nil else { return }

        resetShopUserDefaultsToDefaults()
        shopId = lastComponent
        UserDefaults.standard.set(lastComponent, forKey: "shopId")
        launchMenuOnce = true
    }
}
