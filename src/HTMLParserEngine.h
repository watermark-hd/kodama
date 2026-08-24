#import <Cocoa/Cocoa.h>

/* 本文中のクリック可能なリンクの種別。
 * NSTextViewのNSLinkAttributeNameに素のNSURLを入れると「画像を表示」と
 * 「ページへ遷移」を区別できないため、種別付きのラッパーとして使う。 */
typedef enum {
    PWRLinkKindImage = 0,
    PWRLinkKindPage = 1
} PWRLinkKind;

@interface PWRLinkTarget : NSObject
{
    NSURL *url;
    PWRLinkKind kind;
}

- (id)initWithURL:(NSURL *)aURL kind:(PWRLinkKind)aKind;
- (NSURL *)url;
- (PWRLinkKind)kind;

@end

/* ページ内の見出し1件(左ペインのナビ用) */
@interface PWRHeading : NSObject
{
    NSString *title;
    int level;                 /* 1〜3 (h1-h3) */
    unsigned int bodyLocation; /* 本文NSAttributedString中の対応位置 */
    NSURL *linkURL;            /* 見出しがリンクを内包している場合のリンク先(無ければnil) */
}

- (id)initWithTitle:(NSString *)aTitle
              level:(int)aLevel
       bodyLocation:(unsigned int)aLocation
            linkURL:(NSURL *)aLinkURL;
- (NSString *)title;
- (int)level;
- (unsigned int)bodyLocation;
- (NSURL *)linkURL;

@end

/* HTMLパース結果一式(左ペイン/中央ペイン/右ペインの元データ) */
@interface PWRParsedPage : NSObject
{
    NSArray *headings;
    NSAttributedString *bodyText;
    NSArray *imageURLs;
    NSString *pageTitle; /* <title>タグの内容。無ければnil */
    NSURL *metaRefreshURL; /* <meta http-equiv="refresh">での自動転送先。無ければnil */
}

- (id)initWithHeadings:(NSArray *)aHeadings
               bodyText:(NSAttributedString *)aBodyText
              imageURLs:(NSArray *)anImageURLs
              pageTitle:(NSString *)aPageTitle
         metaRefreshURL:(NSURL *)aMetaRefreshURL;
- (NSArray *)headings;
- (NSAttributedString *)bodyText;
- (NSArray *)imageURLs;
- (NSString *)pageTitle;
- (NSURL *)metaRefreshURL;

@end

/* libxml2ベースのHTML→構造化データ変換エンジン */
@interface HTMLParserEngine : NSObject

+ (PWRParsedPage *)parsePageFromData:(NSData *)htmlData baseURL:(NSURL *)baseURL;

@end
