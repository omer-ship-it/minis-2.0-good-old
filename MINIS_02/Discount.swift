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

        // =====================================================
        // ✅ 1) NEW SIMPLE FORMAT
        //     https://minis.studio/student
        // =====================================================
        if path == "/student" || path == "/student/" {

            let mini = UserDefaults.standard.integer(forKey: "miniAppId")
            guard mini > 0 else { return nil }

            return StudentClaim(
                miniAppId: mini,
                campaignId: "student",
                discountPercent: 10,
                durationMonths: 6
            )
        }

        // =====================================================
        // ✅ 2) OLD / ADVANCED FORMAT (still supported)
        //     /student/claim?miniAppId=...&off=...
        // =====================================================
        guard path.contains("/student/claim") else { return nil }

        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []

        func getCI(_ key: String) -> String? {
            items.first { $0.name.lowercased() == key.lowercased() }?.value
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

struct MemberJoinIntent: Identifiable, Codable, Equatable {
    var id: String { "\(miniAppId)-\(campaignId)" }

    let miniAppId: Int
    let campaignId: String   // e.g. "members"
    let stampEarnedNow: Int  // usually 1
    let createdAt: TimeInterval

    static func from(url: URL) -> MemberJoinIntent? {
        let host = (url.host ?? "").lowercased()
        guard host == "minis.studio" || host.hasSuffix(".minis.studio") else { return nil }

        let path = url.path.lowercased()

        // ✅ Simple format:
        // https://minis.studio/members
        if path == "/members" || path == "/members/" {
            let mini = UserDefaults.standard.integer(forKey: "miniAppId")
            guard mini > 0 else { return nil }
            return MemberJoinIntent(
                miniAppId: mini,
                campaignId: "members",
                stampEarnedNow: 1,
                createdAt: Date().timeIntervalSince1970
            )
        }

        // ✅ Advanced format (optional):
        // https://minis.studio/members/join?miniAppId=3&stamp=1&camp=members
        guard path.contains("/members/join") else { return nil }

        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func getCI(_ key: String) -> String? {
            items.first { $0.name.lowercased() == key.lowercased() }?.value
        }

        let mini  = Int(getCI("miniAppId") ?? "") ?? UserDefaults.standard.integer(forKey: "miniAppId")
        let camp  = getCI("camp") ?? "members"
        let stamp = Int(getCI("stamp") ?? "") ?? 1

        guard mini > 0 else { return nil }

        return MemberJoinIntent(
            miniAppId: mini,
            campaignId: camp,
            stampEarnedNow: max(1, stamp),
            createdAt: Date().timeIntervalSince1970
        )
    }
}

struct MembersClubView: View {

    let miniAppId: Int
    let campaignId: String
    let stampEarnedNow: Int
    

    @State private var showStoreSheet = false
    @State private var isSending = false
    @State private var sendError: String? = nil

    @State private var name: String = ""
    @State private var email: String = ""
    @State private var birthDay: Int = 1
    @State private var birthMonth: Int = 1

    @FocusState private var focusedField: Field?
    private enum Field { case name, email }

    private let textColor = Color(hex: "#324E57")
    private let bgColor   = Color(hex: "#D2C1A5")
    
    @Environment(\.dismiss) private var dismiss
    var openStoreOnSubmit: Bool = false 

    private var emailClean: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var nameClean: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canContinue: Bool {
        guard nameClean.count >= 2 else { return false }
        // identity = email → require basic valid email
        return emailClean.contains("@") && emailClean.contains(".")
    }

    private var hebrewMonthSymbols: [String] {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale(identifier: "he_IL")
        return cal.monthSymbols
    }

    private var monthNameHe: String {
        let idx = max(1, min(12, birthMonth)) - 1
        return hebrewMonthSymbols[idx]
    }
    
    private func membersFontName() -> String {
        if let stored = UserDefaults.standard.string(forKey: "fontName"),
           !stored.isEmpty,
           stored != "System" {
            return stored
        }
        return primariesFontName
    }
    var body: some View {
        VStack(spacing: 22) {

            Spacer()

            Text("☕️")
                .font(.system(size: 72))

            Text("החברים של בית העם")
                .font(.primariesDemi(30))
                .foregroundColor(textColor)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            Text("הרווחת חותמת אחת — כל קפה 10 עלינו")
                .font(.primariesDemi(17))
                .foregroundColor(textColor.opacity(0.90))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
                .frame(maxWidth: .infinity)

            VStack(spacing: 18) {

                UnderlineRTLTextField(
                    placeholder: "שם מלא",
                    text: $name,
                    keyboard: .default,
                    returnKey: .next,
                    textContentType: .name,
                    autocap: .words,
                    fontName: membersFontName(),   // 👈 now resolved here
                    fontSize: 17,
                    onReturn: { focusedField = .email }
                )

                UnderlineRTLTextField(
                    placeholder: "אימייל",
                    text: $email,
                    keyboard: .emailAddress,
                    returnKey: .done,
                    textContentType: .emailAddress,
                    autocap: .none,
                    fontName: membersFontName(),
                    fontSize: 17,
                    onReturn: { focusedField = nil }
                )
                .focused($focusedField, equals: .email)

                Text("יום הולדת")
                    .font(.primariesDemi(17))
                    .foregroundColor(textColor.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)

                // format: חודש: ינואר   יום: 3
                HStack(spacing: 18) {

                    Menu {
                        ForEach(1...12, id: \.self) { m in
                            Button(hebrewMonthSymbols[m-1]) { birthMonth = m }
                        }
                    } label: {
                        underlineMenuLabel("חודש: \(monthNameHe)")
                    }
                    .buttonStyle(.plain)
                    .environment(\.layoutDirection, .rightToLeft)

                    Menu {
                        ForEach(1...31, id: \.self) { d in
                            Button("\(d)") { birthDay = d }
                        }
                    } label: {
                        underlineMenuLabel("יום: \(birthDay)")
                    }
                    .buttonStyle(.plain)
                    .environment(\.layoutDirection, .rightToLeft)
                }
                .environment(\.layoutDirection, .rightToLeft)

                if let err = sendError {
                    Text(err)
                        .font(.primariesDemi(14))
                        .foregroundColor(.red.opacity(0.9))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 28)
            .environment(\.layoutDirection, .rightToLeft)
            .padding(.top, 8)

            Spacer()

            Button {
                guard !isSending else { return }
                isSending = true
                sendError = nil

                // 1) Save locally (always)
                persistMemberJoin()

                // 2) Fire-and-forget to server, then open store
                identifyMemberByEmail { ok, msg in
                    DispatchQueue.main.async {
                        self.isSending = false
                        if !ok {
                            self.sendError = msg ?? "שגיאה בשליחה לשרת"
                            // still let them continue to store
                        }
                        self.showStoreSheet = true
                    }
                }
            } label: {
                ZStack {
                    Text("הצטרף לחברים של בית העם")
                        .font(.primariesDemi(18))
                        .foregroundColor(bgColor)
                        .opacity(isSending ? 0 : 1)

                    if isSending {
                        ProgressView()
                            .tint(bgColor)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(textColor.opacity(canContinue && !isSending ? 1 : 0.45))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .disabled(!canContinue || isSending)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .environment(\.layoutDirection, .rightToLeft)
        .environment(\.locale, Locale(identifier: "he_IL"))
        .background(bgColor.ignoresSafeArea())
        .interactiveDismissDisabled(false)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                focusedField = .name
            }
        }
        .fullScreenCover(isPresented: $showStoreSheet) {
            StoreProductPresenter(appId: 6737725110)
                .ignoresSafeArea()
                .background(bgColor)
                .environment(\.layoutDirection, .rightToLeft)
                .environment(\.locale, Locale(identifier: "he_IL"))
        }
    }

    private func underlineMenuLabel(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
              
                Text(text)
                    .font(.primariesDemi(16))
                    .foregroundColor(textColor)
                Spacer()
            }
            Rectangle()
                .fill(Color.primary.opacity(0.35))
                .frame(height: 1)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Local persist (App Group ready later)
    private func persistMemberJoin() {
        let mm = String(format: "%02d", birthMonth)
        let dd = String(format: "%02d", birthDay)
        let birthdayMMDD = "\(mm)-\(dd)"

        // ✅ ensure anon id exists
        let anon = UserDefaults.standard.string(forKey: "anonUUID") ?? UUID().uuidString
        UserDefaults.standard.set(anon, forKey: "anonUUID")

        let payload: [String: Any] = [
            "miniAppId": miniAppId,
            "campaignId": campaignId,
            "stampEarnedNow": stampEarnedNow,
            "name": nameClean,
            "email": emailClean,
            "birthdayMMDD": birthdayMMDD,
            "anonId": anon,
            "createdAt": Date().timeIntervalSince1970
        ]

        UserDefaults.standard.set(payload, forKey: "pendingMemberJoin")
        UserDefaults.standard.set(payload, forKey: "memberProfileLocal") // ✅ immediate local profile
    }

    // MARK: - Server call
    private func identifyMemberByEmail(completion: @escaping (Bool, String?) -> Void) {
        let mm = String(format: "%02d", birthMonth)
        let dd = String(format: "%02d", birthDay)
        let birthdayMMDD = "\(mm)-\(dd)"

        let anon = UserDefaults.standard.string(forKey: "anonUUID") ?? UUID().uuidString
        UserDefaults.standard.set(anon, forKey: "anonUUID")

        guard let url = URL(string: "https://minis.studio/api/identity/members/join") else {
            completion(false, "Bad URL")
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 6

        #if APPCLIP
        let appVariant = "appclip"
        #else
        let appVariant = "app"
        #endif

        let payload: [String: Any] = [
            "miniAppId": miniAppId,
            "campaign": campaignId,
            "stampEarnedNow": stampEarnedNow,
            "anonId": anon,
            "platform": "ios",
            "appVariant": appVariant,
            "email": emailClean,
            "name": nameClean,
            "birthdayMMDD": birthdayMMDD
        ]

        req.httpBody = (try? JSONSerialization.data(withJSONObject: payload))

        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err = err {
                completion(false, err.localizedDescription)
                return
            }
            guard let http = resp as? HTTPURLResponse else {
                completion(false, "No response")
                return
            }
            if (200...299).contains(http.statusCode) {
                completion(true, nil)
            } else {
                let body = String(data: data ?? Data(), encoding: .utf8) ?? ""
                completion(false, body.isEmpty ? "HTTP \(http.statusCode)" : body)
            }
        }.resume()
    }
}

// MARK: - RTL UIKit TextField (reliable right alignment)
private struct UnderlineRTLTextField: View {
    let placeholder: String
    @Binding var text: String

    var keyboard: UIKeyboardType = .default
    var returnKey: UIReturnKeyType = .default
    var textContentType: UITextContentType? = nil
    var autocap: UITextAutocapitalizationType = .sentences
    var fontName: String
    var fontSize: CGFloat = 17
    var onReturn: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            RTLUITextField(
                placeholder: placeholder,
                text: $text,
                keyboard: keyboard,
                returnKey: returnKey,
                textContentType: textContentType,
                autocap: autocap,
                fontName: fontName,
                fontSize: fontSize,
                onReturn: onReturn
            )
            .frame(height: 30)

            Rectangle()
                .fill(Color.primary.opacity(0.35))
                .frame(height: 1)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

private struct RTLUITextField: UIViewRepresentable {
    let placeholder: String
    @Binding var text: String

    let keyboard: UIKeyboardType
    let returnKey: UIReturnKeyType
    let textContentType: UITextContentType?
    let autocap: UITextAutocapitalizationType
    let fontName: String
    let fontSize: CGFloat
    let onReturn: (() -> Void)?

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: RTLUITextField
        init(_ parent: RTLUITextField) { self.parent = parent }

        @objc func changed(_ tf: UITextField) {
            parent.text = tf.text ?? ""
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onReturn?()
            return true
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextField {
        let tf = UITextField()
        tf.delegate = context.coordinator

        tf.placeholder = placeholder
        tf.text = text

        tf.semanticContentAttribute = .forceRightToLeft
        tf.textAlignment = .right

        tf.keyboardType = keyboard
        tf.returnKeyType = returnKey
        tf.textContentType = textContentType
        tf.autocapitalizationType = autocap
        tf.autocorrectionType = .no
        tf.spellCheckingType = .no
        tf.clearButtonMode = .whileEditing
        tf.textColor = UIColor(Color(hex: "#324E57"))
        tf.tintColor = UIColor(Color(hex: "#324E57")) // cursor
        
        tf.font = UIFont(name: fontName, size: fontSize)
            ?? UIFont.systemFont(ofSize: fontSize, weight: .semibold)

        tf.addTarget(context.coordinator,
                     action: #selector(Coordinator.changed(_:)),
                     for: .editingChanged)
        return tf
    }

    func updateUIView(_ tf: UITextField, context: Context) {
        if tf.text != text { tf.text = text }
        tf.placeholder = placeholder
        tf.semanticContentAttribute = .forceRightToLeft
        tf.textAlignment = .right

        let desired = UIFont(name: fontName, size: fontSize)
            ?? UIFont.systemFont(ofSize: fontSize, weight: .semibold)
        if tf.font?.fontName != desired.fontName || tf.font?.pointSize != desired.pointSize {
            tf.font = desired
        }
    }
}

struct UnderlineTextField: View {
    let title: String
    @Binding var text: String
    var keyboard: UIKeyboardType = .default
    var autocap: TextInputAutocapitalization = .words

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            TextField(title, text: $text)
                .font(.primariesDemi(16))
                .multilineTextAlignment(.trailing)
                .keyboardType(keyboard)
                .textInputAutocapitalization(autocap)
                .padding(.vertical, 6)

            Rectangle()
                .fill(Color.primary.opacity(0.35))
                .frame(height: 1)
        }
    }
}
