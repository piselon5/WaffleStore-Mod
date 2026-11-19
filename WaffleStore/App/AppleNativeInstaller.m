#import "AppleNativeInstaller.h"
#import <objc/message.h>
#include <dlfcn.h>

static NSError * _Nullable waffleExtractErrorFromResult(id _Nullable result) {
    if (!result) return nil;
    if ([result isKindOfClass:[NSError class]]) {
        return (NSError *)result;
    }
    SEL errSel = NSSelectorFromString(@"error");
    if ([result respondsToSelector:errSel]) {
        id errObj = ((id (*)(id, SEL))objc_msgSend)(result, errSel);
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
                SEL initLookupSel = NSSelectorFromString(@"initWithLookupDictionary:");
                id offerAlloc = [offerCls alloc];
                id offer = ((id (*)(id, SEL, NSDictionary *))objc_msgSend)(offerAlloc, initLookupSel, @{@"buyParams": offerString});

                id itemAlloc = [itemCls alloc];
                id item = ((id (*)(id, SEL, NSDictionary *))objc_msgSend)(itemAlloc, initLookupSel, @{@"_itemOffer": cleanAdam});

                [item setValue:offer forKey:@"_itemOffer"];
                [item setValue:@"iosSoftware" forKey:@"_itemKindString"];
                if (extNum > 0) {
                    [item setValue:@(extNum) forKey:@"_versionIdentifier"];
                }

                SEL defaultCenterSel = NSSelectorFromString(@"defaultCenter");
                SEL defaultCtxSel = NSSelectorFromString(@"defaultContext");
                SEL newPurchasesSel = NSSelectorFromString(@"_newPurchasesWithItems:");
                SEL performSel = NSSelectorFromString(@"_performPurchases:hasBundlePurchase:withClientContext:completionBlock:");

                id center = ((id (*)(id, SEL))objc_msgSend)(centerCls, defaultCenterSel);
                id ctx = ((id (*)(id, SEL))objc_msgSend)(ctxCls, defaultCtxSel);

                if (center && ctx &&
                    [center respondsToSelector:newPurchasesSel] &&
                    [center respondsToSelector:performSel]) {
                    id purchases = ((id (*)(id, SEL, NSArray *))objc_msgSend)(center, newPurchasesSel, @[item]);
                    void (^cb)(id) = ^(id result) {
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
                    };
                    ((void (*)(id, SEL, id, BOOL, id, id))objc_msgSend)(center, performSel, purchases, NO, ctx, cb);
                    return;
                }
            } @catch (NSException *ex) {
                if (completion) {
                    completion(NO, ex.reason ?: @"StoreKitUI exception");
                }
                return;
            }
        }

        // Fallback: AppStoreDaemon ASDPurchaseManager (used only if StoreKitUI is unavailable)
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

                SEL sharedSel = NSSelectorFromString(@"sharedManager");
                SEL procSel = NSSelectorFromString(@"processPurchase:withResponseHandler:");
                id mgr = ((id (*)(id, SEL))objc_msgSend)(mgrCls, sharedSel);
                if (mgr && [mgr respondsToSelector:procSel]) {
                    void (^resp)(id, NSError *) = ^(id response, NSError *error) {
                        if (completion) {
                            dispatch_async(dispatch_get_main_queue(), ^{
                                if (error) {
                                    completion(NO, error.localizedDescription);
                                } else {
                                    completion(YES, nil);
                                }
                            });
                        }
                    };
                    ((void (*)(id, SEL, id, id))objc_msgSend)(mgr, procSel, p, resp);
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
