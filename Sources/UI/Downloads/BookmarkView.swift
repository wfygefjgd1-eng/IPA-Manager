import SwiftUI

struct BookmarkView: View {
    @Environment(\.dismiss) private var dismiss
    let onSelect: (URL) -> Void

    @State private var bookmarks: [BookmarkItem] = BookmarkStore.shared.load()
    @State private var showAddAlert = false
    @State private var newBookmarkURL = ""
    @State private var showError = false

    var body: some View {
        NavigationView {
            List {
                Section("内置书签") {
                    ForEach(BookmarkItem.githubPresets) { item in
                        bookmarkRow(item)
                    }
                }

                if !userBookmarks.isEmpty {
                    Section("我的书签") {
                        ForEach(userBookmarks) { item in
                            bookmarkRow(item)
                        }
                        .onDelete { indexSet in
                            deleteBookmarks(indexSet)
                        }
                    }
                }
            }
            .navigationTitle("书签")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        newBookmarkURL = ""
                        showAddAlert = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .alert("添加书签", isPresented: $showAddAlert) {
                TextField("https://...", text: $newBookmarkURL)
                    .keyboardType(.URL)
                    .autocapitalization(.none)
                Button("取消", role: .cancel) {}
                Button("添加") {
                    addFromTextField()
                }
            } message: {
                Text("请输入网址")
            }
            .alert("提示", isPresented: $showError) {
                Button("确定", role: .cancel) {}
            } message: {
                Text("请输入有效的网址")
            }
        }
    }

    private var userBookmarks: [BookmarkItem] {
        bookmarks.filter { !$0.isPreset }
    }

    private func bookmarkRow(_ item: BookmarkItem) -> some View {
        Button {
            if let url = URL(string: item.url) {
                onSelect(url)
            }
        } label: {
            HStack {
                Image(systemName: item.icon)
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading) {
                    Text(item.title)
                        .foregroundColor(.primary)
                    Text(item.url)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private func addFromTextField() {
        let trimmed = newBookmarkURL.trimmingCharacters(in: .whitespacesAndNewlines)
        var urlString = trimmed
        if !urlString.hasPrefix("http://") && !urlString.hasPrefix("https://") {
            urlString = "https://" + urlString
        }
        guard let url = URL(string: urlString), url.scheme != nil else {
            showError = true
            return
        }

        var title = url.host ?? url.absoluteString
        let path = url.path
        if !path.isEmpty && path != "/" {
            title = URL(fileURLWithPath: path).lastPathComponent
        }

        let item = BookmarkItem(
            title: title,
            url: url.absoluteString,
            icon: "bookmark.fill",
            isPreset: false
        )
        if !bookmarks.contains(where: { $0.url == item.url }) {
            bookmarks.append(item)
        }
        BookmarkStore.shared.save(bookmarks)
        newBookmarkURL = ""
    }

    private func deleteBookmarks(_ indexSet: IndexSet) {
        let userStart = bookmarks.prefix(while: { $0.isPreset }).count
        for index in indexSet {
            let target = userStart + index
            guard target < bookmarks.count else { continue }
            bookmarks.remove(at: target)
        }
        BookmarkStore.shared.save(bookmarks)
    }
}

struct BookmarkItem: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var title: String
    var url: String
    var icon: String
    var isPreset: Bool = false

    static let githubPresets: [BookmarkItem] = [
        BookmarkItem(title: "GitHub", url: "https://github.com", icon: "globe"),
        BookmarkItem(title: "GitHub Releases", url: "https://github.com/login?return_to=%2F", icon: "tag.fill")
    ]
}

final class BookmarkStore {
    static let shared = BookmarkStore()

    private let key = "saved_bookmarks"

    func load() -> [BookmarkItem] {
        let presets = BookmarkItem.githubPresets
        guard let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONDecoder().decode([BookmarkItem].self, from: data) else {
            return presets
        }
        return presets + saved.filter { !$0.isPreset }
    }

    func save(_ items: [BookmarkItem]) {
        let userItems = items.filter { !$0.isPreset }
        guard let data = try? JSONEncoder().encode(userItems) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    func addCurrentPage(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString), url.scheme != nil else { return false }
        let all = load()
        if all.contains(where: { $0.url == urlString }) { return true }

        var title = url.host ?? url.absoluteString
        let path = url.path
        if !path.isEmpty && path != "/" {
            title = URL(fileURLWithPath: path).lastPathComponent
        }

        let item = BookmarkItem(
            title: title,
            url: urlString,
            icon: "bookmark.fill",
            isPreset: false
        )
        var user = all.filter { !$0.isPreset }
        user.append(item)
        save(user)
        return true
    }
}