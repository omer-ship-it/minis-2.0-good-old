import SwiftUI

// MARK: - Admins & Devices (Owner / Grand Manager)

struct AdminsDevicesView: View {
    let miniAppId: Int
    let canRevoke: Bool
    let onClose: () -> Void

    @Environment(\.isRtl) private var isRtl

    @State private var role: String = "admin"          // admin / manager / kds / cashier
    @State private var displayName: String = ""
    @State private var email: String = ""
    
    @State private var inviteToken: String? = nil
    @State private var expiresAt: String? = nil

    @State private var busy = false
    @State private var errorText: String? = nil

    private let roles: [(title: String, value: String)] = [
        ("אדמין", "admin"),
        ("מנהל", "manager"),
        ("קופה", "cashier"),
        ("KDS", "kds")
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 14) {

                        // Header card
                        VStack(alignment: .leading, spacing: 8) {
                            Text(isRtl ? "ניהול מנהלים ומכשירים" : "Admins & Devices")
                                .font(.system(size: 22, weight: .bold))

                            Text("miniAppId: \(miniAppId)")
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .padding(.top, 12)

                        // Create invite form
                        VStack(spacing: 10) {

                            // Role picker
                            HStack {
                                Text(isRtl ? "תפקיד" : "Role")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.secondary)
                                Spacer()
                            }

                            HStack(spacing: 10) {
                                ForEach(roles, id: \.value) { r in
                                    Button {
                                        role = r.value
                                        Haptics.light()
                                    } label: {
                                        Text(r.title)
                                            .font(.system(size: 14, weight: .bold))
                                            .foregroundColor(role == r.value ? .white : .primary)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 8)
                                            .background(role == r.value ? Color.black : Color(.systemGray5))
                                            .clipShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            // Device/Admin name
                            VStack(alignment: .leading, spacing: 6) {
                                Text(isRtl ? "שם" : "Name")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.secondary)

                                TextField(isRtl ? "לדוגמה: קופה 1 / מטבח / אורי" : "e.g. Cashier 1 / Kitchen / Alex",
                                          text: $displayName)
                                .padding(12)
                                .background(Color(.systemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }

                            // Optional email
                            VStack(alignment: .leading, spacing: 6) {
                                Text(isRtl ? "אימייל (אופציונלי)" : "Email (optional)")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.secondary)

                                TextField("name@domain.com", text: $email)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .keyboardType(.emailAddress)
                                    .padding(12)
                                    .background(Color(.systemBackground))
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }

                            // TTL
                           
                            .padding(12)
                            .background(Color(.systemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                            if let err = errorText {
                                Text(err)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.red)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            Button {
                                Task { await createInvite() }
                            } label: {
                                HStack {
                                    if busy { ProgressView().scaleEffect(0.9) }
                                    Text(isRtl ? "צור QR" : "Generate QR")
                                        .font(.system(size: 18, weight: .bold))
                                }
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 52)
                                .background(busy ? Color.gray.opacity(0.35) : Color.black)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .disabled(busy)
                        }
                        .padding(14)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                        // QR section
                        if let token = inviteToken {
                            VStack(spacing: 10) {
                                Text(isRtl ? "סרוק כדי להתחבר" : "Scan to connect")
                                    .font(.system(size: 16, weight: .bold))

                                // QR content: include miniAppId for debugging/future
                                let payload = "https://minis.studio/\(miniAppId)/pair?token=\(token)"


                                DotQRView(text: payload, overlayLabel: "MINI", logoKnockoutFraction: 0.18)
                                    .frame(width: 280, height: 280)

                                if let exp = expiresAt {
                                    Text((isRtl ? "תוקף עד: " : "Expires: ") + exp)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(.secondary)
                                }

                                Button {
                                    UIPasteboard.general.string = payload
                                    Haptics.light()
                                } label: {
                                    Text(isRtl ? "העתק קישור" : "Copy link")
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundColor(.primary)
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 44)
                                        .background(Color(.systemGray5))
                                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(14)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }

                        // Placeholder for revoke list (later)
                        if canRevoke {
                            Text(isRtl ? "בקרוב: רשימת מנהלים + ביטול" : "Soon: list admins + revoke")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 6)
                        }

                        Spacer(minLength: 40)
                    }
                    .padding(.horizontal, 16)
                }
            }
            .navigationTitle(isRtl ? "מנהלים" : "Admins")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        onClose()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .bold))
                            .padding(8)
                            .background(Color(.systemGray5))
                            .clipShape(Circle())
                    }
                }
            }
        }
        .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
    }

    // MARK: - API call: create invite

    private func createInvite() async {
        errorText = nil
        inviteToken = nil
        expiresAt = nil

        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.count >= 2 else {
            errorText = isRtl ? "חייבים שם" : "Name required"
            return
        }

        busy = true
        defer { busy = false }

        let base = UserDefaults.standard.string(forKey: "apiBase") ?? "https://minis.studio"
        guard let url = URL(string: "\(base)/api/admin/invites/create") else {
            errorText = "bad url"
            return
        }

        // ✅ TEMP principal id (until you wire Keychain principal)
        let principalId = UserDefaults.standard.string(forKey: "admin.principalId") ?? "device:dev"

        struct Req: Encodable {
            let miniAppId: Int
            let role: String
            let displayName: String
            let email: String?
        }

        let payload = Req(
            miniAppId: miniAppId,
            role: role,
            displayName: name,
            email: email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : email.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        req.setValue(principalId, forHTTPHeaderField: "X-Principal-Id")
        req.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-Id")
        req.httpBody = try? JSONEncoder().encode(payload)

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let text = String(data: data, encoding: .utf8) ?? ""

            if !(200...299).contains(code) {
                errorText = "HTTP \(code): \(String(text.prefix(200)))"
                return
            }

            // Expect: { ok:true, inviteToken:"...", expiresAtUtc:"..." }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let tok = json["inviteToken"] as? String {
                    inviteToken = tok
                } else if let g = json["inviteToken"] as? NSUUID {
                    inviteToken = g.uuidString
                }

                if let exp = json["expiresAtUtc"] as? String {
                    expiresAt = exp
                }
            }

            if inviteToken == nil {
                errorText = "bad response: \(String(text.prefix(200)))"
            } else {
                Haptics.success()
            }

        } catch {
            errorText = error.localizedDescription
        }
    }
}
