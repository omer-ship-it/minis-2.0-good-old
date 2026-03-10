import Foundation
import SwiftUI

struct ModifierTemplateDraft: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String
    var kind: AdminModifierGroupDraft.Kind
    var items: [ModifierTemplateItemDraft]
    var defaultFirst: Bool = false
}

struct ModifierTemplateItemDraft: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var extraPriceText: String
    var linkedProductId: Int? = nil
}

@MainActor
final class ModifierTemplatesStore: ObservableObject {
    static let shared = ModifierTemplatesStore()

    @Published var templates: [ModifierTemplateDraft] = []

    private let key = "admin.modifier.templates.v1"

    private init() {
        load()
    }

    func load() {
        guard
            let data = UserDefaults.standard.data(forKey: key),
            let decoded = try? JSONDecoder().decode([ModifierTemplateDraft].self, from: data)
        else {
            templates = []
            return
        }
        templates = decoded
    }

    func save() {
        if let data = try? JSONEncoder().encode(templates) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func add(_ template: ModifierTemplateDraft) {
        templates.insert(template, at: 0)
        save()
    }

    func update(_ template: ModifierTemplateDraft) {
        guard let idx = templates.firstIndex(where: { $0.id == template.id }) else { return }
        templates[idx] = template
        save()
    }

    func delete(_ template: ModifierTemplateDraft) {
        templates.removeAll { $0.id == template.id }
        save()
    }

    func duplicate(_ template: ModifierTemplateDraft) {
        var copy = template
        copy.id = UUID()
        copy.title += " Copy"
        templates.insert(copy, at: 0)
        save()
    }
}

struct ModifierTemplatesAdminView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isRtl) private var isRtl

    @StateObject private var store = ModifierTemplatesStore.shared
    @State private var searchText: String = ""
    @State private var selectedTemplate: ModifierTemplateDraft? = nil
    @State private var showCreate = false

    let allProducts: [ShellMenuItem]
    let onPick: ((ModifierTemplateDraft) -> Void)?

    init(
        allProducts: [ShellMenuItem] = [],
        onPick: ((ModifierTemplateDraft) -> Void)? = nil
    ) {
        self.allProducts = allProducts
        self.onPick = onPick
    }

    private var isPickerMode: Bool {
        onPick != nil
    }

    private var filteredTemplates: [ModifierTemplateDraft] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return store.templates }

        return store.templates.filter { template in
            template.title.lowercased().contains(q)
            || template.items.contains(where: { $0.name.lowercased().contains(q) })
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)

                    TextField(
                        isRtl ? "חפש תבנית…" : "Search template…",
                        text: $searchText
                    )
                    .textInputAutocapitalization(.none)
                    .autocorrectionDisabled()

                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 16)
                .padding(.top, 12)

                List {
                    ForEach(filteredTemplates) { template in
                        HStack(spacing: 12) {
                            Button {
                                if let onPick {
                                    onPick(template)
                                    dismiss()
                                } else {
                                    selectedTemplate = template
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(template.title)
                                            .font(.system(size: 16, weight: .semibold))
                                            .foregroundColor(.primary)

                                        Spacer()

                                        Text(
                                            template.kind == .options
                                            ? (isRtl ? "אפשרויות" : "Options")
                                            : (isRtl ? "תוספות" : "Extras")
                                        )
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundColor(.secondary)
                                    }

                                    Text(template.items.map(\.name).joined(separator: " • "))
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)

                                    if template.kind == .options {
                                        Text(
                                            template.defaultFirst
                                            ? (isRtl ? "ברירת מחדל: כן" : "Default first: Yes")
                                            : (isRtl ? "ברירת מחדל: לא" : "Default first: No")
                                        )
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Button {
                                selectedTemplate = template
                            } label: {
                                Image(systemName: "pencil.circle.fill")
                                    .font(.system(size: 22, weight: .semibold))
                                    .foregroundColor(.blue)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 4)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                store.delete(template)
                            } label: {
                                Label(isRtl ? "מחק" : "Delete", systemImage: "trash")
                            }

                            Button {
                                store.duplicate(template)
                            } label: {
                                Label(isRtl ? "שכפל" : "Duplicate", systemImage: "plus.square.on.square")
                            }
                            .tint(.blue)
                        }
                    }

                    if filteredTemplates.isEmpty {
                        Text(isRtl ? "אין תבניות עדיין" : "No templates yet")
                            .foregroundColor(.secondary)
                            .padding(.vertical, 8)
                    }

                    Color.clear
                        .frame(height: 80)
                        .listRowBackground(Color.clear)
                }
                .listStyle(.insetGrouped)
            }
            .navigationTitle(
                isPickerMode
                ? (isRtl ? "בחר תבנית" : "Choose Template")
                : (isRtl ? "תבניות קבוצות" : "Group Templates")
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: isRtl ? "chevron.right" : "chevron.left")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button {
                        showCreate = true
                    } label: {
                        Text(isRtl ? "הוסף תבנית" : "Add Template")
                            .font(.system(size: 16, weight: .bold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(Color.primary)
                            .foregroundColor(Color(.systemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 12)
                .background(Color(.systemBackground))
            }
            .sheet(isPresented: $showCreate) {
                ModifierTemplateEditorView(
                    template: ModifierTemplateDraft(
                        title: "",
                        kind: .options,
                        items: [],
                        defaultFirst: false
                    ),
                    allProducts: allProducts,
                    onSave: { newTemplate in
                        store.add(newTemplate)
                        showCreate = false
                    }
                )
                .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
            }
            .sheet(item: $selectedTemplate) { template in
                ModifierTemplateEditorView(
                    template: template,
                    allProducts: allProducts,
                    onSave: { updated in
                        store.update(updated)
                        selectedTemplate = nil
                    }
                )
                .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
            }
        }
        .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
    }
}

