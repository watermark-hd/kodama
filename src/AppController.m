#import "AppController.h"
#import "PWRCompat.h"
#import "PWRLocalization.h"

/* -setAppleMenu:は公開ヘッダには無いが実在する古典的なNSApplicationの
 * セレクタ(nib無しでメニューバーを組む際の定番)。これを呼んで自分の
 * appMenuを「本物のアプリケーションメニュー」として登録しないと、
 * AppKitが独自にもう一つアプリケーションメニューを生成してしまい、
 * 同じ名前のメニューが2つ並ぶ不具合が起きることを実機で確認した。 */
@interface NSApplication (PWRPrivateAppleMenu)
- (void)setAppleMenu:(NSMenu *)menu;
@end

/* 戻る履歴1件分(URL+当時のページタイトル)。
 * 「戻る」ボタンを右クリックした時の履歴一覧メニュー表示に使う。 */
@interface PWRHistoryEntry : NSObject
{
    NSURL *url;
    NSString *title;
}
- (id)initWithURL:(NSURL *)aURL title:(NSString *)aTitle;
- (NSURL *)url;
- (NSString *)title;
@end

@implementation PWRHistoryEntry

- (id)initWithURL:(NSURL *)aURL title:(NSString *)aTitle {
    self = [super init];
    if (self) {
        url = [aURL retain];
        title = [aTitle copy];
    }
    return self;
}

- (void)dealloc {
    [url release];
    [title release];
    [super dealloc];
}

- (NSURL *)url {
    return url;
}

- (NSString *)title {
    return title;
}

@end

/* URL取得中に一時的に保持しておく、遷移リクエスト1件分の情報。
 * CurlTaskRunnerのcontextとして渡す(画像取得は素のNSURLをcontextに
 * 使っているため、区別できるよう専用クラスにしている)。
 * pushCurrentToHistoryは、取得完了時にHTMLだと確定した場合にだけ
 * 現在のページを履歴へ積むかどうかを表す(navigateToURL:はYES、
 * 戻る/進む操作はNO)。 */
@interface PWRNavigationRequest : NSObject
{
    NSURL *url;
    BOOL pushCurrentToHistory;
}
- (id)initWithURL:(NSURL *)aURL pushCurrentToHistory:(BOOL)aPush;
- (NSURL *)url;
- (BOOL)pushCurrentToHistory;
@end

@implementation PWRNavigationRequest

- (id)initWithURL:(NSURL *)aURL pushCurrentToHistory:(BOOL)aPush {
    self = [super init];
    if (self) {
        url = [aURL retain];
        pushCurrentToHistory = aPush;
    }
    return self;
}

- (void)dealloc {
    [url release];
    [super dealloc];
}

- (NSURL *)url {
    return url;
}

- (BOOL)pushCurrentToHistory {
    return pushCurrentToHistory;
}

@end

@interface AppController (PWRPrivate)
- (void)buildMenuBar;
- (void)buildWindow;
- (void)updateLanguageCheckmarks;
- (void)refreshLocalizedText;
- (void)setStatus:(NSString *)text statusKey:(NSString *)key;
- (void)loadURL:(NSURL *)url;
- (void)navigateToURL:(NSURL *)url;
- (void)beginLoad:(NSURL *)url pushCurrentToHistory:(BOOL)pushCurrentToHistory;
- (void)saveDownloadedData:(NSData *)data suggestedFilename:(NSString *)suggestedFilename;
- (void)displayParsedPage:(PWRParsedPage *)page;
- (void)collapseRightPane;
- (void)expandRightPane;
- (void)rebuildHistoryMenu;
- (void)loadBookmarks;
- (void)saveBookmarks;
- (void)rebuildBookmarkBarButtons;
- (void)clearBookmarkChips;
- (void)updateBookmarkToggleTitle;
- (void)relayoutForBookmarkBarVisibility;
@end

@implementation AppController

#pragma mark - ライフサイクル

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [currentPage release];
    [currentBaseURL release];
    [currentStatusKey release];
    [navigationHistory release];
    [forwardHistory release];
    [bookmarks release];
    [bookmarkDeleteButtons release];
    [bookmarkTrackingTags release];
    [window release];
    [super dealloc];
}

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    rightPaneExpandedWidth = 260.0;
    bookmarkBarHeight = 20.0;
    bookmarkToggleStripHeight = 13.0;
    /* 起動直後だけは開いた状態にしておき、すぐにブックマークをクリック
     * できるようにする(記事を読んでいる最中は今まで通り手動で畳める)。 */
    bookmarkBarExpanded = YES;
    navigationHistory = [[NSMutableArray alloc] init];
    forwardHistory = [[NSMutableArray alloc] init];
    [self loadBookmarks];
    bookmarkDeleteButtons = [[NSMutableArray alloc] init];
    bookmarkTrackingTags = [[NSMutableArray alloc] init];

    [self buildMenuBar];
    [self buildWindow];
    [self rebuildHistoryMenu];
    [self rebuildBookmarkBarButtons];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                              selector:@selector(languageDidChange:)
                                                  name:PWRLanguageChangedNotification
                                                object:nil];

    [self setStatus:PWRL(@"ready") statusKey:@"ready"];

    [window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

#pragma mark - メニューバー構築

- (void)buildMenuBar {
    NSMenu *menubar = [[NSMenu alloc] initWithTitle:@""];

    /* アプリケーションメニュー(先頭のアイテム)。
     * Cocoaは表示上ここに実行中のアプリ名を自動で出すが、それは描画時の
     * 差し替えに過ぎず、クリック判定領域の幅はtitleプロパティの実際の
     * 文字列長から計算される。空文字列のままだと表示(広い)と判定領域
     * (ほぼ0幅)がずれてクリックできなくなるため、実際のアプリ名を設定する。 */
    NSMenuItem *appMenuItem = [[NSMenuItem alloc] initWithTitle:@"Kodama" action:NULL keyEquivalent:@""];
    [menubar addItem:appMenuItem];

    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"Kodama"];
    aboutMenuItem = [[NSMenuItem alloc] initWithTitle:PWRL(@"about") action:@selector(aboutAction:) keyEquivalent:@""];
    [aboutMenuItem setTarget:self];
    [appMenu addItem:aboutMenuItem];
    [appMenu addItem:[NSMenuItem separatorItem]];
    quitMenuItem = [[NSMenuItem alloc] initWithTitle:PWRL(@"quit") action:@selector(terminate:) keyEquivalent:@"q"];
    [quitMenuItem setTarget:NSApp];
    [appMenu addItem:quitMenuItem];
    [appMenuItem setSubmenu:appMenu];
    [NSApp setAppleMenu:appMenu];
    [appMenu release];
    [appMenuItem release];

    /* 編集メニュー。target=nilで作ることで「今フォーカスしている
     * 入力欄」に自動的にコマンドが飛ぶ(標準的なCocoaの作法)。
     * これが無いとCmd+V等の編集ショートカットがURL欄で効かない。
     * 各項目をivarに保持し、refreshLocalizedTextで言語切り替えに
     * 追従させる(以前ここを更新対象に入れ忘れていた不具合の修正)。 */
    editMenuItem = [[NSMenuItem alloc] initWithTitle:PWRL(@"editMenu") action:NULL keyEquivalent:@""];
    [menubar addItem:editMenuItem];

    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:PWRL(@"editMenu")];
    undoItem = [[NSMenuItem alloc] initWithTitle:PWRL(@"undo") action:@selector(undo:) keyEquivalent:@"z"];
    [editMenu addItem:undoItem];
    [undoItem release];
    redoItem = [[NSMenuItem alloc] initWithTitle:PWRL(@"redo") action:@selector(redo:) keyEquivalent:@"Z"];
    [redoItem setKeyEquivalentModifierMask:(NSCommandKeyMask | NSShiftKeyMask)];
    [editMenu addItem:redoItem];
    [redoItem release];
    [editMenu addItem:[NSMenuItem separatorItem]];
    cutItem = [[NSMenuItem alloc] initWithTitle:PWRL(@"cut") action:@selector(cut:) keyEquivalent:@"x"];
    [editMenu addItem:cutItem];
    [cutItem release];
    copyItem = [[NSMenuItem alloc] initWithTitle:PWRL(@"copy") action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItem:copyItem];
    [copyItem release];
    pasteItem = [[NSMenuItem alloc] initWithTitle:PWRL(@"paste") action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItem:pasteItem];
    [pasteItem release];
    [editMenu addItem:[NSMenuItem separatorItem]];
    selectAllItem = [[NSMenuItem alloc] initWithTitle:PWRL(@"selectAll") action:@selector(selectAll:) keyEquivalent:@"a"];
    [editMenu addItem:selectAllItem];
    [selectAllItem release];
    [editMenuItem setSubmenu:editMenu];
    [editMenu release];
    [editMenuItem release];

    /* 言語メニュー */
    languageMenuItem = [[NSMenuItem alloc] initWithTitle:PWRL(@"languageMenu") action:NULL keyEquivalent:@""];
    [menubar addItem:languageMenuItem];

    NSMenu *languageMenu = [[NSMenu alloc] initWithTitle:PWRL(@"languageMenu")];

    japaneseMenuItem = [[NSMenuItem alloc] initWithTitle:PWRJPStr("日本語") action:@selector(selectJapanese:) keyEquivalent:@""];
    [japaneseMenuItem setTarget:self];
    [languageMenu addItem:japaneseMenuItem];

    englishMenuItem = [[NSMenuItem alloc] initWithTitle:@"English" action:@selector(selectEnglish:) keyEquivalent:@""];
    [englishMenuItem setTarget:self];
    [languageMenu addItem:englishMenuItem];

    [languageMenuItem setSubmenu:languageMenu];
    [languageMenu release];

    [self updateLanguageCheckmarks];

    [NSApp setMainMenu:menubar];
    [menubar release];
}

