# コダマ(Kodama) ビルド設定
# PowerMac G4 (Mac OS X 10.4 Tiger) 上のXcode 2.5付属gcc/ldでのビルドを前提とする。
# Xcodeプロジェクトファイルは使わず、SSH越しに `make` だけで完結させる。

APP_NAME   = Kodama
BUILD_DIR  = build
APP_BUNDLE = $(BUILD_DIR)/$(APP_NAME).app
CONTENTS   = $(APP_BUNDLE)/Contents
MACOS_DIR  = $(CONTENTS)/MacOS
RES_DIR    = $(CONTENTS)/Resources

CC      ?= gcc
# G4実機(Tiger)上でネイティブビルドするため、デプロイターゲット指定は不要
# (このgcc 4.0.0はcc1objで-mmacosx-version-minを受け付けない)
CFLAGS  = -Wall -Isrc -I/usr/include/libxml2
LDFLAGS = -framework Cocoa -lxml2

SRC_DIR = src
SOURCES = $(SRC_DIR)/main.m $(SRC_DIR)/AppController.m $(SRC_DIR)/HTMLParserEngine.m \
          $(SRC_DIR)/CurlTaskRunner.m $(SRC_DIR)/PWRLocalization.m
OBJECTS = $(SOURCES:.m=.o)

PARSER_TEST_BIN = $(BUILD_DIR)/parse-test
PARSER_SOURCES  = src/HTMLParserEngine.m src/PWRLocalization.m tools/parse_test.m

CURL_TEST_BIN     = $(BUILD_DIR)/curl-test
CURL_TEST_SOURCES = src/CurlTaskRunner.m src/PWRLocalization.m tools/curl_test.m

.PHONY: all app run clean check-libxml2 test-parser test-curl

all: app

app: $(MACOS_DIR)/$(APP_NAME) $(CONTENTS)/Info.plist $(RES_DIR)/Kodama.icns \
     $(RES_DIR)/curl $(RES_DIR)/cacert.pem

$(MACOS_DIR)/$(APP_NAME): $(OBJECTS)
	@mkdir -p $(MACOS_DIR)
	$(CC) $(OBJECTS) $(LDFLAGS) -o $@

$(CONTENTS)/Info.plist: Resources/Info.plist
	@mkdir -p $(CONTENTS)
	cp $< $@

$(RES_DIR)/Kodama.icns: Resources/Kodama.icns
	@mkdir -p $(RES_DIR)
	cp $< $@

# モダンなHTTPS(TLS1.2/1.3)用にビルドしたcurl(LibreSSL静的リンク・PPC)を
# アプリに同梱する。Tiger素の環境ではMacPorts/Tigerbrewが無いため、
# CurlTaskRunnerはまずこの同梱版を使う。cacert.pemはそのCA証明書。
$(RES_DIR)/curl: Resources/curl
	@mkdir -p $(RES_DIR)
	cp $< $@
	chmod 755 $@

$(RES_DIR)/cacert.pem: Resources/cacert.pem
	@mkdir -p $(RES_DIR)
	cp $< $@

%.o: %.m
	$(CC) $(CFLAGS) -c $< -o $@

run: app
	open $(APP_BUNDLE)

clean:
	rm -rf $(BUILD_DIR) $(SRC_DIR)/*.o

# Phase 0: libxml2がTigerに標準搭載されているかの疎通確認
check-libxml2:
	@mkdir -p $(BUILD_DIR)
	$(CC) -I/usr/include/libxml2 tools/check_libxml2.c -lxml2 -o $(BUILD_DIR)/check-libxml2
	$(BUILD_DIR)/check-libxml2

# Phase 1: HTMLParserEngineをGUI無しで単体テスト
# 例: make test-parser FILE=tools/sample.html
test-parser: $(PARSER_TEST_BIN)
	@if [ -z "$(FILE)" ]; then echo "FILEを指定してください 例: make test-parser FILE=tools/sample.html"; exit 1; fi
	$(PARSER_TEST_BIN) $(FILE) $(BASE)

$(PARSER_TEST_BIN): $(PARSER_SOURCES) src/HTMLParserEngine.h
	@mkdir -p $(BUILD_DIR)
	$(CC) $(CFLAGS) $(PARSER_SOURCES) $(LDFLAGS) -o $@

# Phase 2: CurlTaskRunnerをGUI無しで単体テスト(実際にHTTPSサイトを取得する)
# 例: make test-curl URL=https://example.com
test-curl: $(CURL_TEST_BIN)
	@if [ -z "$(URL)" ]; then echo "URLを指定してください 例: make test-curl URL=https://example.com"; exit 1; fi
	$(CURL_TEST_BIN) $(URL)

$(CURL_TEST_BIN): $(CURL_TEST_SOURCES) src/CurlTaskRunner.h
	@mkdir -p $(BUILD_DIR)
	$(CC) $(CFLAGS) $(CURL_TEST_SOURCES) $(LDFLAGS) -o $@
