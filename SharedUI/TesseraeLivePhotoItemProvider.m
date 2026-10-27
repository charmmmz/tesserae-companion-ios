#import "TesseraeLivePhotoItemProvider.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

void TesseraeLoadLivePhotoItem(NSItemProvider *provider,
                             void (^completion)(PHLivePhoto * _Nullable, NSError * _Nullable)) {
    // Keep the concrete block signature intact for NSItemProvider's documented
    // class coercion. Modern picker providers use loadObjectOfClass in Swift;
    // this fallback handles the legacy type Photos sends to share extensions.
    [provider loadItemForTypeIdentifier:UTTypeLivePhoto.identifier
                               options:nil
                     completionHandler:(NSItemProviderCompletionHandler)^(PHLivePhoto *photo, NSError *error) {
        completion(photo, error);
    }];
}
