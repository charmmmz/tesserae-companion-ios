import Observation
import PhotosUI
import SwiftUI
import TesseraeKit
import UIKit
import UniformTypeIdentifiers

enum GalleryGridMode: String, CaseIterable, Identifiable {
    case square
    case aspectRatio

    var id: String { rawValue }
}

struct GalleryAspectRow: Identifiable {
    struct Item: Identifiable {
        let image: GalleryImage
        let width: CGFloat

        var id: String { image.id }
    }

    let items: [Item]
    let height: CGFloat

    var id: String { items.first?.id ?? "empty-gallery-row" }
}

func galleryAspectRows(
    images: [GalleryImage],
    availableWidth: CGFloat,
    preferredColumns: Int,
    spacing: CGFloat
) -> [GalleryAspectRow] {
    guard !images.isEmpty, availableWidth > 0 else { return [] }

    let columns = min(max(preferredColumns, 2), 8)
    let targetHeight = max(
        44,
        (availableWidth - spacing * CGFloat(columns - 1)) / CGFloat(columns)
    )
    var pending: [(image: GalleryImage, ratio: CGFloat)] = []
    var pendingRatio: CGFloat = 0
    var rows: [GalleryAspectRow] = []

    func appendPendingRow(justified: Bool) {
        guard !pending.isEmpty else { return }
        let gaps = spacing * CGFloat(max(pending.count - 1, 0))
        let fittingHeight = max(1, (availableWidth - gaps) / pendingRatio)
        let rowHeight = justified ? fittingHeight : min(targetHeight, fittingHeight)
        rows.append(
            GalleryAspectRow(
                items: pending.map {
                    GalleryAspectRow.Item(
                        image: $0.image,
                        width: $0.ratio * rowHeight
                    )
                },
                height: rowHeight
            )
        )
        pending.removeAll(keepingCapacity: true)
        pendingRatio = 0
    }

    for image in images {
        let width = max(CGFloat(image.width), 1)
        let height = max(CGFloat(image.height), 1)
        pending.append((image, width / height))
        pendingRatio += width / height
        let projectedWidth = pendingRatio * targetHeight
            + spacing * CGFloat(max(pending.count - 1, 0))
        if projectedWidth >= availableWidth {
            appendPendingRow(justified: true)
        }
    }
    appendPendingRow(justified: false)
    return rows
}

func galleryGridColumnCount(
    startingAt startingColumns: Int,
    magnification: CGFloat
) -> Int {
    let proposed = Int(
        (CGFloat(startingColumns) / max(magnification, 0.1)).rounded()
    )
    return min(max(proposed, 2), 8)
}

func galleryShouldDismissImmersivePhoto(
    dragOffset: CGFloat,
    predictedEndOffset: CGFloat,
    zoomScale: CGFloat
) -> Bool {
    zoomScale <= 1.01
        && (dragOffset > 120 || predictedEndOffset > 240)
}

private struct GalleryLoadingView: View {
    let title: LocalizedStringKey

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(title)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct GalleryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @Environment(\.presentTesseraeSettings) private var presentSettings
    @State private var creatingFolder = false
    @State private var permissionAlertPresented = false

    let isActive: Bool

