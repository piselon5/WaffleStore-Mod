#import "AppleNativeInstaller.h"
#import <UIKit/UIKit.h>
#import <objc/message.h>
#include <dlfcn.h>

@interface WaffleASDPurchase : NSObject
@property (copy) NSString *bundleID;
@property (copy) NSNumber *itemID;
@property (copy) NSString *buyParameters;
@property (copy) NSString *clientID;
@property (assign) long long purchaseID;
@property (assign) BOOL isRedownload;
@property (assign) BOOL createsJobs;
@end

@interface WaffleASDPurchaseResult : NSObject
@property (readonly) BOOL success;
@property (readonly) NSError *error;
@property (readonly) NSNumber *itemID;
@end

@interface WaffleASDServiceBroker : NSObject
+ (id)defaultBroker;
- (id)getPurchaseServiceWithError:(NSError * _Nullable * _Nullable)error;
@end

@interface WaffleASDPurchaseServiceProxy : NSObject
- (void)startPurchase:(id)purchase withReplyHandler:(void (^)(WaffleASDPurchaseResult * _Nullable r, NSError * _Nullable e))handler;
@end

@interface WaffleASDPurchaseManager : NSObject
+ (instancetype)sharedManager;
- (void)startPurchase:(id)purchase withResultHandler:(void (^)(WaffleASDPurchaseResult * _Nullable r, NSError * _Nullable e))handler;
- (void)processPurchase:(id)purchase withResponseHandler:(void (^)(id _Nullable response, NSError * _Nullable error))handler;
@end

@interface WaffleASDNotificationCenter : NSObject
+ (instancetype)defaultCenter;
- (void)setDialogObserver:(nullable id)observer;
- (void)addProgressObserver:(id)observer;
- (void)removeProgressObserver:(id)observer;
@end

@interface WaffleASDProgress : NSObject
@property (readonly) NSString *bundleID;
@property (readonly) long long completedUnitCount;
@property (readonly) long long totalUnitCount;
@property (readonly) long long downloadCompletedUnitCount;
@property (readonly) long long downloadTotalUnitCount;
@property (readonly) long long installCompletedUnitCount;
@property (readonly) long long installTotalUnitCount;
@property (readonly) long long phase;
@property (readonly) double throughput;
@end

@interface WaffleAMSDialogAction : NSObject
@property (readonly) NSString *identifier;
@property (readonly) NSString *title;
@end

@interface WaffleAMSDialogRequest : NSObject
@property (readonly) NSString *identifier;
@property (readonly) NSString *title;
@property (readonly) NSString *message;
@property (readonly) WaffleAMSDialogAction *defaultAction;
@property (readonly) NSArray *buttonActions;
@end

@interface WaffleAMSDialogResult : NSObject
- (instancetype)initWithOriginalRequest:(id)request selectedActionIdentifier:(nullable id)identifier;
@property (copy) NSArray *textfieldValues;
@end

@interface WaffleASDPurchaseHistoryQuery : NSObject
@property (assign) long long accountID;
@property (copy) NSArray *bundleIDs;
@property (copy) NSArray *storeIDs;
@end

@interface WaffleASDPurchaseHistoryApp : NSObject
@property (readonly) NSString *bundleID;
@property (readonly) long long storeItemID;
@end

@interface WaffleASDPurchaseHistory : NSObject
+ (instancetype)sharedInstance;
- (void)updateForAccountID:(long long)accountID
               withContext:(unsigned long long)context
     withCompletionHandler:(void (^)(NSError * _Nullable error))handler;
- (void)executeQuery:(id)query
   withResultHandler:(void (^)(NSArray * _Nullable apps, NSError * _Nullable error))handler;
@end

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

