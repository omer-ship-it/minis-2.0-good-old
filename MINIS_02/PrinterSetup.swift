import SwiftUI
import Network

// MARK: - Models

enum PrinterSet: String, Codable, CaseIterable, Identifiable {
    case tabit, ron
    var id: String { rawValue }

    var title: String {
        switch self {
        case .tabit: return "Standard"
        case .ron:   return "Rongta (older)"
        }
    }
}

struct PrinterStation: Codable, Identifiable, Equatable {
    var id: String              // stable routing id used by products, e.g. "s1"
    var label: String           // human name, e.g. "מטבח"
    var octet: Int              // 1..244
    var set: PrinterSet         // tabit/ron
    var status: Int             // 1 active, 0 disabled

    init(id: String, label: String, octet: Int, set: PrinterSet, status: Int = 1) {
        self.id = id
        self.label = label
        self.octet = octet
        self.set = set
        self.status = status
    }
}

struct PrintersConfig: Codable, Equatable {
    var netPrefix: String               // "10.100.10."
    var stations: [PrinterStation]      // active config
    var backup: [PrinterStation]        // last snapshot for Undo
    var updatedAtUtc: String?

    static func `default`(prefix: String = "10.100.10.") -> PrintersConfig {
        PrintersConfig(
            netPrefix: prefix,
            stations: [
                .init(id: "s1", label: "מטבח",   octet: 232, set: .tabit),
                .init(id: "s2", label: "בר",     octet: 234, set: .tabit),
                .init(id: "s3", label: "וטרינה", octet: 230, set: .tabit),
            ],
            backup: [],
            updatedAtUtc: nil
        )
    }
}

// MARK: - Store (UserDefaults)

@MainActor
final class PrintersConfigStore: ObservableObject {
    static let shared = PrintersConfigStore()

    private init() {
        self.config = Self.load() ?? .default()
    }

    @Published var config: PrintersConfig

    private static let kConfig = "admin.printers.config.v1"

    static func load() -> PrintersConfig? {
        guard let data = UserDefaults.standard.data(forKey: kConfig) else { return nil }
        return try? JSONDecoder().decode(PrintersConfig.self, from: data)
    }

    func save(_ newConfig: PrintersConfig) {
        config = newConfig
        if let data = try? JSONEncoder().encode(newConfig) {
            UserDefaults.standard.set(data, forKey: Self.kConfig)
        }
    }

    func saveWithBackup(_ newStations: [PrinterStation], netPrefix: String) {
        var next = config

        // backup = previous stations (not huge, just one snapshot)
        next.backup = next.stations

        next.netPrefix = netPrefix
        next.stations = newStations
        next.updatedAtUtc = ISO8601DateFormatter().string(from: Date())

        save(next)
    }

    func undo() {
        guard !config.backup.isEmpty else { return }
        var next = config
        let current = next.stations
        next.stations = next.backup
        next.backup = current
        next.updatedAtUtc = ISO8601DateFormatter().string(from: Date())
        save(next)
    }

    func fullHost(for stationId: String) -> String? {
        guard let st = config.stations.first(where: { $0.id == stationId && $0.status != 0 }) else { return nil }
        return config.netPrefix + String(st.octet)
    }
}

// MARK: - Helpers

private func clampOctet244(_ s: String) -> Int? {
    let digits = s.filter(\.isNumber)
    guard let n = Int(digits) else { return nil }
    guard (1...244).contains(n) else { return nil }
    return n
}

private func guessNetPrefixFromLANIP(_ ip: String) -> String? {
    // "10.100.10.55" -> "10.100.10."
    let parts = ip.split(separator: ".")
    guard parts.count == 4 else { return nil }
    return "\(parts[0]).\(parts[1]).\(parts[2])."
}

// MARK: - PIN Gate (minimal)

struct OwnerPinGateSheet: View {
    let title: String
    let correctPin: String
    let onUnlocked: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var pin: String = ""

    private var ok: Bool { pin == correctPin && !pin.isEmpty }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Text(title)
                    .font(.system(size: 20, weight: .bold))
                    .padding(.top, 12)

