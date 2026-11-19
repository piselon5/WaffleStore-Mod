#import "AppleNativeInstaller.h"
#import <UIKit/UIKit.h>
#include <dlfcn.h>

@interface WaffleSKUIItemOffer : NSObject
- (instancetype)initWithLookupDictionary:(NSDictionary *)dictionary;
@end

@interface WaffleSKUIItem : NSObject
- (instancetype)initWithLookupDictionary:(NSDictionary *)dictionary;
@end

@interface WaffleSKUIClientContext : NSObject
+ (instancetype)defaultContext;
@end

@interface WaffleSKUIItemStateCenter : NSObject
+ (instancetype)defaultCenter;
- (id)_newPurchasesWithItems:(NSArray *)items;
- (void)_performPurchases:(id)purchases
        hasBundlePurchase:(BOOL)flag
        withClientContext:(id)context
          completionBlock:(void (^)(id _Nullable result))block;
@end

@interface WaffleASDPurchaseManager : NSObject
+ (instancetype)sharedManager;
- (void)processPurchase:(id)purchase withResponseHandler:(void (^)(id _Nullable response, NSError * _Nullable error))handler;
@end

static UIViewController * _Nullable waffleTopViewController(void) {
    UIWindow *keyWindow = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]] &&
            scene.activationState == UISceneActivationStateForegroundActive) {
            UIWindowScene *ws = (UIWindowScene *)scene;
            for (UIWindow *w in ws.windows) {
                if (w.isKeyWindow) { keyWindow = w; break; }
            }
            if (!keyWindow) keyWindow = ws.windows.firstObject;
            if (keyWindow) break;
        }
    }
    UIViewController *vc = keyWindow.rootViewController;
    while (vc.presentedViewController) {
        vc = vc.presentedViewController;
    }
    return vc;
}

void WafflePresentAlert(NSString *title, NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *vc = waffleTopViewController();
        if (!vc) return;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [vc presentViewController:alert animated:YES completion:nil];
    });
}

static NSError * _Nullable waffleExtractErrorFromResult(id _Nullable result) {
    if (!result) return nil;
    if ([result isKindOfClass:[NSError class]]) {
        return (NSError *)result;
    }
    if ([result respondsToSelector:@selector(error)]) {
        id errObj = [result performSelector:@selector(error)];
        if ([errObj isKindOfClass:[NSError class]]) {
            return (NSError *)errObj;
        }
    }
    return nil;
}

void WaffleInstallViaAppleStore(NSString *adamId,
                                NSString * _Nullable externalVersionId,
                                void (^completion)(BOOL ok, NSString * _Nullable errorMessage)) {
    NSString *cleanAdam = [adamId stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *cleanExt = [externalVersionId stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    if (cleanAdam.length == 0) {
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, @"Missing Apple App ID (adamId).");
            });
        }
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        dlopen("/System/Library/PrivateFrameworks/StoreKitUI.framework/StoreKitUI", RTLD_NOW);

        Class offerCls = NSClassFromString(@"SKUIItemOffer");
        Class itemCls = NSClassFromString(@"SKUIItem");
        Class ctxCls = NSClassFromString(@"SKUIClientContext");
        Class centerCls = NSClassFromString(@"SKUIItemStateCenter");

        long long extNum = cleanExt ? [cleanExt longLongValue] : 0;
        NSString *offerString = nil;
        if (extNum > 0) {
            offerString = [NSString stringWithFormat:
                @"productType=C&price=0&salableAdamId=%@&pricingParameters=pricingParameter&appExtVrsId=%@&clientBuyId=1&installed=0&trolled=1",
                cleanAdam, cleanExt];
        } else {
            offerString = [NSString stringWithFormat:
                @"productType=C&price=0&salableAdamId=%@&pricingParameters=pricingParameter&clientBuyId=1&installed=0&trolled=1",
                cleanAdam];
        }

        if (offerCls && itemCls && ctxCls && centerCls) {
            @try {
                id offer = [(WaffleSKUIItemOffer *)[offerCls alloc] initWithLookupDictionary:@{@"buyParams": offerString}];
                id item = [(WaffleSKUIItem *)[itemCls alloc] initWithLookupDictionary:@{@"_itemOffer": cleanAdam}];

                [item setValue:offer forKey:@"_itemOffer"];
                [item setValue:@"iosSoftware" forKey:@"_itemKindString"];
                if (extNum > 0) {
                    [item setValue:@(extNum) forKey:@"_versionIdentifier"];
                }

                id center = [centerCls performSelector:@selector(defaultCenter)];
                id ctx = [ctxCls performSelector:@selector(defaultContext)];

                if (center && ctx &&
                    [center respondsToSelector:@selector(_newPurchasesWithItems:)] &&
                    [center respondsToSelector:@selector(_performPurchases:hasBundlePurchase:withClientContext:completionBlock:)]) {
                    id purchases = [(WaffleSKUIItemStateCenter *)center _newPurchasesWithItems:@[item]];
                    [(WaffleSKUIItemStateCenter *)center _performPurchases:purchases
                                                         hasBundlePurchase:NO
                                                         withClientContext:ctx
                                                           completionBlock:^(id _Nullable result) {
                        NSError *err = waffleExtractErrorFromResult(result);
                        if (completion) {
                            dispatch_async(dispatch_get_main_queue(), ^{
                                if (err) {
                                    completion(NO, err.localizedDescription);
                                } else {
                                    completion(YES, nil);
                                }
                            });
                        }
                    }];
                    return;
                }
            } @catch (NSException *ex) {
                if (completion) {
                    completion(NO, ex.reason ?: @"StoreKitUI exception");
                }
                return;
            }
        }

        // Fallback: AppStoreDaemon ASDPurchaseManager
        dlopen("/System/Library/PrivateFrameworks/AppStoreDaemon.framework/AppStoreDaemon", RTLD_NOW);
        Class purchaseCls = NSClassFromString(@"ASDPurchase");
        Class mgrCls = NSClassFromString(@"ASDPurchaseManager");
        if (purchaseCls && mgrCls) {
            @try {
                id p = [[purchaseCls alloc] init];
                [p setValue:@([cleanAdam longLongValue]) forKey:@"itemID"];
                [p setValue:offerString forKey:@"buyParameters"];
                if (extNum > 0) {
                    [p setValue:@(extNum) forKey:@"softwareVersionExternalIdentifier"];
                }
                @try { [p setValue:@YES forKey:@"isRedownload"]; } @catch (NSException *e) {}

                id mgr = [mgrCls performSelector:@selector(sharedManager)];
                if (mgr && [mgr respondsToSelector:@selector(processPurchase:withResponseHandler:)]) {
                    [(WaffleASDPurchaseManager *)mgr processPurchase:p withResponseHandler:^(id _Nullable response, NSError * _Nullable error) {
                        if (completion) {
                            dispatch_async(dispatch_get_main_queue(), ^{
                                if (error) {
                                    completion(NO, error.localizedDescription);
                                } else {
                                    completion(YES, nil);
                                }
                            });
                        }
                    }];
                    return;
                }
            } @catch (NSException *ex) {
                if (completion) {
                    completion(NO, ex.reason ?: @"AppStoreDaemon exception");
                }
                return;
            }
        }

        if (completion) {
            completion(NO, @"StoreKitUI/AppStoreDaemon unavailable. Ensure WaffleStore is installed via TrollStore (.tipa) with com.apple.itunesstored.private entitlement.");
        }
    });
}
