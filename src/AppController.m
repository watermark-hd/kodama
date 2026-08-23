#import "AppController.h"
#import "PWRCompat.h"
#import "PWRLocalization.h"

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
@end

@implementation AppController

#pragma mark - ライフサイクル

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [currentPage release];
    [currentBaseURL release];
    [currentStatusKey release];
    [navigationHistory release];
    [window release];
    [super dealloc];
}

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    rightPaneExpandedWidth = 260.0;
    navigationHistory = [[NSMutableArray alloc] init];

    [self buildMenuBar];
    [self buildWindow];

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
    NSMenuItem *appMenuItem = [[NSMenuItem alloc] initWithTitle:@"PPC-WebReader" action:NULL keyEquivalent:@""];
    [menubar addItem:appMenuItem];

    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@""];
    quitMenuItem = [[NSMenuItem alloc] initWithTitle:PWRL(@"quit") action:@selector(terminate:) keyEquivalent:@"q"];
    [quitMenuItem setTarget:NSApp];
    [appMenu addItem:quitMenuItem];
    [appMenuItem setSubmenu:appMenu];
    [appMenu release];
    [appMenuItem release];

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
    [backButton setTitle:PWRL(@"back")];
    [openButton setTitle:PWRL(@"open")];
    [[headingColumn headerCell] setStringValue:PWRL(@"headings")];
    [quitMenuItem setTitle:PWRL(@"quit")];
    [languageMenuItem setTitle:PWRL(@"languageMenu")];
    [hideImageButton setTitle:PWRL(@"hideImage")];

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
    [window setTitle:@"PPC-WebReader"];

    NSView *contentView = [window contentView];
    NSRect contentBounds = [contentView bounds];
    float topBarHeight = 36.0;

    /* --- 上部バー(URL入力 + 開くボタン) --- */
    NSRect topBarFrame = NSMakeRect(0.0, contentBounds.size.height - topBarHeight,
                                     contentBounds.size.width, topBarHeight);
    topBarView = [[NSView alloc] initWithFrame:topBarFrame];
    [topBarView setAutoresizingMask:(NSViewWidthSizable | NSViewMinYMargin)];

    float buttonWidth = 90.0;
    float backButtonWidth = 70.0;

    NSRect backButtonFrame = NSMakeRect(8.0, 5.0, backButtonWidth, 26.0);
    backButton = [[NSButton alloc] initWithFrame:backButtonFrame];
    [backButton setAutoresizingMask:NSViewMaxXMargin];
    [backButton setBezelStyle:NSRoundedBezelStyle];
    [backButton setTitle:PWRL(@"back")];
    [backButton setTarget:self];
    [backButton setAction:@selector(backAction:)];
    [backButton setEnabled:NO];
    [topBarView addSubview:backButton];

    float urlFieldX = 8.0 + backButtonWidth + 8.0;
    float spinnerWidth = 20.0;
    NSRect urlFieldFrame = NSMakeRect(urlFieldX, 7.0,
                                       topBarFrame.size.width - urlFieldX - buttonWidth - spinnerWidth - 24.0, 22.0);
    urlField = [[NSTextField alloc] initWithFrame:urlFieldFrame];
    [urlField setAutoresizingMask:NSViewWidthSizable];
    [urlField setTarget:self];
    [urlField setAction:@selector(openAction:)];
    [topBarView addSubview:urlField];

    NSRect spinnerFrame = NSMakeRect(NSMaxX(urlFieldFrame) + 6.0, 8.0, spinnerWidth, spinnerWidth);
    progressIndicator = [[NSProgressIndicator alloc] initWithFrame:spinnerFrame];
    [progressIndicator setAutoresizingMask:NSViewMinXMargin];
    [progressIndicator setStyle:NSProgressIndicatorSpinningStyle];
    [progressIndicator setDisplayedWhenStopped:NO];
    [topBarView addSubview:progressIndicator];

    NSRect openButtonFrame = NSMakeRect(topBarFrame.size.width - buttonWidth - 8.0, 5.0, buttonWidth, 26.0);
    openButton = [[NSButton alloc] initWithFrame:openButtonFrame];
    [openButton setAutoresizingMask:NSViewMinXMargin];
    [openButton setBezelStyle:NSRoundedBezelStyle];
    [openButton setTitle:PWRL(@"open")];
    [openButton setTarget:self];
    [openButton setAction:@selector(openAction:)];
    [topBarView addSubview:openButton];

    [contentView addSubview:topBarView];
    [window setDefaultButtonCell:[openButton cell]];
    [topBarView release];
    [backButton release];
    [urlField release];
    [progressIndicator release];
    [openButton release];

    /* --- 3ペインsplit view(右ペインは既定で幅0=折りたたみ) --- */
    NSRect splitFrame = NSMakeRect(0.0, 0.0, contentBounds.size.width, contentBounds.size.height - topBarHeight);
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

- (void)openAction:(id)sender {
    NSString *text = [urlField stringValue];
    text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([text length] == 0) {
        return;
    }

    NSURL *url = [NSURL URLWithString:text];
    if (!url || ![url scheme]) {
        /* スキームが省略されていたらhttps://を補う */
        url = [NSURL URLWithString:[@"https://" stringByAppendingString:text]];
    }
    if (!url) {
        return;
    }

    [self navigateToURL:url];
}

/* 現在表示中のページがあれば履歴に積んでから新しいページへ移動する。
 * (URL欄からの入力・見出しリンクのクリックの両方から呼ばれる) */
- (void)navigateToURL:(NSURL *)url {
    if (currentBaseURL) {
        [navigationHistory addObject:currentBaseURL];
        [backButton setEnabled:YES];
    }
    [self loadURL:url];
}

- (void)backAction:(id)sender {
    if ([navigationHistory count] == 0) {
        return;
    }
    NSURL *previous = [[navigationHistory lastObject] retain];
    [navigationHistory removeLastObject];
    [backButton setEnabled:([navigationHistory count] > 0)];
    [self loadURL:previous];
    [previous release];
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
    [currentPage release];
    currentPage = [page retain];

    [[bodyTextView textStorage] setAttributedString:[page bodyText]];
    [headingTableView reloadData];

    /* ページに<title>があればウィンドウタイトルに反映する(通常のブラウザと同じ動作) */
    NSString *pageTitle = [page pageTitle];
    if ([pageTitle length] > 0) {
        [currentStatusKey release];
        currentStatusKey = nil;
        [window setTitle:[NSString stringWithFormat:@"%@ - PPC-WebReader", pageTitle]];
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
    return [indent stringByAppendingString:[heading title]];
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

#pragma mark - NSTextViewDelegate(非公式プロトコル): 画像リンクのクリック

- (BOOL)textView:(NSTextView *)textView clickedOnLink:(id)link atIndex:(unsigned)charIndex {
    if (![link isKindOfClass:[NSURL class]]) {
        return NO;
    }
    NSURL *imageURL = (NSURL *)link;

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
    [window setTitle:[NSString stringWithFormat:@"PPC-WebReader - %@", text]];
}

@end
