#include <stdio.h>
#include <libxml/xmlversion.h>

/* Phase 0: Mac OS X 10.4 Tiger標準搭載のlibxml2が
 * ヘッダ・リンクとも問題なく使えるかをG4実機で確認するための疎通テスト。 */
int main(void) {
    printf("libxml2 version: %s\n", LIBXML_VERSION_STRING);
    return 0;
}
