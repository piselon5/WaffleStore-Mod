#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

void WaffleInstallViaAppleStore(NSString *adamId,
                                NSString * _Nullable externalVersionId,
                                void (^completion)(BOOL ok, NSString * _Nullable errorMessage));

NS_ASSUME_NONNULL_END