- (void)updateLanguageCheckmarks {
    BOOL isJapanese = ![[PWRLocalization currentLanguage] isEqualToString:@"en"];
    [japaneseMenuItem setState:(isJapanese ? NSOnState : NSOffState)];
    [englishMenuItem setState:(isJapanese ? NSOffState : NSOnState)];
}

- (void)aboutAction:(id)sender {
    NSMutableDictionary *options = [NSMutableDictionary dictionary];
    [options setObject:PWRJPStr("コダマ (Kodama)") forKey:@"ApplicationName"];
    [options setObject:@"0.2" forKey:@"ApplicationVersion"];

    /* PPC Mac利用者は国内より海外の方が多いと見込み、Aboutパネルの説明文は
     * 常に日英併記にする(UI言語設定とは独立) */
    NSString *creditsText = PWRJPStr(
        "PowerPC Mac (G3/G4/G5) 向け超軽量3ペインWebリーダー\n"
        "A lightweight 3-pane web reader for PowerPC Macs (G3/G4/G5)\n\n"
        "https://github.com/watermark-hd/kodama");

    NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
    [style setAlignment:NSCenterTextAlignment];
    NSMutableDictionary *creditsAttrs = [NSMutableDictionary dictionary];
    [creditsAttrs setObject:[NSFont systemFontOfSize:11.0] forKey:NSFontAttributeName];
    [creditsAttrs setObject:style forKey:NSParagraphStyleAttributeName];
    [style release];

    NSAttributedString *credits = [[NSAttributedString alloc] initWithString:creditsText attributes:creditsAttrs];
    [options setObject:credits forKey:@"Credits"];
    [credits release];

    [NSApp orderFrontStandardAboutPanelWithOptions:options];
}

- (void)selectJapanese:(id)sender {
    [PWRLocalization setLanguage:@"ja"];
}

- (void)selectEnglish:(id)sender {
    [PWRLocalization setLanguage:@"en"];
}

- (void)languageDidChange:(NSNotification *)note {
    [self refreshLocalizedText];
}

- (void)refreshLocalizedText {
    [addBookmarkButton setTitle:PWRL(@"addBookmark")];
    [backButton setTitle:PWRL(@"back")];
    [forwardButton setTitle:PWRL(@"forward")];
    [[headingColumn headerCell] setStringValue:PWRL(@"headings")];
    [aboutMenuItem setTitle:PWRL(@"about")];
    [quitMenuItem setTitle:PWRL(@"quit")];
    [editMenuItem setTitle:PWRL(@"editMenu")];
    [undoItem setTitle:PWRL(@"undo")];
    [redoItem setTitle:PWRL(@"redo")];
    [cutItem setTitle:PWRL(@"cut")];
    [copyItem setTitle:PWRL(@"copy")];
    [pasteItem setTitle:PWRL(@"paste")];
    [selectAllItem setTitle:PWRL(@"selectAll")];
    [languageMenuItem setTitle:PWRL(@"languageMenu")];
    [hideImageButton setTitle:PWRL(@"hideImage")];
    [self updateBookmarkToggleTitle];
    [self rebuildBookmarkBarButtons]; /* 削除メニューの文言を言語切り替えに追従させる */

    [self updateLanguageCheckmarks];

    if (currentStatusKey) {
        [self setStatus:PWRL(currentStatusKey) statusKey:currentStatusKey];
    } else if ([[currentPage pageTitle] length] > 0) {
        /* ページタイトル表示中(currentStatusKey==nil)でも、末尾のアプリ名部分は
         * 言語切り替えに追従させる */
        [window setTitle:[NSString stringWithFormat:@"%@ - %@", [currentPage pageTitle], PWRL(@"appName")]];
    }
}

#pragma mark - ウィンドウ/ビュー構築(nib不使用)

