import Foundation
import Network
import UIKit
import CoreFoundation
import Combine
import Darwin


enum OneShotPrinter {

    private static let connectTimeout: TimeInterval = 4.0
    private static let sendTimeout: TimeInterval = 9.0
    private static let drainDelaySmall: TimeInterval = 0.45
    private static let drainDelayLarge: TimeInterval = 0.9

    private static let fastAttempts = 2
    private static let fastRetryDelayBase: TimeInterval = 0.35
    private static let fastRetryJitterMax: TimeInterval = 0.25

    // Slow retry window (per job)
    private static let slowRetryEvery: TimeInterval = 5.0
    private static let slowRetryMaxWindow: TimeInterval = 60.0   // 1 minute total

    // Pending pump
    private static let pendingPumpInterval: TimeInterval = 5.0

    // ✅ RETRY LOG THROTTLE
    private static let slowRetryLogEvery: Int = 3
    
    // Per-printer serialization
    private static let lock = NSLock()
    private static var queues: [String: DispatchQueue] = [:]

    // Pending jobs per printer (keyed by dedupeKey)
    private static var pendingOrder: [String: [String]] = [:]
    private static var pendingMap:   [String: [String: Job]] = [:]

    private static func removeJob(pk: String, dedupeKey: String) {
        lock.lock(); defer { lock.unlock() }

        // remove from order list
        if var order = pendingOrder[pk] {
            order.removeAll { $0 == dedupeKey }
            pendingOrder[pk] = order
        }

        // remove from map
        if var map = pendingMap[pk] {
            map.removeValue(forKey: dedupeKey)
            pendingMap[pk] = map
        }
    }
    private static var isDraining: Set<String> = []
    private static var pendingPumpScheduled: Set<String> = []

    // ✅ LAN transition marker state
    private static var lastPrinterLanUp: Bool = false

    // ✅ Completion callbacks per printer + dedupeKey
    // pk -> dedupeKey -> (jobId, callback)
    private static var completions: [String: [String: (UUID, (Bool) -> Void)]] = [:]

    static func sendAwait(host: String, port: UInt16, data: Data, tag: String, dedupeKey: String) async -> Bool {
        await withCheckedContinuation { cont in
            send(host: host, port: port, data: data, tag: tag, dedupeKey: dedupeKey) { ok in
                cont.resume(returning: ok)
            }
        }
    }
    private struct Job {
        let id: UUID
        let createdAt: Date
        let data: Data
        let tag: String
        let dedupeKey: String
        let slowAttempts: Int
    }

    private enum SendOutcome {
        case success(Job)
        case expired(Job)
    }

    // MARK: - Tiny LAN IPv4 helper (en0 / bridge100)

    private static func currentLANIPv4() -> String? {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else { return nil }
        defer { freeifaddrs(ifaddrPtr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let name = String(cString: interface.ifa_name)

            guard name == "en0" || name == "bridge100" else { continue }
            guard interface.ifa_addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }

            let addrInPtr = withUnsafePointer(to: interface.ifa_addr.pointee) {
                $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0 }
            }
            var addr4 = addrInPtr.pointee.sin_addr

            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &addr4, &buffer, socklen_t(INET_ADDRSTRLEN))
            return String(cString: buffer)
        }
        return nil
    }

    private static func isOnPrinterLan(_ ip: String?) -> Bool {
        guard let ip else { return false }
        return ip.hasPrefix("10.100.10.")
    }

    private static func key(_ host: String, _ port: UInt16) -> String { "\(host):\(port)" }

    private static func queue(for host: String, port: UInt16) -> DispatchQueue {
        let k = key(host, port)
        lock.lock(); defer { lock.unlock() }
        if let q = queues[k] { return q }
        let q = DispatchQueue(label: "OneShotPrinter.\(k)")
        queues[k] = q
        return q
    }

    private static func log(_ s: String) {
        Swift.print("🖨️ \(s)")
    }

    private static func totalPendingAllPrinters() -> Int {
        lock.lock(); defer { lock.unlock() }
        return pendingOrder.values.reduce(0) { $0 + $1.count }
    }

    private static func maybeLogLanTransition() {
        let ip = currentLANIPv4()
        let up = isOnPrinterLan(ip)
        let total = totalPendingAllPrinters()

        if up && !lastPrinterLanUp && total > 0 {
            log("ONLINE ip=\(ip ?? "?") → FLUSH pending=\(total)")
        }

        lastPrinterLanUp = up
    }

    // MARK: - Completions storage

    private static func storeCompletion(pk: String, dedupeKey: String, jobId: UUID, completion: @escaping (Bool) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var m = completions[pk] ?? [:]
        m[dedupeKey] = (jobId, completion) // overwrite on dedupe (awaitable caller wants latest)
        completions[pk] = m
    }

    private static func fireCompletion(pk: String, dedupeKey: String, jobId: UUID, ok: Bool) {
        let cb: ((Bool) -> Void)? = {
            lock.lock(); defer { lock.unlock() }
            guard var m = completions[pk],
                  let (storedId, c) = m[dedupeKey],
                  storedId == jobId
            else { return nil }

            m.removeValue(forKey: dedupeKey)
            completions[pk] = m
            return c
        }()
        cb?(ok)
    }

    // MARK: - Public API (with completion)

    /// Main send with per-job completion.
    /// ✅ completion(true) only when bytes were sent successfully.
    /// ✅ completion(false) only when job EXPIRES (slowRetryMaxWindow reached).
    /// (No completion calls for transient retries.)
    static func send(
        host: String,
        port: UInt16,
        data: Data,
        tag: String = "job",
        dedupeKey: String,
        completion: @escaping (Bool) -> Void
    ) {
        let pk = key(host, port)

        maybeLogLanTransition()

        if let ip = currentLANIPv4(), !ip.hasPrefix("10.100.10.") {
            log("OFFLANE ip=\(ip) → \(pk) \(dedupeKey)")
        }

        let jobId: UUID

        lock.lock()
        var map = pendingMap[pk] ?? [:]
        var order = pendingOrder[pk] ?? []

        if let existing = map[dedupeKey] {
            // replace payload but keep retry counter and job id
            jobId = existing.id
            let job = Job(
                id: existing.id,
                createdAt: existing.createdAt,
                data: data,
                tag: tag,
                dedupeKey: dedupeKey,
                slowAttempts: existing.slowAttempts
            )
            map[dedupeKey] = job
            log("DEDUP \(pk) \(dedupeKey) bytes=\(data.count)")
        } else {
            let job = Job(
                id: UUID(),
                createdAt: Date(),
                data: data,
                tag: tag,
                dedupeKey: dedupeKey,
                slowAttempts: 0
            )
            jobId = job.id
            map[dedupeKey] = job
            order.append(dedupeKey)
            log("ENQ \(pk) \(dedupeKey) bytes=\(data.count) pending=\(order.count)")
        }

        pendingMap[pk] = map
        pendingOrder[pk] = order
        lock.unlock()

        // ✅ register completion (dedupe overwrites)
        storeCompletion(pk: pk, dedupeKey: dedupeKey, jobId: jobId, completion: completion)

        queue(for: host, port: port).async {
            drainIfNeeded(host: host, port: port)
        }
    }

    /// Backward-compatible API (no completion)
    static func send(host: String, port: UInt16, data: Data, tag: String = "job", dedupeKey: String) {
        send(host: host, port: port, data: data, tag: tag, dedupeKey: dedupeKey) { _ in }
    }

    static func send(host: String, port: UInt16, data: Data, tag: String = "job") {
        send(host: host, port: port, data: data, tag: tag, dedupeKey: tag) { _ in }
    }

    static func pendingCount(host: String, port: UInt16) -> Int {
        let pk = key(host, port)
        lock.lock(); defer { lock.unlock() }
        return pendingOrder[pk]?.count ?? 0
    }

    // MARK: - Pending pump

    private static func schedulePendingPump(host: String, port: UInt16) {
        let pk = key(host, port)

        lock.lock()
        if pendingPumpScheduled.contains(pk) { lock.unlock(); return }
        pendingPumpScheduled.insert(pk)
        lock.unlock()

        queue(for: host, port: port).asyncAfter(deadline: .now() + pendingPumpInterval) {
            lock.lock()
            pendingPumpScheduled.remove(pk)
            let hasPending = (pendingOrder[pk]?.isEmpty == false)
            lock.unlock()

            guard hasPending else { return }

            maybeLogLanTransition()
            log("PUMP \(pk) pending=\(pendingCount(host: host, port: port))")
            drainIfNeeded(host: host, port: port)
        }
    }

    // MARK: - Drain loop

    private static func drainIfNeeded(host: String, port: UInt16) {
        let pk = key(host, port)

        lock.lock()
        if isDraining.contains(pk) { lock.unlock(); return }
        isDraining.insert(pk)
        lock.unlock()

        maybeLogLanTransition()
        log("DRAIN START \(pk)")

        func next() {
            // ✅ PEEK — do NOT remove job until success/expired
            let job: Job? = {
                lock.lock(); defer { lock.unlock() }
                guard let order = pendingOrder[pk], let dk = order.first else { return nil }

                if let j = pendingMap[pk]?[dk] {
                    return j
                } else {
                    // 🧹 corrupted head: order has dk but map doesn't
                    pendingOrder[pk]?.removeFirst()
                    return nil
                }
            }()

            guard let job else {
                // If queue is truly empty, stop. If we just removed a corrupted head, continue once.
                lock.lock()
                let emptyNow = (pendingOrder[pk]?.isEmpty ?? true)
                lock.unlock()

                if emptyNow {
                    lock.lock(); isDraining.remove(pk); lock.unlock()
                    log("DRAIN STOP \(pk) empty")
                    return
                } else {
                    // there are more items, keep going
                    queue(for: host, port: port).async { next() }
                    return
                }
            }

            trySendWithSlowWindow(host: host, port: port, job: job) { outcome in
                switch outcome {
                case .success(let doneJob):
                    // ✅ NOW remove from queue
                    removeJob(pk: pk, dedupeKey: doneJob.dedupeKey)

                    fireCompletion(pk: pk, dedupeKey: doneJob.dedupeKey, jobId: doneJob.id, ok: true)
                    queue(for: host, port: port).async { next() }

                case .expired(let deadJob):
                    log("DROP \(pk) \(deadJob.dedupeKey) (expired)")

                    // ✅ Remove on expiry too (otherwise it blocks the queue forever)
                    removeJob(pk: pk, dedupeKey: deadJob.dedupeKey)

                    fireCompletion(pk: pk, dedupeKey: deadJob.dedupeKey, jobId: deadJob.id, ok: false)

                    lock.lock()
                    isDraining.remove(pk)
                    lock.unlock()

                    // keep pump in case other pending jobs exist
                    schedulePendingPump(host: host, port: port)
                    return
                }
            }
        }

        next()
    }

    // MARK: - Send strategy
    // ✅ This function ONLY calls completion on success OR expiry.
    // It keeps retrying internally until one of those happens.

    private static func trySendWithSlowWindow(
        host: String,
        port: UInt16,
        job: Job,
        completion: @escaping (SendOutcome) -> Void
    ) {
        // 1) fast attempts
        sendImpl(host: host, port: port, data: job.data, attempt: 1, maxAttempts: fastAttempts, tag: job.dedupeKey) { ok in
            if ok { completion(.success(job)); return }

            let deadline = job.createdAt.addingTimeInterval(slowRetryMaxWindow)

            func slowTick(_ current: Job) {
                if Date() >= deadline {
                    log("EXPIRE \(host):\(port) \(current.dedupeKey)")
                    completion(.expired(current))
                    return
                }

                let nextAttempt = current.slowAttempts + 1
                let updated = Job(
                    id: current.id,
                    createdAt: current.createdAt,
                    data: current.data,
                    tag: current.tag,
                    dedupeKey: current.dedupeKey,
                    slowAttempts: nextAttempt
                )

                if updated.slowAttempts % slowRetryLogEvery == 0 {
                    log("RETRY \(host):\(port) \(updated.dedupeKey) #\(updated.slowAttempts)")
                }

                sendImpl(host: host, port: port, data: updated.data, attempt: 1, maxAttempts: 1, tag: updated.dedupeKey) { ok2 in
                    if ok2 { completion(.success(updated)); return }

                    queue(for: host, port: port).asyncAfter(deadline: .now() + slowRetryEvery) {
                        slowTick(updated)
                    }
                }
            }

            slowTick(job)
        }
    }

    // MARK: - Core send

    private static func sendImpl(
        host: String,
        port: UInt16,
        data: Data,
        attempt: Int,
        maxAttempts: Int,
        tag: String,
        completion: @escaping (Bool) -> Void
    ) {
        let hostNW = NWEndpoint.Host(host)
        let portNW = NWEndpoint.Port(rawValue: port) ?? .init(integerLiteral: 9100)
        let connection = NWConnection(host: hostNW, port: portNW, using: .tcp)

        let startedAt = Date()
        var didFinish = false
        var didBecomeReady = false
        var didStartSend = false

        func markResult(success: Bool) {
            Task { @MainActor in
                PrinterManager.shared.lastSendHadNetworkError = !success
            }
        }

        func finish(success: Bool, reason: String) {
            guard !didFinish else { return }
            didFinish = true

            let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
            log("\(success ? "OK" : "FAIL") \(host):\(port) \(tag) \(ms)ms — \(reason)")

            markResult(success: success)
            connection.stateUpdateHandler = nil
            connection.cancel()

            if success { completion(true); return }

            if attempt < maxAttempts {
                let backoff = fastRetryDelayBase * Double(attempt)
                let jitter  = Double.random(in: 0...fastRetryJitterMax)
                let delay   = backoff + jitter

                queue(for: host, port: port).asyncAfter(deadline: .now() + delay) {
                    sendImpl(
                        host: host,
                        port: port,
                        data: data,
                        attempt: attempt + 1,
                        maxAttempts: maxAttempts,
                        tag: tag,
                        completion: completion
                    )
                }
                return
            }

            completion(false)
        }

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + connectTimeout) {
            if didFinish { return }
            if !didBecomeReady {
                finish(success: false, reason: "connect timeout \(connectTimeout)s")
            }
        }

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                didBecomeReady = true
                guard !didStartSend else { return }
                didStartSend = true

                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + sendTimeout) {
                    if didFinish { return }
                    finish(success: false, reason: "send timeout \(sendTimeout)s")
                }

                connection.send(content: data, completion: .contentProcessed { error in
                    if let error = error {
                        finish(success: false, reason: "send error: \(error)")
                        return
                    }

                    // ✅ Flush barrier
                    connection.send(content: nil, completion: .contentProcessed { barrierErr in
                        if let barrierErr = barrierErr {
                            finish(success: false, reason: "flush barrier error: \(barrierErr)")
                            return
                        }

                        let drain = (data.count > 30_000) ? drainDelayLarge : drainDelaySmall
                        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + drain) {
                            finish(success: true, reason: "sent + barrier + drainDelay \(drain)s")
                        }
                    })
                })
            case .waiting(let e):
                finish(success: false, reason: "waiting: \(e)")
            case .failed(let error):
                finish(success: false, reason: "connection failed: \(error)")

            case .cancelled:
                if !didFinish { finish(success: false, reason: "cancelled") }

            default:
                break
            }
        }

        connection.start(queue: DispatchQueue.global(qos: .utility))
    }
}


