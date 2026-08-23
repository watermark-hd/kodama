#import <Cocoa/Cocoa.h>
#import "../src/HTMLParserEngine.h"

/* Phase 1: HTMLParserEngineをGUI無しで単体テストするためのCLIツール。
 * 使い方: parse-test <HTMLファイルパス> [ベースURL] */
int main(int argc, const char *argv[]) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    if (argc < 2) {
        fprintf(stderr, "使い方: %s <HTMLファイルパス> [ベースURL]\n", argv[0]);
        [pool release];
        return 1;
    }

    NSString *filePath = [NSString stringWithUTF8String:argv[1]];
    NSData *htmlData = [NSData dataWithContentsOfFile:filePath];
    if (!htmlData) {
        fprintf(stderr, "ファイルを読み込めませんでした: %s\n", argv[1]);
        [pool release];
        return 1;
    }

    NSURL *baseURL;
    if (argc >= 3) {
        baseURL = [NSURL URLWithString:[NSString stringWithUTF8String:argv[2]]];
    } else {
        baseURL = [NSURL fileURLWithPath:filePath];
    }

    PWRParsedPage *page = [HTMLParserEngine parsePageFromData:htmlData baseURL:baseURL];
    if (!page) {
        fprintf(stderr, "HTMLのパースに失敗しました\n");
        [pool release];
        return 1;
    }

    printf("=== 見出し一覧 (%lu 件) ===\n", (unsigned long)[[page headings] count]);
    {
        NSEnumerator *e = [[page headings] objectEnumerator];
        PWRHeading *h;
        while ((h = [e nextObject])) {
            NSURL *link = [h linkURL];
            printf("H%d [pos %u] %s%s%s\n", [h level], [h bodyLocation], [[h title] UTF8String],
                   link ? "  -> " : "", link ? [[link absoluteString] UTF8String] : "");
        }
    }

    printf("\n=== 本文 ===\n%s\n", [[[page bodyText] string] UTF8String]);

    printf("\n=== 画像一覧 (%lu 件) ===\n", (unsigned long)[[page imageURLs] count]);
    {
        NSEnumerator *e = [[page imageURLs] objectEnumerator];
        NSURL *u;
        int idx = 1;
        while ((u = [e nextObject])) {
            printf("[%d] %s\n", idx++, [[u absoluteString] UTF8String]);
        }
    }

    [pool release];
    return 0;
}
