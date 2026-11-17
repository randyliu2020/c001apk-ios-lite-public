#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <stdbool.h>

extern bool CDInstallViewClassForTesting(Class target);
extern void CDInstallKnownTargetsForTesting(void);
extern bool CDInstallCloseViewClassForTesting(Class target);
extern bool CDInstallCloseControllerClassForTesting(Class target);

static NSMutableArray<NSDictionary *> *results;
static void Check(BOOL pass, NSString *name) {
    [results addObject:@{@"name": name, @"passed": @(pass)}];
    NSLog(@"%@: %@", pass ? @"PASS" : @"FAIL", name);
}

@interface ProbeBase : UIView
@property(nonatomic) NSUInteger layoutCalls;
@property(nonatomic) NSUInteger moveCalls;
@property(nonatomic) NSUInteger hiddenCalls;
@property(nonatomic) BOOL lastHiddenArgument;
@property(nonatomic, strong) id adData;
@property(nonatomic) NSUInteger modelCalls;
@end
@implementation ProbeBase
@synthesize adData = _adData;
- (void)layoutSubviews { self.layoutCalls += 1; [super layoutSubviews]; }
- (void)didMoveToWindow { self.moveCalls += 1; [super didMoveToWindow]; }
- (void)setHidden:(BOOL)value {
    self.hiddenCalls += 1;
    self.lastHiddenArgument = value;
    [super setHidden:value];
}
- (void)setAdData:(id)value { self.modelCalls += 1; _adData = value; }
@end
@interface ProbeAd : ProbeBase @end
@implementation ProbeAd @end
@interface ProbeOrdinary : ProbeBase @end
@implementation ProbeOrdinary @end
@interface ProbeOwnAd : ProbeBase @end
@implementation ProbeOwnAd
- (void)layoutSubviews { [super layoutSubviews]; }
- (void)didMoveToWindow { [super didMoveToWindow]; }
- (void)setHidden:(BOOL)value { [super setHidden:value]; }
@end
@interface ProbeAdChild : ProbeAd @end
@implementation ProbeAdChild @end
@interface ProbeBackground : ProbeBase @end
@implementation ProbeBackground @end

@interface ProbePopup : ProbeBase
@property(nonatomic) NSUInteger closeCalls;
@end
@implementation ProbePopup
- (void)didTapClose { self.closeCalls += 1; [self removeFromSuperview]; }
@end
@interface ProbeSplash : UIViewController
@property(nonatomic) NSUInteger appearCalls;
@property(nonatomic) NSUInteger skipCalls;
@end
@implementation ProbeSplash
- (void)viewDidAppear:(BOOL)animated { self.appearCalls += 1; [super viewDidAppear:animated]; }
- (void)didTapSkipButton { self.skipCalls += 1; [self.view removeFromSuperview]; }
@end
@interface ProbeDismissingSplash : ProbeSplash @end
@implementation ProbeDismissingSplash
- (BOOL)isBeingDismissed { return YES; }
@end

static NSInteger BadHidden(id receiver, SEL selector, NSInteger value) {
    (void)receiver; (void)selector; return value;
}

static IMP MethodIMP(Class cls, SEL selector) {
    return method_getImplementation(class_getInstanceMethod(cls, selector));
}

static void Finish(void) {
    NSUInteger failed = 0;
    for (NSDictionary *entry in results) if (![entry[@"passed"] boolValue]) failed += 1;
    NSDictionary *receipt = @{@"passed": @(results.count - failed), @"failed": @(failed),
                              @"checks": results,
                              @"scope": @"Synthetic UIKit regression tests; not Coolapk or real-device performance."};
    NSURL *directory = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory
                                                              inDomains:NSUserDomainMask] firstObject];
    NSData *data = [NSJSONSerialization dataWithJSONObject:receipt options:NSJSONWritingPrettyPrinted error:NULL];
    [data writeToURL:[directory URLByAppendingPathComponent:@"display-test-results.json"] atomically:YES];
    NSLog(@"DISPLAY_TESTS_FINISHED passed=%lu failed=%lu", (unsigned long)(results.count - failed),
          (unsigned long)failed);
}

