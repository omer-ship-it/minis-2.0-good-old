import Foundation
import UIKit
import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import Contacts
import MessageUI
import CoreMotion
import Combine

private let appGroupID            = "group.minis"
private let referralImageFilename = "lastMiniReferral.png"
private let referralDefaultsKey   = "lastMiniReferralJSON"
private let referralsListKey      = "miniReferralsJSON"



struct MiniReferral: Codable {
    let title: String
    let subtitle: String
    let miniAppId: Int
    let imageURL: String?
    let sharedAt: Date
    var kind: MiniKind = .miniMe
}

private func sharedDefaults() -> UserDefaults? {
    UserDefaults(suiteName: appGroupID)
}

private func sharedContainerURL() -> URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
}

func saveMiniReferralToAppGroup(_ new: MiniReferral) {
    let defaults = sharedDefaults()
    var arr: [MiniReferral] = []

    if let data = defaults?.data(forKey: referralsListKey),
       let saved = try? JSONDecoder().decode([MiniReferral].self, from: data) {
        arr = saved
    }

    if let idx = arr.firstIndex(where: { $0.miniAppId == new.miniAppId }) {
        arr[idx] = new
    } else {
        arr.insert(new, at: 0)
    }

    if let encoded = try? JSONEncoder().encode(arr) {
        defaults?.set(encoded, forKey: referralsListKey)
    }
}

func loadMiniReferralFromAppGroup() -> MiniReferral? {
    guard let ud = sharedDefaults(),
          let data = ud.data(forKey: referralDefaultsKey),
          let ref = try? JSONDecoder().decode(MiniReferral.self, from: data) else { return nil }
    return ref
}

@discardableResult
func writeReferralImageToAppGroup(_ image: UIImage) -> String? {
    guard let dir = sharedContainerURL() else { return nil }
    let url = dir.appendingPathComponent(referralImageFilename)
    guard let data = image.pngData() else { return nil }
    do {
        try data.write(to: url, options: .atomic)
        return url.path
    } catch {
        print("❌ writeReferralImageToAppGroup:", error)
        return nil
    }
}

struct QuickRecipient: Identifiable, Hashable {
    var id: String { value }
    let display: String
    let value: String
    let image: UIImage?
}

final class ContactsAccess {
    static let shared = ContactsAccess()
    private let store = CNContactStore()

    func requestAndFetch(limit: Int = 30) async throws -> [QuickRecipient] {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .notDetermined {
            let granted: Bool = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Bool, Error>) in
                store.requestAccess(for: .contacts) { ok, err in
                    if let err = err { cont.resume(throwing: err) }
                    else { cont.resume(returning: ok) }
                }
            }
            guard granted else { return [] }
        } else if status != .authorized {
            return []
        }

        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as NSString,
            CNContactFamilyNameKey as NSString,
            CNContactPhoneNumbersKey as NSString,
            CNContactImageDataAvailableKey as NSString,
            CNContactThumbnailImageDataKey as NSString
        ]
        let req = CNContactFetchRequest(keysToFetch: keys)
        req.sortOrder = .userDefault

        var out: [QuickRecipient] = []
        try store.enumerateContacts(with: req) { c, _ in
            guard let num = c.phoneNumbers.first?.value.stringValue, !num.isEmpty else { return }
            let name = ([c.givenName, c.familyName].joined(separator: " ")).trimmingCharacters(in: .whitespaces)
            let clean = num.filter("0123456789+".contains)
            let img = c.imageDataAvailable ? (c.thumbnailImageData.flatMap(UIImage.init(data:))) : nil
            out.append(.init(display: name.isEmpty ? clean : name, value: clean, image: img))
        }
        return Array(out.prefix(limit))
    }
}

struct MessagesComposer: UIViewControllerRepresentable {
    let body: String
    let recipients: [String]

    class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        func messageComposeViewController(_ c: MFMessageComposeViewController,
                                          didFinishWith result: MessageComposeResult) { c.dismiss(animated: true) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let vc = MFMessageComposeViewController()
        vc.messageComposeDelegate = context.coordinator
        vc.body = body
        vc.recipients = recipients
        return vc
    }

    func updateUIViewController(_ vc: MFMessageComposeViewController, context: Context) {}
}

struct AvatarChip: View {
    let name: String
    let phone: String
    let image: UIImage?
    let selected: Bool
    var onTap: () -> Void

    private var initials: String {
        let parts = name.split(separator: " ")
        let first = parts.first?.first.map(String.init) ?? ""
        let last  = parts.dropFirst().first?.first.map(String.init) ?? ""
        return (first + last).uppercased()
    }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                ZStack {
                    if let img = image {
                        Image(uiImage: img).resizable().scaledToFill()
                    } else {
                        Text(initials.isEmpty ? "•" : initials)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.gray)
                    }
                }
                .frame(width: 48, height: 48)
                .clipShape(Circle())
                .overlay(Circle().stroke(selected ? Color.blue : Color.clear, lineWidth: 2))

                Text(name)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .frame(width: 64)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 12).fill(.white))
            .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 4)
        }
        .buttonStyle(.plain)
    }
}
struct DotQRView: View {
    let text: String
    var dotScale: CGFloat = 0.78
    var overlayLabel: String? = "MINI"
    var logoKnockoutFraction: CGFloat = 0.22