    private let columns = [
        GridItem(.adaptive(minimum: 148), spacing: 12),
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(model.galleryFolders) { folder in
                    NavigationLink {
                        GalleryFolderView(folderID: folder.id)
                    } label: {
                        GalleryFolderCard(folder: folder)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("gallery-folder-\(folder.id)")
                }
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if model.isRefreshingGallery && model.galleryFolders.isEmpty {
                GalleryLoadingView(title: "Loading Gallery…")
            } else if model.galleryFolders.isEmpty {
                ContentUnavailableView {
                    Label("No Gallery Folders", systemImage: "photo.on.rectangle.angled")
                } description: {
                    Text("Create a folder, then add photos from your library.")
                } actions: {
                    Button("Create Folder") {
                        beginCreatingFolder()
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Refresh") {
                        Task { await model.refreshGallery() }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .refreshable {
            await model.refreshGallery()
        }
        .task(id: isActive) {
            guard isActive else { return }
            await model.refreshGallery(showErrors: false)
        }
        .navigationTitle("Library")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Create Folder", systemImage: "folder.badge.plus") {
                    beginCreatingFolder()
                }
                .accessibilityIdentifier("gallery-create-folder")

                TesseraeSettingsToolbarButton(openSettings: presentSettings)
            }
        }
        .sheet(isPresented: $creatingFolder) {
            GalleryCreateFolderView()
        }
        .alert("Permission Required", isPresented: $permissionAlertPresented) {
            Button("Open Tesserae") {
                if let url = gallerySettingsURL(model: model) {
                    openURL(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Enable Gallery uploads for this iPhone in Tesserae Settings → Companion. You do not need to pair again."
            )
        }
        .tesseraeScreenBackground()
    }

    private func beginCreatingFolder() {
        if model.galleryWritePermission == .denied {
            permissionAlertPresented = true
            return
        }
        creatingFolder = true
    }
}

private struct GalleryFolderCard: View {
    @Environment(AppModel.self) private var model

    let folder: GalleryFolder

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GalleryThumbnail(
                path: folder.coverThumbnailURL,
                symbol: "photo.on.rectangle.angled"
            )
            .aspectRatio(4 / 3, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(folder.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if !folder.writable {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Read-only")
                }
            }

            Text(
                folder.imageCount == 1
                    ? String(localized: "1 photo")
                    : String(localized: "\(folder.imageCount) photos")
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .tesseraeCard()
        .task(id: folder.coverThumbnailURL) {
            guard let path = folder.coverThumbnailURL else { return }
            await model.loadGalleryThumbnail(path: path)
        }
    }
}

private struct GalleryFolderView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @AppStorage("gallery.grid.mode") private var gridModeValue =
        GalleryGridMode.square.rawValue
    @AppStorage("gallery.grid.columns") private var gridColumnCount = 3
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var isPhotoPickerPresented = false
    @State private var permissionAlertPresented = false
    @State private var pinchStartColumnCount: Int?
    @State private var suppressPhotoSelection = false
    @State private var gridGestureSequence = 0
    @State private var selectedPhotoID: String?
    @State private var offlineAlbumEditorPresented = false
    @State private var offlineAlbumPermissionAlertPresented = false
    @State private var isPreparingOfflineAlbumEditor = false
    @Environment(GalleryUploadCoordinator.self) private var galleryUploads

    let folderID: String

    private var detail: GalleryFolderDetail? {
        model.galleryFolderDetails[folderID]
    }

    private var folder: GalleryFolder? {
        detail?.folder ?? model.galleryFolders.first { $0.id == folderID }
    }

    private var gridMode: GalleryGridMode {
        GalleryGridMode(rawValue: gridModeValue) ?? .square
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let folder, !folder.writable {
                    Label(
                        "This external folder is read-only in Companion.",
                        systemImage: "lock.fill"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .tesseraeCard()
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                }

                if let response = model.offlineAlbumsByFolderID[folderID] {
                    OfflineAlbumSummaryCard(
                        response: response,
                        displays: model.displays,
                        open: beginOfflineAlbumEditing
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                }

                if let detail, !detail.images.isEmpty {
                    GalleryPhotoGrid(
                        images: detail.images,
                        mode: gridMode,
                        columnCount: gridColumnCount,
                        openPhoto: { image in
                            guard !suppressPhotoSelection else { return }
                            selectedPhotoID = image.id
                        }
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .simultaneousGesture(gridMagnificationGesture)
        .accessibilityIdentifier("gallery-folder-scroll")
        .overlay {
            if model.loadingGalleryFolderIDs.contains(folderID) && detail == nil {
                GalleryLoadingView(title: "Loading Photos…")
            } else if let detail, detail.images.isEmpty {
                ContentUnavailableView {
                    Label("No Photos", systemImage: "photo")
                } description: {
                    if detail.folder.writable {
                        Text("Add photos from your library to this folder.")
                    } else {
                        Text("This external folder does not contain any supported images.")
                    }
                } actions: {
                    if detail.folder.writable {
                        Button("Add Photos") {
                            beginAddingPhotos()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .navigationTitle(folder?.name ?? "Library")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Picker("Grid Style", selection: $gridModeValue) {
                        Label("Square Photo Grid", systemImage: "square.grid.3x3")
                            .tag(GalleryGridMode.square.rawValue)
                        Label(
                            "Aspect Ratio Grid",
                            systemImage: "rectangle.grid.3x2"
                        )
                        .tag(GalleryGridMode.aspectRatio.rawValue)
                    }

                    Divider()

                    Button {
                        animateGridColumns(by: -1)
                    } label: {
                        Label("Zoom In", systemImage: "plus.magnifyingglass")
                    }
                    .disabled(gridColumnCount <= 2)

                    Button {
                        animateGridColumns(by: 1)
                    } label: {
                        Label("Zoom Out", systemImage: "minus.magnifyingglass")
                    }
                    .disabled(gridColumnCount >= 8)

                    if model.supportsOfflineAlbums {
                        Divider()

                        Button {
                            beginOfflineAlbumEditing()
                        } label: {
                            Label(
                                model.offlineAlbumsByFolderID[folderID] == nil
                                    ? "Set Up Offline Album"
                                    : "Manage Offline Album",
                                systemImage: "externaldrive.badge.wifi"
                            )
                        }
                        .disabled(
                            isPreparingOfflineAlbumEditor
                                || (model.offlineAlbumsByFolderID[folderID] == nil
                                    && detail?.images.isEmpty != false)
                        )
                    }
                } label: {
                    Label("Grid Options", systemImage: "ellipsis.circle")
                }
                .accessibilityIdentifier("gallery-grid-options")

                if folder?.writable == true {
                    Button("Add Photos", systemImage: "plus") {
                        beginAddingPhotos()
                    }
                    .accessibilityIdentifier("gallery-add-photos")
                }
            }
        }
        .refreshable {
            await model.refreshGalleryFolder(id: folderID)
            await model.refreshOfflineAlbum(folderID: folderID)
        }
        .task(id: folderID) {
            await model.refreshGalleryFolder(id: folderID, showErrors: false)
            await model.refreshOfflineAlbum(folderID: folderID, showErrors: false)
        }
        .navigationDestination(item: $selectedPhotoID) { imageID in
            GalleryImageView(
                images: detail?.images ?? [],
                initialImageID: imageID
            )
        }
        .photosPicker(
            isPresented: $isPhotoPickerPresented,
            selection: $pickerItems,
            maxSelectionCount: max(
                1,
                model.capabilities?.limits.galleryUploadBatchSize ?? 20
            ),
            matching: .images
        )
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty, let folder else { return }
            galleryUploads.enqueue(
                folder: folder,
                pickerItems: items,
                using: model
            )
            pickerItems = []
        }
        .sheet(isPresented: $offlineAlbumEditorPresented) {
            if let folder {
                OfflineAlbumEditorView(
                    folder: folder,
                    images: detail?.images ?? [],
                    current: model.offlineAlbumsByFolderID[folderID]
                )
            }
        }
        .alert("Permission Required", isPresented: $permissionAlertPresented) {
            Button("Open Tesserae") {
                if let url = gallerySettingsURL(model: model) {
                    openURL(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Enable Gallery uploads for this iPhone in Tesserae Settings → Companion."
            )
        }
        .alert(
            "Permission Required",
            isPresented: $offlineAlbumPermissionAlertPresented
        ) {
            Button("Open Tesserae") {
                if let url = offlineAlbumSettingsURL(model: model) {
                    openURL(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Enable Offline Album management for this iPhone in Tesserae Settings → Companion. You do not need to pair again."
            )
        }
        .tesseraeScreenBackground()
    }

    private func beginAddingPhotos() {
        if model.galleryWritePermission == .denied {
            permissionAlertPresented = true
            return
        }
        isPhotoPickerPresented = true
    }

    private func beginOfflineAlbumEditing() {
        if model.offlineAlbumAuthoringPermission == .denied,
           model.offlineAlbumsByFolderID[folderID] == nil
        {
            offlineAlbumPermissionAlertPresented = true
            return
        }
        guard !isPreparingOfflineAlbumEditor else { return }
        isPreparingOfflineAlbumEditor = true
        Task {
            await model.refreshOfflineAlbum(folderID: folderID, showErrors: true)
            isPreparingOfflineAlbumEditor = false
            offlineAlbumEditorPresented = true
        }
    }

    private var gridMagnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { scale in
                let startingColumns = pinchStartColumnCount ?? gridColumnCount
                if pinchStartColumnCount == nil {
                    pinchStartColumnCount = startingColumns
                    gridGestureSequence += 1
                    suppressPhotoSelection = true
                }
                let nextColumnCount = galleryGridColumnCount(
                    startingAt: startingColumns,
                    magnification: scale
                )
                guard nextColumnCount != gridColumnCount else { return }
                withAnimation(.smooth(duration: 0.24)) {
                    gridColumnCount = nextColumnCount
                }
            }
            .onEnded { _ in
                pinchStartColumnCount = nil
                let completedSequence = gridGestureSequence
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(240))
                    guard completedSequence == gridGestureSequence else { return }
                    suppressPhotoSelection = false
                }
            }
    }

    private func animateGridColumns(by delta: Int) {
        withAnimation(.smooth(duration: 0.28)) {
            gridColumnCount = min(max(gridColumnCount + delta, 2), 8)
        }
    }
}

private struct GalleryPhotoGrid: View {
    @State private var availableWidth: CGFloat = 0

    let images: [GalleryImage]
    let mode: GalleryGridMode
    let columnCount: Int
    let openPhoto: (GalleryImage) -> Void

    private let spacing: CGFloat = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch mode {
            case .square:
                LazyVGrid(columns: squareColumns, spacing: spacing) {
                    ForEach(images) { image in
                        GallerySquarePhotoCell(
                            image: image,
                            openPhoto: openPhoto
                        )
                    }
                }
            case .aspectRatio:
                if availableWidth > 0 {
                    LazyVStack(alignment: .leading, spacing: spacing) {
                        ForEach(aspectRows) { row in
                            HStack(spacing: spacing) {
                                ForEach(row.items) { item in
                                    GalleryPhotoLink(
                                        image: item.image,
                                        openPhoto: openPhoto
                                    )
                                        .frame(width: item.width, height: row.height)
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.smooth(duration: 0.28), value: columnCount)
        .accessibilityIdentifier("gallery-photo-grid")
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            guard width > 0, abs(width - availableWidth) > 0.5 else {
                return
            }
            availableWidth = width
        }
    }

    private var squareColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: spacing),
            count: min(max(columnCount, 2), 8)
        )
    }

    private var aspectRows: [GalleryAspectRow] {
        galleryAspectRows(
            images: images,
            availableWidth: availableWidth,
            preferredColumns: columnCount,
            spacing: spacing
        )
    }
}

private struct GallerySquarePhotoCell: View {
    let image: GalleryImage
    let openPhoto: (GalleryImage) -> Void

    var body: some View {
        Rectangle()
            .fill(.clear)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                GalleryPhotoLink(
                    image: image,
                    openPhoto: openPhoto
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .clipped()
    }
}

private struct GalleryPhotoLink: View {
    @Environment(AppModel.self) private var model

    let image: GalleryImage
    let openPhoto: (GalleryImage) -> Void

    var body: some View {
        Button {
            openPhoto(image)
        } label: {
            GalleryThumbnail(
                path: image.thumbnailURL,
                symbol: "photo"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(image.name)
        .accessibilityIdentifier("gallery-image-\(image.id)")
        .task(id: image.thumbnailURL) {
            await model.loadGalleryThumbnail(path: image.thumbnailURL)
        }
    }
}

private struct GalleryLoadedPreview {
    let data: Data
    let image: UIImage
}

private struct GalleryIndexedImage: Identifiable {
    let position: Int
    let image: GalleryImage

    var id: String { image.id }
}

private struct GalleryImageView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedImageID: String
    @State private var loadedPreviews: [String: GalleryLoadedPreview] = [:]
    @State private var loadingPreviewImageIDs: Set<String> = []
    @State private var previewErrorMessages: [String: String] = [:]
    @State private var sendingImageID: String?
    @State private var sendDraft: SendImageDraft?
    @State private var immersivePresented = false

    let images: [GalleryImage]

    init(images: [GalleryImage], initialImageID: String) {
        self.images = images
        let initialID = images.contains { $0.id == initialImageID }
            ? initialImageID
            : images.first?.id ?? initialImageID
        _selectedImageID = State(initialValue: initialID)
    }

    private var indexedImages: [GalleryIndexedImage] {
        images.enumerated().map {
            GalleryIndexedImage(position: $0.offset + 1, image: $0.element)
        }
    }

    private var selectedImage: GalleryImage? {
        images.first { $0.id == selectedImageID }
    }

    var body: some View {
        TabView(selection: $selectedImageID) {
            ForEach(indexedImages) { indexedImage in
                imagePage(indexedImage)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .accessibilityIdentifier("gallery-photo-pager")
        .navigationTitle("Photo")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: selectedImageID) {
            guard let selectedImage else { return }
            await loadPreview(selectedImage)
        }
        .fullScreenCover(isPresented: $immersivePresented) {
            GalleryImmersiveView(
                selectedImageID: $selectedImageID,
                images: images,
                previewImages: previewImages,
                thumbnailData: thumbnailData
            )
        }
        .sheet(item: $sendDraft) { draft in
            NavigationStack {
                SendView(
                    initialImage: draft,
                    prioritizesFramingGesture: true
                )
                    .navigationTitle("Send")
            }
            .tesseraeMessageCenterOverlay()
        }
        .tesseraeScreenBackground()
    }

    private var previewImages: [String: UIImage] {
        loadedPreviews.mapValues(\.image)
    }

    private var thumbnailData: [String: Data] {
        model.galleryThumbnailStates.compactMapValues(\.data)
    }

    private func imagePage(
        _ indexedImage: GalleryIndexedImage
    ) -> some View {
        GalleryImagePage(
            image: indexedImage.image,
            position: indexedImage.position,
            total: images.count,
            previewImage: loadedPreviews[indexedImage.id]?.image,
            thumbnailData: model.galleryThumbnailStates[
                indexedImage.image.thumbnailURL
            ]?.data,
            isLoadingPreview: loadingPreviewImageIDs.contains(indexedImage.id),
            previewErrorMessage: previewErrorMessages[indexedImage.id],
            isLoadingForSend: sendingImageID == indexedImage.id,
            openImmersive: {
                selectedImageID = indexedImage.id
                immersivePresented = true
            },
            retryPreview: {
                Task { await loadPreview(indexedImage.image, force: true) }
            },
            send: {
                Task { await prepareForSend(indexedImage.image) }
            }
        )
        .tag(indexedImage.id)
    }

    private func loadPreview(
        _ image: GalleryImage,
        force: Bool = false
    ) async {
        guard force || loadedPreviews[image.id] == nil else { return }
        guard !loadingPreviewImageIDs.contains(image.id) else { return }
        loadingPreviewImageIDs.insert(image.id)
        previewErrorMessages[image.id] = nil
        defer { loadingPreviewImageIDs.remove(image.id) }

        await model.loadGalleryThumbnail(path: image.thumbnailURL)
        do {
            let data = try await model.fetchGalleryImageContent(image)
            guard let decoded = UIImage(data: data) else {
                throw GalleryPreviewError.decoding
            }
            loadedPreviews[image.id] = GalleryLoadedPreview(
                data: data,
                image: decoded
            )
        } catch is CancellationError {
            return
        } catch {
            previewErrorMessages[image.id] = error.localizedDescription
        }
    }

    private func prepareForSend(_ image: GalleryImage) async {
        guard sendingImageID == nil else { return }
        sendingImageID = image.id
        defer { sendingImageID = nil }
        do {
            let data: Data
            if let loadedPreview = loadedPreviews[image.id] {
                data = loadedPreview.data
            } else {
                data = try await model.fetchGalleryImageContent(image)
            }
            let payload = try gallerySendPayload(
                data: data,
                image: image,
                supportedContentTypes: Set(
                    model.capabilities?.limits.imageContentTypes ?? []
                )
            )
            sendDraft = SendImageDraft(
                data: payload.data,
                contentType: payload.contentType
            )
        } catch {
            model.lastError = error.localizedDescription
        }
    }
}

private struct GalleryImagePage: View {
    let image: GalleryImage
    let position: Int
    let total: Int
    let previewImage: UIImage?
    let thumbnailData: Data?
    let isLoadingPreview: Bool
    let previewErrorMessage: String?
    let isLoadingForSend: Bool
    let openImmersive: () -> Void
    let retryPreview: () -> Void
    let send: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Button(action: openImmersive) {
                    GalleryPreviewCanvas(
                        image: image,
                        previewImage: previewImage,
                        thumbnailData: thumbnailData,
                        isLoading: isLoadingPreview
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open Full Screen")
                .accessibilityIdentifier("gallery-image-preview-\(image.id)")

                if let previewErrorMessage {
                    HStack(spacing: 10) {
                        Label(
                            "Full-resolution preview unavailable.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Button("Retry", action: retryPreview)
                    }
                    .tesseraeCard()
                    .accessibilityLabel(previewErrorMessage)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(image.name)
                        .font(.headline)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(imageMetadata)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text("\(position) / \(total)")
                            .monospacedDigit()
                            .lineLimit(1)
                            .accessibilityLabel(
                                Text("Photo \(position) of \(total)")
                            )
                            .accessibilityIdentifier(
                                "gallery-photo-position-\(image.id)"
                            )
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .tesseraeCard()

                Button(action: send) {
                    Label("Send to Displays", systemImage: "paperplane.fill")
                        .frame(maxWidth: .infinity)
                        .opacity(isLoadingForSend ? 0 : 1)
                        .overlay {
                            if isLoadingForSend {
                                ProgressView()
                                    .tint(.white)
                            }
                        }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isLoadingForSend)
                .accessibilityIdentifier("gallery-send-image")
            }
            .frame(maxWidth: .infinity)
            .padding(16)
        }
        .accessibilityIdentifier("gallery-photo-page-\(image.id)")
    }

    private var imageMetadata: String {
        let size = ByteCountFormatter.string(
            fromByteCount: Int64(image.bytes),
            countStyle: .file
        )
        return "\(image.width) × \(image.height) · \(size)"
    }
}

private struct GalleryPreviewCanvas: View {
    let image: GalleryImage
    let previewImage: UIImage?
    let thumbnailData: Data?
    let isLoading: Bool

    private var displayImage: UIImage? {
        previewImage ?? thumbnailData.flatMap(UIImage.init(data:))
    }

    private var aspectRatio: CGFloat {
        if let displayImage, displayImage.size.height > 0 {
            return min(
                max(displayImage.size.width / displayImage.size.height, 0.2),
                5
            )
        }
        return min(
            max(
                max(CGFloat(image.width), 1) / max(CGFloat(image.height), 1),
                0.2
            ),
            5
        )
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.secondary.opacity(0.10))

            if let displayImage {
                Image(uiImage: displayImage)
                    .resizable()
                    .scaledToFit()
            } else if isLoading {
                ProgressView("Loading Photo…")
            } else {
                Image(systemName: "photo")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(aspectRatio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct GalleryImmersiveView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedImageID: String
    @State private var dismissOffset: CGFloat = 0
    @State private var selectedZoomScale: CGFloat = 1
    @State private var selectedPhotoIsMagnifying = false

    let images: [GalleryImage]
    let previewImages: [String: UIImage]
    let thumbnailData: [String: Data]

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.opacity(backgroundOpacity(in: proxy.size.height))

                TabView(selection: $selectedImageID) {
                    ForEach(images) { image in
                        GalleryZoomablePhoto(
                            imageID: image.id,
                            image: previewImages[image.id]
                                ?? thumbnailData[image.id].flatMap(UIImage.init(data:)),
                            zoomStateChanged: { scale, isMagnifying in
                                if image.id == selectedImageID {
                                    selectedZoomScale = scale
                                    selectedPhotoIsMagnifying = isMagnifying
                                }
                            }
                        )
                        .tag(image.id)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .scrollDisabled(
                    selectedPhotoIsMagnifying || selectedZoomScale > 1.01
                )
            }
            .offset(y: max(0, dismissOffset))
            .scaleEffect(dismissScale(in: proxy.size.height))
            .simultaneousGesture(
                dismissGesture,
                including: selectedPhotoIsMagnifying ? .none : .all
            )
        }
        .ignoresSafeArea()
        .statusBarHidden(true)
        .background(Color.black)
        .accessibilityIdentifier("gallery-immersive-view")
        .accessibilityAction(.escape) {
            dismiss()
        }
        .onChange(of: selectedImageID) { _, _ in
            selectedZoomScale = 1
            selectedPhotoIsMagnifying = false
            dismissOffset = 0
        }
    }

    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { value in
                guard selectedZoomScale <= 1.01,
                      value.translation.height > 0,
                      value.translation.height > abs(value.translation.width)
                else { return }
                dismissOffset = value.translation.height
            }
            .onEnded { value in
                guard dismissOffset > 0 else { return }
                if galleryShouldDismissImmersivePhoto(
                    dragOffset: dismissOffset,
                    predictedEndOffset: value.predictedEndTranslation.height,
                    zoomScale: selectedZoomScale
                ) {
                    dismiss()
                } else {
                    withAnimation(.smooth(duration: 0.22)) {
                        dismissOffset = 0
                    }
                }
            }
    }

    private func backgroundOpacity(in height: CGFloat) -> Double {
        let progress = min(max(dismissOffset / max(height, 1), 0), 1)
        return 1 - Double(progress) * 0.65
    }

    private func dismissScale(in height: CGFloat) -> CGFloat {
        let progress = min(max(dismissOffset / max(height, 1), 0), 1)
        return 1 - progress * 0.08
    }
}

private struct GalleryZoomablePhoto: View {
    @State private var scale: CGFloat = 1
    @State private var settledScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var settledOffset: CGSize = .zero

    let imageID: String
    let image: UIImage?
    let zoomStateChanged: (CGFloat, Bool) -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.clear

                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(scale)
                        .offset(offset)
                } else {
                    ProgressView("Loading Photo…")
                        .tint(.white)
                        .foregroundStyle(.white)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .simultaneousGesture(magnificationGesture(in: proxy.size))
            .simultaneousGesture(
                panGesture(in: proxy.size),
                including: scale > 1.01 ? .all : .none
            )
            .onTapGesture(count: 2) {
                toggleZoom(in: proxy.size)
            }
        }
        .accessibilityIdentifier("gallery-immersive-photo-\(imageID)")
        .accessibilityValue(
            Text(verbatim: String(format: "%.2f×", Double(scale)))
        )
        .onChange(of: imageID) { _, _ in
            resetZoom()
        }
    }

    private func magnificationGesture(in containerSize: CGSize) -> some Gesture {
        MagnificationGesture()
            .onChanged { magnification in
                let proposedScale = min(
                    max(settledScale * magnification, 1),
                    6
                )
                scale = proposedScale
                offset = clampedOffset(
                    settledOffset,
                    scale: proposedScale,
                    in: containerSize
                )
                zoomStateChanged(proposedScale, true)
            }
            .onEnded { _ in
                settledScale = scale
                if scale < 1.2 {
                    resetZoom()
                } else {
                    settledOffset = offset
                    zoomStateChanged(scale, false)
                }
            }
    }

    private func panGesture(in containerSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard scale > 1.01 else { return }
                let proposed = CGSize(
                    width: settledOffset.width + value.translation.width,
                    height: settledOffset.height + value.translation.height
                )
                offset = clampedOffset(
                    proposed,
                    scale: scale,
                    in: containerSize
                )
            }
            .onEnded { _ in
                guard scale > 1.01 else { return }
                settledOffset = offset
            }
    }

    private func toggleZoom(in containerSize: CGSize) {
        withAnimation(.smooth(duration: 0.24)) {
            if scale > 1.01 {
                scale = 1
                settledScale = 1
                offset = .zero
                settledOffset = .zero
            } else {
                scale = 2
                settledScale = 2
                offset = clampedOffset(
                    .zero,
                    scale: 2,
                    in: containerSize
                )
                settledOffset = offset
            }
        }
        zoomStateChanged(scale, false)
    }

    private func resetZoom() {
        scale = 1
        settledScale = 1
        offset = .zero
        settledOffset = .zero
        zoomStateChanged(1, false)
    }

    private func clampedOffset(
        _ proposed: CGSize,
        scale: CGFloat,
        in containerSize: CGSize
    ) -> CGSize {
        guard let image, image.size.width > 0, image.size.height > 0 else {
            return .zero
        }
        let imageRatio = image.size.width / image.size.height
        let containerRatio = containerSize.width / max(containerSize.height, 1)
        let fittedSize: CGSize
        if imageRatio > containerRatio {
            fittedSize = CGSize(
                width: containerSize.width,
                height: containerSize.width / imageRatio
            )
        } else {
            fittedSize = CGSize(
                width: containerSize.height * imageRatio,
                height: containerSize.height
            )
        }
        let maximumX = max(0, (fittedSize.width * scale - containerSize.width) / 2)
        let maximumY = max(
            0,
            (fittedSize.height * scale - containerSize.height) / 2
        )
        return CGSize(
            width: min(max(proposed.width, -maximumX), maximumX),
            height: min(max(proposed.height, -maximumY), maximumY)
        )
    }
}

struct GallerySendPayload: Equatable {
    let data: Data
    let contentType: String
}

func gallerySendPayload(
    data: Data,
    image: GalleryImage,
    supportedContentTypes: Set<String>
) throws -> GallerySendPayload {
    if supportedContentTypes.contains(image.contentType) {
        return GallerySendPayload(data: data, contentType: image.contentType)
    }
    guard let jpeg = UIImage(data: data)?.jpegData(compressionQuality: 0.92) else {
        throw UploadImagePreparationError.decoding
    }
    return GallerySendPayload(data: jpeg, contentType: "image/jpeg")
}

private enum GalleryPreviewError: LocalizedError {
    case decoding

    var errorDescription: String? {
        String(localized: "This photo could not be decoded.")
    }
}

private struct GalleryThumbnail: View {
    @Environment(AppModel.self) private var model

    let path: String?
    let symbol: String

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Rectangle()
                    .fill(.secondary.opacity(0.10))

                if let path,
                   let data = model.galleryThumbnailStates[path]?.data,
                   let image = UIImage(data: data)
                {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(
                            width: proxy.size.width,
                            height: proxy.size.height
                        )
                } else if let path,
                          model.galleryThumbnailStates[path]?.showsProgress == true
                {
                    ProgressView()
                } else {
                    Image(systemName: symbol)
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .clipped()
        .accessibilityHidden(true)
    }
}

private struct GalleryCreateFolderView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Family photos", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Folder")
                } footer: {
                    Text(
                        "Tesserae normalizes this into its storage name. The returned name may differ."
                    )
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(TesseraeTheme.terracotta)
                    }
                }
            }
            .navigationTitle("New Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task { await create() }
                    }
                    .disabled(trimmedName.isEmpty || isSaving)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func create() async {
        guard !trimmedName.isEmpty, !isSaving else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            _ = try await model.createGalleryFolder(name: trimmedName)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

enum GalleryUploadStatus: Equatable {
    case pending
    case preparing
    case uploading
    case uploaded
    case failed(String)
}

struct GalleryUploadCounts: Equatable {
    let total: Int
    let finished: Int
    let uploaded: Int
    let failed: Int

    var isWorking: Bool { finished < total }
}

func galleryUploadCounts(
    statuses: [GalleryUploadStatus]
) -> GalleryUploadCounts {
    let uploaded = statuses.filter { $0 == .uploaded }.count
    let failed = statuses.filter {
        if case .failed = $0 { true } else { false }
    }.count
    return GalleryUploadCounts(
        total: statuses.count,
        finished: uploaded + failed,
        uploaded: uploaded,
        failed: failed
    )
}

struct GalleryUploadSource {
    let supportedContentTypes: [UTType]
    let loadData: @MainActor () async throws -> Data?

    init(pickerItem: PhotosPickerItem) {
        supportedContentTypes = pickerItem.supportedContentTypes
        loadData = {
            try await pickerItem.loadTransferable(type: Data.self)
        }
    }

    init(
        supportedContentTypes: [UTType],
        loadData: @escaping @MainActor () async throws -> Data?
    ) {
        self.supportedContentTypes = supportedContentTypes
        self.loadData = loadData
    }
}

struct GalleryUploadItem: Identifiable {
    let id = UUID()
    let folderID: String
    let folderName: String
    let name: String
    let source: GalleryUploadSource
    let sourceIndex: Int
    let idempotencyKey: String
    var status: GalleryUploadStatus
}

struct GalleryUploadGroup: Identifiable {
    let folderID: String
    let folderName: String
    let uploads: [GalleryUploadItem]

    var id: String { folderID }
}

@MainActor
@Observable
final class GalleryUploadCoordinator {
    private(set) var uploads: [GalleryUploadItem] = []

    private var workerTask: Task<Void, Never>?
    private var completionTask: Task<Void, Never>?
    private var detailsPresented = false
    private let successVisibilityDuration: Duration

    init(successVisibilityDuration: Duration = .seconds(1.8)) {
        self.successVisibilityDuration = successVisibilityDuration
    }

    var counts: GalleryUploadCounts {
        galleryUploadCounts(statuses: uploads.map(\.status))
    }

    var hasUploads: Bool { !uploads.isEmpty }
    var isWorking: Bool { hasUploads && counts.isWorking }

    var groups: [GalleryUploadGroup] {
        var result: [GalleryUploadGroup] = []
        for upload in uploads {
            if let index = result.firstIndex(where: {
                $0.folderID == upload.folderID
            }) {
                let group = result[index]
                result[index] = GalleryUploadGroup(
                    folderID: group.folderID,
                    folderName: group.folderName,
                    uploads: group.uploads + [upload]
                )
            } else {
                result.append(
                    GalleryUploadGroup(
                        folderID: upload.folderID,
                        folderName: upload.folderName,
                        uploads: [upload]
                    )
                )
            }
        }
        return result
    }

    var capsuleTitle: String {
        if isWorking {
            return String(
                localized: "Uploading \(counts.finished) of \(counts.total)"
            )
        }
        if counts.failed > 0 {
            return String(localized: "\(counts.failed) Uploads Failed")
        }
        return String(localized: "\(counts.uploaded) Photos Uploaded")
    }

    func enqueue(
        folder: GalleryFolder,
        pickerItems: [PhotosPickerItem],
        using model: AppModel
    ) {
        enqueue(
            folder: folder,
            sources: pickerItems.map(GalleryUploadSource.init(pickerItem:)),
            using: model
        )
    }

    func enqueue(
        folder: GalleryFolder,
        sources: [GalleryUploadSource],
        using model: AppModel
    ) {
        guard !sources.isEmpty else { return }
        completionTask?.cancel()
        completionTask = nil

        let existingCount = uploads.filter { $0.folderID == folder.id }.count
        for (index, source) in sources.enumerated() {
            let sourceIndex = existingCount + index
            uploads.append(
                GalleryUploadItem(
                    folderID: folder.id,
                    folderName: folder.name,
                    name: String(localized: "Photo \(sourceIndex + 1)"),
                    source: source,
                    sourceIndex: sourceIndex,
                    idempotencyKey: UUID().uuidString,
                    status: .pending
                )
            )
        }
        startWorker(using: model)
    }

    func retryFailed(using model: AppModel) {
        completionTask?.cancel()
        completionTask = nil
        for index in uploads.indices {
            if case .failed = uploads[index].status {
                uploads[index].status = .pending
            }
        }
        startWorker(using: model)
    }

    func dismissFinishedUploads() {
        guard !isWorking else { return }
        completionTask?.cancel()
        completionTask = nil
        uploads = []
    }

    func setDetailsPresented(_ presented: Bool) {
        detailsPresented = presented
        if presented {
            completionTask?.cancel()
            completionTask = nil
        } else if hasUploads, !isWorking, counts.failed == 0 {
            scheduleSuccessfulDismissal()
        }
    }

    func cancelAndClear() {
        workerTask?.cancel()
        workerTask = nil
        completionTask?.cancel()
        completionTask = nil
        detailsPresented = false
        uploads = []
    }

    func waitUntilIdle() async {
        await workerTask?.value
    }

#if DEBUG
    func seedForUITesting() {
        guard uploads.isEmpty else { return }
        let source = GalleryUploadSource(supportedContentTypes: [.jpeg]) {
            Data("gallery-ui-test-photo".utf8)
        }
        uploads = (0 ..< 5).map { index in
            GalleryUploadItem(
                folderID: "folder_family",
                folderName: "family",
                name: String(localized: "Photo \(index + 1)"),
                source: source,
                sourceIndex: index,
                idempotencyKey: "gallery-ui-test-\(index)",
                status: index < 2 ? .uploaded : (index == 2 ? .uploading : .pending)
            )
        }
    }
#endif

    private func startWorker(using model: AppModel) {
        guard workerTask == nil,
              uploads.contains(where: { $0.status == .pending })
        else { return }
        workerTask = Task { @MainActor [weak self, weak model] in
            guard let self, let model else { return }
            await self.processPending(using: model)
        }
    }

    private func processPending(using model: AppModel) async {
        while !Task.isCancelled,
              let itemID = uploads.first(where: { $0.status == .pending })?.id
        {
            await process(itemID: itemID, using: model)
        }
        workerTask = nil
        guard !Task.isCancelled, hasUploads, !isWorking else { return }
        if counts.failed == 0, !detailsPresented {
            scheduleSuccessfulDismissal()
        }
    }

    private func process(itemID: UUID, using model: AppModel) async {
        guard let initialIndex = index(of: itemID) else { return }
        uploads[initialIndex].status = .preparing
        do {
            let source = uploads[initialIndex].source
            guard let data = try await source.loadData() else {
                throw UploadImagePreparationError.decoding
            }
            try Task.checkCancellation()

            let acceptedTypes = Set(
                model.capabilities?.limits.galleryImageContentTypes ?? [
                    "image/jpeg",
                    "image/png",
                    "image/heic",
                    "image/heif",
                    "image/webp",
                ]
            )
            let contentType = source.supportedContentTypes
                .compactMap(\.preferredMIMEType)
                .first(where: acceptedTypes.contains)
            guard let contentType else {
                throw GalleryUploadError.unsupportedType
            }
            if let byteLimit = model.capabilities?.limits.galleryUploadBytes,
               data.count > byteLimit
            {
                throw GalleryUploadError.tooLarge(byteLimit)
            }
            guard let uploadIndex = index(of: itemID) else { return }
            uploads[uploadIndex].status = .uploading
            let upload = uploads[uploadIndex]
            _ = try await model.uploadGalleryImage(
                folderID: upload.folderID,
                data: data,
                fileName: "photo-\(upload.sourceIndex + 1).\(fileExtension(for: contentType))",
                contentType: contentType,
                idempotencyKey: upload.idempotencyKey
            )
            guard let completedIndex = index(of: itemID) else { return }
            uploads[completedIndex].status = .uploaded
        } catch is CancellationError {
            if let index = index(of: itemID) {
                uploads[index].status = .pending
            }
        } catch {
            if let index = index(of: itemID) {
                uploads[index].status = .failed(error.localizedDescription)
            }
        }
    }

    private func scheduleSuccessfulDismissal() {
        completionTask?.cancel()
        completionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: successVisibilityDuration)
            guard !Task.isCancelled,
                  self.hasUploads,
                  !self.isWorking,
                  self.counts.failed == 0,
                  !self.detailsPresented
            else { return }
            self.uploads = []
            self.completionTask = nil
        }
    }

    private func index(of itemID: UUID) -> Int? {
        uploads.firstIndex { $0.id == itemID }
    }

    private func fileExtension(for contentType: String) -> String {
        switch contentType {
        case "image/png": "png"
        case "image/heic": "heic"
        case "image/heif": "heif"
        case "image/webp": "webp"
        default: "jpg"
        }
    }
}

struct GalleryUploadDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(GalleryUploadCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(coordinator.groups) { group in
                    Section {
                        ForEach(group.uploads) { upload in
                            GalleryUploadRow(upload: upload)
                        }
                    } header: {
                        Text(group.folderName)
                    } footer: {
                        let counts = galleryUploadCounts(
                            statuses: group.uploads.map(\.status)
                        )
                        Text("\(counts.finished) of \(counts.total) finished")
                    }
                }

                if coordinator.counts.failed > 0 && !coordinator.isWorking {
                    Section {
                        Button("Retry Failed Uploads") {
                            coordinator.retryFailed(using: model)
                        }

                        Button("Dismiss Failed Uploads", role: .destructive) {
                            coordinator.dismissFinishedUploads()
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("Upload Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .accessibilityIdentifier("gallery-upload-details")
    }
}

private struct GalleryUploadRow: View {
    let upload: GalleryUploadItem

    var body: some View {
        HStack(spacing: 12) {
            statusIcon
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(upload.name)
                if case let .failed(message) = upload.status {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(TesseraeTheme.terracotta)
                        .lineLimit(2)
                }
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch upload.status {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
        case .preparing, .uploading:
            ProgressView()
        case .uploaded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(TesseraeTheme.accent)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(TesseraeTheme.terracotta)
        }
    }
}

private enum GalleryUploadError: LocalizedError {
    case unsupportedType
    case tooLarge(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedType:
            String(localized: "This photo format is not accepted by the Gallery.")
        case let .tooLarge(limit):
            String(
                localized: "This photo exceeds the Gallery upload limit of \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file))."
            )
        }
    }
}

@MainActor
private func gallerySettingsURL(model: AppModel) -> URL? {
    guard let instance = model.activeInstance else { return nil }
    let destination = model.galleryWriteSettingsURL ?? instance.webURL
    return URL(string: destination, relativeTo: instance.baseURL)?.absoluteURL
}

@MainActor
private func offlineAlbumSettingsURL(model: AppModel) -> URL? {
    guard let instance = model.activeInstance else { return nil }
    let destination = model.offlineAlbumSettingsURL ?? instance.webURL
    return URL(string: destination, relativeTo: instance.baseURL)?.absoluteURL
}

#if DEBUG
#Preview("Gallery") {
    TesseraePreviewHost {
        NavigationStack {
            GalleryView(isActive: true)
        }
    }
}
#endif