- (void)buildWindow {
    NSRect windowFrame = NSMakeRect(80.0, 80.0, 900.0, 600.0);
    unsigned int styleMask = NSTitledWindowMask | NSClosableWindowMask |
                              NSMiniaturizableWindowMask | NSResizableWindowMask;
    window = [[NSWindow alloc] initWithContentRect:windowFrame
                                          styleMask:styleMask
                                            backing:NSBackingStoreBuffered
                                              defer:NO];
    [window setMinSize:NSMakeSize(500.0, 320.0)];
    [window setTitle:PWRL(@"appName")];

    NSView *contentView = [window contentView];
    NSRect contentBounds = [contentView bounds];
    float topBarHeight = 36.0;

    /* --- 上部バー(URL入力 + 開くボタン) --- */
    NSRect topBarFrame = NSMakeRect(0.0, contentBounds.size.height - topBarHeight,
                                     contentBounds.size.width, topBarHeight);
    topBarView = [[NSView alloc] initWithFrame:topBarFrame];
    [topBarView setAutoresizingMask:(NSViewWidthSizable | NSViewMinYMargin)];

    /* 左: 戻る/進む。右: ブックマーク追加+読み込み中スピナー。中央: URL欄。
     * 「開く」ボタンはEnterキーで代用できるため廃止した。 */
    float backButtonWidth = 70.0;
    float forwardButtonWidth = 70.0;
    float addBookmarkWidth = 50.0;
    float spinnerWidth = 20.0;

    NSRect backButtonFrame = NSMakeRect(8.0, 5.0, backButtonWidth, 26.0);
    backButton = [[NSButton alloc] initWithFrame:backButtonFrame];
    [backButton setAutoresizingMask:NSViewMaxXMargin];
    [backButton setBezelStyle:NSRoundedBezelStyle];
    [backButton setTitle:PWRL(@"back")];
    [backButton setTarget:self];
    [backButton setAction:@selector(backAction:)];
    [backButton setEnabled:NO];
    [topBarView addSubview:backButton];

    NSRect forwardButtonFrame = NSMakeRect(8.0 + backButtonWidth + 6.0, 5.0, forwardButtonWidth, 26.0);
    forwardButton = [[NSButton alloc] initWithFrame:forwardButtonFrame];
    [forwardButton setAutoresizingMask:NSViewMaxXMargin];
    [forwardButton setBezelStyle:NSRoundedBezelStyle];
    [forwardButton setTitle:PWRL(@"forward")];
    [forwardButton setTarget:self];
    [forwardButton setAction:@selector(forwardAction:)];
    [forwardButton setEnabled:NO];
    [topBarView addSubview:forwardButton];

    float urlFieldX = 8.0 + backButtonWidth + 6.0 + forwardButtonWidth + 8.0;
    float rightClusterW = addBookmarkWidth + 6.0 + spinnerWidth;
    NSRect urlFieldFrame = NSMakeRect(urlFieldX, 7.0,
                                       topBarFrame.size.width - urlFieldX - rightClusterW - 16.0, 22.0);
    urlField = [[NSTextField alloc] initWithFrame:urlFieldFrame];
    [urlField setAutoresizingMask:NSViewWidthSizable];
    [urlField setTarget:self];
    [urlField setAction:@selector(openAction:)];
    [topBarView addSubview:urlField];

    NSRect addBookmarkFrame = NSMakeRect(NSMaxX(urlFieldFrame) + 8.0, 5.0, addBookmarkWidth, 26.0);
    addBookmarkButton = [[NSButton alloc] initWithFrame:addBookmarkFrame];
    [addBookmarkButton setAutoresizingMask:NSViewMinXMargin];
    [addBookmarkButton setBezelStyle:NSRoundedBezelStyle];
    [addBookmarkButton setTitle:PWRL(@"addBookmark")];
    [addBookmarkButton setTarget:self];
    [addBookmarkButton setAction:@selector(addBookmarkAction:)];
    [topBarView addSubview:addBookmarkButton];

    NSRect spinnerFrame = NSMakeRect(NSMaxX(addBookmarkFrame) + 6.0, 8.0, spinnerWidth, spinnerWidth);
    progressIndicator = [[NSProgressIndicator alloc] initWithFrame:spinnerFrame];
    [progressIndicator setAutoresizingMask:NSViewMinXMargin];
    [progressIndicator setStyle:NSProgressIndicatorSpinningStyle];
    [progressIndicator setDisplayedWhenStopped:NO];
    [topBarView addSubview:progressIndicator];

    [contentView addSubview:topBarView];
    [topBarView release];
    [backButton release];
    [forwardButton release];
    [urlField release];
    [addBookmarkButton release];
    [progressIndicator release];

    /* --- ブックマークバー ---
     * 「▼ブックマーク」の細い帯は常時表示し、押した時だけ実際の
     * ブックマーク行が下に現れる折りたたみ式。画面が狭いG4等(1024x768)
     * でもメイン領域を広く保てるように、既定では畳んだ状態にしている。 */
    float initialTotalH = bookmarkToggleStripHeight;
    NSRect bookmarkBarFrame = NSMakeRect(0.0, contentBounds.size.height - topBarHeight - initialTotalH,
                                          contentBounds.size.width, initialTotalH);
    bookmarkBarView = [[NSView alloc] initWithFrame:bookmarkBarFrame];
    [bookmarkBarView setAutoresizingMask:(NSViewWidthSizable | NSViewMinYMargin)];
    [contentView addSubview:bookmarkBarView];

    NSRect toggleFrame = NSMakeRect(0.0, initialTotalH - bookmarkToggleStripHeight,
                                     contentBounds.size.width, bookmarkToggleStripHeight);
    bookmarkToggleButton = [[NSButton alloc] initWithFrame:toggleFrame];
    [bookmarkToggleButton setAutoresizingMask:(NSViewWidthSizable | NSViewMinYMargin)];
    [bookmarkToggleButton setBordered:NO];
    [[bookmarkToggleButton cell] setAlignment:NSCenterTextAlignment];
    [bookmarkToggleButton setTarget:self];
    [bookmarkToggleButton setAction:@selector(toggleBookmarkBarAction:)];
    [bookmarkBarView addSubview:bookmarkToggleButton];
    [bookmarkToggleButton release];
    [self updateBookmarkToggleTitle];

    [bookmarkBarView release];

    /* --- 3ペインsplit view(右ペインは既定で幅0=折りたたみ) --- */
    NSRect splitFrame = NSMakeRect(0.0, 0.0, contentBounds.size.width,
                                    contentBounds.size.height - topBarHeight - initialTotalH);
    splitView = [[NSSplitView alloc] initWithFrame:splitFrame];
    [splitView setVertical:YES];
    [splitView setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];
    [splitView setDelegate:self];

    float dividerThickness = [splitView dividerThickness];
    float leftWidth = 200.0;
    float rightWidth = 0.0;
    float centerWidth = splitFrame.size.width - leftWidth - rightWidth - (dividerThickness * 2.0);

    NSRect leftFrame = NSMakeRect(0.0, 0.0, leftWidth, splitFrame.size.height);
    NSRect centerFrame = NSMakeRect(leftWidth + dividerThickness, 0.0, centerWidth, splitFrame.size.height);
    NSRect rightFrame = NSMakeRect(NSMaxX(centerFrame) + dividerThickness, 0.0, rightWidth, splitFrame.size.height);

    /* 左: 見出しテーブル */
    leftScrollView = [[NSScrollView alloc] initWithFrame:leftFrame];
    [leftScrollView setHasVerticalScroller:YES];
    [leftScrollView setAutohidesScrollers:YES];
    [leftScrollView setBorderType:NSBezelBorder];

    headingTableView = [[NSTableView alloc] initWithFrame:[[leftScrollView contentView] bounds]];
    headingColumn = [[NSTableColumn alloc] initWithIdentifier:@"heading"];
    [headingColumn setWidth:180.0];
    [[headingColumn headerCell] setStringValue:PWRL(@"headings")];
    [headingTableView addTableColumn:headingColumn];
    [headingColumn release];
    [headingTableView setDataSource:self];
    [headingTableView setDelegate:self];

    [leftScrollView setDocumentView:headingTableView];
    [headingTableView release];

    /* 中央: 本文 */
    centerScrollView = [[NSScrollView alloc] initWithFrame:centerFrame];
    [centerScrollView setHasVerticalScroller:YES];
    [centerScrollView setAutohidesScrollers:YES];
    [centerScrollView setBorderType:NSBezelBorder];

    bodyTextView = [[NSTextView alloc] initWithFrame:[[centerScrollView contentView] bounds]];
    [bodyTextView setEditable:NO];
    [bodyTextView setSelectable:YES];
    [bodyTextView setDelegate:self];
    [bodyTextView setVerticallyResizable:YES];
    [bodyTextView setHorizontallyResizable:NO];
    [bodyTextView setAutoresizingMask:NSViewWidthSizable];
    [[bodyTextView textContainer] setWidthTracksTextView:YES];

    [centerScrollView setDocumentView:bodyTextView];
    [bodyTextView release];

    /* 右: 画像プレビュー(隠すボタン + 画像) */
    rightContainerView = [[NSView alloc] initWithFrame:rightFrame];

    float hideButtonHeight = 24.0;
    NSRect hideButtonFrame = NSMakeRect(4.0, rightFrame.size.height - hideButtonHeight - 4.0,
                                         rightFrame.size.width - 8.0, hideButtonHeight);
    hideImageButton = [[NSButton alloc] initWithFrame:hideButtonFrame];
    [hideImageButton setAutoresizingMask:(NSViewWidthSizable | NSViewMinYMargin)];
    [hideImageButton setBezelStyle:NSRoundedBezelStyle];
    [hideImageButton setTitle:PWRL(@"hideImage")];
    [hideImageButton setTarget:self];
    [hideImageButton setAction:@selector(hideImageAction:)];
    [rightContainerView addSubview:hideImageButton];
    [hideImageButton release];

    NSRect rightScrollFrame = NSMakeRect(0.0, 0.0, rightFrame.size.width,
                                          rightFrame.size.height - hideButtonHeight - 8.0);
    rightScrollView = [[NSScrollView alloc] initWithFrame:rightScrollFrame];
    [rightScrollView setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];
    [rightScrollView setHasVerticalScroller:YES];
    [rightScrollView setAutohidesScrollers:YES];
    [rightScrollView setBorderType:NSBezelBorder];

    imageView = [[NSImageView alloc] initWithFrame:[[rightScrollView contentView] bounds]];
    [imageView setImageScaling:NSScaleProportionally];
    [imageView setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];

    [rightScrollView setDocumentView:imageView];
    [imageView release];

    [rightContainerView addSubview:rightScrollView];
    [rightScrollView release];

    [splitView addSubview:leftScrollView];
    [splitView addSubview:centerScrollView];
    [splitView addSubview:rightContainerView];

    [leftScrollView release];
    [centerScrollView release];
    [rightContainerView release];

    [contentView addSubview:splitView];
    [splitView release];
}

