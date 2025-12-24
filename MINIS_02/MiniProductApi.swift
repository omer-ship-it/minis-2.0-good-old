import Foundation
import Combine

struct MinisCustomizationAPI {
    var baseURL = URL(string: "https://minis.studio")!

    enum APIError: Error { case badURL, badResponse(Int, String) }

    /// Always publishes (query ?publish=true), no optional flag exposed.
    func patch(shopId: Int,
               ops: [(path: String, value: Any?, op: String?)] ) async throws -> [String: Any] {

        guard var url = URL(string: "/api/customization/patch", relativeTo: baseURL),
              var comps = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            throw APIError.badURL
        }
        // 👇 force publish=true
        comps.queryItems = [ URLQueryItem(name: "publish", value: "true") ]
        guard let finalURL = comps.url else { throw APIError.badURL }

        // Build JSON body (use JSONSerialization so Any? is fine)
        var arr: [[String: Any]] = []
        arr.reserveCapacity(ops.count)
        for o in ops {
            var item: [String: Any] = ["path": o.path, "op": o.op ?? "set"]
            item["value"] = o.value ?? NSNull()
            arr.append(item)
        }
        let body: [String: Any] = ["shopId": String(shopId), "ops": arr]
        let data = try JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted])

        // Print cURL for debugging (single-line JSON for easy paste)
        if let bodyString = String(data: data, encoding: .utf8) {
            let compact = bodyString.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "  ", with: " ")
            print("""
            🧩 PATCH DEBUG:
            curl -i -X PATCH "\(finalURL.absoluteString)" \\
              -H 'Content-Type: application/json' \\
              -d '\(compact)'
            """)
        }

        // Perform request
        var req = URLRequest(url: finalURL)
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data

        let (respData, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw APIError.badResponse(-1, "No HTTPURLResponse")
        }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: respData, encoding: .utf8) ?? ""
            throw APIError.badResponse(http.statusCode, text)
        }
        return (try JSONSerialization.jsonObject(with: respData, options: []) as? [String: Any]) ?? [:]
    }
}

@MainActor
final class CustomizationUpdater: ObservableObject {
    private let api = MinisCustomizationAPI()
    private var pendingTask: Task<Void, Never>?
    private let shopId: Int
    private let debounceMs: Int

    // Coalesce window: latest value wins per path
    private var queue: [String: Any?] = [:]

    init(shopId: Int, debounceMs: Int = 350) {
        self.shopId = shopId
        self.debounceMs = debounceMs
    }

    /// Debounced + coalesced update (always publishes on send)
    func update(path: String, to value: Any?) {
        queue[path] = value

        pendingTask?.cancel()
        pendingTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: UInt64(max(0, self.debounceMs)) * 1_000_000)

                let opsDict = self.queue
                self.queue.removeAll(keepingCapacity: true)
                if opsDict.isEmpty { return }

                let ops: [(path: String, value: Any?, op: String?)] =
                    opsDict.map { (path: $0.key, value: $0.value, op: "set") }

                // 👇 always publish on each batch
                _ = try await self.api.patch(shopId: self.shopId, ops: ops)
            } catch is CancellationError {
                // debounced (= expected), ignore
            } catch let e as URLError where e.code == .cancelled {
                // cancelled task, ignore
            } catch {
                print("❌ patch failed:", error)
            }
        }
    }

    /// Immediate commit (also publishes). Flushes any queued changes and merges explicit ops.
    func commitAndPublish(ops explicit: [(path: String, value: Any?, op: String?)]) async {
        pendingTask?.cancel()
        var combined = queue
        for e in explicit { combined[e.path] = e.value }
        queue.removeAll(keepingCapacity: true)

        let opsArray: [(path: String, value: Any?, op: String?)] =
            combined.map { (path: $0.key, value: $0.value, op: "set") }

        do {
            _ = try await api.patch(shopId: shopId, ops: opsArray)
        } catch let e as URLError where e.code == .cancelled {
            // unlikely here, but ignore if happens
        } catch {
            print("❌ commit&publish failed:", error)
        }
    }
}

struct MinisProductAPI {
    var baseURL = URL(string: "https://minis.studio")!

    enum APIError: Error { case badURL, badResponse(Int, String) }
    private let hardCodedMiniAppId = 12
    
