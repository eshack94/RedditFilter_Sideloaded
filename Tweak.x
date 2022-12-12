#import <Carousel.h>
#import <Comment.h>
#import <Post.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <objc/runtime.h>
#import "Preferences.h"

@interface UIImage ()
+ (UIImage *)imageNamed:(NSString *)name inBundle:(NSBundle *)bundle;
@end

NSMutableArray *assetBundles;

UIImage *iconWithName(NSString *iconName) {
  NSArray *commonIconSizes = @[
    @"24",
    @"20",
    @"16",
  ];
  UIImage *iconImage;
  for (NSBundle *bundle in assetBundles) {
    for (NSString *iconSize in commonIconSizes) {
      if (iconImage) break;
      iconImage = [UIImage imageNamed:[NSString stringWithFormat:@"%@_%@", iconName, iconSize]
                             inBundle:bundle];
    }
  }
  return iconImage;
}

static NSArray *filteredObjects(NSArray *objects) {
  return
      [objects filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(
                                                            id object, NSDictionary *bindings) {
                 NSString *className = NSStringFromClass(object_getClass(object));
                 if ([NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterPromoted]) {
                   if ([className hasSuffix:@"AdPost"]) return NO;
                   if ([className hasSuffix:@"Post"] &&
                       [object respondsToSelector:@selector(isAdPost)] && ((Post *)object).isAdPost)
                     return NO;
                 }
                 if ([NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterRecommended]) {
                   if ([className containsString:@"Recommendation"]) return NO;
                 }
                 if ([NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterLivestreams]) {
                   if ([className containsString:@"Stream"]) return NO;
                 }
                 if ([NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterNSFW]) {
                   if ([className hasSuffix:@"Post"] &&
                       [object respondsToSelector:@selector(isNSFW)] && ((Post *)object).isNSFW)
                     return NO;
                 }
                 return YES;
               }]];
}

%hook Listing
- (void)fetchNextPage:(id (^)(NSArray *, id))completion {
  id (^newCompletion)(NSArray *, id) = ^id(NSArray *objects, id arg2) {
    objects = filteredObjects(objects);
    return completion(objects, arg2);
  };
  %orig(newCompletion);
}
%end

%hook FeedNetworkSource
- (NSArray *)postsAndCommentsFromData:(id)data {
  return filteredObjects(%orig);
}
%end

%hook PostDetailPresenter
- (BOOL)shouldFetchCommentAdPost {
  return [NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterPromoted] ? NO
                                                                                : %orig;
}
%end

%hook StreamManager
- (instancetype)initWithAccountContext:(id)accountContext
                                source:(NSInteger)source
                 deeplinkSubredditName:(id)deeplinkSubredditName
                       streamingConfig:(id)streamingConfig {
  if ([NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterLivestreams]) return nil;
  return %orig;
}
- (instancetype)initWithService:(id)service
                         source:(NSInteger)source
          deeplinkSubredditName:(id)deeplinkSubredditName
                streamingConfig:(id)streamingConfig {
  if ([NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterLivestreams]) return nil;
  return %orig;
}
%end

%hook Carousel
- (BOOL)isHiddenByUserWithAccountSettings:(id)accountSettings {
  return ([NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterRecommended] &&
          ([self.analyticType containsString:@"recommended"] ||
           [self.analyticType containsString:@"similar"] ||
           [self.analyticType containsString:@"popular"])) ||
         %orig;
}
%end

%hook QuickActionViewModel
- (void)fetchActions {
  if ([NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterRecommended]) return;
  %orig;
}
%end

%hook Post
- (NSArray *)awardingTotals {
  return [NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterAwards] ? nil
                                                                              : %orig;
}
- (NSUInteger)totalAwardsReceived {
  return [NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterAwards] ? 0
                                                                              : %orig;
}
- (BOOL)canAward {
  return [NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterAwards] ? NO
                                                                              : %orig;
}
%end

%hook Comment
- (NSArray *)awardingTotals {
  return [NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterAwards] ? nil
                                                                              : %orig;
}
- (NSUInteger)totalAwardsReceived {
  return [NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterAwards] ? 0
                                                                              : %orig;
}
- (BOOL)canAward {
  return [NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterAwards] ? NO
                                                                              : %orig;
}
- (BOOL)shouldHighlightForHighAward {
  return [NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterAwards] ? NO
                                                                              : %orig;
}
- (BOOL)shouldAutoCollapse {
  return [NSUserDefaults.standardUserDefaults boolForKey:kRedditFilterAutoCollapseAutoMod] &&
                 [((Comment *)self).authorPk isEqualToString:@"t2_6l4z3"]
             ? YES
             : %orig;
}
%end

static Class CoreClass(NSString *name) {
  Class cls = NSClassFromString(name);
  NSArray *prefixes = @[
    @"Reddit.",
    @"RedditCore.",
    @"RedditCoreModels.",
    @"RedditCore_RedditCoreModels.",
  ];
  for (NSString *prefix in prefixes) {
    if (cls) break;
    cls = NSClassFromString([prefix stringByAppendingString:name]);
  }
  return cls;
}

static BOOL initialized = NO;

static void add_image(const struct mach_header *mh, intptr_t vmaddr_slide) {
  if (!initialized && %c(Listing)) {
    %init(Comment = CoreClass(@"Comment"), Post = CoreClass(@"Post"),
                     QuickActionViewModel = CoreClass(@"QuickActionViewModel"),
                     StreamManager = CoreClass(@"StreamManager"));
    initialized = YES;
  }
}

%ctor {
  assetBundles = [NSMutableArray new];
  [assetBundles addObject:NSBundle.mainBundle];
  for (NSString *file in
       [NSFileManager.defaultManager contentsOfDirectoryAtPath:NSBundle.mainBundle.bundlePath
                                                         error:nil]) {
    if (![file hasSuffix:@"bundle"]) continue;
    NSBundle *bundle = [NSBundle
        bundleWithPath:[NSBundle.mainBundle pathForResource:[file stringByDeletingPathExtension]
                                                     ofType:@"bundle"]];
    if (bundle) [assetBundles addObject:bundle];
  }
  for (NSString *file in [NSFileManager.defaultManager
           contentsOfDirectoryAtPath:[NSBundle.mainBundle.bundlePath
                                         stringByAppendingPathComponent:@"Frameworks"]
                               error:nil]) {
    if (![file hasSuffix:@"framework"]) continue;
    NSBundle *bundle = [NSBundle
        bundleWithPath:[NSBundle.mainBundle pathForResource:[file stringByDeletingPathExtension]
                                                     ofType:@"framework"
                                                inDirectory:@"Frameworks"]];
    if (bundle) [assetBundles addObject:bundle];
  }
  _dyld_register_func_for_add_image(add_image);
}
