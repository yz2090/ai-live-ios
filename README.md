# AI 播放端（精简版）— iPhone 端 IPA

**只做一件事**：接收安卓采集端（ai-live.apk）推来的语音并播放。

## 架构
```
安卓采集端（抖音分身+无障碍抓评论/下单）
  → POST /api/say 上报服务器
  → 服务器 AI 回复 + TTS 生成语音
  → WS 推送到绑定的 iPhone 播放端
  → 本 App 接收音频并播放 🔊
```

## 功能
- ✅ WebSocket 连接服务器 `/ws_iphone/{device_id}`（2号测试服务器 <服务器地址>）
- ✅ 接收 TTS 音频 → 队列播放（不重叠）
- ✅ 设备ID：自动生成，填到安卓端"iPhone设备ID"即绑定
- ✅ 断线自动重连 + 后台持续运行（UIBackgroundModes: audio + 静音保活）
- ✅ 静音开关 + 播报音量
- ✅ 最近播报文字显示（带类型标签）

## 目录结构
```
ai-live-ios-lite/
├── AiLiveLite/
│   ├── AiLiveLite.swift              # App入口（后台音频+自动连接）
│   ├── Info.plist                    # 允许HTTP + 后台音频
│   ├── Services/
│   │   ├── WebSocketManager.swift   # WS连接 + 断线重连 + 收音频/meta
│   │   └── AudioPlayerService.swift # TTS队列播放 + 后台保活
│   └── Views/
│       └── ContentView.swift        # 主界面（精简）
└── project.yml                      # XcodeGen 配置
```

## 编译（GitHub Actions 云编译）
1. 推到 GitHub 仓库 → Actions 自动跑 `Build IPA`
2. 下载产物 `AiLiveLite-unsigned.ipa`

## 安装（不越狱，7天签名）
1. 电脑装 [Sideloadly](https://sideloadly.io/) 或 AltStore
2. iPhone 连电脑，拖入 unsigned.ipa
3. 填 Apple ID → 签名安装（免费账号7天需重签）
4. 首次打开：设置→通用→VPN与设备管理→信任开发者证书

## 使用
1. 打开 App，记下**设备ID**（6位短ID，如 a7b271）
2. 安卓采集端设置页 → iPhone设备ID → 填这个ID
3. 服务器自动把该安卓的播报音频推送到这台 iPhone

## 与原版区别
原版 AiLiveApp（v11.20）功能完整（含网页采集百应控制台、背景音乐、播报历史），本精简版**只保留播放功能**，去掉网页采集/背景音乐，界面更简单。
