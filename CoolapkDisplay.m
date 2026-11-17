// Display-only changes for the exact CoolMarket 16.7 advertising view classes.
// Build with ARC and blocks; links only Foundation/UIKit/Objective-C runtime.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

typedef void (*CDVoidMethod)(id, SEL);
typedef void (*CDBoolSetter)(id, SEL, BOOL);
typedef BOOL (*CDBoolGetter)(id, SEL);

@interface CD167DisplayInstallerLock : NSObject
@end
@implementation CD167DisplayInstallerLock
@end

static char CDInstallResultKey;
static CDBoolSetter CDUIKitSetHidden;
static CDBoolGetter CDUIKitIsHidden;

@interface CD167CloseState : NSObject
@property(nonatomic) BOOL finished;
@property(nonatomic) BOOL executing;
@property(nonatomic, strong) NSObject *pending;
@property(nonatomic, weak) UIWindow *attachedWindow;
@property(nonatomic, strong) NSMutableSet<NSValue *> *activeOriginals;
@end
@implementation CD167CloseState
@end

static char CDCloseStateKey;
static char CDCloseInstallResultKey;

static bool CDTypeEquals(char *actual, const char *expected) {
    if (!actual) return false;
    // Method type qualifiers do not change the calling convention.
    const char *unqualified = actual;
    while (*unqualified && strchr("rnNoORV", *unqualified)) ++unqualified;
    bool equal = strcmp(unqualified, expected) == 0;
    free(actual);
    return equal;
}

static bool CDSignatureMatches(Method method, const char *returnType,
                               const char *thirdArgumentType) {
    if (!method || !method_getImplementation(method)) return false;
    unsigned int count = thirdArgumentType ? 3 : 2;
    if (method_getNumberOfArguments(method) != count) return false;
    if (!CDTypeEquals(method_copyReturnType(method), returnType)) return false;
    if (!CDTypeEquals(method_copyArgumentType(method, 0), @encode(id))) return false;
    if (!CDTypeEquals(method_copyArgumentType(method, 1), @encode(SEL))) return false;
    return !thirdArgumentType ||
        CDTypeEquals(method_copyArgumentType(method, 2), thirdArgumentType);
}

static bool CDIsProperViewSubclass(Class target) {
    if (!target || class_isMetaClass(target) || target == [UIView class]) return false;
    // Runtime inheritance, not an overridable isKindOfClass: implementation.
    for (Class cursor = class_getSuperclass(target); cursor;
         cursor = class_getSuperclass(cursor)) {
        if (cursor == [UIView class]) return true;
    }
    return false;
}

static bool CDIsProperControllerSubclass(Class target) {
    if (!target || class_isMetaClass(target) || target == [UIViewController class]) return false;
    for (Class cursor = class_getSuperclass(target); cursor;
         cursor = class_getSuperclass(cursor)) {
        if (cursor == [UIViewController class]) return true;
    }
    return false;
}

static Method CDOwnMethod(Class target, SEL selector) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(target, &count);
    Method found = NULL;
    for (unsigned int i = 0; i < count; ++i) {
        if (sel_isEqual(method_getName(methods[i]), selector)) {
            found = methods[i];
            break;
        }
    }
    free(methods);
    return found;
}

static bool CDPrepareUIKitPrimitives(void) {
    static dispatch_once_t once;
    static bool valid;
    dispatch_once(&once, ^{
        Method setter = class_getInstanceMethod([UIView class], @selector(setHidden:));
        Method getter = class_getInstanceMethod([UIView class], @selector(isHidden));
        valid = CDSignatureMatches(setter, @encode(void), @encode(BOOL)) &&
                CDSignatureMatches(getter, @encode(BOOL), NULL);
        if (valid) {
            CDUIKitSetHidden = (CDBoolSetter)method_getImplementation(setter);
            CDUIKitIsHidden = (CDBoolGetter)method_getImplementation(getter);
        }
    });
    return valid;
}

static void CDHideAdvertisementView(id view) {
    // Do not dispatch setHidden: back through our replacement, and do not call
    // an SDK visibility/data getter. Only the UIView visibility property changes.
    // These are UIView-level IMPs captured at installation; an earlier unrelated
    // plugin could already have replaced them. We do not modify UIView itself.
    // Avoid redundant UIKit mutations during an already-hidden view's layout.
    if (!CDUIKitIsHidden(view, @selector(isHidden))) {
        CDUIKitSetHidden(view, @selector(setHidden:), YES);
    }
}