                SecureField("PIN", text: $pin)
                    .keyboardType(.numberPad)
                    .padding(12)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                Button {
                    guard ok else { return }
                    dismiss()
                    onUnlocked()
                } label: {
                    Text("Unlock")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(ok ? Color.black : Color.gray.opacity(0.35))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .disabled(!ok)

                Spacer()
            }
            .padding(16)
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
                }
            }
        }
    }
}

// MARK: - Setup Sheet


import SwiftUI
import Foundation

struct PrinterSetupSheet: View {
    let isRtl: Bool
    let detectedLANIP: String?
    let onClose: () -> Void

    // Shared runtime store (your app reads from this), but draft persistence is per miniAppId
    @ObservedObject private var store = PrintersConfigStore.shared

    // Draft
    @State private var netPrefixDraft: String = ""
    @State private var stationsDraft: [PrinterStation] = []

    // ✅ Free-text IP per station id (e.g. "192.168.68.232")
    @State private var stationIpDraft: [String: String] = [:]

    // UI
    @State private var showAddStation = false
    @State private var showPin = false
    @State private var unlocked = false
    @State private var toast: String? = nil

    // ✅ Sync UI
    @State private var isSyncing = false
    @State private var lastSyncError: String? = nil
    @State private var syncWorkItem: DispatchWorkItem? = nil

    // PIN
    private let ownerPin = (UserDefaults.standard.string(forKey: "owner.pin") ?? "1234")

    // ✅ Ask pin only once per miniAppId per app session
    private static var sessionUnlockedMiniIds: Set<Int> = []

    // MARK: - MiniAppId + Per-shop keys

    private func resolveMiniAppId() -> Int {
        let d = UserDefaults.standard
        let mini = d.integer(forKey: "miniAppId")
        if mini > 0 { return mini }
        if let s = d.string(forKey: "shopId"), let v = Int(s), v > 0 { return v }
        return 0
    }

    private var miniAppId: Int { resolveMiniAppId() }

    private var localConfigKey: String { "printers.config.\(miniAppId)" }
    private var localUndoKey: String { "printers.undo.\(miniAppId)" }

    private struct LocalPrintersConfig: Codable {
        var netPrefix: String
        var stations: [PrinterStation]
        var backup: [PrinterStation]  // one-step undo snapshot
    }

    private func loadLocalConfig() -> LocalPrintersConfig? {
        guard miniAppId > 0 else { return nil }
        guard let data = UserDefaults.standard.data(forKey: localConfigKey) else { return nil }
        return try? JSONDecoder().decode(LocalPrintersConfig.self, from: data)
    }

    private func saveLocalConfig(_ cfg: LocalPrintersConfig) {
        guard miniAppId > 0 else { return }
        guard let data = try? JSONEncoder().encode(cfg) else { return }
        UserDefaults.standard.set(data, forKey: localConfigKey)
    }

    private func saveUndoSnapshot() {
        guard miniAppId > 0 else { return }
        let snap = LocalPrintersConfig(netPrefix: netPrefixDraft, stations: stationsDraft, backup: [])
        if let data = try? JSONEncoder().encode(snap) {
            UserDefaults.standard.set(data, forKey: localUndoKey)
        }
    }

    private func loadUndoSnapshot() -> LocalPrintersConfig? {
        guard miniAppId > 0 else { return nil }
        guard let data = UserDefaults.standard.data(forKey: localUndoKey) else { return nil }
        return try? JSONDecoder().decode(LocalPrintersConfig.self, from: data)
    }

    // MARK: - Helpers

    private var activeStations: [PrinterStation] {
        stationsDraft.filter { $0.status != 0 }
    }

    private func guessNetPrefixFromLANIP(_ ip: String) -> String? {
        // e.g. "10.100.10.232" -> "10.100.10."
        let parts = ip.split(separator: ".").map(String.init)
        guard parts.count == 4 else { return nil }
        return parts[0] + "." + parts[1] + "." + parts[2] + "."
    }