    @Environment(\.colorScheme) private var scheme

    private var cardBG: Color { Color(.secondarySystemGroupedBackground) } // adapts
    private var qrBG: Color { Color(.systemBackground) }                  // adapts
    private var ink: Color { Color(.label) }                              // adapts

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)

            ZStack {
                if let modules = QRMatrix(text: text, correction: "H") {
                    Canvas { ctx, size in
                        let nInt = modules.count
                        guard nInt > 0 else { return }

                        let side = min(size.width, size.height)

                        // JS-style quiet zone (4 modules)
                        let quiet = 4
                        let totalModules = nInt + quiet * 2
                        let cell = side / CGFloat(totalModules)

                        // center knockout
                        let kSide = side * logoKnockoutFraction
                        let kx = (side - kSide) / 2
                        let ky = (side - kSide) / 2
                        let kRect = CGRect(x: kx, y: ky, width: kSide, height: kSide)

                        // QR background (dynamic)
                        ctx.fill(Path(CGRect(origin: .zero, size: CGSize(width: side, height: side))),
                                 with: .color(qrBG))

                        func isInFinder(_ r: Int, _ c: Int, _ n: Int) -> Bool {
                            let tl = (r < 7 && c < 7)
                            let tr = (r < 7 && c >= n - 7)
                            let bl = (r >= n - 7 && c < 7)
                            return tl || tr || bl
                        }

                        for r in 0..<nInt {
                            for c in 0..<nInt {
                                guard modules[r][c] else { continue }

                                let x = (CGFloat(c + quiet)) * cell
                                let y = (CGFloat(r + quiet)) * cell

                                let cx = x + cell / 2
                                let cy = y + cell / 2
                                if kRect.contains(CGPoint(x: cx, y: cy)) { continue }

                                if isInFinder(r, c, nInt) {
                                    let ix = CGFloat(Int(x.rounded()))
                                    let iy = CGFloat(Int(y.rounded()))
                                    let isz = CGFloat(Int(cell.rounded(.up)))
                                    ctx.fill(Path(CGRect(x: ix, y: iy, width: isz, height: isz)),
                                             with: .color(ink))
                                } else {
                                    let radius = (cell * dotScale) / 2
                                    ctx.fill(Path(ellipseIn: CGRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2)),
                                             with: .color(ink))
                                }
                            }
                        }

                        if let label = overlayLabel, !label.isEmpty {
                            let fontSize = side * 0.10
                            let center = CGPoint(x: side / 2, y: side / 2)

                            // Pick a concrete color (best if `ink` is a Color)
                            // If `ink` is not a Color (e.g. gradient), choose a fallback Color here.
                            let uiColor = UIColor(ink as? Color ?? .black)

                            ctx.withCGContext { cg in
                                UIGraphicsPushContext(cg)
                                defer { UIGraphicsPopContext() }

                                let font = UIFont.systemFont(ofSize: fontSize, weight: .bold)

                                let attrs: [NSAttributedString.Key: Any] = [
                                    .font: font,
                                    .foregroundColor: uiColor
                                ]

                                let ns = NSString(string: label)
                                let size = ns.size(withAttributes: attrs)

                                let rect = CGRect(
                                    x: center.x - size.width / 2,
                                    y: center.y - size.height / 2,
                                    width: size.width,
                                    height: size.height
                                )

                                ns.draw(in: rect, withAttributes: attrs)
                            }
                        }
                    }
                }
            }
            .frame(width: side, height: side)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(cardBG)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.black.opacity(scheme == .dark ? 0.25 : 0.06), lineWidth: 1)
            )
            .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.12),
                    radius: scheme == .dark ? 18 : 16,
                    x: 0, y: 6)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

