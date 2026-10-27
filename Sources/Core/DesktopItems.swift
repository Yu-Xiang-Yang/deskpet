import CoreGraphics
import Foundation

/// The desktop icons as Finder reports them, and what the pet says about them (IconVisits).
enum DesktopItems {
    /// An item on the desktop: its name and the centre of its picture, in Finder's desktop coordinates (points from
    /// the top left of the main screen, y downwards).
    struct Item: Equatable {
        var name: String
        var center: CGPoint
    }

    /// Reads the Finder script's output: the icon size on the first line, then one item per line as
    /// "x<TAB>y<TAB>name". Lines that do not parse are left out, and so are items at (-1, -1), Finder's answer for
    /// an item without a place of its own on the desktop; without a size, icons are 64 points.
    static func parse(_ output: String) -> (iconSize: CGFloat, items: [Item]) {
        var lines = output.components(separatedBy: "\n").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\r")) }
        let size = lines.isEmpty ? nil : Double(lines.removeFirst().trimmingCharacters(in: .whitespaces))
        let items: [Item] = lines.compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let x = Double(parts[0]), let y = Double(parts[1]), !parts[2].isEmpty, x != -1 || y != -1 else { return nil }
            return Item(name: String(parts[2]), center: CGPoint(x: x, y: y))
        }
        return (CGFloat(size.map { min(max($0, 16), 512) } ?? 64), items)
    }

    /// The frame of an item's picture in screen (Cocoa) coordinates: the main screen's origin at its bottom left.
    static func pictureFrame(of item: Item, iconSize: CGFloat, mainScreenHeight: CGFloat) -> CGRect {
        CGRect(x: item.center.x - iconSize / 2, y: mainScreenHeight - item.center.y - iconSize / 2, width: iconSize, height: iconSize)
    }

    /// The items whose names `before` did not have, in Finder's order.
    static func newcomers(before: Set<String>, now: [Item]) -> [Item] {
        now.filter { !before.contains($0.name) }
    }

    /// Kinds of item the pet tells apart by name.
    enum Kind: Equatable {
        case screenshot, image, pdf, document, spreadsheet, slides, installer, archive, video, audio, code, folder, other
    }

    static func kind(of name: String) -> Kind {
        let lower = name.lowercased()
        if ["截屏", "屏幕快照", "screenshot", "screen shot", "cleanshot"].contains(where: { lower.hasPrefix($0) }) { return .screenshot }
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "png", "jpg", "jpeg", "heic", "gif", "webp", "tiff", "bmp", "svg": return .image
        case "pdf": return .pdf
        case "doc", "docx", "pages", "txt", "md", "rtf", "tex": return .document
        case "xls", "xlsx", "numbers", "csv": return .spreadsheet
        case "ppt", "pptx", "key": return .slides
        case "dmg", "pkg": return .installer
        case "zip", "rar", "7z", "gz", "tgz", "tar": return .archive
        case "mp4", "mov", "m4v", "avi", "mkv": return .video
        case "mp3", "m4a", "wav", "flac", "aac": return .audio
        case "swift", "py", "js", "ts", "c", "cpp", "h", "java", "go", "rs", "json", "sh", "ipynb": return .code
        case "": return .folder  // folders (and the rare file without an extension)
        default: return .other
        }
    }

    /// The name as the pet says it: in corner brackets, long names shortened in the middle.
    static func quoted(_ name: String, limit: Int = 18) -> String {
        guard name.count > limit else { return "「\(name)」" }
        return "「\(name.prefix(limit - 7))…\(name.suffix(6))」"
    }

    /// What the pet says on finding `name` newly put on the desktop.
    static func remark(onArrival name: String) -> String {
        let q = quoted(name)
        switch kind(of: name) {
        case .screenshot: return tr("新截图！拍到什么好东西了？", "A new screenshot! What did you catch?")
        case .image: return tr("\(q)，一张新图片～让我看看", "\(q), a new picture~ let me see")
        case .pdf: return tr("\(q)……PDF？是要读的论文吗", "\(q)… a PDF? Something to read?")
        case .document: return tr("新文档\(q)，写作加油～", "A new document, \(q). Happy writing~")
        case .spreadsheet: return tr("\(q)，好多格子和数字", "\(q): so many cells and numbers")
        case .slides: return tr("\(q)？要做汇报了吗", "\(q)? A talk coming up?")
        case .installer: return tr("安装包\(q)，装完记得删掉哦", "An installer, \(q). Delete it once installed~")
        case .archive: return tr("\(q)，里面压着什么呀", "\(q). What's packed in there?")
        case .video: return tr("\(q)，有视频！", "\(q), a video!")
        case .audio: return tr("\(q)，是新歌吗？", "\(q), a new song?")
        case .code: return tr("\(q)，代码的味道", "\(q). Smells like code")
        case .folder: return tr("新文件夹\(q)，里面藏了什么？", "A new folder, \(q). What's inside?")
        case .other: return tr("\(q)是什么呀？闻闻～", "What's \(q)? Sniff sniff~")
        }
    }

    /// What the pet says while sitting on an icon it went to of its own accord.
    static func remark(visiting name: String) -> String {
        let q = quoted(name)
        return [tr("巡视桌面中～\(q)检查完毕", "Patrolling the desktop~ \(q) checked"),
                tr("\(q)坐起来挺舒服的", "\(q) is comfy to sit on"),
                tr("嗯……\(q)闻起来像截止日期", "Hmm… \(q) smells like a deadline"),
                tr("这个\(q)还要吗？好久没动它了", "Still need \(q)? It hasn't moved in ages")].randomElement()!
    }

    // MARK: Widgets

    /// What a desktop widget shows, told by the app that shows it and its title (the system's own widgets come
    /// from Notification Center; titles are only known with screen-recording permission).
    enum WidgetKind: Equatable {
        case claude, github, weather, calendar, todo, stocks, clock, battery, photos, notes, music, other
    }

    static func widgetKind(owner: String, name: String) -> WidgetKind {
        let text = (owner + " " + name).lowercased()
        let table: [(WidgetKind, [String])] = [
            (.claude, ["claude"]), (.github, ["github"]), (.weather, ["天气", "weather"]), (.calendar, ["日历", "日程", "calendar"]),
            // Stocks before lists: "仓位列表" is a stock list.
            (.stocks, ["股", "仓位", "行情", "stock"]), (.todo, ["提醒", "待办", "列表", "reminder", "todo", "to do"]),
            (.clock, ["时钟", "世界时间", "clock"]), (.battery, ["电池", "batter"]), (.photos, ["照片", "相册", "photo"]),
            (.notes, ["备忘", "note"]), (.music, ["音乐", "播客", "music", "podcast"]),
        ]
        return table.first { $0.1.contains(where: text.contains) }?.0 ?? .other
    }

    /// What the character says peeking from behind a widget; for the Claude usage widget, how much of the five-hour
    /// window is used (`claudePercent`, when known).
    static func remark(widgetOwner owner: String, name: String, claudePercent: Int? = nil, now: Date = Date()) -> String {
        switch widgetKind(owner: owner, name: name) {
        case .claude:
            guard let p = claudePercent else { return tr("偷看一下 Claude 用量～", "Peeking at the Claude usage~") }
            return p >= 80 ? tr("Claude 这 5 小时已经用了 \(p)%，省着点用～", "Claude's five hours are \(p)% used. Go easy~")
                           : tr("Claude 这 5 小时才用了 \(p)%，还很充裕～", "Claude's five hours are only \(p)% used. Plenty left~")
        case .github: return tr("今天的格子绿了吗？提交一下吧～", "Is today's square green yet? Time to commit~")
        case .weather: return tr("天气预报写着什么？出门前看一眼～", "What does the forecast say? Check before going out~")
        case .calendar: return tr("日程表……今天还有安排吗？", "The calendar… anything else today?")
        case .todo: return tr("待办清单，今天完成几项了？", "The to-do list. How many done today?")
        case .stocks: return tr("盯盘中……红红绿绿的，看得我眼花", "Watching the market… all that red and green makes me dizzy")
        case .clock:
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            return tr("现在是 \(f.string(from: now))，时间过得好快", "It's \(f.string(from: now)) already. Time flies")
        case .battery: return tr("电量还够吗？记得充电～", "Enough battery? Remember to charge~")
        case .photos: return tr("这张照片拍得真好", "What a lovely photo")
        case .notes: return tr("备忘录上写了什么秘密？", "What secrets are in the notes?")
        case .music: return tr("这首歌好听吗？", "Is this song any good?")
        case .other:
            let title = name.isEmpty ? owner : name
            return title.isEmpty || title == "通知中心" || title == "NotificationCenter"
                ? tr("躲在小组件后面～被你发现了吗？", "Hiding behind a widget~ did you spot me?")
                : tr("「\(title)」这个小组件，我帮你看着～", "I'll keep an eye on “\(title)” for you~")
        }
    }
}
