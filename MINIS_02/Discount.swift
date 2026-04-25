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
    @Environment(\.dismiss) private var dismiss

    private let textColor = Color(hex: "#324E57")
    private let bgColor   = Color(hex: "#D2C1A5")

    var body: some View {
        VStack(spacing: 22) {

            Spacer()

            Text("🎓")
                .font(.system(size: 72))

            Text("הטבת סטודנטים הופעלה")
                .font(.menuRegular(28).weight(.semibold))
                .foregroundColor(textColor)
                .multilineTextAlignment(.center)

            Text("הנחה של 10% להזמנות באפליקציה")
                .font(.menuRegular(20).weight(.semibold))
                .foregroundColor(textColor)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)

            Spacer()

            #if APPCLIP
            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    StoreProductPresenter.shared.present(appId: 6737725110)
                }
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
            #else
            Button {
                dismiss()
            } label: {
                Text("המשך לתפריט")
                    .font(.menuRegular(18).weight(.semibold))
                    .foregroundColor(bgColor)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(textColor)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            #endif
        }
        .environment(\.layoutDirection, .rightToLeft)
        .background(bgColor.ignoresSafeArea())
        .onAppear { activateDiscountNow() }
        #if APPCLIP
        .interactiveDismissDisabled(true)
        #endif
    }

    private func activateDiscountNow() {
        let expiresAt =
            Calendar.current.date(byAdding: .month, value: durationMonths, to: Date())
            ?? Date().addingTimeInterval(60 * 60 * 24 * 30 * Double(durationMonths))

        let disc = ActiveDiscount(
            campaignId: campaignId.isEmpty ? "student" : campaignId,
            percent: discountPercent,
            expiresAt: expiresAt
        )

        MinisShared.saveActiveDiscount(disc)

        // optional: force UI refresh in menu (if you want a toast immediately)
        NotificationCenter.default.post(name: .myItemsChanged, object: nil)
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
    @State private var marketingOptIn: Bool = false

    @State private var isSending = false
    @State private var sendError: String? = nil

    @State private var name: String = ""
    @State private var email: String = ""
    @State private var birthDay: Int? = nil
    @State private var birthMonth: Int? = nil

    // ✅ keyboard-aware
    @State private var keyboardHeight: CGFloat = 0

    @FocusState private var focusedField: Field?
    private enum Field { case name, email }

    @Environment(\.dismiss) private var dismiss

    // ✅ Theme
    private var accent: Color { MenuTheme.accent }
    private var accentUi: UIColor { UIColor(accent) }
    private var placeholderUi: UIColor { UIColor(accent).withAlphaComponent(0.55) }
    private var underline: Color { accent.opacity(0.35) }

    private var shopName: String {
        if miniAppId == 12 { return "בית העם" }
        if miniAppId == 13 { return "Vitamin" }
        
        let s = (UserDefaults.standard.string(forKey: "miniTitle") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? "החנות" : s
    }

    private var titleText: String { "החברים של \(shopName)" }
    private var ctaText: String { "הצטרף לחברים של \(shopName)" }

    private var emailClean: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var nameClean: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canContinue: Bool {
        guard nameClean.count >= 2 else { return false }
        guard emailClean.contains("@"), emailClean.contains(".") else { return false }
        guard birthMonth != nil, birthDay != nil else { return false }
        return true
    }

    private var hebrewMonthSymbols: [String] {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale(identifier: "he_IL")
        return cal.monthSymbols
    }

    private func membersFontName() -> String {
        return menuFontName()
    }

    private var monthLabel: String {
        if let m = birthMonth {
            return "חודש: \(hebrewMonthSymbols[m - 1])"
        } else {
            return "בחר חודש"
        }
    }

    private var dayLabel: String {
        if let d = birthDay {
            return "יום: \(d)"
        } else {
            return "בחר יום"
        }
    }

    @ViewBuilder
    private func benefitRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {

            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(accent)
                .frame(width: 20)

            Text(text)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
    }

    var body: some View {
        ZStack {
            Color.clear.ignoresSafeArea()

            // ✅ XMARK top-leading (always)
            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.primary)
                            .frame(width: 34, height: 34)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)

                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)

                Spacer()
            }
            .zIndex(50)

            ScrollView {
                VStack(spacing: 22) {

                    Spacer().frame(height: 18)

                    Text("☕️")
                        .font(.system(size: 72))

                    Text(titleText)
                        .font(.menuRegular(30).weight(.semibold))
                        .foregroundColor(accent)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)

                    VStack(alignment: .leading, spacing: 10) {
                        benefitRow(icon: "cup.and.saucer.fill", text: "כל קפה 10 עלינו")
                        benefitRow(icon: "clock.fill", text: "30% על כל מוצרי המאפה בין 16:00–17:00")
                        benefitRow(icon: "gift.fill", text: "שובר יום הולדת 50% הנחה")
                    }
                    .font(.menuRegular(16).weight(.semibold))
                    .foregroundColor(accent.opacity(0.9))
                    .frame(maxWidth: 420, alignment: .leading)
                    .padding(.horizontal, 28)

                    VStack(spacing: 18) {
                        UnderlineRTLTextField(
                            placeholder: "שם מלא",
                            text: $name,
                            keyboard: .default,
                            returnKey: .next,
                            textContentType: .name,
                            autocap: .words,
                            fontName: membersFontName(),
                            fontSize: 17,
                            onReturn: { focusedField = .email },
                            textColor: accentUi,
                            underlineColor: underline,
                            placeholderColor: placeholderUi
                        )
                        .focused($focusedField, equals: .name)

                        UnderlineRTLTextField(
                            placeholder: "אימייל",
                            text: $email,
                            keyboard: .emailAddress,
                            returnKey: .done,
                            textContentType: .emailAddress,
                            autocap: .none,
                            fontName: membersFontName(),
                            fontSize: 17,
                            onReturn: { focusedField = nil },
                            textColor: accentUi,
                            underlineColor: underline,
                            placeholderColor: placeholderUi
                        )
                        .focused($focusedField, equals: .email)

                        Text("יום הולדת")
                            .font(.menuRegular(17).weight(.semibold))
                            .foregroundColor(accent.opacity(0.9))
                            .frame(maxWidth: .infinity, alignment: .leading)

                        HStack(spacing: 18) {

                            Menu {
                                ForEach(1...12, id: \.self) { m in
                                    Button(hebrewMonthSymbols[m - 1]) { birthMonth = m }
                                }
                            } label: {
                                underlineMenuLabel(monthLabel)
                            }
                            .buttonStyle(.plain)
                            .environment(\.layoutDirection, .rightToLeft)

                            Menu {
                                ForEach(1...31, id: \.self) { d in
                                    Button("\(d)") { birthDay = d }
                                }
                            } label: {
                                underlineMenuLabel(dayLabel)
                            }
                            .buttonStyle(.plain)
                            .environment(\.layoutDirection, .rightToLeft)
                        }
                        .environment(\.layoutDirection, .rightToLeft)

                        if let err = sendError {
                            Text(err)
                                .font(.menuRegular(14).weight(.semibold))
                                .foregroundColor(.red.opacity(0.9))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 28)
                    .environment(\.layoutDirection, .rightToLeft)
                    .padding(.top, 8)

                    Button {
                        marketingOptIn.toggle()
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: marketingOptIn ? "checkmark.square.fill" : "square")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(accent)

                            Text("מאשר/ת לקבל עדכונים והטבות מ-\(shopName) במייל")
                                .font(.menuRegular(13).weight(.semibold))
                                .foregroundColor(accent.opacity(0.85))
                                .fixedSize(horizontal: false, vertical: true)

                            Spacer()
                        }
                    }
                    .padding(20)
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .padding(.top, 2)

                    // ✅ this is the key: when keyboard appears, add extra bottom padding so fields can scroll above CTA
                    Spacer().frame(height: (keyboardHeight > 0) ? (keyboardHeight + 40) : 120)
                }
            }
            .scrollIndicators(.hidden)
            .animation(.easeOut(duration: 0.25), value: keyboardHeight)
        }

        // ✅ fixed CTA pinned to bottom
        .safeAreaInset(edge: .bottom) {
            VStack {
                Button {
                    guard !isSending else { return }
                    isSending = true
                    sendError = nil

                    persistMemberJoin()
                    dismiss()

                    identifyMemberByEmail { ok, msg in
                        DispatchQueue.main.async {
                            if !ok {
                            }
                        }
                    }
                } label: {
                    ZStack {
                        Text(ctaText)
                            .font(.menuRegular(18).weight(.semibold))
                            .foregroundColor(.white)
                            .opacity(isSending ? 0 : 1)

                        if isSending {
                            ProgressView().tint(.white)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(
                        canContinue && !isSending
                        ? MenuTheme.buttonBackground
                        : Color(.systemGray4)                
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .disabled(!canContinue || isSending)
                .padding(.horizontal, 24)
                .padding(.top, 10)
                .padding(.bottom, 16)
            }
            .background(.clear)
        }
        .environment(\.layoutDirection, .rightToLeft)
        .environment(\.locale, Locale(identifier: "he_IL"))
        .interactiveDismissDisabled(false)
        .onAppear {
            focusedField = nil   // ✅ no auto focus

            // ✅ keyboard observers (push scroll content above CTA)
            NotificationCenter.default.addObserver(
                forName: UIResponder.keyboardWillChangeFrameNotification,
                object: nil,
                queue: .main
            ) { notif in
                guard let frame = notif.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
                let screenH = UIScreen.main.bounds.height
                let overlap = max(0, screenH - frame.minY)
                keyboardHeight = overlap
            }

            NotificationCenter.default.addObserver(
                forName: UIResponder.keyboardWillHideNotification,
                object: nil,
                queue: .main
            ) { _ in
                keyboardHeight = 0
            }
        }
        .onDisappear {
            NotificationCenter.default.removeObserver(self)
        }
    }

    private func underlineMenuLabel(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(text)
                    .font(.menuRegular(16).weight(.semibold))
                    .foregroundColor(accent)
                Spacer()
            }
            Rectangle()
                .fill(underline)
                .frame(height: 1)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Local persist
    private func persistMemberJoin() {
        guard let bm = birthMonth, let bd = birthDay else { return }

        let mm = String(format: "%02d", bm)
        let dd = String(format: "%02d", bd)
        let birthdayMMDD = "\(mm)-\(dd)"

        let anon = UserDefaults.standard.string(forKey: "anonUUID") ?? UUID().uuidString
        UserDefaults.standard.set(anon, forKey: "anonUUID")
        UserDefaults.standard.set(nameClean, forKey: "userName")
        UserDefaults.standard.set(emailClean, forKey: "userEmail")

        let stamps = max(1, min(10, stampEarnedNow))

        var profile: [String: Any] = [
            "miniAppId": miniAppId,
            "campaignId": campaignId,
            "name": nameClean,
            "email": emailClean,
            "birthdayMMDD": birthdayMMDD,
            "birthMonth": bm,
            "birthDay": bd,
            "anonId": anon,
            "createdAt": Date().timeIntervalSince1970,
            "wallet": [
                "stamps": stamps,
                "redeems": 0,
                "birthdayVoucherRedeemedYear": 0
            ],
            "stamps": stamps,
            "marketingOptIn": marketingOptIn
        ]

        if marketingOptIn {
            profile["marketingConsentAt"] = Int(Date().timeIntervalSince1970)
            profile["marketingConsentSource"] = "members_join_ios"
        }

        UserDefaults.standard.set(profile, forKey: "memberProfileLocal")
        UserDefaults.standard.set(profile, forKey: "pendingMemberJoin")
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "members.updatedAt")
    }

    // MARK: - Server call
    private func identifyMemberByEmail(completion: @escaping (Bool, String?) -> Void) {
        guard let bm = birthMonth, let bd = birthDay else { return }

        let mm = String(format: "%02d", bm)
        let dd = String(format: "%02d", bd)
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

        var payload: [String: Any] = [
            "miniAppId": miniAppId,
            "campaign": campaignId,
            "stampEarnedNow": stampEarnedNow,
            "anonId": anon,
            "platform": "ios",
            "appVariant": appVariant,
            "email": emailClean,
            "name": nameClean,
            "birthdayMMDD": birthdayMMDD,
            "birthMonth": bm,
            "birthDay": bd
        ]

        payload["marketingOptIn"] = marketingOptIn
        if marketingOptIn {
            payload["marketingConsentAt"] = Int(Date().timeIntervalSince1970)
            payload["marketingConsentSource"] = "members_join_ios"
        }

        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err = err { completion(false, err.localizedDescription); return }
            guard let http = resp as? HTTPURLResponse else { completion(false, "No response"); return }

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

    // ✅ NEW: explicit colors
    var textColor: UIColor
    var underlineColor: Color
    var placeholderColor: UIColor

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
                onReturn: onReturn,
                textColor: textColor,
                placeholderColor: placeholderColor
            )
            .frame(height: 30)

            Rectangle()
                .fill(underlineColor)
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

    // ✅ NEW
    let textColor: UIColor
    let placeholderColor: UIColor

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

        tf.semanticContentAttribute = .forceRightToLeft
        tf.textAlignment = .right

        tf.keyboardType = keyboard
        tf.returnKeyType = returnKey
        tf.textContentType = textContentType
        tf.autocapitalizationType = autocap
        tf.autocorrectionType = .no
        tf.spellCheckingType = .no
        tf.clearButtonMode = .whileEditing

        // ✅ force colors (works in dark mode too)
        tf.textColor = textColor
        tf.tintColor = textColor // cursor

        tf.attributedPlaceholder = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: placeholderColor]
        )

        tf.font = UIFont(name: fontName, size: fontSize)
            ?? UIFont.systemFont(ofSize: fontSize, weight: .semibold)

        tf.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        return tf
    }

    func updateUIView(_ tf: UITextField, context: Context) {
        if tf.text != text { tf.text = text }

        tf.semanticContentAttribute = .forceRightToLeft
        tf.textAlignment = .right

        // ✅ keep colors stable
        tf.textColor = textColor
        tf.tintColor = textColor
        tf.attributedPlaceholder = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: placeholderColor]
        )

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
                .font(.menuRegular(16).weight(.regular))
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
import SwiftUI
import UIKit
import StoreKit