struct ModifierTemplateEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isRtl) private var isRtl

    @State private var template: ModifierTemplateDraft
    let allProducts: [ShellMenuItem]
    let onSave: (ModifierTemplateDraft) -> Void

    @State private var showProductPicker = false
    @State private var productSearchText: String = ""
    @State private var pendingItemId: UUID? = nil

    init(
        template: ModifierTemplateDraft,
        allProducts: [ShellMenuItem] = [],
        onSave: @escaping (ModifierTemplateDraft) -> Void
    ) {
        _template = State(initialValue: template)
        self.allProducts = allProducts
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField(
                            isRtl ? "שם קבוצה" : "Group title",
                            text: $template.title
                        )
                        .textFieldStyle(.roundedBorder)

                        Picker("", selection: $template.kind) {
                            Text(isRtl ? "אפשרויות" : "Options")
                                .tag(AdminModifierGroupDraft.Kind.options)
                            Text(isRtl ? "תוספות" : "Extras")
                                .tag(AdminModifierGroupDraft.Kind.additions)
                        }
                        .pickerStyle(.segmented)

                        if template.kind == .options {
                            Toggle(
                                isRtl ? "התחל עם ברירת מחדל" : "Default first",
                                isOn: $template.defaultFirst
                            )
                            .toggleStyle(.switch)
                            .tint(.blue)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section(header: Text(isRtl ? "פריטים" : "Items")) {
                    ForEach(Array(template.items.enumerated()), id: \.element.id) { index, item in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 4) {
                                TextField(
                                    template.kind == .options
                                    ? (isRtl ? "אפשרות" : "Option")
                                    : (isRtl ? "תוספת" : "Extra"),
                                    text: Binding(
                                        get: { template.items[index].name },
                                        set: { template.items[index].name = $0 }
                                    )
                                )
                                .textFieldStyle(.roundedBorder)

                                if let linkedId = template.items[index].linkedProductId {
                                    Text("#\(linkedId)")
                                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .padding(.horizontal, 4)
                                }
                            }

                            PriceTextField(
                                text: Binding(
                                    get: { template.items[index].extraPriceText },
                                    set: { template.items[index].extraPriceText = $0 }
                                )
                            )
                            .frame(width: 70)

                            Button {
                                pendingItemId = item.id
                                productSearchText = ""
                                showProductPicker = true
                            } label: {
                                Image(systemName: template.items[index].linkedProductId == nil ? "link" : "link.circle.fill")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundColor(template.items[index].linkedProductId == nil ? .secondary : .blue)
                            }
                            .buttonStyle(.plain)

                            Button {
                                template.items.removeAll { $0.id == item.id }
                                if template.items.isEmpty {
                                    template.items.append(
                                        ModifierTemplateItemDraft(name: "", extraPriceText: "0.0")
                                    )
                                }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 2)
                    }

                    Button {
                        template.items.append(
                            ModifierTemplateItemDraft(name: "", extraPriceText: "0.0")
                        )
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus.circle.fill")
                            Text(
                                template.kind == .options
                                ? (isRtl ? "הוסף אפשרות" : "Add option")
                                : (isRtl ? "הוסף תוספת" : "Add extra")
                            )
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(isRtl ? "עריכת תבנית" : "Edit Template")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isRtl ? "ביטול" : "Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(isRtl ? "שמור" : "Save") {
                        var cleaned = template
                        cleaned.title = cleaned.title.trimmingCharacters(in: .whitespacesAndNewlines)
                        cleaned.items = cleaned.items.compactMap { item in
                            let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !name.isEmpty else { return nil }

                            var x = item
                            x.name = name

                            let raw = item.extraPriceText
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                                .replacingOccurrences(of: ",", with: ".")
                            let price = Double(raw) ?? 0
                            x.extraPriceText = String(format: "%.2f", price)
                            return x
                        }

                        guard !cleaned.title.isEmpty, !cleaned.items.isEmpty else { return }
                        onSave(cleaned)
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showProductPicker) {
                ModifierTemplateProductPickerSheet(
                    isRtl: isRtl,
                    currency: UserDefaults.standard.string(forKey: "currency") ?? "₪",
                    products: allProducts,
                    searchText: $productSearchText,
                    onPick: { product in
                        guard let pendingItemId,
                              let idx = template.items.firstIndex(where: { $0.id == pendingItemId })
                        else { return }

                        template.items[idx].linkedProductId = product.id
                        template.items[idx].name = product.name
                        showProductPicker = false
                        self.pendingItemId = nil
                    },
                    onUnlink: {
                        guard let pendingItemId,
                              let idx = template.items.firstIndex(where: { $0.id == pendingItemId })
                        else { return }

                        template.items[idx].linkedProductId = nil
                        showProductPicker = false
                        self.pendingItemId = nil
                    },
                    onClose: {
                        showProductPicker = false
                        pendingItemId = nil
                    }
                )
                .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
            }
            .onAppear {
                if template.items.isEmpty {
                    template.items = [ModifierTemplateItemDraft(name: "", extraPriceText: "0.0")]
                }
            }
        }
    }
}