    struct UpsertPayload: Encodable {
        var Id: Int?                 // nil for new; DB product id for edit
        var MiniAppId: Int
        var Name: String
        var Price: Double
        var Category: String
        var Image: String
        var Sort: Int?
        var Status: Bool = true
        var JsonData: [String: AnyEncodable]
    }

    struct AnyEncodable: Encodable {
        private let _encode: (Encoder) throws -> Void
        init<T: Encodable>(_ value: T) { _encode = value.encode }
        func encode(to encoder: Encoder) throws { try _encode(encoder) }
    }

    // MARK: Upsert
    func upsertProduct(_ payload: UpsertPayload) async throws -> Int {
           guard let url = URL(string: "/api/products/upsert", relativeTo: baseURL) else {
               throw APIError.badURL
           }

           // 🔒 FORCE MiniAppId = 12 regardless of caller
           var forced = payload
           forced.MiniAppId = hardCodedMiniAppId

           let encoder = JSONEncoder()
           encoder.outputFormatting = [.withoutEscapingSlashes]
           let data = try encoder.encode(forced)

           if let body = String(data: data, encoding: .utf8) {
               print("""
               🧩 UPSERT DEBUG:
               curl -i -X POST "\(url.absoluteString)" \\
                 -H 'Content-Type: application/json' \\
                 -d '\(body.replacingOccurrences(of: "\n", with: ""))'
               """)
           }

           var req = URLRequest(url: url)
           req.httpMethod = "POST"
           req.setValue("application/json", forHTTPHeaderField: "Content-Type")
           req.httpBody = data

           let (respData, resp) = try await URLSession.shared.data(for: req)
           guard let http = resp as? HTTPURLResponse else {
               throw APIError.badResponse(-1, "No HTTPURLResponse")
           }
           guard (200..<300).contains(http.statusCode) else {
               throw APIError.badResponse(http.statusCode, String(data: respData, encoding: .utf8) ?? "")
           }

           if let obj = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let pid = obj["productId"] as? Int {
               return pid
           }
           return 0
       }

    // MARK: Publish
    func publish(shopId: Int) async throws {
        var comps = URLComponents(url: baseURL.appendingPathComponent("/api/customization/publish"),
                                  resolvingAgainstBaseURL: true)!
        comps.queryItems = [URLQueryItem(name: "shopId", value: String("12"))]
        guard let url = comps.url else { throw APIError.badURL }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = Data() // Content-Length: 0
        req.setValue("text/plain", forHTTPHeaderField: "Content-Type")

        print("""
        🟢 PUBLISH DEBUG:
        curl -i -X POST "\(url.absoluteString)" -d ''
        """)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.badResponse(-1, "No HTTPURLResponse") }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.badResponse(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }
}

// MARK: - Encodable DTOs (server casing)
private struct MGSelectionDTO: Encodable {
    let mode: String
    let min: Int
    let max: Int
}
private struct MGItemDTO: Encodable {
    let OptionName: String
    let ExtraPrice: Double
}
private struct ModifierGroupDTO: Encodable {
    let GroupId: String
    let Title: String
    let Selection: MGSelectionDTO
    let Items: [MGItemDTO]
}

// Flat “Modifiers” entry (with "Type")
private struct ModifierDTO: Encodable {
    let OptionName: String
    let ExtraPrice: Double
    let kind: String
    enum CodingKeys: String, CodingKey { case OptionName, ExtraPrice, kind = "Type" }
}

// MARK: - Loose-to-typed helpers
private func str(_ any: Any?, _ def: String = "") -> String {
    if let s = any as? String { return s }
    if let n = any as? NSNumber { return n.stringValue }
    return def
}
private func dbl(_ any: Any?, _ def: Double = 0.0) -> Double {
    if let d = any as? Double { return d }
    if let f = any as? Float  { return Double(f) }
    if let i = any as? Int    { return Double(i) }
    if let s = any as? String, let d = Double(s) { return d }
    if let n = any as? NSNumber { return n.doubleValue }
    return def
}
private func int(_ any: Any?, _ def: Int = 0) -> Int {
    if let i = any as? Int { return i }
    if let s = any as? String, let i = Int(s) { return i }
    if let n = any as? NSNumber { return n.intValue }
    return def
}

