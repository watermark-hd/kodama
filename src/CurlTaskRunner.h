#import <Cocoa/Cocoa.h>

/*
 * curlバイナリをNSTask経由で起動し、非同期でURLを取得するクラス。
 * OS X 10.4標準のNSURLConnectionは現代のTLS1.2/1.3ハンドシェイクに
 * 失敗するため、MacPorts等で導入したモダンなcurlバイナリに丸投げする。
 *
 * このgcc(4.0.0)にはblocks/GCDが無いため、NSTaskDidTerminateNotification
 * と NSFileHandleReadCompletionNotification によるdelegateコールバック
 * パターンで非同期化する。
 *
 * 1回のfetchURL:context:呼び出しにつき1つのインスタンスを使うこと
 * (内部でNSTask/NSPipeの状態を1リクエスト分だけ保持する設計)。
 * 非同期処理が完了するまでは自分自身を保持(retain)するため、
 * 呼び出し側が参照を捨てても問題ない。
 */

@class CurlTaskRunner;

@protocol CurlTaskRunnerDelegate
- (void)curlTaskRunner:(CurlTaskRunner *)runner didFinishWithData:(NSData *)data context:(id)context;
- (void)curlTaskRunner:(CurlTaskRunner *)runner didFailWithError:(NSString *)message context:(id)context;
@end

@interface CurlTaskRunner : NSObject
{
    id<CurlTaskRunnerDelegate> delegate;
    NSTask *task;
    NSMutableData *receivedData;
    NSURL *requestURL;
    id requestContext;
    BOOL didTerminate;
    BOOL didReachEOF;
    int terminationStatus;

    NSString *headerFilePath;
    NSString *responseContentType;
    NSString *responseSuggestedFilename;
    BOOL responseIsAttachment;
}

/* 使えるcurlバイナリのパスを探す。優先順位は
 *   1. アプリ同梱版(Contents/Resources/curl、LibreSSL静的リンク)
 *   2. /opt/local/bin/curl (MacPorts)
 *   3. /usr/local/bin/curl (Tigerbrew/手動)
 *   4. Tigerbrewのportable-curl
 * 見つからなければnilを返す(通常は同梱版があるので発生しない)。 */
+ (NSString *)detectCurlPath;

- (id)initWithDelegate:(id<CurlTaskRunnerDelegate>)aDelegate;

/* 非同期でURLを取得する。完了/失敗はdelegateに通知される。 */
- (void)fetchURL:(NSURL *)url context:(id)context;

/* 取得完了後(didFinishWithData:context:内)でのみ有効。
 * レスポンスがHTMLページではなくファイルダウンロードらしいかどうかを、
 * Content-Disposition: attachment / Content-Typeから判定する。
 * URLの拡張子だけでは/download/kodamaのような拡張子なしのダウンロード
 * ルートを判定できないため、実際のレスポンスヘッダを見て決める。 */
- (BOOL)responseLooksLikeDownload;

/* Content-Dispositionのfilenameから取得したファイル名。無ければnil。 */
- (NSString *)responseSuggestedFilename;

@end