#pragma mark - NSSplitViewの手動レイアウト(TigerにsetPosition:ofDividerAtIndex:が無いため)

- (void)splitView:(NSSplitView *)sender resizeSubviewsWithOldSize:(NSSize)oldSize {
    NSRect bounds = [sender bounds];
    float dividerThickness = [sender dividerThickness];
    float height = bounds.size.height;

    float leftWidth = [leftScrollView frame].size.width;
    float rightWidth = [rightContainerView frame].size.width;

    float centerWidth = bounds.size.width - leftWidth - rightWidth - (dividerThickness * 2.0);
    if (centerWidth < 0.0) {
        centerWidth = 0.0;
    }

    NSRect leftFrame = NSMakeRect(0.0, 0.0, leftWidth, height);
    NSRect centerFrame = NSMakeRect(leftWidth + dividerThickness, 0.0, centerWidth, height);
    NSRect rightFrame = NSMakeRect(NSMaxX(centerFrame) + dividerThickness, 0.0, rightWidth, height);

    [leftScrollView setFrame:leftFrame];
    [centerScrollView setFrame:centerFrame];
    [rightContainerView setFrame:rightFrame];
}

- (BOOL)splitView:(NSSplitView *)sender canCollapseSubview:(NSView *)subview {
    return (subview == rightContainerView);
}

- (void)collapseRightPane {
    NSRect frame = [rightContainerView frame];
    if (frame.size.width <= 0.0) {
        return;
    }
    frame.size.width = 0.0;
    [rightContainerView setFrame:frame];
    [splitView adjustSubviews];
    [splitView setNeedsDisplay:YES];
}

- (void)expandRightPane {
    NSRect frame = [rightContainerView frame];
    if (frame.size.width >= rightPaneExpandedWidth) {
        return;
    }
    frame.size.width = rightPaneExpandedWidth;
    [rightContainerView setFrame:frame];
    [splitView adjustSubviews];
    [splitView setNeedsDisplay:YES];
}

- (void)hideImageAction:(id)sender {
    [self collapseRightPane];
}

#pragma mark - URL入力

/* "yahoo.co.jp"のようなドメインらしき文字列だけをURLとみなし、それ以外
 * (スペースを含む・ドットが無い等)は検索ワードとして扱う簡易判定。
 * Wikipedia等の検索フォーム自体はまだ扱えないため、URL欄からの検索で
 * 代用できるようにする対応。 */
- (BOOL)looksLikeURL:(NSString *)text {
    if ([text rangeOfString:@" "].location != NSNotFound) {
        return NO;
    }
    if ([text rangeOfString:@"://"].location != NSNotFound) {
        return YES;
    }
    NSRange dotRange = [text rangeOfString:@"."];
    if (dotRange.location == NSNotFound || dotRange.location == 0 ||
        NSMaxRange(dotRange) >= [text length]) {
        return NO;
    }
    return YES;
}