    /// ✅ Only used for validation/payload normalization (NOT while typing)
    private func ensureTrailingDot(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "" }
        return t.hasSuffix(".") ? t : (t + ".")
    }

    private func buildIpMapFromDraft() {
        // Build stationIpDraft from netPrefixDraft + octet when missing
        var map: [String: String] = stationIpDraft

        for s in stationsDraft {
            let existing = (map[s.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if existing.isEmpty {
                map[s.id] = ensureTrailingDot(netPrefixDraft) + String(s.octet)
            }
        }
        stationIpDraft = map
    }

    private func applyDetectedPrefixIfNeeded() {
        // ✅ do NOT auto-append dots while typing; only set a default if empty
        if netPrefixDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let ip = detectedLANIP, let p = guessNetPrefixFromLANIP(ip) {
                netPrefixDraft = p
            } else {
                netPrefixDraft = store.config.netPrefix
            }
        }
    }

    private func resetDraftFromStoreOrLocal() {
        // Prefer per-shop local config if exists
        if let local = loadLocalConfig() {
            netPrefixDraft = local.netPrefix
            stationsDraft = local.stations
        } else {
            netPrefixDraft = store.config.netPrefix
            stationsDraft = store.config.stations
        }
        buildIpMapFromDraft()
    }

    // MARK: - Validation + Local Save (per miniAppId)

    private func parseIp(_ raw: String) -> (prefix: String, octet: Int)? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        // Accept "10.100.10.232" or "10.100.10.232:9100" (ignore port)
        let host = s.split(separator: ":").first.map(String.init) ?? s

        let parts = host.split(separator: ".").map(String.init)
        guard parts.count == 4 else { return nil }

        guard let a = Int(parts[0]), let b = Int(parts[1]), let c = Int(parts[2]), let d = Int(parts[3]) else { return nil }
        guard (0...255).contains(a), (0...255).contains(b), (0...255).contains(c), (1...254).contains(d) else { return nil }

        let prefix = "\(a).\(b).\(c)."
        return (prefix, d)
    }

    private func validateDraftAndNormalizeIntoModel() -> String? {
        // ids unique
        let ids = stationsDraft.map(\.id)
        if Set(ids).count != ids.count { return "Duplicate station id" }

        // prefix not empty
        let p = ensureTrailingDot(netPrefixDraft)
        if p.isEmpty { return "Missing network prefix" }

        // each active station must have valid IP and match prefix
        for i in stationsDraft.indices {
            var st = stationsDraft[i]
            guard st.status != 0 else { continue }

            let id = st.id.trimmingCharacters(in: .whitespacesAndNewlines)
            if id.isEmpty { return "Missing id" }

            let ipText = (stationIpDraft[st.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parsed = parseIp(ipText) else {
                return "Bad IP for \(st.label)"
            }

            if parsed.prefix != p {
                return "IP must start with \(p) (\(st.label))"
            }

            // normalize octet into existing model (payload uses prefix+octet)
            st.octet = parsed.octet
            stationsDraft[i] = st
        }

        // ✅ normalize once at save time (not while typing)
        netPrefixDraft = p
        return nil
    }

    private func saveDraftLocalOnly(showToast: Bool) {
        if let err = validateDraftAndNormalizeIntoModel() {
            toast = err
            return
        }

        // save per-shop locally
        saveLocalConfig(LocalPrintersConfig(netPrefix: netPrefixDraft, stations: stationsDraft, backup: []))

        // update runtime store (your app reads from this)
        store.saveWithBackup(stationsDraft, netPrefix: netPrefixDraft)

        if showToast { toast = "Saved" }
    }

    private func undoLocal() {
        guard let snap = loadUndoSnapshot() else {
            toast = "Nothing to undo"
            return
        }

        netPrefixDraft = snap.netPrefix
        stationsDraft = snap.stations
        buildIpMapFromDraft()

        // persist + runtime
        saveDraftLocalOnly(showToast: false)
        toast = "Undone"
        scheduleSync(updatedBy: "ios-undo")
    }

    // MARK: - Server sync

    private struct PrintersUpsertReq: Encodable {
        let miniAppId: Int
        let updatedBy: String
        let printers: ShopPrintersPayload
    }

    private struct PrintersUpsertResp: Decodable {
        let ok: Bool
        let miniAppId: Int?
        let printers: ShopPrintersPayload?
        let error: String?
    }

    private func currentPrintersPayload() -> ShopPrintersPayload {
        ShopPrintersPayload(
            netPrefix: netPrefixDraft,
            stations: stationsDraft.map { $0.toPayload() },          // includes "set"
            backup: store.config.backup.map { $0.toPayload() }
        )
    }

    private func syncNow(updatedBy: String) {
        guard miniAppId > 0 else {
            toast = "Missing miniAppId/shopId"
            return
        }

        if let err = validateDraftAndNormalizeIntoModel() {
            toast = err
            return
        }

        let base = UserDefaults.standard.string(forKey: "apiBase") ?? "https://minis.studio"
        guard let url = URL(string: "\(base)/api/admin/printers/upsert") else {
            toast = "Bad URL"
            return
        }

        let payload = PrintersUpsertReq(
            miniAppId: miniAppId,
            updatedBy: updatedBy,
            printers: currentPrintersPayload()
        )

        // save undo snapshot before commit
        saveUndoSnapshot()

        // local save first (UI stays consistent even if network fails)
        saveDraftLocalOnly(showToast: false)

        isSyncing = true
        lastSyncError = nil

        Task {
            do {
                var req = URLRequest(url: url, timeoutInterval: 20)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.setValue("application/json", forHTTPHeaderField: "Accept")
                req.httpBody = try JSONEncoder().encode(payload)

                // debug curl
                if let body = req.httpBody, let s = String(data: body, encoding: .utf8) {
                    print("""
                    🖨️ PRINTERS UPSERT cURL:
                    curl -i -X POST "\(url.absoluteString)" \\
                      -H "Content-Type: application/json" \\
                      -H "Accept: application/json" \\
                      -d '\(s)'
                    """)
                }

                let (data, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                let raw = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
                print("🌍 printers/upsert HTTP \(code)")
                print("📦 printers/upsert RAW (first 600): \(String(raw.prefix(600)))")

                guard (200..<300).contains(code) else {
                    throw NSError(domain: "http", code: code, userInfo: [NSLocalizedDescriptionKey: raw])
                }

                let decoded = try JSONDecoder().decode(PrintersUpsertResp.self, from: data)
                guard decoded.ok else {
                    throw NSError(domain: "api", code: -2, userInfo: [NSLocalizedDescriptionKey: decoded.error ?? "Unknown API error"])
                }

                await MainActor.run {
                    isSyncing = false
                    lastSyncError = nil

                    if let saved = decoded.printers {
                        let stations: [PrinterStation] = (saved.stations ?? []).map { $0.toStation() }
                        let net = ensureTrailingDot(saved.netPrefix ?? netPrefixDraft)

                        // persist per-shop
                        saveLocalConfig(LocalPrintersConfig(netPrefix: net, stations: stations, backup: []))

                        // update runtime store
                        store.saveWithBackup(stations, netPrefix: net)

                        // refresh draft
                        netPrefixDraft = net
                        stationsDraft = stations
                        buildIpMapFromDraft()
                    }

                    toast = "Synced"
                }
            } catch {
                await MainActor.run {
                    isSyncing = false
                    lastSyncError = error.localizedDescription
                    toast = "Sync failed"
                    print("❌ printers sync failed:", error.localizedDescription)
                }
            }
        }
    }

    private func scheduleSync(updatedBy: String) {
        syncWorkItem?.cancel()

        let work = DispatchWorkItem {
            guard unlocked else { return }
            self.syncNow(updatedBy: updatedBy)
        }

        syncWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    // MARK: - UI helpers

    private func stationIpBinding(_ stationId: String) -> Binding<String> {
        Binding(
            get: { stationIpDraft[stationId] ?? "" },
            set: { stationIpDraft[stationId] = $0 }
        )
    }

    private func ensureUnlockedOrPrompt() {
        if !unlocked { showPin = true }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()

                VStack(spacing: 12) {

                    // Header
                    HStack(spacing: 10) {
                        Text(isRtl ? "מדפסות" : "Printers")
                            .font(.system(size: 20, weight: .bold))

                        Spacer()

                        if isSyncing {
                            ProgressView().scaleEffect(0.9)
                        } else if lastSyncError != nil {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.red)
                        }

                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .font(.system(size: 16, weight: .bold))
                                .padding(8)
                                .background(Color(.systemGray5))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)

                    if let err = lastSyncError, !err.isEmpty {
                        Text((isRtl ? "שגיאת סנכרון: " : "Sync error: ") + err)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.red)
                            .padding(.horizontal, 16)
                            .lineLimit(2)
                    }

                    // Network prefix
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(isRtl ? "רשת" : "Network")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.secondary)
                            Spacer()
                            if let ip = detectedLANIP {
                                Text(ip)
                                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }

                        TextField(isRtl ? "למשל 10.100.10." : "e.g. 10.100.10.", text: $netPrefixDraft)
                            .textInputAutocapitalization(.none)
                            .autocorrectionDisabled()
                            .font(.system(size: 16, weight: .semibold, design: .monospaced))
                            .padding(12)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .onTapGesture { ensureUnlockedOrPrompt() }
                            .disabled(!unlocked)
                            .opacity(unlocked ? 1.0 : 0.55)

                        Text(isRtl ? "טיפ: לשמור נקודה בסוף" : "Tip: keep a trailing dot (.)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 16)

                    // Stations list
                    ScrollView {
                        VStack(spacing: 10) {

                            ForEach(stationsDraft.indices, id: \.self) { idx in
                                let st = stationsDraft[idx]

                                VStack(alignment: .leading, spacing: 10) {

                                    HStack {
                                        Text(st.label)
                                            .font(.system(size: 16, weight: .bold))

                                        Spacer()

                                        Toggle("", isOn: Binding(
                                            get: { stationsDraft[idx].status != 0 },
                                            set: { newVal in
                                                ensureUnlockedOrPrompt()
                                                guard unlocked else { return }
                                                var x = stationsDraft[idx]
                                                x.status = newVal ? 1 : 0
                                                stationsDraft[idx] = x
                                            }
                                        ))
                                        .labelsHidden()
                                        .tint(.blue) // ✅ BLUE
                                    }

                                    // IP
                                    HStack(spacing: 10) {
                                        Text(isRtl ? "כתובת IP" : "IP")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundColor(.secondary)

                                        TextField("10.100.10.232", text: stationIpBinding(st.id))
                                            .textInputAutocapitalization(.none)
                                            .autocorrectionDisabled()
                                            .font(.system(size: 15, weight: .semibold, design: .monospaced))
                                            .padding(10)
                                            .background(Color(.secondarySystemBackground))
                                            .clipShape(RoundedRectangle(cornerRadius: 12))
                                            .onTapGesture { ensureUnlockedOrPrompt() }
                                            .disabled(!unlocked)
                                            .opacity(unlocked ? 1.0 : 0.55)
                                    }

                                    // Routing ID
                                    HStack(spacing: 10) {
                                        Text("ID")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundColor(.secondary)

                                        TextField("s1", text: Binding(
                                            get: { stationsDraft[idx].id },
                                            set: { newVal in
                                                ensureUnlockedOrPrompt()
                                                guard unlocked else { return }
                                                var x = stationsDraft[idx]
                                                x.id = newVal
                                                stationsDraft[idx] = x

                                                // keep ip map key stable if user changes id
                                                // NOTE: best-effort (won't lose the text)
                                                if stationIpDraft[newVal] == nil, let old = stationIpDraft[st.id] {
                                                    stationIpDraft[newVal] = old
                                                    stationIpDraft.removeValue(forKey: st.id)
                                                }
                                            }
                                        ))
                                        .textInputAutocapitalization(.none)
                                        .autocorrectionDisabled()
                                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                                        .padding(10)
                                        .background(Color(.secondarySystemBackground))
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                        .disabled(!unlocked)
                                        .opacity(unlocked ? 1.0 : 0.55)
                                    }

                                    // ✅ Model: Tabit / Rongta
                                    HStack(spacing: 10) {
                                        Text(isRtl ? "דגם" : "Model")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundColor(.secondary)

                                        Spacer()

                                        Picker("", selection: Binding(
                                            get: { stationsDraft[idx].set },
                                            set: { newVal in
                                                ensureUnlockedOrPrompt()
                                                guard unlocked else { return }
                                                var x = stationsDraft[idx]
                                                x.set = newVal
                                                stationsDraft[idx] = x
                                            }
                                        )) {
                                            ForEach(PrinterSet.allCases) { p in
                                                Text(p.title).tag(p)
                                            }
                                        }
                                        .pickerStyle(.segmented)
                                        .disabled(!unlocked)
                                        .opacity(unlocked ? 1.0 : 0.55)
                                    }
                                }
                                .padding(14)
                                .background(Color(.systemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14)
                                        .stroke(Color.black.opacity(0.06), lineWidth: 1)
                                )
                            }

                            Button {
                                ensureUnlockedOrPrompt()
                                guard unlocked else { return }
                                showAddStation = true
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "plus.circle.fill")
                                    Text(isRtl ? "הוסף תחנה" : "Add station")
                                        .font(.system(size: 16, weight: .bold))
                                    Spacer()
                                }
                                .padding(14)
                                .background(Color(.secondarySystemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                            }
                            .buttonStyle(.plain)

                            Button {
                                ensureUnlockedOrPrompt()
                                guard unlocked else { return }
                                undoLocal()
                                Haptics.light()
                            } label: {
                                Text(isRtl ? "בטל שינוי אחרון" : "Undo last change")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundColor(.primary)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 48)
                                    .background(Color(.systemGray5))
                                    .clipShape(RoundedRectangle(cornerRadius: 14))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                    }

                    // Save / Sync
                    HStack(spacing: 12) {
                        Button {
                            ensureUnlockedOrPrompt()
                            guard unlocked else { return }
                            syncNow(updatedBy: "ios-save")
                            Haptics.light()
                        } label: {
                            Text(isSyncing ? (isRtl ? "שומר…" : "Saving…") : (isRtl ? "שמור" : "Save"))
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 52)
                                .background(isSyncing ? Color.black.opacity(0.6) : Color.black)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                        }
                        .buttonStyle(.plain)
                        .disabled(isSyncing)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
                }

                // Toast
                if let t = toast {
                    VStack {
                        Spacer()
                        Text(t)
                            .font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Color(.systemBackground))
                            .clipShape(Capsule())
                            .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 6)
                            .padding(.bottom, 20)
                    }
                    .transition(.opacity)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                            withAnimation { toast = nil }
                        }
                    }
                }
            }
            .onAppear {
                resetDraftFromStoreOrLocal()
                applyDetectedPrefixIfNeeded()
                buildIpMapFromDraft()

                // ask PIN only once per miniAppId per session
                if miniAppId > 0, Self.sessionUnlockedMiniIds.contains(miniAppId) {
                    unlocked = true
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        showPin = true
                    }
                }
            }
            // ✅ Auto-sync on changes (only after unlocked)
            .onChange(of: netPrefixDraft) { _ in
                guard unlocked else { return }
                saveDraftLocalOnly(showToast: false)
                scheduleSync(updatedBy: "ios-change-prefix")
            }
            .onChange(of: stationsDraft) { _ in
                guard unlocked else { return }
                saveDraftLocalOnly(showToast: false)
                scheduleSync(updatedBy: "ios-change-stations")
            }
            .onChange(of: stationIpDraft) { _ in
                guard unlocked else { return }
                saveDraftLocalOnly(showToast: false)
                scheduleSync(updatedBy: "ios-change-ip")
            }
            .sheet(isPresented: $showPin) {
                OwnerPinGateSheet(title: "Owner PIN", correctPin: ownerPin) {
                    unlocked = true
                    if miniAppId > 0 { Self.sessionUnlockedMiniIds.insert(miniAppId) }
                    toast = isRtl ? "נפתח" : "Unlocked"
                }
            }
            .sheet(isPresented: $showAddStation) {
                AddStationSheet(
                    netPrefix: netPrefixDraft,
                    onAdd: { newStation in
                        ensureUnlockedOrPrompt()
                        guard unlocked else { return }

                        stationsDraft.append(newStation)

                        // seed a default IP value for the new station
                        let p = ensureTrailingDot(netPrefixDraft)
                        stationIpDraft[newStation.id] = p.isEmpty ? "" : (p + String(newStation.octet))

                        showAddStation = false

                        saveDraftLocalOnly(showToast: false)
                        scheduleSync(updatedBy: "ios-add-station")
                    },
                    onCancel: { showAddStation = false }
                )
            }
        }
        .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
    }
}

