import Foundation
import AVFoundation

enum YouTubeService {

    enum YouTubeError: LocalizedError {
        case invalidURL
        case requestFailed(Int)
        case noAudioStream
        case downloadFailed

        var errorDescription: String? {
            switch self {
            case .invalidURL:           return "Invalid YouTube URL. Paste the full watch URL or a youtu.be link."
            case .requestFailed(let c): return "YouTube returned status \(c). The video may be private or region-locked."
            case .noAudioStream:        return "No audio stream found in this video."
            case .downloadFailed:       return "Failed to download the audio."
            }
        }
    }

    // MARK: - Public

    /// Downloads audio from a YouTube URL and returns a local file URL + AVAsset.
    static func loadAudio(from urlString: String,
                          progress: @escaping (Double) -> Void) async throws -> (URL, AVAsset) {
        let videoId = try extractVideoId(from: urlString)
        let streamURL = try await fetchAudioStreamURL(videoId: videoId)
        let localURL = try await downloadAudio(from: streamURL, videoId: videoId, progress: progress)
        let asset = AVURLAsset(url: localURL)
        return (localURL, asset)
    }

    // MARK: - Video ID extraction

    private static func extractVideoId(from urlString: String) throws -> String {
        // Handles: youtube.com/watch?v=ID, youtu.be/ID, youtube.com/shorts/ID, /embed/ID
        let pattern = #"(?:v=|youtu\.be/|/embed/|/shorts/)([A-Za-z0-9_-]{11})"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: urlString, range: NSRange(urlString.startIndex..., in: urlString)),
              let range = Range(match.range(at: 1), in: urlString) else {
            throw YouTubeError.invalidURL
        }
        return String(urlString[range])
    }

    // MARK: - Innertube player API (iOS client — returns direct URLs without cipher)

    private static func fetchAudioStreamURL(videoId: String) async throws -> URL {
        let endpoint = URL(string: "https://www.youtube.com/youtubei/v1/player")!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue(
            "com.google.ios.youtube/19.09.3 (iPhone16,2; U; CPU iOS 17_4 like Mac OS X)",
            forHTTPHeaderField: "User-Agent"
        )

        let body: [String: Any] = [
            "videoId": videoId,
            "context": [
                "client": [
                    "clientName":     "IOS",
                    "clientVersion":  "19.09.3",
                    "deviceMake":     "Apple",
                    "deviceModel":    "iPhone16,2",
                    "osName":         "iPhone",
                    "osVersion":      "17.4.0.21E219",
                    "hl":             "en",
                    "gl":             "US"
                ]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw YouTubeError.requestFailed(http.statusCode)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streamingData = json["streamingData"] as? [String: Any] else {
            throw YouTubeError.noAudioStream
        }

        // Prefer adaptiveFormats (audio-only) → fall back to muxed formats
        let audioURL = bestAudioURL(from: streamingData["adaptiveFormats"] as? [[String: Any]] ?? [])
                    ?? bestAudioURL(from: streamingData["formats"] as? [[String: Any]] ?? [])

        guard let audioURL else { throw YouTubeError.noAudioStream }
        return audioURL
    }

    private static func bestAudioURL(from formats: [[String: Any]]) -> URL? {
        // Filter to audio/mp4 (m4a) streams only
        let audioFormats = formats.filter { format in
            guard let mime = format["mimeType"] as? String else { return false }
            return mime.hasPrefix("audio/mp4")
        }

        // Sort descending by bitrate
        let sorted = audioFormats.sorted {
            ($0["bitrate"] as? Int ?? 0) > ($1["bitrate"] as? Int ?? 0)
        }

        // Return the URL of the best stream
        for format in sorted {
            if let urlString = format["url"] as? String, let url = URL(string: urlString) {
                return url
            }
        }
        return nil
    }

    // MARK: - Download

    private static func downloadAudio(from streamURL: URL,
                                      videoId: String,
                                      progress: @escaping (Double) -> Void) async throws -> URL {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("yt_audio_\(videoId)")
            .appendingPathExtension("m4a")

        try? FileManager.default.removeItem(at: dest)

        let delegate = DownloadDelegate(progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)

        return try await withCheckedThrowingContinuation { continuation in
            delegate.continuation = continuation
            delegate.destinationURL = dest
            session.downloadTask(with: streamURL).resume()
        }
    }

    // MARK: - Download delegate

    private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
        let progress: (Double) -> Void
        var continuation: CheckedContinuation<URL, Error>?
        var destinationURL: URL?

        init(progress: @escaping (Double) -> Void) { self.progress = progress }

        func urlSession(_ session: URLSession,
                        downloadTask: URLSessionDownloadTask,
                        didWriteData _: Int64,
                        totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            guard totalBytesExpectedToWrite > 0 else { return }
            let pct = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            DispatchQueue.main.async { self.progress(pct) }
        }

        func urlSession(_ session: URLSession,
                        downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {
            guard let dest = destinationURL else {
                continuation?.resume(throwing: YouTubeError.downloadFailed)
                return
            }
            do {
                try FileManager.default.moveItem(at: location, to: dest)
                continuation?.resume(returning: dest)
            } catch {
                continuation?.resume(throwing: error)
            }
        }

        func urlSession(_ session: URLSession,
                        task: URLSessionTask,
                        didCompleteWithError error: Error?) {
            if let error {
                continuation?.resume(throwing: error)
            }
        }
    }
}
