import SwiftUI
import UIKit

/// マイク権限が拒否されたときのフォールバック UI。設定アプリへ誘導する。
struct PermissionDeniedView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "mic.slash.fill")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)

            Text("マイクへのアクセスが必要です")
                .font(.title3.weight(.semibold))

            Text("このアプリはスピーカーから出た音をマイクで拾って解析します。\n設定アプリの「マイク」を有効にしてください。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("設定を開く") {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}

#Preview {
    PermissionDeniedView()
}