// MARK: - Station Card

private struct StationCard: View {
    let isRtl: Bool
    let netPrefix: String
    let station: PrinterStation
    let onUpdate: (PrinterStation) -> Void
    let onDisable: () -> Void
    let onTest: () -> Void

    @State private var label: String = ""
    @State private var octetText: String = ""
    @State private var showAdvanced = false
    @State private var set: PrinterSet = .tabit
    @State private var status: Int = 1

    private var fullIP: String {
        let n = clampOctet244(octetText) ?? station.octet
        return netPrefix + String(n)
    }

    private func syncFromStation() {
        label = station.label
        octetText = String(station.octet)
        set = station.set
        status = station.status
    }

    private func pushUpdate() {
        let newOctet = clampOctet244(octetText) ?? station.octet
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        onUpdate(
            PrinterStation(
                id: station.id,
                label: trimmed.isEmpty ? station.label : trimmed,
                octet: newOctet,
                set: set,
                status: status
            )
        )
    }

    var body: some View {
        VStack(spacing: 10) {

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Name", text: $label)
                        .font(.system(size: 18, weight: .bold))
                        .onChange(of: label) { _ in pushUpdate() }

                    Text(fullIP)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button(action: onTest) {
                    Text("Test")
                        .font(.system(size: 13, weight: .bold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color(.systemGray5))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)

                Menu {
                    Button(showAdvanced ? "Hide advanced" : "Advanced") { showAdvanced.toggle() }
                    Button("Disable", role: .destructive) {
                        status = 0
                        pushUpdate()
                        onDisable()
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .bold))
                        .padding(10)
                        .background(Color(.systemGray5))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 10) {
                Text("IP")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.secondary)

                Text(netPrefix)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundColor(.secondary)

                TextField("1-244", text: $octetText)
                    .keyboardType(.numberPad)
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .frame(width: 70)
                    .padding(.vertical, 8)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .onChange(of: octetText) { _ in
                        // clamp softly
                        if let n = clampOctet244(octetText) {
                            octetText = String(n)
                        }
                        pushUpdate()
                    }

                Spacer()

                if status == 0 {
                    Text("Disabled")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(.systemGray6))
                        .clipShape(Capsule())
                }
            }

