import Foundation

public enum DashboardIconName {
    private static let legacyAliases = [
        "activity": "pulse",
        "archive-box": "box-arrow-down",
        "archive-tray": "tray-arrow-down",
        "caduceus": "asclepius",
        "circle-wavy": "seal",
        "circle-wavy-check": "seal-check",
        "circle-wavy-question": "seal-question",
        "circle-wavy-warning": "seal-warning",
        "file-dotted": "file-dashed",
        "file-search": "file-magnifying-glass",
        "folder-dotted": "folder-dashed",
        "folder-notch": "folder",
        "folder-notch-minus": "folder-minus",
        "folder-notch-open": "folder-open",
        "folder-notch-plus": "folder-plus",
        "folder-simple-dotted": "folder-simple-dashed",
        "lemniscate": "infinity",
        "text-bolder": "text-b",
    ]

    public static func canonical(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let bareName = trimmed.hasPrefix("ph-")
            ? String(trimmed.dropFirst(3))
            : trimmed
        guard !bareName.isEmpty else { return nil }
        return legacyAliases[bareName] ?? bareName
    }
}

public extension DashboardSummary {
    var canonicalIconName: String? {
        DashboardIconName.canonical(iconName)
    }
}
