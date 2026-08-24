#import "HTMLParserEngine.h"
#import "PWRCompat.h"
#import "PWRLocalization.h"
#include <libxml/HTMLparser.h>
#include <libxml/tree.h>
#include <libxml/xmlstring.h>
#include <string.h>

#pragma mark - 文字エンコーディング検出

/* HTMLの先頭付近からmeta charsetの宣言を素朴に読み取る。
 * このlibxml2(2.6.16)はエンコーディング自動検出が不安定で、
 * Shift_JIS宣言のページ(ITmedia等)で文字化けすることを実機で
 * 確認したため、検出できた場合は明示的にhtmlReadMemoryへ
 * エンコーディング名を渡すようにする。 */
static NSString *PWRDetectCharset(NSData *htmlData) {
    unsigned int scanLen = [htmlData length] < 4096 ? [htmlData length] : 4096;
    NSMutableData *working = [NSMutableData dataWithBytes:[htmlData bytes] length:scanLen];
    [working appendBytes:"\0" length:1];
    const char *base = (const char *)[working bytes];

    const char *marker = strcasestr(base, "charset=");
    if (!marker) {
        return nil;
    }
    marker += strlen("charset=");

    while (*marker == '"' || *marker == '\'' || *marker == ' ') {
        marker++;
    }

    char buf[64];
    unsigned int i = 0;
    while (i < sizeof(buf) - 1 && marker[i] &&
           marker[i] != '"' && marker[i] != '\'' && marker[i] != ' ' &&
           marker[i] != ';' && marker[i] != '>' && marker[i] != '\n' && marker[i] != '\r') {
        buf[i] = marker[i];
        i++;
    }
    buf[i] = '\0';

    if (i == 0) {
        return nil;
    }
    return [NSString stringWithUTF8String:buf];
}

#pragma mark - script/styleの生テキスト除去(libxml2に渡す前の前処理)

/* このlibxml2(2.6.16)のHTMLパーサーは、<script>の中身をHTML5仕様通りの
 * 「閉じタグが出るまで完全な生テキスト」として扱えないことがある。
 * 実際のニュースサイトで、JSのテンプレートリテラル内に書かれた
 * "<div class=...>" のようなタグっぽい文字列を見て、誤ってscript要素の
 * 外に出たと誤認識し、以降のJSコードがそのまま本文に漏れて表示される
 * 問題を確認した。パーサーに渡す前に、生バイト列の段階で該当タグの
 * 中身を確実に取り除いてこれを回避する。 */
/* script/styleの両方を1回の走査で取り除く。
 * 以前はscript用・style用で別々に(コピー→走査→コピー)を行っており、
 * ページ全体のバイト列を都合4回複製していた。G3のような非力な機体では
 * この前処理だけでも無視できないコストになるため、NUL終端用の複製を
 * 1回だけにし、script/styleどちらが先に出てきても1パスで処理する。 */
static NSData *PWRStripRawTextBlocks(NSData *htmlData) {
    NSMutableData *working = [NSMutableData dataWithData:htmlData]; /* strcasestr/strchr用にNUL終端(1回だけ) */
    [working appendBytes:"\0" length:1];

    const char *base = (const char *)[working bytes];
    long totalLen = (long)[working length] - 1;

    NSMutableData *result = [NSMutableData dataWithCapacity:(unsigned)totalLen];
    long pos = 0;
    while (pos < totalLen) {
        const char *scriptOpen = strcasestr(base + pos, "<script");
        const char *styleOpen = strcasestr(base + pos, "<style");

        const char *foundOpen;
        const char *closeTag;
        if (scriptOpen && (!styleOpen || scriptOpen < styleOpen)) {
            foundOpen = scriptOpen;
            closeTag = "</script";
        } else if (styleOpen) {
            foundOpen = styleOpen;
            closeTag = "</style";
        } else {
            foundOpen = NULL;
            closeTag = NULL;
        }

        if (!foundOpen) {
            [result appendBytes:(base + pos) length:(totalLen - pos)];
            break;
        }
        long openStart = foundOpen - base;
        [result appendBytes:(base + pos) length:(openStart - pos)];

        const char *gt = strchr(foundOpen, '>');
        if (!gt) {
            /* 開始タグ自体が壊れている場合はそれ以降を丸ごと捨てて終了 */
            break;
        }
        long afterOpenTag = (gt - base) + 1;

        const char *foundClose = strcasestr(base + afterOpenTag, closeTag);
        long nextPos;
        if (foundClose) {
            const char *closeGt = strchr(foundClose, '>');
            nextPos = closeGt ? (closeGt - base) + 1 : totalLen;
        } else {
            nextPos = totalLen; /* 閉じタグが無ければ末尾まで捨てる */
        }
        pos = nextPos;
    }

    return result;
}

