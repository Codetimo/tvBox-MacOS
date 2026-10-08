import AVKit
import Combine
import Foundation

@MainActor
final class PlaybackCoordinator: ObservableObject {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var errorMessage: String?

    func play(_ channel: TVChannel) {
        guard channel.streamURL.scheme == "http" || channel.streamURL.scheme == "https" else {
            errorMessage = "Only HTTP(S) playback is enabled in the MVP."
            return
        }
        errorMessage = nil
        let item = AVPlayerItem(url: channel.streamURL)
        player = AVPlayer(playerItem: item)
        player?.play()
    }

    func stop() {
        player?.pause()
        player = nil
    }
}
