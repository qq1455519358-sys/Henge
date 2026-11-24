// Runs inside macOS on a Henge virtual Mac, as a LaunchAgent. It keeps the clipboard in step with the device,
// keeps the shared folder (and any external USB drive at ~/Henge/External) mounted, and shows live physical
// host battery, charging, thermal, and Wi-Fi status in the macOS menu bar.
#import <AppKit/AppKit.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>

#define HOST "10.0.2.4"

static int send_all(int fd, const void *p, size_t n) {
    const char *c = p;
    while (n) {
        ssize_t w = send(fd, c, n, 0);
        if (w <= 0) return -1;
        c += w, n -= (size_t)w;
    }
    return 0;
}

// One request on its own connection. A plain socket: the server is ours, and URLSession refuses plain HTTP.
static NSData *request(NSString *method, NSString *path, NSData *body, int *status, unsigned long *seq) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return nil;
    struct timeval timeout = {.tv_sec = 40};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof timeout);
    int on = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on);
    struct sockaddr_in addr = {.sin_family = AF_INET, .sin_port = htons(80)};
    inet_pton(AF_INET, HOST, &addr.sin_addr);
    if (connect(fd, (struct sockaddr *)&addr, sizeof addr) != 0) {
        close(fd);
        return nil;
    }
    NSString *head = [NSString stringWithFormat:@"%@ %@ HTTP/1.1\r\nHost: " HOST "\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n", method, path,
                                                (unsigned long)body.length];
    const char *text = head.UTF8String;
    if (send_all(fd, text, strlen(text)) != 0 || (body.length && send_all(fd, body.bytes, body.length) != 0)) {
        close(fd);
        return nil;
    }
    NSMutableData *all = [NSMutableData data];
    char piece[16384];
    for (;;) {
        ssize_t got = recv(fd, piece, sizeof piece, 0);
        if (got <= 0) break;
        [all appendBytes:piece length:(NSUInteger)got];
    }
    close(fd);
    NSRange end = [all rangeOfData:[NSData dataWithBytes:"\r\n\r\n" length:4] options:0 range:NSMakeRange(0, all.length)];
    if (end.location == NSNotFound) return nil;
    NSString *headers = [[NSString alloc] initWithData:[all subdataWithRange:NSMakeRange(0, end.location)] encoding:NSUTF8StringEncoding];
    if (sscanf(headers.UTF8String, "HTTP/1.1 %d", status) != 1) return nil;
    NSRange found = [headers rangeOfString:@"X-Henge-Seq: "];
    if (found.location != NSNotFound && seq) *seq = strtoul(headers.UTF8String + NSMaxRange(found), NULL, 10);
    NSUInteger start = NSMaxRange(end);
    return [all subdataWithRange:NSMakeRange(start, all.length - start)];
}

static NSInteger lastChange;
static NSString *mountPoint(void) { return [NSHomeDirectory() stringByAppendingPathComponent:@"Henge"]; }

// The device's clipboard, as it changes. The server holds each request until there is something new.
static void followDevice(void) {
    unsigned long seq = 0;
    for (BOOL first = YES;; first = NO) {
        int status = 0;
        unsigned long now = seq;
        NSData *body = request(@"GET", [NSString stringWithFormat:@"/.henge/clipboard?since=%lu", first ? ULONG_MAX >> 1 : seq], nil, &status, &now);
        if (!body) {
            sleep(5);
            continue;
        }
        BOOL news = !first && status == 200 && now != seq;
        seq = now;
        if (!news) continue;
        NSString *text = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
        if (!text) continue;
        dispatch_async(dispatch_get_main_queue(), ^{
            NSPasteboard *board = NSPasteboard.generalPasteboard;
            [board clearContents];
            [board setString:text forType:NSPasteboardTypeString];
            lastChange = board.changeCount;
        });
    }
}

// The Mac's clipboard goes to the device, unless the app that copied it marked it as secret.
static void checkClipboard(void) {
    NSPasteboard *board = NSPasteboard.generalPasteboard;
    if (board.changeCount == lastChange) return;
    lastChange = board.changeCount;
    if ([board.types containsObject:@"org.nspasteboard.ConcealedType"]) return;
    NSString *text = [board stringForType:NSPasteboardTypeString];
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (!data.length) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        int status = 0;
        request(@"PUT", @"/.henge/clipboard", data, &status, NULL);
    });
}

// The shared folder, at ~/Henge. mount_webdav needs an empty folder it owns, and is a no-op failure if it is mounted.
static void keepMounted(void) {
    NSString *point = mountPoint();
    [NSFileManager.defaultManager createDirectoryAtPath:point withIntermediateDirectories:YES attributes:nil error:NULL];
    struct stat folder, parent;
    if (stat(point.fileSystemRepresentation, &folder) != 0 || stat(NSHomeDirectory().fileSystemRepresentation, &parent) != 0) return;
    if (folder.st_dev != parent.st_dev) return; // already something else's volume: mounted
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/sbin/mount_webdav"];
    task.arguments = @[ @"-S", @"-v", @"Henge", @"http://" HOST "/", point ];
    task.standardOutput = NSFileHandle.fileHandleWithNullDevice;
    task.standardError = NSFileHandle.fileHandleWithNullDevice;
    [task launchAndReturnError:NULL];
}