// tiny helper
private extension Optional {
    func also(_ f: (Wrapped) -> Void) -> Wrapped? {
        if let v = self { f(v) }
        return self
    }
}

struct EscPos {
    // Initialize / reset printer
    static let initPrinter = Data([0x1B, 0x40])

    // Line feed (n lines)
    static func feed(_ n: UInt8) -> Data { Data([0x1B, 0x64, n]) }

    // Cut paper
    static let cut = Data([0x1D, 0x56, 0x01])

    // 🔄 180° rotation (ESC { n)
      static let rotate180On  = Data([0x1B, 0x7B, 0x01])   // ESC { 1
      static let rotate180Off = Data([0x1B, 0x7B, 0x00])   // ESC { 0

    // 🔔 Open cash drawer (ESC p, m=0, t1=60 (0x3C = 600ms), t2=255)
    // Adjust timing bytes if your drawer needs different pulse length.
    static let openDrawer    = Data([0x1B, 0x70, 0x00, 0x40, 0x50])
     static let openDrawerAlt = Data([0x1B, 0x70, 0x01, 0x40, 0x50])

    // Raster image (GS v 0) with 180° rotation
    static func raster(_ image: UIImage, maxWidthDots: Int = 576) -> Data {
        guard let rotated = rotate180(image),
              let cg = rotated.cgImage else { return Data() }

        let scale = CGFloat(maxWidthDots) / CGFloat(cg.width)
        let W = maxWidthDots
        let H = max(1, Int(CGFloat(cg.height) * scale))

        let cs = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: nil,
            width: W,
            height: H,
            bitsPerComponent: 8,
            bytesPerRow: W,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return Data()
        }

        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: W, height: H))

        guard let gray = ctx.makeImage(),
              let buf = gray.dataProvider?.data else { return Data() }
        let px = CFDataGetBytePtr(buf)!

        var mono = [UInt8](repeating: 0, count: W * H)
        for i in 0..<(W * H) {
            mono[i] = px[i] < 200 ? 1 : 0
        }

        let bytesPerRow = (W + 7) / 8
        var out = Data([
            0x1D, 0x76, 0x30, 0x00,
            UInt8(bytesPerRow & 0xFF), UInt8(bytesPerRow >> 8),
            UInt8(H & 0xFF),         UInt8(H >> 8)
        ])

        for y in 0..<H {
            for bx in 0..<bytesPerRow {
                var b: UInt8 = 0
                for bit in 0..<8 {
                    let x = bx * 8 + bit
                    if x < W, mono[y * W + x] == 1 {
                        b |= (0x80 >> bit)
                    }
                }
                out.append(b)
            }
        }

        out.append(0x0A) // line feed
        return out
    }

    // Rotate image 180°
    private static func rotate180(_ image: UIImage) -> UIImage? {
        let size = image.size
        UIGraphicsBeginImageContextWithOptions(size, false, image.scale)
        guard let ctx = UIGraphicsGetCurrentContext() else {
            UIGraphicsEndImageContext()
            return nil
        }

        ctx.translateBy(x: size.width, y: size.height)
        ctx.rotate(by: .pi)
        image.draw(in: CGRect(origin: .zero, size: size))

        let rotated = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return rotated
    }
}

// MARK: - ESC/POS text helpers (alignment + style)
extension EscPos {
    /// ESC a n  (0 = left, 1 = center, 2 = right)
    static func align(_ mode: UInt8) -> Data {
        Data([0x1B, 0x61, mode])
    }

    /// ESC ! n + ESC E (bold)
    /// bit 3 = double height, bit 4 = double width
    static func style(doubleHeight: Bool = false,
                      doubleWidth: Bool = false,
                      bold: Bool = false) -> Data {
        var flags: UInt8 = 0
        if doubleHeight { flags |= 0x10 }
        if doubleWidth  { flags |= 0x20 }

        var d = Data()
        // ESC ! n  → font size flags
        d.append(contentsOf: [0x1B, 0x21, flags])
        // ESC E n  → bold on/off
        d.append(contentsOf: [0x1B, 0x45, bold ? 1 : 0])
        return d
    }
}

/// Simple ASCII line helper (no Hebrew, just plain text)
func asciiLine(_ s: String) -> Data {
    Data((s + "\n").utf8)
}

func visualHebrew(_ s: String) -> String {
    String(s.reversed())
}

func containsHebrew(_ s: String) -> Bool {
    return s.range(of: #"\p{Hebrew}"#, options: .regularExpression) != nil
}

/// (optional) better heuristic for mixed strings like "John (יוחנן)"
func isMostlyHebrew(_ s: String) -> Bool {
    var he = 0
    var latin = 0
    for scalar in s.unicodeScalars {
        if CharacterSet(charactersIn: "\u{0590}"..."\u{05FF}").contains(scalar) { he += 1 }
        else if CharacterSet.letters.contains(scalar) { latin += 1 }
    }
    return he > latin
}
/// Encode Hebrew line as Windows-1255 (or ISO-8859-8), with LF at the end
/// Encode line as Windows-1255 (or ISO-8859-8), with LF at the end.
/// ✅ Hebrew gets visual flip, English stays normal.
func hebrewLineData(_ s: String) -> Data {
    // Choose ONE of these:
    // let visual = containsHebrew(s) ? visualHebrew(s) : s
    let visual = isMostlyHebrew(s) ? visualHebrew(s) : s   // better for mixed text

    // Try Windows-1255
    let win1255Enc = CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.windowsHebrew.rawValue)
    )
    if let d = visual.data(using: String.Encoding(rawValue: win1255Enc)) {
        return d + Data([0x0A])    // LF
    }

    // Fallback: ISO-8859-8
    let iso8859_8_Enc = CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.isoLatinHebrew.rawValue)
    )
    if let d = visual.data(using: String.Encoding(rawValue: iso8859_8_Enc)) {
        return d + Data([0x0A])
    }

    // Last fallback: UTF-8
    return Data((visual + "\n").utf8)
}

fileprivate func stationFromFilter(_ f: StationFilter) -> Station? {
    switch f {
    case .all:     return nil
    case .kitchen: return .kitchen
    case .bar:     return .bar
    case .bakery:  return .bakery
    }
}

fileprivate func stationFromString(_ s: String?) -> Station? {
    guard let raw = s?.trimmingCharacters(in: .whitespacesAndNewlines),
          !raw.isEmpty
    else { return nil }

    switch raw.lowercased() {
    case "bar":     return .bar
    case "kitchen": return .kitchen
    case "bakery":  return .bakery
    default:        return nil
    }
}

fileprivate func lineStation(_ line: KDSOrderLine) -> Station? {
    stationFromString(line.station ?? line.category)
}

func hebrewLine(_ text: String,
                widthDots: Int = 576,
                font: UIFont,
                align: NSTextAlignment = .right,
                topBottomPadding: CGFloat = 6,
                sidePadding: CGFloat = 8) -> UIImage {
    let para = NSMutableParagraphStyle()
    para.alignment = align
    para.baseWritingDirection = .rightToLeft

    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .paragraphStyle: para
    ]

    let max = CGSize(width: CGFloat(widthDots) - 2 * sidePadding,
                     height: .greatestFiniteMagnitude)
    let box = (text as NSString).boundingRect(with: max,
                                              options: [.usesLineFragmentOrigin],
                                              attributes: attrs,
                                              context: nil).integral
    let size = CGSize(width: CGFloat(widthDots), height: box.height + 2 * topBottomPadding)

    UIGraphicsBeginImageContextWithOptions(size, true, 1)
    UIColor.white.setFill()
    UIRectFill(CGRect(origin: .zero, size: size))
    (text as NSString).draw(in: CGRect(x: sidePadding,
                                       y: topBottomPadding,
                                       width: max.width,
                                       height: box.height),
                            withAttributes: attrs)
    let img = UIGraphicsGetImageFromCurrentImageContext()!
    UIGraphicsEndImageContext()
    return img
}

func separatorLine(_ text: String = "✱✱✱✱✱✱✱✱✱✱✱✱✱✱",
                   widthDots: Int = 576,
                   font: UIFont = .monospacedSystemFont(ofSize: 22, weight: .regular)) -> UIImage {
    hebrewLine(text,
               widthDots: widthDots,
               font: font,
               align: .center,
               topBottomPadding: 2,
               sidePadding: 8)
}

func dottedRule(widthDots: Int = 576) -> UIImage {
    hebrewLine(String(repeating: "·", count: 50),
               widthDots: widthDots,
               font: .monospacedSystemFont(ofSize: 18, weight: .regular),
               align: .center,
               topBottomPadding: 0,
               sidePadding: 8)
}

@MainActor
final class TCPPrinter: ObservableObject {
    enum PrinterConnState { case idle, connecting, ready, failed(String) }

    @Published private(set) var printerStatus: String = "Disconnected"
    @Published private(set) var printerState: PrinterConnState = .idle

    private var conn: NWConnection?
    private var host: String = "10.0.0.110"
    private var port: UInt16 = 9100

    private var sendQueue = DispatchQueue(label: "printer.send.queue")
    private var outbox: [Data] = []
    private var isFlushing = false

    func configure(host: String, port: UInt16 = 9100) {
        self.host = host
        self.port = port
    }

    func connectIfNeeded() {
        guard conn == nil else { return }
        printerStatus = "Connecting…"
        printerState = .connecting

        let c = NWConnection(host: .init(host), port: .init(rawValue: port)!, using: .tcp)
        conn = c
        c.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            Task { @MainActor in
                switch st {
                case .ready:
                    self.printerStatus = "Connected"
                    self.printerState = .ready
                    self.flush()
                case .failed(let e):
                    self.printerStatus = "Failed: \(e.localizedDescription)"
                    self.printerState = .failed(e.localizedDescription)
                    self.teardown()
                case .waiting(let e):
                    self.printerStatus = "Waiting: \(e.localizedDescription)"
                case .cancelled:
                    self.printerStatus = "Disconnected"
                    self.printerState = .idle
                default:
                    break
                }
            }
        }
        c.start(queue: sendQueue)
    }

    func clearQueue() {
        outbox.removeAll()
        isFlushing = false
    }

    func printJob(_ data: Data) {
        outbox.append(data)
        switch printerState {
        case .ready:
            flush()
        case .idle, .failed:
            connectIfNeeded()
        case .connecting:
            break
        }
    }

    private func flush() {
        guard let c = conn, !isFlushing, !outbox.isEmpty else { return }
        guard case TCPPrinter.PrinterConnState.ready = printerState else { return }

        isFlushing = true
        let job = outbox.removeFirst()
        c.send(content: job, completion: .contentProcessed { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                self.isFlushing = false
                self.flush()
            }
        })
    }

    func disconnect() { teardown() }

    private func teardown() {
        conn?.cancel(); conn = nil
        isFlushing = false
        if outbox.isEmpty {
            printerState = .idle
            printerStatus = "Disconnected"
        }
    }
}



@MainActor
final class PrinterManager {
    enum Mode { case persistent, oneShot }
    @Published var lastSendHadNetworkError: Bool = false

    func markLastSendResult(success: Bool) {
        Task { @MainActor in
            self.lastSendHadNetworkError = !success
        }
    }

    static let shared = PrinterManager()
    private let debugTickets = true

    // MARK: - Raw IPs for each physical printer

    // Ron / Rongta printers
    private let RonbarPrinterIP     = "10.100.10.222"
    private let RonbakeryPrinterIP  = "10.100.10.221"
    private let RonkitchenPrinterIP = "10.100.10.220"

