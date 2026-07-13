#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <math.h>

// iOS 16.6 / 抖音极速版 39.5.0 / v4：SKU / 加购分支 + 专享价动作 + 可读延迟设置
// 不依赖 Substrate、ElleKit、FLEX 或 Logos，可作为 bare dylib 注入。

static UIButton *gLooperButton = nil;
static NSMutableSet<NSString *> *gProcessed = nil;
static NSMutableDictionary<NSString *, NSNumber *> *gFailures = nil;
static NSInteger gProcessedCount = 0;
static NSInteger gSkippedCount = 0;
static NSInteger gRunToken = 0;
static NSInteger gNoProgressCount = 0;
static BOOL gWaitingForPageData = NO;
static BOOL gRunning = NO;
static BOOL gPaused = NO;
static BOOL gCompleted = NO;
static NSString *gCurrentKey = nil;
static NSIndexPath *gCurrentIndexPath = nil;
static CFTimeInterval gOpenStartedAt = 0;
static BOOL gCurrentUsedAddCart = NO; // 没有“共N款”时，改走底部“加购”分支。

// 可在悬浮按钮上双击修改，并持久保存。随机抖动采用“基础延迟 + 0~抖动上限”。
static NSTimeInterval gInitialSettleSeconds = 2.5;
static NSTimeInterval gDetailStaySeconds = 2.0;
static NSTimeInterval gReturnSettleSeconds = 0.8;
static NSTimeInterval gPageLoadBaseSeconds = 3.5;
static NSTimeInterval gPageLoadMaxSeconds = 18.0;
static NSTimeInterval gGlobalJitterSeconds = 1.2;
static NSTimeInterval gOpenTimeoutSeconds = 12.0;
static NSTimeInterval gBackTimeoutSeconds = 10.0;
static NSTimeInterval gSKUOpenTimeoutSeconds = 8.0;
static NSTimeInterval gSKUStaySeconds = 1.2;
static NSTimeInterval gAfterSKUCloseSeconds = 0.8;
static NSTimeInterval gAfterExclusiveSeconds = 1.0;

static NSString * const kPrefInitialSettle = @"DLP.InitialSettle";
static NSString * const kPrefDetailStay = @"DLP.DetailStay";
static NSString * const kPrefReturnSettle = @"DLP.ReturnSettle";
static NSString * const kPrefPageLoadBase = @"DLP.PageLoadBase";
static NSString * const kPrefPageLoadMax = @"DLP.PageLoadMax";
static NSString * const kPrefGlobalJitter = @"DLP.GlobalJitter";
static NSString * const kPrefSKUStay = @"DLP.SKUStay";
static NSString * const kPrefAfterExclusive = @"DLP.AfterExclusive";

static NSTimeInterval LooperClamp(NSTimeInterval value, NSTimeInterval minimum, NSTimeInterval maximum) {
    return MIN(MAX(value, minimum), maximum);
}

static NSTimeInterval LooperJitteredDelay(NSTimeInterval base) {
    uint32_t raw = arc4random_uniform(10001);
    NSTimeInterval randomPart = ((NSTimeInterval)raw / 10000.0) * MAX(0.0, gGlobalJitterSeconds);
    return MAX(0.05, base + randomPart);
}

static void LooperLoadPreferences(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults objectForKey:kPrefInitialSettle]) gInitialSettleSeconds = LooperClamp([defaults doubleForKey:kPrefInitialSettle], 0.5, 15.0);
    if ([defaults objectForKey:kPrefDetailStay]) gDetailStaySeconds = LooperClamp([defaults doubleForKey:kPrefDetailStay], 0.5, 30.0);
    if ([defaults objectForKey:kPrefReturnSettle]) gReturnSettleSeconds = LooperClamp([defaults doubleForKey:kPrefReturnSettle], 0.3, 10.0);
    if ([defaults objectForKey:kPrefPageLoadBase]) gPageLoadBaseSeconds = LooperClamp([defaults doubleForKey:kPrefPageLoadBase], 1.0, 30.0);
    if ([defaults objectForKey:kPrefPageLoadMax]) gPageLoadMaxSeconds = LooperClamp([defaults doubleForKey:kPrefPageLoadMax], 5.0, 60.0);
    if ([defaults objectForKey:kPrefGlobalJitter]) gGlobalJitterSeconds = LooperClamp([defaults doubleForKey:kPrefGlobalJitter], 0.0, 10.0);
    if ([defaults objectForKey:kPrefSKUStay]) gSKUStaySeconds = LooperClamp([defaults doubleForKey:kPrefSKUStay], 0.3, 15.0);
    if ([defaults objectForKey:kPrefAfterExclusive]) gAfterExclusiveSeconds = LooperClamp([defaults doubleForKey:kPrefAfterExclusive], 0.3, 15.0);
    gPageLoadMaxSeconds = MAX(gPageLoadMaxSeconds, gPageLoadBaseSeconds + 2.0);
}

static void LooperSavePreferences(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setDouble:gInitialSettleSeconds forKey:kPrefInitialSettle];
    [defaults setDouble:gDetailStaySeconds forKey:kPrefDetailStay];
    [defaults setDouble:gReturnSettleSeconds forKey:kPrefReturnSettle];
    [defaults setDouble:gPageLoadBaseSeconds forKey:kPrefPageLoadBase];
    [defaults setDouble:gPageLoadMaxSeconds forKey:kPrefPageLoadMax];
    [defaults setDouble:gGlobalJitterSeconds forKey:kPrefGlobalJitter];
    [defaults setDouble:gSKUStaySeconds forKey:kPrefSKUStay];
    [defaults setDouble:gAfterExclusiveSeconds forKey:kPrefAfterExclusive];
    [defaults synchronize];
}

#pragma mark - Window / controller

static UIWindow *LooperKeyWindow(void) {
    UIApplication *app = UIApplication.sharedApplication;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (scene.activationState != UISceneActivationStateForegroundActive) continue;
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            for (UIWindow *window in windowScene.windows) {
                if (window.isKeyWindow) return window;
            }
            for (UIWindow *window in windowScene.windows) {
                if (!window.hidden && window.alpha > 0.01) return window;
            }
        }
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    for (UIWindow *window in app.windows) {
        if (window.isKeyWindow) return window;
    }
    return app.windows.firstObject;
#pragma clang diagnostic pop
}

static UIViewController *LooperTopController(UIViewController *root) {
    if (!root) return nil;
    UIViewController *presented = root.presentedViewController;
    if (presented && !presented.isBeingDismissed) {
        return LooperTopController(presented);
    }
    if ([root isKindOfClass:UINavigationController.class]) {
        return LooperTopController(((UINavigationController *)root).visibleViewController);
    }
    if ([root isKindOfClass:UITabBarController.class]) {
        return LooperTopController(((UITabBarController *)root).selectedViewController);
    }
    for (UIViewController *child in [root.childViewControllers reverseObjectEnumerator]) {
        if (child.viewIfLoaded.window) return LooperTopController(child);
    }
    return root;
}

