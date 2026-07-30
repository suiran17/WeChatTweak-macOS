.PHONY: build clean

build::
	swift build -c release --arch arm64 --arch x86_64
	cp -f .build/apple/Products/Release/wechattweak ./wechattweak
	cp -f .build/apple/Products/Release/libWeChatTweakMenu.dylib ./libWeChatTweakMenu.dylib
	codesign --force --sign - ./wechattweak
	codesign --force --sign - ./libWeChatTweakMenu.dylib

clean::
	rm -rf .build
	rm -f wechattweak
	rm -f libWeChatTweakMenu.dylib
