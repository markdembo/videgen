import Foundation
import AVFoundation
import UIKit

enum VideoComposer {

    struct Config {
        /// Ordered list of clips. Each specifies which local video URL to use,
        /// where in that file to start, and how long to take from it.
        let clips: [ClipSpec]

        /// Already-downloaded local audio file.
        let audioURL: URL
        /// Seconds into the audio file where the selected segment begins.
        let audioTrimStart: Double
        /// Duration of the selected audio segment (seconds).
        let audioTrimDuration: Double

        /// Beat timestamps (seconds, relative to audioTrimStart).
        /// The composer creates a cut at each beat.
        let beatTimestamps: [Double]

        /// Fallback clip length when beat data is sparse.
        let targetClipDuration: Double

        /// Output frame size. Defaults to 1080 × 1920 (portrait 9:16).
        let renderSize: CGSize

        init(clips: [ClipSpec],
             audioURL: URL,
             audioTrimStart: Double,
             audioTrimDuration: Double,
             beatTimestamps: [Double],
             targetClipDuration: Double,
             renderSize: CGSize = CGSize(width: 1080, height: 1920)) {
            self.clips              = clips
            self.audioURL           = audioURL
            self.audioTrimStart     = audioTrimStart
            self.audioTrimDuration  = audioTrimDuration
            self.beatTimestamps     = beatTimestamps
            self.targetClipDuration = targetClipDuration
            self.renderSize         = renderSize
        }
    }

    struct ClipSpec {
        let videoURL: URL
        let segmentStart: Double   // best-moment start (seconds)
        let segmentDuration: Double
    }

    enum ComposerError: LocalizedError {
        case noClips
        case trackCreationFailed
        case noAudioTrack
        case exportFailed(String)

        var errorDescription: String? {
            switch self {
            case .noClips:               return "No video clips to compose."
            case .trackCreationFailed:   return "Could not create composition tracks."
            case .noAudioTrack:          return "Audio file has no audio track."
            case .exportFailed(let msg): return "Export failed: \(msg)"
            }
        }
    }

    // MARK: - Public

    static func compose(config: Config,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard !config.clips.isEmpty else { throw ComposerError.noClips }

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video,
                                                           preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioTrack = composition.addMutableTrack(withMediaType: .audio,
                                                           preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw ComposerError.trackCreationFailed }

        // ── Build cut list from beat timestamps ─────────────────────────────
        var cutTimes: [Double]
        if config.beatTimestamps.count > 1 {
            cutTimes = [0] + config.beatTimestamps
        } else {
            // Fallback: even cuts
            cutTimes = stride(from: 0.0, to: config.audioTrimDuration,
                              by: config.targetClipDuration).map { $0 }
        }
        // Cap at audio end
        cutTimes = cutTimes.filter { $0 < config.audioTrimDuration }
        if cutTimes.isEmpty { cutTimes = [0] }

        // ── Insert video segments ────────────────────────────────────────────
        var compositionTime = CMTime.zero
        var layerInstructions: [(CMTimeRange, CGAffineTransform)] = []

        for (i, cutStart) in cutTimes.enumerated() {
            let cutEnd = i + 1 < cutTimes.count ? cutTimes[i + 1] : config.audioTrimDuration
            let desiredDuration = min(cutEnd - cutStart, config.targetClipDuration)
            guard desiredDuration > 0 else { continue }

            let clip = config.clips[i % config.clips.count]
            let clipAsset = AVURLAsset(url: clip.videoURL)

            guard let srcTrack = try? await clipAsset.loadTracks(withMediaType: .video).first else {
                continue
            }

            let availableDuration = max(0, (try? await clipAsset.load(.duration).seconds) ?? 0 - clip.segmentStart)
            let actualDuration    = min(desiredDuration, availableDuration)
            guard actualDuration > 0.05 else { continue }

            let srcTimeRange = CMTimeRange(
                start:    CMTime(seconds: clip.segmentStart, preferredTimescale: 600),
                duration: CMTime(seconds: actualDuration,    preferredTimescale: 600)
            )

            try videoTrack.insertTimeRange(srcTimeRange, of: srcTrack, at: compositionTime)

            // Compute aspect-fill transform for this clip
            let naturalSize = try await srcTrack.load(.naturalSize)
            let preferred   = try await srcTrack.load(.preferredTransform)
            let transform   = aspectFillTransform(naturalSize: naturalSize,
                                                  preferred:   preferred,
                                                  target:      config.renderSize)
            let destRange = CMTimeRange(start: compositionTime,
                                        duration: CMTime(seconds: actualDuration, preferredTimescale: 600))
            layerInstructions.append((destRange, transform))

            compositionTime = CMTimeAdd(compositionTime, CMTime(seconds: actualDuration, preferredTimescale: 600))
            progress(0.5 * Double(i + 1) / Double(cutTimes.count))
        }

        // ── Insert audio segment ─────────────────────────────────────────────
        let audioAsset = AVURLAsset(url: config.audioURL)
        guard let srcAudioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first else {
            throw ComposerError.noAudioTrack
        }

        // Trim audio to match video duration
        let videoDuration   = compositionTime
        let maxAudioDuration = CMTime(seconds: config.audioTrimDuration, preferredTimescale: 600)
        let audioInsertDuration = CMTimeMinimum(videoDuration, maxAudioDuration)

        let audioSrcRange = CMTimeRange(
            start:    CMTime(seconds: config.audioTrimStart, preferredTimescale: 600),
            duration: audioInsertDuration
        )
        try audioTrack.insertTimeRange(audioSrcRange, of: srcAudioTrack, at: .zero)

        // Fade audio out over last 1 second
        let fadeStart = CMTimeSubtract(videoDuration, CMTime(seconds: 1, preferredTimescale: 600))
        if fadeStart > .zero {
            audioTrack.preferredVolume = 1.0
        }

        // ── Video composition (per-segment transforms) ────────────────────────
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize    = config.renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)