static BOOL LooperIsDetailPage(void) {
    UIWindow *window = LooperKeyWindow();
    UIViewController *top = LooperTopController(window.rootViewController);
    NSString *name = top ? NSStringFromClass(top.class) : @"";
    return [name isEqualToString:@"IESECGoodsDetailPageViewController"] ||
           [name containsString:@"GoodsDetailPageViewController"];
}

static BOOL LooperIsSKUPage(void) {
    UIWindow *window = LooperKeyWindow();
    UIViewController *top = LooperTopController(window.rootViewController);
    NSString *name = top ? NSStringFromClass(top.class) : @"";
    return [name isEqualToString:@"IESECPdpSKUViewController"] ||
           [name containsString:@"PdpSKUViewController"];
}

#pragma mark - View traversal

static void LooperCollectSubviews(UIView *view, NSMutableArray<UIView *> *out) {
    if (!view) return;
    [out addObject:view];
    for (UIView *subview in view.subviews) {
        if (subview == gLooperButton) continue;
        LooperCollectSubviews(subview, out);
    }
}

static BOOL LooperHasAncestorClass(UIView *view, NSString *className) {
    UIView *current = view.superview;
    while (current) {
        if ([NSStringFromClass(current.class) isEqualToString:className]) return YES;
        current = current.superview;
    }
    return NO;
}

static UICollectionView *LooperFindProductCollection(void) {
    UIWindow *window = LooperKeyWindow();
    if (!window) return nil;

    NSMutableArray<UIView *> *views = [NSMutableArray array];
    LooperCollectSubviews(window, views);

    UICollectionView *best = nil;
    NSInteger bestScore = NSIntegerMin;

    for (UIView *view in views) {
        if (![view isKindOfClass:UICollectionView.class]) continue;
        UICollectionView *cv = (UICollectionView *)view;
        if (cv.hidden || cv.alpha < 0.05 || cv.bounds.size.width < 300 || cv.bounds.size.height < 350) continue;

        NSInteger score = 0;
        if (LooperHasAncestorClass(cv, @"IESECShopGoodsBackgroundView")) score += 100;
        if (cv.contentSize.height > cv.bounds.size.height + 100) score += 10;

        for (UICollectionViewCell *cell in cv.visibleCells) {
            NSString *cellName = NSStringFromClass(cell.class);
            if ([cellName isEqualToString:@"IESECShopProductsSLICell"]) score += 40;
            if ([cellName isEqualToString:@"IESECShopGoodsListFooterCell"]) score += 20;
        }

        if (score > bestScore) {
            bestScore = score;
            best = cv;
        }
    }

    return bestScore >= 40 ? best : nil;
}

static NSString *LooperVisibleText(UIView *view) {
    if (!view || view.hidden || view.alpha < 0.05) return @"";
    if ([view isKindOfClass:UILabel.class]) return ((UILabel *)view).text ?: @"";
    if ([view isKindOfClass:UIButton.class]) return [((UIButton *)view) titleForState:UIControlStateNormal] ?: @"";
    return view.accessibilityLabel ?: @"";
}

static BOOL LooperViewTreeContainsText(UIView *view, NSString *target) {
    if (!view || view.hidden || view.alpha < 0.05) return NO;
    NSString *text = LooperVisibleText(view);
    if ([text isEqualToString:target]) return YES;
    for (UIView *subview in view.subviews) {
        if (subview == gLooperButton) continue;
        if (LooperViewTreeContainsText(subview, target)) return YES;
    }
    return NO;
}


static NSString *LooperNormalizedText(NSString *text) {
    if (!text.length) return @"";
    NSCharacterSet *spaces = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    NSArray<NSString *> *parts = [text componentsSeparatedByCharactersInSet:spaces];
    return [parts componentsJoinedByString:@""];
}

static BOOL LooperLooksLikeSKUCount(NSString *text) {
    NSString *normalized = LooperNormalizedText(text);
    if (normalized.length < 3 || normalized.length > 12) return NO;
    return [normalized hasPrefix:@"共"] && [normalized hasSuffix:@"款"];
}

static CGRect LooperFrameInWindow(UIView *view, UIWindow *window) {
    if (!view || !window) return CGRectNull;
    return [view convertRect:view.bounds toView:window];
}

static BOOL LooperInvokeGestureRecognizer(UIGestureRecognizer *recognizer) {
    if (!recognizer || !recognizer.enabled) return NO;
    Ivar targetsIvar = class_getInstanceVariable(recognizer.class, "_targets");
    if (!targetsIvar) return NO;
    id rawTargets = object_getIvar(recognizer, targetsIvar);
    if (![rawTargets isKindOfClass:NSArray.class]) return NO;

    BOOL invoked = NO;
    for (id targetAction in (NSArray *)rawTargets) {
        Ivar targetIvar = class_getInstanceVariable([targetAction class], "_target");
        Ivar actionIvar = class_getInstanceVariable([targetAction class], "_action");
        if (!targetIvar || !actionIvar) continue;
        id target = object_getIvar(targetAction, targetIvar);
        ptrdiff_t actionOffset = ivar_getOffset(actionIvar);
        uint8_t *bytes = (uint8_t *)(__bridge void *)targetAction;
        SEL action = *(SEL *)(bytes + actionOffset);
        if (!target || !action || ![target respondsToSelector:action]) continue;

        NSMethodSignature *signature = [target methodSignatureForSelector:action];
        if (signature.numberOfArguments <= 2) {
            typedef void (*ActionNoArg)(id, SEL);
            ((ActionNoArg)objc_msgSend)(target, action);
            invoked = YES;
        } else {
            typedef void (*ActionWithSender)(id, SEL, id);
            ((ActionWithSender)objc_msgSend)(target, action, recognizer);
            invoked = YES;
        }
    }
    return invoked;
}

static BOOL LooperActivateSingleView(UIView *view) {
    if (!view || view.hidden || view.alpha < 0.05 || !view.userInteractionEnabled) return NO;
    if ([view isKindOfClass:UIControl.class]) {
        UIControl *control = (UIControl *)view;
        if (control.enabled) {
            [control sendActionsForControlEvents:UIControlEventTouchUpInside];
            return YES;
        }
    }

    for (UIGestureRecognizer *recognizer in view.gestureRecognizers) {
        if (LooperInvokeGestureRecognizer(recognizer)) return YES;
    }

    if (view.isAccessibilityElement && [view accessibilityActivate]) return YES;
    return NO;
}

static BOOL LooperActivateViewAndAncestors(UIView *view, NSInteger maxDepth) {
    UIView *current = view;
    for (NSInteger depth = 0; current && depth <= maxDepth; depth++, current = current.superview) {
        if (LooperActivateSingleView(current)) return YES;
    }
    return NO;
}

