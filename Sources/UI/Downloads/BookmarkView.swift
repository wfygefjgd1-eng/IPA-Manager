import SwiftUI

struct BookmarkView: View {
    @Environment(\.dismiss) private var dismiss
    let onSelect: (URL) -> Void

    @State private var bookmarks: [BookmarkItem] = BookmarkStore.shared.load()

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
                        addBookmark()
                    } label: {
                        Image(systemName: "plus")
                    }
                }
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

    private func addBookmark() {
        let alert = UIAlertController(title: "添加书签", message: "输入网址", preferredStyle: .alert)
        alert.addTextField { textField in
            textField.placeholder = "https://..."
            textField.keyboardType = .URL
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "添加", style: .default) { _ in
            guard let text = alert.textFields?.first?.text,
                  let url = URL(string: text),
                  url.scheme != nil else { return }

            let title = url.host ?? url.absoluteString
            let item = BookmarkItem(title: title, url: url.absoluteString, icon: "bookmark.fill", isPreset: false)
            bookmarks.append(item)
            BookmarkStore.shared.save(bookmarks)
        })

        if let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first?.windows.first {
            scene.rootViewController?.present(alert, animated: true)
        }
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

    func addCurrentPage(_ urlString: String) {
        guard let url = URL(string: urlString), url.scheme != nil else { return }
        let all = load()
        if all.contains(where: { $0.url == urlString }) { return }

        var title = url.absoluteString
        let path = url.path
        if !path.isEmpty && path != "/" {
            title = URL(fileURLWithPath: path).lastPathComponent
        } else if let host = url.host {
            title = host
        }

        let item = BookmarkItem(
            title: title.isEmpty ? "书签" : title,
            url: urlString,
            icon: "bookmark.fill",
            isPreset: false
        )
        var user = all.filter { !$0.isPreset }
        user.append(item)
        save(user)
    }
}