        var instructions: [AVVideoCompositionInstructionProtocol] = []
        for (range, transform) in layerInstructions {
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = range
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
            layer.setTransform(transform, at: range.start)
            instruction.layerInstructions = [layer]
            instructions.append(instruction)
        }
        videoComposition.instructions = instructions

        // ── Export ────────────────────────────────────────────────────────────
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vidgen_\(Int(Date().timeIntervalSince1970))")
            .appendingPathExtension("mp4")
        try? FileManager.default.removeItem(at: outputURL)

        guard let exporter = AVAssetExportSession(asset: composition,
                                                  presetName: AVAssetExportPreset1920x1080) else {
            throw ComposerError.exportFailed("Could not create export session")
        }
        exporter.outputURL          = outputURL
        exporter.outputFileType     = .mp4
        exporter.videoComposition   = videoComposition
        exporter.shouldOptimizeForNetworkUse = true

        // Poll progress
        let progressTimer = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                progress(0.5 + Double(exporter.progress) * 0.5)
            }
        }

        await exporter.export()
        progressTimer.cancel()
        progress(1.0)

        if let error = exporter.error {
            throw ComposerError.exportFailed(error.localizedDescription)
        }
        return outputURL
    }

    // MARK: - Aspect-fill transform

    /// Returns an `AVMutableVideoCompositionLayerInstruction` transform that
    /// aspect-fills `target` from a source track with the given `naturalSize`
    /// and `preferred` rotation transform.
    private static func aspectFillTransform(naturalSize: CGSize,
                                            preferred: CGAffineTransform,
                                            target: CGSize) -> CGAffineTransform {
        // Determine display size after applying the preferred rotation
        let rect = CGRect(origin: .zero, size: naturalSize).applying(preferred)
        let displaySize = CGSize(width: abs(rect.width), height: abs(rect.height))

        // Scale to aspect-fill target
        let scaleX = target.width  / max(displaySize.width,  1)
        let scaleY = target.height / max(displaySize.height, 1)
        let scale  = max(scaleX, scaleY)

        let scaledW = displaySize.width  * scale
        let scaledH = displaySize.height * scale
        let tx      = (target.width  - scaledW) / 2
        let ty      = (target.height - scaledH) / 2

        // Compose: preferred rotation → scale → center
        let scaleAndCenter = CGAffineTransform(scaleX: scale, y: scale)
            .translatedBy(x: tx / scale, y: ty / scale)
        return preferred.concatenating(scaleAndCenter)
    }
}