static BOOL LooperTapSKUCountEntry(void) {
    UIWindow *window = LooperKeyWindow();
    if (!window) return NO;
    NSMutableArray<UIView *> *views = [NSMutableArray array];
    LooperCollectSubviews(window, views);

    UIView *best = nil;
    CGFloat bestArea = 0.0;
    for (UIView *view in views) {
        if (view.hidden || view.alpha < 0.05) continue;
        NSString *text = LooperVisibleText(view);
        if (!LooperLooksLikeSKUCount(text)) continue;
        CGRect rect = LooperFrameInWindow(view, window);
        if (CGRectIsNull(rect) || CGRectIsEmpty(rect)) continue;
        if (CGRectGetMinX(rect) < window.bounds.size.width * 0.45) continue;
        if (CGRectGetMidY(rect) > window.bounds.size.height * 0.60) continue;

        UIView *candidate = view;
        for (NSInteger i = 0; i < 5 && candidate.superview; i++) {
            CGRect parentRect = LooperFrameInWindow(candidate.superview, window);
            if (parentRect.size.width >= 45.0 && parentRect.size.width <= 180.0 &&
                parentRect.size.height >= 20.0 && parentRect.size.height <= 90.0 &&
                CGRectGetMinX(parentRect) >= window.bounds.size.width * 0.45 &&
                CGRectGetMidY(parentRect) <= window.bounds.size.height * 0.60) {
                candidate = candidate.superview;
            } else {
                break;
            }
        }
        CGRect candidateRect = LooperFrameInWindow(candidate, window);
        CGFloat area = candidateRect.size.width * candidateRect.size.height;
        if (area > bestArea) {
            bestArea = area;
            best = candidate;
        }
    }
    return best ? LooperActivateViewAndAncestors(best, 5) : NO;
}


static BOOL LooperTapAddCartEntry(void) {
    UIWindow *window = LooperKeyWindow();
    if (!window) return NO;

    NSMutableArray<UIView *> *views = [NSMutableArray array];
    LooperCollectSubviews(window, views);

    // 第一优先：部分页面会直接暴露“加购 / 加入购物车 / 添加购物车”标签。
    UIView *bestTextView = nil;
    CGFloat bestTextArea = CGFLOAT_MAX;
    for (UIView *view in views) {
        if (view.hidden || view.alpha < 0.05) continue;
        NSString *text = LooperNormalizedText(LooperVisibleText(view));
        BOOL matched = [text isEqualToString:@"加购"] ||
                       [text isEqualToString:@"加入购物车"] ||
                       [text isEqualToString:@"添加购物车"];
        if (!matched) continue;

        UIView *candidate = view;
        for (NSInteger i = 0; i < 7 && candidate; i++, candidate = candidate.superview) {
            CGRect rect = LooperFrameInWindow(candidate, window);
            if (CGRectIsNull(rect) || CGRectIsEmpty(rect)) continue;
            if (CGRectGetMidY(rect) < window.bounds.size.height * 0.78) continue;
            if (rect.size.width < 45.0 || rect.size.width > 190.0) continue;
            if (rect.size.height < 28.0 || rect.size.height > 90.0) continue;
            CGFloat area = rect.size.width * rect.size.height;
            if (area < bestTextArea) {
                bestTextArea = area;
                bestTextView = candidate;
            }
        }
    }
    if (bestTextView && LooperActivateViewAndAncestors(bestTextView, 6)) return YES;

    // 第二优先：无文字标签的详情页，底部结构稳定为：
    // 左侧店铺/客服 90pt + 右侧动作区；动作区第一个约 90x44 的块就是“加购”。
    UIView *bottomContainer = nil;
    for (UIView *view in views) {
        if ([NSStringFromClass(view.class) isEqualToString:@"IESECGoodsDetailContainerBottomContainer"] &&
            !view.hidden && view.alpha >= 0.05) {
            bottomContainer = view;
            break;
        }
    }
    if (!bottomContainer) return NO;

    NSMutableArray<UIView *> *bottomViews = [NSMutableArray array];
    LooperCollectSubviews(bottomContainer, bottomViews);

    UIView *best = nil;
    CGFloat bestScore = CGFLOAT_MAX;
    CGFloat screenW = window.bounds.size.width;
    CGFloat screenH = window.bounds.size.height;
    CGPoint target = CGPointMake(screenW * 0.38, screenH * 0.93);

    for (UIView *view in bottomViews) {
        if (view == bottomContainer || view.hidden || view.alpha < 0.05) continue;
        if (![NSStringFromClass(view.class) isEqualToString:@"IESECSliceXViewElementView"]) continue;

        CGRect rect = LooperFrameInWindow(view, window);
        if (CGRectIsNull(rect) || CGRectIsEmpty(rect)) continue;
        if (rect.size.width < 72.0 || rect.size.width > 112.0) continue;
        if (rect.size.height < 36.0 || rect.size.height > 60.0) continue;
        if (CGRectGetMinX(rect) < screenW * 0.20 || CGRectGetMaxX(rect) > screenW * 0.58) continue;
        if (CGRectGetMidY(rect) < screenH * 0.86) continue;

        CGFloat dx = CGRectGetMidX(rect) - target.x;
        CGFloat dy = CGRectGetMidY(rect) - target.y;
        CGFloat sizePenalty = fabs(rect.size.width - 90.0) * 1.8 + fabs(rect.size.height - 44.0) * 2.0;
        CGFloat score = fabs(dx) + fabs(dy) * 1.5 + sizePenalty;
        if (score < bestScore) {
            bestScore = score;
            best = view;
        }
    }

    return best ? LooperActivateViewAndAncestors(best, 6) : NO;
}

static BOOL LooperTapExclusivePrice(void) {
    UIWindow *window = LooperKeyWindow();
    if (!window) return NO;
    NSMutableArray<UIView *> *views = [NSMutableArray array];
    LooperCollectSubviews(window, views);

    UIView *best = nil;
    CGFloat bestArea = CGFLOAT_MAX;
    for (UIView *view in views) {
        if (view.hidden || view.alpha < 0.05) continue;
        NSString *text = LooperNormalizedText(LooperVisibleText(view));
        if (![text isEqualToString:@"专享价"] && ![text containsString:@"抖音商城App专享"]) continue;

        UIView *candidate = view;
        for (NSInteger i = 0; i < 8 && candidate; i++, candidate = candidate.superview) {
            if (!candidate || candidate.hidden || candidate.alpha < 0.05) continue;
            if (!LooperViewTreeContainsText(candidate, @"专享价") ||
                !LooperViewTreeContainsText(candidate, @"抖音商城App专享")) continue;
            CGRect rect = LooperFrameInWindow(candidate, window);
            if (CGRectIsNull(rect) || CGRectIsEmpty(rect)) continue;
            if (rect.size.width < 80.0 || rect.size.width > 190.0) continue;
            if (rect.size.height < 32.0 || rect.size.height > 90.0) continue;
            if (CGRectGetMidY(rect) < window.bounds.size.height * 0.65) continue;
            CGFloat area = rect.size.width * rect.size.height;
            if (area < bestArea) {
                bestArea = area;
                best = candidate;
            }
        }
    }
    return best ? LooperActivateViewAndAncestors(best, 6) : NO;
}