    // Tabit printers
    private let TabitBarPrinterIP     = "10.100.10.234"
    private let TabitBakeryPrinterIP  = "10.100.10.230"   // adjust if needed
    private let TabitKitchenPrinterIP = "10.100.10.232"
    private let KitchenBackPrinterIP = "10.100.10.238"
    // ✅ Rongta KitchenBack tuning (make it match the others)
    private let kitchenBackFamily: PrinterFamily = .ron      // uses ESC t 33
    private let kitchenBackRotated: Bool = false              // or false if you don’t want rotation
    private let kitchenBackLineWidth: Int = 42               // match the rest
    
    private func sortForPrint(_ lines: [KDSOrderLine]) -> [KDSOrderLine] {
        lines.sorted {
            // stable, deterministic
            let s0 = ($0.station ?? "").lowercased()
            let s1 = ($1.station ?? "").lowercased()
            if s0 != s1 { return s0 < s1 }

            let c0 = normalizeCategory($0.category ?? "")
            let c1 = normalizeCategory($1.category ?? "")
            if c0 != c1 { return c0 < c1 }

            let n0 = $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let n1 = $1.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if n0 != n1 { return n0 < n1 }

            return ($0.productId ?? 0) < ($1.productId ?? 0)
        }
    }

    // MARK: - Which set is active? (global toggle)

    enum PrinterSet: String {
        case ron
        case tabit
    }

    private func isToastLine(_ ln: KDSOrderLine) -> Bool {
        let name = ln.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.contains("טוסט") { return true }
        if name.lowercased().contains("toast") { return true }
        return false
    }
    
    private let printerSetKey = "kds.printer.set"

