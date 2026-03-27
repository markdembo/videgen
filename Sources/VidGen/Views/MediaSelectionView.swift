import SwiftUI
import Photos
import PhotosUI

struct MediaSelectionView: View {
    @EnvironmentObject var appState: AppState
    @State private var showPicker = false

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 4)]

    var body: some View {
        NavigationStack {
            Group {
                if appState.mediaItems.isEmpty {
                    emptyState
                } else {
                    clipGrid
                }
            }
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showPicker = true } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                    }
                }
                if !appState.mediaItems.isEmpty {
                    ToolbarItem(placement: .navigationBarLeading) {
                        EditButton()
                    }
                }
            }
        }
        .sheet(isPresented: $showPicker) {
            PhotoPickerView { results in
                Task { await processPickerResults(results) }
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("Add Photos & Videos")
                .font(.title2.bold())
            Text("Tap + to select from your library.\nLive Photos, videos, and stills all work.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .font(.subheadline)
            Button {
                showPicker = true
            } label: {
                Label("Choose Media", systemImage: "plus")
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(.white.opacity(0.15), in: Capsule())
            }
        }
        .padding()
    }

    // MARK: - Clip grid

    private var clipGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach($appState.mediaItems) { $item in
                    ClipCell(item: $item)
                        .aspectRatio(9/16, contentMode: .fit)
                }
            }
            .padding(4)
        }
    }

    // MARK: - PHPicker results → MediaItem

    private func processPickerResults(_ results: [PHPickerResult]) async {
        // Collect PHAssets
        let identifiers = results.compactMap(\.assetIdentifier)
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var assetsById: [String: PHAsset] = [:]
        fetchResult.enumerateObjects { asset, _, _ in
            assetsById[asset.localIdentifier] = asset
        }

        for result in results {
            guard let id = result.assetIdentifier,
                  let asset = assetsById[id] else { continue }

            // Skip duplicates
            if appState.mediaItems.contains(where: { $0.asset.localIdentifier == id }) { continue }

            let type: MediaType = asset.mediaSubtypes.contains(.photoLive) ? .livePhoto
                                : asset.mediaType == .video                 ? .video
                                :                                             .photo

            var item = MediaItem(id: UUID(), asset: asset, type: type)
            item.thumbnail = await loadThumbnail(asset: asset)
            appState.mediaItems.append(item)

            // Kick off async work for this item
            let itemId = item.id
            Task {
                // 1. Extract video (live photo / regular video)
                if type != .photo {
                    if let url = try? await LivePhotoExtractor.extractVideo(from: asset) {
                        if var current = appState.mediaItems.first(where: { $0.id == itemId }) {
                            current.extractedVideoURL = url
                            current.avAsset = AVURLAsset(url: url)
                            appState.updateItem(current)
                        }
                    }
                }

                // 2. Analyse for best moment
                if var current = appState.mediaItems.first(where: { $0.id == itemId }) {
                    current.analysisState = .analyzing
                    appState.updateItem(current)

                    let result = await ClipAnalyzer.analyze(
                        item: appState.mediaItems.first(where: { $0.id == itemId }) ?? current,
                        targetDuration: appState.targetClipDuration
                    )

                    if var final = appState.mediaItems.first(where: { $0.id == itemId }) {
                        final.bestSegmentStart = result.bestSegmentStart
                        final.bestSegmentScore = result.score
                        final.analysisState    = .complete(score: result.score)
                        appState.updateItem(final)
                    }
                }
            }
        }
    }

    private func loadThumbnail(asset: PHAsset) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let opts = PHImageRequestOptions()
            opts.deliveryMode = .fastFormat
            opts.isNetworkAccessAllowed = true
            var done = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 300, height: 300),
                contentMode: .aspectFill,
                options: opts
            ) { img, info in
                guard !done else { return }
                let degraded = info?[PHImageResultIsDegradedKey] as? Bool ?? false
                if !degraded || img != nil {
                    done = true
                    continuation.resume(returning: img)
                }
            }
        }
    }
}

// MARK: - Clip cell

struct ClipCell: View {
    @Binding var item: MediaItem

    var body: some View {
        ZStack(alignment: .bottom) {
            // Thumbnail
            if let img = item.thumbnail {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .clipped()
            } else {
                Rectangle().fill(Color.gray.opacity(0.3))
                ProgressView().tint(.white)
            }

            // Bottom overlay
            LinearGradient(colors: [.clear, .black.opacity(0.6)],
                           startPoint: .center, endPoint: .bottom)

            HStack {
                // Type badge
                typeBadge

                Spacer()

                // Score / analysis indicator
                scoreIndicator
            }
            .padding(6)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(item.type == .livePhoto ? Color.yellow.opacity(0.6) : Color.clear, lineWidth: 1.5)
        )
    }

    @ViewBuilder
    private var typeBadge: some View {
        switch item.type {
        case .livePhoto:
            Text("LIVE")
                .font(.system(size: 9, weight: .bold))
                .padding(.horizontal, 4).padding(.vertical, 2)
                .background(.yellow, in: Capsule())
                .foregroundStyle(.black)
        case .video:
            Image(systemName: "video.fill")
                .font(.caption2)
                .foregroundStyle(.white)
        case .photo:
            EmptyView()
        }
    }

    @ViewBuilder
    private var scoreIndicator: some View {
        switch item.analysisState {
        case .analyzing:
            ProgressView().scaleEffect(0.6).tint(.white)
        case .complete(let score):
            HStack(spacing: 2) {
                Image(systemName: scoreIcon(score))
                    .font(.caption2)
                    .foregroundStyle(scoreColor(score))
            }
        default:
            EmptyView()
        }
    }

    private func scoreIcon(_ score: Double) -> String {
        score > 0.6 ? "star.fill" : score > 0.3 ? "star.leadinghalf.filled" : "star"
    }

    private func scoreColor(_ score: Double) -> Color {
        score > 0.6 ? .yellow : score > 0.3 ? .orange : .gray
    }
}

// MARK: - PHPicker wrapper

struct PhotoPickerView: UIViewControllerRepresentable {
    let onComplete: ([PHPickerResult]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .any(of: [.images, .videos, .livePhotos])
        config.selectionLimit = 0  // unlimited
        config.preferredAssetRepresentationMode = .current
        let vc = PHPickerViewController(configuration: config)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onComplete: onComplete) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onComplete: ([PHPickerResult]) -> Void
        init(onComplete: @escaping ([PHPickerResult]) -> Void) { self.onComplete = onComplete }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            onComplete(results)
        }
    }
}