private func makeGroupsDTO(from groups: [[String: Any]]) -> [ModifierGroupDTO] {
    groups.compactMap { g in
        let gid   = str(g["GroupId"])
        let title = str(g["Title"])
        guard !gid.isEmpty, !title.isEmpty else { return nil }

        let selDict = (g["Selection"] as? [String: Any]) ?? [:]
        let sel = MGSelectionDTO(mode: str(selDict["mode"]), min: int(selDict["min"]), max: int(selDict["max"]))

        let itemsArr = (g["Items"] as? [[String: Any]]) ?? []
        let items: [MGItemDTO] = itemsArr.compactMap { it in
            let name = str(it["OptionName"])
            guard !name.isEmpty else { return nil }
            return MGItemDTO(OptionName: name, ExtraPrice: dbl(it["ExtraPrice"]))
        }

        return ModifierGroupDTO(GroupId: gid, Title: title, Selection: sel, Items: items)
    }
}


func buildJsonData(
    description: String,
    printer: String?,                          // ✅ NEW
    optionsArr: [[String: Any]],
    additionsArr: [[String: Any]],
    removalsArr: [[String: Any]],
    groups: [[String: Any]]
) -> [String: MinisProductAPI.AnyEncodable] {

    let resolvedPrinter: String = {
        let p = (printer ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if p.isEmpty { return "Bar" }
        switch p.lowercased() {
        case "bar":     return "Bar"
        case "kitchen": return "Kitchen"
        case "bakery":  return "Bakery"
        default:        return "Bar"
        }
    }()

    // 1️⃣ Build groups DTO from the "new" structured editor model
    let groupsDTO = makeGroupsDTO(from: groups)

    // 2️⃣ If we have real groups → prefer them and DO NOT also flatten everything
    if !groupsDTO.isEmpty {
        return [
            "Description":    .init(description),
            "Printer":        .init(resolvedPrinter),          // ✅ NEW (top-level)
            // keep flat Modifiers empty when using groups, so the backend
            // doesn't re-flatten them into a default "אפשרויות" group
            "Modifiers":      .init([] as [ModifierDTO]),
            "ModifierGroups": .init(groupsDTO)
        ]
    }

    // 3️⃣ Legacy path: no groups → fall back to flat Modifiers
    let modifiers: [ModifierDTO] =
        optionsArr.compactMap { row in
            guard let name = row["OptionName"] as? String else { return nil }
            return ModifierDTO(OptionName: name, ExtraPrice: dbl(row["ExtraPrice"]), kind: "Options")
        }
        + additionsArr.compactMap { row in
            guard let name = row["OptionName"] as? String else { return nil }
            return ModifierDTO(OptionName: name, ExtraPrice: dbl(row["ExtraPrice"]), kind: "Additions")
        }
        + removalsArr.compactMap { row in
            guard let name = row["OptionName"] as? String else { return nil }
            return ModifierDTO(OptionName: name, ExtraPrice: 0.0, kind: "Removals")
        }

    return [
        "Description": .init(description),
        "Printer":     .init(resolvedPrinter),                 // ✅ NEW (top-level)
        "Modifiers":   .init(modifiers)
        // no ModifierGroups key in pure legacy mode
    ]
}

//



extension MinisProductAPI {
    func softDelete(productId: Int, miniAppId: Int) async throws {
        guard var comps = URLComponents(url: baseURL.appendingPathComponent("/api/products/\(productId)/soft-delete"),
                                        resolvingAgainstBaseURL: true) else {
            throw APIError.badURL
        }
        comps.queryItems = [URLQueryItem(name: "miniAppId", value: String(miniAppId))]
        guard let url = comps.url else { throw APIError.badURL }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = Data()              // Content-Length: 0
        req.setValue("text/plain", forHTTPHeaderField: "Content-Type")

        // debug
        print(#"""
        🗑️ SOFT DELETE:
        curl -i -X POST "\#(url.absoluteString)" -d ''
        """#)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.badResponse(-1, "No HTTPURLResponse") }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.badResponse(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }
}

struct CategoryAPI {
    struct Req: Encodable { let miniAppId: Int; let order: [String] }
    static func reorder(miniAppId: Int, order: [String]) async throws {
        guard let url = URL(string: "https://minis.studio/api/categories/reorder") else { return }
        let body = Req(miniAppId: miniAppId, order: order)
        let data = try JSONEncoder().encode(body)

        // debug cURL
        if let s = String(data: data, encoding: .utf8) {
            print("""
            🧭 CATS REORDER:
            curl -i -X POST "\(url.absoluteString)" \\
              -H 'Content-Type: application/json' \\
              -d '\(s.replacingOccurrences(of: "\n", with: ""))'
            """)
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode ?? 500 < 300 else { return }
    }
}
