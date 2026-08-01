import Foundation

// MARK: - 播报历史条目
struct BroadcastEntry: Identifiable {
    let id = UUID()
    let time: String
    let type: String      // danmaku / warmup / time_announce / order / follow / gift / tts_test
    let text: String

    var typeLabel: String {
        switch type {
        case "danmaku": return "💬 弹幕"
        case "warmup": return "📢 暖场"
        case "time_announce": return "🕐 报时"
        case "order": return "💰 下单"
        case "follow": return "❤️ 关注"
        case "gift": return "🎁 礼物"
        default: return "🔊 播报"
        }
    }

    var typeColor: UInt32 {
        switch type {
        case "danmaku": return 0x4CAF50
        case "warmup": return 0x795548
        case "time_announce": return 0x2196F3
        case "order": return 0xF44336
        case "follow": return 0xE91E63
        case "gift": return 0xFF9800
        default: return 0x9E9E9E
        }
    }
}

// MARK: - 全局配置（真机版）
let kServerHost = "39.96.2.213"      // 生产服务器（安卓采集/管理后台/bark_key 都在这里）
let kServerPort = 18766
let kDeviceIdKey = "ailive_iphone_device_id"   // UserDefaults 存储设备ID
