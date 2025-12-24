import SwiftUI
import StripeCore

@main
struct MiniApp: App {
    @AppStorage("direction") private var direction: String = "ltr"

    init() {
        STPAPIClient.shared.publishableKey = "pk_live_51H5URzFZIwZSNufssK4R7BjLhpqxHVcfmEZVH8Tg74MAHMA20RfkYhIfbwFjDWJ55KzHWkOhEcqVWhIO2VShjOcU00Tslmi1XT"

        let std = UserDefaults.standard
        let miniId = std.integer(forKey: "miniAppId")
        let shopId = std.string(forKey: "shopId")

        if miniId == 0 && (shopId == nil || shopId!.isEmpty) {
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
            .onAppear { parseMiniIfNeeded() }
        }
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
}