struct AppStoreSheet: UIViewControllerRepresentable {
    let appId: Int
    @Binding var isPresented: Bool

    func makeCoordinator() -> Coordinator { Coordinator(isPresented: $isPresented) }

    func makeUIViewController(context: Context) -> SKStoreProductViewController {
        let vc = SKStoreProductViewController()
        vc.delegate = context.coordinator

        let params: [String: Any] = [
            SKStoreProductParameterITunesItemIdentifier: NSNumber(value: appId)
        ]

        vc.loadProduct(withParameters: params) { loaded, error in
            if let error = error {
            } else {
            }
        }

        return vc
    }

    func updateUIViewController(_ uiViewController: SKStoreProductViewController, context: Context) {}

    final class Coordinator: NSObject, SKStoreProductViewControllerDelegate {
        private var isPresented: Binding<Bool>

        init(isPresented: Binding<Bool>) {
            self.isPresented = isPresented
        }

        func productViewControllerDidFinish(_ viewController: SKStoreProductViewController) {
            // ✅ close SwiftUI sheet
            isPresented.wrappedValue = false
        }
    }
}

import UIKit
import StoreKit

@MainActor
final class StoreProductPresenter: NSObject, SKStoreProductViewControllerDelegate {

    static let shared = StoreProductPresenter()

