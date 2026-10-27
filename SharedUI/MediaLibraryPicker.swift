import Photos
import PhotosUI
import SwiftUI
import TesseraeKit
import UniformTypeIdentifiers

/// Uses the system picker's item providers, without requesting access to the photo library.
struct MediaLibraryPicker: UIViewControllerRepresentable {
    var livePhotosOnly = false
    let onSelection: (MediaPickerSelection?) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = livePhotosOnly ? .livePhotos : .any(of: [.images, .videos])
        configuration.selectionLimit = 1
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onSelection: onSelection) }

    @MainActor final class Coordinator: PHPickerViewControllerDelegate {
        let onSelection: (MediaPickerSelection?) -> Void
        init(onSelection: @escaping (MediaPickerSelection?) -> Void) { self.onSelection = onSelection }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            onSelection(results.first.map { MediaPickerSelection(provider: $0.itemProvider) })
        }
    }
}

extension View {
    func mediaLibraryPicker(isPresented: Binding<Bool>, selection: Binding<MediaPickerSelection?>,
                            livePhotosOnly: Bool = false) -> some View {
        sheet(isPresented: isPresented) {
            MediaLibraryPicker(livePhotosOnly: livePhotosOnly) { item in
                if let item { selection.wrappedValue = item }
                isPresented.wrappedValue = false
            }
            .ignoresSafeArea()
        }
    }
}

@MainActor final class MediaPickerSelection: Identifiable, Equatable {
    nonisolated let id = UUID()
    let provider: NSItemProvider
    let kind: MediaFrameSource.Kind

    init(provider: NSItemProvider) {
        self.provider = provider
        if provider.hasItemConformingToTypeIdentifier(UTType.livePhoto.identifier)
            || provider.canLoadObject(ofClass: PHLivePhoto.self) { kind = .livePhoto }
        else if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) { kind = .video }
        else { kind = .photo }
    }

    nonisolated static func == (lhs: MediaPickerSelection, rhs: MediaPickerSelection) -> Bool { lhs.id == rhs.id }

    func load(maximumPixelSize: Int) async throws -> MediaFrameSource {
        if kind == .video {
            let movie = try await loadMovie()
            let reader = VideoFrameReader(file: movie, maximumPixelSize: maximumPixelSize)
            let image = try await reader.image(at: 0)
            try Task.checkCancellation()
            return MediaFrameSource(kind: .video, primaryImage: image, maximumPixelSize: maximumPixelSize) { movie }
        }
        let imageType = provider.registeredTypeIdentifiers.compactMap(UTType.init)
            .first { $0.conforms(to: .image) && $0 != .livePhoto } ?? .image
        let prepared: PreparedUploadImage
        do {
            let data = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                provider.loadDataRepresentation(forTypeIdentifier: imageType.identifier) { data, error in
                    if let data { continuation.resume(returning: data) }
                    else { continuation.resume(throwing: error ?? UploadImagePreparationError.decoding) }
                }
            }
            prepared = try await Self.prepare(data, type: imageType.preferredMIMEType ?? "image/jpeg", maximumPixelSize: maximumPixelSize)
        } catch {
            try Task.checkCancellation()
            // Some share sources vend an object rather than image-file bytes.
            let data = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                provider.loadObject(ofClass: UIImage.self) { object, error in
                    if let image = object as? UIImage, let data = image.pngData() { continuation.resume(returning: data) }
                    else { continuation.resume(throwing: error ?? UploadImagePreparationError.decoding) }
                }
            }
            prepared = try await Self.prepare(data, type: "image/png", maximumPixelSize: maximumPixelSize)
        }
        try Task.checkCancellation()
        return MediaFrameSource(kind: kind, primaryImage: prepared, maximumPixelSize: maximumPixelSize) {
            try await self.loadLivePhotoMovie()
        }
    }

    private static func prepare(_ data: Data, type: String, maximumPixelSize: Int) async throws -> PreparedUploadImage {
        try await Task.detached(priority: .userInitiated) {
            try UploadImagePreparer.prepare(data: data, fallbackContentType: type, maximumPixelSize: maximumPixelSize)
        }.value
    }

    private func loadMovie() async throws -> MediaTemporaryFile {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, error in
                do {
                    guard let url else { throw error ?? MediaFrameError.unavailable }
                    // Provider URLs expire when this callback returns.
                    continuation.resume(returning: try MediaTemporaryFile(copying: url))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func loadLivePhotoMovie() async throws -> MediaTemporaryFile {
        if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
            return try await loadMovie()
        }
        if provider.canLoadObject(ofClass: PHLivePhoto.self) {
            do {
                return try await withCheckedThrowingContinuation { continuation in
                    provider.loadObject(ofClass: PHLivePhoto.self) { object, error in
                        if let photo = object as? PHLivePhoto {
                            Self.exportMovie(from: photo) { continuation.resume(with: $0) }
                        } else { continuation.resume(throwing: error ?? MediaFrameError.unavailable) }
                    }
                }
            } catch { try Task.checkCancellation() }
        }
        let file = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<MediaTemporaryFile, Error>) in
            // Preserve the concrete PHLivePhoto block signature required by
            // Photos' legacy item provider; a generic Swift block cannot coerce it.
            TesseraeLoadLivePhotoItem(provider) { photo, error in
                if let photo {
                    Self.exportMovie(from: photo) { continuation.resume(with: $0) }
                }
                else { continuation.resume(throwing: error ?? MediaFrameError.unavailable) }
            }
        }
        try Task.checkCancellation()
        return file
    }

    // Consume Photos objects in their callback context; only the immutable file
    // lease crosses back to the main actor, including on older Photos SDKs.
    nonisolated static func exportMovie(from photo: PHLivePhoto,
        completion: @escaping @Sendable (Result<MediaTemporaryFile, Error>) -> Void) {
        do {
            let resources = PHAssetResource.assetResources(for: photo)
            guard let video = resources.first(where: { $0.type == .fullSizePairedVideo })
                ?? resources.first(where: { $0.type == .pairedVideo }) else { throw MediaFrameError.unavailable }
            let file = try MediaTemporaryFile(fileExtension: "mov")
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            PHAssetResourceManager.default().writeData(for: video, toFile: file.url, options: options) { error in
                if let error { completion(.failure(error)) }
                else { completion(.success(file)) }
            }
        } catch { completion(.failure(error)) }
    }
}

/// An immutable file lease can cross actors; its last owner removes only its own directory.
final class MediaTemporaryFile: Sendable {
    let url: URL
    private let directory: URL

    init(fileExtension: String) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("tesserae-media-\(UUID().uuidString)", isDirectory: true)
        url = directory.appendingPathComponent("source").appendingPathExtension(fileExtension)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    convenience init(copying source: URL) throws {
        try self.init(fileExtension: source.pathExtension.isEmpty ? "mov" : source.pathExtension)
        try FileManager.default.copyItem(at: source, to: url)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}
