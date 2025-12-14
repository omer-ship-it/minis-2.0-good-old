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
    @AppStorage("miniAppId") private var miniAppId: Int = 0          // 👈 NEW
    @AppStorage("launchMenuOnce") private var launchMenuOnce: Bool = false
    @AppStorage("autoPrintEnabled") private var autoPrintEnabled: Bool = true
    
    @AppStorage("direction") private var direction: String = "ltr"
    @AppStorage("deliveryLoc") private var deliveryLoc: String = ""

    init() {
        STPAPIClient.shared.publishableKey = "pk_live_51H5URzFZIwZSNufssK4R7BjLhpqxHVcfmEZVH8Tg74MAHMA20RfkYhIfbwFjDWJ55KzHWkOhEcqVWhIO2VShjOcU00Tslmi1XT"
      //  PrinterManager.shared.setPrinterSet(.ron)
        let demoData = PrinterManager.SalesReportData(
            ppaRestaurant: 50,
            dinersRestaurant: 223,
            totalRestaurantIncVat: 11304,
            ppaRestaurantValue: 0,

            ppaTA: 32,
            dinersTA: 138,
            totalTAIncVat: 4472,

            // 🔄 REVERSED VALUES
            totalSalesIncVat: 15776,   // was 692.2
            tipsTotal: 21,
            grandTotal: 15776,         // was 699.9

            cashAmount: 1457,
            cashCount: 47,
            cardAmount: 14319,
            cardCount: 314,
            collectionsTotalAmount: 361,
            collectionsTotalCount: 15776,

            closedDrawersAmount: 0,
            openDrawersAmount: 0,
            depositWithdrawAmount: 0,
            drawerTotalAmount: 0,
            mainDrawerAmount: 1478,
            hostStationDrawerAmount: 0,

            tipBaseTotal: 21,
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
                } else {
                    // Use your existing mini UI here.
                    // If you have a helper:
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
        print("🔗 onOpenURL → \(url.absoluteString)")

        guard url.host == "minis.studio" else { return }

        // ✅ Reset loc each time we open a new mini (prevents leakage between bars)
        deliveryLoc = ""
        UserDefaults.standard.removeObject(forKey: "deliveryLoc")

        // Parse path
        let components = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        guard let last = components.last, let id = Int(last) else { return }

        let miniType = components.dropLast().last ?? "unknown"
        print("🎯 Deep link → type=\(miniType), miniAppId=\(id)")

        miniAppId = id
        UserDefaults.standard.set(id, forKey: "miniAppId")

        let shopIdString = String(id)
        shopId = shopIdString
        UserDefaults.standard.set(shopIdString, forKey: "shopId")

        // ✅ Parse ?loc= from query string
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
}
