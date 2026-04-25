import Foundation
import Network
import UIKit
import CoreFoundation
import SwiftUI

// ============================================================
//  RongtaPlaceholderTicketDebug.swift
//  Minimal placeholder ticket print for Rongta 10.100.10.221
//  ✅ WIN-1255 + VISUAL REVERSE (confirmed working)
//  All helpers are DBG-suffixed to avoid collisions.
// ============================================================

// MARK: - Minimal View

struct RongtaPlaceholderTicketDebugView: View {
    @State private var isPrinting = false
    @State private var status: String = "Idle"

    var body: some View {
        VStack(spacing: 12) {
            Text("Rongta Placeholder Ticket")
                .font(.headline)

            Text("\(RongtaPlaceholderPrinterDBG.host):\(RongtaPlaceholderPrinterDBG.port)")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button {
                guard !isPrinting else { return }
                isPrinting = true
                status = "Printing…"

                RongtaPlaceholderPrinterDBG.printPlaceholderTicket { ok, bytes, reason in
                    DispatchQueue.main.async {
                        status = ok ? "✅ Sent (\(bytes))" : "🛑 Failed: \(reason) (\(bytes))"
                        isPrinting = false
                    }
                }
            } label: {
                Text(isPrinting ? "Printing…" : "🧾 Print Placeholder Ticket")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isPrinting)

            Text(status)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }
}

// MARK: - Printer

enum RongtaPlaceholderPrinterDBG {

    static let host = "172.22.239.232"
    static let port: UInt16 = 9100

    static func printPlaceholderTicket(completion: ((Bool, Int, String) -> Void)? = nil) {
        Task {
            let job = buildPlaceholderTicket()
            let (ok, reason) = await send2(host: host, port: port, data: job, connectTimeout: 5.0, sendTimeout: 6.0)
            completion?(ok, job.count, reason)
        }
    }
    
    
    static func send2(host: String, port: UInt16, data: Data, connectTimeout: TimeInterval, sendTimeout: TimeInterval) async -> (Bool, String) {
        await withCheckedContinuation { cont in
            let c = NWConnection(host: .init(host),
                                 port: .init(rawValue: port) ?? 9100,
                                 using: .tcp)

            var finished = false
            func finish(_ ok: Bool, _ reason: String) {
                guard !finished else { return }
                finished = true
                c.stateUpdateHandler = nil
                c.cancel()
                cont.resume(returning: (ok, reason))
            }

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + connectTimeout) {
                finish(false, "connect timeout \(connectTimeout)s")
            }

            c.stateUpdateHandler = { st in
                switch st {
                case .ready:
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + sendTimeout) {
                        finish(false, "send timeout \(sendTimeout)s")
                    }

                    c.send(content: data, completion: .contentProcessed { err in
                        if let err { finish(false, "send error: \(err)"); return }
                        c.send(content: nil, completion: .contentProcessed { berr in
                            if let berr { finish(false, "barrier error: \(berr)"); return }
                            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.35) {
                                finish(true, "sent + barrier")
                            }
                        })
                    })

                case .failed(let e):
                    finish(false, "failed: \(e)")
                case .waiting(let e):
                    finish(false, "waiting: \(e)")
                case .cancelled:
                    finish(false, "cancelled")
                default:
                    break
                }
            }

