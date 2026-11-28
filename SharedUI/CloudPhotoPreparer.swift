import CoreImage
import Foundation
import ImageIO
import TesseraeKit
import UIKit

enum CloudPhotoPreparer {
    static func prepare(data: Data, devices: [CloudDevice], selectedIDs: Set<String>,
                        fit: ImageFitMode, framings: [PanelAspectRatio: ImageFraming],
                        systemEntry: Bool = false) async throws -> CloudPhotoPreparation {
        let work = Task.detached(priority: .userInitiated) {
            guard !selectedIDs.isEmpty else { throw CloudSubmissionError.invalidPreparation }
            let selected = devices.filter { selectedIDs.contains($0.id) }
            guard selected.count == selectedIDs.count else { throw CloudSubmissionError.changedGeometry }
            let targets = try selected.map { device -> CloudSubmissionTarget in
                guard let geometry = device.panel.compositionGeometry else { throw CloudSubmissionError.changedGeometry }
                return .init(id: device.id, name: device.name, geometry: geometry)
            }
#if DEBUG
            if systemEntry { AppConfiguration.recordSystemDiagnostic("raster.before") }
#endif
            let sourceLimit = systemEntry
                ? try CloudSystemRasterBudget.decodeLimit(data: data, targets: targets, fit: fit, framings: framings)
                : nil
            let upright = try UploadImagePreparer.prepare(data: data, fallbackContentType: "image/jpeg", maximumPixelSize: sourceLimit)
            guard let image = UIImage(data: upright.data) else { throw UploadImagePreparationError.decoding }
#if DEBUG
            if systemEntry { AppConfiguration.recordSystemDiagnostic("raster.decoded") }
#endif
            let groups = Dictionary(grouping: targets, by: \.geometry)
            var outputs: [CloudPhotoOutput] = []
            for geometry in groups.keys.sorted(by: { ($0.width, $0.height) < ($1.width, $1.height) }) {
                try Task.checkCancellation()
                let aspect = PanelAspectRatio(width: geometry.width, height: geometry.height)
                let framing = framings[aspect] ?? .centeredFill
                if systemEntry {
                    try CloudSystemRasterBudget.checkWorkingSet(sourceBytes: data.count,
                        sourcePixels: upright.pixelWidth * upright.pixelHeight, geometry: geometry, fit: fit,
                        accumulatedOutputBytes: outputs.reduce(0) { $0 + $1.data.count })
                }
                let output = try autoreleasepool { try raster(image: image, geometry: geometry, fit: fit, framing: framing) }
#if DEBUG
                if systemEntry { AppConfiguration.recordSystemDiagnostic("raster.exported") }
#endif
                outputs.append(.init(data: output.data, format: output.format, geometry: geometry,
                    targetIDs: groups[geometry, default: []].map(\.id).sorted()))
            }
            return CloudPhotoPreparation(targets: targets, outputs: outputs)
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    static func raster(image: UIImage, geometry: CloudCompositionGeometry, fit: ImageFitMode,
                       framing: ImageFraming) throws -> (data: Data, format: CloudRasterFormat) {
        let size = CGSize(width: geometry.width, height: geometry.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let sourceWidth = image.size.width * image.scale
        let sourceHeight = image.size.height * image.scale
        let background: UIImage?
        if fit == .blur {
            let cover = renderer.image { context in
                UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size))
                let rect = ImageFitMode.fill.previewRect(sourceWidth: sourceWidth, sourceHeight: sourceHeight,
                    canvasWidth: Double(size.width), canvasHeight: Double(size.height))
                image.draw(in: CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height))
            }
            if let cgImage = cover.cgImage {
                let input = CIImage(cgImage: cgImage)
                let blurred = input.clampedToExtent().applyingGaussianBlur(sigma: max(2, min(size.width, size.height) / 16))
                let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
                guard let rendered = context.createCGImage(blurred, from: input.extent) else {
                    throw UploadImagePreparationError.decoding
                }
                background = UIImage(cgImage: rendered)
            } else { throw UploadImagePreparationError.decoding }
        } else { background = nil }
        let raster = renderer.image { context in
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size))
            background?.draw(in: CGRect(origin: .zero, size: size))
            if fit == .fill {
                let rect = framing.framedPreviewRect(sourceWidth: sourceWidth, sourceHeight: sourceHeight,
                    canvasWidth: Double(size.width), canvasHeight: Double(size.height),
                    targetWidth: Double(geometry.width), targetHeight: Double(geometry.height))
                image.draw(in: CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height))
            } else {
                let rect = fit.previewRect(sourceWidth: sourceWidth, sourceHeight: sourceHeight,
                    canvasWidth: Double(size.width), canvasHeight: Double(size.height),
                    targetPixelWidth: Double(geometry.width), targetPixelHeight: Double(geometry.height))
                image.draw(in: CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height))
            }
        }
