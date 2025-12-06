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
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("cashPointMode") private var cashPointMode: Bool = true
    @AppStorage("shopId") private var shopId: String = "0"
    @AppStorage("launchMenuOnce") private var launchMenuOnce: Bool = false
    @AppStorage("autoPrintEnabled") private var autoPrintEnabled: Bool = true   // 👈 new flag

    init() {
        // PrinterManager.shared.printSalesDebugDemo()
        UIView.appearance().tintColor = UIColor.label

        // 🔥 Global RTL for UIKit (menus, alerts, etc.)
        UIView.appearance().semanticContentAttribute = .forceRightToLeft
        UISegmentedControl.appearance().setTitleTextAttributes(
              [.foregroundColor: UIColor.black],
              for: .selected
          )

          // Unselected: white 70% opacity
          UISegmentedControl.appearance().setTitleTextAttributes(
              [.foregroundColor: UIColor.white.withAlphaComponent(0.7)],
              for: .normal
          )

          // Background for selected segment
          UISegmentedControl.appearance().selectedSegmentTintColor = UIColor.white

          // Transparent background for the whole control
          UISegmentedControl.appearance().backgroundColor = UIColor.white.withAlphaComponent(0.15)
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
            // 🔥 React to app lifecycle
            .onChange(of: scenePhase) { phase in
                switch phase {
                case .active:
                    if cashPointMode && autoPrintEnabled {
                        print("📡 App active + cashPointMode + autoPrintEnabled → start polling")
                        OrdersAutoPrinter.shared.startPolling(interval: 10) // or 30
                    } else {
                        print("📡 App active but auto-print disabled → stop polling")
                        OrdersAutoPrinter.shared.stopPolling()
                    }

                case .inactive, .background:
                    print("🛑 App inactive/background → stop polling")
                    OrdersAutoPrinter.shared.stopPolling()

                @unknown default:
                    break
                }
            }
            // 🔥 React if the setting changes while app is running
            .onChange(of: autoPrintEnabled) { enabled in
                guard scenePhase == .active, cashPointMode else {
                    OrdersAutoPrinter.shared.stopPolling()
                    return
                }

                if enabled {
                    print("⚙️ autoPrintEnabled turned ON → start polling")
                    OrdersAutoPrinter.shared.startPolling(interval: 10)
                } else {
                    print("⚙️ autoPrintEnabled turned OFF → stop polling")
                    OrdersAutoPrinter.shared.stopPolling()
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