static void RunCloseTests(UIWindow *window) {
    Check(!CDInstallCloseViewClassForTesting([UIView class]) &&
          !CDInstallCloseViewClassForTesting([ProbeOrdinary class]), @"Close hook rejects global class and absent action");
    Check(!CDInstallCloseControllerClassForTesting([UIViewController class]),
          @"Close hook rejects global UIViewController");
    IMP baseMove = MethodIMP([ProbeBase class], @selector(didMoveToWindow));
    Check(CDInstallCloseViewClassForTesting([ProbePopup class]), @"Install exact popup close hook");
    Check(baseMove == MethodIMP([ProbeBase class], @selector(didMoveToWindow)),
          @"Popup close hook leaves superclass unchanged");
    IMP popupMove = MethodIMP([ProbePopup class], @selector(didMoveToWindow));
    Check(CDInstallCloseViewClassForTesting([ProbePopup class]) &&
          popupMove == MethodIMP([ProbePopup class], @selector(didMoveToWindow)), @"Popup close install is idempotent");
    ProbePopup *popup = [ProbePopup new];
    [window.rootViewController.view addSubview:popup];
    [popup didMoveToWindow];
    ProbePopup *manual = [ProbePopup new];
    [window.rootViewController.view addSubview:manual];
    [manual didTapClose];
    ProbePopup *detached = [ProbePopup new];
    [window.rootViewController.view addSubview:detached];
    [detached removeFromSuperview];
    __weak ProbePopup *released;
    @autoreleasepool {
        ProbePopup *shortLived = [ProbePopup new];
        released = shortLived;
        [window.rootViewController.view addSubview:shortLived];
        [shortLived removeFromSuperview];
    }

    IMP controllerAppear = MethodIMP([UIViewController class], @selector(viewDidAppear:));
    Check(CDInstallCloseControllerClassForTesting([ProbeSplash class]), @"Install exact splash UI close hook");
    Check(controllerAppear == MethodIMP([UIViewController class], @selector(viewDidAppear:)),
          @"Splash hook leaves global view-controller lifecycle unchanged");
    ProbeSplash *splash = [ProbeSplash new];
    [window.rootViewController.view addSubview:splash.view];
    [splash viewDidAppear:YES];
    [splash viewDidAppear:NO];
    ProbeSplash *removedSplash = [ProbeSplash new];
    [window.rootViewController.view addSubview:removedSplash.view];
    [removedSplash viewDidAppear:YES];
    [removedSplash.view removeFromSuperview];
    ProbeDismissingSplash *dismissing = [ProbeDismissingSplash new];
    [window.rootViewController.view addSubview:dismissing.view];
    [dismissing viewDidAppear:YES];

    dispatch_async(dispatch_get_main_queue(), ^{
        Check(popup.closeCalls == 1 && popup.superview == nil,
              @"Automatic popup close uses original action once and removes overlay");
        Check(manual.closeCalls == 1, @"Manual close racing queued close is not duplicated");
        Check(detached.closeCalls == 0, @"Detached popup cancels pending close");
        Check(released == nil, @"Pending close does not retain a removed popup");
        Check(splash.appearCalls == 2 && splash.skipCalls == 1 && splash.view.superview == nil,
              @"Splash preserves lifecycle and calls original skip once");
        Check(removedSplash.skipCalls == 0, @"Removed splash cancels pending skip");
        Check(dismissing.skipCalls == 0, @"Already dismissing controller is not closed twice");
        [window.rootViewController.view addSubview:detached];
        [window.rootViewController.view addSubview:popup];
        dispatch_async(dispatch_get_main_queue(), ^{
            Check(detached.closeCalls == 1, @"A cancelled popup can close when reattached");
            Check(popup.closeCalls == 2, @"Reused popup closes once for each new attachment");
            Finish();
        });
    });
}