static BOOL LooperTapSKUCloseButton(void) {
    UIWindow *window = LooperKeyWindow();
    if (!window) return NO;
    NSMutableArray<UIView *> *views = [NSMutableArray array];
    LooperCollectSubviews(window, views);

    UIView *best = nil;
    CGFloat bestY = CGFLOAT_MAX;
    for (UIView *view in views) {
        if (view.hidden || view.alpha < 0.05) continue;
        if (![NSStringFromClass(view.class) isEqualToString:@"IESECSliceXImageElementView"]) continue;
        CGRect rect = LooperFrameInWindow(view, window);
        if (CGRectIsNull(rect) || CGRectIsEmpty(rect)) continue;
        if (rect.size.width < 20.0 || rect.size.width > 34.0 ||
            rect.size.height < 20.0 || rect.size.height > 34.0) continue;
        if (CGRectGetMinX(rect) < window.bounds.size.width - 62.0) continue;
        if (CGRectGetMidY(rect) < window.bounds.size.height * 0.10 ||
            CGRectGetMidY(rect) > window.bounds.size.height * 0.35) continue;
        if (CGRectGetMidY(rect) < bestY) {
            bestY = CGRectGetMidY(rect);
            best = view;
        }
    }
    return best ? LooperActivateViewAndAncestors(best, 5) : NO;
}

static BOOL LooperFooterVisible(UICollectionView *cv) {
    if (!cv) return NO;
    for (UICollectionViewCell *cell in cv.visibleCells) {
        if ([NSStringFromClass(cell.class) isEqualToString:@"IESECShopGoodsListFooterCell"]) {
            CGRect rect = [cell convertRect:cell.bounds toView:cv];
            if (CGRectIntersectsRect(cv.bounds, rect) && !cell.hidden && cell.alpha > 0.05) return YES;
        }
    }
    return LooperViewTreeContainsText(cv, @"商品已全部展示");
}

static NSArray<NSIndexPath *> *LooperVisibleProductIndexPaths(UICollectionView *cv) {
    if (!cv) return @[];
    NSMutableArray<NSIndexPath *> *paths = [NSMutableArray array];
    for (UICollectionViewCell *cell in cv.visibleCells) {
        if (![NSStringFromClass(cell.class) isEqualToString:@"IESECShopProductsSLICell"]) continue;
        if (cell.hidden || cell.alpha < 0.05) continue;
        CGRect rect = [cell convertRect:cell.bounds toView:cv];
        if (!CGRectIntersectsRect(cv.bounds, rect)) continue;
        NSIndexPath *indexPath = [cv indexPathForCell:cell];
        if (indexPath) [paths addObject:indexPath];
    }
    [paths sortUsingComparator:^NSComparisonResult(NSIndexPath *a, NSIndexPath *b) {
        UICollectionViewLayoutAttributes *aa = [cv layoutAttributesForItemAtIndexPath:a];
        UICollectionViewLayoutAttributes *bb = [cv layoutAttributesForItemAtIndexPath:b];
        CGFloat ay = aa ? CGRectGetMinY(aa.frame) : (CGFloat)a.item;
        CGFloat by = bb ? CGRectGetMinY(bb.frame) : (CGFloat)b.item;
        if (ay < by) return NSOrderedAscending;
        if (ay > by) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    return paths;
}

static NSString *LooperKeyForIndexPath(NSIndexPath *indexPath) {
    return [NSString stringWithFormat:@"%ld-%ld", (long)indexPath.section, (long)indexPath.item];
}

#pragma mark - Button / status

static void LooperUpdateButton(NSString *title) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gLooperButton) return;
        [gLooperButton setTitle:title forState:UIControlStateNormal];
        UIWindow *window = LooperKeyWindow();
        if (window) [window bringSubviewToFront:gLooperButton];
    });
}

static void LooperRefreshButton(void) {
    if (gPaused) {
        LooperUpdateButton([NSString stringWithFormat:@"继续 %ld", (long)gProcessedCount]);
    } else if (gRunning) {
        LooperUpdateButton([NSString stringWithFormat:@"暂停 %ld", (long)gProcessedCount]);
    } else if (gCompleted) {
        LooperUpdateButton([NSString stringWithFormat:@"完成 %ld", (long)gProcessedCount]);
    } else {
        LooperUpdateButton(@"开始");
    }
}

static void LooperShowMessage(NSString *title, NSString *message) {
    UIWindow *window = LooperKeyWindow();
    UIViewController *top = LooperTopController(window.rootViewController);
    if (!top || [top isKindOfClass:UIAlertController.class]) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [top presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Scheduling

static void LooperProcessNext(NSInteger token);
static void LooperComplete(void);
static void LooperWaitForPageData(NSInteger token, CFTimeInterval startedAt, CGFloat previousHeight, NSInteger previousMaxItem);

static void LooperAfter(NSTimeInterval delay, NSInteger token, dispatch_block_t block) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (token != gRunToken) return;
        block();
    });
}

#pragma mark - Enter / back

static BOOL LooperOpenProduct(UICollectionView *cv, NSIndexPath *indexPath) {
    if (!cv || !indexPath) return NO;
    UICollectionViewCell *cell = [cv cellForItemAtIndexPath:indexPath];
    if (!cell || ![NSStringFromClass(cell.class) isEqualToString:@"IESECShopProductsSLICell"]) return NO;

    [cv selectItemAtIndexPath:indexPath animated:NO scrollPosition:UICollectionViewScrollPositionNone];
    id<UICollectionViewDelegate> delegate = cv.delegate;
    SEL selector = @selector(collectionView:didSelectItemAtIndexPath:);
    if (delegate && [delegate respondsToSelector:selector]) {
        typedef void (*SelectIMP)(id, SEL, UICollectionView *, NSIndexPath *);
        ((SelectIMP)objc_msgSend)(delegate, selector, cv, indexPath);
        return YES;
    }

    // 备用：商品 Cell 内如果存在 UIControl，则触发其点击事件。
    NSMutableArray<UIView *> *views = [NSMutableArray array];
    LooperCollectSubviews(cell, views);
    for (UIView *view in views) {
        if (![view isKindOfClass:UIControl.class]) continue;
        UIControl *control = (UIControl *)view;
        if (!control.enabled || control.hidden || control.alpha < 0.05) continue;
        [control sendActionsForControlEvents:UIControlEventTouchUpInside];
        return YES;
    }
    return NO;
}

static UINavigationController *LooperNavigationControllerFor(UIViewController *vc) {
    UIViewController *current = vc;
    while (current) {
        if (current.navigationController) return current.navigationController;
        if ([current isKindOfClass:UINavigationController.class]) return (UINavigationController *)current;
        current = current.parentViewController;
    }
    return nil;
}

