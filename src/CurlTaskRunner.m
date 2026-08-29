#import "CurlTaskRunner.h"
#import "PWRCompat.h"
#import "PWRLocalization.h"

@interface CurlTaskRunner (PWRPrivate)
- (void)finalizeIfReady;
- (void)parseResponseHeaders;
+ (NSString *)bundledCurlPath;
+ (NSString *)bundledCABundlePath;
@end

@implementation CurlTaskRunner

/* アプリに同梱したcurl(LibreSSL静的リンク・モダンTLS対応)のパス。
 * 実行権限が無い/存在しない場合はnil。GUI無しのCLIテスト時は
 * mainBundleにResourcesが無いため自然にnilになりシステム探索へ回る。 */
+ (NSString *)bundledCurlPath {
    NSString *path = [[NSBundle mainBundle] pathForResource:@"curl" ofType:nil];
    if (path && [[NSFileManager defaultManager] isExecutableFileAtPath:path]) {
        return path;
    }
    return nil;
}

/* 同梱curlに渡すCA証明書(cacert.pem)のパス。無ければnil。 */
+ (NSString *)bundledCABundlePath {
    NSString *path = [[NSBundle mainBundle] pathForResource:@"cacert" ofType:@"pem"];
    if (path && [[NSFileManager defaultManager] isReadableFileAtPath:path]) {
        return path;
    }
    return nil;
}

+ (NSString *)detectCurlPath {
    NSFileManager *fm = [NSFileManager defaultManager];

    /* まず同梱版を優先。Tiger素の環境(MacPorts/Tigerbrew無し)でも
     * 「ダウンロードして起動するだけ」で動かすため。 */
    NSString *bundled = [self bundledCurlPath];
    if (bundled) {
        return bundled;
    }

    NSArray *candidates = [NSArray arrayWithObjects:
        @"/opt/local/bin/curl",   /* MacPorts */
        @"/usr/local/bin/curl",   /* Tigerbrew(brew install curl)/手動インストール */
        nil];
    NSEnumerator *e = [candidates objectEnumerator];
    NSString *path;
    while ((path = [e nextObject])) {
        if ([fm isExecutableFileAtPath:path]) {
            return path;
        }
    }

    /* Tigerbrewが`brew doctor`実行時などに自前で取得する「ポータブルcurl」。
     * バージョン番号を含むディレクトリ名なので固定パスにせず走査する
     * (例: .../vendor/portable-curl/7.58.0-1/bin/curl) */
    NSString *vendorDir = @"/usr/local/Library/Homebrew/vendor/portable-curl";
    NSArray *versions = [fm directoryContentsAtPath:vendorDir];
    NSEnumerator *ve = [versions objectEnumerator];
    NSString *version;
    while ((version = [ve nextObject])) {
        NSString *candidate = [[vendorDir stringByAppendingPathComponent:version]
                                stringByAppendingPathComponent:@"bin/curl"];
        if ([fm isExecutableFileAtPath:candidate]) {
            return candidate;
        }
    }

    return nil;
}

- (id)initWithDelegate:(id<CurlTaskRunnerDelegate>)aDelegate {
    self = [super init];
    if (self) {
        delegate = aDelegate; /* weak参照。呼び出し側が生存を管理する */
    }
    return self;
}

- (void)dealloc {
    [task release];
    [receivedData release];
    [requestURL release];
    [requestContext release];
    [headerFilePath release];
    [responseContentType release];
    [responseSuggestedFilename release];
    [super dealloc];
}

- (void)fetchURL:(NSURL *)url context:(id)context {
    NSString *curlPath = [CurlTaskRunner detectCurlPath];
    if (!curlPath) {
        NSString *msg = PWRL(@"curlNotFound");
        [delegate curlTaskRunner:self didFailWithError:msg context:context];
        return;
    }

    requestURL = [url retain];
    requestContext = [context retain];
    receivedData = [[NSMutableData alloc] init];
    didTerminate = NO;
    didReachEOF = NO;
    terminationStatus = 0;

    /* レスポンスヘッダ(Content-Type/Content-Disposition)をファイルに
     * 書き出させる。標準出力(本文データ)とは別ファイルにすることで、
     * バイナリの本文データにヘッダ文字列が混入するのを避ける。 */
    headerFilePath = [[NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"kodama-headers-%@", [[NSProcessInfo processInfo] globallyUniqueString]]] retain];

    task = [[NSTask alloc] init];
    [task setLaunchPath:curlPath];

    NSMutableArray *args = [NSMutableArray arrayWithObjects:
        @"-sS",                 /* サイレント、ただしエラーは表示 */
        @"-L",                  /* リダイレクト追跡 */
        @"-D", headerFilePath,  /* レスポンスヘッダの書き出し先 */
        @"--max-time", @"30",
        /* サイト側の「対応ブラウザではありません」的な出し分け・警告を
         * 避けるため、モダンなFirefoxを名乗る。ダウンロード判定は
         * レスポンスヘッダ(Content-Disposition/Content-Type)ベースで
         * UAには依存しないため、この偽装が既存機能に影響することはない。 */
        @"-A", @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:109.0) Gecko/20100101 Firefox/121.0",
        nil];

    /* 同梱版curlを使う場合は、システムにCA証明書ストアが無い
     * (Tiger素の環境)可能性が高いので同梱のcacert.pemを明示的に渡す。
     * MacPorts/Tigerbrew等のシステムcurlにフォールバックした場合は、
     * そちら側のCAストアを尊重して--cacertは渡さない。 */
    if ([curlPath isEqualToString:[CurlTaskRunner bundledCurlPath]]) {
        NSString *caBundle = [CurlTaskRunner bundledCABundlePath];
        if (caBundle) {
            [args addObject:@"--cacert"];
            [args addObject:caBundle];
        }
    }

    [args addObject:[url absoluteString]];
    [task setArguments:args];

    NSPipe *outPipe = [NSPipe pipe];
    [task setStandardOutput:outPipe];
    [task setStandardError:[NSPipe pipe]]; /* エラーメッセージは今は破棄 */

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self
           selector:@selector(dataAvailable:)
               name:NSFileHandleReadCompletionNotification
             object:[outPipe fileHandleForReading]];
    [nc addObserver:self
           selector:@selector(taskTerminated:)
               name:NSTaskDidTerminateNotification
             object:task];

    /* 非同期処理が終わるまで自分自身を生かしておく(手動retain管理)。
     * finalizeIfReadyで対になるautoreleaseを呼ぶ。 */
    [self retain];

    [[outPipe fileHandleForReading] readInBackgroundAndNotify];
    [task launch];
}

