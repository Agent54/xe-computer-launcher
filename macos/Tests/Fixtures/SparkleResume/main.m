#import <Foundation/Foundation.h>
#import <Sparkle/Sparkle.h>
#import "SPUDownloaderProtocol.h"
#import "SPUDownloaderDelegate.h"

@interface Client : NSObject <SPUDownloaderDelegate>
@property (copy) NSURL *archive;
@property (copy) NSString *output;
@property uint64_t received, checkpoint;
@property int64_t expected;
@property (strong) id<SPUDownloaderProtocol> downloader;
@end

@implementation Client
- (void)downloaderDidReceiveExpectedContentLength:(int64_t)length { self.expected = length; }
- (void)downloaderDidReceiveDataOfLength:(uint64_t)length
{
    self.received += length;
    if (!self.checkpoint) {
        printf("%llu\n", self.received);
        fflush(stdout);
    }
    if (self.checkpoint && self.received == self.checkpoint) {
        puts("received");
        fflush(stdout);
        [self.downloader cleanup:^{ exit(2); }];
    }
}
- (void)downloaderDidSetDownloadBookmarkData:(NSData *)bookmark downloadToken:(NSString *)token
{
    self.archive = [NSURL URLByResolvingBookmarkData:bookmark options:0 relativeToURL:nil bookmarkDataIsStale:NULL error:NULL];
}
- (void)downloaderDidFinishWithTemporaryDownloadData:(SPUDownloadData *)data
{
    NSError *error = nil;
    if (self.expected <= 0 || self.received != (uint64_t)self.expected) exit(1);
    if (![NSFileManager.defaultManager copyItemAtURL:self.archive toURL:[NSURL fileURLWithPath:self.output] error:&error]) {
        NSLog(@"Archive copy failed: %@", error);
        exit(1);
    }
    exit(0);
}
- (void)downloaderDidFailWithError:(NSError *)error
{
    NSLog(@"Download interrupted: %@", error.localizedDescription);
    exit(2);
}
@end

// Exercise Sparkle's actual choice of delta vs. full enclosure and stop at the
// public download-complete callback, before a fixture archive could be installed.
@interface DeltaDriver : SPUStandardUserDriver <SPUUpdaterDelegate>
@property (copy) NSString *feed;
@property uint64_t received;
@end

@implementation DeltaDriver
- (NSString *)feedURLStringForUpdater:(SPUUpdater *)updater { return self.feed; }
- (void)showUserInitiatedUpdateCheckWithCancellation:(void (^)(void))cancel {}
- (void)showUpdateFoundWithAppcastItem:(SUAppcastItem *)item state:(SPUUserUpdateState *)state reply:(void (^)(SPUUserUpdateChoice))reply {
    reply(SPUUserUpdateChoiceInstall);
}
- (void)showDownloadInitiatedWithCancellation:(void (^)(void))cancel {}
- (void)showDownloadDidReceiveExpectedContentLength:(uint64_t)length {}
- (void)showDownloadDidReceiveDataOfLength:(uint64_t)length {
    self.received += length;
    printf("%llu\n", self.received);
    fflush(stdout);
}
- (void)updater:(SPUUpdater *)updater willDownloadUpdate:(SUAppcastItem *)item withRequest:(NSMutableURLRequest *)request {
    if (!item.isDeltaUpdate) { NSLog(@"Sparkle selected the full archive"); exit(1); }
}
- (void)updater:(SPUUpdater *)updater didDownloadUpdate:(SUAppcastItem *)item {
    exit(item.isDeltaUpdate && self.received == item.contentLength ? 0 : 1);
}
- (void)showUpdaterError:(NSError *)error acknowledgement:(void (^)(void))reply { NSLog(@"%@", error); exit(1); }
@end

int main(int argc, const char *argv[])
{
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ exit(1); });
    if (argc == 2) {
        NSBundle *host = NSBundle.mainBundle;
        DeltaDriver *driver = [[DeltaDriver alloc] initWithHostBundle:host delegate:nil];
        driver.feed = @(argv[1]);
        __attribute__((objc_precise_lifetime)) SPUUpdater *updater = [[SPUUpdater alloc] initWithHostBundle:host applicationBundle:host userDriver:driver delegate:driver];
        NSError *error = nil;
        if (![updater startUpdater:&error]) { NSLog(@"%@", error); return 1; }
        [updater checkForUpdates];
        [NSRunLoop.currentRunLoop run];
        return 1;
    }
    if (argc != 5) return 1;
    Client *client = [Client new];
    client.output = @(argv[3]);
    client.checkpoint = strtoull(argv[4], NULL, 10);
    NSXPCConnection *connection = [[NSXPCConnection alloc] initWithServiceName:@"org.sparkle-project.DownloaderService"];
    connection.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:@protocol(SPUDownloaderProtocol)];
    connection.exportedInterface = [NSXPCInterface interfaceWithProtocol:@protocol(SPUDownloaderDelegate)];
    connection.exportedObject = client;
    [connection resume];
    id<SPUDownloaderProtocol> downloader = [connection remoteObjectProxyWithErrorHandler:^(NSError *error) {
        NSLog(@"Downloader XPC connection failed: %@", error);
        exit(1);
    }];
    client.downloader = downloader;
    NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:@(argv[1])]];
    [downloader startPersistentDownloadWithRequest:request bundleIdentifier:@(argv[2]) desiredFilename:@"Fixture"];
    [[NSRunLoop currentRunLoop] run];
    return 1;
}