static BOOL LooperGoBack(void) {
    UIWindow *window = LooperKeyWindow();
    UIViewController *top = LooperTopController(window.rootViewController);
    if (!top) return NO;

    UINavigationController *nav = LooperNavigationControllerFor(top);
    if (nav && nav.viewControllers.count > 1) {
        [nav popViewControllerAnimated:YES];
        return YES;
    }
    if (top.presentingViewController) {
        [top dismissViewControllerAnimated:YES completion:nil];
        return YES;
    }

    // 备用：寻找真正的“返回”UIControl。
    NSMutableArray<UIView *> *views = [NSMutableArray array];
    LooperCollectSubviews(window, views);
    for (UIView *view in views) {
        if (![view isKindOfClass:UIControl.class]) continue;
        if (![[LooperVisibleText(view) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] isEqualToString:@"返回"]) continue;
        UIControl *control = (UIControl *)view;
        [control sendActionsForControlEvents:UIControlEventTouchUpInside];
        return YES;
    }
    return NO;
}

static void LooperProcessNext(NSInteger token);
static void LooperProceedToExclusive(NSInteger token);

static void LooperWaitForList(NSInteger token, CFTimeInterval startedAt, CFTimeInterval lastBackAt, NSInteger backAttempts) {
    if (token != gRunToken || !gRunning || gPaused) return;
    UICollectionView *list = LooperFindProductCollection();
    if (!LooperIsDetailPage() && !LooperIsSKUPage() && list) {
        gCurrentKey = nil;
        gCurrentIndexPath = nil;
        LooperAfter(LooperJitteredDelay(gReturnSettleSeconds), token, ^{ LooperProcessNext(token); });
        return;
    }

    CFTimeInterval now = CACurrentMediaTime();
    if (now - startedAt > gBackTimeoutSeconds) {
        gPaused = YES;
        gRunning = NO;
        LooperRefreshButton();
        LooperShowMessage(@"已暂停", @"连续返回后仍未回到商品列表，请手动返回列表后点“继续”。");
        return;
    }

    if (now - lastBackAt > 1.4 && backAttempts < 5) {
        if (LooperIsSKUPage()) {
            if (!LooperTapSKUCloseButton()) (void)LooperGoBack();
        } else {
            (void)LooperGoBack();
        }
        lastBackAt = now;
        backAttempts += 1;
    }
    LooperAfter(0.25, token, ^{
        LooperWaitForList(token, startedAt, lastBackAt, backAttempts);
    });
}

static void LooperBeginReturnToList(NSInteger token) {
    if (token != gRunToken || !gRunning || gPaused) return;
    UICollectionView *list = LooperFindProductCollection();
    if (!LooperIsDetailPage() && !LooperIsSKUPage() && list) {
        LooperAfter(LooperJitteredDelay(gReturnSettleSeconds), token, ^{ LooperProcessNext(token); });
        return;
    }

    CFTimeInterval now = CACurrentMediaTime();
    if (LooperIsSKUPage()) {
        if (!LooperTapSKUCloseButton()) (void)LooperGoBack();
    } else {
        (void)LooperGoBack();
    }
    LooperWaitForList(token, now, now, 1);
}

static void LooperWaitForDetailAfterSKUClose(NSInteger token, CFTimeInterval startedAt, NSInteger closeAttempts) {
    if (token != gRunToken || !gRunning || gPaused) return;
    if (LooperIsDetailPage()) {
        LooperAfter(LooperJitteredDelay(gAfterSKUCloseSeconds), token, ^{
            if (gCurrentUsedAddCart) LooperBeginReturnToList(token);
            else LooperProceedToExclusive(token);
        });
        return;
    }
    UICollectionView *list = LooperFindProductCollection();
    if (!LooperIsSKUPage() && list) {
        LooperAfter(LooperJitteredDelay(gReturnSettleSeconds), token, ^{ LooperProcessNext(token); });
        return;
    }

    CFTimeInterval elapsed = CACurrentMediaTime() - startedAt;
    if (LooperIsSKUPage() && elapsed > 1.2 * (closeAttempts + 1) && closeAttempts < 3) {
        BOOL closed = LooperTapSKUCloseButton();
        if (!closed) (void)LooperGoBack();
        LooperAfter(0.35, token, ^{
            LooperWaitForDetailAfterSKUClose(token, startedAt, closeAttempts + 1);
        });
        return;
    }
    if (elapsed > gSKUOpenTimeoutSeconds) {
        if (gCurrentUsedAddCart) LooperBeginReturnToList(token);
        else LooperProceedToExclusive(token);
        return;
    }
    LooperAfter(0.25, token, ^{
        LooperWaitForDetailAfterSKUClose(token, startedAt, closeAttempts);
    });
}

static void LooperCloseSKUAndContinue(NSInteger token) {
    if (token != gRunToken || !gRunning || gPaused) return;
    if (!LooperIsSKUPage()) {
        if (gCurrentUsedAddCart) LooperBeginReturnToList(token);
        else LooperProceedToExclusive(token);
        return;
    }

    BOOL closed = LooperTapSKUCloseButton();
    if (!closed) (void)LooperGoBack();
    LooperWaitForDetailAfterSKUClose(token, CACurrentMediaTime(), 1);
}

static void LooperWaitForSKU(NSInteger token, CFTimeInterval startedAt, NSInteger openAttempt) {
    if (token != gRunToken || !gRunning || gPaused) return;
    if (LooperIsSKUPage()) {
        LooperAfter(LooperJitteredDelay(gSKUStaySeconds), token, ^{ LooperCloseSKUAndContinue(token); });
        return;
    }
    UICollectionView *list = LooperFindProductCollection();
    if (!LooperIsDetailPage() && list) {
        LooperAfter(LooperJitteredDelay(gReturnSettleSeconds), token, ^{ LooperProcessNext(token); });
        return;
    }

    if (CACurrentMediaTime() - startedAt > gSKUOpenTimeoutSeconds) {
        BOOL retried = NO;
        if (openAttempt < 2 && LooperIsDetailPage()) {
            retried = gCurrentUsedAddCart ? LooperTapAddCartEntry() : LooperTapSKUCountEntry();
        }
        if (retried) {
            LooperAfter(0.35, token, ^{
                LooperWaitForSKU(token, CACurrentMediaTime(), openAttempt + 1);
            });
        } else {
            if (gCurrentUsedAddCart) LooperBeginReturnToList(token);
            else LooperProceedToExclusive(token);
        }
        return;
    }
    LooperAfter(0.25, token, ^{ LooperWaitForSKU(token, startedAt, openAttempt); });
}

static void LooperTrySKUThenExclusive(NSInteger token) {
    if (token != gRunToken || !gRunning || gPaused) return;
    if (!LooperIsDetailPage()) {
        if (LooperIsSKUPage()) {
            LooperAfter(LooperJitteredDelay(gSKUStaySeconds), token, ^{ LooperCloseSKUAndContinue(token); });
        } else {
            LooperBeginReturnToList(token);
        }
        return;
    }

    // 有“共N款”：打开 SKU → 关闭 → 点击专享价 → 返回。
    gCurrentUsedAddCart = NO;
    if (LooperTapSKUCountEntry()) {
        LooperWaitForSKU(token, CACurrentMediaTime(), 1);
        return;
    }

    // 没有“共N款”：只点击底部“加购”，SKU 弹层出现后关闭并直接返回。
    gCurrentUsedAddCart = YES;
    if (LooperTapAddCartEntry()) {
        LooperWaitForSKU(token, CACurrentMediaTime(), 1);
    } else {
        // 找不到加购入口时不误点专享价，直接安全返回。
        LooperBeginReturnToList(token);
    }
}

