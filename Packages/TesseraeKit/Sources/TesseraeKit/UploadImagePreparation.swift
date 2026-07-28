import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct PreparedUploadImage: Equatable, Sendable {
    public let data: Data
    public let contentType: String
    public let fileExtension: String
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(
        data: Data,
        contentType: String,
        fileExtension: String,
        pixelWidth: Int,
        pixelHeight: Int
    ) {
        self.data = data
        self.contentType = contentType
        self.fileExtension = fileExtension
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

public enum UploadImagePreparationError: Error, Equatable, LocalizedError, Sendable {
    case decoding
    case encoding

    public var errorDescription: String? {
        switch self {
        case .decoding:
            "The selected image could not be decoded."
        case .encoding:
            "The selected image could not be prepared for upload."
        }
    }
}

public enum UploadImagePreparer {
    /// Produces upload bytes whose pixel matrix is already upright.
    ///
    /// Photos commonly supplies HEIC or JPEG data with an EXIF orientation
    /// value instead of rotating the stored pixels. UIKit previews honour that
    /// metadata, while server-side renderers do not always do so consistently.
    /// Non-upright images are therefore rendered through Core Image and encoded
    /// with orientation 1 before they leave the phone.
    public static func prepare(
        data: Data,
        fallbackContentType: String,
        maximumPixelSize: Int? = nil
    ) throws -> PreparedUploadImage {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetCount(source) > 0,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any]
        else {
            throw UploadImagePreparationError.decoding
        }

        let sourceType = CGImageSourceGetType(source)
            .flatMap { UTType($0 as String) }
        let contentType = sourceType?.preferredMIMEType ?? fallbackContentType
        let fileExtension = sourceType?.preferredFilenameExtension
            ?? fileExtension(for: contentType)
        let width = numericProperty(properties[kCGImagePropertyPixelWidth])
        let height = numericProperty(properties[kCGImagePropertyPixelHeight])
        let orientation = numericProperty(properties[kCGImagePropertyOrientation])

        guard width > 0, height > 0 else {
            throw UploadImagePreparationError.decoding
        }

        let sourceMaxEdge = max(width, height)
        let boundedMaximumPixelSize = maximumPixelSize.map {
            max(1, min($0, sourceMaxEdge))
        }
        let needsResize = boundedMaximumPixelSize.map {
            sourceMaxEdge > $0
        } ?? false
        let needsOrientationBake = orientation != 0 && orientation != 1

        if !needsResize && !needsOrientationBake {
            return PreparedUploadImage(
                data: data,
                contentType: contentType,
                fileExtension: fileExtension,
                pixelWidth: width,
                pixelHeight: height
            )
        }

        let thumbnailMaxEdge = boundedMaximumPixelSize ?? sourceMaxEdge
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxEdge,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions as CFDictionary
        ) else {
            throw UploadImagePreparationError.decoding
        }

        let encoded = NSMutableData()
        let outputContentType: String
        let outputExtension: String
        let destinationType: UTType
        if sourceType?.conforms(to: .png) == true {
            outputContentType = "image/png"
            outputExtension = "png"
            destinationType = .png
        } else {
            outputContentType = "image/jpeg"
            outputExtension = "jpg"
            destinationType = .jpeg
        }
        guard let destination = CGImageDestinationCreateWithData(
            encoded,
            destinationType.identifier as CFString,
            1,
            nil
        ) else {
            throw UploadImagePreparationError.encoding
        }
        var destinationProperties: [CFString: Any] = [
            kCGImagePropertyOrientation: 1,
        ]
        if destinationType == .jpeg {
            destinationProperties[kCGImageDestinationLossyCompressionQuality] = 0.92
        }
        CGImageDestinationAddImage(
            destination,
            image,
            destinationProperties as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw UploadImagePreparationError.encoding
        }

        return PreparedUploadImage(
            data: encoded as Data,
            contentType: outputContentType,
            fileExtension: outputExtension,
            pixelWidth: image.width,
            pixelHeight: image.height
        )
    }

    private static func numericProperty(_ value: Any?) -> Int {
        if let number = value as? NSNumber {
            return number.intValue
        }
        return 0
    }

    private static func fileExtension(for contentType: String) -> String {
        switch contentType {
        case "image/png": "png"
        case "image/heic": "heic"
        case "image/heif": "heif"
        case "image/webp": "webp"
        default: "jpg"
        }
    }
}