void WafflePresentAlert(NSString *title, NSString * _Nullable message) {
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

@interface WaffleASDObserver : NSObject
@property (copy, nonatomic) NSString *bundleID;
@property (copy, nonatomic) void (^logBlock)(NSString *line);
@property (assign, nonatomic) BOOL sawProgress;
@property (assign, nonatomic) BOOL installComplete;
@property (assign, nonatomic) NSInteger lastLoggedPercent;
@end

@implementation WaffleASDObserver

- (void)emit:(NSString *)line {
    if (!line.length) return;
    NSLog(@"%@", line);
    void (^block)(NSString *) = self.logBlock;
    if (block) {
        dispatch_async(dispatch_get_main_queue(), ^{
            block(line);
        });
    }
}

- (void)handleDialogRequest:(id)request resultHandler:(void (^)(id _Nullable, NSError * _Nullable))handler {
    WaffleAMSDialogRequest *req = (WaffleAMSDialogRequest *)request;
    NSString *reqID = [req respondsToSelector:@selector(identifier)] ? req.identifier : nil;
    NSString *reqMsg = [req respondsToSelector:@selector(message)] ? req.message : nil;
    [self emit:[NSString stringWithFormat:@"[AppleNativeInstall] Dialog: %@ — %@",
                reqID ?: @"(no id)", reqMsg ?: @"(no message)"]];

    if (!handler) return;

    WaffleAMSDialogAction *chosen = nil;
    if ([req respondsToSelector:@selector(defaultAction)]) {
        chosen = req.defaultAction;
    }
    if (!chosen && [req respondsToSelector:@selector(buttonActions)]) {
        NSArray *actions = req.buttonActions;
        if ([actions isKindOfClass:[NSArray class]] && actions.count > 0) {
            chosen = actions.firstObject;
        }
    }

    Class resultClass = NSClassFromString(@"AMSDialogResult");
    if (!resultClass || !chosen) {
        [self emit:@"[AppleNativeInstall] Dialog declined (no AMSDialogResult/action)"];
        handler(nil, nil);
        return;
    }

    NSString *chosenID = [chosen respondsToSelector:@selector(identifier)] ? chosen.identifier : nil;
    NSString *chosenTitle = [chosen respondsToSelector:@selector(title)] ? chosen.title : nil;
    WaffleAMSDialogResult *result = [(WaffleAMSDialogResult *)[resultClass alloc] initWithOriginalRequest:request
                                                                                selectedActionIdentifier:chosenID];
    if ([result respondsToSelector:@selector(setTextfieldValues:)]) {
        result.textfieldValues = @[];
    }
    [self emit:[NSString stringWithFormat:@"[AppleNativeInstall] Dialog answered: %@ (%@)",
                chosenTitle ?: @"", chosenID ?: @""]];
    handler(result, nil);
}

- (void)handleDialogRequest:(id)request
                   purchase:(id)purchase
              purchaseQueue:(id)queue
                 completion:(void (^)(id _Nullable, NSError * _Nullable))completion {
    [self handleDialogRequest:request resultHandler:completion];
}

- (void)handleAuthenticateRequest:(id)request resultHandler:(void (^)(id _Nullable, NSError * _Nullable))handler {
    [self emit:@"[AppleNativeInstall] Store requested Apple ID authentication (sign in via iOS Settings -> App Store)"];
    if (handler) handler(nil, nil);
}

- (void)handleAuthenticateRequest:(id)request
                         purchase:(id)purchase
                    purchaseQueue:(id)queue
                       completion:(void (^)(id _Nullable, NSError * _Nullable))completion {
    [self handleAuthenticateRequest:request resultHandler:completion];
}

- (void)notificationCenter:(id)center receivedProgress:(id)payload {
    NSArray *items = [payload isKindOfClass:[NSArray class]] ? (NSArray *)payload : (payload ? @[payload] : @[]);
    for (WaffleASDProgress *p in items) {
        if (![p respondsToSelector:@selector(bundleID)]) continue;
        if (self.bundleID.length > 0 && ![p.bundleID isEqualToString:self.bundleID]) continue;

        self.sawProgress = YES;
        long long dDone = [p respondsToSelector:@selector(downloadCompletedUnitCount)] ? p.downloadCompletedUnitCount : 0;
        long long dTotal = [p respondsToSelector:@selector(downloadTotalUnitCount)] ? p.downloadTotalUnitCount : 0;
        long long iDone = [p respondsToSelector:@selector(installCompletedUnitCount)] ? p.installCompletedUnitCount : 0;
        long long iTotal = [p respondsToSelector:@selector(installTotalUnitCount)] ? p.installTotalUnitCount : 0;

        if (dTotal > 0 && dDone <= dTotal) {
            NSInteger pct = (NSInteger)((100LL * dDone) / dTotal);
            if (pct - self.lastLoggedPercent >= 15 || pct == 100 || self.lastLoggedPercent < 0) {
                self.lastLoggedPercent = pct;
                [self emit:[NSString stringWithFormat:@"[AppleNativeInstall] Downloading %@: %ld%% (%.1f / %.1f MB)",
                            p.bundleID, (long)pct, dDone / 1048576.0, dTotal / 1048576.0]];
            }
        } else if (iTotal > 0 && iDone <= iTotal) {
            NSInteger pct = (NSInteger)((100LL * iDone) / iTotal);
            if (pct == 100 && !self.installComplete) {
                self.installComplete = YES;
                [self emit:[NSString stringWithFormat:@"[AppleNativeInstall] Installing %@: 100%%", p.bundleID]];
            }
        }
    }
}

@end

static NSString * _Nullable waffleBuyParamsFromDescription(NSString *desc) {
    if (![desc isKindOfClass:[NSString class]]) return nil;
    NSRange key = [desc rangeOfString:@"buyParams = \""];
    if (key.location == NSNotFound) return nil;
    NSUInteger start = key.location + key.length;
    NSRange end = [desc rangeOfString:@"\"" options:0 range:NSMakeRange(start, desc.length - start)];
    if (end.location == NSNotFound) return nil;
    return [desc substringWithRange:NSMakeRange(start, end.location - start)];
}

static NSString * _Nullable waffleServerBuyParamsFromError(NSError * _Nullable error) {
    if (!error) return nil;
    NSDictionary *userInfo = error.userInfo;
    id payload = userInfo[@"AMSServerPayload"];
    if ([payload isKindOfClass:[NSDictionary class]]) {
        id dialog = ((NSDictionary *)payload)[@"dialog"];
        id action = [dialog isKindOfClass:[NSDictionary class]] ? ((NSDictionary *)dialog)[@"okButtonAction"] : nil;
        id params = [action isKindOfClass:[NSDictionary class]] ? ((NSDictionary *)action)[@"buyParams"] : nil;
        if ([params isKindOfClass:[NSString class]] && [(NSString *)params length] > 0) {
            return (NSString *)params;
        }
    }
    for (NSString *k in userInfo) {
        if (![k hasPrefix:@"AMSServerPayload"]) continue;
        id val = userInfo[k];
        NSString *params = waffleBuyParamsFromDescription([val isKindOfClass:[NSString class]] ? val : [val description]);
        if (params.length > 0) return params;
    }
    return nil;
}

static NSString *waffleEnsureExtIdInBuyParams(NSString *buyParams, NSString *cleanExt) {
    if (cleanExt.length == 0 || [cleanExt longLongValue] <= 0) return buyParams;
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    BOOL found = NO;
    for (NSString *kv in [buyParams componentsSeparatedByString:@"&"]) {
        if ([kv hasPrefix:@"appExtVrsId="]) {
            [parts addObject:[NSString stringWithFormat:@"appExtVrsId=%@", cleanExt]];
            found = YES;
        } else if (kv.length > 0) {
            [parts addObject:kv];
        }
    }
    if (!found) {
        [parts addObject:[NSString stringWithFormat:@"appExtVrsId=%@", cleanExt]];
    }
    return [parts componentsJoinedByString:@"&"];
}

static NSString *waffleDescribePurchaseError(NSError * _Nullable err, BOOL owned) {
    if (!err) return @"Unknown App Store daemon failure.";
    NSDictionary *payload = [err.userInfo[@"AMSServerPayload"] isKindOfClass:[NSDictionary class]]
        ? err.userInfo[@"AMSServerPayload"] : nil;
    NSString *dialogID = nil;
    NSString *custMsg = nil;
    NSString *dialogMsg = nil;
    if (payload) {
        id metrics = payload[@"metrics"];
        if ([metrics isKindOfClass:[NSDictionary class]]) {
            dialogID = metrics[@"dialogId"];
        }
        if ([payload[@"customerMessage"] isKindOfClass:[NSString class]]) {
            custMsg = payload[@"customerMessage"];
        }
        id dialog = payload[@"dialog"];
        if ([dialog isKindOfClass:[NSDictionary class]]) {
            dialogMsg = dialog[@"explanation"] ?: dialog[@"message"];
        }
    }

    if ([dialogID isEqualToString:@"MZCommerce.ProductRequiresLaterStoreVersion"]) {
        NSString *base = custMsg.length > 0 ? custMsg : @"This app requires a newer iOS version.";
        NSString *hint = owned
            ? @"Apple did not serve the selected build (ensure AppStoreTroller Exact tweak is installed and active for appstored + installd, then respring/ldrestart)."
            : @"Your device App Store Apple ID does not have a license for this app yet. Acquire the free app once on a newer iOS device (or in iTunes), then retry this Build ID.";
        return [NSString stringWithFormat:@"%@\n\n%@", base, hint];
    }

    if ([err.domain isEqualToString:@"ASDErrorDomain"] && err.code == 505) {
        return @"ASDErrorDomain 505: Missing com.apple.itunesstored.private entitlement. Install WaffleStore via TrollStore (.tipa).";
    }

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    [parts addObject:[NSString stringWithFormat:@"%@ (%ld): %@", err.domain ?: @"Error", (long)err.code, err.localizedDescription ?: @"Failed"]];
    if (custMsg.length > 0) [parts addObject:custMsg];
    if (dialogMsg.length > 0 && ![dialogMsg isEqualToString:custMsg]) [parts addObject:dialogMsg];
    if (dialogID.length > 0) [parts addObject:[NSString stringWithFormat:@"dialogId: %@", dialogID]];
    return [parts componentsJoinedByString:@"\n"];
}

static NSString * _Nullable waffleResolveBundleIdSync(NSString *adamId) {
    NSString *urlStr = [NSString stringWithFormat:@"https://itunes.apple.com/lookup?id=%@&entity=software,iPadSoftware&limit=1", adamId];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) return nil;
    __block NSString *resolved = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable resp, NSError * _Nullable err) {
        if (data.length > 0) {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSArray *results = [json isKindOfClass:[NSDictionary class]] ? json[@"results"] : nil;
            NSDictionary *first = ([results isKindOfClass:[NSArray class]] && results.count > 0) ? results.firstObject : nil;
            if ([first isKindOfClass:[NSDictionary class]] && [first[@"bundleId"] isKindOfClass:[NSString class]]) {
                resolved = first[@"bundleId"];
            }
        }
        dispatch_semaphore_signal(sem);
    }] resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10LL * NSEC_PER_SEC));
    return resolved;
}