static bool CDInstallViewClass(Class target) {
    // Installation and UIKit behavior are confined to the main thread.
    if (![NSThread isMainThread] || !CDIsProperViewSubclass(target)) return false;
    @synchronized ([CD167DisplayInstallerLock class]) {
        NSNumber *previousResult = objc_getAssociatedObject(target, &CDInstallResultKey);
        if (previousResult) return previousResult.boolValue;

        SEL selectors[] = {
            @selector(layoutSubviews), @selector(didMoveToWindow), @selector(setHidden:)
        };
        IMP original[3] = {NULL, NULL, NULL};
        IMP replacement[3] = {NULL, NULL, NULL};
        const char *types[3] = {NULL, NULL, NULL};

        // Validate every method before making any change. Inherited UIKit
        // methods are allowed, but a differently-typed override is rejected.
        bool valid = CDPrepareUIKitPrimitives();
        for (unsigned int i = 0; valid && i < 3; ++i) {
            Method method = class_getInstanceMethod(target, selectors[i]);
            valid = CDSignatureMatches(method, @encode(void),
                                       i == 2 ? @encode(BOOL) : NULL);
            if (valid) {
                original[i] = method_getImplementation(method);
                types[i] = method_getTypeEncoding(method);
            }
        }
        if (!valid) {
            objc_setAssociatedObject(target, &CDInstallResultKey, @NO,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return false;
        }

        for (unsigned int i = 0; i < 2; ++i) {
            // Capturing this specific original IMP is important: looking it
            // up by the receiver's dynamic class would recurse if a target
            // subclass inherits another target's replacement.
            CDVoidMethod savedOriginal = (CDVoidMethod)original[i];
            SEL savedSelector = selectors[i];
            replacement[i] = imp_implementationWithBlock(^(id receiver) {
                savedOriginal(receiver, savedSelector);
                CDHideAdvertisementView(receiver);
            });
        }
        CDBoolSetter savedSetter = (CDBoolSetter)original[2];
        replacement[2] = imp_implementationWithBlock(^(id receiver, BOOL hidden) {
            // Preserve the caller's exact argument and the original setter's
            // side effects; the subsequent change is purely view visibility.
            savedSetter(receiver, @selector(setHidden:), hidden);
            CDHideAdvertisementView(receiver);
        });

        if (!replacement[0] || !replacement[1] || !replacement[2]) {
            for (unsigned int i = 0; i < 3; ++i) {
                if (replacement[i]) imp_removeBlock(replacement[i]);
            }
            objc_setAssociatedObject(target, &CDInstallResultKey, @NO,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return false;
        }

        unsigned int installed = 0;
        for (; installed < 3; ++installed) {
            // Always attempt a local addition first. Never mutate the Method
            // returned for an inherited implementation on the superclass.
            if (class_addMethod(target, selectors[installed], replacement[installed],
                                types[installed])) continue;
            Method own = CDOwnMethod(target, selectors[installed]);
            if (!own || method_getImplementation(own) != original[installed]) break;
            method_setImplementation(own, replacement[installed]);
        }

        if (installed != 3) {
            // A conflicting runtime mutation is unexpected on the main
            // thread. Restore original dispatch, including any added local
            // entries. Published blocks stay alive to avoid dangling IMPs.
            for (unsigned int i = 0; i < installed; ++i) {
                class_replaceMethod(target, selectors[i], original[i], types[i]);
            }
            for (unsigned int i = installed; i < 3; ++i) {
                imp_removeBlock(replacement[i]);
            }
            objc_setAssociatedObject(target, &CDInstallResultKey, @NO,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return false;
        }

        objc_setAssociatedObject(target, &CDInstallResultKey, @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return true;
    }
}

static CD167CloseState *CDCloseStateForObject(id receiver) {
    CD167CloseState *state = objc_getAssociatedObject(receiver, &CDCloseStateKey);
    if (!state) {
        state = [CD167CloseState new];
        objc_setAssociatedObject(receiver, &CDCloseStateKey, state,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return state;
}

static void CDRunOriginalCloseOnce(id receiver, SEL selector, CDVoidMethod original,
                                   CD167CloseState *state) {
    // Parent and child targets can both wrap an inherited action. Permit each
    // captured implementation once within the same original-call chain, while
    // rejecting re-entry through an implementation already executing.
    NSValue *identity = [NSValue valueWithPointer:(const void *)original];
    if (state.executing) {
        if ([state.activeOriginals containsObject:identity]) return;
        [state.activeOriginals addObject:identity];
        original(receiver, selector);
        return;
    }
    if (state.finished) return;
    state.finished = YES;
    state.pending = nil;
    state.executing = YES;
    state.activeOriginals = [NSMutableSet setWithObject:identity];
    @try {
        original(receiver, selector);
    } @finally {
        state.executing = NO;
        state.activeOriginals = nil;
    }
}

static UIView *CDCloseSurface(id receiver, bool isController) {
    // viewIfLoaded avoids creating a view merely to dismiss an absent screen.
    return isController ? [(UIViewController *)receiver viewIfLoaded] : (UIView *)receiver;
}

static bool CDControllerIsLeaving(UIViewController *controller) {
    return controller.isBeingDismissed || controller.isMovingFromParentViewController ||
           controller.presentedViewController != nil;
}

static void CDQueueOriginalClose(id receiver, bool isController,
                                 SEL action, CDVoidMethod originalAction) {
    UIView *surface = CDCloseSurface(receiver, isController);
    UIWindow *window = surface.window;
    if (!window || (isController && CDControllerIsLeaving(receiver))) return;
    CD167CloseState *state = CDCloseStateForObject(receiver);
    if (state.finished || state.pending) return;
    NSObject *ticket = [NSObject new];
    state.pending = ticket;
    __weak id weakReceiver = receiver;
    __weak UIView *weakSurface = surface;
    __weak UIWindow *weakWindow = window;
    dispatch_async(dispatch_get_main_queue(), ^{
        id liveReceiver = weakReceiver;
        UIView *liveSurface = weakSurface;
        UIWindow *liveWindow = weakWindow;
        if (!liveReceiver) return;
        if (objc_getAssociatedObject(liveReceiver, &CDCloseStateKey) != state ||
            state.pending != ticket) return;
        state.pending = nil;
        if (!liveSurface || !liveWindow || state.finished ||
            CDCloseSurface(liveReceiver, isController) != liveSurface ||
            liveSurface.window != liveWindow) return;
        if (isController && CDControllerIsLeaving(liveReceiver)) return;
        CDRunOriginalCloseOnce(liveReceiver, action, originalAction, state);
    });
}

static void CDUpdateCloseViewAttachment(UIView *view, SEL action,
                                        CDVoidMethod originalAction) {
    UIWindow *window = view.window;
    CD167CloseState *state = objc_getAssociatedObject(view, &CDCloseStateKey);
    if (!window) {
        // Detachment invalidates queued tickets. A later attachment of a reused
        // interstitial gets a new epoch, even if it uses the same UIWindow.
        objc_setAssociatedObject(view, &CDCloseStateKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    if (!state || state.attachedWindow != window) {
        state = [CD167CloseState new];
        state.attachedWindow = window;
        objc_setAssociatedObject(view, &CDCloseStateKey, state,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    CDQueueOriginalClose(view, false, action, originalAction);
}

static bool CDInstallCloseClass(Class target, bool isController) {
    if (![NSThread isMainThread] ||
        !(isController ? CDIsProperControllerSubclass(target) : CDIsProperViewSubclass(target))) {
        return false;
    }
    @synchronized ([CD167DisplayInstallerLock class]) {
        NSNumber *previous = objc_getAssociatedObject(target, &CDCloseInstallResultKey);
        if (previous) return previous.boolValue;
        SEL selectors[2] = {
            isController ? @selector(viewDidAppear:) : @selector(didMoveToWindow),
            sel_registerName(isController ? "didTapSkipButton" : "didTapClose")
        };
        IMP original[2] = {NULL, NULL};
        IMP replacement[2] = {NULL, NULL};
        const char *types[2] = {NULL, NULL};
        // The UI action is not assumed from its name: check the actual ABI
        // before either lifecycle or action dispatch is changed.
        for (unsigned int i = 0; i < 2; ++i) {
            Method method = class_getInstanceMethod(target, selectors[i]);
            if (!CDSignatureMatches(method, @encode(void),
                                    i == 0 && isController ? @encode(BOOL) : NULL)) {
                objc_setAssociatedObject(target, &CDCloseInstallResultKey, @NO,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                return false;
            }
            original[i] = method_getImplementation(method);
            types[i] = method_getTypeEncoding(method);
        }
        CDVoidMethod savedAction = (CDVoidMethod)original[1];
        SEL actionSelector = selectors[1];
        if (isController) {
            CDBoolSetter savedLifecycle = (CDBoolSetter)original[0];
            replacement[0] = imp_implementationWithBlock(^(id receiver, BOOL animated) {
                savedLifecycle(receiver, @selector(viewDidAppear:), animated);
                CDQueueOriginalClose(receiver, true, actionSelector, savedAction);
            });
        } else {
            CDVoidMethod savedLifecycle = (CDVoidMethod)original[0];
            replacement[0] = imp_implementationWithBlock(^(id receiver) {
                savedLifecycle(receiver, @selector(didMoveToWindow));
                CDUpdateCloseViewAttachment(receiver, actionSelector, savedAction);
            });
        }
        replacement[1] = imp_implementationWithBlock(^(id receiver) {
            CDRunOriginalCloseOnce(receiver, actionSelector, savedAction,
                                   CDCloseStateForObject(receiver));
        });
        if (!replacement[0] || !replacement[1]) {
            for (unsigned int i = 0; i < 2; ++i) {
                if (replacement[i]) imp_removeBlock(replacement[i]);
            }
            objc_setAssociatedObject(target, &CDCloseInstallResultKey, @NO,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return false;
        }
        unsigned int installed = 0;
        for (; installed < 2; ++installed) {
            if (class_addMethod(target, selectors[installed], replacement[installed],
                                types[installed])) continue;
            Method own = CDOwnMethod(target, selectors[installed]);
            if (!own || method_getImplementation(own) != original[installed]) break;
            method_setImplementation(own, replacement[installed]);
        }
        if (installed != 2) {
            for (unsigned int i = 0; i < installed; ++i) {
                class_replaceMethod(target, selectors[i], original[i], types[i]);
            }
            for (unsigned int i = installed; i < 2; ++i) imp_removeBlock(replacement[i]);
        }
        objc_setAssociatedObject(target, &CDCloseInstallResultKey, @(installed == 2),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return installed == 2;
    }
}

static void CDInstallKnownTargets(void) {
    if (![NSThread isMainThread]) return;
    // Exact names and inheritance were read from the supplied 16.7 binary.
    // No substring search, global view hook, view-tree traversal, or timer.
    static const char *const names[] = {
        "_TtC10CoolMarket44GeneralEntityListFeedAdvertisementCellBaseV4",
        "_TtCC10CoolMarket44GeneralEntityListFeedAdvertisementCellBaseV48BodyView",
        "_TtC10CoolMarket59GeneralEntityListFeedAdvertisementCellBaseV4_ImageMediaView",
        "_TtCC10CoolMarket44GeneralEntityListFeedAdvertisementCellBaseV423SelfRenderContainerView"
    };
    // Splash/interstitial containers retain their buttons and cleanup. Use
    // their verified original UI actions instead of hiding a modal container.
    for (unsigned int i = 0; i < sizeof(names) / sizeof(names[0]); ++i) {
        Class target = objc_getClass(names[i]);
        if (target) CDInstallViewClass(target);
    }
    Class splash = objc_getClass("_TtC10CoolMarket33SplashAdvertisementViewController");
    if (splash) CDInstallCloseClass(splash, true);
    Class interstitial = objc_getClass("_TtC10CoolMarket20KAInterstitialAdView");
    if (interstitial) CDInstallCloseClass(interstitial, false);
}

#ifdef CD_TESTING
// Compile-time-only test seam. Arbitrary target installation is not exported
// by the production dylib. Repeated successful installation returns true
// without replacing any IMP a second time.
__attribute__((visibility("default")))
bool CDInstallViewClassForTesting(Class target) {
    return CDInstallViewClass(target);
}

__attribute__((visibility("default")))
bool CDInstallCloseViewClassForTesting(Class target) {
    return CDInstallCloseClass(target, false);
}

__attribute__((visibility("default")))
bool CDInstallCloseControllerClassForTesting(Class target) {
    return CDInstallCloseClass(target, true);
}

__attribute__((visibility("default")))
void CDInstallKnownTargetsForTesting(void) {
    CDInstallKnownTargets();
}
#else
__attribute__((constructor)) static void CDStart(void) {
    // LoadControl can dlopen us off the main thread. A single main-queue job
    // performs installation after Objective-C image registration has finished.
    dispatch_async(dispatch_get_main_queue(), ^{
        CDInstallKnownTargets();
    });
}
#endif
