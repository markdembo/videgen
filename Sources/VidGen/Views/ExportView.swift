import SwiftUI
import AVFoundation
import Photos

struct ExportView: View {
    @EnvironmentObject var appState: AppState
    @State private var shareItem: URL?
    @State private var showShare  = false
    @State private var savedToPhotos = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    summarySection
                    if appState.isExporting {
                        exportingSection
                    } else if let url = appState.exportedVideoURL {
                        doneSection(url: url)
                    } else {
                        exportButton
                    }
                }
                .padding()
            }
            .navigationTitle("Export")
        }
        .sheet(isPresented: $showShare) {
            if let url = shareItem {
                ShareSheet(url: url)
            }
        }
    }

    // MARK: - Summary

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Summary", systemImage: "list.clipboard")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                summaryRow(icon: "photo.stack",
                           label: "Clips",
                           value: "\(appState.mediaItems.count)")

                summaryRow(icon: "music.note",
                           label: "Music",
                           value: appState.audioLocalURL != nil ? "Loaded" : "None")

                summaryRow(icon: "timer",
                           label: "Audio trim",
                           value: appState.audioAsset != nil
                               ? "\(formatTime(appState.trimStart)) – \(formatTime(appState.trimEnd))"
                               : "—")

                summaryRow(icon: "metronome",
                           label: "Beats",
                           value: appState.beatPositions.isEmpty
                               ? "Not detected"
                               : "\(appState.beatPositions.count) @ \(Int(appState.estimatedBPM)) BPM")

                summaryRow(icon: "timer.circle",
                           label: "Clip length",
                           value: String(format: "%.2f s", appState.targetClipDuration))
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private func summaryRow(icon: String, label: String, value: String) -> some View {
        GridRow {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .fontWeight(.medium)
        }
        .font(.subheadline)
    }

    // MARK: - Exporting

    private var exportingSection: some View {
        VStack(spacing: 16) {
            ProgressView(value: appState.exportProgress)
                .tint(.white)
                .scaleEffect(x: 1, y: 2)
                .animation(.linear, value: appState.exportProgress)

            Text("Composing video… \(Int(appState.exportProgress * 100))%")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Done

    private func doneSection(url: URL) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)

            Text("Video Ready")
                .font(.title2.bold())

            HStack(spacing: 12) {
                Button {
                    shareItem = url
                    showShare  = true
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.blue, in: RoundedRectangle(cornerRadius: 12))
                }

                Button {
                    Task { await saveToPhotos(url: url) }
                } label: {
                    Label(savedToPhotos ? "Saved!" : "Save to Photos",
                          systemImage: savedToPhotos ? "checkmark" : "photo.badge.plus")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                }
                .disabled(savedToPhotos)
            }

            Button {
                appState.exportedVideoURL = nil
                appState.exportProgress   = 0
                savedToPhotos = false
            } label: {
                Text("Make Another")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Export button

    private var exportButton: some View {
        VStack(spacing: 12) {
            if !canExport {
                missingRequirements
            }

            Button {
                Task { await startExport() }
            } label: {
                HStack {
                    Image(systemName: "film.stack")
                    Text("Generate Video")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(canExport ? Color.blue : Color.blue.opacity(0.3),
                            in: RoundedRectangle(cornerRadius: 14))
            }
            .disabled(!canExport)
        }
    }

    private var canExport: Bool {
        !appState.mediaItems.isEmpty && appState.audioAsset != nil
    }

    @ViewBuilder
    private var missingRequirements: some View {
        VStack(alignment: .leading, spacing: 8) {
            if appState.mediaItems.isEmpty {
                requirementRow(met: false, text: "Add at least one clip in Library")
            }
            if appState.audioAsset == nil {
                requirementRow(met: false, text: "Load music in the Music tab")
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func requirementRow(met: Bool, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: met ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(met ? .green : .orange)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func startExport() async {
        guard canExport, let audioURL = appState.audioLocalURL else { return }
        appState.isExporting    = true
        appState.exportProgress = 0

        // Build ClipSpecs from MediaItems
        let clips: [VideoComposer.ClipSpec] = appState.mediaItems.compactMap { item in
            guard let url = item.extractedVideoURL ?? (item.type == .photo ? nil : nil) else {
                // For photos, we can't use them directly in the video track
                // (they need to be rendered as video frames first — skip for now)
                if item.type == .photo { return nil }
                return nil
            }
            return VideoComposer.ClipSpec(
                videoURL:        url,
                segmentStart:    item.bestSegmentStart,
                segmentDuration: appState.targetClipDuration
            )
        }

        guard !clips.isEmpty else {
            appState.errorMessage = "No video clips could be loaded. Make sure your selected media includes videos or Live Photos."
            appState.isExporting  = false
            return
        }

        let config = VideoComposer.Config(
            clips:             clips,
            audioURL:          audioURL,
            audioTrimStart:    appState.trimStart,
            audioTrimDuration: appState.trimDuration,
            beatTimestamps:    appState.beatPositions,
            targetClipDuration: appState.targetClipDuration
        )

        do {
            let url = try await VideoComposer.compose(config: config) { progress in
                Task { @MainActor in appState.exportProgress = progress }
            }
            appState.exportedVideoURL = url
        } catch {
            appState.errorMessage = error.localizedDescription
        }

        appState.isExporting = false
    }

    private func saveToPhotos(url: URL) async {
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }
            savedToPhotos = true
        } catch {
            appState.errorMessage = "Could not save to Photos: \(error.localizedDescription)"
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Share sheet

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
