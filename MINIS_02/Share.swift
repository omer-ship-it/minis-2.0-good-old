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
    var tint: Color = .primary
    var bg: Color = .white
    var overlayLabel: String? = nil
    var logoKnockoutFraction: CGFloat = 0.28

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ZStack {
                if let matrix = QRMatrix(text: text) {
                    Canvas { ctx, size in
                        let n = CGFloat(matrix.count)
                        guard n > 0 else { return }
                        let cell = side / n

                        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(bg))

                        let kSide = side * logoKnockoutFraction
                        let kRect = CGRect(x: (side - kSide)/2, y: (side - kSide)/2, width: kSide, height: kSide)

                        for row in 0..<matrix.count {
                            for col in 0..<matrix[row].count {
                                guard matrix[row][col] else { continue }
                                let cx = (CGFloat(col) + 0.5) * cell
                                let cy = (CGFloat(row) + 0.5) * cell
                                if kRect.contains(CGPoint(x: cx, y: cy)) { continue }
                                let d = cell * dotScale
                                ctx.fill(
                                    Path(ellipseIn: CGRect(x: cx - d/2, y: cy - d/2, width: d, height: d)),
                                    with: .color(tint)
                                )
                            }
                        }
                    }
                }

                if let label = overlayLabel {
                    Text(label)
                        .font(.system(size: side * 0.1, weight: .heavy, design: .rounded))
                        .foregroundColor(.black)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                }
            }
            .frame(width: side, height: side)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.white)
            )
            .shadow(color: .black.opacity(0.15), radius: 12, x: 0, y: 6)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

private func QRMatrix(text: String, correction: String = "M") -> [[Bool]]? {
    let data = Data(text.utf8)
    let filter = CIFilter.qrCodeGenerator()
    filter.setValue(data, forKey: "inputMessage")
    filter.setValue(correction, forKey: "inputCorrectionLevel")

    let context = CIContext(options: [.useSoftwareRenderer: false])
    guard let ciImage = filter.outputImage,
          let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }

    let width = cgImage.width, height = cgImage.height
    guard width == height else { return nil }

    let bytesPerRow = width
    var buffer = [UInt8](repeating: 255, count: width * height)
    let colorSpace = CGColorSpaceCreateDeviceGray()

    guard let ctx = CGContext(data: &buffer, width: width, height: height,
                              bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                              space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }

    ctx.interpolationQuality = .none
    ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

    var matrix = Array(repeating: Array(repeating: false, count: width), count: height)
    for y in 0..<height {
        let rowStart = y * bytesPerRow
        for x in 0..<width {
            matrix[y][x] = buffer[rowStart + x] < 128
        }
    }
    return matrix
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
                                .background(RoundedRectangle(cornerRadius: 16).fill(.white))
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
                                .background(RoundedRectangle(cornerRadius: 16).fill(.white))
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
            .toolbarColorScheme(.light, for: .navigationBar)
            .toolbar(angle.isCustomerFacing ? .hidden : .visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if !angle.isCustomerFacing {
                        Button {
                            dismiss()
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(Color.white)
                                    .frame(width: 40, height: 40)
                                    .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)

                                Image(systemName: "xmark")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(.black)
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
