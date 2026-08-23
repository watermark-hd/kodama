#import <Cocoa/Cocoa.h>

/*
 * Phase 0: ツールチェーン疎通確認用の最小Cocoaアプリ。
 * nibを使わずコードだけでウィンドウを1枚出す。
 * G4実機でこれがビルド・起動できれば、gcc/ldでのCocoaリンクが
 * 正常に機能していることが確認できる。
 */
int main(int argc, const char *argv[]) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    NSApplication *app = [NSApplication sharedApplication];

    NSRect frame = NSMakeRect(100, 100, 800, 600);
    unsigned int styleMask = NSTitledWindowMask | NSClosableWindowMask |
                              NSMiniaturizableWindowMask | NSResizableWindowMask;
    NSWindow *window = [[NSWindow alloc] initWithContentRect:frame
                                                     styleMask:styleMask
                                                       backing:NSBackingStoreBuffered
                                                         defer:NO];
    [window setTitle:@"PPC-WebReader (Phase 0)"];
    [window makeKeyAndOrderFront:nil];

    [app activateIgnoringOtherApps:YES];
    [app run];

    [pool release];
    return 0;
}