- (void)dataAvailable:(NSNotification *)note {
    NSData *data = [[note userInfo] objectForKey:NSFileHandleNotificationDataItem];
    if ([data length] > 0) {
        [receivedData appendData:data];
        [[note object] readInBackgroundAndNotify];
    } else {
        /* 空データ = パイプのEOF。curlが全出力を書き終えたことを意味する */
        didReachEOF = YES;
        [self finalizeIfReady];
    }
}

- (void)taskTerminated:(NSNotification *)note {
    didTerminate = YES;
    terminationStatus = [task terminationStatus];
    [self finalizeIfReady];
}

/* タスク終了とパイプEOFの両方が揃うまで待つ。
 * 順序はOSやタイミングに依存するため、どちらか片方だけでは
 * 確定させない(取りこぼし・競合を避けるための待ち合わせ)。 */
- (void)finalizeIfReady {
    if (!didTerminate || !didReachEOF) {
        return;
    }

    [[NSNotificationCenter defaultCenter] removeObserver:self];

    if (terminationStatus == 0) {
        [self parseResponseHeaders];
        [delegate curlTaskRunner:self didFinishWithData:receivedData context:requestContext];
    } else {
        NSString *msg = [NSString stringWithFormat:PWRL(@"curlFailedFormat"), terminationStatus];
        [delegate curlTaskRunner:self didFailWithError:msg context:requestContext];
    }

    [self autorelease];
}

/* -Dで書き出させたヘッダファイルを読み、Content-Type/Content-Dispositionを
 * 拾う。-Lでリダイレクトを辿った場合はホップごとのヘッダが連続して
 * 書き込まれるため、後方のブロックほど上書きすることで最終レスポンスの
 * 値を採用する。 */
- (void)parseResponseHeaders {
    if (!headerFilePath) {
        return;
    }
    NSString *headerText = [NSString stringWithContentsOfFile:headerFilePath
                                                        encoding:NSUTF8StringEncoding
                                                           error:NULL];
    [[NSFileManager defaultManager] removeFileAtPath:headerFilePath handler:nil];

    if (!headerText) {
        return;
    }

    NSArray *lines = [headerText componentsSeparatedByString:@"\n"];
    NSEnumerator *le = [lines objectEnumerator];
    NSString *line;
    while ((line = [le nextObject])) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *lower = [trimmed lowercaseString];

        if ([lower hasPrefix:@"content-type:"]) {
            NSString *value = [trimmed substringFromIndex:[@"content-type:" length]];
            [responseContentType release];
            responseContentType = [[value stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]] retain];
        } else if ([lower hasPrefix:@"content-disposition:"]) {
            responseIsAttachment = ([lower rangeOfString:@"attachment"].location != NSNotFound);

            NSRange filenameRange = [trimmed rangeOfString:@"filename=" options:NSCaseInsensitiveSearch];
            if (filenameRange.location != NSNotFound) {
                NSString *filenamePart = [trimmed substringFromIndex:NSMaxRange(filenameRange)];
                NSRange semiRange = [filenamePart rangeOfString:@";"];
                if (semiRange.location != NSNotFound) {
                    filenamePart = [filenamePart substringToIndex:semiRange.location];
                }
                filenamePart = [filenamePart stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceAndNewlineCharacterSet]];
                filenamePart = [filenamePart stringByTrimmingCharactersInSet:
                    [NSCharacterSet characterSetWithCharactersInString:@"\""]];
                [responseSuggestedFilename release];
                responseSuggestedFilename = [filenamePart retain];
            }
        }
    }
}

- (BOOL)responseLooksLikeDownload {
    if (responseIsAttachment) {
        return YES;
    }
    if (!responseContentType) {
        /* ヘッダが取れなかった場合は従来通りHTMLとして扱う(安全側) */
        return NO;
    }
    NSString *ct = [responseContentType lowercaseString];
    if ([ct hasPrefix:@"text/"] ||
        [ct rangeOfString:@"html"].location != NSNotFound ||
        [ct rangeOfString:@"xml"].location != NSNotFound) {
        return NO;
    }
    return YES;
}

- (NSString *)responseSuggestedFilename {
    return responseSuggestedFilename;
}

@end