    private var isPresenting = false

    func present(appId: Int) {
        guard !isPresenting else { return }
        guard let top = Self.topMostViewController() else {
            return
        }

        isPresenting = true

        let storeVC = SKStoreProductViewController()
        storeVC.delegate = self
        storeVC.modalPresentationStyle = .pageSheet

        let params: [String: Any] = [
            SKStoreProductParameterITunesItemIdentifier: NSNumber(value: appId)
        ]

        storeVC.loadProduct(withParameters: params) { loaded, error in
            if let error = error {
            } else {
            }
        }

        top.present(storeVC, animated: true)
    }

    func productViewControllerDidFinish(_ viewController: SKStoreProductViewController) {
        viewController.dismiss(animated: true) { [weak self] in
            self?.isPresenting = false
        }
    }

    private static func topMostViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }

        guard let scene = scenes.first else { return nil }

        let keyWindow = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first
        guard var top = keyWindow?.rootViewController else { return nil }

        while let presented = top.presentedViewController {
            top = presented
        }

        if let nav = top as? UINavigationController {
            return nav.visibleViewController ?? nav
        }
        if let tab = top as? UITabBarController {
            return tab.selectedViewController ?? tab
        }

        return top
    }
}

import SwiftUI
import StoreKit

struct LoyaltyInstallView: View {
    let earnedStamps: Int
    @State private var showOverlay = false

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: 18) {

                // HERO IMAGE
                Image("loyalty-coffee")
                    .resizable()
                    .scaledToFill()
                    .frame(height: 260)
                    .clipped()
                    .clipShape(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                    )
                    .padding(.top, 8)

                // CONTENT CARD
                VStack(spacing: 14) {

                    // TITLE
                    Text("החברים של בית העם")
                        .font(.menuRegular(17).weight(.semibold))
                        .foregroundStyle(.primary)

                    // VALUE
                    Text("כל קפה עשירי עלינו")
                        .font(.menuRegular(30).weight(.semibold))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.primary)

                    // STAMPS ROW
                  

                    // STATUS TEXT
                    Text("הרווחת \(earnedStamps) חותמות")
                        .font(.menuRegular(20).weight(.semibold))
                        .foregroundStyle(.secondary)

                    
                    HStack(spacing: 10) {
                        ForEach(0..<earnedStamps, id: \.self) { _ in
                            Image(systemName: "cup.and.saucer.fill")
                                .font(.menuRegular(22).weight(.semibold))
                        }
                    }
                    .padding(.top, 2)
                    // CTA
                    Button {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            StoreProductPresenter.shared.present(appId: 6737725110)
                        }
                    } label: {
                        Text("שמירה בכרטיסייה")
                            .font(.menuRegular(18).weight(.semibold))
                            .foregroundColor(.black)                 // ✅ always black
                            .frame(maxWidth: .infinity, minHeight: 56)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(Color(hex: "#D2C1A5"))     // ✅ your beige (or any)
                            )
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 6)
                  
                
                }
                .padding(.vertical, 20)
                .padding(.horizontal, 18)
                .background(.regularMaterial)
                .clipShape(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(.quaternary, lineWidth: 1)
                )

                Spacer(minLength: 12)
            }
            .padding(.horizontal, 16)
        }
        .appStoreOverlay(isPresented: $showOverlay) {
            SKOverlay.AppClipConfiguration(position: .bottom)
        }
    }
}
import SwiftUI

