import Foundation

/// What an app that plays sound is, as far as dancing is concerned: music players count as music, calls, chats, mail,
/// the system's own sounds and video players never do, and for every other app (browsers, unknown players, tools
/// without a bundle) the sound itself decides (MusicJudge).
enum SoundSource: Equatable {
    case music, ignored, undecided

    private static let musicApps = ["com.spotify.client", "com.netease.163music", "com.tencent.QQMusicMac", "com.kugou.", "cn.kuwo.",
                                    "com.kuwo.", "com.tidal.", "com.amazon.music", "com.deezer.", "com.coppertino.vox",
                                    "com.apple.garageband", "com.apple.logic", "com.apple.mainstage"]
    private static let videoApps = ["com.colliderli.iina", "org.videolan.vlc", "io.mpv", "com.firecore.infuse", "com.youku",
                                    "com.tencent.tenvideo", "tv.danmaku", "com.bilibili", "com.iqiyi", "com.qiyi", "com.mgtv",
                                    "com.netflix", "com.bytedance.douyin", "com.apple.tv", "com.apple.quicktimeplayer"]
    private static let talkApps = ["com.tencent.xinwechat", "com.tencent.qq", "com.alibaba.dingtalk", "com.microsoft.teams",
                                   "com.tencent.meeting", "us.zoom.", "com.tinyspeck.slackmacgap", "com.hnc.discord",
                                   "ru.keepcoder.telegram", "org.telegram.", "com.bytedance.lark", "com.electron.lark",
                                   "net.whatsapp.", "com.microsoft.outlook"]

    static func of(bundleID: String?) -> SoundSource {
        guard let id = bundleID?.lowercased(), !id.isEmpty else { return .undecided }
        func listed(_ list: [String]) -> Bool { list.contains { id.hasPrefix($0.lowercased()) } }
        // Music first: "com.tencent.qq" (QQ) is also the beginning of "com.tencent.QQMusicMac".
        if id == "com.apple.music" || listed(musicApps) { return .music }
        if listed(videoApps) || listed(talkApps) { return .ignored }
        // Safari plays through WebKit's helper processes; every other Apple process is the system.
        if id == "com.apple.safari" || id.hasPrefix("com.apple.webkit") { return .undecided }
        if id.hasPrefix("com.apple.") { return .ignored }
        return id.contains("music") ? .music : .undecided
    }
}

/// Decides from the windows of the system's sound classifier (SoundAnalysis, about 1.5 s each, every 0.75 s) whether
/// the sound is music. A window counts when "music" has at least 0.4 confidence and either outweighs "speech" or
/// singing or rapping is heard, which leaves out talk, videos with background music under the voice, and the single
/// window of a notification sound. Music starts after 3 of the last 4 windows and ends after 4 of the last 5 are not.
struct MusicJudge {
    struct Window: Equatable {
        var music = 0.0, speech = 0.0, singing = 0.0, rapping = 0.0
    }

    private(set) var isMusic = false
    private var recent: [Bool] = []

    static func counts(_ w: Window) -> Bool {
        w.music >= 0.4 && (w.music >= w.speech || max(w.singing, w.rapping) >= 0.25)
    }

    @discardableResult
    mutating func add(_ w: Window) -> Bool {
        recent.append(Self.counts(w))
        if recent.count > 5 { recent.removeFirst(recent.count - 5) }
        if isMusic {
            if recent.suffix(5).filter({ !$0 }).count >= 4 { isMusic = false }
        } else if recent.suffix(4).filter({ $0 }).count >= 3 {
            isMusic = true
        }
        return isMusic
    }

    mutating func reset() {
        isMusic = false
        recent = []
    }
}
