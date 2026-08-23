#import <Cocoa/Cocoa.h>
#import "CurlTaskRunner.h"
#import "HTMLParserEngine.h"

/*
 * 3ペインUI(左:見出しナビ/中央:本文/右:画像プレビュー)を
 * nib無し・コードだけで組み立てるアプリ本体。
 * NSApplicationのdelegateとして動作する。
 *
 * 右ペインは既定で幅0(折りたたみ)。画像リンクをクリックした時だけ
 * 展開し、別の画像をクリックしても閉じずに中身だけ差し替える。
 * 新しいページを読み込んだ時と手動の「隠す」ボタンでのみ閉じる。
 */

@interface AppController : NSObject <CurlTaskRunnerDelegate>
{
    NSWindow *window;

    NSView *topBarView;
    NSButton *backButton;
    NSTextField *urlField;
    NSButton *openButton;

    NSMutableArray *navigationHistory; /* 戻る用: 訪問済みURLのスタック */

    NSSplitView *splitView;

    NSScrollView *leftScrollView;
    NSTableView *headingTableView;
    NSTableColumn *headingColumn;

    NSScrollView *centerScrollView;
    NSTextView *bodyTextView;

    NSView *rightContainerView;
    NSButton *hideImageButton;
    NSScrollView *rightScrollView;
    NSImageView *imageView;

    NSMenuItem *quitMenuItem;
    NSMenuItem *languageMenuItem;
    NSMenuItem *japaneseMenuItem;
    NSMenuItem *englishMenuItem;

    PWRParsedPage *currentPage;
    NSURL *currentBaseURL;
    NSString *currentStatusKey; /* 現在表示中のステータスのローカライズキー */

    float rightPaneExpandedWidth;
}

- (void)applicationDidFinishLaunching:(NSNotification *)note;

@end
