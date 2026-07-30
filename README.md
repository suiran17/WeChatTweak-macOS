# WeChatTweak

[![README](https://img.shields.io/badge/GitHub-black?logo=github&logoColor=white)](https://github.com/sunnyyoung/WeChatTweak)
[![README](https://img.shields.io/badge/Telegram-black?logo=telegram&logoColor=white)](https://t.me/wechattweak)
[![README](https://img.shields.io/badge/FAQ-black?logo=googledocs&logoColor=white)](https://github.com/sunnyyoung/WeChatTweak/wiki/FAQ)

A command-line tool for tweaking WeChat.

## 功能

- 阻止消息撤回，并在发送者头像下方显示「[已撤回]」
- 阻止自动更新
- 微信内 Tweak 菜单与设置页
- 从 Tweak 菜单启动另一个微信实例

## 当前版本支持

| 微信版本 | 构建号 | Apple Silicon | Intel | 拦截撤回 | 头像撤回标识 | Tweak 菜单 | 阻止更新 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 4.1.12 | 269341 | ✅ | ✅ | ✅ | Intel / Rosetta | ✅ | ✅ |

微信 4.x 已把主要逻辑迁移到 `Contents/Resources/wechat.dylib`。本项目会按配置选择
实际二进制，并在写入前核对原始字节；配置与本机二进制不一致时会直接停止，不会写入
部分补丁。撤回发生后，原消息继续保留；在 Intel 或 Rosetta 模式下，发送者头像下方
还会显示「[已撤回]」标识。原生 Apple Silicon 的头像标识仍待适配。

安装时会把通用架构的 `libWeChatTweakMenu.dylib` 放入微信，并向主程序加入加载命令。
Tweak 菜单提供状态页、设置入口以及“登录另一个微信账号”入口。此入口通过 macOS
启动新的应用实例，不复用旧版本的硬编码多开地址。

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

默认会同时安装微信内 Tweak 菜单。只应用静态补丁可添加 `--without-menu`；自行构建
或移动菜单运行库时可通过 `--menu-dylib /path/to/libWeChatTweakMenu.dylib` 指定。

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
