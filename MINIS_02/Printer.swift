import Foundation
import Combine
import Network
import SwiftUI

@MainActor
final class PrinterReachabilityMonitor: ObservableObject {

    struct Printer: Identifiable, Hashable {
        let id = UUID()
        let name: String
        let host: String   // IP or hostname
        let port: UInt16   // usually 9100 for ESC/POS
    }

    struct StatusRow: Identifiable {
        let id = UUID()
        let printer: Printer
        let isReachable: Bool
        let detail: String
    }

    @Published private(set) var isNetworkUp: Bool = true
    @Published private(set) var rows: [StatusRow] = []
    @Published private(set) var isReadyToPrint: Bool = false
    @Published private(set) var lastCheckedAt: Date? = nil

    private let printers: [Printer]
    private let pathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "printers.path.monitor")

    private var checkTask: Task<Void, Never>? = nil

    init(printers: [Printer]) {
        self.printers = printers
        startPathMonitor()
        startPolling()
    }

    deinit {
        pathMonitor.cancel()
        checkTask?.cancel()
    }
    
    var allPrintersOnline: Bool {
        !rows.isEmpty && rows.allSatisfy { $0.isReachable }
    }

    var anyPrinterOffline: Bool {
        rows.contains { !$0.isReachable }
    }

    var offlineCount: Int {
        rows.filter { !$0.isReachable }.count
    }

    private func startPathMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }

            Task { @MainActor in
                let up = (path.status == .satisfied)
                self.isNetworkUp = up

                if !up {
                    // Neutral state: don’t scream “offline” if we’re just not on the printer network
                    self.isReadyToPrint = false
                    // Optional: clear rows so UI looks neutral until we can re-check
                    // self.rows = []
                    return
                }

                // ✅ Network is back: re-check immediately (no waiting 30–60s)
                await self.checkNow()
            }
        }
        pathMonitor.start(queue: monitorQueue)
    }

    private func startPolling() {
        checkTask?.cancel()
        checkTask = Task { [weak self] in
            guard let self else { return }
            // First check immediately
            await self.checkNow()

            // Then poll every 3 seconds (lightweight)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000_000)
                //await self.checkNow()
            }
        }
    }

    func checkNow() async {
        let results = await withTaskGroup(of: StatusRow.self, returning: [StatusRow].self) { group in
            for p in printers {
                group.addTask {
                    await Self.check(printer: p)
                }
            }
            var out: [StatusRow] = []
            for await r in group { out.append(r) }
            return out
        }

        // stable ordering
        let sorted = results.sorted { $0.printer.name < $1.printer.name }

        rows = sorted
        isReadyToPrint = allPrintersOnline
        lastCheckedAt = Date()
    }

    private static func check(printer: Printer) async -> StatusRow {
        let host = NWEndpoint.Host(printer.host)
        let port = NWEndpoint.Port(rawValue: printer.port) ?? .init(integerLiteral: 9100)

        let conn = NWConnection(host: host, port: port, using: .tcp)

        return await withCheckedContinuation { cont in
            var finished = false

            func finish(_ ok: Bool, _ detail: String) {
                guard !finished else { return }
                finished = true
                conn.cancel()
                cont.resume(returning: StatusRow(printer: printer, isReachable: ok, detail: detail))
            }

            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(true, "Online")
                case .failed(let err):
                    finish(false, "Offline (\(err))")
                default:
                    break
                }
            }

            conn.start(queue: DispatchQueue.global(qos: .utility))

            // timeout
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.2) {
                finish(false, "Timeout")
            }
        }
    }
    
    func testPrintAllReachable() async {
        // Only printers that are currently reachable
        let targets = rows.filter { $0.isReachable }.map(\.printer)
        guard !targets.isEmpty else { return }

        for p in targets {
            await Self.sendTestTicket(to: p)
        }
    }

    private static func sendTestTicket(to printer: Printer) async {
        let host = NWEndpoint.Host(printer.host)
        let port = NWEndpoint.Port(rawValue: printer.port) ?? .init(integerLiteral: 9100)

        let conn = NWConnection(host: host, port: port, using: .tcp)

        // Minimal ESC/POS test
        var data = Data()
        data += Data([0x1B, 0x40]) // ESC @ (init)
        data += "\n".data(using: .utf8)!
        data += "TEST BONE\n".data(using: .utf8)!
        data += "\(printer.name)\n".data(using: .utf8)!
        data += "\(Date())\n".data(using: .utf8)!
        data += "\n\n".data(using: .utf8)!
        data += Data([0x1D, 0x56, 0x41, 0x10]) // GS V A n  (partial cut, n=16)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            var finished = false

            func finish() {
                guard !finished else { return }
                finished = true
                conn.cancel()
                cont.resume()
            }

            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.send(content: data, completion: .contentProcessed { _ in
                        finish()
                    })
                case .failed:
                    finish()
                default:
                    break
                }
            }

            conn.start(queue: DispatchQueue.global(qos: .utility))

            // Timeout safety
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.0) {
                finish()
            }
        }
    }
}
