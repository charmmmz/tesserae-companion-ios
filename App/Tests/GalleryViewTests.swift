import Foundation
import TesseraeKit
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import Tesserae_Companion

@MainActor
final class GalleryViewTests: XCTestCase {
    func testUploadCountsTreatFailuresAsFinishedWithoutCallingThemUploaded() {
        let counts = galleryUploadCounts(
            statuses: [
                .uploaded,
                .failed("Network unavailable"),
                .uploading,
                .pending,
            ]
        )

        XCTAssertEqual(
            counts,
            GalleryUploadCounts(
                total: 4,
                finished: 2,
                uploaded: 1,
                failed: 1
            )
        )
        XCTAssertTrue(counts.isWorking)
    }

    func testUploadCoordinatorRunsQueueWithoutAProgressSheet() async throws {
        let model = makeGalleryModel()
        await model.connectDemo()
        await model.refreshGallery()
        await model.refreshGalleryFolder(id: "folder_family")
        let folder = try XCTUnwrap(
            model.galleryFolders.first { $0.id == "folder_family" }
        )
        let initialImageCount = try XCTUnwrap(
            model.galleryFolderDetails[folder.id]?.images.count
        )
        let coordinator = GalleryUploadCoordinator(
            successVisibilityDuration: .seconds(60)
        )
        let sources = (0 ..< 2).map { index in
            GalleryUploadSource(supportedContentTypes: [.jpeg]) {
                Data("queued-photo-\(index)".utf8)
            }
        }

        coordinator.enqueue(folder: folder, sources: sources, using: model)

        XCTAssertTrue(coordinator.hasUploads)
        XCTAssertTrue(coordinator.isWorking)
        await coordinator.waitUntilIdle()
        XCTAssertEqual(coordinator.counts.uploaded, 2)
        XCTAssertEqual(coordinator.counts.failed, 0)
        XCTAssertFalse(coordinator.isWorking)
        XCTAssertEqual(
            model.galleryFolderDetails[folder.id]?.images.count,
            initialImageCount + 2
        )
        coordinator.cancelAndClear()
    }

    func testPinchMagnificationAdjustsAndClampsGridDensity() {
        XCTAssertEqual(
            galleryGridColumnCount(startingAt: 4, magnification: 2),
            2
        )
        XCTAssertEqual(
            galleryGridColumnCount(startingAt: 4, magnification: 0.5),
            8
        )
        XCTAssertEqual(
            galleryGridColumnCount(startingAt: 2, magnification: 4),
            2
        )
        XCTAssertEqual(
            galleryGridColumnCount(startingAt: 8, magnification: 0.1),
            8
        )
    }

    func testImmersiveDismissRequiresDownwardThresholdAtRestingZoom() {
        XCTAssertTrue(
            galleryShouldDismissImmersivePhoto(
                dragOffset: 121,
                predictedEndOffset: 121,
                zoomScale: 1
            )
        )
        XCTAssertTrue(
            galleryShouldDismissImmersivePhoto(
                dragOffset: 80,
                predictedEndOffset: 241,
                zoomScale: 1
            )
        )
        XCTAssertFalse(
            galleryShouldDismissImmersivePhoto(
                dragOffset: 200,
                predictedEndOffset: 300,
                zoomScale: 2
            )
        )
        XCTAssertFalse(
            galleryShouldDismissImmersivePhoto(
                dragOffset: 80,
                predictedEndOffset: 200,
                zoomScale: 1
            )
        )
    }

    func testAspectRowsPreserveEveryImageAndReportedRatio() {
        let images = [
            image(id: "portrait", width: 900, height: 1_200),
            image(id: "landscape", width: 1_600, height: 900),
            image(id: "square", width: 1_000, height: 1_000),
            image(id: "wide", width: 2_000, height: 800),
        ]

        let rows = galleryAspectRows(
            images: images,
            availableWidth: 390,
            preferredColumns: 3,
            spacing: 2
        )

        XCTAssertEqual(rows.flatMap(\.items).map(\.id), images.map(\.id))
        for row in rows {
            let occupiedWidth = row.items.reduce(0) { $0 + $1.width }
                + CGFloat(max(row.items.count - 1, 0)) * 2
            XCTAssertLessThanOrEqual(occupiedWidth, 390.01)
            XCTAssertGreaterThan(row.height, 0)
            for item in row.items {
                let expected = CGFloat(item.image.width) / CGFloat(item.image.height)
                XCTAssertEqual(item.width / row.height, expected, accuracy: 0.001)
            }
        }
    }

    func testSendPayloadTrustsReturnedMIMETypeInsteadOfFilename() throws {
        let data = Data("server-png-rendition".utf8)
        let rendition = image(
            id: "gif-rendition",
            name: "birthday.gif.png",
            contentType: "image/png",
            width: 640,
            height: 480
        )

        let payload = try gallerySendPayload(
            data: data,
            image: rendition,
            supportedContentTypes: ["image/png"]
        )

        XCTAssertEqual(payload, GallerySendPayload(data: data, contentType: "image/png"))
    }

    func testSendPayloadConvertsUnsupportedReturnedTypeToJPEG() throws {
        let png = try XCTUnwrap(
            Data(
                base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAADIAAAAeCAYAAABuUU38AAAAU0lEQVR42u3PMQ3AIBAAQJxUSxc84KgKagcZWGBiadKViiAkn+aGE3Dpffr8gyQisily3NdcMWoOQURERERERERERGR/pJUzBBERERERERGRgJEPNPv5WtxkAPMAAAAASUVORK5CYII="
            )
        )
        let image = image(
            id: "png-only",
            name: "photo.png",
            contentType: "image/png",
            width: 1,
            height: 1
        )

        let payload = try gallerySendPayload(
            data: png,
            image: image,
            supportedContentTypes: ["image/jpeg"]
        )

        XCTAssertEqual(payload.contentType, "image/jpeg")
        XCTAssertEqual(payload.data.prefix(2), Data([0xFF, 0xD8]))
    }

    private func image(
        id: String,
        name: String = "photo.jpg",
        contentType: String = "image/jpeg",
        width: Int,
        height: Int
    ) -> GalleryImage {
        GalleryImage(
            id: id,
            folderID: "family",
            name: name,
            contentType: contentType,
            bytes: 128,
            width: width,
            height: height,
            eTag: "\"\(id)\"",
            thumbnailURL: "/api/app/v1/gallery/images/\(id)/thumbnail",
            contentURL: "/api/app/v1/gallery/images/\(id)/content"
        )
    }

    private func makeGalleryModel() -> AppModel {
        let client = MockTesseraeClient(latency: .milliseconds(0))
        return AppModel(
            liveClient: client,
            demoClient: client,
            credentials: InMemoryCredentialStore(),
            stateStore: InMemoryCompanionStateStore(),
            sendPreferences: InMemoryCompanionSendPreferencesStore(),
            shareQueue: InMemoryShareQueueStore(),
            linkShareQueue: InMemoryLinkShareQueueStore(),
            activityThumbnails: InMemoryActivityThumbnailStore(),
            discovery: StaticDiscoveryService(results: [])
        )
    }
}
