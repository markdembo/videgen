import Foundation
import Photos
import UIKit
import Vision
import CoreImage
import AVFoundation

enum ClipAnalyzer {

    struct Result {
        let bestSegmentStart: Double
        let score: Double
    }

    // MARK: - Public entry point

    static func analyze(item: MediaItem, targetDuration: Double) async -> Result {
        switch item.type {
        case .photo:
            return await analyzePhoto(asset: item.asset)
        case .video, .livePhoto:
            return await analyzeVideoAsset(item: item, targetDuration: targetDuration)
        }
    }

    // MARK: - Photo analysis

    private static func analyzePhoto(asset: PHAsset) async -> Result {
        guard let image = await requestThumbnail(for: asset, size: CGSize(width: 400, height: 400)) else {
            return Result(bestSegmentStart: 0, score: 0)
        }
        let score = await scoreFrame(image)
        return Result(bestSegmentStart: 0, score: score)
    }

    // MARK: - Video analysis (sample frames, find best window)

    private static func analyzeVideoAsset(item: MediaItem, targetDuration: Double) async -> Result {
        // Use already-extracted URL if available, otherwise request AVAsset directly
        let avAsset: AVAsset
        if let url = item.extractedVideoURL {
            avAsset = AVURLAsset(url: url)
        } else if let existing = item.avAsset {
            avAsset = existing
        } else {
            guard let loaded = await loadAVAsset(for: item.asset) else {
                return Result(bestSegmentStart: 0, score: 0)
            }
            avAsset = loaded
        }

        let duration: Double
        do {
            let cmDuration = try await avAsset.load(.duration)
            duration = cmDuration.seconds
        } catch {
            return Result(bestSegmentStart: 0, score: 0)
        }

        guard duration > 0 else { return Result(bestSegmentStart: 0, score: 0) }

        let generator = AVAssetImageGenerator(asset: avAsset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 300, height: 300)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter  = CMTime(seconds: 0.1, preferredTimescale: 600)

        // Sample at ~2 fps
        let sampleInterval = 0.5
        let count = max(1, Int(duration / sampleInterval))
        var frameScores: [(time: Double, score: Double)] = []

        for i in 0..<count {
            let time = Double(i) * sampleInterval
            let cmTime = CMTime(seconds: time, preferredTimescale: 600)
            if let cgImage = try? generator.copyCGImage(at: cmTime, actualTime: nil) {
                let uiImage = UIImage(cgImage: cgImage)
                let score = await scoreFrame(uiImage)
                frameScores.append((time: time, score: score))
            }
        }

        guard !frameScores.isEmpty else { return Result(bestSegmentStart: 0, score: 0) }

        // Sliding window — find the window of `targetDuration` with highest average score
        let windowSize = max(1, Int(targetDuration / sampleInterval))
        var bestStart = 0.0
        var bestScore = 0.0

        for i in 0...max(0, frameScores.count - windowSize) {
            let window = frameScores[i..<min(i + windowSize, frameScores.count)]
            let avg = window.map(\.score).reduce(0, +) / Double(window.count)
            if avg > bestScore {
                bestScore = avg
                bestStart = frameScores[i].time
            }
        }

        return Result(bestSegmentStart: bestStart, score: bestScore)
    }

    // MARK: - Frame scoring

    private static func scoreFrame(_ image: UIImage) async -> Double {
        guard let cgImage = image.cgImage else { return 0 }
        async let faceScore = faceQualityScore(cgImage: cgImage)
        let sharpness = sharpnessScore(cgImage: cgImage)
        let face = await faceScore
        // Weighted: faces matter more, sharpness as fallback
        return face * 0.65 + sharpness * 0.35
    }

    // MARK: - Vision face quality

    private static func faceQualityScore(cgImage: CGImage) async -> Double {
        await withCheckedContinuation { continuation in
            let request = VNDetectFaceCaptureQualityRequest { req, _ in
                let observations = req.results as? [VNFaceObservation] ?? []

                if observations.isEmpty {
                    // No faces — neutral score; sharpness will dominate for scenery
                    continuation.resume(returning: 0.25)
                    return
                }

                // Average face quality + smile bonus
                var totalScore = 0.0
                for obs in observations {
                    let quality = Double(obs.faceCaptureQuality ?? 0)
                    let smile   = smileBonus(for: obs)
                    totalScore += quality * 0.85 + smile * 0.15
                }
                continuation.resume(returning: min(1.0, totalScore / Double(observations.count)))
            }

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([request])
        }
    }

    /// Infers smile from mouth landmark geometry (mouth corners above mouth center).
    private static func smileBonus(for observation: VNFaceObservation) -> Double {
        guard let landmarks = observation.landmarks,
              let outerLips = landmarks.outerLips else { return 0 }

        let points = outerLips.normalizedPoints
        guard points.count >= 6 else { return 0 }

        // Leftmost, rightmost, and bottom-center point of lips
        let leftCorner  = points.min(by: { $0.x < $1.x })!
        let rightCorner = points.max(by: { $0.x < $1.x })!
        let bottomPoint = points.min(by: { $0.y < $1.y })!  // y=0 is bottom in Vision

        let cornerAvgY = (leftCorner.y + rightCorner.y) / 2
        let lift = cornerAvgY - bottomPoint.y  // positive = corners above bottom = smile

        return Double(min(1.0, max(0, lift * 10)))
    }

    // MARK: - Sharpness (Laplacian via Core Image)

    private static func sharpnessScore(cgImage: CGImage) -> Double {
        let ciImage = CIImage(cgImage: cgImage)
        let context = CIContext(options: [.useSoftwareRenderer: false])

        // Downscale for speed
        let scale = min(1.0, 200.0 / Double(cgImage.width))
        let scaled = ciImage.transformed(by: .init(scaleX: scale, y: scale))

        guard let gray = CIFilter(name: "CIColorControls",
                                  parameters: ["inputImage": scaled,
                                               kCIInputSaturationKey: 0.0])?.outputImage,
              let laplacian = CIFilter(name: "CILaplacian",
                                       parameters: ["inputImage": gray])?.outputImage,
              let areaMax = CIFilter(name: "CIAreaMaximum",
                                     parameters: ["inputImage": laplacian,
                                                  "inputExtent": CIVector(cgRect: laplacian.extent)])?.outputImage
        else { return 0.5 }

        var pixel = [Float](repeating: 0, count: 4)
        context.render(areaMax,
                       toBitmap: &pixel,
                       rowBytes: MemoryLayout<Float>.size * 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBAf,
                       colorSpace: nil)

        return min(1.0, Double(pixel[0]) / 0.08)
    }

    // MARK: - Helpers

    private static func requestThumbnail(for asset: PHAsset, size: CGSize) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .fastFormat
            options.isNetworkAccessAllowed = false
            options.isSynchronous = false

            var resumed = false
            PHImageManager.default().requestImage(for: asset,
                                                  targetSize: size,
                                                  contentMode: .aspectFill,
                                                  options: options) { image, info in
                guard !resumed else { return }
                let isDegraded = info?[PHImageResultIsDegradedKey] as? Bool ?? false
                if !isDegraded || image != nil {
                    resumed = true
                    continuation.resume(returning: image)
                }
            }
        }
    }

    private static func loadAVAsset(for asset: PHAsset) async -> AVAsset? {
        await withCheckedContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.deliveryMode = .fastFormat
            options.isNetworkAccessAllowed = false

            var resumed = false
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: avAsset)
            }
        }
    }
}