@interface HengeMenuController : NSObject
@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) NSMenuItem *hostItem;
@property (nonatomic, strong) NSMenuItem *networkItem;
@property (nonatomic, strong) NSMenuItem *thermalItem;
@property (nonatomic, strong) NSMenuItem *externalInfoItem;
@property (nonatomic, strong) NSMenuItem *openExternalItem;
- (void)setup;
- (void)refreshStatus;
@end

@implementation HengeMenuController

- (void)setup {
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.title = @"iPad";
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Henge Host"];
    menu.autoenablesItems = NO;

    self.hostItem = [[NSMenuItem alloc] initWithTitle:@"Host: Connecting…" action:nil keyEquivalent:@""];
    self.hostItem.enabled = NO;
    [menu addItem:self.hostItem];

    self.networkItem = [[NSMenuItem alloc] initWithTitle:@"Network: —" action:nil keyEquivalent:@""];
    self.networkItem.enabled = NO;
    [menu addItem:self.networkItem];

    self.thermalItem = [[NSMenuItem alloc] initWithTitle:@"Thermal: Normal" action:nil keyEquivalent:@""];
    self.thermalItem.enabled = NO;
    [menu addItem:self.thermalItem];

    self.externalInfoItem = [[NSMenuItem alloc] initWithTitle:@"External Drive: Not mounted" action:nil keyEquivalent:@""];
    self.externalInfoItem.enabled = NO;
    [menu addItem:self.externalInfoItem];

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *openShared = [[NSMenuItem alloc] initWithTitle:@"Open Shared Folder (~/Henge)" action:@selector(openSharedFolder:) keyEquivalent:@""];
    openShared.target = self;
    openShared.enabled = YES;
    [menu addItem:openShared];

    self.openExternalItem = [[NSMenuItem alloc] initWithTitle:@"Open External USB Drive (~/Henge/External)" action:@selector(openExternalDrive:) keyEquivalent:@""];
    self.openExternalItem.target = self;
    self.openExternalItem.enabled = NO;
    [menu addItem:self.openExternalItem];

    self.statusItem.menu = menu;
}

- (void)openSharedFolder:(id)sender {
    (void)sender;
    [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:mountPoint()]];
}

- (void)openExternalDrive:(id)sender {
    (void)sender;
    NSString *ext = [mountPoint() stringByAppendingPathComponent:@"External"];
    [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:ext]];
}

- (void)refreshStatus {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        int status = 0;
        NSData *body = request(@"GET", @"/.henge/status", nil, &status, NULL);
        if (!body || status != 200) return;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:body options:0 error:NULL];
        if (![json isKindOfClass:[NSDictionary class]]) return;
        NSNumber *batNum = json[@"battery"];
        BOOL charging = [json[@"charging"] boolValue];
        NSString *device = [json[@"device"] isKindOfClass:[NSString class]] ? json[@"device"] : @"iPad";
        NSString *net = [json[@"network"] isKindOfClass:[NSString class]] ? json[@"network"] : @"Online";
        NSString *ip = [json[@"ip"] isKindOfClass:[NSString class]] ? json[@"ip"] : @"";
        NSString *thermal = [json[@"thermal"] isKindOfClass:[NSString class]] ? json[@"thermal"] : @"Normal";
        NSString *ext = [json[@"external"] isKindOfClass:[NSString class]] ? json[@"external"] : @"";

        dispatch_async(dispatch_get_main_queue(), ^{
            int pct = batNum ? batNum.intValue : -1;
            if (pct >= 0) {
                self.statusItem.button.title = [NSString stringWithFormat:@"iPad %d%%%@", pct, charging ? @" ⚡" : @""];
                self.hostItem.title = [NSString stringWithFormat:@"%@ · Battery %d%%%@", device, pct, charging ? @" (Charging)" : @""];
            } else {
                self.statusItem.button.title = @"iPad";
                self.hostItem.title = device;
            }
            self.networkItem.title = ip.length ? [NSString stringWithFormat:@"Network: %@ (%@)", net, ip]
                                               : [NSString stringWithFormat:@"Network: %@", net];
            self.thermalItem.title = [NSString stringWithFormat:@"Thermal: %@", thermal];
            if (ext.length) {
                self.externalInfoItem.title = [NSString stringWithFormat:@"External Drive: %@", ext];
                self.openExternalItem.enabled = YES;
            } else {
                self.externalInfoItem.title = @"External Drive: Not mounted";
                self.openExternalItem.enabled = NO;
            }
        });
    });
}

@end

int main(void) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        HengeMenuController *menuCtrl = [HengeMenuController new];
        [menuCtrl setup];
        [menuCtrl refreshStatus];

        lastChange = NSPasteboard.generalPasteboard.changeCount;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ followDevice(); });
        keepMounted();

        NSTimer *clipTimer = [NSTimer timerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) { (void)timer; checkClipboard(); }];
        NSTimer *mountTimer = [NSTimer timerWithTimeInterval:30 repeats:YES block:^(NSTimer *timer) { (void)timer; keepMounted(); }];
        NSTimer *statusTimer = [NSTimer timerWithTimeInterval:8 repeats:YES block:^(NSTimer *timer) { (void)timer; [menuCtrl refreshStatus]; }];
        [NSRunLoop.mainRunLoop addTimer:clipTimer forMode:NSRunLoopCommonModes];
        [NSRunLoop.mainRunLoop addTimer:mountTimer forMode:NSRunLoopCommonModes];
        [NSRunLoop.mainRunLoop addTimer:statusTimer forMode:NSRunLoopCommonModes];
        [app run];
    }
    return 0;
}
