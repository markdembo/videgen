import Foundation
import AVFoundation
import Combine

@MainActor
final class AppState: ObservableObject {

    // MARK: - Media
    @Published var mediaItems: [MediaItem] = []

    // MARK: - Audio
    @Published var youtubeURL: String = ""
    @Published var audioLocalURL: URL?
    @Published var audioAsset: AVAsset?
    @Published var audioDuration: Double = 0
    @Published var waveformSamples: [Float] = []
    @Published var beatPositions: [Double] = []   // relative to trimStart
    @Published var estimatedBPM: Double = 0

    // Trim range (seconds, relative to start of loaded audio)
    @Published var trimStart: Double = 0
    @Published var trimEnd: Double = 30

    // MARK: - Composition settings
    @Published var targetClipDuration: Double = 2.0  // 1–3 s

    // MARK: - Status flags
    @Published var isLoadingAudio: Bool = false
    @Published var isDetectingBeats: Bool = false
    @Published var isExporting: Bool = false
    @Published var exportProgress: Double = 0
    @Published var exportedVideoURL: URL?
    @Published var errorMessage: String?

    // MARK: - Helpers
    var trimDuration: Double { max(0, trimEnd - trimStart) }

    func removeMedia(at offsets: IndexSet) {
        mediaItems.remove(atOffsets: offsets)
    }

    func moveMedia(from source: IndexSet, to destination: Int) {
        mediaItems.move(fromOffsets: source, toOffset: destination)
    }

    func updateItem(_ item: MediaItem) {
        if let idx = mediaItems.firstIndex(where: { $0.id == item.id }) {
            mediaItems[idx] = item
        }
    }

    func clearError() { errorMessage = nil }
}
