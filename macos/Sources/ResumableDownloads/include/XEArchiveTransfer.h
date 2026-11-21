#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface XEArchiveTransfer : NSObject <NSURLSessionDataDelegate>
- (void)resume;
- (void)cancel;
+ (void)pruneDirectory:(NSString *)directory retainingURL:(NSURL *)url NS_SWIFT_NAME(prune(directory:retaining:));
+ (BOOL)shouldRetryError:(NSError *)error response:(nullable NSURLResponse *)response NS_SWIFT_NAME(shouldRetry(_:response:));
+ (NSString *)partialFilenameForURL:(NSURL *)url NS_SWIFT_NAME(partialFilename(for:));
+ (nullable XEArchiveTransfer *)taskForRequest:(NSURLRequest *)request
                              directory:(NSString *)directory
                                  queue:(nullable NSOperationQueue *)queue
                               progress:(void (^)(int64_t received, int64_t total))progress
                             completion:(void (^)(NSURL *, NSURLResponse * _Nullable, NSError * _Nullable))completion
                                  error:(NSError **)error NS_SWIFT_NAME(task(for:directory:queue:progress:completion:));
@end
NS_ASSUME_NONNULL_END