extension ModifierTemplateDraft {
    func toAdminModifierGroupDraft() -> AdminModifierGroupDraft {
        AdminModifierGroupDraft(
            id: UUID(),
            title: title,
            kind: kind,
            items: items.map {
                AdminModifierItemDraft(
                    id: UUID(),
                    name: $0.name,
                    extraPriceText: $0.extraPriceText,
                    linkedProductId: $0.linkedProductId
                )
            },
            defaultFirst: defaultFirst
        )
    }
}

private struct ModifierTemplateProductPickerSheet: View {
    let isRtl: Bool
    let currency: String
    let products: [ShellMenuItem]
    @Binding var searchText: String
    let onPick: (ShellMenuItem) -> Void
    let onUnlink: () -> Void
    let onClose: () -> Void

    private var filtered: [ShellMenuItem] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty {
            return products.sorted { $0.name < $1.name }
        }

        return products.filter { product in
            product.name.lowercased().contains(q) ||
            String(product.id).contains(q) ||
            product.category.lowercased().contains(q)
        }
        .sorted { $0.name < $1.name }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)

                    TextField(
                        isRtl ? "חפש מוצר…" : "Search product…",
                        text: $searchText
                    )
                    .textInputAutocapitalization(.none)
                    .autocorrectionDisabled()

                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 16)
                .padding(.top, 12)

                List {
                    Section {
                        Button(role: .destructive) {
                            onUnlink()
                        } label: {
                            HStack {
                                Image(systemName: "link.badge.minus")
                                Text(isRtl ? "הסר קישור" : "Remove link")
                            }
                        }
                    }

                    ForEach(filtered) { product in
                        Button {
                            onPick(product)
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(product.name)
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundColor(.primary)

                                    Text("#\(product.id) • \(product.category) • \(String(format: "\(currency)%.2f", product.price))")
                                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }

                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    if products.isEmpty {
                        Text(isRtl ? "לא נמצאו מוצרים" : "No products found")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle(isRtl ? "קישור למוצר" : "Link to product")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: onClose) {
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