    var activePrinterSet: PrinterSet {
        get {
            let raw = UserDefaults.standard.string(forKey: printerSetKey) ?? PrinterSet.tabit.rawValue
            return PrinterSet(rawValue: raw) ?? .tabit
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: printerSetKey)
            Swift.print("🖨 Active printer set changed to:", newValue.rawValue)
        }
    }

    /// Public helper to switch between Ron and Tabit from UI / settings
    func setPrinterSet(_ set: PrinterSet) {
        activePrinterSet = set
        // If you use persistent mode, you may want to reconnect:
        updatePort(port)  // reconfigure TCP connections with new IPs
    }

    // Computed active IPs based on current set
    private var activeBarIP: String {
        switch activePrinterSet {
        case .ron:   return RonbarPrinterIP
        case .tabit: return TabitBarPrinterIP
        }
    }

    private var activeBakeryIP: String {
        switch activePrinterSet {
        case .ron:   return RonbakeryPrinterIP
        case .tabit: return TabitBakeryPrinterIP
        }
    }

    private var activeKitchenIP: String {
        switch activePrinterSet {
        case .ron:   return RonkitchenPrinterIP
        case .tabit: return TabitKitchenPrinterIP
        }
    }

    // MARK: - Printer family (Hebrew + rotation rules)

    enum HebrewCodePage: UInt8 {
        case beitHaam = 33  // your original Rongta setting
        case tabit    = 2   // Tabit printers (t=2 worked in probe)
        // if you later decide 3 is better: case tabit = 3
    }

    enum PrinterFamily {
        case ron
        case tabit

        var codePage: HebrewCodePage {
            switch self {
            case .ron:   return .beitHaam
            case .tabit: return .tabit
            }
        }

        /// Only Ron tickets should use 180° rotation
        var supportsRotation: Bool {
            switch self {
            case .ron:   return true
            case .tabit: return false
            }
        }
    }

    // Family derived only from activePrinterSet (global switch)
    private var activeFamily: PrinterFamily {
        switch activePrinterSet {
        case .ron:   return .ron
        case .tabit: return .tabit
        }
    }

    func escSelectHebrew(_ cp: HebrewCodePage) -> Data {
        Data([0x1B, 0x74, cp.rawValue])
    }

    // MARK: - Test helper: probe codepages on any given IP

    func printHebrewCodepageProbe(to host: String, port: UInt16 = 9100) {
        var job = Data()
        job += EscPos.initPrinter

        let testText = "אבגדהוזחט כלםמןנסעפצקרשת 123"

        for n: UInt8 in 0...47 {
            job.append(contentsOf: [0x1B, 0x74, n])
            job += asciiLine("ESC t \(n) → Windows-1255 bytes + visualHebrew")
            job += hebrewLineData(testText)
            job += EscPos.feed(1)
        }

        job += EscPos.feed(4)
        job += EscPos.cut

        Swift.print("📄 Probing Hebrew codepages on \(host):\(port)")
        OneShotPrinter.send(host: host, port: port, data: job)
    }

    // MARK: - TCP printers

    private let barTCP     = TCPPrinter()
    private let bakeryTCP  = TCPPrinter()
    private let kitchenTCP = TCPPrinter()

    private var mode: Mode = .persistent

    private var port: UInt16 {
        let raw = UserDefaults.standard.integer(forKey: "kds.printer.port")
        let candidate = UInt16(exactly: raw) ?? 0
        return candidate == 0 ? 9100 : candidate
    }

    // MARK: - Cash drawer

    func openCashDrawer() {
        let job = EscPos.openDrawer
            + EscPos.feed(2)
            + EscPos.openDrawerAlt
            + EscPos.feed(2)

        let host = activeBakeryIP
        Swift.print("🔔 [PrinterManager] openCashDrawer (one-shot) → BAKERY \(host):\(port)")
        OneShotPrinter.send(host: host, port: port, data: job)
    }

    private init() { }

    // MARK: - Connection mode / port

    func updatePort(_ port: UInt16 = 9100) {
        UserDefaults.standard.set(Int(port), forKey: "kds.printer.port")

        // Configure TCP connections based on ACTIVE set
        barTCP.configure(host: activeBarIP,     port: port)
        bakeryTCP.configure(host: activeBakeryIP, port: port)
        kitchenTCP.configure(host: activeKitchenIP, port: port)

        if mode == .persistent {
            barTCP.connectIfNeeded()
            bakeryTCP.connectIfNeeded()
            kitchenTCP.connectIfNeeded()
        }
    }

    func updateMode(_ newMode: Mode) {
        mode = newMode
        barTCP.disconnect()
        bakeryTCP.disconnect()
        kitchenTCP.disconnect()
    }

    // === Mixed Hebrew + Price helper (2-column table line) ===
    // Hebrew label on the RIGHT (RTL), price on the LEFT (LTR).
    func hebrewMixedLineData(label: String,
                             price: String,
                             totalWidth: Int = 42,
                             leftPadding: Int = 1) -> Data {

        let margin = String(repeating: " ", count: leftPadding)
        let priceText = price
        let leftPart = margin + priceText + " "

        let visualLabel = visualHebrew(label)

        let remainingWidth = max(0, totalWidth - leftPart.count)
        let labelLen = visualLabel.count
        let spacesCount = max(1, remainingWidth - labelLen)
        let spaces = String(repeating: " ", count: spacesCount)

        let line = leftPart + spaces + visualLabel

        let win1255Enc = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.windowsHebrew.rawValue)
        )
        if let d = line.data(using: String.Encoding(rawValue: win1255Enc)) {
            return d + Data([0x0A])
        }

        let iso8859_8_Enc = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.isoLatinHebrew.rawValue)
        )
        if let d = line.data(using: String.Encoding(rawValue: iso8859_8_Enc)) {
            return d + Data([0x0A])
        }

        return Data((line + "\n").utf8)
    }

    // MARK: - Tax invoice
    let taBarText = "** TA **"  // or "TA"
    func reverseNumber(_ s: String) -> String {
        String(s.reversed())
    }
    
    func printTaxInvoice(
        invoiceNumber: Int,
        date: Date = Date(),
        customerName: String?,
        items: [InvoiceItem],
        vatRate: Double = 0.18,

        // ✅ Required to make this a "Tax Invoice / Receipt" (i.e., paid now)
        paidAmount: Double,
        paymentMethod: String,        // e.g. "Credit Card" / "Cash" / "Transfer"
        cardBrand: String? = nil,      // e.g. "Visa"
        cardLast4: String? = nil,      // e.g. "1234"
        installments: Int? = nil       // e.g. 3
    ) {
        // ---- BUSINESS DETAILS ----
        let businessName    = "בית העם קונדיטוריה ויין בע\"מ"
        let businessAddress = "מנורה 3 ירושלים"
        let businessPhone   = "טלפון: 000000050"
        let businessVatId   = "ח.פ / עוסק מורשה: 931487615"

        // ---- DATE / META ----
        let df = DateFormatter()
        df.locale = Locale(identifier: "he_IL")
        df.dateFormat = "dd/MM/yyyy  HH:mm"
        let dateText = reverseNumber(df.string(from: date))

        // ✅ Must say Tax Invoice / Receipt when paid
        let invoiceIdText = "חשבונית מס/קבלה #\(reverseNumber(String(invoiceNumber)))"

        let safeCustomer = (customerName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let customerLine = safeCustomer.isEmpty ? "ללא שם לקוח" : "לקוח: \(safeCustomer)"

        // ---- TOTALS from REAL LINE DATA ----
        let gross = items.reduce(0) { $0 + $1.lineTotal }
        let net = gross / (1.0 + vatRate)
        let vatAmount = gross - net

        func money(_ value: Double) -> String { String(format: "%.2f", value) }

        // ---- PAYMENT (Receipt) LINES ----
        func paymentLines() -> [String] {
            var lines: [String] = []
            lines.append("שולם: \(reverseNumber(money(paidAmount)))")
            lines.append("אמצעי תשלום: \(paymentMethod)")

            if let last4 = cardLast4?.trimmingCharacters(in: .whitespacesAndNewlines), !last4.isEmpty {
                var cardLine = "כרטיס: **** \(last4)"
                if let brand = cardBrand?.trimmingCharacters(in: .whitespacesAndNewlines), !brand.isEmpty {
                    cardLine += " \(brand)"
                }
                lines.append(cardLine)
            }

            if let n = installments, n > 1 {
                lines.append("תשלומים: \(n)")
            }

            return lines
        }

        // ---- DEBUG PREVIEW ----
        Swift.print("══════════ TAX INVOICE/RECEIPT PREVIEW #\(invoiceNumber) ══════════")
        Swift.print("Date: \(dateText)")
        Swift.print("Customer: \(safeCustomer.isEmpty ? "No customer name" : safeCustomer)")
        Swift.print("────────────────────────────────────────────")
        for item in items {
            Swift.print("• \(item.quantity)x \(item.name) → \(money(item.lineTotal))")
        }
        Swift.print("────────────────────────────────────────────")
        Swift.print("Net (before VAT): \(money(net))")
        Swift.print("VAT \(Int(vatRate * 100))%: \(money(vatAmount))")
        Swift.print("Total: \(money(gross))")
        Swift.print("Paid: \(money(paidAmount)) via \(paymentMethod)")
        Swift.print("════════════════════════════════════════════\n")

        // ---- LAYOUT CONSTANTS ----
        let lineWidth = 42
        func separatorLine() -> Data { asciiLine(String(repeating: "-", count: lineWidth)) }

        // ---- BUILD ESC/POS JOB ----
        var job = Data()
        job += EscPos.initPrinter
        job += EscPos.feed(1)

        let fam = activeFamily
        job += escSelectHebrew(fam.codePage)

        // ===== TITLE (BIG, CENTER) =====
        job += EscPos.align(1)
        job += EscPos.style(doubleHeight: true, doubleWidth: true, bold: true)
        job += hebrewLineData("חשבונית מס/קבלה") // ✅ fixed

        // ===== BUSINESS DETAILS (CENTER) =====
        job += EscPos.feed(1)
        job += EscPos.align(1)
        job += EscPos.style(doubleHeight: false, doubleWidth: false, bold: false)
        job += hebrewLineData(businessName)
        job += hebrewLineData(businessAddress)
        job += hebrewLineData(businessPhone)
        job += hebrewLineData(businessVatId)

        job += EscPos.feed(1)

        // ===== INVOICE META (CENTER) =====
        job += hebrewLineData(invoiceIdText)
        job += hebrewLineData("תאריך: \(dateText)")
        job += hebrewLineData(customerLine)

        // ===== PAYMENT META (CENTER) =====
        job += EscPos.feed(1)
        for line in paymentLines() {
            job += hebrewLineData(line)
        }

        // ===== SEPARATOR =====
        job += EscPos.feed(1)
        job += EscPos.align(0)
        job += separatorLine()

        // ===== ITEMS TABLE =====
        job += EscPos.feed(1)
        job += EscPos.align(0)

        func stripModsForInvoice(_ s: String) -> String {
            var x = s
            if let r = x.range(of: "\n") { x = String(x[..<r.lowerBound]) }
            if let r = x.range(of: "·") { x = String(x[..<r.lowerBound]) }
            if let r = x.range(of: ",") { x = String(x[..<r.lowerBound]) }
            if let r = x.range(of: ":") { x = String(x[..<r.lowerBound]) }
            return x.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        for item in items {
            let cleanName = stripModsForInvoice(item.name)
            let label = "\(item.quantity)x \(cleanName)"
            let priceText = money(item.lineTotal)

            job += hebrewMixedLineData(
                label: label,
                price: priceText,
                totalWidth: lineWidth,
                leftPadding: 1
            )
        }

        // ===== SEPARATOR =====
        job += EscPos.feed(1)
        job += EscPos.align(0)
        job += separatorLine()

        // ===== TOTALS TABLE =====
        job += EscPos.feed(1)
        job += EscPos.align(0)

        job += EscPos.style(doubleHeight: false, doubleWidth: false, bold: false)
        job += hebrewMixedLineData(
            label: "סה\"כ לפני מע\"מ",
            price: money(net),
            totalWidth: lineWidth,
            leftPadding: 1
        )

        // ✅ fixed: 81% -> vatRate
        job += hebrewMixedLineData(
            label: "מע\"מ %81",
            price: money(vatAmount),
            totalWidth: lineWidth,
            leftPadding: 1
        )

        job += EscPos.style(doubleHeight: false, doubleWidth: false, bold: true)
        job += hebrewMixedLineData(
            label: "סה\"כ לתשלום",
            price: money(gross),
            totalWidth: lineWidth,
            leftPadding: 1
        )

        // Optional but useful: show paid amount (receipt clarity)
        job += EscPos.style(doubleHeight: false, doubleWidth: false, bold: false)
        job += hebrewMixedLineData(
            label: "שולם",
            price: money(paidAmount),
            totalWidth: lineWidth,
            leftPadding: 1
        )

        job += EscPos.align(0)
        job += EscPos.feed(4)
        job += EscPos.cut

        let host = activeBakeryIP
        Swift.print("🧾 [PrinterManager] printTaxInvoice → bakery (one-shot) \(host):\(port)")
        OneShotPrinter.send(host: host, port: port, data: job)
    }

    // MARK: - Main order printing

    func print(order o: KDSAdminOrder, for station: StationFilter) {
        guard o.source == .kiosk else {
            Swift.print("🛑 [PrinterManager] skipping print for non-kiosk source: \(o.source)")
            return
        }

        let allLines = o.lines
        let kitchenLines = sortForPrint(allLines.filter { classifyStation(for: $0) == .kitchen })
        let bakeryLines  = sortForPrint(allLines.filter { classifyStation(for: $0) == .bakery })
        let barLines     = sortForPrint(allLines.filter { classifyStation(for: $0) == .bar })
        
        switch station {
        case .kitchen:
            guard !kitchenLines.isEmpty else {
                Swift.print("🧑‍🍳 KITCHEN: no lines to print for order #\(o.id)")
                return
            }

            // ✅ Always print ALL kitchen lines to Kitchen (unchanged)
            do {
                debugTicketPreview(order: o, lines: kitchenLines, stationLabel: "Kitchen")
                let host = activeKitchenIP
                let fam  = activeFamily
                let job  = makeJob(order: o, lines: kitchenLines, rotated: false, family: fam)
                Swift.print("🧑‍🍳 KITCHEN: sending \(job.count) bytes to \(host):\(port)")
                send(job, host: host, dedupeKey: "bone|\(o.id)|kitchen")
            }

            // ✅ Additionally print ONLY toast lines to KitchenBack (Rongta)
            let toastLines = kitchenLines.filter { isToastLine($0) }
            if !toastLines.isEmpty {
                debugTicketPreview(order: o, lines: toastLines, stationLabel: "KitchenBack (טוסט)")

                let host = KitchenBackPrinterIP

                // 🔥 FORCE Rongta decoding (ESC t 33) regardless of activePrinterSet
                let backFamily: PrinterFamily = .ron

                // If your Rongta is physically rotated, set rotated: true (kept true here)
                let backJob = makeJob(
                    order: o,
                    lines: toastLines,
                    rotated: kitchenBackRotated,
                    family: kitchenBackFamily,
                    lineWidth: kitchenBackLineWidth
                )

                Swift.print("🧑‍🍳 KITCHENBACK (RONGTA): sending \(backJob.count) bytes to \(host):\(port)")
                send(backJob, host: host, dedupeKey: "bone|\(o.id)|kitchenback|toast")
            }

            return
            

        case .bakery:
            Swift.print("🧁 BAKERY printing order #\(o.id), lines=",
                        bakeryLines.map { "\($0.name) (\($0.category ?? "-"))" })

            guard !bakeryLines.isEmpty else {
                Swift.print("🧁 BAKERY: no lines to print for order #\(o.id)")
                return
            }

            debugTicketPreview(order: o, lines: bakeryLines, stationLabel: "Bakery")

            let host = activeBakeryIP
            let fam  = activeFamily
            let job  = makeJob(order: o, lines: bakeryLines, rotated: false, family: fam)
            Swift.print("🧁 BAKERY: sending \(job.count) bytes to \(host):\(port)")
            let dk = "bone|\(o.id)|bakery"
            send(job, host: host, dedupeKey: dk)

        case .all:
            guard !allLines.isEmpty else {
                Swift.print("📦 ALL: no lines to print for order #\(o.id)")
                return
            }

            let host = activeBarIP
            let fam  = activeFamily
            let job  = makeJob(order: o, lines: allLines, rotated: false, family: fam)
            Swift.print("📦 ALL: sending \(job.count) bytes to bar \(host):\(port)")
            debugTicketPreview(order: o, lines: allLines, stationLabel: "All stations")
            let dk = "bone|\(o.id)|all"
            send(job, host: host, dedupeKey: dk)

        case .bar:
            Swift.print("🖨 BAR station handling order #\(o.id)")
            Swift.print("   • bakeryLines =",
                        bakeryLines.map { "\($0.name) (\($0.category ?? "-"))" })
            Swift.print("   • barLines    =",
                        barLines.map { "\($0.name) (\($0.category ?? "-"))" })

            if bakeryLines.isEmpty && barLines.isEmpty {
                Swift.print("🖨 BAR: no lines to print for order #\(o.id)")
                return
            }

            if !bakeryLines.isEmpty {
                debugTicketPreview(order: o,
                                   lines: bakeryLines,
                                   stationLabel: "Bakery via BAR")

                let host = activeBakeryIP
                let fam  = activeFamily
                let bakeryJob = makeJob(order: o, lines: bakeryLines, rotated: false, family: fam)

                Swift.print("🧁 BAKERY (from BAR): sending \(bakeryJob.count) bytes to \(host):\(port)")

                // ✅ IMPORTANT: unique per-order+station so jobs don't overwrite each other
                let dedupeKey = "bone|\(o.id)|bakery"
                send(bakeryJob, host: host, dedupeKey: dedupeKey)
            }

            if !barLines.isEmpty {
                debugTicketPreview(order: o,
                                   lines: barLines,
                                   stationLabel: "Bar")

                let host = activeBarIP
                let fam  = activeFamily
                let barJob = makeJob(order: o, lines: barLines, rotated: false, family: fam)

                Swift.print("🖨 BAR: sending \(barJob.count) bytes to \(host):\(port)")

                // ✅ Stable per-order + station dedupe key
                let dedupeKey = "bone|\(o.id)|bar"
                send(barJob, host: host, dedupeKey: dedupeKey)
            }
        }
    }

    // MARK: - Split-all printing (rotated only for Ron)

    func printSplitAllStations(order o: KDSAdminOrder) {
        guard o.source == .kiosk else {
            Swift.print("🛑 [PrinterManager] skipping split-all print for non-kiosk source: \(o.source)")
            return
        }

        let allLines = o.lines

        // ✅ sort once if you added sortForPrint(...)
        // let kitchenLines = sortForPrint(allLines.filter { classifyStation(for: $0) == .kitchen })
        // let bakeryLines  = sortForPrint(allLines.filter { classifyStation(for: $0) == .bakery })
        // let barLines     = sortForPrint(allLines.filter { classifyStation(for: $0) == .bar })

        let kitchenLines: [KDSOrderLine] = allLines.filter { classifyStation(for: $0) == .kitchen }
        let bakeryLines:  [KDSOrderLine] = allLines.filter { classifyStation(for: $0) == .bakery }
        let barLines:     [KDSOrderLine] = allLines.filter { classifyStation(for: $0) == .bar }

        if kitchenLines.isEmpty && bakeryLines.isEmpty && barLines.isEmpty {
            Swift.print("🖨 SPLIT-ALL: no lines to print for order #\(o.id)")
            return
        }

        let fam = activeFamily

        // ✅ Precompute toast subset BEFORE using it anywhere
        let toastLines = kitchenLines.filter { isToastLine($0) }

        // ---------------- KITCHEN ----------------
        if !kitchenLines.isEmpty {
            debugTicketPreview(order: o, lines: kitchenLines, stationLabel: "Kitchen (split all)")

            let host = activeKitchenIP
            let rotated = fam.supportsRotation

            let job = makeJob(
                order: o,
                lines: kitchenLines,                 // ✅ kitchen gets ALL kitchen lines
                rotated: rotated,
                family: fam,
                lineWidth: 42                        // or your default variable
            )

            Swift.print("🧑‍🍳 SPLIT-ALL KITCHEN: sending \(job.count) bytes to \(host):\(port)")
            send(job, host: host, dedupeKey: "bone|\(o.id)|kitchen")
        }

        // ---------------- KITCHEN BACK (RONGTA) ----------------
        if !toastLines.isEmpty {
            debugTicketPreview(order: o, lines: toastLines, stationLabel: "KitchenBack (split all) טוסט")

            let host = KitchenBackPrinterIP

            let job = makeJob(
                order: o,
                lines: toastLines,
                rotated: kitchenBackRotated,         // ✅ your knob (true/false)
                family: kitchenBackFamily,           // ✅ forced .ron
                lineWidth: kitchenBackLineWidth      // ✅ 42 (or 32 if 58mm)
            )

            Swift.print("🧑‍🍳 SPLIT-ALL KITCHENBACK: sending \(job.count) bytes to \(host):\(port)")
            send(job, host: host, dedupeKey: "bone|\(o.id)|kitchenback|toast")
        }

        // ---------------- BAKERY ----------------
        if !bakeryLines.isEmpty {
            debugTicketPreview(order: o, lines: bakeryLines, stationLabel: "Bakery (split all)")

            let host = activeBakeryIP
            let rotated = fam.supportsRotation

            let job = makeJob(
                order: o,
                lines: bakeryLines,
                rotated: rotated,
                family: fam,
                lineWidth: 42
            )

            Swift.print("🧁 SPLIT-ALL BAKERY: sending \(job.count) bytes to \(host):\(port)")
            send(job, host: host, dedupeKey: "bone|\(o.id)|bakery")
        }

        // ---------------- BAR ----------------
        if !barLines.isEmpty {
            debugTicketPreview(order: o, lines: barLines, stationLabel: "Bar (split all)")

            let host = activeBarIP
            let rotated = fam.supportsRotation

            let job = makeJob(
                order: o,
                lines: barLines,
                rotated: rotated,
                family: fam,
                lineWidth: 42
            )

            Swift.print("🍹 SPLIT-ALL BAR: sending \(job.count) bytes to \(host):\(port)")
            send(job, host: host, dedupeKey: "bone|\(o.id)|bar")
        }
    }

    // MARK: - Classification helpers (unchanged)

    fileprivate func normalizeCategory(_ s: String) -> String {
        let allowed = CharacterSet.letters
            .union(.decimalDigits)
            .union(.whitespaces)

        return String(
            s.unicodeScalars
                .filter { allowed.contains($0) }
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    }
    fileprivate func classifyStation(for line: KDSOrderLine) -> Station {
        if let s = stationFromString(line.station) { return s }
        Swift.print("⚠️ [PrinterManager] missing station for productId=\(line.productId ?? -1) name='\(line.name)' → default Kitchen")
        return .kitchen
    }
 

    private func send(_ job: Data, host: String, dedupeKey: String) {
        OneShotPrinter.send(host: host, port: port, data: job, tag: dedupeKey, dedupeKey: dedupeKey)
    }
    // OPTIONAL: keep a backwards-compatible wrapper so old call sites still compile
   
    private func debugTicketPreview(order: KDSAdminOrder,
                                    lines: [KDSOrderLine],
                                    stationLabel: String) {
        guard debugTickets else { return }

        Swift.print("──────── \(stationLabel.uppercased()) TICKET #\(order.id) ────────")
        Swift.print("Customer: \(order.customerName.isEmpty ? "-" : order.customerName)")
        Swift.print("Service:  \(serviceLabel(from: order.service))")
        Swift.print("Printed:  \(Date())")
        Swift.print("Items:")

        if lines.isEmpty {
            Swift.print("  (no lines)")
        } else {
            for ln in lines {
                let cat = ln.category ?? "-"
                Swift.print("  - \(ln.qty)x \(ln.name) [\(cat)]")

                if let mods = ln.modifiers?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !mods.isEmpty {
                    Swift.print("      · \(mods)")
                }
            }
        }

        Swift.print("────────────────────────────────────────────\n")
    }

    private func removeKeyword(_ keyword: String, from mods: String?) -> String {
        guard var m = mods else { return "" }

        m = m.replacingOccurrences(of: keyword, with: "", options: .caseInsensitive)
        m = m.replacingOccurrences(of: "  ", with: " ")
        return m.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - makeJob core (same logic, now family-aware for rotation)

    private func makeJob(
        order o: KDSAdminOrder,
        lines: [KDSOrderLine],
        rotated: Bool = false,
        family: PrinterFamily,
        lineWidth: Int = 42
    ) -> Data {

        struct PrintItem {
            var nameWithSize: String
            var qty: Int
            var modsClean: String
        }

        
        let phoneLine: String? = {
            let p = o.customerPhone?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !p.isEmpty else { return nil }
            // Optional: don’t print phone for team tables
            if (o.customerName.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("שולחן")) { return nil }
            return p
        }()
        // ✅ Single separator derived from lineWidth (keeps Rongta + others identical)
        let sep = String(repeating: "-", count: max(8, lineWidth))

        let caution: String = {
            let name = o.customerName.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty || name.lowercased() == "customer" { return "שם לקוח" }
            return name
        }()

        let orderIdText = "\(o.id)"

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = .current
        df.dateFormat = "HH:mm   dd/MM/yyyy"

        // ✅ Print-time only (real now), ignore placedAt
        let orderMeta1 = df.string(from: Date())
        // ===== STEP 1: Build print items =====
        var rawItems: [PrintItem] = []

        for ln in lines {
            let (sizeWord, modsRest) = extractSize(from: ln.modifiers)
            let cleanName = ln.name.trimmingCharacters(in: .whitespacesAndNewlines)

            let rawModifiers = ln.modifiers ?? ""
            let modsLower = rawModifiers.lowercased()

            let nameWithSize: String = {
                if cleanName == "אספרסו" || cleanName == "מקיאטו" {
                    return modsLower.contains("כפול") ? "\(cleanName) כפול" : cleanName
                }

                if cleanName == "הפוך" || cleanName == "אמריקנו" {
                    if let size = sizeWord, !size.isEmpty { return "\(cleanName) \(size)" }
                    return "\(cleanName) קטן"
                }

                if let size = sizeWord, !size.isEmpty {
                    return "\(cleanName) \(size)"
                }

                return cleanName
            }()

            let modsSource: String = {
                if cleanName == "אספרסו" || cleanName == "מקיאטו" {
                    return removeKeyword("כפול", from: rawModifiers)
                } else {
                    return modsRest
                }
            }()

            let modsClean = breakModifiers(modsSource)

            rawItems.append(
                PrintItem(
                    nameWithSize: nameWithSize,
                    qty: ln.qty,
                    modsClean: modsClean
                )
            )
        }

        // ===== STEP 2: Merge items with same title + no modifiers =====
        var mergedItems: [PrintItem] = []

        for item in rawItems {
            if item.modsClean.isEmpty {
                if let idx = mergedItems.firstIndex(where: {
                    $0.nameWithSize == item.nameWithSize && $0.modsClean.isEmpty
                }) {
                    mergedItems[idx].qty += item.qty
                } else {
                    mergedItems.append(item)
                }
            } else {
                mergedItems.append(item)
            }
        }

        // ===== STEP 3: Build ESC/POS =====
        var job = Data()
        job += EscPos.initPrinter

        // Hebrew codepage per family
        job += escSelectHebrew(family.codePage)

        // Only actually apply ESC { if family supports rotation
        let shouldRotate = rotated && family.supportsRotation
        if shouldRotate {
            job += EscPos.rotate180On
        }

        let rawService = o.service?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let isTakeAwayService =
            rawService == "ta" ||
            rawService.contains("take") ||
            rawService.contains("to-go") ||
            rawService.contains("togo") ||
            rawService.contains("pickup") ||
            rawService.contains("collection")

        let modifierIndent = "  "

        if shouldRotate {
            // ================= ROTATED =================
            job += EscPos.align(1)
            job += EscPos.style(doubleHeight: true, doubleWidth: true, bold: true)
            job += asciiLine(orderIdText)
            job += EscPos.feed(1)

            job += EscPos.align(1)
            job += EscPos.style(doubleHeight: true, doubleWidth: true, bold: true)
            job += hebrewLineData(caution)
            job += EscPos.feed(1)
            
            if let p = o.customerPhone?.trimmingCharacters(in: .whitespacesAndNewlines),
               !p.isEmpty {
                job += EscPos.align(1)
                job += EscPos.style(doubleHeight: false, doubleWidth: true, bold: true)
                job += asciiLine(p)          // ✅ keep digits stable
                job += EscPos.feed(1)
            }

            if isTakeAwayService {
                job += EscPos.feed(1)
                job += makeBlackTitle(taBarText, totalWidth: 24)
                job += EscPos.feed(1)
            }

            job += EscPos.style(doubleHeight: false, doubleWidth: false, bold: false)
            job += EscPos.align(0)
            job += asciiLine(sep)
            job += EscPos.feed(1)

            for item in mergedItems.reversed() {

                if !item.modsClean.isEmpty {
                    job += EscPos.feed(1)
                    job += EscPos.align(2)
                    job += EscPos.style(doubleHeight: false, doubleWidth: true, bold: false)

                    let lines = item.modsClean
                        .split(whereSeparator: { $0 == "\n" || $0 == "\r\n" })
                        .map(String.init)

                    if lines.isEmpty {
                        job += hebrewLineData(modifierIndent + item.modsClean)
                    } else {
                        for m in lines { job += hebrewLineData(modifierIndent + m) }
                    }
                }

                job += EscPos.align(2)
                job += EscPos.style(doubleHeight: true, doubleWidth: true, bold: true)
                job += hebrewLineData("\(item.qty) \(item.nameWithSize)")

                job += EscPos.feed(1)
                job += EscPos.style(doubleHeight: false, doubleWidth: false, bold: false)
                job += EscPos.align(0)
                job += asciiLine(sep)
                job += EscPos.feed(1)
            }

            // ✅ Date / time – BIG (match regular printers)
            job += EscPos.align(1)   // CENTER

            job += EscPos.style(doubleHeight: true,
                                doubleWidth: true,
                                bold: false)
            job += asciiLine(orderMeta1)

            // reset after
            job += EscPos.style(doubleHeight: false,
                                doubleWidth: false,
                                bold: false)
            
            if isTakeAwayService {
                job += EscPos.feed(1)
                job += makeBlackTitle(taBarText, totalWidth: 24)
                job += EscPos.feed(1)
            }

        } else {
            // ================= NON-ROTATED =================
            job += EscPos.align(1)
            job += EscPos.style(doubleHeight: true, doubleWidth: true, bold: true)
            job += asciiLine(orderIdText)
            job += EscPos.feed(1)

            let isTeamTable = caution.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("שולחן")

            if isTeamTable {
                job += EscPos.feed(1)
                job += makeTeamNameFramedLine(caution, totalWidth: 24, capCount: 3) // *** ... ***
                job += EscPos.feed(1)
            } else {
                job += EscPos.align(1)
                job += EscPos.style(doubleHeight: true, doubleWidth: true, bold: true)
                job += hebrewLineData(caution)
                job += EscPos.style(doubleHeight: false, doubleWidth: false, bold: false)
                job += EscPos.align(0)
                job += EscPos.feed(1)
            }

           
            // 🖤 PHONE — BLACK ROW
            if let p = phoneLine {
                job += EscPos.feed(1)
                job += makePhoneFramedLine(p, totalWidth: 24)
                job += EscPos.feed(1)
            }

            job += EscPos.style(doubleHeight: false, doubleWidth: false, bold: false)
            job += EscPos.align(0)
            job += EscPos.feed(1)
            if isTakeAwayService {
                job += EscPos.feed(1)
                job += makeBlackTitle(taBarText, totalWidth: 24)
                job += EscPos.feed(1)
            }

            job += EscPos.align(1)
            job += EscPos.style(doubleHeight: true, doubleWidth: true, bold: false)
            job += asciiLine(orderMeta1)

            job += EscPos.style(doubleHeight: false, doubleWidth: false, bold: false)
            job += EscPos.align(0)
            job += asciiLine(sep)
            job += EscPos.feed(1)

            for item in mergedItems.reversed() {

                job += EscPos.align(2)
                job += EscPos.style(doubleHeight: true, doubleWidth: true, bold: true)
                job += hebrewLineData("\(item.qty) \(item.nameWithSize)")

                if !item.modsClean.isEmpty {
                    job += EscPos.feed(1)
                    job += EscPos.align(2)
                    job += EscPos.style(doubleHeight: false, doubleWidth: true, bold: false)

                    let lines = item.modsClean
                        .split(whereSeparator: { $0 == "\n" || $0 == "\r\n" })
                        .map(String.init)

                    if lines.isEmpty {
                        job += hebrewLineData(modifierIndent + item.modsClean)
                    } else {
                        for m in lines { job += hebrewLineData(modifierIndent + m) }
                    }
                }

                job += EscPos.feed(1)
                job += EscPos.style(doubleHeight: false, doubleWidth: false, bold: false)
                job += EscPos.align(0)
                job += asciiLine(sep)
                job += EscPos.feed(1)
            }

            job += EscPos.align(1)
            job += EscPos.style(doubleHeight: true, doubleWidth: true, bold: true)
            job += asciiLine(orderIdText)
            job += EscPos.feed(1)

            if isTeamTable {
                job += EscPos.feed(1)
                job += makeTeamNameFramedLine(caution, totalWidth: 24, capCount: 3) // *** ... ***
                job += EscPos.feed(1)
            } else {
                job += hebrewLineData(caution)
                job += EscPos.feed(2)
            }

            if isTakeAwayService {
                job += EscPos.feed(1)
                job += makeBlackTitle(taBarText, totalWidth: 24)
                job += EscPos.feed(1)
            }
        }

        // RESET + bottom padding
        job += EscPos.style(doubleHeight: false, doubleWidth: false, bold: false)
        job += EscPos.align(0)
        job += EscPos.feed(6)

        if shouldRotate {
            job += EscPos.rotate180Off
        }

        job += EscPos.cut
        return job
    }
}

fileprivate func breakModifiers(_ mods: String) -> String {
    let raw = mods.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty else { return "" }

    // Split on common separators: "·" "," "•" + newlines
    let seps = CharacterSet(charactersIn: "·,•\n\r")
    let parts = raw
        .components(separatedBy: seps)
        .map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "·• "))
        }
        .filter { !$0.isEmpty }
        .map { token -> String in
            // Remove "title: value" -> "value"
            if let r = token.range(of: ":") {
                return token[token.index(after: r.lowerBound)...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return token
        }
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

    // ✅ Deduplicate while preserving order
    var seen = Set<String>()
    var out: [String] = []
    for p in parts {
        if !seen.contains(p) {
            seen.insert(p)
            out.append(p)
        }
    }

    // ✅ ONE PER ROW (printer already prints each \n on a new line)
    return out.joined(separator: "\n")
}


extension PrinterManager {
    private func containsHebrew(_ s: String) -> Bool {
        return s.range(of: "\\p{Hebrew}", options: .regularExpression) != nil
    }
    
    // MARK: - Hebrew shaping (simple rule: flip entire cell if Hebrew exists)
    private func flipHebrewOnly(_ raw: String) -> String {
        return containsHebrew(raw) ? visualHebrew(raw) : raw
    }
    
    // MARK: - Black title bar
    private func makeBlackTitle(_ text: String, totalWidth: Int = 24) -> Data {
        let rendered = containsHebrew(text) ? visualHebrew(text) : text
        var line = rendered
        
        if line.count < totalWidth {
            let pad = totalWidth - line.count
            let left = pad / 2
            let right = pad - left
            line = String(repeating: " ", count: left) + line
            + String(repeating: " ", count: right)
        } else if line.count > totalWidth {
            line = String(line.prefix(totalWidth))
        }
        
        var d = Data()
        
        // Double size font
        d.append(contentsOf: [0x1D, 0x21, 0x11])
        
        // Reverse ON (white text on black)
        d.append(contentsOf: [0x1D, 0x42, 0x01])
        
        // Print Hebrew (Windows-1255)
        let enc = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.windowsHebrew.rawValue)
        )
        d += (line as NSString).data(using: enc) ?? Data()
        d.append(0x0A)
        
        // Reverse OFF
        d.append(contentsOf: [0x1D, 0x42, 0x00])
        
        // Reset font
        d.append(contentsOf: [0x1D, 0x21, 0x00])
        
        return d
    }
    
    // MARK: - Table row
    // MARK: - Table row
    // MARK: - Table row (supports custom column widths)
    private func makeDebugRow(
        _ columns: [String],
        align: [Character],
        colWidths: [Int]? = nil
    ) -> Data {
        // Default widths (used if no colWidths passed)
        let widths = colWidths ?? [9, 9, 9, 12]
        let totalCols = widths.count
        var parts: [String] = []
        
        for i in 0..<totalCols {
            let raw       = i < columns.count ? columns[i] : ""
            let alignType = i < align.count   ? align[i]   : "L"
            
            var s = flipHebrewOnly(raw)
            let colWidth = widths[i]
            
            if s.count > colWidth {
                s = String(s.prefix(colWidth))
            }
            
            let padding = max(0, colWidth - s.count)
            
            switch alignType {
            case "R":
                s = String(repeating: " ", count: padding) + s
            case "C":
                let left = padding / 2
                let right = padding - left
                s = String(repeating: " ", count: left) + s
                + String(repeating: " ", count: right)
            default:
                s = s + String(repeating: " ", count: padding)
            }
            
            parts.append(s)
        }
        
        let line = parts.joined(separator: " | ")
        
        // 🔍 LOG PREVIEW
        Swift.print("ROW:", line)
        
        if containsHebrew(line) {
            let enc = CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.windowsHebrew.rawValue)
            )
            var d = (line as NSString).data(using: enc) ?? Data()
            d.append(0x0A)
            return d
        } else {
            return asciiLine(line)
        }
    }
    
    // MARK: - Separator (supports custom column widths)
    private func makeDebugSeparator(colWidths: [Int]? = nil) -> Data {
        let widths = colWidths ?? [9, 9, 9, 12]
        // each separator is " | " (3 chars)
        let totalChars = widths.reduce(0, +) + (widths.count - 1) * 3
        let line = String(repeating: "-", count: totalChars)
        return asciiLine(line)
    }
    struct SalesReportData {
        // MARK: - מכירות (Sales)
        var ppaRestaurant: Int          // 26
        var dinersRestaurant: Int       // 14
        var totalRestaurantIncVat: Double  // 375.0
        var ppaRestaurantValue: Double  // 7.713  (the number shown on "מסעדה  7.713")
        
        var ppaTA: Int                  // 22
        var dinersTA: Int               // 8
        var totalTAIncVat: Double       // 317.2
        
        var totalSalesIncVat: Double    // 692.2
        var tipsTotal: Double           // 7.713
        var grandTotal: Double          // 699.9
        
        // MARK: - תקבולים (Collections)
        var cashAmount: Double          // 250.0
        var cashCount: Int              // 3
        
        var cardAmount: Double          // 329.9
        var cardCount: Int              // 5
        
        var collectionsTotalAmount: Double  // 579.9
        var collectionsTotalCount: Int      // 8
        
        // MARK: - דוח מזומן (Cash report)
        var closedDrawersAmount: Double     // הד. סגורות
        var openDrawersAmount: Double       // הד. פתוחות
        var depositWithdrawAmount: Double   // הפקדה/משיכה
        
        var drawerTotalAmount: Double       // סהכ במגירת
        var mainDrawerAmount: Double        // מגירה ראשית
        var hostStationDrawerAmount: Double // עמדת מארחת
        
        // MARK: - תשר (Tips)
        var tipBaseTotal: Double            // row "תשר"
        var tipRestaurant: Double           // שולחנות מסעדה
        var tipBarTakeaway: Double          // בר ולקחת
        
        var extraTipTotal: Double           // עודף טיפ
        var extraTipRestaurant: Double      // מסעדה
        var extraTipBar: Double             // בר
        
        // MARK: - חריגים (Exceptions)
        var ordersOTHAmount: Double
        var ordersOTHCount: Int
        
        var itemsOTHAmount: Double
        var itemsOTHCount: Int
        
        var canceledItemsAmount: Double
        var canceledItemsCount: Int
        
        var refundedItemsAmount: Double
        var refundedItemsCount: Int
        
        var discountsAmount: Double
        var discountsCount: Int
        
        var discountsRefundAmount: Double
        var discountsRefundCount: Int
        
        // You can add more fields later if the layout grows
    }
    
    func printSalesDebugReport(_ data: SalesReportData, vatRate: Double = 0.18) {
        Swift.print("=== DEBUG PRINT (מכירות + תקבולים + דוח מזומן + תשר + חריגים) ===")
        
        func exVat(_ incVat: Double) -> Double {
            guard vatRate > 0 else { return incVat }
            return incVat / (1.0 + vatRate)
        }
        
        func f1(_ v: Double) -> String { String(format: "%.1f", v) }
        func f2(_ v: Double) -> String { String(format: "%.2f", v) }
        
        var job = Data()
        job += EscPos.initPrinter
        job += escSelectHebrew(.tabit)
        
        // ---------- DATE / TIME ----------
        let now = Date()
        
        let tf = DateFormatter()
        tf.locale = Locale(identifier: "he_IL")
        tf.dateFormat = "HH:mm:ss"
        
        let df = DateFormatter()
        df.locale = Locale(identifier: "he_IL")
        df.dateFormat = "dd/MM/yyyy"
        
        let timeText = tf.string(from: now)
        let dateText = df.string(from: now)
        
        // ---------- HEADER ----------
        job.append(contentsOf: [0x1B, 0x21, 0x10])
        job.append(contentsOf: [0x1B, 0x45, 0x01])
        job += makeDebugRow(["Beit Ha'am"], align: ["C"], colWidths: [48])
        job.append(contentsOf: [0x1B, 0x45, 0x00])
        job.append(contentsOf: [0x1B, 0x21, 0x00])
        
        job += makeDebugRow(["בית העם קונדיטוריה ויין בע\"מ"], align: ["C"], colWidths: [48])
        job += makeDebugRow(["ח.פ / ע.מ. 931487615"], align: ["C"], colWidths: [48])
        job += EscPos.feed(1)
        
        job.append(contentsOf: [0x1B, 0x21, 0x10])
        job.append(contentsOf: [0x1B, 0x45, 0x01])
        job += makeDebugRow(["דוח Z"], align: ["C"], colWidths: [48])
        job.append(contentsOf: [0x1B, 0x45, 0x00])
        job.append(contentsOf: [0x1B, 0x21, 0x00])
        
        job += makeDebugRow([dateText], align: ["C"], colWidths: [48])
        job += EscPos.feed(1)
        job += makeDebugRow(["\(timeText) \(dateText)"], align: ["C"], colWidths: [48])
        job += makeDebugSeparator(colWidths: [48])
        
        // ---------- מכירות ----------
        // TYPE | ללא | כולל | סועד | PPA
        let salesWidths = [10, 10, 8, 5, 5]
        
        job += makeBlackTitle("מכירות", totalWidth: 24)
        job += EscPos.feed(1)
        job += makeDebugSeparator(colWidths: salesWidths)
        
        job += makeDebugRow(
            ["סוג", "ללא מע״מ", "כולל מע״מ", "סועד", "PPA"],
            align: ["C","C","C","C","C"],
            colWidths: salesWidths
        )
        job += makeDebugSeparator(colWidths: salesWidths)
        
        // מסעדה
        job += makeDebugRow(
            [
                "מסעדה",
                f1(exVat(data.totalRestaurantIncVat)),
                f1(data.totalRestaurantIncVat),
                "\(data.dinersRestaurant)",
                "\(data.ppaRestaurant)"
            ],
            align: ["R","R","R","R","R"],
            colWidths: salesWidths
        )
        
        // TA
        job += makeDebugRow(
            [
                "TA",
                f1(exVat(data.totalTAIncVat)),
                f1(data.totalTAIncVat),
                "\(data.dinersTA)",
                "\(data.ppaTA)"
            ],
            align: ["R","R","R","R","R"],
            colWidths: salesWidths
        )
        
        // מכירות
        job += makeDebugRow(
            [
                "מכירות",
                f1(exVat(data.totalSalesIncVat)),
                f1(data.totalSalesIncVat),
                "",
                ""
            ],
            align: ["R","R","R","R","R"],
            colWidths: salesWidths
        )
        
        // תשר (no VAT)
        job += makeDebugRow(
            [
                "תשר",
                "",
                f1(data.tipsTotal),
                "",
                ""
            ],
            align: ["R","R","R","R","R"],
            colWidths: salesWidths
        )
        
        // סה״כ
        job += makeDebugRow(
            [
                "סה\"כ",
                f1(exVat(data.grandTotal)),
                f1(data.grandTotal),
                "",
                ""
            ],
            align: ["R","R","R","R","R"],
            colWidths: salesWidths
        )
        
        job += makeDebugSeparator(colWidths: salesWidths)
        
        // ---------- END ----------
        job += EscPos.feed(3)
        job += EscPos.cut
        
        Swift.print("SENDING", job.count, "bytes to printer")
        OneShotPrinter.send(host: activeBakeryIP, port: port, data: job)
    }
    
    // MARK: - Team table: *** (black) + NAME (white) + *** (black)
    private func makeTeamNameFramedLine(_ nameRaw: String, totalWidth: Int = 24, capCount: Int = 3) -> Data {
        let name = nameRaw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Use the same Hebrew behavior as elsewhere
        let rendered = containsHebrew(name) ? visualHebrew(name) : name

        let cap = String(repeating: "*", count: max(1, capCount))
        let innerWidth = max(0, totalWidth - cap.count - cap.count)

        let nameTrimmed: String = {
            if rendered.count <= innerWidth { return rendered }
            return String(rendered.prefix(innerWidth))
        }()

        // Center inside inner area
        let pad = max(0, innerWidth - nameTrimmed.count)
        let leftPad = pad / 2
        let rightPad = pad - leftPad
        let middle = String(repeating: " ", count: leftPad) + nameTrimmed + String(repeating: " ", count: rightPad)

        // Encode everything in Windows-1255 (works for *, spaces, Hebrew)
        let enc = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.windowsHebrew.rawValue)
        )

        func enc1255(_ s: String) -> Data {
            (s as NSString).data(using: enc) ?? Data(s.utf8)
        }

        var d = Data()

        // match your phone/title size
        d.append(contentsOf: [0x1D, 0x21, 0x11]) // GS ! double W+H

        // Reverse ON → left ***
        d.append(contentsOf: [0x1D, 0x42, 0x01])
        d += enc1255(cap)

        // Reverse OFF → middle white
        d.append(contentsOf: [0x1D, 0x42, 0x00])
        d += enc1255(middle)

        // Reverse ON → right ***
        d.append(contentsOf: [0x1D, 0x42, 0x01])
        d += enc1255(cap)

        // Reverse OFF + newline
        d.append(contentsOf: [0x1D, 0x42, 0x00])
        d.append(0x0A)

        // Reset size
        d.append(contentsOf: [0x1D, 0x21, 0x00])

        return d
    }
    // MARK: - Phone: ** (black) + number (white) + ** (black)
    private func makePhoneFramedLine(_ phoneRaw: String, totalWidth: Int = 24) -> Data {
        // Keep digits stable (don’t reverse, don’t Hebrew-shape)
        let phone = phoneRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        
        let leftCap = "*"
        let rightCap = "*"
        let innerWidth = max(0, totalWidth - leftCap.count - rightCap.count)
        
        // If phone too long, keep the last digits (usually what matters)
        let phoneTrimmed: String = {
            if phone.count <= innerWidth { return phone }
            return String(phone.suffix(innerWidth))
        }()
        
        // Center phone inside the inner area
        let pad = max(0, innerWidth - phoneTrimmed.count)
        let leftPad = pad / 2
        let rightPad = pad - leftPad
        let middle = String(repeating: " ", count: leftPad) + phoneTrimmed + String(repeating: " ", count: rightPad)
        
        var d = Data()
        
        // (optional) double-size like your black title
        d.append(contentsOf: [0x1D, 0x21, 0x11]) // GS ! 0x11 (double W + H)
        
        // Reverse ON → print left **
        d.append(contentsOf: [0x1D, 0x42, 0x01]) // GS B 1
        d += Data(leftCap.utf8)
        
        // Reverse OFF → print the phone on white
        d.append(contentsOf: [0x1D, 0x42, 0x00]) // GS B 0
        d += Data(middle.utf8)
        
        // Reverse ON → print right **
        d.append(contentsOf: [0x1D, 0x42, 0x01]) // GS B 1
        d += Data(rightCap.utf8)
        
        // Reverse OFF + newline
        d.append(contentsOf: [0x1D, 0x42, 0x00]) // GS B 0
        d.append(0x0A)
        
        // Reset size
        d.append(contentsOf: [0x1D, 0x21, 0x00])
        
        return d
    }
    // MARK: - MAIN DEMO
    func printSalesReport(
        _ report: PrinterManager.SalesReportData,
        type: CashPointView.ReportType,
        reportDate: Date = Date(),          // ✅ report is FOR this day
        isRestore: Bool = false,            // ✅ true when restoring
        generatedAt: Date = Date()          // ✅ print time (now)
    ) {
        Swift.print("=== PRINT REPORT \(type == .x ? "X" : "Z") ===")
        // ⚠️ Printing adjustment: reduce 1 NIS from tips
        let printTipAdjustment: Double = 0.0
        
        
        // ✅ THIS is what you want to print as "cash" (cash + tips)
        let printedTips = max(report.tipBaseTotal - printTipAdjustment, 0)
        let printedCashWithTip = max(report.cashAmount    , 0)
        
        // ✅ Totals for printing (cash already includes tip now)
        let printedCollectionsTotal = printedCashWithTip + report.cardAmount
        // Recalculate collections total for printing
        // VAT rate comes from your live model mapping (XReport vatRate / ZReport vatRate)
        // If you haven't added it yet, default to 18%.
        let vatRate = 0.18
        
        func exVat(_ incVat: Double) -> Double {
            guard vatRate > 0 else { return incVat }
            return incVat / (1.0 + vatRate)
        }
        func reverseNumber(_ s: String) -> String {
            String(s.reversed())
        }
        
        var job = Data()
        job += EscPos.initPrinter
        job += escSelectHebrew(.tabit)
        
        // ---------- DATE/TIME ----------
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "he_IL")
        timeFormatter.dateFormat = "HH:mm:ss"
        
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "he_IL")
        dateFormatter.dateFormat = "dd/MM/yyyy"
        
        // ✅ Date shown in the big header = report day (restoreDate)
        let reportDateText = dateFormatter.string(from: reportDate)
        
        // ✅ “generated” line uses actual print time
        let genTimeText = timeFormatter.string(from: generatedAt)
        let genDateText = dateFormatter.string(from: generatedAt)
        
        // ---------- HEADER ----------
        job.append(contentsOf: [0x1B, 0x21, 0x10])   // double-height
        job.append(contentsOf: [0x1B, 0x45, 0x01])   // bold ON
        job += makeDebugRow(["Beit Ha'am"], align: ["C"], colWidths: [48])
        job.append(contentsOf: [0x1B, 0x45, 0x00])   // bold OFF
        job.append(contentsOf: [0x1B, 0x21, 0x00])   // reset font
        job += EscPos.feed(1)
        
        job += makeDebugRow(["בית העם קונדיטוריה ויין בע\"מ"], align: ["C"], colWidths: [48])
        job += makeDebugRow(["ח.פ / ע.מ. 516784139"], align: ["C"], colWidths: [48])
        job += EscPos.feed(1)
        
        // Title: X/Z
        job.append(contentsOf: [0x1B, 0x21, 0x10])
        job.append(contentsOf: [0x1B, 0x45, 0x01])
        job += makeDebugRow(["דוח תנועות פעיל \(type == .x ? "X" : "Z")"], align: ["C"], colWidths: [48])
        job.append(contentsOf: [0x1B, 0x45, 0x00])
        job.append(contentsOf: [0x1B, 0x21, 0x00])
        job += EscPos.feed(1)
        
        // ✅ Date big = report date (not today)
        job.append(contentsOf: [0x1B, 0x21, 0x10])
        job.append(contentsOf: [0x1B, 0x45, 0x01])
        job += makeDebugRow([reportDateText], align: ["C"], colWidths: [48])
        job.append(contentsOf: [0x1B, 0x45, 0x00])
        job.append(contentsOf: [0x1B, 0x21, 0x00])
        
        job += EscPos.feed(1)
        
        // ✅ Generated line: restore vs normal
        if isRestore {
            job += makeDebugRow(["\(reportDateText)"], align: ["C"], colWidths: [48])
        } else {
            job += makeDebugRow(["הופק בתאריך \(genDateText) \(genTimeText)"], align: ["C"], colWidths: [48])
        }
        job += makeDebugSeparator(colWidths: [48])
        
        // ---------- SALES ----------
        let salesWidths = [5, 5, 8, 21]
        job += makeBlackTitle("מכירות", totalWidth: 24)
        job += EscPos.feed(1)
        job += makeDebugSeparator(colWidths: salesWidths)
        job += makeDebugRow(["PPA", "סועד", "כולל מעמ", "ללא מעמ"], align: ["C","C","C","C"], colWidths: salesWidths)
        job += makeDebugSeparator(colWidths: salesWidths)
        
        job += makeDebugRow(
            [
                "\(report.ppaRestaurant)",
                "\(report.dinersRestaurant)",
                fmt1(report.totalRestaurantIncVat),
                "מסעדה  \(reverseNumber(fmt1(exVat(report.totalRestaurantIncVat))))"
            ],
            align: ["R","R","R","R"],
            colWidths: salesWidths
        )
        
        job += makeDebugRow(
            [
                "\(report.ppaTA)",
                "\(report.dinersTA)",
                fmt1(report.totalTAIncVat),
                "\(fmt1(exVat(report.totalTAIncVat)))     TA"
            ],
            align: ["R","R","R","R"],
            colWidths: salesWidths
        )
        
        job += makeDebugRow(
            ["", "",
             fmt1(report.totalSalesIncVat),
             "מכירות \(reverseNumber(fmt1(exVat(report.totalSalesIncVat))))"
            ],
            align: ["R","R","R","R"],
            colWidths: salesWidths
        )
        
        job += makeDebugRow(
            ["", "", fmt1(report.tipsTotal), "תשר"],
            align: ["R","R","R","R"],
            colWidths: salesWidths
        )
        
        job += makeDebugRow(
            ["", "",
             fmt1(report.totalSalesIncVat + report.tipsTotal),
             "סה\"כ   \(reverseNumber(fmt1(exVat(report.grandTotal))))"
            ],
            align: ["R","R","R","R"],
            colWidths: salesWidths
        )
        
        job += makeDebugSeparator(colWidths: salesWidths)
        
        // ---------- PAYMENTS ----------
        job += makeBlackTitle("תקבולים", totalWidth: 24)
        job += EscPos.feed(1)
        job += makeDebugSeparator()
        job += makeDebugRow(["סכום","תשלום","סוג","כמות"], align: ["C","C","C","C"])
        job += makeDebugSeparator()
        
        job += makeDebugRow([fmt2(printedCashWithTip), "מזומן", "-", "\(report.cashCount)"], align: ["R","C","C","R"])
        
        job += makeDebugRow([fmt2(report.cardAmount), "אשראי", "-", "\(report.cardCount)"], align: ["R","C","C","R"])
        
        job += makeDebugSeparator()
        job += makeDebugRow([fmt2(printedCollectionsTotal), "סה\"כ", "", "\(report.collectionsTotalCount)"], align: ["R","C","C","R"])
        job += makeDebugSeparator()
        
        // ---------- CASH REPORT ----------
        let cashReportWidths = [8, 14, 17]
        job += makeBlackTitle("דוח מזומן", totalWidth: 24)
        job += EscPos.feed(1)
        job += makeDebugSeparator(colWidths: cashReportWidths)
        job += makeDebugRow(["סכום", "סוג מגירה", "סוג פעולה"], align: ["C","C","C"], colWidths: cashReportWidths)
        
        job += makeDebugSeparator(colWidths: cashReportWidths)
        
        job += makeDebugRow([fmt2(printedCashWithTip), "", "הד. סגורות"], align: ["R","C","R"], colWidths: cashReportWidths)
        
        job += makeDebugRow([fmt1(report.openDrawersAmount), "", "הד. פתוחות"], align: ["R","C","R"], colWidths: cashReportWidths)
        job += makeDebugRow([fmt1(report.depositWithdrawAmount), "", "הפקדה/משיכה"], align: ["R","C","R"], colWidths: cashReportWidths)
        job += makeDebugSeparator(colWidths: cashReportWidths)
        
        job += makeDebugRow([fmt2(printedCashWithTip), "", "סה\"כ במגירה"], align: ["R","C","R"], colWidths: cashReportWidths)
        job += makeDebugRow([fmt2(printedCashWithTip), "מגירה ראשית", ""], align: ["R","R","R"], colWidths: cashReportWidths)
        job += makeDebugRow([fmt1(report.hostStationDrawerAmount), "עמדת מארחת", ""], align: ["R","R","R"], colWidths: cashReportWidths)
        job += makeDebugSeparator(colWidths: cashReportWidths)
        
        // ---------- TIPS ----------
        let tipsWidths = cashReportWidths
        job += makeBlackTitle("תשר", totalWidth: 24)
        job += EscPos.feed(1)
        job += makeDebugSeparator(colWidths: tipsWidths)
        
        job += makeDebugRow([fmt1(report.tipBaseTotal), "", "תשר"], align: ["R","C","R"], colWidths: tipsWidths)
        job += makeDebugRow([fmt1(report.tipRestaurant), "שולחנות מסעדה", ""], align: ["R","R","R"], colWidths: tipsWidths)
        job += makeDebugRow([fmt1(report.tipBarTakeaway), "בר ולקחת", ""], align: ["R","R","R"], colWidths: tipsWidths)
        
        job += makeDebugSeparator(colWidths: tipsWidths)
        
        job += makeDebugRow([fmt1(report.extraTipTotal), "", "עודף טיפ"], align: ["R","C","R"], colWidths: tipsWidths)
        job += makeDebugRow([fmt1(report.extraTipRestaurant), "מסעדה", ""], align: ["R","R","R"], colWidths: tipsWidths)
        job += makeDebugRow([fmt1(report.extraTipBar), "בר", ""], align: ["R","R","R"], colWidths: tipsWidths)
        
        job += makeDebugSeparator(colWidths: tipsWidths)
        
        // ---------- EXCEPTIONS ----------
        let exceptionsWidths = tipsWidths
        job += makeBlackTitle("חריגים", totalWidth: 24)
        job += EscPos.feed(1)
        job += makeDebugSeparator(colWidths: exceptionsWidths)
        
        job += makeDebugRow([fmt1(report.ordersOTHAmount), "\(report.ordersOTHCount)", "הזמנות HTO"], align: ["R","R","R"], colWidths: exceptionsWidths)
        job += makeDebugRow([fmt1(report.itemsOTHAmount), "\(report.itemsOTHCount)", "מנות HTO"], align: ["R","R","R"], colWidths: exceptionsWidths)
        job += makeDebugRow([fmt1(report.canceledItemsAmount), "\(report.canceledItemsCount)", "ביטולי מנות"], align: ["R","R","R"], colWidths: exceptionsWidths)
        job += makeDebugRow([fmt1(report.refundedItemsAmount), "\(report.refundedItemsCount)", "החזרי מנות"], align: ["R","R","R"], colWidths: exceptionsWidths)
        job += makeDebugRow([fmt1(report.discountsAmount), "\(report.discountsCount)", "הנחות"], align: ["R","R","R"], colWidths: exceptionsWidths)
        job += makeDebugRow([fmt1(report.discountsRefundAmount), "\(report.discountsRefundCount)", "החזר הנחות"], align: ["R","R","R"], colWidths: exceptionsWidths)
        
        job += makeDebugSeparator(colWidths: exceptionsWidths)
        
        // ---------- END ----------
        job += EscPos.feed(3)
        job += EscPos.cut
        
        Swift.print("SENDING", job.count, "bytes to printer")
        OneShotPrinter.send(host: activeBakeryIP, port: port, data: job)
    }
    private func fmt1(_ v: Double) -> String { String(format: "%.1f", v) }
    private func fmt2(_ v: Double) -> String { String(format: "%.2f", v) }
    
    
    
    // ✅ STEP: make this return a real ACK so OrdersAutoPrinter can decide markPrinted()

    func printCashPointSplit(
        orderNumber: Int,
        entries: [BasketEntry],
        total: Double,
        diningMode: DiningMode,
        customerName: String?,
        customerPhone: String?
    ) async -> Bool {

        let lines: [KDSOrderLine] = entries.map { entry in
            KDSOrderLine(
                itemId: nil,
                productId: entry.item.id,
                name: entry.item.name,
                qty: entry.quantity,
                category: entry.item.category,
                status: 1,
                station: entry.item.printer,     // ✅ station routing
                modifiers: entry.subtitle
            )
        }

        let order = KDSAdminOrder(
            id: orderNumber,
            source: .kiosk,
            tableLabel: nil,
            bucket: .active,
            stage: .received,
            placedAt: Date(),
            scheduledFor: nil,
            customerName: customerName ?? "",
            customerPhone: customerPhone,
            totalGBP: total,
            itemSummary: "",
            isDelivery: false,
            shortCode: nil,
            lines: lines,
            service: diningMode == .dineIn ? "sit" : "ta",
            name: customerName
        )

        let allLines = order.lines
        let fam = activeFamily

        let kitchenLines = allLines.filter { classifyStation(for: $0) == .kitchen }
        let bakeryLines  = allLines.filter { classifyStation(for: $0) == .bakery }
        let barLines     = allLines.filter { classifyStation(for: $0) == .bar }
        let toastLines   = kitchenLines.filter { isToastLine($0) }

        struct StationAttempt {
            let name: String
            let ok: Bool
        }

        var results: [StationAttempt] = []

        // ✅ KITCHEN
        if !kitchenLines.isEmpty {
            let job = makeJob(order: order, lines: kitchenLines, rotated: fam.supportsRotation, family: fam, lineWidth: 42)
            let ok = await OneShotPrinter.sendAwait(
                host: activeKitchenIP,
                port: port,
                data: job,
                tag: "bone|\(order.id)|kitchen",
                dedupeKey: "bone|\(order.id)|kitchen"
            )
            results.append(.init(name: "Kitchen", ok: ok))
        }

        // ✅ KITCHENBACK (toast only)
        if !toastLines.isEmpty {
            let dk = "bone|\(order.id)|kitchenback|toast"

            let job = makeJob(
                order: order,
                lines: toastLines,
                rotated: kitchenBackRotated,
                family: kitchenBackFamily,
                lineWidth: kitchenBackLineWidth
            )

            let ok = await OneShotPrinter.sendAwait(
                host: KitchenBackPrinterIP,
                port: port,
                data: job,
                tag: dk,
                dedupeKey: dk
            )

            results.append(.init(name: "KitchenBack", ok: ok))
        }

        // ✅ BAKERY
        if !bakeryLines.isEmpty {
            let dk = "bone|\(order.id)|bakery"

            let job = makeJob(
                order: order,
                lines: bakeryLines,
                rotated: fam.supportsRotation,
                family: fam,
                lineWidth: 42
            )

            let ok = await OneShotPrinter.sendAwait(
                host: activeBakeryIP,
                port: port,
                data: job,
                tag: dk,
                dedupeKey: dk
            )

            results.append(.init(name: "Bakery", ok: ok))
        }
        // ✅ BAR
        if !barLines.isEmpty {
            let dk = "bone|\(order.id)|bar"
            let job = makeJob(
                order: order,
                lines: barLines,
                rotated: fam.supportsRotation,
                family: fam,
                lineWidth: 42
            )

            let ok = await OneShotPrinter.sendAwait(
                host: activeBarIP,
                port: port,
                data: job,
                tag: dk,
                dedupeKey: dk
            )

            results.append(.init(name: "Bar", ok: ok))
        }

        let failed = results.filter { !$0.ok }.map(\.name)
        if !failed.isEmpty {
            Swift.print("🛑 printCashPointSplit FAILED order=\(order.id) stations=\(failed)")
            return false
        }

        return true
    }
    
    
    
}