static void RunTests(UIWindow *window) {
    results = [NSMutableArray new];
    Check([NSThread isMainThread], @"Tests run on UIKit main thread");
    SEL selectors[] = {@selector(layoutSubviews), @selector(didMoveToWindow), @selector(setHidden:)};
    IMP baseBefore[3], uiBefore[3];
    for (unsigned int i = 0; i < 3; ++i) {
        baseBefore[i] = MethodIMP([ProbeBase class], selectors[i]);
        uiBefore[i] = MethodIMP([UIView class], selectors[i]);
    }
    Check(!CDInstallViewClassForTesting(Nil), @"Reject nil class");
    Check(!CDInstallViewClassForTesting([NSObject class]), @"Reject non-view class");
    Check(!CDInstallViewClassForTesting([UIView class]), @"Reject global UIView hook");
    Check(CDInstallViewClassForTesting([ProbeAd class]), @"Install inherited methods on exact ad subclass");
    BOOL originalsUntouched = YES;
    for (unsigned int i = 0; i < 3; ++i) {
        originalsUntouched &= baseBefore[i] == MethodIMP([ProbeBase class], selectors[i]);
        originalsUntouched &= uiBefore[i] == MethodIMP([UIView class], selectors[i]);
    }
    Check(originalsUntouched, @"Superclass and UIKit implementations unchanged");
    IMP adBefore = MethodIMP([ProbeAd class], @selector(layoutSubviews));
    Check(CDInstallViewClassForTesting([ProbeAd class]) &&
          adBefore == MethodIMP([ProbeAd class], @selector(layoutSubviews)), @"Repeated install is idempotent");

    ProbeOrdinary *ordinary = [[ProbeOrdinary alloc] initWithFrame:CGRectMake(1, 2, 300, 200)];
    ordinary.hidden = NO;
    Check(!ordinary.hidden && ordinary.hiddenCalls == 1, @"Ordinary sibling visibility unchanged");
    ProbeAd *ad = [[ProbeAd alloc] initWithFrame:CGRectMake(1, 2, 300, 200)];
    [window.rootViewController.view addSubview:ad];
    ad.layoutCalls = 0;
    [ad layoutSubviews];
    Check(ad.layoutCalls == 1 && ad.hidden, @"Original layout called once, then ad hidden");
    ad.moveCalls = 0;
    [ad didMoveToWindow];
    Check(ad.moveCalls == 1 && ad.hidden, @"Original window lifecycle called once");
    ad.hiddenCalls = 0;
    ad.hidden = NO;
    Check(ad.hidden && ad.hiddenCalls == 1 && !ad.lastHiddenArgument,
          @"Original hidden setter receives unchanged caller argument");
    NSDictionary *model = @{@"adData": @"original", @"cursor": @"next-page-token"};
    ad.adData = model;
    Check(ad.adData == model && ad.modelCalls == 1, @"Data setter and pagination payload untouched");
    CGRect frame = ad.frame;
    [ad layoutSubviews];
    Check(CGRectEqualToRect(frame, ad.frame), @"Ad frame and collection layout geometry unchanged");
    [ad removeFromSuperview];
    Check(ad.superview == nil, @"Original removal lifecycle remains usable");
    Check(CDInstallViewClassForTesting([ProbeOwnAd class]), @"Install class with own method overrides");
    ProbeOwnAd *own = [ProbeOwnAd new];
    [own layoutSubviews];
    Check(own.layoutCalls == 1 && own.hidden, @"Own override still calls original superclass once");
    Check(CDInstallViewClassForTesting([ProbeAdChild class]), @"Install child of hooked class");
    ProbeAdChild *child = [ProbeAdChild new];
    [child layoutSubviews];
    Check(child.layoutCalls == 1 && child.hidden, @"Parent-child hooks do not recurse or duplicate layout");

    Class bad = objc_allocateClassPair([ProbeBase class], "ProbeWrongABI", 0);
    class_addMethod(bad, @selector(setHidden:), (IMP)BadHidden, "q@:q");
    objc_registerClassPair(bad);
    IMP badLayout = MethodIMP(bad, @selector(layoutSubviews));
    Check(!CDInstallViewClassForTesting(bad) && badLayout == MethodIMP(bad, @selector(layoutSubviews)),
          @"Wrong ABI is rejected before any layout mutation");

    UIImageView *photo = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 100, 100)];
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = 1;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(1200, 800) format:format];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [[UIColor redColor] setFill];
        [context fillRect:CGRectMake(0, 0, 1200, 800)];
    }];
    photo.image = image;
    photo.contentMode = UIViewContentModeScaleAspectFit;
    photo.userInteractionEnabled = YES;
    UIPinchGestureRecognizer *pinch = [UIPinchGestureRecognizer new];
    [photo addGestureRecognizer:pinch];
    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 0, 100, 100)];
    scroll.minimumZoomScale = 1;
    scroll.maximumZoomScale = 4;
    [scroll addSubview:photo];
    [window.rootViewController.view addSubview:scroll];
    IMP imageLayout = MethodIMP([UIImageView class], @selector(layoutSubviews));
    IMP scrollLayout = MethodIMP([UIScrollView class], @selector(layoutSubviews));
    CDInstallKnownTargetsForTesting();
    [photo layoutSubviews];
    Check(photo.image == image && CGImageGetWidth(photo.image.CGImage) == 1200 &&
          CGImageGetHeight(photo.image.CGImage) == 800, @"Ordinary full-resolution image object and dimensions unchanged");
    Check(photo.contentMode == UIViewContentModeScaleAspectFit && !photo.hidden,
          @"Ordinary image visibility and content mode unchanged");
    Check(photo.gestureRecognizers.count == 1 && photo.gestureRecognizers.firstObject == pinch && pinch.enabled,
          @"Existing photo gesture recognizer preserved");
    Check(scroll.minimumZoomScale == 1 && scroll.maximumZoomScale == 4 && scroll.panGestureRecognizer.enabled,
          @"Scroll and zoom configuration preserved");
    Check(imageLayout == MethodIMP([UIImageView class], @selector(layoutSubviews)) &&
          scrollLayout == MethodIMP([UIScrollView class], @selector(layoutSubviews)),
          @"No global image or scroll method replacement");
    NSUInteger before = ad.layoutCalls;
    for (NSUInteger i = 0; i < 10000; ++i) [ad layoutSubviews];
    Check(ad.layoutCalls == before + 10000, @"Repeated layouts preserve one original call each");

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        bool accepted = CDInstallViewClassForTesting([ProbeBackground class]);
        dispatch_async(dispatch_get_main_queue(), ^{
            Check(!accepted, @"Off-main-thread installation rejected");
            RunCloseTests(window);
        });
    });
}

@interface DisplayTestDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation DisplayTestDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void)application; (void)options;
    return YES;
}
@end

@interface DisplayTestSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow *window;
@end
@implementation DisplayTestSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session
      options:(UISceneConnectionOptions *)options {
    (void)session; (void)options;
    if (![scene isKindOfClass:[UIWindowScene class]]) return;
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = [UIViewController new];
    [self.window makeKeyAndVisible];
    dispatch_async(dispatch_get_main_queue(), ^{ RunTests(self.window); });
}
@end

int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass([DisplayTestDelegate class])); }
}
