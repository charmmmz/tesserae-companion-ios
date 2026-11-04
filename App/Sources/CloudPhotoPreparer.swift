import CoreImage
import Foundation
import TesseraeKit
import UIKit

struct CloudPhotoPreparation: Sendable {
    let targets: [CloudSubmissionTarget]
    let outputs: [CloudPhotoOutput]
}

enum CloudPhotoPreparer {
    static func prepare(data: Data, devices: [CloudDevice], selectedIDs: Set<String>,
                        fit: ImageFitMode, framings: [PanelAspectRatio: ImageFraming]) async throws -> CloudPhotoPreparation {
        let work = Task.detached(priority: .userInitiated) {
            let upright = try UploadImagePreparer.prepare(data: data, fallbackContentType: "image/jpeg")
            guard let image = UIImage(data: upright.data), !selectedIDs.isEmpty else {
                throw CloudSubmissionError.invalidPreparation
            }
            let selected = devices.filter { selectedIDs.contains($0.id) }
            guard selected.count == selectedIDs.count else { throw CloudSubmissionError.changedGeometry }
            let targets = try selected.map { device -> CloudSubmissionTarget in
                guard let geometry = device.panel.compositionGeometry else { throw CloudSubmissionError.changedGeometry }
                return .init(id: device.id, name: device.name, geometry: geometry)
            }
            let groups = Dictionary(grouping: targets, by: \.geometry)
            var outputs: [CloudPhotoOutput] = []
            for geometry in groups.keys.sorted(by: { ($0.width, $0.height) < ($1.width, $1.height) }) {
                try Task.checkCancellation()
                let aspect = PanelAspectRatio(width: geometry.width, height: geometry.height)
                let framing = framings[aspect] ?? .centeredFill
                let output = try raster(image: image, geometry: geometry, fit: fit, framing: framing)
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
        if let data = raster.pngData(), data.count <= 12_582_912 { return (data, .png) }
        for quality in [0.96, 0.9, 0.82, 0.72, 0.6] {
            if let data = raster.jpegData(compressionQuality: quality), data.count <= 12_582_912 { return (data, .jpeg) }
        }
        throw CloudSubmissionError.invalidPreparation
    }
}