private func QRMatrix(text: String, correction: String = "H") -> [[Bool]]? {
    let data = Data(text.utf8)
    let filter = CIFilter.qrCodeGenerator()
    filter.setValue(data, forKey: "inputMessage")
    filter.setValue(correction, forKey: "inputCorrectionLevel")

    let context = CIContext(options: [.useSoftwareRenderer: false])
    guard let ciImage = filter.outputImage,
          let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }

    let width = cgImage.width
    let height = cgImage.height
    guard width == height, width > 0 else { return nil }

    // Read as 8-bit grayscale
    let bytesPerRow = width
    var buffer = [UInt8](repeating: 255, count: width * height)
    let colorSpace = CGColorSpaceCreateDeviceGray()

    guard let ctx = CGContext(
        data: &buffer,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.none.rawValue
    ) else { return nil }

    ctx.interpolationQuality = .none
    ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

    // Build raw matrix (includes CoreImage quiet zone)
    var raw = Array(repeating: Array(repeating: false, count: width), count: height)
    for y in 0..<height {
        let rowStart = y * bytesPerRow
        for x in 0..<width {
            raw[y][x] = buffer[rowStart + x] < 128
        }
    }

    // ✅ Trim the quiet zone off (so we can re-add exactly 4 modules like JS)
    // Find bounding box of dark modules
    var minX = width, minY = height, maxX = -1, maxY = -1
    for y in 0..<height {
        for x in 0..<width where raw[y][x] {
            if x < minX { minX = x }
            if y < minY { minY = y }
            if x > maxX { maxX = x }
            if y > maxY { maxY = y }
        }
    }
    if maxX < 0 || maxY < 0 { return nil }

    let coreW = maxX - minX + 1
    let coreH = maxY - minY + 1
    guard coreW == coreH, coreW > 0 else { return nil }

    var core = Array(repeating: Array(repeating: false, count: coreW), count: coreH)
    for y in 0..<coreH {
        for x in 0..<coreW {
            core[y][x] = raw[minY + y][minX + x]
        }
    }
    return core
}
struct QRShareSheet: View {
    let url: URL
    var title = "Share"
    private let qrSide: CGFloat = 260
    
    let isBeigelBake = (UserDefaults.standard.string(forKey: "shopId") == "3")

    @Environment(\.dismiss) private var dismiss
    @State private var showComposer = false
    @State private var copiedToast = false
    @StateObject private var angle = DeviceAngleManager()

    var body: some View {
        NavigationStack {
            ZStack {
                VStack(spacing: angle.isCustomerFacing ? 24 : 16) {
                    Spacer()

                    VStack(spacing: 16) {
                        DotQRView(
                            text: url.absoluteString,
                            overlayLabel: isBeigelBake ? "BB" : "MINI",
                            logoKnockoutFraction: 0.28
                        )
                        .frame(
                            width: angle.isCustomerFacing ? qrSide * 1.0 : qrSide,
                            height: angle.isCustomerFacing ? qrSide * 1.0 : qrSide
                        )
                        .rotationEffect(angle.isCustomerFacing ? .degrees(180) : .degrees(0))
                        .shadow(radius: 8)

                        if angle.isCustomerFacing {
                            Text("Scan to Connect")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundColor(.primary)
                                .rotationEffect(.degrees(180))
                                .transition(.opacity.combined(with: .scale))
                                .padding(.bottom, 30)
                        }
                    }

                    if !angle.isCustomerFacing {
                        HStack(spacing: 12) {
                            Button {
                                if MFMessageComposeViewController.canSendText() {
                                    showComposer = true
                                }
                            } label: {
                                VStack(spacing: 6) {
                                    Image(systemName: "square.and.arrow.up")
                                        .font(.system(size: 24, weight: .semibold))
                                    Text(isBeigelBake ? "Share Beigel Bake" : "Share Mini")
                                        .font(.system(size: 11, weight: .semibold))
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
                                .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 6)
                            }
                            .buttonStyle(.plain)

                            Button {
                                UIPasteboard.general.string = url.absoluteString
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                    copiedToast = true
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        copiedToast = false
                                    }
                                }
                            } label: {
                                VStack(spacing: 6) {
                                    Image(systemName: "link")
                                        .font(.system(size: 24, weight: .semibold))
                                    Text("Copy link")
                                        .font(.system(size: 11, weight: .semibold))
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
                                .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 6)
                            }
                            .buttonStyle(.plain)
                        }
                        .frame(width: qrSide)
                        .transition(.opacity)
                    }

                    Spacer(minLength: 12)

                    if copiedToast {
                        Text("Link copied")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.thinMaterial, in: Capsule())
                            .transition(.opacity.combined(with: .scale))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemGroupedBackground))
                .onAppear { angle.start() }
                .onDisappear { angle.stop() }
            }
            .navigationTitle(isBeigelBake ? "Share Beigel Bake" : "Share Mini")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.clear, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar(angle.isCustomerFacing ? .hidden : .visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if !angle.isCustomerFacing {
                        Button {
                            dismiss()
                        } label: {
                            ZStack {
                                Circle().fill(Color(.secondarySystemGroupedBackground))
                                    .frame(width: 40, height: 40)
                                    .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)

                                Image(systemName: "xmark")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(.primary)
                            }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showComposer) {
            MessagesComposer(body: "\(url.absoluteString)", recipients: [])
                .ignoresSafeArea()
        }
    }
}

final class DeviceAngleManager: ObservableObject {
    private let motion = CMMotionManager()
    private let queue  = OperationQueue()
    @Published var rotation: Angle = .degrees(0)
    @Published var isCustomerFacing: Bool = false
    private let flipThreshold: Double = 0.0

    func start() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 30.0
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) { [weak self] dm, _ in
            guard let self, let g = dm?.gravity else { return }
            let customerFacing = g.y > flipThreshold
            let target = customerFacing ? Angle.degrees(180) : Angle.degrees(0)

            DispatchQueue.main.async {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                    self.rotation = target
                    self.isCustomerFacing = customerFacing
                }
            }
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
    }
}
