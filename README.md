# AI 直播助手 — iPhone 播放端 (IPA)

安卓采集端抓弹幕 → 服务器AI回复+TTS → **本App收音频并播报**（含背景音乐）。

## 功能
- ✅ WebSocket 连接服务器 `/ws_iphone/{device_id}`（2号测试服务器 59.110.152.66:18766）
- ✅ 接收TTS音频 → 队列播放（不重叠）
- ✅ 背景音乐：内置在App内循环播放（暂停/切歌/音量）
- ✅ 双音量控制：人声 + 音乐 分开调
- ✅ 静音开关（静音后仍收音频，只不发声）
- ✅ 播报历史：带类型标签（💬弹幕/📢暖场/🕐报时/💰下单/❤️关注/🎁礼物）
- ✅ 设备ID：自动生成，填到安卓端即可绑定
- ✅ 断线自动重连 + 后台持续运行（UIBackgroundModes: audio）

## 目录结构
```
AiLiveApp/
├── AiLiveApp.swift              # App入口（后台音频配置）
├── Info.plist                   # 允许HTTP + 后台音频
├── Models/
│   └── BroadcastEntry.swift     # 播报历史模型
├── Services/
│   ├── WebSocketManager.swift   # WS连接 + 断线重连 + 收音频/元数据
│   └── AudioPlayerService.swift # TTS队列播放 + 背景音乐 + 双音量
└── Views/
    └── ContentView.swift        # 主界面
project.yml                      # XcodeGen 配置
.github/workflows/build-ipa.yml  # GitHub Actions 云编译出 IPA
```

## 编译（GitHub Actions 云编译）
1. 把本目录推到 GitHub 仓库
2. Actions 自动跑 `Build IPA` 工作流
3. 下载产物 `AiLivePlayer-unsigned.ipa`

## 安装（不越狱，7天签名）
1. 电脑装 [Sideloadly](https://sideloadly.io/) 或 AltStore
2. 手机连电脑，把 unsigned.ipa 拖进 Sideloadly
3. 填 Apple ID → 签名安装（免费账号7天需重签一次）
4. 首次打开需要 设置→通用→VPN与设备管理→信任开发者证书

## 使用
1. 打开App，记下顶部的**设备ID**
2. 安卓采集端设置页 → iPhone设备ID → 填这个ID
3. 服务器会把该安卓的播报音频推送到这台iPhone

## 更换背景音乐
把 mp3/m4a 文件放进 `AiLiveApp/` 目录（和 Swift 文件同级），重新编译即可。