static void LooperProceedToExclusive(NSInteger token) {
    if (token != gRunToken || !gRunning || gPaused) return;
    if (LooperIsSKUPage()) {
        LooperCloseSKUAndContinue(token);
        return;
    }
    if (!LooperIsDetailPage()) {
        LooperBeginReturnToList(token);
        return;
    }

    (void)LooperTapExclusivePrice();
    LooperAfter(LooperJitteredDelay(gAfterExclusiveSeconds), token, ^{ LooperBeginReturnToList(token); });
}

static void LooperWaitForDetail(NSInteger token) {
    if (token != gRunToken || !gRunning || gPaused) return;
    if (LooperIsDetailPage()) {
        if (gCurrentKey.length) {
            [gProcessed addObject:gCurrentKey];
            gProcessedCount += 1;
            gNoProgressCount = 0;
            LooperRefreshButton();
        }
        LooperAfter(LooperJitteredDelay(gDetailStaySeconds), token, ^{ LooperTrySKUThenExclusive(token); });
        return;
    }

    if (CACurrentMediaTime() - gOpenStartedAt > gOpenTimeoutSeconds) {
        NSInteger failures = [gFailures[gCurrentKey] integerValue] + 1;
        gFailures[gCurrentKey] = @(failures);
        if (failures >= 2 && gCurrentKey.length) {
            [gProcessed addObject:gCurrentKey];
            gSkippedCount += 1;
        }
        gCurrentKey = nil;
        gCurrentIndexPath = nil;
        LooperAfter(0.5, token, ^{ LooperProcessNext(token); });
        return;
    }
    LooperAfter(0.25, token, ^{ LooperWaitForDetail(token); });
}

#pragma mark - List processing

static BOOL LooperScrollDown(UICollectionView *cv) {
    if (!cv) return NO;
    UIEdgeInsets inset;
    if (@available(iOS 11.0, *)) inset = cv.adjustedContentInset;
    else inset = cv.contentInset;

    CGFloat minY = -inset.top;
    CGFloat maxY = MAX(minY, cv.contentSize.height - cv.bounds.size.height + inset.bottom);
    CGFloat currentY = cv.contentOffset.y;
    CGFloat nextY = MIN(maxY, currentY + cv.bounds.size.height * 0.72);
    if (nextY <= currentY + 2.0) return NO;
    [cv setContentOffset:CGPointMake(cv.contentOffset.x, nextY) animated:YES];
    return YES;
}

static NSInteger LooperMaxVisibleProductItem(UICollectionView *cv) {
    NSInteger maximum = -1;
    for (NSIndexPath *indexPath in LooperVisibleProductIndexPaths(cv)) {
        maximum = MAX(maximum, indexPath.item);
    }
    return maximum;
}

static BOOL LooperHasUnprocessedVisibleProduct(UICollectionView *cv) {
    for (NSIndexPath *indexPath in LooperVisibleProductIndexPaths(cv)) {
        if (![gProcessed containsObject:LooperKeyForIndexPath(indexPath)]) return YES;
    }
    return NO;
}

static BOOL LooperLoadingIndicatorVisible(UICollectionView *cv) {
    if (!cv) return NO;
    if (LooperViewTreeContainsText(cv, @"正在加载") ||
        LooperViewTreeContainsText(cv, @"加载中") ||
        LooperViewTreeContainsText(cv, @"加载中.")) return YES;

    NSMutableArray<UIView *> *views = [NSMutableArray array];
    LooperCollectSubviews(cv, views);
    for (UIView *view in views) {
        if (view.hidden || view.alpha < 0.05) continue;
        NSString *name = NSStringFromClass(view.class);
        if ([name isEqualToString:@"IESECActionLoadingView"] ||
            [name isEqualToString:@"AWEUILoadingView"]) return YES;
    }
    return NO;
}

static void LooperPauseForPageTimeout(void) {
    gWaitingForPageData = NO;
    gPaused = YES;
    gRunning = NO;
    LooperRefreshButton();
    NSString *message = [NSString stringWithFormat:
        @"等待下一批商品超过 %.0f 秒，已暂停以避免误判结束。等商品加载出来后点“继续”。\n\n双击悬浮按钮可调整：翻页基础等待、最长等待和随机抖动。",
        gPageLoadMaxSeconds];
    LooperShowMessage(@"列表加载较慢", message);
}

static void LooperWaitForPageData(NSInteger token, CFTimeInterval startedAt, CGFloat previousHeight, NSInteger previousMaxItem) {
    if (token != gRunToken || !gRunning || gPaused) return;
    gWaitingForPageData = YES;

    UICollectionView *cv = LooperFindProductCollection();
    if (!cv) {
        if (CACurrentMediaTime() - startedAt >= gPageLoadMaxSeconds) {
            LooperPauseForPageTimeout();
            return;
        }
        LooperAfter(0.45, token, ^{
            LooperWaitForPageData(token, startedAt, previousHeight, previousMaxItem);
        });
        return;
    }

    if (LooperHasUnprocessedVisibleProduct(cv)) {
        gWaitingForPageData = NO;
        gNoProgressCount = 0;
        LooperAfter(LooperJitteredDelay(0.35), token, ^{ LooperProcessNext(token); });
        return;
    }

    if (LooperFooterVisible(cv)) {
        gWaitingForPageData = NO;
        LooperComplete();
        return;
    }

    CGFloat currentHeight = cv.contentSize.height;
    NSInteger currentMaxItem = LooperMaxVisibleProductItem(cv);
    BOOL dataChanged = currentHeight > previousHeight + 8.0 || currentMaxItem > previousMaxItem;
    if (dataChanged) {
        gWaitingForPageData = NO;
        gNoProgressCount = 0;
        LooperAfter(LooperJitteredDelay(0.55), token, ^{ LooperProcessNext(token); });
        return;
    }

    CFTimeInterval elapsed = CACurrentMediaTime() - startedAt;
    if (elapsed >= gPageLoadMaxSeconds) {
        LooperPauseForPageTimeout();
        return;
    }

    // 加载动画存在时持续等待；没有动画也继续等到最长时间，避免慢网误判。
    (void)LooperLoadingIndicatorVisible(cv);
    LooperAfter(0.45, token, ^{
        LooperWaitForPageData(token, startedAt, previousHeight, previousMaxItem);
    });
}

