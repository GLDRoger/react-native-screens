#import <UIKit/UIKit.h>
#import <XCTest/XCTest.h>
#import <objc/message.h>
#import <objc/runtime.h>

static char eventsKey;
static NSMutableArray *Events(id bar)
{
  NSMutableArray *events = objc_getAssociatedObject(bar, &eventsKey);
  if (!events) {
    events = [NSMutableArray new];
    objc_setAssociatedObject(bar, &eventsKey, events, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
  return events;
}
static void Cancel(id self, SEL cmd)
{
  [Events(self) addObject:@"cancel"];
}
static void Text(id self, SEL cmd, NSString *text)
{
  [Events(self) addObject:@[ @"text", text ?: @"" ]];
}
static void SetText(id bar, NSString *text)
{
  ((void (*)(id, SEL, NSString *))objc_msgSend)(bar, NSSelectorFromString(@"setText:"), text);
}
static void DropEvent(id self, SEL cmd, UISearchController *controller) {}
static void DismissWithoutGuards(id self, SEL cmd, UISearchController *controller)
{
  [(id<UISearchBarDelegate>)self searchBarCancelButtonClicked:controller.searchBar];
}
static uint32_t NextRandom(uint32_t &seed)
{
  seed ^= seed << 13;
  seed ^= seed >> 17;
  seed ^= seed << 5;
  return seed;
}
@interface SearchControllerHostProbe : UISearchController
@property (nonatomic, strong) UIViewController *host;
@end
@implementation SearchControllerHostProbe
- (UIViewController *)presentingViewController
{
  return self.host;
}
@end

@interface SearchEvents : XCTestCase
@end
@implementation SearchEvents
- (id)makeBar
{
  Class probe = NSClassFromString(@"RNSSearchBarEventProbe");
  if (!probe) {
    Class base = NSClassFromString(@"RNSSearchBar");
    XCTAssertNotNil(base);
    probe = objc_allocateClassPair(base, "RNSSearchBarEventProbe", 0);
    class_addMethod(probe, NSSelectorFromString(@"emitOnCancelButtonPressEvent"), (IMP)Cancel, "v@:");
    class_addMethod(probe, NSSelectorFromString(@"emitOnChangeTextEventWithText:"), (IMP)Text, "v@:@");
    NSString *mutation = NSProcessInfo.processInfo.environment[@"RNS_SEARCH_MUTATION"];
    if ([mutation isEqualToString:@"missing-dismiss"]) {
      class_addMethod(probe, @selector(didDismissSearchController:), (IMP)DropEvent, "v@:@");
    } else if ([mutation isEqualToString:@"missing-text-update"]) {
      class_addMethod(probe, @selector(updateSearchResultsForSearchController:), (IMP)DropEvent, "v@:@");
    } else if ([mutation isEqualToString:@"unconditional-dismiss"]) {
      class_addMethod(probe, @selector(didDismissSearchController:), (IMP)DismissWithoutGuards, "v@:@");
    }
    if (mutation.length > 0)
      NSLog(@"RNS_SEARCH_MUTATION=%@", mutation);
    objc_registerClassPair(probe);
  }
  return [[probe alloc] init];
}
- (UIWindow *)showBar:(id)bar
{
  UIWindow *window = [[UIWindow alloc] initWithFrame:CGRectMake(0, 0, 400, 800)];
  window.rootViewController = [UIViewController new];
  [window makeKeyAndVisible];
  UISearchController *controller = [bar valueForKey:@"controller"];
  [window.rootViewController.view addSubview:controller.searchBar];
  return window;
}
- (void)testMissingCancelDelegate
{
  id bar = [self makeBar];
  UIWindow *window = [self showBar:bar];
  UISearchController *controller = [bar valueForKey:@"controller"];
  XCTAssertTrue([bar respondsToSelector:@selector(didDismissSearchController:)]);
  if (![bar respondsToSelector:@selector(didDismissSearchController:)])
    return;
  [(id<UISearchControllerDelegate>)bar willPresentSearchController:controller];
  SetText(bar, @"needle");
  controller.searchResultsUpdater = nil;
  controller.searchBar.text = @"";
  [(id<UISearchControllerDelegate>)bar willDismissSearchController:controller];
  [(id<UISearchControllerDelegate>)bar didDismissSearchController:controller];
  XCTAssertEqualObjects(Events(bar), (@[ @"cancel", @[ @"text", @"" ] ]));
  window.hidden = YES;
}
- (void)testMissingInFieldClearDelegate
{
  id bar = [self makeBar];
  UISearchController *controller = [bar valueForKey:@"controller"];
  XCTAssertTrue([bar respondsToSelector:@selector(updateSearchResultsForSearchController:)]);
  if (![bar respondsToSelector:@selector(updateSearchResultsForSearchController:)])
    return;
  SetText(bar, @"needle");
  XCTAssertEqual(Events(bar).count, 0u);
  controller.searchResultsUpdater = nil;
  controller.searchBar.text = @"";
  [(id<UISearchResultsUpdating>)bar updateSearchResultsForSearchController:controller];
  [(id<UISearchBarDelegate>)bar searchBar:controller.searchBar textDidChange:@""];
  XCTAssertEqualObjects(Events(bar), (@[ @[ @"text", @"" ] ]));
}
- (void)testProgrammaticDeactivationDoesNotCancel
{
  id bar = [self makeBar];
  UIWindow *window = [self showBar:bar];
  UISearchController *controller = [bar valueForKey:@"controller"];
  XCTAssertTrue([bar respondsToSelector:@selector(didDismissSearchController:)]);
  if (![bar respondsToSelector:@selector(didDismissSearchController:)])
    return;
  [(id<UISearchControllerDelegate>)bar willPresentSearchController:controller];
  SetText(bar, @"needle");
  ((void (*)(id, SEL, BOOL))objc_msgSend)(bar, NSSelectorFromString(@"setActive:"), NO);
  controller.searchBar.text = @"";
  [(id<UISearchControllerDelegate>)bar willDismissSearchController:controller];
  [(id<UISearchControllerDelegate>)bar didDismissSearchController:controller];
  XCTAssertEqual(Events(bar).count, 0u);
  window.hidden = YES;
}
- (void)testCancelCallbackAndDismissalDoNotDoubleReport
{
  for (NSNumber *programmatic in @[ @NO, @YES ]) {
    id bar = [self makeBar];
    UIWindow *window = [self showBar:bar];
    UISearchController *controller = [bar valueForKey:@"controller"];
    XCTAssertTrue([bar respondsToSelector:@selector(didDismissSearchController:)]);
    if (![bar respondsToSelector:@selector(didDismissSearchController:)])
      return;
    [(id<UISearchControllerDelegate>)bar willPresentSearchController:controller];
    SetText(bar, @"needle");
    if (programmatic.boolValue) {
      [bar performSelector:NSSelectorFromString(@"cancelSearch")];
      [bar performSelector:NSSelectorFromString(@"cancelSearch")];
    } else {
      [(id<UISearchBarDelegate>)bar searchBarCancelButtonClicked:controller.searchBar];
    }
    [(id<UISearchControllerDelegate>)bar didDismissSearchController:controller];
    XCTAssertEqualObjects(Events(bar), (@[ @"cancel", @[ @"text", @"" ] ]));
    window.hidden = YES;
  }
}
- (void)testNavigationCollapseDoesNotCancelOrClearQuery
{
  id bar = [self makeBar];
  SearchControllerHostProbe *controller = [[SearchControllerHostProbe alloc] initWithSearchResultsController:nil];
  UIViewController *host = [UIViewController new];
  UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:host];
  controller.host = host;
  [bar setValue:controller forKey:@"controller"];
  UIWindow *window = [self showBar:bar];
  XCTAssertTrue([bar respondsToSelector:@selector(didDismissSearchController:)]);
  if (![bar respondsToSelector:@selector(didDismissSearchController:)])
    return;
  [(id<UISearchControllerDelegate>)bar willPresentSearchController:controller];
  SetText(bar, @"needle");
  [navigation pushViewController:[UIViewController new] animated:NO];
  [(id<UISearchControllerDelegate>)bar willDismissSearchController:controller];
  controller.searchBar.text = @"";
  [(id<UISearchResultsUpdating>)bar updateSearchResultsForSearchController:controller];
  [(id<UISearchControllerDelegate>)bar didDismissSearchController:controller];
  XCTAssertEqual(Events(bar).count, 0u);
  window.hidden = YES;
}
- (void)testDismissedIntegratedFieldCanBeDetachedFromItsHeader
{
  id bar = [self makeBar];
  UIWindow *window = [self showBar:bar];
  UISearchController *controller = [bar valueForKey:@"controller"];
  XCTAssertTrue([bar respondsToSelector:@selector(didDismissSearchController:)]);
  if (![bar respondsToSelector:@selector(didDismissSearchController:)])
    return;
  UIView *header = [UIView new];
  [window.rootViewController.view addSubview:header];
  [bar setValue:header forKey:@"navigationItemDelegate"];
  [(id<UISearchControllerDelegate>)bar willPresentSearchController:controller];
  SetText(bar, @"needle");
  controller.searchResultsUpdater = nil;
  [controller.searchBar removeFromSuperview];
  controller.searchBar.text = @"";
  [(id<UISearchControllerDelegate>)bar willDismissSearchController:controller];
  [(id<UISearchControllerDelegate>)bar didDismissSearchController:controller];
  XCTAssertEqualObjects(Events(bar), (@[ @"cancel", @[ @"text", @"" ] ]));
  window.hidden = YES;
}
- (void)testResultsUpdateAndDismissalDoNotDoubleReportText
{
  id bar = [self makeBar];
  UIWindow *window = [self showBar:bar];
  UISearchController *controller = [bar valueForKey:@"controller"];
  XCTAssertTrue([bar respondsToSelector:@selector(didDismissSearchController:)]);
  if (![bar respondsToSelector:@selector(didDismissSearchController:)])
    return;
  [(id<UISearchControllerDelegate>)bar willPresentSearchController:controller];
  SetText(bar, @"needle");
  controller.searchResultsUpdater = nil;
  controller.searchBar.text = @"";
  [(id<UISearchResultsUpdating>)bar updateSearchResultsForSearchController:controller];
  [(id<UISearchControllerDelegate>)bar willDismissSearchController:controller];
  [(id<UISearchControllerDelegate>)bar didDismissSearchController:controller];
  XCTAssertEqualObjects(Events(bar), (@[ @[ @"text", @"" ], @"cancel" ]));
  window.hidden = YES;
}
- (void)testSeededEventOrderFuzzing
{
  uint32_t seed = 29489;
  NSArray<NSString *> *queries = @[
    @"needle",
    @"é日本語😀",
    @"   ",
    @"x\ny",
    [@"x" stringByPaddingToLength:1024 withString:@"x" startingAtIndex:0]
  ];
  for (NSUInteger trace = 0; trace < 64; trace++) {
    @autoreleasepool {
      NSUInteger mode = trace % 4;
      id bar = [self makeBar];
      XCTAssertTrue([bar respondsToSelector:@selector(didDismissSearchController:)]);
      if (![bar respondsToSelector:@selector(didDismissSearchController:)])
        return;
      SearchControllerHostProbe *controller = [[SearchControllerHostProbe alloc] initWithSearchResultsController:nil];
      UIViewController *host = [UIViewController new];
      UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:host];
      if (mode == 3)
        controller.host = host;
      [bar setValue:controller forKey:@"controller"];
      UIWindow *window = [self showBar:bar];
      for (NSUInteger cycle = 0; cycle < 2; cycle++) {
        [navigation popToRootViewControllerAnimated:NO];
        [(id<UISearchControllerDelegate>)bar willPresentSearchController:controller];
        [Events(bar) removeAllObjects];
        SetText(bar, queries[NextRandom(seed) % queries.count]);
        if (mode == 2) {
          ((void (*)(id, SEL, BOOL))objc_msgSend)(bar, NSSelectorFromString(@"setActive:"), NO);
        }
        if (mode == 3)
          [navigation pushViewController:[UIViewController new] animated:NO];
        controller.searchBar.text = @"";
        NSMutableArray<NSNumber *> *actions = [@[ @0, @1, @0, @1 ] mutableCopy];
        if (mode != 1)
          [actions addObjectsFromArray:@[ @2, @3 ]];
        if (mode == 0 && trace % 3 != 0) {
          [actions addObjectsFromArray:trace % 3 == 1 ? @[ @4, @4 ] : @[ @5, @5 ]];
        }
        for (NSUInteger index = actions.count; index > 1; index--) {
          [actions exchangeObjectAtIndex:index - 1 withObjectAtIndex:NextRandom(seed) % index];
        }
        for (NSNumber *action in actions) {
          switch (action.unsignedIntegerValue) {
            case 0:
              [(id<UISearchResultsUpdating>)bar updateSearchResultsForSearchController:controller];
              break;
            case 1:
              [(id<UISearchBarDelegate>)bar searchBar:controller.searchBar textDidChange:@""];
              break;
            case 2:
              [(id<UISearchControllerDelegate>)bar willDismissSearchController:controller];
              break;
            case 3:
              [(id<UISearchControllerDelegate>)bar didDismissSearchController:controller];
              break;
            case 4:
              [(id<UISearchBarDelegate>)bar searchBarCancelButtonClicked:controller.searchBar];
              break;
            case 5:
              [bar performSelector:NSSelectorFromString(@"cancelSearch")];
              break;
          }
        }
        NSUInteger cancellations = 0;
        NSUInteger changes = 0;
        for (id event in Events(bar)) {
          if ([event isEqual:@"cancel"])
            cancellations++;
          else {
            XCTAssertEqualObjects(event, (@[ @"text", @"" ]), @"trace %lu cycle %lu", trace, cycle);
            changes++;
          }
        }
        XCTAssertEqual(cancellations, mode == 0 ? 1u : 0u, @"trace %lu cycle %lu", trace, cycle);
        XCTAssertEqual(changes, mode < 2 ? 1u : 0u, @"trace %lu cycle %lu", trace, cycle);
      }
      window.hidden = YES;
    }
  }
}
@end
