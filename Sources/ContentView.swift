import SwiftUI

struct ContentView: View {
    @ObservedObject var service: HarnessService

    var body: some View {
        Group {
            if let url = service.serverURL {
                HarnessWebView(url: url)
            } else {
                VStack(spacing: 16) {
                    if service.state == .starting || service.state == .installing {
                        ProgressView()
                            .controlSize(.large)
                    }

                    Text("DeepSeek Harness")
                        .font(.title2.weight(.semibold))
                    Text(service.statusText)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 520)

                    if case .failed = service.state {
                        HStack(spacing: 12) {
                            Button("重新启动") {
                                service.restart()
                            }
                            .keyboardShortcut(.defaultAction)

                            Button("安装全局 dsh") {
                                service.installGlobalDSH()
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(32)
            }
        }
        .frame(minWidth: 960, minHeight: 640)
    }
}