fileprivate func serviceLabel(from raw: String?) -> String {
    switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "sit", "dinein", "dine_in", "dine-in", "table", "eat-in", "eatin":
        return "לשבת"
    case "ta", "takeaway", "take_away", "take-away",
         "collection", "pickup", "pick_up", "pick-up",
         "to-go", "togo":
        return "לקחת"
    default:
        return "לשבת"
    }
}

fileprivate func extractSize(from modifiers: String?) -> (size: String?, rest: String) {
    guard var mods = modifiers?.trimmingCharacters(in: .whitespacesAndNewlines),
          !mods.isEmpty else {
        return (nil, "")
    }

    func clean(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "·,• "))
    }

    // ✅ include "•" in the separator class
    let patterns = [
        #"(?i)(^|[·,•\s])גודל\s*:?\s*([^·,•\n]+)"#,
        #"(?i)(^|[·,•\s])size\s*:?\s*([^·,•\n]+)"#
    ]

    for pattern in patterns {
        if let rx = try? NSRegularExpression(pattern: pattern, options: []) {
            let range = NSRange(mods.startIndex..<mods.endIndex, in: mods)
            if let m = rx.firstMatch(in: mods, options: [], range: range),
               m.numberOfRanges >= 3,
               let capRange = Range(m.range(at: 2), in: mods) {

                let sizeVal = clean(String(mods[capRange]))

                // remove the matched "גודל: X" segment
                if let fullRange = Range(m.range(at: 0), in: mods) {
                    mods.removeSubrange(fullRange)
                }

                // ✅ also remove any OTHER occurrences of size (like after "•")
                if !sizeVal.isEmpty {
                    let escaped = NSRegularExpression.escapedPattern(for: sizeVal)
                    let removeAgain = #"(?i)(^|[·,•\s])גודל\s*:?\s*\#(escaped)"#
                    if let rx2 = try? NSRegularExpression(pattern: removeAgain, options: []) {
                        let r2 = NSRange(mods.startIndex..<mods.endIndex, in: mods)
                        mods = rx2.stringByReplacingMatches(in: mods, options: [], range: r2, withTemplate: " ")
                    }
                }

                let restClean = clean(mods)
                return (sizeVal.isEmpty ? nil : sizeVal, restClean)
            }
        }
    }

    // Fallback: detect plain tokens like "גדול/קטן"
    let keywords = ["קטן","בינוני","גדול","ענק","Small","Medium","Large","S","M","L"]
    for kw in keywords {
        let pattern = #"(?i)\b\#(NSRegularExpression.escapedPattern(for: kw))\b"#
        if let rx = try? NSRegularExpression(pattern: pattern, options: []) {
            let range = NSRange(mods.startIndex..<mods.endIndex, in: mods)
            if rx.firstMatch(in: mods, options: [], range: range) != nil {
                mods = rx.stringByReplacingMatches(in: mods, options: [], range: range, withTemplate: " ")
                return (kw, clean(mods))
            }
        }
    }

    return (nil, clean(mods))
}