struct NightClosedView: View {
    let shopName: String

    @AppStorage(AppSettings.Key.cashPointMode)
    private var cashPointMode: Bool = AppSettings.Defaults.cashPointMode

    // ✅ tell MenuView to dismiss back to HomeView
    @AppStorage("ui.dismissToHome") private var dismissToHome: Bool = false
    @Environment(\.dismiss) private var dismiss

    // Cute animation states
    @State private var moonFloat: Bool = false
    @State private var starsTwinkle: Bool = false
    @State private var cloudDrift: Bool = false

    private var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    // ✅ Jerusalem time from device, always
    private var tzIL: TimeZone { TimeZone(identifier: "Asia/Jerusalem") ?? .current }

    private var hourIL: Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tzIL
        return cal.component(.hour, from: Date())
    }

    private var minuteIL: Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tzIL
        return cal.component(.minute, from: Date())
    }

    private var isBetween8And5: Bool {
        // ✅ Your new enum
        ILHours.isOpenNowIL()   // 08:00–16:59
    }

    private var isBefore8: Bool {
        hourIL < 8
    }

    // ✅ Hebrew only
    private var titleText: String {
        // optional debug:
        // print("🕒 Jerusalem hour =", hourIL, "minute =", minuteIL, "| 8–17 =", isBetween8And5, "| before 8 =", isBefore8)

        if isBetween8And5 {
            return "הקופה פתוחה"
        } else {
            return "ערב טוב 🌙"
        }
    }

    // ✅ Hebrew only
    private var mainLine: String {
        if isBetween8And5 {
            return "הזמנות מתקבלות עכשיו רק דרך הקופה"
        }
        if isBefore8 {
            return "נפתח להזמנות ב־08:00"
        }
        return "נחזור מחר"
    }

    var body: some View {
        ZStack {
            // Night gradient
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.06, blue: 0.14),
                    Color(red: 0.07, green: 0.10, blue: 0.22),
                    Color(red: 0.10, green: 0.12, blue: 0.26)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            // Stars layer
            StarsField(twinkle: starsTwinkle)
                .opacity(0.95)
                .ignoresSafeArea()

            // Moon + clouds
            VStack(spacing: 0) {
                Spacer().frame(height: 70)

                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.92))
                        .frame(width: 110, height: 110)
                        .shadow(color: .white.opacity(0.10), radius: 30, y: 8)
                        .overlay(
                            Circle()
                                .fill(Color.black.opacity(0.08))
                                .frame(width: 18, height: 18)
                                .offset(x: -18, y: 10)
                        )
                        .overlay(
                            Circle()
                                .fill(Color.black.opacity(0.06))
                                .frame(width: 12, height: 12)
                                .offset(x: 24, y: -8)
                        )
                        .offset(y: moonFloat ? -10 : 10)
                        .animation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true), value: moonFloat)

                    Circle()
                        .stroke(Color.white.opacity(0.12), lineWidth: 2)
                        .frame(width: 160, height: 160)
                        .blur(radius: 0.5)

                    CloudRow()
                        .opacity(0.22)
                        .offset(x: cloudDrift ? 120 : -140, y: 60)
                        .animation(.linear(duration: 14).repeatForever(autoreverses: false), value: cloudDrift)
                }

                Spacer()
            }

            // ✅ CENTERED TEXT
            VStack(spacing: 14) {
                Text(titleText)
                    .font(.menuRegular(36).weight(.heavy))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)

                Text(mainLine)
                    .font(.menuRegular(19).weight(.semibold))
                    .foregroundColor(.white.opacity(0.92))
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)

                Text(shopName)
                    .font(.menuRegular(14).weight(.semibold))
                    .foregroundColor(.white.opacity(0.55))
                    .padding(.top, 8)
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 22)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
            )
            .padding(.horizontal, 18)
            .onLongPressGesture(minimumDuration: 1.2) {
                if UIDevice.current.userInterfaceIdiom == .pad {
                    cashPointMode = true
                }
            }

            // ✅ TOP CLOSE BUTTON (iPhone full app only)
            #if !APPCLIP
            if isPhone {
                VStack {
                    HStack {
                        Button {
                            // 1) close Night screen
                            dismiss()

                            // 2) tell menuView to dismiss back to HomeView
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                                dismissToHome = true
                            }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.white)
                                .frame(width: 36, height: 36)
                                .background(Color.white.opacity(0.14))
                                .clipShape(Circle())
                                .overlay(
                                    Circle().stroke(Color.white.opacity(0.18), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)

                        Spacer()
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 14)

                    Spacer()
                }
            }
            #endif
        }
        .onAppear {
            moonFloat = true
            starsTwinkle = true
            cloudDrift = true
        }
        .preferredColorScheme(.dark)
        .environment(\.layoutDirection, .rightToLeft)
        .environment(\.locale, Locale(identifier: "he_IL"))
    }

    // MARK: - Stars background

    private struct StarsField: View {
        let twinkle: Bool

        private let stars: [(x: CGFloat, y: CGFloat, size: CGFloat, alpha: Double)] = {
            var result: [(CGFloat, CGFloat, CGFloat, Double)] = []
            var i = 0
            for y in stride(from: 0.05, through: 0.9, by: 0.12) {
                for x in stride(from: 0.05, through: 0.95, by: 0.12) {
                    if i % 3 == 0 {
                        result.append(
                            (x, y, i % 5 == 0 ? 2.4 : 1.6, i % 7 == 0 ? 0.9 : 0.6)
                        )
                    }
                    i += 1
                }
            }
            return result
        }()

        var body: some View {
            GeometryReader { geo in
                ZStack {
                    ForEach(0..<stars.count, id: \.self) { i in
                        let s = stars[i]
                        Circle()
                            .fill(Color.white)
                            .frame(width: s.size, height: s.size)
                            .position(x: s.x * geo.size.width, y: s.y * geo.size.height)
                            .opacity(twinkle ? s.alpha : s.alpha * 0.7)
                            .animation(
                                .easeInOut(duration: 1.2 + Double(i % 6) * 0.25)
                                    .repeatForever(autoreverses: true),
                                value: twinkle
                            )
                    }
                }
            }
        }
    }

    // MARK: - Soft drifting clouds

    private struct CloudRow: View {
        var body: some View {
            HStack(spacing: 22) {
                cloud
                cloud.opacity(0.85).scaleEffect(0.85)
                cloud.opacity(0.7).scaleEffect(0.7)
            }
        }

        private var cloud: some View {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white)
                    .frame(width: 120, height: 34)

                Circle()
                    .fill(Color.white)
                    .frame(width: 46, height: 46)
                    .offset(x: -36, y: -8)

                Circle()
                    .fill(Color.white)
                    .frame(width: 56, height: 56)
                    .offset(x: 4, y: -18)

                Circle()
                    .fill(Color.white)
                    .frame(width: 42, height: 42)
                    .offset(x: 40, y: -8)
            }
            .blur(radius: 0.4)
        }
    }
}
