#import <Cocoa/Cocoa.h>
#import "../src/CurlTaskRunner.h"
#import "../src/PWRCompat.h"

/* Phase 2: CurlTaskRunnerをGUI無しで単体テストするためのCLIツール。
 * 使い方: curl-test <URL>
 * 実際にモダンなcurlでTLS1.2/1.3サイトを取得できるかをG4実機で確認する。 */

@interface CurlTestDelegate : NSObject <CurlTaskRunnerDelegate>
{
@public
    BOOL finished;
    int exitCode;
}
@end

@implementation CurlTestDelegate

- (id)init {
    self = [super init];
    if (self) {
        finished = NO;
        exitCode = 0;
    }
    return self;
}

- (void)curlTaskRunner:(CurlTaskRunner *)runner didFinishWithData:(NSData *)data context:(id)context {
    unsigned int len = [data length];
    printf("=== 取得成功: %u バイト ===\n", len);

    NSString *preview = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
    if (!preview) {
        preview = PWRJPStr("(UTF-8として解釈できないデータでした。バイナリの可能性があります)");
    }
    unsigned int strLen = [preview length];
    unsigned int showLen = strLen < 500 ? strLen : 500;
    printf("--- 先頭%u文字のプレビュー ---\n%s\n", showLen, [[preview substringToIndex:showLen] UTF8String]);

    finished = YES;
    exitCode = 0;
}

- (void)curlTaskRunner:(CurlTaskRunner *)runner didFailWithError:(NSString *)message context:(id)context {
    fprintf(stderr, "=== 取得失敗: %s ===\n", [message UTF8String]);
    finished = YES;
    exitCode = 1;
}

@end

int main(int argc, const char *argv[]) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    if (argc < 2) {
        fprintf(stderr, "使い方: %s <URL>\n", argv[0]);
        [pool release];
        return 1;
    }

    NSString *curlPath = [CurlTaskRunner detectCurlPath];
    if (curlPath) {
        printf("使用するcurl: %s\n", [curlPath UTF8String]);
    } else {
        printf("警告: モダンなcurlが見つかりません。システム標準curlはTLSが古く失敗する可能性があります。\n");
    }

    NSURL *url = [NSURL URLWithString:[NSString stringWithUTF8String:argv[1]]];
    CurlTestDelegate *delegate = [[CurlTestDelegate alloc] init];
    CurlTaskRunner *runner = [[CurlTaskRunner alloc] initWithDelegate:delegate];

    [runner fetchURL:url context:nil];

    while (!delegate->finished) {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }

    {
        int code = delegate->exitCode;
        [runner release];
        [delegate release];
        [pool release];
        return code;
    }
}
