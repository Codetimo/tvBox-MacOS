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
    @State private var channels: [TVChannel] = []

    private var filteredChannels: [TVChannel] {
        guard !searchText.isEmpty else { return channels }
        return channels.filter { $0.name.localizedCaseInsensitiveContains(searchText) || $0.group.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationSplitView {
            List(filteredChannels) { channel in
                Button {
                    playback.play(channel)
                } label: {
                    VStack(alignment: .leading) {
                        Text(channel.name)
                        Text(channel.group).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            .searchable(text: $searchText)
            .navigationTitle("TVBox Mac")
        } detail: {
            if let player = playback.player {
                VideoPlayer(player: player)
                    .frame(minWidth: 640, minHeight: 360)
            } else {
                ContentUnavailableView("选择频道", systemImage: "play.tv", description: Text("导入 M3U 或 TVBox JSON 后开始播放"))
            }
        }
    }
}
