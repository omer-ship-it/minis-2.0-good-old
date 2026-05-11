import SwiftUI
import Network
import UIKit
import Foundation

// ============================================================
//  PrinterNetworkAlerts.swift
//  Elegant cashier-facing alerts when the iPad/iPhone hops to
//  the wrong WiFi (e.g. "Tabit Haam" instead of "Beit Haam") and
//  ESC/POS tickets stop printing.
//
//  Three escalating layers, all wired to PrinterReachabilityMonitor:
//    1) PrinterOfflineBanner   — sticky strip above the cart while
//       the basket is non-empty and the LAN/printers are unreachable.
//    2) PrinterOfflineModal    — confirmation dialog you fire at the
//       *moment of print* when offline; offers "open WiFi" or
//       "save & auto-print when network returns".
//    3) PrinterRecoveredToast  — 2s auto-dismiss confirmation that
//       fires when the printer LAN flips back online after being
//       offline; closes the loop for the cashier.
//
//  Drop-in usage in Cashpoint.swift:
//
//      ZStack(alignment: .top) {
//          ...existing content...
//      }
//      .printerNetworkAlerts(
//          monitor: printerMonitor,
//          basketIsEmpty: basket.isEmpty,
//          isRtl: isRtl
//      )
//
//  And, at the moment of print, gate completeOrder() with:
//
//      if !printerMonitor.isReadyToPrint {
//          showPrinterOfflineModal = true
//          return
//      }
// ============================================================

// MARK: - Strings (Hebrew RTL primary, English fallback)

enum PrinterNetCopy {
    static func bannerTitle(isRtl: Bool, ssid: String?) -> String {
        if isRtl {
            if let s = ssid, !s.isEmpty { return "מחוברים ל־\(s) — לא ברשת המדפסות" }
            return "לא מחוברים לרשת המדפסות"
        } else {
            if let s = ssid, !s.isEmpty { return "On \(s) — not on the printer network" }
            return "Not on the printer network"
        }
    }

    static func bannerSubtitle(isRtl: Bool, expectedSSID: String) -> String {
        isRtl
            ? "עברו ל־\(expectedSSID) כדי שהזמנות יודפסו."
            : "Switch to \(expectedSSID) so tickets can print."
    }

    static func openWiFi(isRtl: Bool) -> String {
        isRtl ? "פתח Wi-Fi" : "Open Wi-Fi"
    }

    static func modalTitle(isRtl: Bool) -> String {
        isRtl ? "לא ניתן להדפיס כרגע" : "Can't print right now"
    }

    static func modalBody(isRtl: Bool, currentSSID: String?, expectedSSID: String) -> String {
        if isRtl {
            if let s = currentSSID, !s.isEmpty {
                return "המכשיר על \(s). עברו ל־\(expectedSSID) — ההזמנה תישמר ותודפס אוטומטית כשהרשת תחזור."
            }
            return "המכשיר אינו ברשת המדפסות. ההזמנה תישמר ותודפס אוטומטית כשהרשת תחזור."
        } else {
            if let s = currentSSID, !s.isEmpty {
                return "Connected to \(s). Switch to \(expectedSSID) — the order is saved and will print as soon as the network returns."
            }
            return "Device isn't on the printer network. The order is saved and will print as soon as the network returns."
        }
    }

    static func saveAndAutoPrint(isRtl: Bool) -> String {
        isRtl ? "שמור והדפס אוטומטית" : "Save and auto-print"
    }

    static func cancel(isRtl: Bool) -> String {
        isRtl ? "ביטול" : "Cancel"
    }

    static func recoveredToast(isRtl: Bool) -> String {
        isRtl ? "חזרנו לרשת. ההזמנות שבתור הודפסו ✓" : "Back online. Queued tickets printed ✓"
    }
}

// MARK: - Local network helpers

enum LocalNetworkInfo {
    /// IPv4 address for the active WiFi interface ("en0"), if any.
    static func currentIPv4() -> String? {
        var addresses: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            let flags = Int32(p.pointee.ifa_flags)
            let family = p.pointee.ifa_addr.pointee.sa_family
            if (flags & (IFF_UP|IFF_RUNNING|IFF_LOOPBACK)) == (IFF_UP|IFF_RUNNING),
               family == UInt8(AF_INET) {
                let name = String(cString: p.pointee.ifa_name)
                if name == "en0" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(p.pointee.ifa_addr,
                                   socklen_t(p.pointee.ifa_addr.pointee.sa_len),
                                   &hostname,
                                   socklen_t(NI_MAXHOST),
                                   nil, 0, NI_NUMERICHOST) == 0 {
                        addresses.append(String(cString: hostname))
                    }
                }
            }
            ptr = p.pointee.ifa_next
        }
        return addresses.first
    }

    /// True when the current IPv4 lives on the same /24 as the printer prefix
    /// (e.g. "10.100.10."). This is the cheap, no-entitlement way to know
    /// "are we on the printer LAN?" without reading SSIDs.
    static func isOnSubnet(prefix: String) -> Bool {
        guard let ip = currentIPv4() else { return false }
        return ip.hasPrefix(prefix)
    }
}

// MARK: - Public configuration

struct PrinterNetworkConfig {
    /// Display name shown in copy as the network the cashier *should* be on.
    var expectedSSID: String = "Tabit Haam"
    /// IP prefix that identifies the printer LAN.
    var printerSubnetPrefix: String = "10.100.10."
}

