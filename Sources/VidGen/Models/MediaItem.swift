import Foundation
import Photos
import UIKit

enum MediaType: Equatable {
    case photo
    case video
    case livePhoto
}

struct MediaItem: Identifiable {
    let id: UUID
    let asset: PHAsset
    let type: MediaType

    var thumbnail: UIImage?
    var extractedVideoURL: URL?     // local .mov extracted from Live Photo or regular video
    var avAsset: AVAsset?           // loaded AVAsset for video/livePhoto

    // Analysis results
    var bestSegmentStart: Double = 0
    var bestSegmentScore: Double = 0
    var analysisState: AnalysisState = .pending

    // Per-clip override (inherits from AppState.targetClipDuration by default)
    var clipDurationOverride: Double? = nil

    var duration: Double {
        if asset.mediaType == .video || type == .livePhoto {
            return asset.duration > 0 ? asset.duration : 3.0
        }
        return 0  // photos have no inherent duration; the global setting is used
    }

    enum AnalysisState: Equatable {
        case pending
        case analyzing
        case complete(score: Double)
        case failed
    }
}
