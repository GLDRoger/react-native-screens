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
@end
