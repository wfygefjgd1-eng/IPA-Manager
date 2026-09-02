import SwiftUI

struct BookmarkView: View {
    @Environment(\.dismiss) private var dismiss
    let onSelect: (URL) -> Void

    @State private var bookmarks: [BookmarkItem] = BookmarkStore.shared.load()
    @State private var newBookmarkURL = ""

    /// 区分「添加书签输入」与「提示错误」两种弹窗模式（合并后的单个 alert）
    private enum BookmarkAlertCase {
        case add
        case invalidURL
    }

    @State private var alertCase: BookmarkAlertCase = .add
    @State private var showAlert = false
    @State private var showAddedToast = false
    /// 添加成功 toast 的可取消计时（见添加书签处的使用）
    @State private var addedToastWorkItem: DispatchWorkItem?

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
                        alertCase = .add
                        showAlert = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            // 合并后的单个 alert：用 alertCase 区分「添加书签输入」与「提示错误」
            .alert(
                Text(alertCase == .invalidURL ? "提示" : "添加书签"),
                isPresented: $showAlert
            ) {
                switch alertCase {
                case .add:
                    TextField("https://...", text: $newBookmarkURL)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                    Button("取消", role: .cancel) {}
                    Button("添加") {
                        addFromTextField()
                    }
                case .invalidURL:
                    Button("确定", role: .cancel) {}
                }
            } message: {
                switch alertCase {
                case .add:
                    Text("请输入网址")
                case .invalidURL:
                    Text("请输入有效的网址")
                }
            }
            // 添加成功后的轻提示
            .overlay(alignment: .bottom) {
                if showAddedToast {
                    Text("已添加到我的书签")
                        .font(.footnote)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.black.opacity(0.75)))
                        .foregroundColor(.white)
                        .padding(.bottom, 16)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: showAddedToast)
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
            alertCase = .invalidURL
            // 等当前 alert 先完成 dismiss，再弹出错误提示
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                showAlert = true
            }
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
            showAddedToast = true
            // 可取消计时：连续添加两个书签时，旧实现的第一个 1.5s 计时到点会把
            // 第二个刚亮的 toast 提前藏掉（与 BrowserView 的 toast 互踩同源）
            addedToastWorkItem?.cancel()
            let work = DispatchWorkItem { showAddedToast = false }
            addedToastWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
        }
        BookmarkStore.shared.save(bookmarks)
        newBookmarkURL = ""
    }

    private func deleteBookmarks(_ indexSet: IndexSet) {
        let userStart = bookmarks.prefix(while: { $0.isPreset }).count
        // 降序删除：后面索引先删，前面索引不受前面元素被删的影响，避免删错条目
        let targets = indexSet.sorted(by: >)
        for index in targets {
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
        BookmarkItem(title: "GitHub Releases", url: "https://github.com/releases", icon: "tag.fill")
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

    /// 收藏当前页：返回 true 表示（已存在或已新增）收藏成功；false 表示 URL 无效被拒绝。
    /// 与 BookmarkView.addFromTextField 的“重复不再提示新增”语义保持一致。
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
