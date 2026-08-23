# PPC-WebReader ビルド設定
# PowerMac G4 (Mac OS X 10.4 Tiger) 上のXcode 2.5付属gcc/ldでのビルドを前提とする。
# Xcodeプロジェクトファイルは使わず、SSH越しに `make` だけで完結させる。

APP_NAME   = PPC-WebReader
BUILD_DIR  = build
APP_BUNDLE = $(BUILD_DIR)/$(APP_NAME).app
CONTENTS   = $(APP_BUNDLE)/Contents
MACOS_DIR  = $(CONTENTS)/MacOS

CC      ?= gcc
# G4実機(Tiger)上でネイティブビルドするため、デプロイターゲット指定は不要
# (このgcc 4.0.0はcc1objで-mmacosx-version-minを受け付けない)
CFLAGS  = -Wall -Isrc
LDFLAGS = -framework Cocoa

SRC_DIR = src
SOURCES = $(SRC_DIR)/main.m
OBJECTS = $(SOURCES:.m=.o)

PARSER_TEST_BIN = $(BUILD_DIR)/parse-test
PARSER_SOURCES  = src/HTMLParserEngine.m tools/parse_test.m

.PHONY: all app run clean check-libxml2 test-parser

all: app

app: $(MACOS_DIR)/$(APP_NAME) $(CONTENTS)/Info.plist

$(MACOS_DIR)/$(APP_NAME): $(OBJECTS)
	@mkdir -p $(MACOS_DIR)
	$(CC) $(OBJECTS) $(LDFLAGS) -o $@

$(CONTENTS)/Info.plist: Resources/Info.plist
	@mkdir -p $(CONTENTS)
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
	$(CC) $(CFLAGS) -I/usr/include/libxml2 $(PARSER_SOURCES) -lxml2 $(LDFLAGS) -o $@