#if DEBUG
        AppConfiguration.recordSystemDiagnostic("raster.canvas-alive")
#endif
        if let data = raster.pngData(), data.count <= 12_582_912 { return (data, .png) }
        for quality in [0.96, 0.9, 0.82, 0.72, 0.6] {
            if let data = raster.jpegData(compressionQuality: quality), data.count <= 12_582_912 { return (data, .jpeg) }
        }
        throw CloudSubmissionError.invalidPreparation
    }
}

enum CloudSystemRasterBudget {
    static let maximumSourceEdge = 4_096
    static let maximumDecodedPixels = 4_194_304
    static let maximumCanvasPixels = 4_194_304
    static let maximumWorkingBytes = 96 * 1_024 * 1_024

    static func decodeLimit(data: Data, targets: [CloudSubmissionTarget], fit: ImageFitMode,
                            framings: [PanelAspectRatio: ImageFraming]) throws -> Int {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let rawWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let rawHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              rawWidth.isFinite, rawHeight.isFinite, rawWidth > 0, rawHeight > 0 else { throw UploadImagePreparationError.decoding }
        let rotated = [5, 6, 7, 8].contains((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1)
        let width = rotated ? rawHeight : rawWidth, height = rotated ? rawWidth : rawHeight
        var requiredScale: Double = fit == .center ? 1 : 0
        for target in targets {
            let geometry = target.geometry
            guard geometry.width * geometry.height <= maximumCanvasPixels else { throw CloudSystemMediaError.workingSet }
            let x = Double(geometry.width) / width, y = Double(geometry.height) / height
            let scale: Double
            switch fit {
            case .fit: scale = min(x, y)
            case .fill:
                let framing = framings[PanelAspectRatio(width: geometry.width, height: geometry.height)] ?? .centeredFill
                guard framing.focusX.isFinite, framing.focusY.isFinite, framing.zoom.isFinite,
                      framing.zoom >= 1, framing.zoom <= 4 else { throw CloudSubmissionError.invalidPreparation }
                scale = max(x, y) * framing.zoom
            case .center: scale = 1
            case .blur, .stretch: scale = max(x, y)
            }
            requiredScale = max(requiredScale, min(1, scale))
        }
        let edge = ceil(max(width, height) * requiredScale)
        let pixels = ceil(width * requiredScale) * ceil(height * requiredScale)
        guard edge.isFinite, edge >= 1, edge <= Double(maximumSourceEdge), pixels <= Double(maximumDecodedPixels) else {
            throw CloudSystemMediaError.workingSet
        }
        for target in targets {
            try checkWorkingSet(sourceBytes: data.count, sourcePixels: Int(pixels), geometry: target.geometry,
                                fit: fit, accumulatedOutputBytes: 0)
        }
        return Int(edge)
    }

    static func checkWorkingSet(sourceBytes: Int, sourcePixels: Int, geometry: CloudCompositionGeometry,
                                fit: ImageFitMode, accumulatedOutputBytes: Int) throws {
        let pixels = geometry.width * geometry.height
        let estimate = sourceBytes + sourcePixels * 8 + pixels * (fit == .blur ? 24 : 12)
            + 12_582_912 + accumulatedOutputBytes
        guard sourcePixels <= maximumDecodedPixels, pixels <= maximumCanvasPixels,
              estimate <= maximumWorkingBytes else { throw CloudSystemMediaError.workingSet }
    }
}

enum CloudSystemMediaError: LocalizedError {
    case workingSet
    var errorDescription: String? {
        String(localized: "This photo needs more memory than a system action can use. It has been kept for review in Tesserae Companion.")
    }
}

extension CloudPhotoPreparer {
    static func systemEntry(runtime: ConnectionRuntime, directory: URL) -> CloudSystemEntry {
        CloudSystemEntry(runtime: runtime, directory: directory) { data, recipe, devices in
            try await prepare(data: data, devices: devices, selectedIDs: Set(devices.map(\.id)),
                fit: recipe.fit, framings: recipe.framings, systemEntry: true)
        }
    }
}
