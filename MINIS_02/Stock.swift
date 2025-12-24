import SwiftUI
import Kingfisher
import Combine

// MARK: - Model

struct StockItem: Identifiable {
    let id: Int
    let name: String
    let category: String
    let imageURL: String?
    var isEnabled: Bool
    var stock: Int
}

@MainActor
final class StockViewModel: ObservableObject {
    @Published var items: [StockItem] = []
    @Published var searchText: String = ""

    init() {
        // TODO: replace with API load
        items = [
            .init(id: 1, name: "קרואסון חמאה", category: "מאפים", imageURL: nil, isEnabled: true, stock: 24),
            .init(id: 2, name: "קפה הפוך", category: "שתייה חמה", imageURL: nil, isEnabled: true, stock: 999),
            .init(id: 3, name: "סלט יווני", category: "סלטים", imageURL: nil, isEnabled: false, stock: 5)
        ]
    }

    var grouped: [String: [StockItem]] {
        let filtered = filteredItems
        return Dictionary(grouping: filtered, by: { $0.category })
    }

    private var filteredItems: [StockItem] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return items }
        let lower = q.lowercased()
        return items.filter {
            $0.name.lowercased().contains(lower) ||
            $0.category.lowercased().contains(lower)
        }
    }
}

// MARK: - View

struct StockView: View {
    @Environment(\.isRtl) private var isRtl
    @StateObject private var vm = StockViewModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar
                Divider()
                listBody
            }
            .navigationTitle(isRtl ? "מלאי" : "Stock")
            .environment(\.layoutDirection, isRtl ? .rightToLeft : .leftToRight)
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(isRtl ? "חיפוש מוצר או קטגוריה" : "Search product or category",
                          text: $vm.searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            if !vm.searchText.isEmpty {
                Button { vm.searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 18))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var listBody: some View {
        List {
            ForEach(vm.grouped.keys.sorted(), id: \.self) { cat in
                if let items = vm.grouped[cat] {
                    Section(header: Text(cat).font(.system(size: 15, weight: .semibold))) {
                        ForEach(items) { item in
                            StockRow(
                                item: binding(for: item)
                            )
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func binding(for item: StockItem) -> Binding<StockItem> {
        guard let idx = vm.items.firstIndex(where: { $0.id == item.id }) else {
            fatalError("Stock item not found")
        }
        return $vm.items[idx]
    }
}

// MARK: - Row

struct StockRow: View {
    @Binding var item: StockItem
    @Environment(\.isRtl) private var isRtl

    var body: some View {
        HStack(spacing: 10) {
            thumbnail

            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(2)

                Text(item.category)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            Spacer(minLength: 8)

            // Amount stepper and toggle on the trailing side
            HStack(spacing: 10) {
                stockStepper

                Toggle("", isOn: $item.isEnabled)
                    .labelsHidden()
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var thumbnail: some View {
        Group {
            if let urlString = item.imageURL,
               let url = URL(string: urlString) {
                KFImage(url)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color(.systemGray5)
                    Image(systemName: "photo")
                        .foregroundColor(.secondary)
                        .font(.system(size: 16, weight: .medium))
                }
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var stockStepper: some View {
        HStack(spacing: 6) {
            Button {
                if item.stock > 0 {
                    item.stock -= 1
                }
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 28, height: 28)
                    .background(Color(.systemGray5))
                    .clipShape(Circle())
            }

            // Blank when stock == 0
            Text(item.stock == 0 ? "" : "\(item.stock)")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 32, alignment: .center)

            Button {
                item.stock += 1
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 28, height: 28)
                    .background(Color(.systemGray5))
                    .clipShape(Circle())
            }
        }
    }
}