#pragma mark - PWRLinkTarget

@implementation PWRLinkTarget

- (id)initWithURL:(NSURL *)aURL kind:(PWRLinkKind)aKind {
    self = [super init];
    if (self) {
        url = [aURL retain];
        kind = aKind;
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

- (PWRLinkKind)kind {
    return kind;
}

@end

#pragma mark - PWRHeading

@implementation PWRHeading

- (id)initWithTitle:(NSString *)aTitle
              level:(int)aLevel
       bodyLocation:(unsigned int)aLocation
            linkURL:(NSURL *)aLinkURL {
    self = [super init];
    if (self) {
        title = [aTitle copy];
        level = aLevel;
        bodyLocation = aLocation;
        linkURL = [aLinkURL retain];
    }
    return self;
}

- (void)dealloc {
    [title release];
    [linkURL release];
    [super dealloc];
}

- (NSString *)title {
    return title;
}

- (int)level {
    return level;
}

- (NSURL *)linkURL {
    return linkURL;
}

- (unsigned int)bodyLocation {
    return bodyLocation;
}

@end

#pragma mark - PWRParsedPage

@implementation PWRParsedPage

- (id)initWithHeadings:(NSArray *)aHeadings
               bodyText:(NSAttributedString *)aBodyText
              imageURLs:(NSArray *)anImageURLs
              pageTitle:(NSString *)aPageTitle
         metaRefreshURL:(NSURL *)aMetaRefreshURL {
    self = [super init];
    if (self) {
        headings = [aHeadings copy];
        bodyText = [aBodyText copy];
        imageURLs = [anImageURLs copy];
        pageTitle = [aPageTitle copy];
        metaRefreshURL = [aMetaRefreshURL retain];
    }
    return self;
}

- (void)dealloc {
    [headings release];
    [bodyText release];
    [imageURLs release];
    [pageTitle release];
    [metaRefreshURL release];
    [super dealloc];
}

- (NSString *)pageTitle {
    return pageTitle;
}

- (NSURL *)metaRefreshURL {
    return metaRefreshURL;
}

- (NSArray *)headings {
    return headings;
}

- (NSAttributedString *)bodyText {
    return bodyText;
}

- (NSArray *)imageURLs {
    return imageURLs;
}

@end

#pragma mark - DOM走査用の内部コンテキスト(libxml2のCツリーをたどりながら組み立てる)

typedef struct {
    NSMutableArray *headings;
    NSMutableAttributedString *body;
    NSMutableArray *imageURLs;
    NSURL *baseURL;
} PWRWalkContext;

static NSString *PWRStringFromXmlChar(const xmlChar *s) {
    if (!s) {
        return @"";
    }
    return [NSString stringWithUTF8String:(const char *)s];
}

/* 連続する空白・改行を半角スペース1個に圧縮する。
 * 空白だけのテキストノード(要素と要素の間の区切り)は完全に消さず
 * 半角スペース1個として残すことで、"text<a>link</a>more" のような
 * 単語同士がくっついてしまうのを防ぐ。 */
static NSString *PWRCollapseWhitespace(NSString *s) {
    if ([s length] == 0) {
        return @"";
    }
    NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSString *trimmed = [s stringByTrimmingCharactersInSet:ws];
    if ([trimmed length] == 0) {
        return @" ";
    }

    /* Tiger(10.4)のFoundationにはcomponentsSeparatedByCharactersInSet:が
     * 存在しない(Leopard以降のAPI)ため、NSScannerで単語ごとに拾う */
    NSMutableArray *nonEmptyParts = [NSMutableArray array];
    NSScanner *scanner = [NSScanner scannerWithString:trimmed];
    [scanner setCharactersToBeSkipped:nil];
    while (![scanner isAtEnd]) {
        [scanner scanCharactersFromSet:ws intoString:NULL];
        NSString *word = nil;
        if ([scanner scanUpToCharactersFromSet:ws intoString:&word] && [word length] > 0) {
            [nonEmptyParts addObject:word];
        }
    }
    NSString *collapsed = [nonEmptyParts componentsJoinedByString:@" "];

    if ([ws characterIsMember:[s characterAtIndex:0]]) {
        collapsed = [@" " stringByAppendingString:collapsed];
    }
    if ([ws characterIsMember:[s characterAtIndex:([s length] - 1)]]) {
        collapsed = [collapsed stringByAppendingString:@" "];
    }
    return collapsed;
}

static void PWRAppendPlain(NSString *text, PWRWalkContext *ctx) {
    if ([text length] == 0) {
        return;
    }
    NSAttributedString *chunk = [[NSAttributedString alloc] initWithString:text];
    [ctx->body appendAttributedString:chunk];
    [chunk release];
}

/* 直前の要素が改行なしで終わっている場合に改行を1つ補う。
 * ブロック要素の"後ろ"にしか区切りを入れていないと、直前の要素との
 * 間に何も無かった場合(例: <nav>ホーム</nav><h1>...</h1>)にテキストが
 * くっついてしまうため、ブロック要素の"前"にも保険として呼ぶ。 */
static void PWREnsureSeparation(PWRWalkContext *ctx) {
    unsigned int len = [ctx->body length];
    if (len == 0) {
        return;
    }
    if ([[ctx->body string] characterAtIndex:(len - 1)] != '\n') {
        PWRAppendPlain(@"\n", ctx);
    }
}

/* PWREnsureSeparationと同じ判定を、bodyの末尾ではなく指定位置(pos)の
 * 直前に対して行い、必要なら改行をその位置へ挿入する。ブロック要素の
 * 中身を後から追加してみて実際に何か残った場合にだけ区切りを入れたい
 * ケース(PWRAppendNodeのisBlock処理)で使う。 */
static void PWRInsertSeparationAt(PWRWalkContext *ctx, unsigned int pos) {
    if (pos == 0) {
        return;
    }
    if ([[ctx->body string] characterAtIndex:(pos - 1)] != '\n') {
        NSAttributedString *nl = [[NSAttributedString alloc] initWithString:@"\n"];
        [ctx->body insertAttributedString:nl atIndex:pos];
        [nl release];
    }
}

/* class/id名にナビゲーション由来と分かる特徴的な語を含む要素を除外する。
 * <nav>タグを使わずdivでメニューを組んでいるサイト(FNN等)向けの対策。
 * "nav"や"header"のような一般的すぎる語は記事本文側のクラス名(例:
 * article-header)を誤って除外してしまう恐れがあるため避け、
 * 実サイトで確認できた"gnav"のような誤検知の少ない語に絞っている。
 * BrandText/OwnedAd/SuperBanner/SideLink/in-feed-Nativeは、ITmedia等が
 * 使っているGoogle Ad Manager系の広告枠class/idで実サイトで確認した。 */
static BOOL PWRHasNavigationLikeClass(xmlNode *node) {
    static const char *keywords[] = {
        "gnav", "navi", "globalnav", "global-nav", "breadcrumb", "pankuzu", "drawer", "hamburger",
        "related", "sns-share", "pagetop",
        "BrandText", "OwnedAd", "SuperBanner", "SideLink", "in-feed-Native",
        "ranking-link", "related-article", "relation-link", "recommend-media",
        "mailmagazine", "comment-input", "CommentWidget", "p-header"
    };
    static const int keywordCount = 24;
    static const char *attrNames[] = {"class", "id"};
    static const int attrCount = 2;
    int a, k;

    for (a = 0; a < attrCount; a++) {
        xmlChar *val = xmlGetProp(node, (const xmlChar *)attrNames[a]);
        if (!val) {
            continue;
        }
        for (k = 0; k < keywordCount; k++) {
            if (strcasestr((const char *)val, keywords[k])) {
                xmlFree(val);
                return YES;
            }
        }
        xmlFree(val);
    }

    /* Yahoo! JAPAN独自のクリック計測属性(実サイトのHTMLで確認:
     * _cl_vmodule:header/gnavi/fnavi/snavi/toplink/tool/related/pagetop等)。
     * Yahoo!のclass名はビルドのたびに変わるハッシュ値(styled-components製)
     * で全く当てにならない一方、この属性の値は意味のある固定語で、かつ
     * 記事本文側では別の語彙(detail/accr/sf等)が使われることを確認済み
     * なので、"header"のようなclass/idでは避けている単体では汎用的すぎる
     * 語もここでは"vmodule:"付きで安全に使える。他サイトにはまず
     * 存在しない属性なので、ここでの判定が他サイトへ影響することもない。 */
    xmlChar *clParams = xmlGetProp(node, (const xmlChar *)"data-cl-params");
    if (clParams) {
        static const char *clKeywords[] = {
            "vmodule:header", "vmodule:gnavi", "vmodule:fnavi", "vmodule:snavi",
            "vmodule:toplink", "vmodule:tool", "vmodule:related", "vmodule:pagetop",
            "vmodule:search", "vmodule:message"
        };
        static const int clKeywordCount = 10;
        for (k = 0; k < clKeywordCount; k++) {
            if (strcasestr((const char *)clParams, clKeywords[k])) {
                xmlFree(clParams);
                return YES;
            }
        }
        xmlFree(clParams);
    }

    return NO;
}

static xmlNode *PWRFindNodeByName(xmlNode *node, const char *name) {
    xmlNode *cur;
    for (cur = node; cur; cur = cur->next) {
        if (cur->type == XML_ELEMENT_NODE &&
            xmlStrcasecmp(cur->name, (const xmlChar *)name) == 0) {
            return cur;
        }
        if (cur->children) {
            xmlNode *found = PWRFindNodeByName(cur->children, name);
            if (found) {
                return found;
            }
        }
    }
    return NULL;
}

/* <meta http-equiv="refresh" content="0;URL=...">での自動転送先を探す。
 * DuckDuckGoの検索結果リンク等、HTTPリダイレクトではなくこの仕組みで
 * 転送する「クッションページ」が実サイトに多いことを実機で確認したため、
 * これが無いとクリックしても何も表示されない(空白のまま)問題があった。 */
static NSURL *PWRFindMetaRefreshURL(xmlNode *node, NSURL *baseURL) {
    xmlNode *cur;
    for (cur = node; cur; cur = cur->next) {
        if (cur->type == XML_ELEMENT_NODE && xmlStrcasecmp(cur->name, (const xmlChar *)"meta") == 0) {
            xmlChar *httpEquiv = xmlGetProp(cur, (const xmlChar *)"http-equiv");
            BOOL isRefresh = (httpEquiv && xmlStrcasecmp(httpEquiv, (const xmlChar *)"refresh") == 0);
            if (httpEquiv) {
                xmlFree(httpEquiv);
            }
            if (isRefresh) {
                xmlChar *content = xmlGetProp(cur, (const xmlChar *)"content");
                if (content) {
                    NSString *contentStr = PWRStringFromXmlChar(content);
                    xmlFree(content);
                    NSRange urlRange = [contentStr rangeOfString:@"url=" options:NSCaseInsensitiveSearch];
                    if (urlRange.location != NSNotFound) {
                        NSString *urlPart = [contentStr substringFromIndex:NSMaxRange(urlRange)];
                        urlPart = [urlPart stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                        if ([urlPart length] >= 2) {
                            unichar first = [urlPart characterAtIndex:0];
                            unichar last = [urlPart characterAtIndex:([urlPart length] - 1)];
                            if ((first == '"' && last == '"') || (first == '\'' && last == '\'')) {
                                urlPart = [urlPart substringWithRange:NSMakeRange(1, [urlPart length] - 2)];
                            }
                        }
                        NSURL *resolved = [[NSURL URLWithString:urlPart relativeToURL:baseURL] absoluteURL];
                        if (resolved) {
                            return resolved;
                        }
                    }
                }
            }
        }
        if (cur->children) {
            NSURL *found = PWRFindMetaRefreshURL(cur->children, baseURL);
            if (found) {
                return found;
            }
        }
    }
    return NULL;
}

/* 見出し内に最初に見つかった<a href>のリンク先を探す(見出し=リンクの判定用)。
 * ポータルサイトのように見出しが実質「別記事へのリンク」であるケースに対応する。 */
static NSURL *PWRFindHrefInSubtree(xmlNode *node, NSURL *baseURL) {
    xmlNode *cur;
    for (cur = node; cur; cur = cur->next) {
        if (cur->type == XML_ELEMENT_NODE) {
            if (xmlStrcasecmp(cur->name, (const xmlChar *)"a") == 0) {
                xmlChar *href = xmlGetProp(cur, (const xmlChar *)"href");
                if (href) {
                    NSString *hrefStr = PWRStringFromXmlChar(href);
                    xmlFree(href);
                    NSURL *resolved = [[NSURL URLWithString:hrefStr relativeToURL:baseURL] absoluteURL];
                    if (resolved) {
                        return resolved;
                    }
                }
            }
            if (cur->children) {
                NSURL *found = PWRFindHrefInSubtree(cur->children, baseURL);
                if (found) {
                    return found;
                }
            }
        }
    }
    return NULL;
}

/* 見出しの外側(祖先)に<a href>が無いか探す。
 * <a href="..."><h3>見出し</h3></a> のように、見出しの方がリンクに
 * 包まれているカード型マークアップ(ニュース一覧などで多い)に対応する。 */
static NSURL *PWRFindHrefInAncestors(xmlNode *node, NSURL *baseURL) {
    xmlNode *cur = node->parent;
    while (cur && cur->type == XML_ELEMENT_NODE) {
        if (xmlStrcasecmp(cur->name, (const xmlChar *)"a") == 0) {
            xmlChar *href = xmlGetProp(cur, (const xmlChar *)"href");
            if (href) {
                NSString *hrefStr = PWRStringFromXmlChar(href);
                xmlFree(href);
                NSURL *resolved = [[NSURL URLWithString:hrefStr relativeToURL:baseURL] absoluteURL];
                if (resolved) {
                    return resolved;
                }
            }
        }
        cur = cur->parent;
    }
    return NULL;
}

static void PWRAppendNode(xmlNode *node, PWRWalkContext *ctx);

static void PWRAppendChildren(xmlNode *node, PWRWalkContext *ctx) {
    xmlNode *child;
    for (child = node->children; child; child = child->next) {
        PWRAppendNode(child, ctx);
    }
}

static void PWRAppendNode(xmlNode *node, PWRWalkContext *ctx) {
    if (node->type == XML_TEXT_NODE || node->type == XML_CDATA_SECTION_NODE) {
        NSString *collapsed = PWRCollapseWhitespace(PWRStringFromXmlChar(node->content));
        if ([collapsed isEqualToString:@" "]) {
            /* 空白のみのテキストノード。改行の直後(=タグ間インデント由来)なら
             * 単語区切りとしての意味を持たないので無視する */
            unsigned int len = [ctx->body length];
            if (len == 0 || [[ctx->body string] characterAtIndex:(len - 1)] == '\n') {
                return;
            }
        }
        PWRAppendPlain(collapsed, ctx);
        return;
    }
    if (node->type != XML_ELEMENT_NODE) {
        return;
    }

    const xmlChar *name = node->name;

    /* 中身ごと無視するタグ。
     * <header>は記事タイトルを内包しているサイトもあるため対象外にしている。
     * (ナビゲーションが多いポータルサイト等ではまだノイズが残りうる)
     * svg/video/audio/object/embed/canvas/mapはテキストを持たず、特に
     * アイコンスプライト用のsvgは内部に数百のpath/g要素を抱えることが
     * あるため、丸ごと読み飛ばして無駄な走査を避ける。 */
    if (xmlStrcasecmp(name, (const xmlChar *)"script") == 0 ||
        xmlStrcasecmp(name, (const xmlChar *)"style") == 0 ||
        xmlStrcasecmp(name, (const xmlChar *)"head") == 0 ||
        xmlStrcasecmp(name, (const xmlChar *)"noscript") == 0 ||
        xmlStrcasecmp(name, (const xmlChar *)"iframe") == 0 ||
        xmlStrcasecmp(name, (const xmlChar *)"nav") == 0 ||
        xmlStrcasecmp(name, (const xmlChar *)"footer") == 0 ||
        xmlStrcasecmp(name, (const xmlChar *)"svg") == 0 ||
        xmlStrcasecmp(name, (const xmlChar *)"video") == 0 ||
        xmlStrcasecmp(name, (const xmlChar *)"audio") == 0 ||
        xmlStrcasecmp(name, (const xmlChar *)"object") == 0 ||
        xmlStrcasecmp(name, (const xmlChar *)"embed") == 0 ||
        xmlStrcasecmp(name, (const xmlChar *)"canvas") == 0 ||
        xmlStrcasecmp(name, (const xmlChar *)"map") == 0) {
        return;
    }
    if (PWRHasNavigationLikeClass(node)) {
        return;
    }

    if (xmlStrcasecmp(name, (const xmlChar *)"br") == 0) {
        PWRAppendPlain(@"\n", ctx);
        return;
    }

    if (xmlStrcasecmp(name, (const xmlChar *)"img") == 0) {
        xmlChar *srcAttr = xmlGetProp(node, (const xmlChar *)"src");
        if (srcAttr) {
            NSString *srcStr = PWRStringFromXmlChar(srcAttr);
            xmlFree(srcAttr);
            NSURL *resolved = [[NSURL URLWithString:srcStr relativeToURL:ctx->baseURL] absoluteURL];
            if (resolved) {
                [ctx->imageURLs addObject:resolved];
                unsigned long index = [ctx->imageURLs count];
                /* Tiger(2005年)にはApple Color Emojiフォントが存在しないため、
                 * 仕様書にある絵文字プレースホルダーは使わずASCII安全な表記にする */

                /* alt属性があればラベルに含める。天気図・避難所情報等の
                 * 画像はaltが付いていることが多く、広告画像は空のことが
                 * 多いため、番号だけより目的の画像を見分けやすくなる。 */
                NSString *placeholder;
                xmlChar *altAttr = xmlGetProp(node, (const xmlChar *)"alt");
                NSString *altStr = altAttr ? PWRCollapseWhitespace(PWRStringFromXmlChar(altAttr)) : @"";
                if (altAttr) {
                    xmlFree(altAttr);
                }
                altStr = [altStr stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if ([altStr length] > 30) {
                    altStr = [[altStr substringToIndex:30] stringByAppendingString:PWRJPStr("…")];
                }

                if ([altStr length] > 0) {
                    placeholder = [NSString stringWithFormat:PWRL(@"showImageWithAlt"), index, altStr];
                } else {
                    placeholder = [NSString stringWithFormat:PWRL(@"showImage"), index];
                }

                PWRLinkTarget *target = [[PWRLinkTarget alloc] initWithURL:resolved kind:PWRLinkKindImage];
                NSMutableDictionary *attrs = [NSMutableDictionary dictionary];
                [attrs setObject:target forKey:NSLinkAttributeName];
                [attrs setObject:[NSColor blueColor] forKey:NSForegroundColorAttributeName];
                NSAttributedString *link = [[NSAttributedString alloc] initWithString:placeholder attributes:attrs];
                [ctx->body appendAttributedString:link];
                [link release];
                [target release];
            }
        }
        return;
    }

    if (xmlStrcasecmp(name, (const xmlChar *)"a") == 0) {
        xmlChar *hrefAttr = xmlGetProp(node, (const xmlChar *)"href");
        NSURL *resolved = nil;
        if (hrefAttr) {
            NSString *hrefStr = PWRStringFromXmlChar(hrefAttr);
            xmlFree(hrefAttr);
            resolved = [[NSURL URLWithString:hrefStr relativeToURL:ctx->baseURL] absoluteURL];
        }

        unsigned int before = [ctx->body length];
        PWRAppendChildren(node, ctx);
        unsigned int after = [ctx->body length];

        /* リンク先が取れた場合だけ、実際に流し込まれたテキスト範囲に
         * クリック可能なページ遷移リンクとしての属性を後付けする。
         * (関連ニュース/アクセスランキング等、見出しタグを使わない
         * 一覧リンクを辿れるようにするための対応) */
        if (resolved && after > before) {
            PWRLinkTarget *target = [[PWRLinkTarget alloc] initWithURL:resolved kind:PWRLinkKindPage];
            [ctx->body addAttribute:NSLinkAttributeName value:target range:NSMakeRange(before, after - before)];
            [ctx->body addAttribute:NSForegroundColorAttributeName value:[NSColor blueColor]
                               range:NSMakeRange(before, after - before)];
            [target release];
        }
        return;
    }

    {
        int headingLevel = 0;
        if (xmlStrcasecmp(name, (const xmlChar *)"h1") == 0) {
            headingLevel = 1;
        } else if (xmlStrcasecmp(name, (const xmlChar *)"h2") == 0) {
            headingLevel = 2;
        } else if (xmlStrcasecmp(name, (const xmlChar *)"h3") == 0) {
            headingLevel = 3;
        }

        if (headingLevel > 0) {
            PWREnsureSeparation(ctx);
            unsigned int before = [ctx->body length];

            PWRAppendChildren(node, ctx);

            unsigned int after = [ctx->body length];
            if (after > before) {
                [ctx->body addAttribute:NSFontAttributeName
                                   value:[NSFont boldSystemFontOfSize:13.0]
                                   range:NSMakeRange(before, after - before)];
            }

            NSString *titleText = [[ctx->body string] substringWithRange:NSMakeRange(before, after - before)];
            /* サイトによっては見出しタグの中に本文の抜粋(<p>等)がネストして
             * いることがあり、そのままだと見出しリストに長大な文章が
             * 表示されてしまう。見出しは本来1行のはずなので、最初の
             * 改行で打ち切って左ペインの表示用テキストとする */
            NSRange firstNewline = [titleText rangeOfString:@"\n"];
            if (firstNewline.location != NSNotFound) {
                titleText = [titleText substringToIndex:firstNewline.location];
                titleText = [titleText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            }
            NSURL *headingLinkURL = PWRFindHrefInSubtree(node->children, ctx->baseURL);
            if (!headingLinkURL) {
                headingLinkURL = PWRFindHrefInAncestors(node, ctx->baseURL);
            }
            PWRHeading *heading = [[PWRHeading alloc] initWithTitle:titleText
                                                                level:headingLevel
                                                         bodyLocation:before
                                                              linkURL:headingLinkURL];
            [ctx->headings addObject:heading];
            [heading release];

            PWRAppendPlain(@"\n\n", ctx);
            return;
        }
    }

    {
        /* リスト項目は段落と違い前後に空白行を入れず、行頭に「・」を付けて
         * 詰めて並べる(ランキング/関連記事一覧が間延びして見えるのを防ぐ) */
        BOOL isListItem = xmlStrcasecmp(name, (const xmlChar *)"li") == 0;
        BOOL isBlock = isListItem ||
                       xmlStrcasecmp(name, (const xmlChar *)"p") == 0 ||
                       xmlStrcasecmp(name, (const xmlChar *)"blockquote") == 0 ||
                       xmlStrcasecmp(name, (const xmlChar *)"h4") == 0 ||
                       xmlStrcasecmp(name, (const xmlChar *)"h5") == 0 ||
                       xmlStrcasecmp(name, (const xmlChar *)"h6") == 0;

        /* div/article/section/ul/a/span/strongなどはここに落ちてきて、
         * 透過的なコンテナとして子要素をそのまま辿るだけになる */
        unsigned int before = [ctx->body length];
        PWRAppendChildren(node, ctx);
        unsigned int after = [ctx->body length];

        /* 中身がナビ/広告判定で丸ごと除去され実質空になった場合、「・」や
         * 段落の区切りだけが残ってしまう(例: Yahoo!のヘッダーメニューの
         * ようにテキストにだけ計測用属性が付いているケース)。実際に
         * 何か追加された時だけ、前後の区切りを後から挿入する。 */
        if (after == before) {
            return;
        }

        if (isListItem) {
            NSAttributedString *bullet = [[NSAttributedString alloc] initWithString:PWRJPStr("・ ")];
            [ctx->body insertAttributedString:bullet atIndex:before];
            [bullet release];
            PWRAppendPlain(@"\n", ctx);
        } else if (isBlock) {
            PWRInsertSeparationAt(ctx, before);
            PWRAppendPlain(@"\n\n", ctx);
        }
    }
}

#pragma mark - HTMLParserEngine

@implementation HTMLParserEngine

+ (PWRParsedPage *)parsePageFromData:(NSData *)htmlData baseURL:(NSURL *)baseURL {
    if ([htmlData length] == 0) {
        return nil;
    }

    NSData *cleanedData = PWRStripRawTextBlocks(htmlData);
    NSString *charset = PWRDetectCharset(htmlData);
    const char *encodingCString = charset ? [charset UTF8String] : NULL;

    const char *urlCString = baseURL ? [[baseURL absoluteString] UTF8String] : NULL;
    /* このlibxml2(2.6.16, Tiger標準)にはHTML_PARSE_RECOVERが存在しない。
     * HTMLパーサーはデフォルトで壊れたHTMLを寛容に読むため無くても問題ない */
    htmlDocPtr doc = htmlReadMemory([cleanedData bytes], [cleanedData length], urlCString, encodingCString,
                                     HTML_PARSE_NOERROR | HTML_PARSE_NOWARNING | HTML_PARSE_NONET);
    if (!doc) {
        return nil;
    }

    xmlNode *root = xmlDocGetRootElement(doc);
    xmlNode *bodyNode = root ? PWRFindNodeByName(root, "body") : NULL;

    PWRWalkContext ctx;
    ctx.headings = [NSMutableArray array];
    ctx.body = [[NSMutableAttributedString alloc] init];
    ctx.imageURLs = [NSMutableArray array];
    ctx.baseURL = baseURL;

    if (bodyNode) {
        PWRAppendChildren(bodyNode, &ctx);
    } else if (root) {
        PWRAppendChildren(root, &ctx);
    }

    /* ウィンドウタイトル表示用に<title>タグの中身も拾っておく */
    NSString *pageTitle = nil;
    xmlNode *titleNode = root ? PWRFindNodeByName(root, "title") : NULL;
    if (titleNode) {
        xmlChar *content = xmlNodeGetContent(titleNode);
        if (content) {
            pageTitle = PWRCollapseWhitespace(PWRStringFromXmlChar(content));
            xmlFree(content);
        }
    }

    NSURL *metaRefreshURL = root ? PWRFindMetaRefreshURL(root, baseURL) : nil;

    xmlFreeDoc(doc);

    PWRParsedPage *page = [[[PWRParsedPage alloc] initWithHeadings:ctx.headings
                                                            bodyText:ctx.body
                                                           imageURLs:ctx.imageURLs
                                                           pageTitle:pageTitle
                                                      metaRefreshURL:metaRefreshURL] autorelease];
    [ctx.body release];
    return page;
}

@end