- (void)openAction:(id)sender {
    NSString *text = [urlField stringValue];
    text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([text length] == 0) {
        return;
    }

    NSURL *url;
    if ([self looksLikeURL:text]) {
        url = [NSURL URLWithString:text];
        if (!url || ![url scheme]) {
            /* スキームが省略されていたらhttps://を補う */
            url = [NSURL URLWithString:[@"https://" stringByAppendingString:text]];
        }
    } else {
        /* URLらしくない入力は検索へ。Googleは検証の結果、gbv=1(旧来の
         * 簡易HTMLモード)を付けてもJS必須のページに転送されてしまい
         * このアプリでは使えなかった。DuckDuckGoの素のHTML版エンドポイント
         * (html.duckduckgo.com/html/)はscriptタグ無しの静的HTMLで
         * 検索結果を返すため、こちらを使う */
        NSString *encoded = [text stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
        url = [NSURL URLWithString:[NSString stringWithFormat:@"https://html.duckduckgo.com/html/?q=%@", encoded]];
    }
    if (!url) {
        return;
    }

    [self navigateToURL:url];
}

/* 現在表示中のページがあれば履歴に積んでから新しいページへ移動する。
 * (URL欄からの入力・見出しリンクのクリック・本文中のリンクのクリック全てから呼ばれる) */
/* 新しいページへの移動(URL欄からの入力・リンククリック・ブックマーク等)。
 * 「進む」で辿れるのは戻った直後だけ、という通常のブラウザの挙動に
 * 合わせ、新規移動では進む履歴を破棄する。 */
- (void)navigateToURL:(NSURL *)url {
    /* 履歴の更新(現在のページをnavigationHistoryへ積む/forwardHistoryを破棄)は
     * ここでは行わず、取得完了後に「実際にHTMLページだった」場合にのみ行う
     * (beginLoad:pushCurrentToHistory:参照)。ダウンロードだった場合に
     * 現在表示中のページの履歴状態を誤って書き換えないようにするため。 */
    [self beginLoad:url pushCurrentToHistory:YES];
}

- (void)backAction:(id)sender {
    if ([navigationHistory count] == 0) {
        return;
    }
    if (currentBaseURL) {
        PWRHistoryEntry *fwdEntry = [[PWRHistoryEntry alloc] initWithURL:currentBaseURL
                                                                     title:[currentPage pageTitle]];
        [forwardHistory addObject:fwdEntry];
        [fwdEntry release];
        [forwardButton setEnabled:YES];
    }
    PWRHistoryEntry *previous = [[navigationHistory lastObject] retain];
    [navigationHistory removeLastObject];
    [backButton setEnabled:([navigationHistory count] > 0)];
    [self rebuildHistoryMenu];
    [self loadURL:[previous url]];
    [previous release];
}

- (void)forwardAction:(id)sender {
    if ([forwardHistory count] == 0) {
        return;
    }
    if (currentBaseURL) {
        PWRHistoryEntry *backEntry = [[PWRHistoryEntry alloc] initWithURL:currentBaseURL
                                                                      title:[currentPage pageTitle]];
        [navigationHistory addObject:backEntry];
        [backEntry release];
        [backButton setEnabled:YES];
        [self rebuildHistoryMenu];
    }
    PWRHistoryEntry *next = [[forwardHistory lastObject] retain];
    [forwardHistory removeLastObject];
    [forwardButton setEnabled:([forwardHistory count] > 0)];
    [self loadURL:[next url]];
    [next release];
}

/* 戻るボタンを右クリック(control+クリック)した時に出す履歴一覧から、
 * 指定のページへ直接ジャンプする。それより新しい履歴は通常のブラウザ同様に破棄する。 */
- (void)jumpToHistoryEntry:(id)sender {
    int index = [sender tag];
    if (index < 0 || (unsigned int)index >= [navigationHistory count]) {
        return;
    }
    PWRHistoryEntry *entry = [[navigationHistory objectAtIndex:index] retain];
    [navigationHistory removeObjectsInRange:NSMakeRange(index, [navigationHistory count] - index)];
    [backButton setEnabled:([navigationHistory count] > 0)];
    [forwardHistory removeAllObjects];
    [forwardButton setEnabled:NO];
    [self rebuildHistoryMenu];
    [self loadURL:[entry url]];
    [entry release];
}

/* 戻るボタンの右クリックメニューを、現在の履歴内容に合わせて作り直す。
 * 直近に訪れたページを上に表示する(古いものほど下)。 */
- (void)rebuildHistoryMenu {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
    int index = [navigationHistory count] - 1;
    NSEnumerator *e = [navigationHistory reverseObjectEnumerator];
    PWRHistoryEntry *entry;
    while ((entry = [e nextObject])) {
        NSString *displayTitle = [entry title];
        if ([displayTitle length] == 0) {
            displayTitle = [[entry url] absoluteString];
        }
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:displayTitle
                                                        action:@selector(jumpToHistoryEntry:)
                                                 keyEquivalent:@""];
        [item setTarget:self];
        [item setTag:index];
        [menu addItem:item];
        [item release];
        index--;
    }
    [backButton setMenu:menu];
    [menu release];
}

#pragma mark - ブックマーク

- (void)loadBookmarks {
    NSArray *saved = [[NSUserDefaults standardUserDefaults] arrayForKey:@"PWRBookmarks"];
    if (saved) {
        bookmarks = [saved mutableCopy];
    } else {
        bookmarks = [[NSMutableArray alloc] init];
    }
}

- (void)saveBookmarks {
    [[NSUserDefaults standardUserDefaults] setObject:bookmarks forKey:@"PWRBookmarks"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)addBookmarkAction:(id)sender {
    if (!currentBaseURL) {
        return;
    }
    NSString *urlString = [currentBaseURL absoluteString];

    /* 同じURLが既に登録済みなら追加しない */
    NSEnumerator *e = [bookmarks objectEnumerator];
    NSDictionary *existing;
    while ((existing = [e nextObject])) {
        if ([[existing objectForKey:@"url"] isEqualToString:urlString]) {
            return;
        }
    }

    NSString *title = [currentPage pageTitle];
    if ([title length] == 0) {
        title = urlString;
    }
    NSDictionary *entry = [NSDictionary dictionaryWithObjectsAndKeys:
        title, @"title", urlString, @"url", nil];
    [bookmarks addObject:entry];
    [self saveBookmarks];
    [self rebuildBookmarkBarButtons];
}

- (void)bookmarkClicked:(id)sender {
    int index = [sender tag];
    if (index < 0 || (unsigned int)index >= [bookmarks count]) {
        return;
    }
    NSDictionary *entry = [bookmarks objectAtIndex:index];
    NSURL *url = [NSURL URLWithString:[entry objectForKey:@"url"]];
    if (url) {
        [self navigateToURL:url];
    }
}

/* NSAlertにはaccessoryViewが無い(Leopard以降のAPI)ため、
 * テキスト入力欄付きの小さなモーダルパネルを自前で組む */
- (void)renameBookmarkAction:(id)sender {
    int index = [sender tag];
    if (index < 0 || (unsigned int)index >= [bookmarks count]) {
        return;
    }
    NSDictionary *entry = [bookmarks objectAtIndex:index];
    NSString *currentTitle = [entry objectForKey:@"title"];

    NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0.0, 0.0, 320.0, 110.0)
                                                  styleMask:NSTitledWindowMask
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
    [panel setTitle:PWRL(@"renameBookmark")];

    NSTextField *label = [[NSTextField alloc] initWithFrame:NSMakeRect(16.0, 78.0, 288.0, 17.0)];
    [label setStringValue:PWRL(@"renameBookmarkPrompt")];
    [label setEditable:NO];
    [label setSelectable:NO];
    [label setBezeled:NO];
    [label setDrawsBackground:NO];
    [[panel contentView] addSubview:label];
    [label release];

    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(16.0, 50.0, 288.0, 22.0)];
    [field setStringValue:(currentTitle ? currentTitle : @"")];
    [[panel contentView] addSubview:field];
    [field release];

    NSButton *cancelButton = [[NSButton alloc] initWithFrame:NSMakeRect(140.0, 12.0, 80.0, 26.0)];
    [cancelButton setBezelStyle:NSRoundedBezelStyle];
    [cancelButton setTitle:PWRL(@"cancel")];
    [cancelButton setTarget:self];
    [cancelButton setAction:@selector(renameCancelAction:)];
    [[panel contentView] addSubview:cancelButton];
    [cancelButton release];

    NSButton *okButton = [[NSButton alloc] initWithFrame:NSMakeRect(224.0, 12.0, 80.0, 26.0)];
    [okButton setBezelStyle:NSRoundedBezelStyle];
    [okButton setTitle:PWRL(@"ok")];
    [okButton setTarget:self];
    [okButton setAction:@selector(renameOKAction:)];
    [[panel contentView] addSubview:okButton];
    [panel setDefaultButtonCell:[okButton cell]];
    [okButton release];

    [panel makeFirstResponder:field];
    [field selectText:nil];

    int result = [NSApp runModalForWindow:panel];
    [panel orderOut:nil];

    if (result == 1) {
        NSString *newTitle = [[field stringValue]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([newTitle length] > 0) {
            NSMutableDictionary *updated = [NSMutableDictionary dictionaryWithDictionary:entry];
            [updated setObject:newTitle forKey:@"title"];
            [bookmarks replaceObjectAtIndex:index withObject:updated];
            [self saveBookmarks];
            [self rebuildBookmarkBarButtons];
        }
    }

    [panel release];
}

