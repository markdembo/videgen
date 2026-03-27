import SwiftUI
import AVFoundation

struct MusicView: View {
    @EnvironmentObject var appState: AppState
    @State private var urlInput: String = ""
    @State private var downloadProgress: Double = 0
    @FocusState private var urlFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    youtubeSection
                    if appState.audioAsset != nil {
                        waveformSection
                        trimSection
                        beatSection
                        clipDurationSection
                    }
                }
                .padding()
            }
            .navigationTitle("Music")
        }
    }

    // MARK: - YouTube input

    private var youtubeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("YouTube Link", systemImage: "link")
                .font(.headline)

            HStack(spacing: 10) {
                TextField("https://youtube.com/watch?v=...", text: $urlInput)
                    .focused($urlFocused)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(10)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))

                Button {
                    urlFocused = false
                    Task { await loadAudio() }
                } label: {
                    Group {
                        if appState.isLoadingAudio {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.title2)
                        }
                    }
                    .frame(width: 44, height: 44)
                }
                .disabled(appState.isLoadingAudio || urlInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if appState.isLoadingAudio {
                ProgressView(value: downloadProgress)
                    .tint(.white)
                    .animation(.linear, value: downloadProgress)
                Text(downloadProgress < 1 ? "Downloading audio… \(Int(downloadProgress * 100))%" : "Processing…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let url = appState.audioLocalURL {
                Label(url.lastPathComponent, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Waveform

    private var waveformSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Waveform", systemImage: "waveform")
                .font(.headline)

            WaveformView(
                samples:      appState.waveformSamples,
                beats:        appState.beatPositions,
                trimStart:    appState.trimStart,
                trimEnd:      appState.trimEnd,
                totalSeconds: appState.audioDuration
            )
            .frame(height: 80)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(16)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Trim

    private var trimSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Trim Selection", systemImage: "scissors")
                .font(.headline)

            let dur = appState.audioDuration

            VStack(spacing: 10) {
                HStack {
                    Text("Start")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .leading)
                    Slider(
                        value: $appState.trimStart,
                        in: 0...max(0, appState.trimEnd - 1)
                    )
                    Text(formatTime(appState.trimStart))
                        .font(.caption.monospacedDigit())
                        .frame(width: 48, alignment: .trailing)
                }

                HStack {
                    Text("End")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .leading)
                    Slider(
                        value: $appState.trimEnd,
                        in: min(appState.trimStart + 1, dur)...dur
                    )
                    Text(formatTime(appState.trimEnd))
                        .font(.caption.monospacedDigit())
                        .frame(width: 48, alignment: .trailing)
                }
            }

            HStack {
                Image(systemName: "timer")
                    .foregroundStyle(.secondary)
                Text("Selection: \(formatTime(appState.trimDuration))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Beat detection

    private var beatSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Beat Detection", systemImage: "metronome")
                .font(.headline)

            if !appState.beatPositions.isEmpty {
                HStack(spacing: 20) {
                    statPill(value: "\(appState.beatPositions.count)", label: "beats")
                    statPill(value: String(format: "%.0f", appState.estimatedBPM), label: "BPM")
                }
            }

            Button {
                Task { await detectBeats() }
            } label: {
                HStack {
                    if appState.isDetectingBeats {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "waveform.path.ecg")
                    }
                    Text(appState.isDetectingBeats ? "Detecting…" : "Detect Beats")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
            }
            .disabled(appState.isDetectingBeats || appState.audioAsset == nil)
        }
        .padding(16)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Clip duration

    private var clipDurationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Clip Duration", systemImage: "timer.circle")
                .font(.headline)

            Text("Each clip will be trimmed to approximately this length. Cuts snap to detected beats.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Text("1s")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $appState.targetClipDuration, in: 1...3, step: 0.25)
                Text("3s")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(String(format: "%.2f seconds", appState.targetClipDuration))
                .font(.subheadline.monospacedDigit())
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(16)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Actions

    private func loadAudio() async {
        let trimmed = urlInput.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        appState.isLoadingAudio = true
        downloadProgress = 0

        do {
            let (url, asset) = try await YouTubeService.loadAudio(from: trimmed) { pct in
                Task { @MainActor in self.downloadProgress = pct }
            }
            downloadProgress = 1
            appState.audioLocalURL = url
            appState.audioAsset    = asset

            // Load duration
            let duration = try await asset.load(.duration).seconds
            appState.audioDuration = duration
            appState.trimStart     = 0
            appState.trimEnd       = min(duration, 120)

            // Build waveform display samples
            let beatResult = try await BeatDetector.analyze(asset: asset, from: 0, to: min(duration, 120))
            appState.waveformSamples = beatResult.waveformSamples
        } catch {
            appState.errorMessage = error.localizedDescription
        }

        appState.isLoadingAudio = false
    }

    private func detectBeats() async {
        guard let asset = appState.audioAsset else { return }
        appState.isDetectingBeats = true
        do {
            let result = try await BeatDetector.analyze(
                asset: asset,
                from:  appState.trimStart,
                to:    appState.trimEnd
            )
            // Store beats relative to trim start
            appState.beatPositions = result.timestamps.map { $0 - appState.trimStart }
            appState.estimatedBPM  = result.bpm
            appState.waveformSamples = result.waveformSamples
        } catch {
            appState.errorMessage = error.localizedDescription
        }
        appState.isDetectingBeats = false
    }

    // MARK: - Helpers

    private func formatTime(_ seconds: Double) -> String {
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    @ViewBuilder
    private func statPill(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title2.bold().monospacedDigit())
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Waveform view

struct WaveformView: View {
    let samples:      [Float]
    let beats:        [Double]
    let trimStart:    Double
    let trimEnd:      Double
    let totalSeconds: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Bars
                HStack(alignment: .center, spacing: 1) {
                    ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                        Capsule()
                            .fill(Color.white.opacity(0.6))
                            .frame(height: max(2, geo.size.height * CGFloat(sample)))
                    }
                }

                // Trim region overlay
                if totalSeconds > 0 {
                    let startFrac = CGFloat(trimStart / totalSeconds)
                    let endFrac   = CGFloat(trimEnd   / totalSeconds)
                    Rectangle()
                        .fill(Color.blue.opacity(0.2))
                        .frame(width: (endFrac - startFrac) * geo.size.width)
                        .offset(x: startFrac * geo.size.width)

                    // Beat markers
                    ForEach(Array(beats.enumerated()), id: \.offset) { _, beat in
                        let frac = CGFloat((trimStart + beat) / totalSeconds)
                        Rectangle()
                            .fill(Color.yellow.opacity(0.8))
                            .frame(width: 1.5)
                            .offset(x: frac * geo.size.width)
                    }
                }
            }
            .background(Color.white.opacity(0.05))
        }
    }
}
