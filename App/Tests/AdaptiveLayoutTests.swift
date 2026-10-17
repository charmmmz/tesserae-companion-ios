import CoreGraphics
import Testing
@testable import Tesserae_Companion

struct AdaptiveLayoutTests {
    @Test(arguments: [CGFloat(320), 390, 600, 820, 1024, 1366])
    func galleryDensityKeepsThumbnailsUsable(width: CGFloat) {
        for preference in 2...8 {
            let columns = galleryAdaptiveColumnCount(preferred: preference, availableWidth: width)
            let cell = (width - CGFloat(columns - 1) * 2) / CGFloat(columns)
            #expect(cell >= 44)
            #expect(cell <= 180)
        }
    }

    @Test func galleryRestoresPreferredDensityAfterResize() {
        #expect(galleryAdaptiveColumnCount(preferred: 3, availableWidth: 390) == 3)
        #expect(galleryAdaptiveColumnCount(preferred: 3, availableWidth: 1024) > 3)
        #expect(galleryAdaptiveColumnCount(preferred: 3, availableWidth: 390) == 3)
    }
}