- (void)renameOKAction:(id)sender {
    [NSApp stopModalWithCode:1];
}

- (void)renameCancelAction:(id)sender {
    [NSApp stopModalWithCode:0];
}

- (void)deleteBookmarkAction:(id)sender {
    int index = [sender tag];
    if (index < 0 || (unsigned int)index >= [bookmarks count]) {
        return;
    }
    [bookmarks removeObjectAtIndex:index];
    [self saveBookmarks];
    [self rebuildBookmarkBarButtons];
}

/* ブックマークバーの中身をすべて作り直す。ブックマークの追加/削除/
 * 言語切り替えの度に呼ばれる。 */
/* ブックマーク行の中身(チップ・×ボタン・トラッキング矩形)だけを片付ける。
 * 常時表示のbookmarkToggleButtonはここでは触らない。 */
- (void)clearBookmarkChips {
    NSEnumerator *te = [bookmarkTrackingTags objectEnumerator];
    NSNumber *tagNum;
    while ((tagNum = [te nextObject])) {
        [bookmarkBarView removeTrackingRect:[tagNum intValue]];
    }
    [bookmarkTrackingTags removeAllObjects];
    [bookmarkDeleteButtons removeAllObjects];

    NSArray *existingSubviews = [[bookmarkBarView subviews] copy];
    NSEnumerator *se = [existingSubviews objectEnumerator];
    NSView *v;
    while ((v = [se nextObject])) {
        if (v != bookmarkToggleButton) {
            [v removeFromSuperview];
        }
    }
    [existingSubviews release];
}

- (void)toggleBookmarkBarAction:(id)sender {
    bookmarkBarExpanded = !bookmarkBarExpanded;
    [self updateBookmarkToggleTitle];
    [self rebuildBookmarkBarButtons];
}

- (void)updateBookmarkToggleTitle {
    NSString *arrow = bookmarkBarExpanded ? PWRJPStr("▲") : PWRJPStr("▼");
    NSString *label = [NSString stringWithFormat:@"%@ %@", arrow, PWRL(@"bookmarksToggle")];

    /* [cell setAlignment:]だけだとattributedTitle使用時に反映されない
     * ことがあるため、段落スタイルとして直接中央揃えを埋め込む */
    NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
    [style setAlignment:NSCenterTextAlignment];

    NSMutableDictionary *attrs = [NSMutableDictionary dictionary];
    [attrs setObject:[NSColor grayColor] forKey:NSForegroundColorAttributeName];
    [attrs setObject:[NSFont systemFontOfSize:9.0] forKey:NSFontAttributeName];
    [attrs setObject:style forKey:NSParagraphStyleAttributeName];
    /* 細い帯の中で文字がやや下に寄って見えるとの指摘を受け、
     * ベースラインを少し持ち上げて視覚的に中央へ近づける */
    [attrs setObject:[NSNumber numberWithFloat:1.5] forKey:NSBaselineOffsetAttributeName];
    [style release];

    NSAttributedString *attrTitle = [[NSAttributedString alloc] initWithString:label attributes:attrs];
    [bookmarkToggleButton setAttributedTitle:attrTitle];
    [attrTitle release];
}

/* ブックマーク行(チップ)を組み立てる。折りたたみ中(bookmarkBarExpanded==NO)
 * は「▼ブックマーク」の帯だけ残してチップは作らない。 */
- (void)rebuildBookmarkBarButtons {
    [self clearBookmarkChips];

    if (!bookmarkBarExpanded) {
        [self relayoutForBookmarkBarVisibility];
        return;
    }

    float x = 6.0;
    float buttonH = 15.0;
    float maxChipW = 140.0;
    float deleteButtonW = 16.0;
    float y = (bookmarkBarHeight - buttonH) / 2.0;
    int index = 0;
    NSFont *bookmarkFont = [NSFont systemFontOfSize:10.0];

    NSEnumerator *e = [bookmarks objectEnumerator];
    NSDictionary *entry;
    while ((entry = [e nextObject])) {
        NSString *title = [entry objectForKey:@"title"];

        /* ボタン型ではなく、隣とスペースの空いた文字リンクだけの見た目にする
         * (ブックマークが増えた時に窮屈にならないように、という要望対応) */
        NSButton *b = [[NSButton alloc] initWithFrame:NSMakeRect(x, y, 10.0, buttonH)];
        [b setBordered:NO];
        [b setTarget:self];
        [b setAction:@selector(bookmarkClicked:)];
        [b setTag:index];

        NSMutableDictionary *titleAttrs = [NSMutableDictionary dictionary];
        [titleAttrs setObject:[NSColor blackColor] forKey:NSForegroundColorAttributeName];
        [titleAttrs setObject:bookmarkFont forKey:NSFontAttributeName];
        NSAttributedString *attrTitle = [[NSAttributedString alloc] initWithString:title attributes:titleAttrs];
        [b setAttributedTitle:attrTitle];
        [attrTitle release];

        [b sizeToFit];
        float chipW = [b frame].size.width;
        if (chipW > maxChipW) {
            chipW = maxChipW;
        }
        [b setFrame:NSMakeRect(x, y, chipW, buttonH)];

        /* 右クリック(control+クリック)で名前変更・削除のメニューを出す */
        NSMenu *contextMenu = [[NSMenu alloc] initWithTitle:@""];
        NSMenuItem *renameItem = [[NSMenuItem alloc] initWithTitle:PWRL(@"renameBookmark")
                                                              action:@selector(renameBookmarkAction:)
                                                       keyEquivalent:@""];
        [renameItem setTarget:self];
        [renameItem setTag:index];
        [contextMenu addItem:renameItem];
        [renameItem release];
        NSMenuItem *deleteItem = [[NSMenuItem alloc] initWithTitle:PWRL(@"deleteBookmark")
                                                              action:@selector(deleteBookmarkAction:)
                                                       keyEquivalent:@""];
        [deleteItem setTarget:self];
        [deleteItem setTag:index];
        [contextMenu addItem:deleteItem];
        [deleteItem release];
        [b setMenu:contextMenu];
        [contextMenu release];

        [bookmarkBarView addSubview:b];
        [b release];

        /* ×削除ボタンはマウスを乗せた時だけ、文字のすぐ右に現れる */
        NSRect deleteFrame = NSMakeRect(x + chipW + 3.0, y - 1.0, deleteButtonW, buttonH);
        NSButton *deleteButton = [[NSButton alloc] initWithFrame:deleteFrame];
        [deleteButton setBezelStyle:NSSmallSquareBezelStyle];
        [deleteButton setTitle:PWRJPStr("×")];
        [deleteButton setTarget:self];
        [deleteButton setAction:@selector(deleteBookmarkAction:)];
        [deleteButton setTag:index];
        [deleteButton setHidden:YES];
        [bookmarkBarView addSubview:deleteButton];
        [bookmarkDeleteButtons addObject:deleteButton];
        [deleteButton release];

        NSRect trackingFrame = NSMakeRect(x, y, chipW + 3.0 + deleteButtonW, buttonH);
        NSTrackingRectTag tag = [bookmarkBarView addTrackingRect:trackingFrame
                                                             owner:self
                                                          userData:(void *)(long)index
                                                      assumeInside:NO];
        [bookmarkTrackingTags addObject:[NSNumber numberWithInt:tag]];

        x += chipW + 3.0 + deleteButtonW + 12.0; /* 次のブックマークとの間に余白 */
        index++;
    }

    [self relayoutForBookmarkBarVisibility];
}

