# WeChatTweak

[![README](https://img.shields.io/badge/GitHub-black?logo=github&logoColor=white)](https://github.com/sunnyyoung/WeChatTweak)
[![README](https://img.shields.io/badge/Telegram-black?logo=telegram&logoColor=white)](https://t.me/wechattweak)
[![README](https://img.shields.io/badge/FAQ-black?logo=googledocs&logoColor=white)](https://github.com/sunnyyoung/WeChatTweak/wiki/FAQ)

A command-line tool for tweaking WeChat.

## 功能

- 阻止消息撤回
- 阻止自动更新
- 客户端多开（旧版微信）

## 当前版本支持

| 微信版本 | 构建号 | Apple Silicon | Intel | 阻止撤回 | 阻止更新 |
| --- | --- | --- | --- | --- | --- |
| 4.1.12 | 269341 | ✅ | ✅ | ✅ | ✅ |

微信 4.x 已把主要逻辑迁移到 `Contents/Resources/wechat.dylib`。本项目会按配置选择
实际二进制，并在写入前核对原始字节；配置与本机二进制不一致时会直接停止，不会写入
部分补丁。269341 暂不启用多开补丁，旧版地址不能安全复用。

## 安装&使用

```bash
# 安装
brew install sunnyyoung/tap/wechattweak

# 更新
brew upgrade wechattweak

# 执行 Patch
wechattweak patch

# 查看所有支持的 WeChat 版本
wechattweak versions
```

从源码运行时，建议先退出微信并执行只读检查：

```bash
swift run wechattweak patch --dry-run --config ./config.json
swift run wechattweak patch --config ./config.json
```

正式执行前会在被修改的二进制旁创建 `.wechattweak-backup` 备份，随后对嵌套动态库和
应用重新签名。若明确不需要备份，可添加 `--no-backup`。重复执行时，已经写入的补丁会
被识别为 `alreadyPatched`，不会再次修改。

> 修改并重新签名会使微信失去腾讯的原始代码签名。微信升级后请先运行
> `patch --dry-run`，不要把 269341 的地址用于其他构建号。

## 参考

- [微信 macOS 客户端无限多开功能实践](https://blog.sunnyyoung.net/wei-xin-macos-ke-hu-duan-wu-xian-duo-kai-gong-neng-shi-jian/)
- [微信 macOS 客户端拦截撤回功能实践](https://blog.sunnyyoung.net/wei-xin-macos-ke-hu-duan-lan-jie-che-hui-gong-neng-shi-jian/)
- [让微信 macOS 客户端支持 Alfred](https://blog.sunnyyoung.net/rang-wei-xin-macos-ke-hu-duan-zhi-chi-alfred/)

## 贡献者

This project exists thanks to all the people who contribute.

[![Contributors](https://contrib.rocks/image?repo=sunnyyoung/WeChatTweak)](https://github.com/sunnyyoung/WeChatTweak/graphs/contributors)

## License

The [AGPL-3.0](LICENSE).
