import Foundation

// MARK: - 数据模型

struct VideoInfo {
    var width = 0
    var height = 0
    var duration: Double = 0
    var codec = ""
    var fps: Double = 0
    var bitRate: Double = 0
    var hasAudio = false
    var isHDR = false
    var bitDepth = 0
}

enum MakeError: LocalizedError {
    case msg(String)
    var errorDescription: String? {
        switch self {
        case .msg(let m): return m
        }
    }
}

struct MadeLive {
    let videoURL: URL
    let photoURL: URL
    let identifier: String
    let info: VideoInfo
    /// 系统 PHLivePhoto 验证是否通过（高置信可设为锁屏实况壁纸）
    var verifiedLive = false
    /// 验证备注：系统错误详情 / 封面搜索过程
    var verifyNote = ""
    /// 最终采用的封面时刻（秒）
    var coverSeconds = 0
}

func fourCCString(_ code: FourCharCode) -> String {
    let v: [UInt8] = [UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
                      UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
    return String(bytes: v, encoding: .ascii) ?? "????"
}
