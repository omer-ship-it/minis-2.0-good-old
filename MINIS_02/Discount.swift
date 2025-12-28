import SwiftUI
import StoreKit

import SwiftUI
import StoreKit

struct StudentDiscountView: View {

    let miniAppId: Int
    let campaignId: String
    let discountPercent: Int
    let durationMonths: Int

    @Environment(\.isRtl) private var isRtl
    @State private var showStoreSheet = false   // 🔥 auto-open store
    @State private var showOverlay = false
    
    private let textColor = Color(hex: "#324E57")
    private let bgColor   = Color(hex: "#D2C1A5")

    var body: some View {
        VStack(spacing: 28) {

            Spacer()

            // 🎓 Icon
            Text("🎓")
                .font(.system(size: 72))

            // Title
            Text("הטבת סטודנטים הופעלה")
                .font(.primariesDemi(isRtl ? 26 : 28))
                .foregroundColor(textColor)
                .multilineTextAlignment(.center)

            // Subtitle
            Text("הנחה של \(discountPercent)% להזמנות באפליקציה")
                .font(.primariesDemi(isRtl ? 18 : 20))
                .foregroundColor(textColor)
                .multilineTextAlignment(.center)

          
            .font(.primariesDemi(isRtl ? 15 : 16))
            .foregroundColor(textColor.opacity(0.85))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)

            Spacer()

            // 🔒 Single CTA — no escape
            Button {
                persistStudentDiscount()
                showStoreSheet = true
            } label: {
                Text("להורדת האפליקציה")
                    .font(.primariesDemi(isRtl ? 17 : 18))
                    .foregroundColor(bgColor)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(textColor)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .padding(.horizontal, 24)
          
            .padding(.bottom, 24)
        }
        .environment(\.layoutDirection, .rightToLeft)
        .background(bgColor.ignoresSafeArea())
        .interactiveDismissDisabled(true)              // 🔒 no swipe-down
        .fullScreenCover(isPresented: $showStoreSheet) {
            StoreProductPresenter(appId: 6737725110)
                .ignoresSafeArea()
                .background(bgColor)
        }
        
    }
    private func openAppStore() {
        // ✅ Replace with your real app id
        let appId = "6737725110"

        if let url = URL(string: "itms-apps://itunes.apple.com/app/id\(appId)") {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
    }
    // MARK: - Persist for Full App (App Group ready)
    private func persistStudentDiscount() {
        let expiresAt = Calendar.current.date(
            byAdding: .month,
            value: durationMonths,
            to: Date()
        )!

        let payload: [String: Any] = [
            "miniAppId": miniAppId,
            "campaignId": campaignId,
            "discountPercent": discountPercent,
            "expiresAt": expiresAt.timeIntervalSince1970
        ]

        // ⚠️ For production: move this to App Group UserDefaults
        UserDefaults.standard.set(payload, forKey: "pendingStudentDiscount")
    }
}

import WebKit
import SwiftUI

struct StudentHandshakeWebSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isRtl) private var isRtl

    var body: some View {
        NavigationStack {
            CashPointURLWebView(url: url)
                .navigationTitle("הנחת סטודנטים - 10%")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 16, weight: .bold))
                                .padding(8)
                                .background(Color(.systemGray5))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }
                }
        }
        .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
    }
}

struct CashPointURLWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let web = WKWebView(frame: .zero)
        web.scrollView.isScrollEnabled = true
        web.scrollView.bounces = true
        web.load(URLRequest(url: url))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}


import SwiftUI
import StoreKit

struct AppStoreLoadingSheet: View {
    let appId: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()

                // ✅ immediate UI (never blank)
                VStack(spacing: 14) {
                    ProgressView()
                        .scaleEffect(1.2)
                    Text("טוען את App Store…")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.primary)
                    Text("עוד רגע ונפתח את העמוד")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // ✅ this will present SKStoreProductViewController when ready
                StoreProductPresenter(appId: appId)
                    .frame(width: 0, height: 0)   // keep invisible
            }
            .navigationTitle("להורדת האפליקציה")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .bold))
                            .padding(8)
                            .background(Color(.systemGray5))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

import SwiftUI
import StoreKit

struct StoreProductPresenter: UIViewControllerRepresentable {
    let appId: Int  // numeric id, e.g. 6737725110
    @Environment(\.dismiss) private var dismiss

    final class Coordinator: NSObject, SKStoreProductViewControllerDelegate {
        let parent: StoreProductPresenter
        init(_ parent: StoreProductPresenter) { self.parent = parent }
        func productViewControllerDidFinish(_ viewController: SKStoreProductViewController) {
            viewController.dismiss(animated: true) {
                self.parent.dismiss() // close the SwiftUI cover too
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIViewController {
        // A plain host VC that will present the Store VC modally (required by Apple).
        let host = UIViewController()
        host.view.backgroundColor = .clear

        let storeVC = SKStoreProductViewController()
        storeVC.delegate = context.coordinator

        let params = [SKStoreProductParameterITunesItemIdentifier: NSNumber(value: appId)]
        storeVC.loadProduct(withParameters: params) { loaded, error in
            DispatchQueue.main.async {
                if let error = error {
                    print("❌ Store load error:", error.localizedDescription)
                    self.dismiss()
                    return
                }
                // Present modally (complies with SKStoreProductViewController rules)
                host.present(storeVC, animated: true, completion: nil)
            }
        }

        return host
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}

struct StudentClaim: Identifiable, Codable, Equatable {
    var id: String { "\(miniAppId)-\(campaignId)-\(discountPercent)-\(durationMonths)" }

    let miniAppId: Int
    let campaignId: String
    let discountPercent: Int
    let durationMonths: Int

    static func from(url: URL) -> StudentClaim? {
        // tolerate host casing + possible subdomains
        let host = (url.host ?? "").lowercased()
        guard host == "minis.studio" || host.hasSuffix(".minis.studio") else { return nil }

        let path = url.path.lowercased()
        guard path.contains("/student/claim") else { return nil }

        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []

        func getCI(_ key: String) -> String? {
            items.first(where: { $0.name.lowercased() == key.lowercased() })?.value
        }

        let mini   = Int(getCI("miniAppId") ?? "") ?? 0
        let camp   = getCI("camp") ?? "student"
        let off    = Int(getCI("off") ?? "") ?? 10
        let months = Int(getCI("months") ?? "") ?? 6

        guard mini > 0 else { return nil }

        return StudentClaim(
            miniAppId: mini,
            campaignId: camp,
            discountPercent: off,
            durationMonths: months
        )
    }
}
