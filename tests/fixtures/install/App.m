#import <AppKit/AppKit.h>

int main(void) {
    @autoreleasepool {
        NSBundle *bundle = NSBundle.mainBundle;
        NSString *version = [bundle objectForInfoDictionaryKey:@"CFBundleVersion"];
        if ([version isEqual:@"3"]) return 3;
        BOOL hang = [version isEqual:@"4"];
        NSString *dir = bundle.bundlePath.stringByDeletingLastPathComponent;
        NSString *marker = [dir stringByAppendingPathComponent:hang ? @"hung.pid" : @"running.pid"];
        NSString *pid = [NSString stringWithFormat:@"%d", NSProcessInfo.processInfo.processIdentifier];
        [pid writeToFile:marker atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        if (hang) {
            [NSApplication sharedApplication];
            [NSThread sleepForTimeInterval:60];
            return 4;
        }
        NSTask *daemon = [[NSTask alloc] init];
        daemon.executableURL = [NSURL fileURLWithPath:@"/usr/bin/python3"];
        daemon.arguments = @[[bundle.resourcePath stringByAppendingPathComponent:@"agentdeckd.py"]];
        if (![daemon launchAndReturnError:NULL]) return 5;
        [NSApplication.sharedApplication run];
    }
}
