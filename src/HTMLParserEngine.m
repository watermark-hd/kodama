#import "HTMLParserEngine.h"
#import "PWRCompat.h"
#include <libxml/HTMLparser.h>
#include <libxml/tree.h>
#include <libxml/xmlstring.h>
#include <string.h>

#pragma mark - script/styleの生テキスト除去(libxml2に渡す前の前処理)

/* このlibxml2(2.6.16)のHTMLパーサーは、<script>の中身をHTML5仕様通りの
 * 「閉じタグが出るまで完全な生テキスト」として扱えないことがある。
 * 実際のニュースサイトで、JSのテンプレートリテラル内に書かれた
 * "<div class=...>" のようなタグっぽい文字列を見て、誤ってscript要素の
 * 外に出たと誤認識し、以降のJSコードがそのまま本文に漏れて表示される
 * 問題を確認した。パーサーに渡す前に、生バイト列の段階で該当タグの
 * 中身を確実に取り除いてこれを回避する。 */
static NSData *PWRStripTagBlock(NSData *data, const char *tagName) {
    NSMutableData *working = [NSMutableData dataWithData:data];
    [working appendBytes:"\0" length:1]; /* strcasestr/strchr用にNUL終端 */

    const char *base = (const char *)[working bytes];
    long totalLen = (long)[working length] - 1;

    char openTag[24];
    char closeTag[24];
    snprintf(openTag, sizeof(openTag), "<%s", tagName);
    snprintf(closeTag, sizeof(closeTag), "</%s", tagName);

    NSMutableData *result = [NSMutableData dataWithCapacity:(unsigned)totalLen];
    long pos = 0;
    while (pos < totalLen) {
        const char *foundOpen = strcasestr(base + pos, openTag);
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

static NSData *PWRStripRawTextBlocks(NSData *htmlData) {
    NSData *noScript = PWRStripTagBlock(htmlData, "script");
    NSData *noStyle = PWRStripTagBlock(noScript, "style");
    return noStyle;
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
              pageTitle:(NSString *)aPageTitle {
    self = [super init];
    if (self) {
        headings = [aHeadings copy];
        bodyText = [aBodyText copy];
        imageURLs = [anImageURLs copy];
        pageTitle = [aPageTitle copy];
    }
    return self;
}

- (void)dealloc {
    [headings release];
    [bodyText release];
    [imageURLs release];
    [pageTitle release];
    [super dealloc];
}

- (NSString *)pageTitle {
    return pageTitle;
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
     * (ナビゲーションが多いポータルサイト等ではまだノイズが残りうる) */
    if (xmlStrcasecmp(name, (const xmlChar *)"script") == 0 ||
        xmlStrcasecmp(name, (const xmlChar *)"style") == 0 ||
        xmlStrcasecmp(name, (const xmlChar *)"head") == 0 ||
        xmlStrcasecmp(name, (const xmlChar *)"noscript") == 0 ||
        xmlStrcasecmp(name, (const xmlChar *)"iframe") == 0 ||
        xmlStrcasecmp(name, (const xmlChar *)"nav") == 0 ||
        xmlStrcasecmp(name, (const xmlChar *)"footer") == 0) {
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
                NSString *placeholder = [NSString stringWithFormat:PWRJPStr("[ 画像%lu を表示 ]"), index];

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

        if (isBlock) {
            PWREnsureSeparation(ctx);
        }
        if (isListItem) {
            PWRAppendPlain(PWRJPStr("・ "), ctx);
        }

        /* div/article/section/ul/a/span/strongなどはここに落ちてきて、
         * 透過的なコンテナとして子要素をそのまま辿るだけになる */
        PWRAppendChildren(node, ctx);

        if (isListItem) {
            PWRAppendPlain(@"\n", ctx);
        } else if (isBlock) {
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

    const char *urlCString = baseURL ? [[baseURL absoluteString] UTF8String] : NULL;
    /* このlibxml2(2.6.16, Tiger標準)にはHTML_PARSE_RECOVERが存在しない。
     * HTMLパーサーはデフォルトで壊れたHTMLを寛容に読むため無くても問題ない */
    htmlDocPtr doc = htmlReadMemory([cleanedData bytes], [cleanedData length], urlCString, NULL,
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

    xmlFreeDoc(doc);

    PWRParsedPage *page = [[[PWRParsedPage alloc] initWithHeadings:ctx.headings
                                                            bodyText:ctx.body
                                                           imageURLs:ctx.imageURLs
                                                           pageTitle:pageTitle] autorelease];
    [ctx.body release];
    return page;
}

@end