static void LooperComplete(void) {
    gRunning = NO;
    gPaused = NO;
    gCompleted = YES;
    gRunToken += 1;
    LooperRefreshButton();
    NSString *message = [NSString stringWithFormat:@"已处理 %ld 个商品%@。",
                         (long)gProcessedCount,
                         gSkippedCount > 0 ? [NSString stringWithFormat:@"，另跳过 %ld 个打开失败的商品", (long)gSkippedCount] : @""];
    LooperShowMessage(@"商品遍历完成", message);
}

static void LooperProcessNext(NSInteger token) {
    if (token != gRunToken || !gRunning || gPaused) return;

    if (LooperIsSKUPage() || LooperIsDetailPage()) {
        LooperBeginReturnToList(token);
        return;
    }

    UICollectionView *cv = LooperFindProductCollection();
    if (!cv) {
        gNoProgressCount += 1;
        if (gNoProgressCount >= 20) {
            gPaused = YES;
            gRunning = NO;
            LooperRefreshButton();
            LooperShowMessage(@"已暂停", @"当前没有识别到店铺“全部商品”列表，请进入该页面后点“继续”。");
            return;
        }
        LooperAfter(0.4, token, ^{ LooperProcessNext(token); });
        return;
    }

    NSArray<NSIndexPath *> *visible = LooperVisibleProductIndexPaths(cv);
    for (NSIndexPath *indexPath in visible) {
        NSString *key = LooperKeyForIndexPath(indexPath);
        if ([gProcessed containsObject:key]) continue;

        gCurrentKey = key;
        gCurrentIndexPath = indexPath;
        gCurrentUsedAddCart = NO;
        gOpenStartedAt = CACurrentMediaTime();
        BOOL opened = LooperOpenProduct(cv, indexPath);
        if (!opened) {
            NSInteger failures = [gFailures[key] integerValue] + 1;
            gFailures[key] = @(failures);
            if (failures >= 2) {
                [gProcessed addObject:key];
                gSkippedCount += 1;
            }
            gCurrentKey = nil;
            gCurrentIndexPath = nil;
            LooperAfter(0.45, token, ^{ LooperProcessNext(token); });
        } else {
            LooperWaitForDetail(token);
        }
        return;
    }

    if (LooperFooterVisible(cv)) {
        LooperComplete();
        return;
    }

    CGFloat previousHeight = cv.contentSize.height;
    NSInteger previousMaxItem = LooperMaxVisibleProductItem(cv);
    (void)LooperScrollDown(cv);
    gNoProgressCount = 0;
    gWaitingForPageData = YES;

    // 翻页后先按“基础等待 + 随机抖动”等待，再持续轮询到最长等待时间。
    LooperAfter(LooperJitteredDelay(gPageLoadBaseSeconds), token, ^{
        LooperWaitForPageData(token, CACurrentMediaTime(), previousHeight, previousMaxItem);
    });
}

static void LooperResetListToTop(NSInteger token, NSInteger attempt) {
    if (token != gRunToken || !gRunning || gPaused) return;
    UICollectionView *cv = LooperFindProductCollection();
    if (!cv) {
        if (attempt < 20) {
            LooperAfter(0.35, token, ^{ LooperResetListToTop(token, attempt + 1); });
        } else {
            gPaused = YES;
            gRunning = NO;
            LooperRefreshButton();
            LooperShowMessage(@"未找到商品列表", @"请先进入店铺的“全部商品”第一页，再点“继续”。");
        }
        return;
    }

    UIEdgeInsets inset;
    if (@available(iOS 11.0, *)) inset = cv.adjustedContentInset;
    else inset = cv.contentInset;
    [cv setContentOffset:CGPointMake(cv.contentOffset.x, -inset.top) animated:NO];

    // 首次进入店铺时页面可能会自动恢复旧滚动位置，所以再归顶一次。
    LooperAfter(LooperJitteredDelay(0.8), token, ^{
        UICollectionView *again = LooperFindProductCollection();
        if (again) {
            UIEdgeInsets againInset;
            if (@available(iOS 11.0, *)) againInset = again.adjustedContentInset;
            else againInset = again.contentInset;
            [again setContentOffset:CGPointMake(again.contentOffset.x, -againInset.top) animated:NO];
        }
        LooperAfter(LooperJitteredDelay(gReturnSettleSeconds), token, ^{ LooperProcessNext(token); });
    });
}

#pragma mark - Controls

static void LooperStart(void) {
    gRunToken += 1;
    NSInteger token = gRunToken;
    gProcessed = [NSMutableSet set];
    gFailures = [NSMutableDictionary dictionary];
    gProcessedCount = 0;
    gSkippedCount = 0;
    gNoProgressCount = 0;
    gCurrentKey = nil;
    gCurrentIndexPath = nil;
    gCurrentUsedAddCart = NO;
    gWaitingForPageData = NO;
    gRunning = YES;
    gPaused = NO;
    gCompleted = NO;
    LooperUpdateButton(@"准备");

    LooperAfter(LooperJitteredDelay(gInitialSettleSeconds), token, ^{ LooperResetListToTop(token, 1); });
}

static void LooperPause(void) {
    gRunToken += 1;
    gRunning = NO;
    gPaused = YES;
    LooperRefreshButton();
}

static void LooperResume(void) {
    gRunToken += 1;
    NSInteger token = gRunToken;
    gRunning = YES;
    gPaused = NO;
    gCompleted = NO;
    LooperRefreshButton();

    if (LooperIsSKUPage() || LooperIsDetailPage()) {
        LooperBeginReturnToList(token);
    } else {
        LooperAfter(0.25, token, ^{ LooperProcessNext(token); });
    }
}

static void LooperStopAndReset(void) {
    gRunToken += 1;
    gRunning = NO;
    gPaused = NO;
    gCompleted = NO;
    gCurrentKey = nil;
    gCurrentIndexPath = nil;
    gCurrentUsedAddCart = NO;
    gWaitingForPageData = NO;
    if (LooperIsSKUPage()) {
        if (!LooperTapSKUCloseButton()) (void)LooperGoBack();
    } else if (LooperIsDetailPage()) {
        (void)LooperGoBack();
    }
    LooperRefreshButton();
}

@interface ProductLooperTarget : NSObject
+ (void)buttonTapped;
+ (void)buttonDoubleTapped;
+ (void)buttonLongPressed:(UILongPressGestureRecognizer *)gesture;
+ (void)buttonPanned:(UIPanGestureRecognizer *)gesture;
@end

@implementation ProductLooperTarget
+ (void)buttonTapped {
    if (gRunning) LooperPause();
    else if (gPaused) LooperResume();
    else LooperStart();
}

