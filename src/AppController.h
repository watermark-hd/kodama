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
    NSButton *forwardButton;
    NSTextField *urlField;
    NSButton *addBookmarkButton;
    NSProgressIndicator *progressIndicator;

    NSMutableArray *navigationHistory; /* 戻る用: 訪問済みURLのスタック */
    NSMutableArray *forwardHistory; /* 進む用: 戻った分のURLのスタック */

    NSView *bookmarkBarView; /* 「▼ブックマーク」トグル行+ブックマーク行のコンテナ */
    NSButton *bookmarkToggleButton; /* 「▼/▲ ブックマーク」。常時表示、押すと開閉する */
    BOOL bookmarkBarExpanded; /* 既定は畳んだ状態(画面の狭いG4等でメイン領域を広く保つため) */
    NSMutableArray *bookmarks; /* {"title":..., "url":...}の配列。NSUserDefaultsで永続化 */
    NSMutableArray *bookmarkDeleteButtons; /* 各ブックマークの×ボタン(ホバー時のみ表示) */
    NSMutableArray *bookmarkTrackingTags; /* addTrackingRect:のタグ。再構築時に確実に解除するため保持 */
    float bookmarkBarHeight; /* ブックマーク行自体の高さ(展開時) */
    float bookmarkToggleStripHeight; /* 「▼ブックマーク」行の高さ(常時) */

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

    NSMenuItem *aboutMenuItem;
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