- (void)mouseEntered:(NSEvent *)event {
    int index = (int)(long)[event userData];
    if (index >= 0 && index < (int)[bookmarkDeleteButtons count]) {
        [[bookmarkDeleteButtons objectAtIndex:index] setHidden:NO];
    }
}

- (void)mouseExited:(NSEvent *)event {
    int index = (int)(long)[event userData];
    if (index >= 0 && index < (int)[bookmarkDeleteButtons count]) {
        [[bookmarkDeleteButtons objectAtIndex:index] setHidden:YES];
    }
}

/* 「▼ブックマーク」の帯は常時表示、展開時だけブックマーク行の分の高さを足す。
 * トグルボタン自身の位置も、コンテナの高さが変わるたびに天井(一番上)に
 * 来るよう再計算する。 */
- (void)relayoutForBookmarkBarVisibility {
    NSView *contentView = [window contentView];
    NSRect contentBounds = [contentView bounds];
    float topBarH = 36.0;
    float totalH = bookmarkToggleStripHeight + (bookmarkBarExpanded ? bookmarkBarHeight : 0.0);

    NSRect bmFrame = NSMakeRect(0.0, contentBounds.size.height - topBarH - totalH,
                                 contentBounds.size.width, totalH);
    [bookmarkBarView setFrame:bmFrame];

    NSRect toggleFrame = NSMakeRect(0.0, totalH - bookmarkToggleStripHeight,
                                     contentBounds.size.width, bookmarkToggleStripHeight);
    [bookmarkToggleButton setFrame:toggleFrame];

    NSRect spFrame = NSMakeRect(0.0, 0.0, contentBounds.size.width,
                                 contentBounds.size.height - topBarH - totalH);
    [splitView setFrame:spFrame];
    [splitView adjustSubviews];

    /* setFrame:だけでは古い位置の描画が残る(残像)ことがあったため、
     * コンテンツビュー全体に再描画を明示的に指示する */
    [contentView setNeedsDisplay:YES];
    [bookmarkBarView setNeedsDisplay:YES];
    [splitView setNeedsDisplay:YES];
}

/* 履歴には積まずにページを読み込む(戻る操作専用の下位メソッド) */
- (void)loadURL:(NSURL *)url {
    [self beginLoad:url pushCurrentToHistory:NO];
}

/* URL取得を開始する。取得結果がHTMLページかファイルダウンロードかは
 * 取得が完了するまで分からないため、currentBaseURL/本文表示/履歴の
 * 更新はここでは行わず、取得完了後(didFinishWithData:context:)で
 * HTMLだと確定してから行う。こうすることで、リンク先が実はダウンロード
 * だった場合に現在表示中のページを誤って消してしまうのを防ぐ。 */
- (void)beginLoad:(NSURL *)url pushCurrentToHistory:(BOOL)pushCurrentToHistory {
    [self setStatus:PWRL(@"loading") statusKey:@"loading"];
    [progressIndicator startAnimation:nil];

    PWRNavigationRequest *req = [[PWRNavigationRequest alloc] initWithURL:url
                                                        pushCurrentToHistory:pushCurrentToHistory];
    CurlTaskRunner *runner = [[CurlTaskRunner alloc] initWithDelegate:self];
    [runner fetchURL:url context:req];
    [runner release]; /* fetchURL内部で自己retainするのでここで手放してよい */
    [req release];
}

#pragma mark - ファイルダウンロード

/* 取得済みのバイナリデータを、保存パネルで選んだ場所にそのまま書き出す。 */
- (void)saveDownloadedData:(NSData *)data suggestedFilename:(NSString *)suggestedFilename {
    if ([suggestedFilename length] == 0) {
        suggestedFilename = @"download";
    }

    NSSavePanel *panel = [NSSavePanel savePanel];
    [panel setTitle:PWRL(@"saveDownload")];

    int result = [panel runModalForDirectory:NSHomeDirectory() file:suggestedFilename];
    if (result == NSFileHandlingPanelOKButton) {
        if (![data writeToFile:[panel filename] atomically:YES]) {
            NSAlert *alert = [NSAlert alertWithMessageText:PWRL(@"networkError")
                                              defaultButton:PWRL(@"ok")
                                            alternateButton:nil
                                                otherButton:nil
                                 informativeTextWithFormat:@"%@", PWRL(@"downloadWriteFailed")];
            [alert runModal];
        }
    }
}

#pragma mark - CurlTaskRunnerDelegate