            if showAdvanced {
                HStack {
                    Text("Model")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.secondary)
                    Spacer()
                    Picker("", selection: $set) {
                        ForEach(PrinterSet.allCases) { p in
                            Text(p.title).tag(p)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: set) { _ in pushUpdate() }
                }
            }

            // show station id (routing key)
            HStack {
                Text("ID: \(station.id)")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .onAppear { syncFromStation() }
        .onChange(of: station) { _ in syncFromStation() }
        .opacity(station.status == 0 ? 0.45 : 1.0)
    }
}

// MARK: - Add Station

private struct AddStationSheet: View {
    let netPrefix: String
    let onAdd: (PrinterStation) -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var label: String = ""
    @State private var octetText: String = ""
    @State private var set: PrinterSet = .tabit

    private var canAdd: Bool {
        let lbl = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return !lbl.isEmpty && clampOctet244(octetText) != nil
    }

    private func nextId() -> String {
        // Very simple: s<timestamp last 5 digits>
        let n = Int(Date().timeIntervalSince1970) % 100000
        return "s\(n)"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("e.g. Kitchen", text: $label)
                }

                Section("IP") {
                    HStack {
                        Text(netPrefix).font(.system(.body, design: .monospaced))
                        TextField("1-244", text: $octetText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.center)
                    }
                    Text("Full: \(netPrefix)\(clampOctet244(octetText) ?? 0)")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                Section("Model") {
                    Picker("Model", selection: $set) {
                        ForEach(PrinterSet.allCases) { p in
                            Text(p.title).tag(p)
                        }
                    }
                }

                Section {
                    Button {
                        guard canAdd else { return }
                        let st = PrinterStation(
                            id: nextId(),
                            label: label.trimmingCharacters(in: .whitespacesAndNewlines),
                            octet: clampOctet244(octetText)!,
                            set: set,
                            status: 1
                        )
                        dismiss()
                        onAdd(st)
                    } label: {
                        Text("Add")
                            .font(.system(size: 18, weight: .bold))
                    }
                    .disabled(!canAdd)
                }
            }
            .navigationTitle("Add station")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                        onCancel()
                    } label: { Text("Cancel") }
                }
            }
        }
    }
}

