import Foundation
import Photos
import AVFoundation

enum LivePhotoExtractor {

    enum ExtractionError: LocalizedError {
        case notLivePhoto
        case noVideoResource
        case cannotAccessVideo

        var errorDescription: String? {
            switch self {
            case .notLivePhoto:      return "Asset is not a Live Photo"
            case .noVideoResource:   return "No paired video found in Live Photo"
            case .cannotAccessVideo: return "Could not access video data"
            }
        }
    }

    // MARK: - Public

    /// Returns a local file URL containing the video for any media asset.
    /// For Live Photos: extracts the paired .mov.
    /// For regular videos: exports via AVAssetExportSession to guarantee a local URL.
    static func extractVideo(from asset: PHAsset) async throws -> URL {
        if asset.mediaSubtypes.contains(.photoLive) {
            return try await extractLivePhotoVideo(asset: asset)
        } else if asset.mediaType == .video {
            return try await exportVideo(asset: asset)
        }
        throw ExtractionError.cannotAccessVideo
    }

    // MARK: - Live Photo

    private static func extractLivePhotoVideo(asset: PHAsset) async throws -> URL {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let videoResource = resources.first(where: { $0.type == .pairedVideo }) else {
            throw ExtractionError.noVideoResource
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lp_\(asset.localIdentifier.prefix(8))_\(UUID().uuidString)")
            .appendingPathExtension("mov")

        try? FileManager.default.removeItem(at: outputURL)

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(
                for: videoResource,
                toFile: outputURL,
                options: options
            ) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }

        return outputURL
    }

    // MARK: - Regular video

    private static func exportVideo(asset: PHAsset) async throws -> URL {
        let avAsset: AVAsset = try await withCheckedThrowingContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat

            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
                if let error = info?[PHImageErrorKey] as? Error {
                    continuation.resume(throwing: error)
                } else if let avAsset {
                    continuation.resume(returning: avAsset)
                } else {
                    continuation.resume(throwing: ExtractionError.cannotAccessVideo)
                }
            }
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vid_\(asset.localIdentifier.prefix(8))_\(UUID().uuidString)")
            .appendingPathExtension("mov")

        try? FileManager.default.removeItem(at: outputURL)

        guard let exporter = AVAssetExportSession(asset: avAsset, presetName: AVAssetExportPresetHighestQuality) else {
            throw ExtractionError.cannotAccessVideo
        }
        exporter.outputURL = outputURL
        exporter.outputFileType = .mov

        await exporter.export()
        if let error = exporter.error { throw error }
        return outputURL
    }
}