- (void)curlTaskRunner:(CurlTaskRunner *)runner didFinishWithData:(NSData *)data context:(id)context {
    [progressIndicator stopAnimation:nil];

    if ([context isKindOfClass:[NSURL class]]) {
        /* 画像取得の完了。ページ自体は変わっていないのでウィンドウタイトルには触れない */
        NSImage *image = [[NSImage alloc] initWithData:data];
        if (image) {
            [imageView setImage:image];
            [image release];
            [self expandRightPane];
        }
        return;
    }

    /* URL取得の完了(HTMLページ or ファイルダウンロード)。
     * URLの拡張子だけでは/download/kodamaのような拡張子なしの
     * ダウンロードルートを判定できないため、実際のレスポンスヘッダ
     * (Content-Disposition/Content-Type)を見て判断する。 */
    PWRNavigationRequest *req = (PWRNavigationRequest *)context;

    if ([runner responseLooksLikeDownload]) {
        NSString *suggestedName = [runner responseSuggestedFilename];
        if ([suggestedName length] == 0) {
            suggestedName = [[[req url] path] lastPathComponent];
        }
        /* 現在のページ状態(履歴・URL欄・本文)には一切触れない。
         * loading表示にしていたステータスだけを元に戻す。 */
        if (currentStatusKey) {
            [self setStatus:PWRL(currentStatusKey) statusKey:currentStatusKey];
        } else if ([[currentPage pageTitle] length] > 0) {
            [window setTitle:[NSString stringWithFormat:@"%@ - %@", [currentPage pageTitle], PWRL(@"appName")]];
        } else {
            [self setStatus:PWRL(@"ready") statusKey:@"ready"];
        }
        [self saveDownloadedData:data suggestedFilename:suggestedName];
        return;
    }

    /* HTMLページだと確定したので、ここで初めて実際にページ遷移を行う */
    if ([req pushCurrentToHistory]) {
        if (currentBaseURL) {
            PWRHistoryEntry *entry = [[PWRHistoryEntry alloc] initWithURL:currentBaseURL
                                                                      title:[currentPage pageTitle]];
            [navigationHistory addObject:entry];
            [entry release];
            [backButton setEnabled:YES];
            [self rebuildHistoryMenu];
        }
        [forwardHistory removeAllObjects];
        [forwardButton setEnabled:NO];
    }

    [currentBaseURL release];
    currentBaseURL = [[req url] retain];
    [urlField setStringValue:[[req url] absoluteString]];
    [self collapseRightPane];

    PWRParsedPage *page = [HTMLParserEngine parsePageFromData:data baseURL:currentBaseURL];
    if (!page) {
        [self setStatus:PWRL(@"parseError") statusKey:@"parseError"];
        return;
    }
    [self displayParsedPage:page];
}

- (void)curlTaskRunner:(CurlTaskRunner *)runner didFailWithError:(NSString *)message context:(id)context {
    [progressIndicator stopAnimation:nil];
    [self setStatus:message statusKey:nil];

    NSAlert *alert = [NSAlert alertWithMessageText:PWRL(@"networkError")
                                      defaultButton:PWRL(@"ok")
                                    alternateButton:nil
                                        otherButton:nil
                         informativeTextWithFormat:@"%@", message];
    [alert runModal];
}

#pragma mark - ページ表示

- (void)displayParsedPage:(PWRParsedPage *)page {
    /* <meta http-equiv="refresh">を持つ「クッションページ」だった場合は、
     * それ自体を表示せず目的のページへそのまま差し替える。履歴には
     * クッションページの方は積まない(戻った時にまた転送されて実質
     * 戻れなくなるのを防ぐため)。自己参照ループの簡易対策として、
     * 転送先が今読み込んだURLと同じ場合だけは追従しない。 */
    NSURL *refreshURL = [page metaRefreshURL];
    if (refreshURL && ![[refreshURL absoluteString] isEqualToString:[currentBaseURL absoluteString]]) {
        [self loadURL:refreshURL];
        return;
    }

    [currentPage release];
    currentPage = [page retain];

    [[bodyTextView textStorage] setAttributedString:[page bodyText]];

    /* 見出しテーブルの選択行はreloadData後も行番号ベースで残ってしまう
     * (以前のページで選択していた行が新しいページでもたまたま有効な
     * 行数内だと、そのまま選択状態が残る)。ここで明示的に解除しておかないと、
     * reloadDataで行数が減った際にAppKitが選択行を範囲内へ自動的に
     * 詰め直し、その結果tableViewSelectionDidChange:が呼ばれて新しい
     * ページの無関係な見出し(関連記事など)へ本文が自動スクロールして
     * しまうことがあった。 */
    [headingTableView deselectAll:nil];
    [headingTableView reloadData];

    /* 本文スクロールビューも、選択解除だけでは前のページのスクロール
     * 位置がそのまま残ってしまうため、明示的に先頭へ戻す。 */
    [bodyTextView scrollRangeToVisible:NSMakeRange(0, 0)];

    /* ページに<title>があればウィンドウタイトルに反映する(通常のブラウザと同じ動作) */
    NSString *pageTitle = [page pageTitle];
    if ([pageTitle length] > 0) {
        [currentStatusKey release];
        currentStatusKey = nil;
        [window setTitle:[NSString stringWithFormat:@"%@ - %@", pageTitle, PWRL(@"appName")]];
    } else {
        [self setStatus:PWRL(@"ready") statusKey:@"ready"];
    }
}

#pragma mark - NSTableViewDataSource / NSTableViewDelegate(非公式プロトコル)

- (int)numberOfRowsInTableView:(NSTableView *)tableView {
    return [[currentPage headings] count];
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)column row:(int)row {
    PWRHeading *heading = [[currentPage headings] objectAtIndex:row];
    NSString *indent = @"";
    if ([heading level] == 2) {
        indent = @"  ";
    } else if ([heading level] == 3) {
        indent = @"    ";
    }
    /* 「・」が無いと同レベルの見出しが並んだ時に記事の切れ目が分かりにくい
     * という報告を受け、先頭に付ける */
    return [NSString stringWithFormat:PWRJPStr("・%@%@"), indent, [heading title]];
}

- (void)tableViewSelectionDidChange:(NSNotification *)note {
    int row = [headingTableView selectedRow];
    if (row < 0 || (unsigned int)row >= [[currentPage headings] count]) {
        return;
    }
    PWRHeading *heading = [[currentPage headings] objectAtIndex:row];

    NSURL *link = [heading linkURL];
    if (link) {
        /* ポータルサイト等、見出しが実質「別記事へのリンク」の場合はページ遷移する */
        [self navigateToURL:link];
        return;
    }

    NSRange range = NSMakeRange([heading bodyLocation], 1);
    [bodyTextView scrollRangeToVisible:range];
}

#pragma mark - NSTextViewDelegate(非公式プロトコル): 本文中のリンクのクリック

- (BOOL)textView:(NSTextView *)textView clickedOnLink:(id)link atIndex:(unsigned)charIndex {
    if (![link isKindOfClass:[PWRLinkTarget class]]) {
        return NO;
    }
    PWRLinkTarget *target = (PWRLinkTarget *)link;

    if ([target kind] == PWRLinkKindPage) {
        /* 関連ニュース/アクセスランキング等、本文中の通常のテキストリンクをクリックした場合。
         * 見出しリンクと同じくページ遷移として扱う */
        [self navigateToURL:[target url]];
        return YES;
    }

    NSURL *imageURL = [target url];

    /* 画像取得中はウィンドウタイトル(ページタイトル表示)を変えず、スピナーのみ回す */
    [progressIndicator startAnimation:nil];

    CurlTaskRunner *runner = [[CurlTaskRunner alloc] initWithDelegate:self];
    [runner fetchURL:imageURL context:imageURL];
    [runner release];
    return YES;
}

#pragma mark - ステータス表示(ウィンドウタイトル)

- (void)setStatus:(NSString *)text statusKey:(NSString *)key {
    [currentStatusKey release];
    currentStatusKey = [key copy];
    [window setTitle:[NSString stringWithFormat:@"%@ - %@", PWRL(@"appName"), text]];
}

@end
