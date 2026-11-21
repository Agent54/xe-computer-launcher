#import "XEArchiveTransfer.h"
#import <os/log.h>
#import <CommonCrypto/CommonDigest.h>
#import <fcntl.h>
#import <sys/xattr.h>
#import <sys/stat.h>

// Keep the HTTP validator on the partial file so both move or disappear together.
static const char *validatorAttribute = "dev.xe.update.if-range";
typedef NS_ENUM(NSUInteger, XETransferPhase) { XETransferRange, XETransferMetadata, XETransferFull };

@implementation XEArchiveTransfer {
    NSURL *_file;
    NSFileHandle *_handle;
    NSString *_validator;
    int64_t _offset;
    int64_t _total;
    NSHTTPURLResponse *_completeResponse;
    NSError *_error;
    XETransferPhase _phase;
    NSMutableURLRequest *_nextRequest;
    NSURLRequest *_request;
    NSURLSession *_session;
    NSURLSessionDataTask *_task;
    BOOL _cancelled;
    void (^_progress)(int64_t, int64_t);
    void (^_completion)(NSURL *, NSURLResponse *, NSError *);
}

+ (void)pruneDirectory:(NSString *)directory retainingURL:(NSURL *)url
{
    NSString *keep = [self partialFilenameForURL:url];
    NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-10 * 24 * 60 * 60];
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:nil]) {
        if ([name isEqualToString:keep] || name.length != 64 ||
            [name rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"].invertedSet].location != NSNotFound) continue;
        NSString *path = [directory stringByAppendingPathComponent:name];
        int fd = open(path.fileSystemRepresentation, O_RDWR | O_EXLOCK | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC);
        if (fd < 0) continue;
        struct stat opened, current;
        if (fstat(fd, &opened) == 0 && S_ISREG(opened.st_mode) &&
            opened.st_mtimespec.tv_sec < cutoff.timeIntervalSince1970 &&
            lstat(path.fileSystemRepresentation, &current) == 0 &&
            opened.st_dev == current.st_dev && opened.st_ino == current.st_ino) {
            unlink(path.fileSystemRepresentation);
        }
        close(fd);
    }
}

static NSError *transferError(NSString *message)
{
    return [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorBadServerResponse
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

+ (BOOL)shouldRetryError:(NSError *)error response:(NSURLResponse *)response
{
    if (![error.domain isEqualToString:NSURLErrorDomain]) return NO;
    switch (error.code) {
        case NSURLErrorNetworkConnectionLost:
        case NSURLErrorTimedOut:
        case NSURLErrorNotConnectedToInternet:
        case NSURLErrorCannotConnectToHost:
        case NSURLErrorCannotFindHost:
        case NSURLErrorDNSLookupFailed:
            return YES;
        case NSURLErrorBadServerResponse: {
            if (![response isKindOfClass:NSHTTPURLResponse.class]) return NO;
            NSInteger status = [(NSHTTPURLResponse *)response statusCode];
            return status == 408 || status == 429 || status == 500 || status == 502 || status == 503 || status == 504;
        }
        default:
            return NO;
    }
}

+ (NSString *)partialFilenameForURL:(NSURL *)url
{
    NSData *key = [url.absoluteString dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(key.bytes, (CC_LONG)key.length, digest);
    NSMutableString *name = [NSMutableString string];
    for (NSUInteger i = 0; i < sizeof(digest); i++) [name appendFormat:@"%02x", digest[i]];
    return name;
}

+ (XEArchiveTransfer *)taskForRequest:(NSURLRequest *)request
                              directory:(NSString *)directory
                                  queue:(NSOperationQueue *)queue
                               progress:(void (^)(int64_t, int64_t))progress
                             completion:(void (^)(NSURL *, NSURLResponse *, NSError *))completion
                                  error:(NSError **)error
{
    if (![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:error]) {
        return nil;
    }
    XEArchiveTransfer *transfer = [self new];
    transfer->_file = [NSURL fileURLWithPath:[directory stringByAppendingPathComponent:[self partialFilenameForURL:request.URL]]];
    int fd = open(transfer->_file.fileSystemRepresentation, O_RDWR | O_CREAT | O_EXLOCK | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) {
        *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        return nil;
    }
    transfer->_handle = [[NSFileHandle alloc] initWithFileDescriptor:fd closeOnDealloc:YES];
    unsigned long long size;
    if (![transfer->_handle seekToEndReturningOffset:&size error:error]) return nil;
    transfer->_offset = (int64_t)size;

    NSMutableURLRequest *download = [request mutableCopy];
    [download setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
    if (size > 0) {
        char value[8192];
        ssize_t length = fgetxattr(fd, validatorAttribute, value, sizeof(value), 0, 0);
        if (length > 0) {
            transfer->_validator = [[NSString alloc] initWithBytes:value length:(NSUInteger)length encoding:NSUTF8StringEncoding];
        } else if (length < 0 && errno != ENOATTR) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
            return nil;
        }
        if (transfer->_validator != nil) {
            [download setValue:[NSString stringWithFormat:@"bytes=%llu-", size] forHTTPHeaderField:@"Range"];
            [download setValue:transfer->_validator forHTTPHeaderField:@"If-Range"];
        }
    }
    transfer->_progress = [progress copy];
    transfer->_completion = [completion copy];
    transfer->_request = [request copy];
    transfer->_session = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.defaultSessionConfiguration
                                                         delegate:transfer delegateQueue:queue];
    transfer->_task = [transfer->_session dataTaskWithRequest:download];
    return transfer;
}

- (void)resume
{
    @synchronized (self) { [_task resume]; }
}

- (void)cancel
{
    @synchronized (self) {
        _cancelled = YES;
        [_task cancel];
    }
}

- (BOOL)continueWithPhase:(XETransferPhase)phase
{
    _phase = phase;
    _nextRequest = [_request mutableCopy];
    [_nextRequest setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
    [_nextRequest setValue:nil forHTTPHeaderField:@"Range"];
    [_nextRequest setValue:nil forHTTPHeaderField:@"If-Range"];
    _nextRequest.HTTPMethod = phase == XETransferMetadata ? @"HEAD" : @"GET";
    return NO;
}

- (BOOL)acceptResponse:(NSHTTPURLResponse *)response
{
    NSString *etag = [response valueForHTTPHeaderField:@"ETag"];
    NSString *validator = [etag hasPrefix:@"\""] ? etag : [response valueForHTTPHeaderField:@"Last-Modified"];
    NSString *returnedValidator = [_validator hasPrefix:@"\""] ? etag : [response valueForHTTPHeaderField:@"Last-Modified"];
    NSString *range = [response valueForHTTPHeaderField:@"Content-Range"];
    if (_phase == XETransferMetadata && response.statusCode == 200) {
        if (response.expectedContentLength == _offset && [_validator isEqualToString:returnedValidator]) {
            _total = _offset;
            _completeResponse = response;
            return YES;
        }
        // Keep the saved bytes until a successful GET confirms the replacement.
        // HEAD can lack validators or be unsupported by a CDN.
        return [self continueWithPhase:XETransferFull];
    }
    if (_phase == XETransferMetadata && (response.statusCode == 405 || response.statusCode == 501)) {
        return [self continueWithPhase:XETransferFull];
    }
    if (response.statusCode == 416 && _validator != nil && _phase == XETransferRange) {
        long long length;
        int consumed = 0;
        BOOL hasLength = range != nil && sscanf(range.UTF8String, "bytes */%lld%n", &length, &consumed) == 1 &&
            consumed == (int)range.length && length >= 0;
        if (hasLength && length == _offset && [_validator isEqualToString:returnedValidator]) {
            // The response body describes the HTTP error. Deliver the archive on disk.
            _total = _offset;
            _completeResponse = response;
            return YES;
        }
        if (returnedValidator == nil) return [self continueWithPhase:XETransferMetadata];
        _error = transferError(@"The update server could not confirm the saved byte range.");
        if (hasLength && returnedValidator != nil &&
            (length < _offset || ![_validator isEqualToString:returnedValidator])) {
            NSError *truncateError = nil;
            if (![_handle truncateAtOffset:0 error:&truncateError]) _error = truncateError;
        }
        return NO;
    }
    NSString *encoding = [response valueForHTTPHeaderField:@"Content-Encoding"];
    if (encoding != nil && [encoding caseInsensitiveCompare:@"identity"] != NSOrderedSame) {
        _error = transferError(@"The update server returned an encoded archive.");
        return NO;
    }
    if (response.statusCode == 206) {
        long long start, end, total;
        int consumed = 0;
        if (_phase != XETransferRange || _validator == nil || range == nil ||
            sscanf(range.UTF8String, "bytes %lld-%lld/%lld%n", &start, &end, &total, &consumed) != 3 ||
            consumed != (int)range.length || start != _offset || total <= start || end != total - 1 ||
            (response.expectedContentLength >= 0 && response.expectedContentLength != total - start) ||
            (returnedValidator != nil && ![_validator isEqualToString:returnedValidator])) {
            _error = transferError(@"The update server returned an inconsistent byte range.");
            return NO;
        }
        _total = total;
        return YES;
    }
    if (response.statusCode != 200) {
        _error = transferError([NSString stringWithFormat:@"Update download returned HTTP %ld.", (long)response.statusCode]);
        return NO;
    }
    if (_offset > 0) {
        os_log(OS_LOG_DEFAULT, "Server sent a full update for a partial download; replacing the saved prefix.");
        NSError *truncateError = nil;
        if (![_handle truncateAtOffset:0 error:&truncateError]) {
            _error = truncateError;
            return NO;
        }
        _offset = 0;
    }
    NSData *value = [validator dataUsingEncoding:NSUTF8StringEncoding];
    int fd = _handle.fileDescriptor;
    if (value != nil) {
        if (fsetxattr(fd, validatorAttribute, value.bytes, value.length, 0, 0) != 0) {
            _error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
            return NO;
        }
    } else if (fremovexattr(fd, validatorAttribute, 0) != 0 && errno != ENOATTR) {
        _error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        return NO;
    }
    _total = response.expectedContentLength;
    return YES;
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler
{
    if (![response isKindOfClass:NSHTTPURLResponse.class]) {
        _error = transferError(@"The update server did not return an HTTP response.");
    }
    if (_error != nil || ![self acceptResponse:(NSHTTPURLResponse *)response]) {
        completionHandler(NSURLSessionResponseCancel);
        return;
    }
    _progress(_offset, _total);
    completionHandler(_completeResponse == nil ? NSURLSessionResponseAllow : NSURLSessionResponseCancel);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data
{
    if (_error != nil) return;
    NSError *writeError = nil;
    if (_total >= 0 && data.length > (uint64_t)(_total - _offset)) {
        _error = transferError(@"The update server sent more bytes than advertised.");
    } else if ([_handle writeData:data error:&writeError]) {
        _offset += data.length;
        _progress(_offset, _total);
        return;
    } else {
        _error = writeError;
    }
    [task cancel];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error
{
    @synchronized (self) {
        if (_nextRequest != nil && !_cancelled && (error == nil ||
            ([error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled))) {
            // Protocol recovery is part of this operation, not a failed attempt.
            // Keep the same file lock and cancellation handle across all steps.
            _task = [session dataTaskWithRequest:_nextRequest];
            _nextRequest = nil;
            [_task resume];
            return;
        }
        if (_cancelled) {
            _error = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil];
            _completeResponse = nil;
        }
        _task = nil;
    }
    NSError *failure = _error ?: error;
    NSURLResponse *response = task.response;
    if (_completeResponse != nil && (error == nil ||
        ([error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled))) {
        failure = nil;
        response = [[NSURLResponse alloc] initWithURL:task.originalRequest.URL MIMEType:@"application/octet-stream"
                                expectedContentLength:_total textEncodingName:nil];
    }
    if (failure == nil && _total >= 0 && _offset != _total) {
        failure = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNetworkConnectionLost
                                  userInfo:@{NSLocalizedDescriptionKey: @"The update download ended before the archive was complete."}];
    }
    // An error callback may immediately retry. On success the caller moves the
    // complete file to its own destination while we still hold the lock.
    if (failure != nil) _handle = nil;
    _completion(_file, response, failure);
    _handle = nil;
    [session finishTasksAndInvalidate];
    _session = nil;
}
@end
