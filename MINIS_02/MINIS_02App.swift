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

func disableQuickTypeBar() {
    let tf = UITextField.appearance()
    tf.inputAssistantItem.leadingBarButtonGroups = []
    tf.inputAssistantItem.trailingBarButtonGroups = []

    let tv = UITextView.appearance()
    tv.inputAssistantItem.leadingBarButtonGroups = []
    tv.inputAssistantItem.trailingBarButtonGroups = []
}

@main
struct MINIS_02App: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @State var isRtl = true
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("cashPointMode") private var cashPointMode: Bool = true
    @AppStorage("shopId") private var shopId: String = "12"
    @AppStorage("miniAppId") private var miniAppId: Int = 0          // 👈 NEW
    @AppStorage("launchMenuOnce") private var launchMenuOnce: Bool = false
    @AppStorage("autoPrintEnabled") private var autoPrintEnabled: Bool = true

    init() {
      //  PrinterManager.shared.setPrinterSet(.ron)
        let demoData = PrinterManager.SalesReportData(
            ppaRestaurant: 26,
            dinersRestaurant: 14,
            totalRestaurantIncVat: 375.0,
            ppaRestaurantValue: 7.713,

            ppaTA: 22,
            dinersTA: 8,
            totalTAIncVat: 317.2,

            // 🔄 REVERSED VALUES
            totalSalesIncVat: 699.9,   // was 692.2
            tipsTotal: 7.713,
            grandTotal: 692.2,         // was 699.9

            cashAmount: 250.0,
            cashCount: 3,
            cardAmount: 329.9,
            cardCount: 5,
            collectionsTotalAmount: 579.9,
            collectionsTotalCount: 8,

            closedDrawersAmount: 0,
            openDrawersAmount: 0,
            depositWithdrawAmount: 0,
            drawerTotalAmount: 0,
            mainDrawerAmount: 0,
            hostStationDrawerAmount: 0,

            tipBaseTotal: 0,
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
        PrinterManager.shared.printSalesDebugReport(demoData)
        UIView.appearance().tintColor = UIColor.label

        // 🔥 Global RTL for UIKit (menus, alerts, etc.)
        UIView.appearance().semanticContentAttribute = .forceRightToLeft

        UISegmentedControl.appearance().setTitleTextAttributes(
            [.foregroundColor: UIColor.black],
            for: .selected
        )

        // Unselected: white/black 70% opacity depending on theme
        let normalTextColor = UIColor { trait in
            trait.userInterfaceStyle == .dark ? .white.withAlphaComponent(0.7)
                                              : .black.withAlphaComponent(0.7)
        }

        let selectedTextColor = UIColor { trait in
            trait.userInterfaceStyle == .dark ? .black : .white
        }

        let selectedTint = UIColor { trait in
            trait.userInterfaceStyle == .dark ? .white : .black
        }

        let backgroundColor = UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor.white.withAlphaComponent(0.15)
                : UIColor.black.withAlphaComponent(0.10)
        }

        // MARK: - Apply
        UISegmentedControl.appearance().setTitleTextAttributes(
            [.foregroundColor: normalTextColor],
            for: .normal
        )

        UISegmentedControl.appearance().setTitleTextAttributes(
            [.foregroundColor: selectedTextColor],
            for: .selected
        )

        UISegmentedControl.appearance().selectedSegmentTintColor = selectedTint
        UISegmentedControl.appearance().backgroundColor = backgroundColor

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
                    // Use your existing mini UI here.
                    // If you have a helper:
                    menuView()
                    //
                    // For now, to keep it compiling even if you don't:
                    Text("Mini app view")
                        .tint(.primary)
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

    // MARK: - NFC / QR Deep Link Handler
    // URLs like:
    //   https://minis.studio/shop/12
    //   https://minis.studio/fastlane/12
    // mini type = pathComponents[1] ("shop" / "fastlane")
    // miniAppId = Int(pathComponents[2])
    private func handleIncoming(url: URL) {
        guard url.host == "minis.studio" else { return }

        let components = url.pathComponents
        // Expect at least: ["/", "shop", "12"]
        guard components.count >= 3 else { return }

        let miniType = components[1]              // e.g. "shop" or "fastlane"
        let rawId = components[2]                 // e.g. "12"

        guard let id = Int(rawId) else { return }

        print("🎯 Deep link → type=\(miniType), miniAppId=\(id)")

        // Save mini id
        miniAppId = id
        UserDefaults.standard.set(id, forKey: "miniAppId")

        // For now: mirror to shopId for existing logic
        shopId = rawId
        UserDefaults.standard.set(rawId, forKey: "shopId")

        // Reset style/theme for the new mini
        resetShopUserDefaultsToDefaults()

        // Force opening Mini side (not POS)
        launchMenuOnce = true
        cashPointMode = false
    }
}
