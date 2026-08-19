import SwiftUI

struct AppsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedApp: AppInfo?

    var body: some View {
        NavigationView {
            Group {
                if appState.installedApps.isEmpty {
                    emptyView
                } else {
                    List(appState.installedApps) { app in
                        Button {
                            selectedApp = app
                        } label: {
                            appRow(app)
                        }
                    }
                }
            }
            .navigationTitle("已签应用")
            .sheet(item: $selectedApp) { app in
                AppDetailView(app: app)
            }
        }
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "apps.iphone")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("暂无已签名应用")
                .font(.headline)
            Text("签名完成后，应用会出现在这里")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    private func appRow(_ app: AppInfo) -> some View {
        HStack(spacing: 12) {
            AppIconView(iconPath: app.iconPath)
            VStack(alignment: .leading, spacing: 4) {
                Text(app.name.isEmpty ? "未命名" : app.name)
                    .font(.headline)
                Text(app.bundleID.isEmpty ? "未知 Bundle ID" : app.bundleID)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("\(app.version) · \(app.sizeDescription)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}