            c.start(queue: .global(qos: .utility))
        }
    }

    static func buildPlaceholderTicket() -> Data {
        // ✅ What we print is already VISUAL (reversed) before encoding
        func he(_ s: String) -> Data { win1255LineDataDBG(visualHebrewDBG(s)) }

        let orderId = "1042"
        let time = "19:45"
        let date = "22/02/2026"

        let customer = "אומר"
        let table = "שולחן 12"

        let items: [(Int, String, String?)] = [
            (2, "הפוך קטן", "שיבולת שועל"),
            (1, "אספרסו כפול", nil),
            (1, "טוסט גבינות", "בלי עגבניה")
        ]

        let sep = String(repeating: "-", count: 42)

        var job = Data()
        job += EscPosDBG.initPrinter

        // Choose the printer's Hebrew codepage (keep your known default; reversal+win1255 is the key)
        // Many Rongta firmwares are fine with this left as-is; you can keep 33 if you want:
        job.append(contentsOf: [0x1B, 0x74, 33]) // ESC t 33

        // Title
        job += EscPosDBG.align(1)
        job += EscPosDBG.style(doubleHeight: true, doubleWidth: true, bold: true)
        job += asciiLineDBG(orderId)
        job += EscPosDBG.feed(1)

        // Customer / table
        job += EscPosDBG.style(doubleHeight: true, doubleWidth: true, bold: true)
        job += he(customer)
        job += EscPosDBG.feed(1)

        job += EscPosDBG.style(doubleHeight: false, doubleWidth: true, bold: true)
        job += he(table)
        job += EscPosDBG.feed(1)

        // Date/time (keep digits stable, no reverse)
        job += EscPosDBG.style(doubleHeight: false, doubleWidth: false, bold: false)
        job += EscPosDBG.align(1)
        job += asciiLineDBG("\(time)   \(date)")
        job += EscPosDBG.feed(1)

        // Items
        job += EscPosDBG.align(0)
        job += asciiLineDBG(sep)
        job += EscPosDBG.feed(1)

        for (qty, name, mods) in items {
            job += EscPosDBG.align(2) // right
            job += EscPosDBG.style(doubleHeight: true, doubleWidth: true, bold: true)
            job += he("\(qty) \(name)")

            if let mods, !mods.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                job += EscPosDBG.feed(1)
                job += EscPosDBG.style(doubleHeight: false, doubleWidth: true, bold: false)
                job += he("  \(mods)")
            }

            job += EscPosDBG.feed(1)
            job += EscPosDBG.style(doubleHeight: false, doubleWidth: false, bold: false)
            job += EscPosDBG.align(0)
            job += asciiLineDBG(sep)
            job += EscPosDBG.feed(1)
        }

        // Footer
        job += EscPosDBG.align(1)
        job += EscPosDBG.feed(2)
        job += EscPosDBG.style(doubleHeight: false, doubleWidth: false, bold: false)
        job += he("תודה ובהצלחה")
        job += EscPosDBG.feed(4)
        job += EscPosDBG.cut

        return job
    }

    // MARK: - TCP send (minimal)

    static func send(host: String, port: UInt16, data: Data, connectTimeout: TimeInterval, sendTimeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { cont in
            let c = NWConnection(host: .init(host),
                                 port: .init(rawValue: port) ?? 9100,
                                 using: .tcp)

            var finished = false
            func finish(_ ok: Bool, _ reason: String) {
                guard !finished else { return }
                finished = true
                c.stateUpdateHandler = nil
                c.cancel()
                cont.resume(returning: ok)
            }

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + connectTimeout) {
                finish(false, "connect timeout \(connectTimeout)s")
            }

            c.stateUpdateHandler = { st in
                switch st {
                case .ready:
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + sendTimeout) {
                        finish(false, "send timeout \(sendTimeout)s")
                    }

                    c.send(content: data, completion: .contentProcessed { err in
                        if let err {
                            finish(false, "send error: \(err)")
                            return
                        }
                        c.send(content: nil, completion: .contentProcessed { berr in
                            if let berr {
                                finish(false, "barrier error: \(berr)")
                                return
                            }
                            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.35) {
                                finish(true, "sent + barrier")
                            }
                        })
                    })

                case .failed(let e):
                    finish(false, "failed: \(e)")
                case .waiting(let e):
                    finish(false, "waiting: \(e)")
                case .cancelled:
                    finish(false, "cancelled")
                default:
                    break
                }
            }

            c.start(queue: DispatchQueue.global(qos: .utility))
        }
    }
}

// MARK: - ESC/POS helpers (DBG)

struct EscPosDBG {
    static let initPrinter = Data([0x1B, 0x40])
    static func feed(_ n: UInt8) -> Data { Data([0x1B, 0x64, n]) }
    static let cut = Data([0x1D, 0x56, 0x01])

    static func align(_ mode: UInt8) -> Data { Data([0x1B, 0x61, mode]) } // 0 left 1 center 2 right

    static func style(doubleHeight: Bool = false,
                      doubleWidth: Bool = false,
                      bold: Bool = false) -> Data {
        var flags: UInt8 = 0
        if doubleHeight { flags |= 0x10 }
        if doubleWidth  { flags |= 0x20 }
        var d = Data()
        d.append(contentsOf: [0x1B, 0x21, flags])        // ESC ! n
        d.append(contentsOf: [0x1B, 0x45, bold ? 1 : 0]) // ESC E n
        return d
    }
}

// MARK: - Encoding helpers (DBG)

func asciiLineDBG(_ s: String) -> Data { Data((s + "\n").utf8) }

func visualHebrewDBG(_ s: String) -> String {
    String(s.reversed())
}

func win1255LineDataDBG(_ s: String) -> Data {
    let enc = CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.windowsHebrew.rawValue)
    )
    if let d = (s as NSString).data(using: enc) { return d + Data([0x0A]) }
    return Data((s + "\n").utf8)
}
