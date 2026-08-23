#import <Cocoa/Cocoa.h>

/*
 * Xcode 2.5付属のgcc 4.0.0はObjective-Cの @"日本語" 文字列リテラルを
 * 正しくエンコードできない(文字化けする)という制約がある。
 * Cの文字列リテラルからUTF-8として明示的に変換すれば正しく扱えるため、
 * 日本語を含むNSStringリテラルは必ずこのマクロ経由で書くこと。
 *
 * 例: PWRJPStr("画像を表示")
 */
#define PWRJPStr(cstr) [NSString stringWithUTF8String:(cstr)]
