#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

void WafflePresentAlert(NSString *title, NSString * _Nullable message);

void WaffleInstallViaAppleStore(NSString *adamId,
                                NSString * _Nullable bundleId,
                                NSString * _Nullable externalVersionId,
                                void (^ _Nullable logHandler)(NSString *line),
                                void (^completion)(BOOL ok, NSString * _Nullable errorMessage));

NS_ASSUME_NONNULL_END
