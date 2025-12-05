import SwiftUI
import Kingfisher

// A mutable draft of a product used for editing/creating
struct AdminProductDraft: Identifiable {
    let id = UUID()
    var productId: Int?

    var name: String
    var priceText: String
    var category: String
    var description: String
    var imageURL: String        // can be full URL or short name
    var modifierGroups: [AdminModifierGroupDraft]
}


struct AdminModifierGroupDraft: Identifiable, Hashable {
    enum Kind: String, CaseIterable, Identifiable {
        case options
        case additions
        var id: String { rawValue }
        var title: String {
            switch self {
            case .options:   return "Options"
            case .additions: return "Extras"
            }
        }
    }

    var id = UUID()
    var title: String
    var kind: Kind
    var items: [AdminModifierItemDraft]
}


struct AdminModifierItemDraft: Identifiable, Hashable {
    var id = UUID()
    var name: String
    var extraPriceText: String   // text field backing for price
}

// Editable modifier item

struct AdminProductEditorMode {
    enum Mode {
        case create
        case edit
    }
}

struct AdminProductEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isRtl)   private var isRtl

    @State private var draft: AdminProductDraft
    @State private var lastAddedGroupId: AdminModifierGroupDraft.ID?

    // 👇 NEW: keep a live local preview of the picked image
    @State private var pickedImage: UIImage? = nil
    @State private var showImagePicker = false
    @State private var isUploadingImage = false

    private let mode: AdminProductEditorMode.Mode
    private let onSave: (AdminProductDraft) -> Void
    private let onDelete: (() -> Void)?
    private let onChangeImage: (() -> Void)?

    init(
        draft: AdminProductDraft,
        mode: AdminProductEditorMode.Mode,
        onSave: @escaping (AdminProductDraft) -> Void,
        onDelete: (() -> Void)? = nil,
        onChangeImage: (() -> Void)? = nil
    ) {
        _draft = State(initialValue: draft)

        if draft.priceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self._draft.wrappedValue.priceText = "0.0"
        }

        self.mode = mode
        self.onSave = onSave
        self.onDelete = onDelete
        self.onChangeImage = onChangeImage
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    Section { headerImageSection }
                    Section { mainFieldsSection }

                    Section(
                        header:
                            HStack {
                                Text(isRtl ? "תוספות / אפשרויות" : "Options & Extras")
                                    .font(.primariesDemi(18))
                                Spacer()
                                Button {
                                    addNewModifierGroup()
                                } label: {
                                    Image(systemName: "plus.circle.fill")
                                }
                            }
                    ) {
                        if draft.modifierGroups.isEmpty {
                            Text(isRtl ? "אין תוספות" : "No modifiers yet")
                                .foregroundColor(.secondary)
                        } else {
                            ForEach(draft.modifierGroups) { group in
                                AdminModifierGroupEditor(
                                    group: binding(for: group),
                                    onDelete: { removeModifierGroup(group) }
                                )
                                .id(group.id)
                            }
                            .onMove(perform: moveModifierGroups)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .onChange(of: lastAddedGroupId) { id in
                    guard let id else { return }
                    withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: isRtl ? "chevron.right" : "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                    }
                }
                ToolbarItem(placement: .principal) {
                    Text(modeTitle)
                        .font(.primariesDemi(18))
                }
                if mode == .edit, let onDelete {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(role: .destructive) {
                            onDelete()
                            dismiss()
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { bottomBar }
            .sheet(isPresented: $showImagePicker) {
                AdminImagePicker { image in
                    handlePickedImage(image)
                }
            }
        }
        .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
    }

    private var modeTitle: String {
        switch mode {
        case .create: return isRtl ? "מוצר חדש" : "New Product"
        case .edit:   return isRtl ? "עריכת מוצר" : "Edit Product"
        }
    }

    // MARK: - Image header

    private var headerImageSection: some View {
        VStack(spacing: 8) {

            // Resolve a remote URL only when we *don't* have a local preview
            let remoteURL: URL? = {
                let trimmed = draft.imageURL.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
                    return URL(string: trimmed)
                } else {
                    return URL(string: "https://minitel.co.uk/images/\(trimmed).png")
                }
            }()

            ZStack {
                Rectangle()
                    .fill(Color(.systemGray5))
                    .frame(height: 220)
                    .overlay(
                        Group {
                            if let img = pickedImage {
                                // 👇 show local picked image immediately
                                Image(uiImage: img)
                                    .resizable()
                                    .scaledToFill()
                                    .clipped()
                            } else if let url = remoteURL {
                                KFImage(url)
                                    .resizable()
                                    .scaledToFill()
                                    .clipped()
                            } else {
                                Text(isRtl ? "הוסף תמונה" : "Add image")
                                    .foregroundColor(.secondary)
                            }
                        }
                    )
                    .clipped()
                    .onTapGesture {
                        showImagePicker = true
                    }

                if isUploadingImage {
                    ZStack {
                        Color.black.opacity(0.25)
                        ProgressView(isRtl ? "מעלה תמונה…" : "Uploading…")
                            .tint(.white)
                            .foregroundColor(.white)
                    }
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, 4)
            .padding(.top, 4)

            if onChangeImage == nil {
                HStack {
                    Text(isRtl ? "קישור לתמונה" : "Image URL")
                        .font(.primariesDemi(14))
                    TextField(isRtl ? "shop12_croissant" : "shop12_croissant",
                              text: $draft.imageURL)
                        .textInputAutocapitalization(.none)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                }
            } else {
                Button { showImagePicker = true } label: {
                    Text(isRtl ? "בחירת תמונה" : "Change Image")
                        .font(.primariesDemi(15))
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// Called when the user picks an image from the gallery.
    private func handlePickedImage(_ image: UIImage) {
        // 1️⃣ Show it immediately in the UI
        self.pickedImage = image

        // 2️⃣ Start upload in background
        isUploadingImage = true

        let shopId = UserDefaults.standard.string(forKey: "shopId") ?? "0"
        let productIdPart = draft.productId.map { "prod\($0)" } ?? "new"
        let ts = Int(Date().timeIntervalSince1970)
        let slugName = draft.name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")

        // short key used by the uploader
        let imageName = "shop\(shopId)_\(productIdPart)_\(ts)_\(slugName)"

        saveImageToServer(image: image, imageName: imageName) { result in
            DispatchQueue.main.async {
                self.isUploadingImage = false
                switch result {
                case .success(let savedName):
                    // 🔴 savedName is the bare key, e.g. "shop12_prod653_..._קראפין_פיסטוק"
                    // ✅ store the FULL URL in draft.imageURL:
                    let encoded = savedName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? savedName
                    self.draft.imageURL = "https://minitel.co.uk/images/uploads/\(encoded).png"

                case .failure(let error):
                    print("❌ image upload failed:", error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Main fields

    private var mainFieldsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(isRtl ? "שם המוצר" : "Name")
                    .font(.primariesDemi(14))
                TextField("",
                          text: $draft.name,
                          prompt: Text(isRtl ? "שם המוצר" : "Name"))
                    .font(.custom(primariesFontName, size: 18))
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(isRtl ? "מחיר" : "Price")
                        .font(.primariesDemi(14))
                    PriceTextField(text: $draft.priceText)
                        .frame(height: 36)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(isRtl ? "קטגוריה" : "Category")
                        .font(.primariesDemi(14))
                    TextField(isRtl ? "קטגוריה" : "Category", text: $draft.category)
                        .textFieldStyle(.roundedBorder)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(isRtl ? "תיאור" : "Description")
                    .font(.primariesDemi(14))
                TextField(isRtl ? "תיאור קצר" : "Short description",
                          text: $draft.description,
                          axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3, reservesSpace: true)
            }
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 16) {
            Spacer()
            Button {
                let price = Double(draft.priceText.replacingOccurrences(of: ",", with: ".")) ?? 0
                var cleanDraft = cleanedForSave(draft)
                cleanDraft.priceText = String(format: "%.2f", price)

                onSave(cleanDraft)
                dismiss()
            } label: {
                Text(mode == .create ? (isRtl ? "הוסף מוצר" : "Create")
                                     : (isRtl ? "שמור שינויים" : "Save"))
                    .font(.primariesDemi(17))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(.systemBackground).ignoresSafeArea(edges: .bottom))
    }

    // MARK: - Cleaning + helpers

    private func cleanedForSave(_ draft: AdminProductDraft) -> AdminProductDraft {
        var copy = draft

        copy.modifierGroups = copy.modifierGroups.map { group in
            var g = group
            g.items = g.items.filter {
                !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return g;
        }

        copy.modifierGroups = copy.modifierGroups.filter { group in
            let hasTitle = !group.title
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
            return hasTitle || !group.items.isEmpty
        }

        return copy
    }

    private func binding(for group: AdminModifierGroupDraft) -> Binding<AdminModifierGroupDraft> {
        Binding(
            get: {
                draft.modifierGroups.first(where: { $0.id == group.id }) ?? group
            },
            set: { newValue in
                if let idx = draft.modifierGroups.firstIndex(where: { $0.id == group.id }) {
                    draft.modifierGroups[idx] = newValue
                }
            }
        )
    }

    private func removeModifierGroup(_ group: AdminModifierGroupDraft) {
        if let idx = draft.modifierGroups.firstIndex(where: { $0.id == group.id }) {
            draft.modifierGroups.remove(at: idx)
        }
    }

    private func moveModifierGroups(from source: IndexSet, to destination: Int) {
        draft.modifierGroups.move(fromOffsets: source, toOffset: destination)
    }

    private func addNewModifierGroup() {
        let new = AdminModifierGroupDraft(
            title: "",
            kind: .options,
            items: []
        )
        draft.modifierGroups.append(new)
        lastAddedGroupId = new.id
    }
}
struct AdminModifierGroupEditor: View {
    @Environment(\.isRtl) private var isRtl
    @State private var showDeleteAlert = false
    @Binding var group: AdminModifierGroupDraft
    let onDelete: () -> Void

    @FocusState private var isTitleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // HEADER: title + type + delete
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    TextField(
                        "",
                        text: $group.title,
                        prompt: Text(isRtl ? "קבוצה חדשה" : "New group")
                    )
                    .font(.primariesDemi(15))
                    .textFieldStyle(.roundedBorder)
                    .focused($isTitleFocused)

                    Picker("", selection: $group.kind) {
                        Text(isRtl ? "אפשרויות" : "Options")
                            .tag(AdminModifierGroupDraft.Kind.options)
                        Text(isRtl ? "תוספות" : "Additions")
                            .tag(AdminModifierGroupDraft.Kind.additions)
                    }
                    .pickerStyle(.segmented)
                }

                Spacer()

                Button {
                    showDeleteAlert = true   // just open confirm
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.red)
                        .padding(6)          // small tap target, not the whole box
                }
                .buttonStyle(.borderless)    // don’t let List expand the tap area
                .alert(isPresented: $showDeleteAlert) {
                    Alert(
                        title: Text(isRtl ? "למחוק קבוצה?" : "Delete group?"),
                        message: Text(isRtl
                                      ? "האם אתה בטוח שברצונך למחוק את קבוצת התוספות הזו?"
                                      : "Are you sure you want to delete this modifier group?"),
                        primaryButton: .destructive(Text(isRtl ? "מחק" : "Delete")) {
                            onDelete()
                        },
                        secondaryButton: .cancel(Text(isRtl ? "ביטול" : "Cancel"))
                    )
                }
            }

            // OPTIONS / ADDITIONS LIST
            VStack(spacing: 6) {
                ForEach(Array(group.items.indices), id: \.self) { index in
                    HStack(spacing: 8) {
                        // Name
                        TextField(
                            group.kind == .options
                                ? (isRtl ? "אפשרות" : "Option")
                                : (isRtl ? "תוספת" : "Extra"),
                            text: $group.items[index].name
                        )
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: group.items[index].name) { newValue in
                            autoAppendRowIfNeeded(currentIndex: index, newValue: newValue)
                        }

                        // Extra price – with auto-select on focus
                        PriceTextField(text: $group.items[index].extraPriceText)
                            .frame(width: 60)

                        // Delete row
                        Button {
                            removeItem(at: index)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundColor(.red.opacity(0.7))
                        }
                    }
                }

                // 👇 New "Add modifier" button at bottom of each group
                Button {
                    appendEmptyItem()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill")
                        Text(
                            group.kind == .options
                            ? (isRtl ? "הוסף אפשרות" : "Add option")
                            : (isRtl ? "הוסף תוספת" : "Add extra")
                        )
                        .font(.system(size: 14, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onAppear {
            // Focus title for new groups (empty title) with a short delay
            if group.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    isTitleFocused = true
                }
            }

            // Ensure at least one empty item
            if group.items.isEmpty {
                appendEmptyItem()
            }
        }
    }

    // MARK: - Helpers

    private func appendEmptyItem() {
        group.items.append(
            AdminModifierItemDraft(
                name: "",
                extraPriceText: "0.0"   // 👈 default 0.0 instead of 0
            )
        )
    }

    private func removeItem(at index: Int) {
        guard group.items.indices.contains(index) else { return }
        group.items.remove(at: index)
        if group.items.isEmpty {
            appendEmptyItem()
        }
    }

    /// When user starts typing into the *last* option row, auto-append a new empty row.
    private func autoAppendRowIfNeeded(currentIndex: Int, newValue: String) {
        guard currentIndex == group.items.count - 1 else { return }

        let trimmed = newValue.trimmingCharacters(in: .whitespaces)
        // Only when they type the *first* non-empty character in the last row
        if trimmed.count == 1 {
            appendEmptyItem()
        }
    }
}

struct PriceTextField: UIViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeUIView(context: Context) -> UITextField {
        let tf = UITextField()
        tf.keyboardType = .decimalPad

        // 👇 Leading alignment instead of center
        tf.textAlignment = .right

        tf.borderStyle = .roundedRect
        tf.delegate = context.coordinator
        tf.text = text
        tf.addTarget(context.coordinator,
                     action: #selector(Coordinator.textChanged(_:)),
                     for: .editingChanged)
        return tf
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }
    }

    class Coordinator: NSObject, UITextFieldDelegate {
        @Binding var text: String

        init(text: Binding<String>) {
            _text = text
        }

        @objc func textChanged(_ sender: UITextField) {
            text = sender.text ?? ""
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            // 👇 Automatically select all text on focus
            DispatchQueue.main.async {
                textField.selectAll(nil)
            }
        }
    }
}

import UIKit

extension UIImage {
    /// Scale proportionally so that max(width, height) == maxDimension
    func scaled(toMaxDimension maxDimension: CGFloat) -> UIImage? {
        let maxSide = max(size.width, size.height)
        guard maxSide > 0 else { return self }

        let scale = maxDimension / maxSide
        if scale >= 1 { return self }   // already small enough

        let newSize = CGSize(width: size.width * scale,
                             height: size.height * scale)

        UIGraphicsBeginImageContextWithOptions(newSize, false, 0)
        defer { UIGraphicsEndImageContext() }

        draw(in: CGRect(origin: .zero, size: newSize))
        return UIGraphicsGetImageFromCurrentImageContext()
    }
}

func saveImageToServer(
    image: UIImage,
    imageName: String,
    completion: @escaping (Result<String, Error>) -> Void
) {
    // 1) Scale down to 400px max
    let resized = image.scaled(toMaxDimension: 400) ?? image
    
    // 2) Convert to JPEG
    guard let imageData = resized.jpegData(compressionQuality: 0.7) else {
        completion(.failure(NSError(domain: "", code: -1)))
        return
    }
    let imageString = imageData.base64EncodedString()
    guard let uploadURL = URL(string: "https://minitel.co.uk/utilities/saveimage.aspx") else {
        completion(.failure(NSError(domain: "", code: -1)))
        return
    }
    
    var request = URLRequest(url: uploadURL)
    request.httpMethod = "POST"
    request.addValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    
    // The server expects something like: "myImageName.pngimage=BASE64DATA"
    let postBody = "\(imageName).pngimage=\(imageString)"
    request.httpBody = postBody.data(using: .utf8)
    request.addValue("\(postBody.count)", forHTTPHeaderField: "Content-Length")
    
    URLSession.shared.dataTask(with: request) { _, response, error in
        if let error = error {
            completion(.failure(error))
            return
        }
        if let httpResp = response as? HTTPURLResponse,
           httpResp.statusCode == 200 {
            completion(.success(imageName))
        } else {
            completion(.failure(NSError(domain: "", code: -1)))
        }
    }.resume()
}

struct AdminImagePicker: UIViewControllerRepresentable {
    var onImagePicked: (UIImage) -> Void
    
    func makeCoordinator() -> Coordinator {
        Coordinator(onImagePicked: onImagePicked)
    }
    
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onImagePicked: (UIImage) -> Void
        
        init(onImagePicked: @escaping (UIImage) -> Void) {
            self.onImagePicked = onImagePicked
        }
        
        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]
        ) {
            if let img = info[.editedImage] as? UIImage ?? info[ .originalImage ] as? UIImage {
                onImagePicked(img)
            }
            picker.dismiss(animated: true)
        }
        
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}
extension AdminProductDraft {
    func toUpsertPayload(shopId: Int) -> MinisProductAPI.UpsertPayload {
        // 1) Build groups array for ModifierGroups
        //    We use group.title as the Title, and map Kind → mode/min/max
        let groups: [[String: Any]] = modifierGroups.map { group in
            let items: [[String: Any]] = group.items.map { item in
                let price = Double(item.extraPriceText.replacingOccurrences(of: ",", with: ".")) ?? 0
                return [
                    "OptionName": item.name,
                    "ExtraPrice": price
                ]
            }

            // Selection rules: options = single; additions = multi
            let selection: [String: Any] = {
                switch group.kind {
                case .options:
                    return [
                        "mode": "single",
                        "min": 1,
                        "max": 1
                    ]
                case .additions:
                    return [
                        "mode": "multi",
                        "min": 0,
                        "max": max(items.count, 1)
                    ]
                }
            }()

            return [
                // you can keep GroupId stable by using the UUID or a slug
                "GroupId": group.id.uuidString,
                "Title": group.title,       // 👈 THIS is your custom title
                "Selection": selection,
                "Items": items
            ]
        }

        // 2) Legacy flat modifiers – you can keep them or drop them.
        //    Since buildJsonData prefers groups when non-empty,
        //    it’s safe to leave these empty now.
        let optionsArr: [[String: Any]] = []
        let additionsArr: [[String: Any]] = []
        let removalsArr: [[String: Any]] = []

        // 3) Build jsonData with your helper (now groups is NON-empty)
        let jsonData = buildJsonData(
            description: description,
            optionsArr: optionsArr,
            additionsArr: additionsArr,
            removalsArr: removalsArr,
            groups: groups
        )

        // 4) Normalise the rest of the fields
        let price = Double(priceText.replacingOccurrences(of: ",", with: ".")) ?? 0
        let cleanCategory = category.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalCategory = cleanCategory.isEmpty ? "General" : cleanCategory

        let rawImage = imageURL.trimmingCharacters(in: .whitespacesAndNewlines)
               let cleanImage: String
               if rawImage.isEmpty {
                   // default placeholder ONLY if nothing was set
                   cleanImage = "https://beithaam.com/wp-content/uploads/2024/12/share.jpg"
               } else {
                   // could be short name (shop12_...) or full URL
                   cleanImage = rawImage
               }

        return .init(
            Id: productId,            // existing DB id or nil for new
            MiniAppId: shopId,
            Name: name,
            Price: price,
            Category: finalCategory,
            Image: cleanImage,
            Sort: nil,
            Status: true,
            JsonData: jsonData
        )
    }
}
