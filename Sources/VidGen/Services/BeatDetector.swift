import Foundation
import AVFoundation
import Accelerate

enum BeatDetector {

    struct BeatResult {
        let timestamps: [Double]   // seconds relative to file start
        let bpm: Double
        let waveformSamples: [Float]  // normalised RMS for display, ~200 buckets
    }

    enum BeatError: LocalizedError {
        case noAudioTrack
        case readFailed

        var errorDescription: String? {
            switch self {
            case .noAudioTrack: return "The audio file has no audio track."
            case .readFailed:   return "Failed to read audio data."
            }
        }
    }

    // MARK: - Public

    static func analyze(asset: AVAsset,
                        from startTime: Double,
                        to endTime: Double) async throws -> BeatResult {
        let samples = try await readMonoSamples(from: asset, start: startTime, end: endTime)
        let sampleRate = 44100.0

        let waveform  = buildWaveform(samples: samples, buckets: 300)
        let onset     = spectralFlux(samples: samples)
        let hopSize   = 512
        let frameRate = sampleRate / Double(hopSize)
        let minDist   = Int(frameRate * 0.25)  // 250 ms minimum gap between beats

        let peakFrames = pickPeaks(in: onset, minDistance: minDist)
        let timestamps = peakFrames.map { startTime + Double($0 * hopSize) / sampleRate }
        let bpm        = estimateBPM(timestamps: timestamps)

        return BeatResult(timestamps: timestamps, bpm: bpm, waveformSamples: waveform)
    }

    // MARK: - PCM reading

    private static func readMonoSamples(from asset: AVAsset,
                                        start: Double,
                                        end: Double) async throws -> [Float] {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw BeatError.noAudioTrack
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey:             kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey:    32,
            AVLinearPCMIsFloatKey:     true,
            AVLinearPCMIsBigEndianKey: false,
            AVNumberOfChannelsKey:     1,
            AVSampleRateKey:           44100.0
        ]

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 44100),
            end:   CMTime(seconds: end,   preferredTimescale: 44100)
        )
        reader.startReading()

        var samples: [Float] = []
        while reader.status == .reading {
            guard let buf = output.copyNextSampleBuffer(),
                  let block = CMSampleBufferGetDataBuffer(buf) else { break }
            let length = CMBlockBufferGetDataLength(block)
            let count  = length / MemoryLayout<Float>.size
            var chunk  = [Float](repeating: 0, count: count)
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &chunk)
            samples.append(contentsOf: chunk)
            CMSampleBufferInvalidate(buf)
        }
        if reader.status == .failed { throw reader.error ?? BeatError.readFailed }
        return samples
    }

    // MARK: - Spectral flux onset detection

    private static func spectralFlux(samples: [Float]) -> [Float] {
        let windowSize = 2048
        let hopSize    = 512
        let halfWindow = windowSize / 2
        let log2n      = vDSP_Length(log2(Float(windowSize)))

        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(FFT_RADIX2)) else { return [] }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        var hannWindow = [Float](repeating: 0, count: windowSize)
        vDSP_hann_window(&hannWindow, vDSP_Length(windowSize), Int32(vDSP_HANN_NORM))

        var prevMag = [Float](repeating: 0, count: halfWindow)
        var flux: [Float] = []

        var offset = 0
        while offset + windowSize <= samples.count {
            var windowed = [Float](repeating: 0, count: windowSize)
            vDSP_vmul(Array(samples[offset..<offset+windowSize]), 1,
                      hannWindow, 1, &windowed, 1, vDSP_Length(windowSize))

            var realPart = [Float](repeating: 0, count: halfWindow)
            var imagPart = [Float](repeating: 0, count: halfWindow)
            windowed.withUnsafeBufferPointer { ptr in
                var split = DSPSplitComplex(realp: &realPart, imagp: &imagPart)
                ptr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfWindow) { cp in
                    vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(halfWindow))
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
            }

            var magnitudes = [Float](repeating: 0, count: halfWindow)
            var split = DSPSplitComplex(realp: &realPart, imagp: &imagPart)
            vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(halfWindow))

            // Half-wave rectified spectral flux
            var diff    = [Float](repeating: 0, count: halfWindow)
            var zeros   = [Float](repeating: 0, count: halfWindow)
            vDSP_vsub(prevMag, 1, magnitudes, 1, &diff, 1, vDSP_Length(halfWindow))
            vDSP_vmax(diff, 1, &zeros, 1, &diff, 1, vDSP_Length(halfWindow))

            var f: Float = 0
            vDSP_sve(diff, 1, &f, vDSP_Length(halfWindow))
            flux.append(f)

            prevMag = magnitudes
            offset += hopSize
        }
        return flux
    }

    // MARK: - Peak picking (adaptive local threshold)

    private static func pickPeaks(in signal: [Float], minDistance: Int) -> [Int] {
        guard signal.count > 2 else { return [] }

        let halfContext = 40  // ~1 second context window on each side
        var peaks: [Int] = []

        for i in 1..<(signal.count - 1) {
            guard signal[i] > signal[i-1], signal[i] > signal[i+1] else { continue }

            let lo = max(0, i - halfContext)
            let hi = min(signal.count, i + halfContext)
            let ctx = Array(signal[lo..<hi])

            var mean: Float = 0, sq: Float = 0
            vDSP_meanv(ctx, 1, &mean, vDSP_Length(ctx.count))
            var ctx2 = ctx; vDSP_vsq(ctx, 1, &ctx2, 1, vDSP_Length(ctx.count))
            vDSP_meanv(ctx2, 1, &sq, vDSP_Length(ctx.count))
            let std = sqrt(max(0, sq - mean * mean))
            let threshold = mean + 0.55 * std

            guard signal[i] > threshold else { continue }

            if let last = peaks.last, i - last < minDistance {
                if signal[i] > signal[last] { peaks[peaks.count - 1] = i }
            } else {
                peaks.append(i)
            }
        }
        return peaks
    }

    // MARK: - BPM estimation (median inter-beat interval)

    private static func estimateBPM(timestamps: [Double]) -> Double {
        guard timestamps.count > 1 else { return 120 }
        let intervals = zip(timestamps, timestamps.dropFirst()).map { $1 - $0 }.sorted()
        let median = intervals[intervals.count / 2]
        return median > 0 ? (60.0 / median) : 120
    }

    // MARK: - Waveform (RMS buckets for display)

    private static func buildWaveform(samples: [Float], buckets: Int) -> [Float] {
        guard !samples.isEmpty else { return [] }
        let bucketSize = max(1, samples.count / buckets)
        var result = [Float](repeating: 0, count: buckets)
        for b in 0..<buckets {
            let start = b * bucketSize
            let end   = min(start + bucketSize, samples.count)
            let chunk = Array(samples[start..<end])
            var rms: Float = 0
            vDSP_rmsqv(chunk, 1, &rms, vDSP_Length(chunk.count))
            result[b] = rms
        }
        // Normalise
        var maxVal: Float = 0
        vDSP_maxv(result, 1, &maxVal, vDSP_Length(result.count))
        if maxVal > 0 { vDSP_vsdiv(result, 1, &maxVal, &result, 1, vDSP_Length(result.count)) }
        return result
    }
}
