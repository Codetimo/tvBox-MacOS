import SwiftUI
import AVKit

@main
struct TVBoxMacOSApp: App {
    var body: some Scene {
        WindowGroup {
            ChannelBrowserView()
        }
    }
}

struct ChannelBrowserView: View {
    @StateObject private var playback = PlaybackCoordinator()
    @State private var searchText = ""
    @State private var sourceURLText = ""
    @State private var channels: [TVChannel] = []
    @State private var isLoading = false
    @State private var statusMessage: String?

    private var filteredChannels: [TVChannel] {
        guard !searchText.isEmpty else { return channels }
        return channels.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.group.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 12) {
                HStack {
                    TextField("M3U 或 TVBox JSON URL", text: $sourceURLText)
                        .textFieldStyle(.roundedBorder)
                    Button("导入") {
                        Task { await loadSource() }
                    }
                    .disabled(isLoading || sourceURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal)

                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                }

                List(filteredChannels) { channel in
                    Button {
                        playback.play(channel)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(channel.name)
                            Text(channel.group)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .searchable(text: $searchText)
            }
            .navigationTitle("TVBox Mac")
        } detail: {
            if let player = playback.player {
                VideoPlayer(player: player)
                    .frame(minWidth: 640, minHeight: 360)
            } else {
                ContentUnavailableView(
                    "选择频道",
                    systemImage: "play.tv",
                    description: Text("导入 M3U 或 TVBox JSON 后开始播放")
                )
            }
        }
    }

    @MainActor
    private func loadSource() async {
        guard let url = URL(string: sourceURLText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            statusMessage = "URL 格式不正确。"
            return
        }

        isLoading = true
        statusMessage = "正在导入源…"
        defer { isLoading = false }

        do {
            let snapshot = try await SourceLoader().load(url: url)
            channels = snapshot.channels
            statusMessage = "已导入 (channels.count) 个频道。"
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}