+ (void)buttonDoubleTapped {
    if (gRunning) {
        LooperShowMessage(@"请先暂停", @"运行中先单击“暂停”，再双击按钮调整延迟。设置保存后会立即用于后续动作。");
        return;
    }

    UIWindow *window = LooperKeyWindow();
    UIViewController *top = LooperTopController(window.rootViewController);
    if (!top || [top isKindOfClass:UIAlertController.class]) return;

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"遍历延迟设置"
                                                                   message:@"有共N款：SKU→关闭→专享价→返回；无共N款：加购→关闭SKU→返回。每个输入框左侧已标明对应功能。随机抖动会额外增加 0～上限秒。"
                                                            preferredStyle:UIAlertControllerStyleAlert];

    NSArray<NSString *> *fieldLabels = @[
        @"详情动作前",
        @"SKU/加购弹层",
        @"专享价点击后",
        @"翻页基础",
        @"翻页最长",
        @"返回列表后",
        @"随机抖动"
    ];
    NSArray<NSNumber *> *values = @[
        @(gDetailStaySeconds),
        @(gSKUStaySeconds),
        @(gAfterExclusiveSeconds),
        @(gPageLoadBaseSeconds),
        @(gPageLoadMaxSeconds),
        @(gReturnSettleSeconds),
        @(gGlobalJitterSeconds)
    ];

    for (NSInteger i = 0; i < fieldLabels.count; i++) {
        [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
            textField.keyboardType = UIKeyboardTypeDecimalPad;
            textField.text = [NSString stringWithFormat:@"%.1f", values[i].doubleValue];
            textField.clearButtonMode = UITextFieldViewModeWhileEditing;
            textField.textAlignment = NSTextAlignmentRight;

            UILabel *prefix = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 112.0, 32.0)];
            prefix.text = [NSString stringWithFormat:@"  %@：", fieldLabels[i]];
            prefix.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightMedium];
            prefix.textColor = UIColor.secondaryLabelColor;
            prefix.adjustsFontSizeToFitWidth = YES;
            prefix.minimumScaleFactor = 0.75;
            textField.leftView = prefix;
            textField.leftViewMode = UITextFieldViewModeAlways;
        }];
    }

    [alert addAction:[UIAlertAction actionWithTitle:@"恢复默认" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        gDetailStaySeconds = 2.0;
        gSKUStaySeconds = 1.2;
        gAfterExclusiveSeconds = 1.0;
        gPageLoadBaseSeconds = 3.5;
        gPageLoadMaxSeconds = 18.0;
        gReturnSettleSeconds = 0.8;
        gGlobalJitterSeconds = 1.2;
        LooperSavePreferences();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            LooperShowMessage(@"已恢复默认", @"详情动作前 2.0 秒；SKU/加购弹层 1.2 秒；专享价点击后 1.0 秒；翻页基础 3.5 秒；翻页最长 18 秒；返回列表后 0.8 秒；随机抖动 0～1.2 秒。");
        });
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        NSArray<UITextField *> *fields = alert.textFields;
        gDetailStaySeconds = LooperClamp(fields[0].text.doubleValue, 0.5, 30.0);
        gSKUStaySeconds = LooperClamp(fields[1].text.doubleValue, 0.3, 15.0);
        gAfterExclusiveSeconds = LooperClamp(fields[2].text.doubleValue, 0.3, 15.0);
        gPageLoadBaseSeconds = LooperClamp(fields[3].text.doubleValue, 1.0, 30.0);
        gPageLoadMaxSeconds = LooperClamp(fields[4].text.doubleValue, 5.0, 60.0);
        gReturnSettleSeconds = LooperClamp(fields[5].text.doubleValue, 0.3, 10.0);
        gGlobalJitterSeconds = LooperClamp(fields[6].text.doubleValue, 0.0, 10.0);
        gPageLoadMaxSeconds = MAX(gPageLoadMaxSeconds, gPageLoadBaseSeconds + 2.0);
        LooperSavePreferences();
        NSString *message = [NSString stringWithFormat:
            @"详情动作前 %.1f 秒；SKU/加购弹层 %.1f 秒；专享价点击后 %.1f 秒；翻页基础 %.1f 秒；翻页最长 %.1f 秒；返回列表后 %.1f 秒；随机增加 0～%.1f 秒。",
            gDetailStaySeconds, gSKUStaySeconds, gAfterExclusiveSeconds, gPageLoadBaseSeconds, gPageLoadMaxSeconds, gReturnSettleSeconds, gGlobalJitterSeconds];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            LooperShowMessage(@"设置已保存", message);
        });
    }]];

    [top presentViewController:alert animated:YES completion:nil];
}

+ (void)buttonLongPressed:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    LooperStopAndReset();
    LooperShowMessage(@"已停止", @"任务已停止并重置。重新进入商品第一页后点“开始”即可再次运行。");
}

+ (void)buttonPanned:(UIPanGestureRecognizer *)gesture {
    UIView *button = gesture.view;
    UIView *container = button.superview;
    if (!button || !container) return;
    CGPoint translation = [gesture translationInView:container];
    CGPoint center = CGPointMake(button.center.x + translation.x, button.center.y + translation.y);
    CGFloat halfW = button.bounds.size.width / 2.0;
    CGFloat halfH = button.bounds.size.height / 2.0;
    center.x = MIN(MAX(center.x, halfW + 4.0), container.bounds.size.width - halfW - 4.0);
    center.y = MIN(MAX(center.y, halfH + 30.0), container.bounds.size.height - halfH - 30.0);
    button.center = center;
    [gesture setTranslation:CGPointZero inView:container];
}
@end

static void LooperInstallButton(void) {
    if (gLooperButton.superview) return;
    UIWindow *window = LooperKeyWindow();
    if (!window) return;

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.frame = CGRectMake(8, 205, 72, 38);
    button.layer.cornerRadius = 12.0;
    button.layer.borderWidth = 1.0;
    button.layer.borderColor = UIColor.whiteColor.CGColor;
    button.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.84];
    [button setTitle:@"开始" forState:UIControlStateNormal];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont boldSystemFontOfSize:13.0];
    button.accessibilityIdentifier = @"DouyinLiteProductLooperButton";

    UITapGestureRecognizer *singleTap = [[UITapGestureRecognizer alloc] initWithTarget:ProductLooperTarget.class action:@selector(buttonTapped)];
    singleTap.numberOfTapsRequired = 1;
    UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc] initWithTarget:ProductLooperTarget.class action:@selector(buttonDoubleTapped)];
    doubleTap.numberOfTapsRequired = 2;
    [singleTap requireGestureRecognizerToFail:doubleTap];
    [button addGestureRecognizer:singleTap];
    [button addGestureRecognizer:doubleTap];

    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:ProductLooperTarget.class action:@selector(buttonLongPressed:)];
    longPress.minimumPressDuration = 0.8;
    [button addGestureRecognizer:longPress];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:ProductLooperTarget.class action:@selector(buttonPanned:)];
    [button addGestureRecognizer:pan];

    gLooperButton = button;
    [window addSubview:button];
    [window bringSubviewToFront:button];
}

static void LooperInstallButtonWithRetry(NSInteger attempt) {
    LooperInstallButton();
    if (!gLooperButton.superview && attempt < 30) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            LooperInstallButtonWithRetry(attempt + 1);
        });
    }
}

__attribute__((constructor))
static void ProductLooperInit(void) {
    LooperLoadPreferences();
    dispatch_async(dispatch_get_main_queue(), ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            LooperInstallButtonWithRetry(1);
        });
    });
}
