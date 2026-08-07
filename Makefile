.PHONY: build clean test

SWIFT_SOURCES := $(wildcard Sources/WeChatTweak/*.swift)
MENU_SOURCES := $(wildcard Sources/WeChatTweakMenu/*.m)
MACOS_SDK := /Library/Developer/CommandLineTools/SDKs/MacOSX11.1.sdk
MODULE_CACHE := .build/module-cache
DIST := dist

build::
	mkdir -p .build/catalina $(MODULE_CACHE) $(DIST)
	swiftc -O -target x86_64-apple-macosx10.15 $(SWIFT_SOURCES) -o .build/catalina/wechattweak-x86_64
	swiftc -O -target arm64-apple-macosx11.0 $(SWIFT_SOURCES) -o .build/catalina/wechattweak-arm64
	lipo -create .build/catalina/wechattweak-x86_64 .build/catalina/wechattweak-arm64 -output $(DIST)/wechattweak
	clang -fobjc-arc -fmodules -fmodules-cache-path=$(MODULE_CACHE) -mmacosx-version-min=10.15 \
		-isysroot $(MACOS_SDK) -framework AppKit -framework Foundation -dynamiclib \
		-arch x86_64 -arch arm64 $(MENU_SOURCES) -I Sources/WeChatTweakMenu/include \
		-I Sources/WeChatTweakMenu -install_name @rpath/libWeChatTweakMenu.dylib \
		-o $(DIST)/libWeChatTweakMenu.dylib
	codesign --force --sign - $(DIST)/wechattweak
	codesign --force --sign - $(DIST)/libWeChatTweakMenu.dylib

test::
	mkdir -p .build/catalina $(MODULE_CACHE)
	clang -fobjc-arc -fmodules -fmodules-cache-path=$(MODULE_CACHE) -mmacosx-version-min=10.15 \
		-isysroot $(MACOS_SDK) -framework AppKit -framework Foundation \
		Tests/LegacyRecallMarkerHarness.m Sources/WeChatTweakMenu/LegacyRecallMarker.m \
		-I Sources/WeChatTweakMenu -o .build/catalina/LegacyRecallMarkerHarness
	.build/catalina/LegacyRecallMarkerHarness
	$(DIST)/wechattweak patch --dry-run --app /Applications/WeChat.app \
		--config ./config.json --menu-dylib $(DIST)/libWeChatTweakMenu.dylib

clean::
	rm -rf .build
	rm -rf $(DIST)
