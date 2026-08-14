import Foundation

public enum GalleryFolderKind: String, Codable, Hashable, Sendable {
    case `internal`
    case external
}

public struct GalleryFolder: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let kind: GalleryFolderKind
    public let writable: Bool
    public let imageCount: Int
    public let coverThumbnailURL: String?

    public init(
        id: String,
        name: String,
        kind: GalleryFolderKind,
        writable: Bool,
        imageCount: Int,
        coverThumbnailURL: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.writable = writable
        self.imageCount = imageCount
        self.coverThumbnailURL = coverThumbnailURL
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case kind
        case writable
        case imageCount
        case coverThumbnailURL = "coverThumbnailUrl"
    }
}

public struct GalleryImage: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let folderID: String
    public let name: String
    public let contentType: String
    public let bytes: Int
    public let width: Int
    public let height: Int
    public let eTag: String
    public let thumbnailURL: String
    public let contentURL: String
    public let createdAt: Date?

    public init(
        id: String,
        folderID: String,
        name: String,
        contentType: String,
        bytes: Int,
        width: Int,
        height: Int,
        eTag: String,
        thumbnailURL: String,
        contentURL: String,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.folderID = folderID
        self.name = name
        self.contentType = contentType
        self.bytes = bytes
        self.width = width
        self.height = height
        self.eTag = eTag
        self.thumbnailURL = thumbnailURL
        self.contentURL = contentURL
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case folderID = "folderId"
        case name
        case contentType
        case bytes
        case width
        case height
        case eTag = "etag"
        case thumbnailURL = "thumbnailUrl"
        case contentURL = "contentUrl"
        case createdAt
    }
}

public struct GalleryFolderDetail: Codable, Hashable, Sendable {
    public let folder: GalleryFolder
    public let images: [GalleryImage]

    public init(folder: GalleryFolder, images: [GalleryImage]) {
        self.folder = folder
        self.images = images
    }
}

public struct GalleryFoldersResponse: Codable, Hashable, Sendable {
    public let folders: [GalleryFolder]

    public init(folders: [GalleryFolder]) {
        self.folders = folders
    }
}

public struct GalleryFolderResponse: Codable, Hashable, Sendable {
    public let folder: GalleryFolder
    public let images: [GalleryImage]

    public init(folder: GalleryFolder, images: [GalleryImage]) {
        self.folder = folder
        self.images = images
    }
}

public struct GalleryFolderCreateRequest: Codable, Hashable, Sendable {
    public let name: String

    public init(name: String) {
        self.name = name
    }
}

public struct GalleryImageResponse: Codable, Hashable, Sendable {
    public let image: GalleryImage

    public init(image: GalleryImage) {
        self.image = image
    }
}
