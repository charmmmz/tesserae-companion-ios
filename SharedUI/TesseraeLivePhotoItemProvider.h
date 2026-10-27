#import <Foundation/Foundation.h>
#import <Photos/Photos.h>

NS_ASSUME_NONNULL_BEGIN

/// Photos' legacy Live Photo item requires a completion block whose Objective-C
/// signature names PHLivePhoto. A generic Swift NSSecureCoding block loses that
/// coercion hint, even though the provider advertises com.apple.live-photo.
FOUNDATION_EXPORT void TesseraeLoadLivePhotoItem(
    NSItemProvider *provider,
    void (NS_SWIFT_SENDABLE ^completion)(PHLivePhoto * _Nullable photo, NSError * _Nullable error));

NS_ASSUME_NONNULL_END
