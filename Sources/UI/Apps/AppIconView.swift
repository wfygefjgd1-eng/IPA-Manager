import SwiftUI
import UIKit

struct AppIconView: View {
    let iconPath: String?

    var body: some View {
        Group {
            if let iconPath = iconPath,
               let uiImage = UIImage(contentsOfFile: iconPath) {
                Image(uiImage: uiImage)
                    .resizable()
            } else {
                Image(systemName: "app.fill")
                    .resizable()
                    .foregroundColor(.gray)
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}