import Foundation

enum PrintersAdminAPI {
    struct ApiError: Error { let message: String }

    struct UpsertRequest: Encodable {
        let miniAppId: Int
        let updatedBy: String
        let printers: ShopPrintersPayload
    }

    struct UpsertResponse: Decodable {
        let ok: Bool
        let miniAppId: Int?
        let printers: ShopPrintersPayload?
        let error: String?
    }

    static func upsert(miniAppId: Int, printers: ShopPrintersPayload, updatedBy: String) async throws -> ShopPrintersPayload {
        let base = UserDefaults.standard.string(forKey: "apiBase") ?? "https://minis.studio"
        guard let url = URL(string: "\(base)/api/admin/printers/upsert") else {
            throw ApiError(message: "Bad URL")
        }

        let reqBody = UpsertRequest(
            miniAppId: miniAppId,
            updatedBy: updatedBy,
            printers: printers
        )

        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(reqBody)

        // ✅ debug curl
        if let body = req.httpBody, let s = String(data: body, encoding: .utf8) {
            print("""
            🖨️ PRINTERS UPSERT cURL:
            curl -i -X POST "\(url.absoluteString)" \\
              -H "Content-Type: application/json" \\
              -d '\(s)'
            """)
        }

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        let text = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"

        print("🌍 printers/upsert HTTP \(code)")
        print("📦 printers/upsert RAW (first 600): \(String(text.prefix(600)))")

        guard (200..<300).contains(code) else {
            throw ApiError(message: "HTTP \(code): \(text)")
        }

        let decoded = try JSONDecoder().decode(UpsertResponse.self, from: data)
        guard decoded.ok, let saved = decoded.printers else {
            throw ApiError(message: decoded.error ?? "Unknown API error")
        }

        return saved
    }
}


extension PrinterStation {
    func toPayload() -> ShopPrinterStationPayload {
        ShopPrinterStationPayload(
            id: id,
            label: label,
            octet: octet,
            set: set.rawValue,
            status: status
        )
    }
}

extension ShopPrinterStationPayload {
    func toStation() -> PrinterStation {
        PrinterStation(
            id: id ?? UUID().uuidString,                 // ✅ fallback id
            label: label ?? "Printer",                   // ✅ fallback label
            octet: octet ?? 1,                            // ✅ safe default
            set: PrinterSet(rawValue: set ?? "") ?? .tabit,
            status: status ?? 1                           // ✅ default active
        )
    }
}