static BOOL waffleIsBundleInstalledWithSinf(NSString *bundleID) {
    if (bundleID.length == 0) return NO;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *root = @"/var/containers/Bundle/Application";
    for (NSString *uuid in [fm contentsOfDirectoryAtPath:root error:NULL]) {
        NSString *container = [root stringByAppendingPathComponent:uuid];
        NSDictionary *md = [NSDictionary dictionaryWithContentsOfFile:[container stringByAppendingPathComponent:@"iTunesMetadata.plist"]];
        if (![md[@"softwareVersionBundleId"] isEqualToString:bundleID]) continue;
        for (NSString *entry in [fm contentsOfDirectoryAtPath:container error:NULL]) {
            if ([entry hasSuffix:@".app"]) {
                NSString *sc = [[container stringByAppendingPathComponent:entry] stringByAppendingPathComponent:@"SC_Info"];
                for (NSString *f in [fm contentsOfDirectoryAtPath:sc error:NULL]) {
                    if ([f hasSuffix:@".sinf"]) return YES;
                }
            }
        }
    }
    return NO;
}

static BOOL waffleCheckOwnedInHistorySync(NSString *adamId, NSString *bundleId, BOOL *outHasAccount, void (^emit)(NSString *)) {
    if (outHasAccount) *outHasAccount = NO;
    Class historyCls = NSClassFromString(@"ASDPurchaseHistory");
    Class queryCls = NSClassFromString(@"ASDPurchaseHistoryQuery");
    Class storeCls = NSClassFromString(@"ACAccountStore");
    if (!historyCls || !queryCls || !storeCls) return NO;

    SEL sharedSel = NSSelectorFromString(@"ams_sharedAccountStore");
    SEL activeSel = NSSelectorFromString(@"ams_activeiTunesAccount");
    SEL dsidSel = NSSelectorFromString(@"ams_DSID");
    if (![storeCls respondsToSelector:sharedSel]) return NO;

    id store = ((id (*)(id, SEL))objc_msgSend)(storeCls, sharedSel);
    if (!store || ![store respondsToSelector:activeSel]) return NO;
    id account = ((id (*)(id, SEL))objc_msgSend)(store, activeSel);
    if (!account || ![account respondsToSelector:dsidSel]) return NO;
    NSNumber *dsid = ((id (*)(id, SEL))objc_msgSend)(account, dsidSel);
    if (![dsid isKindOfClass:[NSNumber class]] || dsid.longLongValue == 0) return NO;

    if (outHasAccount) *outHasAccount = YES;
    WaffleASDPurchaseHistory *history = [historyCls sharedInstance];
    if (!history) return NO;

    dispatch_semaphore_t sem1 = dispatch_semaphore_create(0);
    [history updateForAccountID:dsid.longLongValue withContext:0 withCompletionHandler:^(NSError * _Nullable error) {
        if (error && emit) {
            emit([NSString stringWithFormat:@"[AppleNativeInstall] History refresh note: %@", error.localizedDescription]);
        }
        dispatch_semaphore_signal(sem1);
    }];
    dispatch_semaphore_wait(sem1, dispatch_time(DISPATCH_TIME_NOW, 10LL * NSEC_PER_SEC));

    WaffleASDPurchaseHistoryQuery *q = [[queryCls alloc] init];
    if ([q respondsToSelector:@selector(setAccountID:)]) {
        q.accountID = dsid.longLongValue;
    }

    __block NSArray *apps = nil;
    dispatch_semaphore_t sem2 = dispatch_semaphore_create(0);
    [history executeQuery:q withResultHandler:^(NSArray * _Nullable result, NSError * _Nullable error) {
        apps = result;
        dispatch_semaphore_signal(sem2);
    }];
    dispatch_semaphore_wait(sem2, dispatch_time(DISPATCH_TIME_NOW, 8LL * NSEC_PER_SEC));

    long long targetAdam = [adamId longLongValue];
    for (WaffleASDPurchaseHistoryApp *app in apps) {
        if ([app respondsToSelector:@selector(storeItemID)] && app.storeItemID == targetAdam && targetAdam > 0) {
            return YES;
        }
        if (bundleId.length > 0 && [app respondsToSelector:@selector(bundleID)] && [app.bundleID isEqualToString:bundleId]) {
            return YES;
        }
    }
    return NO;
}

