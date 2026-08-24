#import "PWRLocalization.h"
#import "PWRCompat.h"

NSString * const PWRLanguageChangedNotification = @"PWRLanguageChangedNotification";

static NSString *gCurrentLanguage = nil;
static NSDictionary *gJaStrings = nil;
static NSDictionary *gEnStrings = nil;

@implementation PWRLocalization

+ (void)initialize {
    if (self != [PWRLocalization class]) {
        return;
    }

    gJaStrings = [[NSDictionary alloc] initWithObjectsAndKeys:
        PWRJPStr("開く"), @"open",
        PWRJPStr("戻る"), @"back",
        PWRJPStr("進む"), @"forward",
        PWRJPStr("追加"), @"addBookmark",
        PWRJPStr("ブックマーク"), @"bookmarksToggle",
        PWRJPStr("削除"), @"deleteBookmark",
        PWRJPStr("名前を変更"), @"renameBookmark",
        PWRJPStr("新しい名前を入力してください"), @"renameBookmarkPrompt",
        PWRJPStr("キャンセル"), @"cancel",
        PWRJPStr("編集"), @"editMenu",
        PWRJPStr("切り取り"), @"cut",
        PWRJPStr("コピー"), @"copy",
        PWRJPStr("ペースト"), @"paste",
        PWRJPStr("すべてを選択"), @"selectAll",
        PWRJPStr("取り消す"), @"undo",
        PWRJPStr("やり直す"), @"redo",
        PWRJPStr("見出し"), @"headings",
        PWRJPStr("読み込み中..."), @"loading",
        PWRJPStr("準備完了"), @"ready",
        PWRJPStr("通信エラー"), @"networkError",
        PWRJPStr("HTMLの解析に失敗しました"), @"parseError",
        PWRJPStr("終了"), @"quit",
        PWRJPStr("言語"), @"languageMenu",
        PWRJPStr("画像を隠す"), @"hideImage",
        PWRJPStr("OK"), @"ok",
        PWRJPStr("モダンなcurlが見つかりません(MacPortsやTigerbrewでインストールしてください)"), @"curlNotFound",
        PWRJPStr("通信に失敗しました(curl終了コード %d)"), @"curlFailedFormat",
        nil];

    gEnStrings = [[NSDictionary alloc] initWithObjectsAndKeys:
        @"Open", @"open",
        @"Back", @"back",
        @"Forward", @"forward",
        @"Add", @"addBookmark",
        @"Bookmarks", @"bookmarksToggle",
        @"Delete", @"deleteBookmark",
        @"Rename", @"renameBookmark",
        @"Enter a new name", @"renameBookmarkPrompt",
        @"Cancel", @"cancel",
        @"Edit", @"editMenu",
        @"Cut", @"cut",
        @"Copy", @"copy",
        @"Paste", @"paste",
        @"Select All", @"selectAll",
        @"Undo", @"undo",
        @"Redo", @"redo",
        @"Headings", @"headings",
        @"Loading...", @"loading",
        @"Ready", @"ready",
        @"Network Error", @"networkError",
        @"Failed to parse HTML", @"parseError",
        @"Quit", @"quit",
        @"Language", @"languageMenu",
        @"Hide Image", @"hideImage",
        @"OK", @"ok",
        @"Modern curl not found (please install via MacPorts or Tigerbrew)", @"curlNotFound",
        @"Request failed (curl exit code %d)", @"curlFailedFormat",
        nil];

    gCurrentLanguage = [@"ja" retain]; /* デフォルトは日本語 */
}

+ (void)setLanguage:(NSString *)langCode {
    if ([gCurrentLanguage isEqualToString:langCode]) {
        return;
    }
    [gCurrentLanguage release];
    gCurrentLanguage = [langCode copy];
    [[NSNotificationCenter defaultCenter] postNotificationName:PWRLanguageChangedNotification object:nil];
}

+ (NSString *)currentLanguage {
    return gCurrentLanguage;
}

+ (NSString *)stringForKey:(NSString *)key {
    NSDictionary *table = [gCurrentLanguage isEqualToString:@"en"] ? gEnStrings : gJaStrings;
    NSString *value = [table objectForKey:key];
    return value ? value : key;
}

@end
