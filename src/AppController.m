#import "AppController.h"
#import "PWRCompat.h"
#import "PWRLocalization.h"

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

@interface AppController (PWRPrivate)
- (void)buildMenuBar;
- (void)buildWindow;
- (void)updateLanguageCheckmarks;
- (void)refreshLocalizedText;
- (void)setStatus:(NSString *)text statusKey:(NSString *)key;
- (void)loadURL:(NSURL *)url;
- (void)navigateToURL:(NSURL *)url;
- (void)displayParsedPage:(PWRParsedPage *)page;
- (void)collapseRightPane;
- (void)expandRightPane;
- (void)rebuildHistoryMenu;
- (void)loadBookmarks;
- (void)saveBookmarks;
- (void)rebuildBookmarkBarButtons;
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
    bookmarkBarHeight = 28.0;
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

    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@""];
    quitMenuItem = [[NSMenuItem alloc] initWithTitle:PWRL(@"quit") action:@selector(terminate:) keyEquivalent:@"q"];
    [quitMenuItem setTarget:NSApp];
    [appMenu addItem:quitMenuItem];
    [appMenuItem setSubmenu:appMenu];
    [appMenu release];
    [appMenuItem release];

    /* 編集メニュー。target=nilで作ることで「今フォーカスしている
     * 入力欄」に自動的にコマンドが飛ぶ(標準的なCocoaの作法)。
     * これが無いとCmd+V等の編集ショートカットがURL欄で効かない。 */
    NSMenuItem *editMenuItem = [[NSMenuItem alloc] initWithTitle:PWRL(@"editMenu") action:NULL keyEquivalent:@""];
    [menubar addItem:editMenuItem];

    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:PWRL(@"editMenu")];
    NSMenuItem *undoItem = [[NSMenuItem alloc] initWithTitle:PWRL(@"undo") action:@selector(undo:) keyEquivalent:@"z"];
    [editMenu addItem:undoItem];
    [undoItem release];
    NSMenuItem *redoItem = [[NSMenuItem alloc] initWithTitle:PWRL(@"redo") action:@selector(redo:) keyEquivalent:@"Z"];
    [redoItem setKeyEquivalentModifierMask:(NSCommandKeyMask | NSShiftKeyMask)];
    [editMenu addItem:redoItem];
    [redoItem release];
    [editMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *cutItem = [[NSMenuItem alloc] initWithTitle:PWRL(@"cut") action:@selector(cut:) keyEquivalent:@"x"];
    [editMenu addItem:cutItem];
    [cutItem release];
    NSMenuItem *copyItem = [[NSMenuItem alloc] initWithTitle:PWRL(@"copy") action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItem:copyItem];
    [copyItem release];
    NSMenuItem *pasteItem = [[NSMenuItem alloc] initWithTitle:PWRL(@"paste") action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItem:pasteItem];
    [pasteItem release];
    [editMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *selectAllItem = [[NSMenuItem alloc] initWithTitle:PWRL(@"selectAll") action:@selector(selectAll:) keyEquivalent:@"a"];
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
    [quitMenuItem setTitle:PWRL(@"quit")];
    [languageMenuItem setTitle:PWRL(@"languageMenu")];
    [hideImageButton setTitle:PWRL(@"hideImage")];
    [self rebuildBookmarkBarButtons]; /* 削除メニューの文言を言語切り替えに追従させる */

    [self updateLanguageCheckmarks];

    if (currentStatusKey) {
        [self setStatus:PWRL(currentStatusKey) statusKey:currentStatusKey];
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
    [window setTitle:PWRJPStr("コダマ")];

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

    /* --- ブックマークバー(アドレスバー直下、ブックマークが1件も無ければ高さ0) --- */
    float shownBookmarkH = ([bookmarks count] > 0) ? bookmarkBarHeight : 0.0;
    NSRect bookmarkBarFrame = NSMakeRect(0.0, contentBounds.size.height - topBarHeight - shownBookmarkH,
                                          contentBounds.size.width, shownBookmarkH);
    bookmarkBarView = [[NSView alloc] initWithFrame:bookmarkBarFrame];
    [bookmarkBarView setAutoresizingMask:(NSViewWidthSizable | NSViewMinYMargin)];
    [bookmarkBarView setHidden:(shownBookmarkH == 0.0)];
    [contentView addSubview:bookmarkBarView];
    [bookmarkBarView release];

    /* --- 3ペインsplit view(右ペインは既定で幅0=折りたたみ) --- */
    NSRect splitFrame = NSMakeRect(0.0, 0.0, contentBounds.size.width,
                                    contentBounds.size.height - topBarHeight - shownBookmarkH);
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
    [self loadURL:url];
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
- (void)rebuildBookmarkBarButtons {
    /* 古いトラッキング矩形を必ず解除してから作り直す。bookmarkBarView自体は
     * 再構築の度に作り直されるわけではないので、放置すると溜まっていく */
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
        [v removeFromSuperview];
    }
    [existingSubviews release];

    float x = 6.0;
    float buttonH = 18.0;
    float maxChipW = 140.0;
    float deleteButtonW = 16.0;
    float y = (bookmarkBarHeight - buttonH) / 2.0;
    int index = 0;
    NSFont *bookmarkFont = [NSFont systemFontOfSize:11.0];

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

        /* 右クリック(control+クリック)でも削除メニューを出せるようにしておく */
        NSMenu *contextMenu = [[NSMenu alloc] initWithTitle:@""];
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

/* ブックマークの有無に応じてブックマークバー/split viewの高さを再計算する。
 * ブックマークが1件も無ければバー自体を高さ0で隠す(折りたたみ式)。 */
- (void)relayoutForBookmarkBarVisibility {
    NSView *contentView = [window contentView];
    NSRect contentBounds = [contentView bounds];
    float topBarH = 36.0;
    float shownH = ([bookmarks count] > 0) ? bookmarkBarHeight : 0.0;

    NSRect bmFrame = NSMakeRect(0.0, contentBounds.size.height - topBarH - shownH,
                                 contentBounds.size.width, shownH);
    [bookmarkBarView setFrame:bmFrame];
    [bookmarkBarView setHidden:(shownH == 0.0)];

    NSRect spFrame = NSMakeRect(0.0, 0.0, contentBounds.size.width,
                                 contentBounds.size.height - topBarH - shownH);
    [splitView setFrame:spFrame];
    [splitView adjustSubviews];
}

/* 履歴には積まずにページを読み込む(戻る操作専用の下位メソッド) */
- (void)loadURL:(NSURL *)url {
    [currentBaseURL release];
    currentBaseURL = [url retain];

    [urlField setStringValue:[url absoluteString]];
    [self collapseRightPane];

    [currentPage release];
    currentPage = nil;
    [[bodyTextView textStorage] setAttributedString:[[[NSAttributedString alloc] initWithString:@""] autorelease]];
    [headingTableView reloadData];

    [self setStatus:PWRL(@"loading") statusKey:@"loading"];
    [progressIndicator startAnimation:nil];

    CurlTaskRunner *runner = [[CurlTaskRunner alloc] initWithDelegate:self];
    [runner fetchURL:url context:@"html"];
    [runner release]; /* fetchURL内部で自己retainするのでここで手放してよい */
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

    /* HTML取得の完了 */
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
    [headingTableView reloadData];

    /* ページに<title>があればウィンドウタイトルに反映する(通常のブラウザと同じ動作) */
    NSString *pageTitle = [page pageTitle];
    if ([pageTitle length] > 0) {
        [currentStatusKey release];
        currentStatusKey = nil;
        [window setTitle:[NSString stringWithFormat:PWRJPStr("%@ - コダマ"), pageTitle]];
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
    [window setTitle:[NSString stringWithFormat:PWRJPStr("コダマ - %@"), text]];
}

@end