static NSError * _Nullable waffleExtractErrorFromResult(id _Nullable result) {
    if (!result) return nil;
    if ([result isKindOfClass:[NSError class]]) return (NSError *)result;
    if ([result respondsToSelector:@selector(error)]) {
        id errObj = ((id (*)(id, SEL))objc_msgSend)(result, @selector(error));
        if ([errObj isKindOfClass:[NSError class]]) return (NSError *)errObj;
    }
    return nil;
}

void WaffleInstallViaAppleStore(NSString *adamId,
                                NSString * _Nullable bundleId,
                                NSString * _Nullable externalVersionId,
                                void (^ _Nullable logHandler)(NSString *line),
                                void (^completion)(BOOL ok, NSString * _Nullable errorMessage)) {
    NSString *cleanAdam = [adamId stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
    NSString *initialBundle = [bundleId stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
    NSString *cleanExt = [externalVersionId stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";

    void (^emit)(NSString *) = ^(NSString *line) {
        if (!line.length) return;
        NSLog(@"%@", line);
        if (logHandler) {
            dispatch_async(dispatch_get_main_queue(), ^{
                logHandler(line);
            });
        }
    };

    void (^finish)(BOOL, NSString * _Nullable) = ^(BOOL ok, NSString * _Nullable msg) {
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(ok, msg);
            });
        }
    };

    if (cleanAdam.length == 0) {
        finish(NO, @"Missing Apple App ID (adamId).");
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        dlopen("/System/Library/Frameworks/Accounts.framework/Accounts", RTLD_LAZY);
        dlopen("/System/Library/PrivateFrameworks/AppleMediaServices.framework/AppleMediaServices", RTLD_NOW);
        dlopen("/System/Library/PrivateFrameworks/AppStoreDaemon.framework/AppStoreDaemon", RTLD_NOW);

        NSString *cleanBundle = initialBundle;
        if (cleanBundle.length == 0) {
            emit([NSString stringWithFormat:@"[AppleNativeInstall] Resolving bundleID for app %@...", cleanAdam]);
            cleanBundle = waffleResolveBundleIdSync(cleanAdam) ?: @"";
        }

        long long extNum = cleanExt.length > 0 ? [cleanExt longLongValue] : 0;
        emit([NSString stringWithFormat:@"[AppleNativeInstall] Start app=%@ bundle=%@ ext=%@",
              cleanAdam, cleanBundle.length > 0 ? cleanBundle : @"(missing)", extNum > 0 ? cleanExt : @"latest"]);

        BOOL hasAccount = NO;
        BOOL owned = waffleCheckOwnedInHistorySync(cleanAdam, cleanBundle, &hasAccount, emit);
        emit([NSString stringWithFormat:@"[AppleNativeInstall] iOS App Store account=%@ owned=%@",
              hasAccount ? @"active" : @"none", owned ? @"YES" : @"NO"]);

        NSString *pricing = owned ? @"STDRDL" : @"STDQ";
        NSString *baseBuyParams = [NSString stringWithFormat:
            @"salableAdamId=%@&productType=C&price=0&pricingParameters=%@&hasBeenAuthedForBuy=true&hasConfirmedPaymentSheet=true",
            cleanAdam, pricing];
        if (extNum > 0) {
            baseBuyParams = [baseBuyParams stringByAppendingFormat:@"&appExtVrsId=%@", cleanExt];
        }

        Class purchaseCls = NSClassFromString(@"ASDPurchase");
        Class brokerCls = NSClassFromString(@"ASDServiceBroker");
        Class mgrCls = NSClassFromString(@"ASDPurchaseManager");
        Class ncCls = NSClassFromString(@"ASDNotificationCenter");

        WaffleASDObserver *obs = nil;
        id nc = nil;
        if (ncCls && [ncCls respondsToSelector:@selector(defaultCenter)]) {
            nc = [ncCls defaultCenter];
            obs = [WaffleASDObserver new];
            obs.bundleID = cleanBundle;
            obs.logBlock = logHandler;
            obs.lastLoggedPercent = -1;
            if ([nc respondsToSelector:@selector(setDialogObserver:)]) {
                [nc setDialogObserver:obs];
            }
            if ([nc respondsToSelector:@selector(addProgressObserver:)]) {
                [nc addProgressObserver:obs];
            }
        }

        if (purchaseCls && cleanBundle.length > 0 && (brokerCls || mgrCls)) {
            NSError *svcErr = nil;
            id svc = nil;
            if (brokerCls && [brokerCls respondsToSelector:@selector(defaultBroker)]) {
                id broker = [brokerCls defaultBroker];
                if ([broker respondsToSelector:@selector(getPurchaseServiceWithError:)]) {
                    svc = [broker getPurchaseServiceWithError:&svcErr];
                }
            }

            if (svc && [svc respondsToSelector:@selector(startPurchase:withReplyHandler:)]) {
                __block BOOL ok = NO;
                __block NSString *retryParams = nil;
                __block NSError *lastError = nil;

                BOOL (^runAttempt)(NSString *) = ^BOOL(NSString *params) {
                    WaffleASDPurchase *p = [[purchaseCls alloc] init];
                    p.bundleID = cleanBundle;
                    p.itemID = @([cleanAdam longLongValue]);
                    p.buyParameters = params;
                    p.isRedownload = owned;
                    p.createsJobs = YES;
                    p.clientID = @"com.apple.AppStore";
                    p.purchaseID = (long long)(arc4random_uniform(8000000) + 1000000);

                    ok = NO;
                    retryParams = nil;
                    emit([NSString stringWithFormat:@"[AppleNativeInstall] Sending ASDPurchase (purchaseID=%lld, pricing=%@, ext=%@)...",
                          p.purchaseID, pricing, extNum > 0 ? cleanExt : @"latest"]);

                    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
                    [(WaffleASDPurchaseServiceProxy *)svc startPurchase:p withReplyHandler:^(WaffleASDPurchaseResult * _Nullable r, NSError * _Nullable e) {
                        ok = r ? r.success : (e == nil);
                        if (!ok) {
                            NSError *err = (r && r.error) ? r.error : e;
                            lastError = err;
                            retryParams = waffleServerBuyParamsFromError(err);
                        }
                        dispatch_semaphore_signal(sem);
                    }];
                    return dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 120LL * NSEC_PER_SEC)) == 0;
                };

                BOOL completed = runAttempt(baseBuyParams);
                NSMutableSet *seenParams = [NSMutableSet set];
                for (int round = 1; completed && !ok && retryParams.length > 0 && round <= 4; round++) {
                    if ([seenParams containsObject:retryParams]) break;
                    [seenParams addObject:retryParams];
                    NSString *replay = waffleEnsureExtIdInBuyParams(retryParams, cleanExt);
                    emit([NSString stringWithFormat:@"[AppleNativeInstall] Replaying dialog buyParams (round %d)...", round]);
                    completed = runAttempt(replay);
                }

                if (ok) {
                    emit(@"[AppleNativeInstall] Purchase accepted by appstored! Download queued.");
                    finish(YES, nil);

                    // Keep observer alive briefly to stream download/install progress into Logs.
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 90LL * NSEC_PER_SEC),
                                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                        if (waffleIsBundleInstalledWithSinf(cleanBundle)) {
                            emit([NSString stringWithFormat:@"[AppleNativeInstall] Verified %@ installed (SC_Info/.sinf present).", cleanBundle]);
                        }
                        if (nc && obs && [nc respondsToSelector:@selector(removeProgressObserver:)]) {
                            [nc removeProgressObserver:obs];
                        }
                    });
                    return;
                }

                if (nc && obs && [nc respondsToSelector:@selector(removeProgressObserver:)]) {
                    [nc removeProgressObserver:obs];
                }

                NSString *detail = completed
                    ? waffleDescribePurchaseError(lastError, owned)
                    : @"Timed out waiting for appstored purchase reply (120s).";
                emit([NSString stringWithFormat:@"[AppleNativeInstall] Failed: %@", detail]);
                finish(NO, detail);
                return;
            } else {
                emit([NSString stringWithFormat:@"[AppleNativeInstall] ASDServiceBroker unavailable (%@); trying ASDPurchaseManager...",
                      svcErr ? svcErr.localizedDescription : @"no proxy"]);
                if (mgrCls && [mgrCls respondsToSelector:@selector(sharedManager)]) {
                    id mgr = [mgrCls sharedManager];
                    WaffleASDPurchase *p = [[purchaseCls alloc] init];
                    p.bundleID = cleanBundle;
                    p.itemID = @([cleanAdam longLongValue]);
                    p.buyParameters = baseBuyParams;
                    p.isRedownload = owned;
                    p.createsJobs = YES;
                    p.clientID = @"com.apple.AppStore";
                    p.purchaseID = (long long)(arc4random_uniform(8000000) + 1000000);

                    if ([mgr respondsToSelector:@selector(startPurchase:withResultHandler:)]) {
                        [(WaffleASDPurchaseManager *)mgr startPurchase:p withResultHandler:^(WaffleASDPurchaseResult * _Nullable r, NSError * _Nullable e) {
                            BOOL ok = r ? r.success : (e == nil);
                            NSError *err = (r && r.error) ? r.error : e;
                            if (ok) {
                                emit(@"[AppleNativeInstall] ASDPurchaseManager accepted download.");
                                finish(YES, nil);
                                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 90LL * NSEC_PER_SEC),
                                               dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                                    if (nc && obs && [nc respondsToSelector:@selector(removeProgressObserver:)]) {
                                        [nc removeProgressObserver:obs];
                                    }
                                });
                            } else {
                                if (nc && obs && [nc respondsToSelector:@selector(removeProgressObserver:)]) {
                                    [nc removeProgressObserver:obs];
                                }
                                NSString *detail = waffleDescribePurchaseError(err, owned);
                                emit([NSString stringWithFormat:@"[AppleNativeInstall] ASDPurchaseManager failed: %@", detail]);
                                finish(NO, detail);
                            }
                        }];
                        return;
                    }
                    if ([mgr respondsToSelector:@selector(processPurchase:withResponseHandler:)]) {
                        [(WaffleASDPurchaseManager *)mgr processPurchase:p withResponseHandler:^(id _Nullable response, NSError * _Nullable error) {
                            if (!error) {
                                emit(@"[AppleNativeInstall] ASDPurchaseManager processPurchase accepted.");
                                finish(YES, nil);
                                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 90LL * NSEC_PER_SEC),
                                               dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                                    if (nc && obs && [nc respondsToSelector:@selector(removeProgressObserver:)]) {
                                        [nc removeProgressObserver:obs];
                                    }
                                });
                            } else {
                                if (nc && obs && [nc respondsToSelector:@selector(removeProgressObserver:)]) {
                                    [nc removeProgressObserver:obs];
                                }
                                NSString *detail = waffleDescribePurchaseError(error, owned);
                                emit([NSString stringWithFormat:@"[AppleNativeInstall] processPurchase failed: %@", detail]);
                                finish(NO, detail);
                            }
                        }];
                        return;
                    }
                }
            }
        }

        if (nc && obs && [nc respondsToSelector:@selector(removeProgressObserver:)]) {
            [nc removeProgressObserver:obs];
        }

        // Last-resort fallback: StoreKitUI SKUIItemStateCenter (e.g. if bundleID lookup failed completely).
        dispatch_async(dispatch_get_main_queue(), ^{
            emit(@"[AppleNativeInstall] Falling back to StoreKitUI SKUIItemStateCenter...");
            dlopen("/System/Library/PrivateFrameworks/StoreKitUI.framework/StoreKitUI", RTLD_NOW);

            Class offerCls = NSClassFromString(@"SKUIItemOffer");
            Class itemCls = NSClassFromString(@"SKUIItem");
            Class ctxCls = NSClassFromString(@"SKUIClientContext");
            Class centerCls = NSClassFromString(@"SKUIItemStateCenter");

            if (offerCls && itemCls && ctxCls && centerCls) {
                @try {
                    id offer = [(WaffleSKUIItemOffer *)[offerCls alloc] initWithLookupDictionary:@{@"buyParams": baseBuyParams}];
                    id item = [(WaffleSKUIItem *)[itemCls alloc] initWithLookupDictionary:@{
                        @"itemId": @([cleanAdam longLongValue]),
                        @"bundleId": cleanBundle
                    }];
                    [item setValue:offer forKey:@"_itemOffer"];
                    [item setValue:@"iosSoftware" forKey:@"_itemKindString"];
                    if (extNum > 0) {
                        [item setValue:@(extNum) forKey:@"_versionIdentifier"];
                    }
                    id center = [centerCls defaultCenter];
                    id ctx = [ctxCls defaultContext];
                    if (center && ctx &&
                        [center respondsToSelector:@selector(_newPurchasesWithItems:)] &&
                        [center respondsToSelector:@selector(_performPurchases:hasBundlePurchase:withClientContext:completionBlock:)]) {
                        id purchases = [(WaffleSKUIItemStateCenter *)center _newPurchasesWithItems:@[item]];
                        [(WaffleSKUIItemStateCenter *)center _performPurchases:purchases
                                                             hasBundlePurchase:NO
                                                             withClientContext:ctx
                                                               completionBlock:^(id _Nullable result) {
                            NSError *err = waffleExtractErrorFromResult(result);
                            if (err) {
                                NSString *detail = waffleDescribePurchaseError(err, owned);
                                emit([NSString stringWithFormat:@"[AppleNativeInstall] SKUI failed: %@", detail]);
                                finish(NO, detail);
                            } else {
                                emit(@"[AppleNativeInstall] SKUI purchase completed.");
                                finish(YES, nil);
                            }
                        }];
                        return;
                    }
                } @catch (NSException *ex) {
                    finish(NO, ex.reason ?: @"StoreKitUI exception");
                    return;
                }
            }

            finish(NO, @"AppStoreDaemon and StoreKitUI unavailable. Ensure WaffleStore is installed via TrollStore (.tipa) with com.apple.itunesstored.private entitlement.");
        });
    });
}