fileprivate extension Optional where Wrapped == UInt16 {
    func nonZeroOrDefault(_ def: UInt16) -> UInt16 {
        switch self {
        case .some(let v) where v != 0: return v
        default: return def
        }
    }
}

fileprivate func removeGroupTitles(from mods: String) -> String {
    let tokens = mods
        .components(separatedBy: CharacterSet(charactersIn: "·,"))
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .map { token in
            if let r = token.range(of: #"^[^:]{1,30}:\s*"#, options: .regularExpression) {
                return token[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let r = token.range(of: #"^\(([^:]{1,30}):\s*"#, options: .regularExpression) {
                var t = token
                t.removeSubrange(r)
                return t.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return token
        }

    return tokens.joined(separator: " · ")
}


struct InvoiceItem {
    let name: String
    let quantity: Int
    let unitPrice: Double

    var lineTotal: Double {
        Double(quantity) * unitPrice
    }
}


// MARK: - API row (matches /api/zreports/daily output)
struct DailyReportApiRow: Decodable {
    let date: Date

    let grossTotal: Double
    let netTotal: Double
    let vatTotal: Double

    let cashTotal: Double
    let cardTotal: Double
    let paymentsTotal: Double

    let totalTips: Double
    let cashTips: Double
    let cardTips: Double

    let ordersCount: Int
    let taCount: Int
    let taGross: Double
    let restaurantCount: Int
    let restaurantGross: Double

    let cashCount: Int
    let cardCount: Int
    let mixedCount: Int
    let missingPaymentCount: Int

    enum CodingKeys: String, CodingKey {
        case date = "Date"
        case grossTotal = "GrossTotal"
        case netTotal = "NetTotal"
        case vatTotal = "VATTotal"
        case cashTotal = "CashTotal"
        case cardTotal = "CardTotal"
        case paymentsTotal = "PaymentsTotal"
        case totalTips = "TotalTips"
        case cashTips = "CashTips"
        case cardTips = "CardTips"
        case ordersCount = "OrdersCount"
        case taCount = "TaCount"
        case taGross = "TaGross"
        case restaurantCount = "RestaurantCount"
        case restaurantGross = "RestaurantGross"
        case cashCount = "CashCount"
        case cardCount = "CardCount"
        case mixedCount = "MixedCount"
        case missingPaymentCount = "MissingPaymentCount"
    }
}

// MARK: - Map API -> your existing SalesReportData
 extension PrinterManager.SalesReportData {
    static func fromDaily(_ r: DailyReportApiRow) -> PrinterManager.SalesReportData {

        // ✅ precise PPA value (Double) for restaurant (required by your init)
        let ppaRestaurantValue: Double =
            r.restaurantCount > 0 ? (r.restaurantGross / Double(r.restaurantCount)) : 0

        // ✅ TA ppa is only Int in your struct
        let ppaTAInt: Int =
            r.taCount > 0 ? Int((r.taGross / Double(r.taCount)).rounded()) : 0

        // Collections (unique paying orders)
        let collectionsUnique = max(0, r.cashCount + r.cardCount - r.mixedCount)

        return PrinterManager.SalesReportData(
            // ⚠️ order MUST match your initializer labels:
            ppaRestaurant: Int(ppaRestaurantValue.rounded()),
            dinersRestaurant: r.restaurantCount,
            totalRestaurantIncVat: r.restaurantGross,
            ppaRestaurantValue: ppaRestaurantValue,

            ppaTA: ppaTAInt,
            dinersTA: r.taCount,
            totalTAIncVat: r.taGross,

            totalSalesIncVat: r.grossTotal,
            tipsTotal: r.totalTips,
            grandTotal: r.grossTotal + r.totalTips,

            // ⚠️ your init expects cashAmount, cashCount, cardAmount, cardCount (this order)
            cashAmount: r.cashTotal,
            cashCount: r.cashCount,
            cardAmount: r.cardTotal,
            cardCount: r.cardCount,

            collectionsTotalAmount: r.paymentsTotal,
            collectionsTotalCount: collectionsUnique,

            // Not yet wired from API → keep zero for preview
            closedDrawersAmount: 0,
            openDrawersAmount: 0,
            depositWithdrawAmount: 0,
            drawerTotalAmount: 0,
            mainDrawerAmount: 0,
            hostStationDrawerAmount: 0,

            // tips breakdown (not wired yet)
            tipBaseTotal: r.totalTips,
            tipRestaurant: 0,
            tipBarTakeaway: 0,
            extraTipTotal: 0,
            extraTipRestaurant: 0,
            extraTipBar: 0,

            // exceptions (not wired yet)
            ordersOTHAmount: 0, ordersOTHCount: 0,
            itemsOTHAmount: 0, itemsOTHCount: 0,
            canceledItemsAmount: 0, canceledItemsCount: 0,
            refundedItemsAmount: 0, refundedItemsCount: 0,
            discountsAmount: 0, discountsCount: 0,
            discountsRefundAmount: 0, discountsRefundCount: 0
        )
    }
}

extension EscPos {

    // MARK: - ESC/POS QR (native GS ( k)

    enum QREcc: UInt8 {
        case L = 48   // 7%
        case M = 49   // 15%
        case Q = 50   // 25%
        case H = 51   // 30%
    }

    /// Native QR (GS ( k) - works on most 80mm ESC/POS printers (Rongta/XP/TM-T20 class).
    /// - Parameters:
    ///   - text: payload (UTF-8)
    ///   - size: module size 1...16 (typical 4...8)
    ///   - ecc: error correction
    ///   - center: prints centered (ESC a 1) by default
    ///   - model2: usually correct; some printers accept only model2
    static func qrNative(
        _ text: String,
        size: UInt8 = 6,
        ecc: QREcc = .M,
        center: Bool = true,
        model2: Bool = true
    ) -> Data {
        let payload = Data(text.utf8)

        // Helper: build GS ( k command
        func gs_k(_ cn: UInt8, _ fn: UInt8, _ m: UInt8, data: Data = Data()) -> Data {
            // pL pH = (data.count + 3) little-endian
            let len = data.count + 3
            let pL = UInt8(len & 0xFF)
            let pH = UInt8((len >> 8) & 0xFF)

            var d = Data([0x1D, 0x28, 0x6B, pL, pH, cn, fn, m])
            d.append(data)
            return d
        }

        var out = Data()

        if center { out += EscPos.align(1) }

        // 1) Select model
        // cn=49 (0x31), fn=65 (0x41)
        // m = 49 => model 1, 50 => model 2
        out += gs_k(0x31, 0x41, model2 ? 0x32 : 0x31, data: Data([0x00]))

        // 2) Set module size
        // cn=49, fn=67, m=size (1..16)
        let clampedSize = max(1, min(16, Int(size)))
        out += gs_k(0x31, 0x43, UInt8(clampedSize))

        // 3) Set error correction
        // cn=49, fn=69, m=ecc (48..51)
        out += gs_k(0x31, 0x45, ecc.rawValue)

        // 4) Store data
        // cn=49, fn=80, m=48, data=payload
        out += gs_k(0x31, 0x50, 0x30, data: payload)

        // 5) Print
        // cn=49, fn=81, m=48
        out += gs_k(0x31, 0x51, 0x30)

        out += EscPos.feed(1)

        if center { out += EscPos.align(0) }

        return out
    }

    // MARK: - QR as IMAGE fallback (CIQRCodeGenerator + raster)

    static func qrImageRaster(
        _ text: String,
        maxWidthDots: Int = 384,   // 58mm=384, 80mm=576 (you use 576 elsewhere)
        center: Bool = true
    ) -> Data {
        guard let img = makeQRImage(text: text) else { return Data() }

        var out = Data()
        if center { out += EscPos.align(1) }
        out += EscPos.raster(img, maxWidthDots: maxWidthDots)
        out += EscPos.feed(1)
        if center { out += EscPos.align(0) }
        return out
    }

    private static func makeQRImage(text: String) -> UIImage? {
        let data = Data(text.utf8)
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel") // L/M/Q/H

        guard let output = filter.outputImage else { return nil }

        // Scale up (avoid blurry QR)
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))

        let ctx = CIContext(options: nil)
        guard let cg = ctx.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

extension PrinterManager {

    func printHebrewLoyaltySlipV2(
        earnedStamps: Int,
        qrPayload: String,
        station: Station = .bakery,
        useNativeQR: Bool = true
    ) {
        let host: String = {
            switch station {
            case .kitchen: return activeKitchenIP
            case .bar:     return activeBarIP
            case .bakery:  return activeBakeryIP
            }
        }()

        let fam = activeFamily

        var job = Data()
        job += EscPos.initPrinter
        job += escSelectHebrew(fam.codePage)

        // ===== TITLE (smaller, bold) =====
        job += EscPos.align(1)
        job += EscPos.style(doubleHeight: true, doubleWidth: true, bold: true)
        job += hebrewLineData("·· החברים של בית העם ··")   // my favorite
        job += EscPos.feed(1)
        job += EscPos.feed(1)
        

        // ===== EARNED (big) =====
        job += EscPos.style(doubleHeight: true, doubleWidth: true, bold: true)
        job += hebrewLineData("הרווחת \(earnedStamps) חותמות")
        job += EscPos.feed(1)

        // A little breathing room before QR
        job += EscPos.feed(1)
        job += EscPos.style(doubleHeight: true, doubleWidth: true, bold: true)
        job += hebrewLineData("סרקו להוספה לכרטיסיה")
        job += EscPos.feed(1)
        // ===== QR =====
        if useNativeQR {
            job += EscPos.qrNative(qrPayload, size: 7, ecc: .M, center: true, model2: true)
        } else {
            job += EscPos.qrImageRaster(qrPayload, maxWidthDots: 576, center: true)
        }

        // ===== UNDER QR (big) =====
        job += EscPos.feed(1)
        job += EscPos.align(1)
       
        // ===== END =====
        job += EscPos.style(doubleHeight: false, doubleWidth: false, bold: false)
        job += EscPos.feed(3)
        job += EscPos.cut

        let dk = "loyalty.he.v2|\(earnedStamps)|\(qrPayload.hashValue)"
        Swift.print("🎟️ [PrinterManager] printHebrewLoyaltySlipV2 → \(station) \(host):\(port)")
        OneShotPrinter.send(host: host, port: port, data: job, tag: dk, dedupeKey: dk)
    }
}