// MARK: - Banner

struct PrinterOfflineBanner: View {
    let isRtl: Bool
    let config: PrinterNetworkConfig
    let currentSSID: String?

    private var subtitle: String {
        PrinterNetCopy.bannerSubtitle(isRtl: isRtl, expectedSSID: config.expectedSSID)
    }

    private var title: String {
        PrinterNetCopy.bannerTitle(isRtl: isRtl, ssid: currentSSID)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.black)

            VStack(alignment: isRtl ? .trailing : .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.black)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.black.opacity(0.7))
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Button {
                openWiFiSettings()
            } label: {
                Text(PrinterNetCopy.openWiFi(isRtl: isRtl))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.black)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(red: 1.0, green: 0.92, blue: 0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
        )
        .fixedSize()
        .transition(.move(edge: .top).combined(with: .opacity))
        .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
    }

    private func openWiFiSettings() {
        // App-Prefs deep link is gated by iOS — fall back to Settings root.
        let urls = [
            URL(string: "App-Prefs:root=WIFI"),
            URL(string: UIApplication.openSettingsURLString)
        ].compactMap { $0 }
        for u in urls {
            if UIApplication.shared.canOpenURL(u) {
                UIApplication.shared.open(u, options: [:], completionHandler: nil)
                return
            }
        }
    }
}

// MARK: - Recovered toast

struct PrinterRecoveredToast: View {
    let isRtl: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
            Text(PrinterNetCopy.recoveredToast(isRtl: isRtl))
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Capsule().fill(Color.black.opacity(0.85)))
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
    }
}

// MARK: - View modifier that bundles all three

struct PrinterNetworkAlertsModifier: ViewModifier {
    @ObservedObject var monitor: PrinterReachabilityMonitor
    let basketIsEmpty: Bool
    let isRtl: Bool
    var config: PrinterNetworkConfig = PrinterNetworkConfig()

    @State private var showRecovered = false
    @State private var lastReady: Bool = true
    @State private var currentSSID: String? = nil

    private var shouldShowBanner: Bool {
        if monitor.isReadyToPrint { return false }
        if !monitor.isNetworkUp { return true }
        if monitor.anyPrinterOffline { return true }
        if !LocalNetworkInfo.isOnSubnet(prefix: config.printerSubnetPrefix) { return true }
        return false
    }

    func body(content: Content) -> some View {
        ZStack(alignment: .top) {
            content

            if shouldShowBanner {
                PrinterOfflineBanner(
                    isRtl: isRtl,
                    config: config,
                    currentSSID: currentSSID
                )
                .padding(.top, 4)
                .zIndex(9999)
            }

            VStack {
                Spacer()
                if showRecovered {
                    PrinterRecoveredToast(isRtl: isRtl)
                        .zIndex(9998)
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: shouldShowBanner)
        .animation(.easeInOut(duration: 0.25), value: showRecovered)
        .onChange(of: monitor.isReadyToPrint) { ready in
            // Detect the false → true edge to show the recovered toast.
            if ready && !lastReady {
                withAnimation { showRecovered = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    withAnimation { showRecovered = false }
                }
            }
            lastReady = ready
        }
        .onAppear {
            lastReady = monitor.isReadyToPrint
        }
    }
}

extension View {
    /// Attaches the printer-network banner + recovered toast.
    /// Pair with `.printerOfflineModal(...)` at the moment of print.
    func printerNetworkAlerts(
        monitor: PrinterReachabilityMonitor,
        basketIsEmpty: Bool,
        isRtl: Bool,
        config: PrinterNetworkConfig = PrinterNetworkConfig()
    ) -> some View {
        modifier(PrinterNetworkAlertsModifier(
            monitor: monitor,
            basketIsEmpty: basketIsEmpty,
            isRtl: isRtl,
            config: config
        ))
    }
}

// MARK: - Print-moment modal

extension View {
    /// Confirmation dialog the cashier sees when they try to print while
    /// the printer LAN is unreachable. Two paths:
    ///   • Open WiFi settings → resolve the SSID hop themselves.
    ///   • Save & auto-print → trust the OneShotPrinter retry queue.
    func printerOfflineModal(
        isPresented: Binding<Bool>,
        isRtl: Bool,
        currentSSID: String? = nil,
        config: PrinterNetworkConfig = PrinterNetworkConfig(),
        onSaveAndAutoPrint: @escaping () -> Void
    ) -> some View {
        confirmationDialog(
            PrinterNetCopy.modalTitle(isRtl: isRtl),
            isPresented: isPresented,
            titleVisibility: .visible
        ) {
            Button(PrinterNetCopy.openWiFi(isRtl: isRtl)) {
                let urls = [
                    URL(string: "App-Prefs:root=WIFI"),
                    URL(string: UIApplication.openSettingsURLString)
                ].compactMap { $0 }
                for u in urls where UIApplication.shared.canOpenURL(u) {
                    UIApplication.shared.open(u, options: [:], completionHandler: nil)
                    break
                }
            }
            Button(PrinterNetCopy.saveAndAutoPrint(isRtl: isRtl)) {
                onSaveAndAutoPrint()
            }
            Button(PrinterNetCopy.cancel(isRtl: isRtl), role: .cancel) { }
        } message: {
            Text(PrinterNetCopy.modalBody(
                isRtl: isRtl,
                currentSSID: currentSSID,
                expectedSSID: config.expectedSSID
            ))
        }
    }
}
