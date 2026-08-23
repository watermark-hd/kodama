#import <Cocoa/Cocoa.h>

/*
 * 日本語/英語のUI文字列を実行時に切り替えるための最小ローカライズ機構。
 *
 * .lproj + NSLocalizedStringという標準的なCocoaローカライズは
 * OS標準の言語設定に従うのが基本で、アプリ内でその場で切り替えるには
 * 追加の仕組みが要る。ここではシンプルに、日英2つの辞書をコード内に
 * 直接持ち、+setLanguage:で切り替えてPWRLanguageChangedNotificationを
 * 発行する方式にした。
 *
 * 文字列はすべてPWRCompat.hのPWRJPStr経由で構築すること
 * (gcc 4.0.0は@"日本語"のようなリテラルを正しくエンコードできないため)。
 */

extern NSString * const PWRLanguageChangedNotification;

@interface PWRLocalization : NSObject

+ (void)setLanguage:(NSString *)langCode; /* @"ja" または @"en" */
+ (NSString *)currentLanguage;
+ (NSString *)stringForKey:(NSString *)key;

@end

/* PWRL(@"open") のように書けるようにする糖衣マクロ */
#define PWRL(key) [PWRLocalization stringForKey:(key)]
