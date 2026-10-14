import Foundation

/// The parts of a forecast that weather alerts look at.
struct WeatherSnapshot: Equatable {
    struct Hour: Equatable {
        var time: Date
        var code: Int
        var temperature: Double
        var precipitationProbability: Double
        var precipitation: Double
        var windSpeed: Double
    }

    var place: String
    var currentCode: Int
    var currentPrecipitation: Double
    /// The coming hours, earliest first.
    var hours: [Hour]
    var todayMax: Double?
    var tomorrowMax: Double?
    var tomorrowMin: Double?
    var tomorrowCode: Int?
    var tomorrowPrecipitationProbability: Double?
}

enum WeatherAlert: Equatable {
    /// Rain (or snow) is likely soon although it is dry now.
    case precipitationSoon(minutes: Int, probability: Int, snow: Bool)
    /// Thunderstorm, heavy rain, heavy snow or strong wind within the next hours.
    case severe(minutes: Int, description: String)
    /// Tomorrow compared with today (evening check): temperature change and/or rain.
    case tomorrow(temperatureChange: Int?, rainProbability: Int?)
}

/// Remembers which alerts were given, so that each change is announced once.
struct WeatherAlertState: Codable, Equatable {
    var lastPrecipitationAlert: Date?
    var lastSevereAlert: Date?
    var lastTomorrowAlertDay: String?
}

enum WeatherAlerts {
    static func isRain(_ code: Int) -> Bool { (51...67).contains(code) || (80...82).contains(code) || code >= 95 }
    static func isSnow(_ code: Int) -> Bool { (71...77).contains(code) || code == 85 || code == 86 }
    static func isWet(_ code: Int) -> Bool { isRain(code) || isSnow(code) }

    /// Severe conditions: thunderstorms (95–99), heavy rain (65, 67, 82), heavy snow (75, 86).
    static func severeDescription(_ code: Int) -> String? {
        switch code {
        case 95...99: return tr("雷阵雨", "thunderstorms")
        case 65, 67, 82: return tr("大雨", "heavy rain")
        case 75, 86: return tr("大雪", "heavy snow")
        default: return nil
        }
    }

    static let windThreshold = 45.0  // km/h, roughly Beaufort 6

    /// The alerts due for `snapshot` at `now`; updates `state` so that each fires once per change.
    static func evaluate(_ snapshot: WeatherSnapshot, now: Date, state: inout WeatherAlertState,
                         calendar: Calendar = .current) -> [WeatherAlert] {
        var alerts: [WeatherAlert] = []
        let upcoming = snapshot.hours.filter { $0.time > now.addingTimeInterval(-1800) }

        // Dry now, likely wet within three hours (once per six hours).
        let dryNow = !isWet(snapshot.currentCode) && snapshot.currentPrecipitation < 0.1
        if dryNow, state.lastPrecipitationAlert.map({ now.timeIntervalSince($0) > 6 * 3600 }) ?? true,
           let hour = upcoming.first(where: { $0.time <= now.addingTimeInterval(3 * 3600)
                                              && ($0.precipitationProbability >= 60 || (isWet($0.code) && $0.precipitationProbability >= 40)) }) {
            state.lastPrecipitationAlert = now
            alerts.append(.precipitationSoon(minutes: max(0, Int(hour.time.timeIntervalSince(now) / 60)),
                                             probability: Int(hour.precipitationProbability), snow: isSnow(hour.code)))
        }

        // Severe weather within six hours (once per six hours).
        if state.lastSevereAlert.map({ now.timeIntervalSince($0) > 6 * 3600 }) ?? true,
           let hour = upcoming.first(where: { $0.time <= now.addingTimeInterval(6 * 3600)
                                              && (severeDescription($0.code) != nil || $0.windSpeed >= windThreshold) }) {
            state.lastSevereAlert = now
            let description = severeDescription(hour.code) ?? String(format: tr("大风（约 %.0f km/h）", "strong wind (about %.0f km/h)"), hour.windSpeed)
            alerts.append(.severe(minutes: max(0, Int(hour.time.timeIntervalSince(now) / 60)), description: description))
        }

        // In the evening: tomorrow much warmer or colder than today, or rainy (once per day).
        let day = ReminderRules.dayStamp(now, calendar)
        if calendar.component(.hour, from: now) >= 17, state.lastTomorrowAlertDay != day {
            var change: Int?
            if let today = snapshot.todayMax, let tomorrow = snapshot.tomorrowMax, abs(tomorrow - today) >= 6 {
                change = Int((tomorrow - today).rounded())
            }
            var rain: Int?
            if let p = snapshot.tomorrowPrecipitationProbability, p >= 70 { rain = Int(p) }
            if change != nil || rain != nil {
                state.lastTomorrowAlertDay = day
                alerts.append(.tomorrow(temperatureChange: change, rainProbability: rain))
            }
        }
        return alerts
    }

    /// Text and motion for the pet.
    static func message(_ alert: WeatherAlert, place: String) -> (text: String, motion: PetMotion) {
        func when(_ minutes: Int) -> String {
            minutes < 50 ? tr("马上", "very soon") : tr("大约 \(Int((Double(minutes) / 60).rounded())) 小时后", "in about \(Int((Double(minutes) / 60).rounded())) h")
        }
        switch alert {
        case .precipitationSoon(let minutes, let probability, let snow):
            return snow
                ? (tr("\(place)\(when(minutes))可能下雪（概率 \(probability)%），出门注意保暖防滑～", "Snow is likely in \(place) \(when(minutes)) (\(probability)%). Dress warmly~"), .surprised)
                : (tr("\(place)\(when(minutes))可能下雨（概率 \(probability)%），出门记得带伞～", "Rain is likely in \(place) \(when(minutes)) (\(probability)%). Take an umbrella~"), .surprised)
        case .severe(let minutes, let description):
            return (tr("注意：\(place)\(when(minutes))可能有\(description)，尽量别出门哦。", "Heads up: \(description) is possible in \(place) \(when(minutes)). Better stay in."), .surprised)
        case .tomorrow(let change, let rain):
            var parts: [String] = []
            if let change {
                parts.append(change < 0 ? tr("明天比今天降温约 \(-change)°C，记得加衣服", "tomorrow will be about \(-change)°C colder, dress warmly")
                                        : tr("明天比今天升温约 \(change)°C，注意防暑", "tomorrow will be about \(change)°C warmer"))
            }
            if let rain { parts.append(tr("明天降水概率 \(rain)%，记得带伞", "rain is likely tomorrow (\(rain)%), take an umbrella")) }
            return (tr("天气预报：", "Forecast: ") + parts.joined(separator: tr("；", "; ")) + tr("～", "."), .nod)
        }
    }
}

/// Text helpers for the memory bank.
enum MemoryText {
    /// Letters and digits only, lower-cased: punctuation and spacing do not make two memories different.
    static func normalized(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// Whether `a` says essentially the same as `b`: equal after normalisation, one containing the other,
    /// or one obtained from the other by inserting a few characters (at least 70% of the longer text kept
    /// in order). A substituted word ("cat" → "dog") is a different fact and is not a duplicate.
    static func isDuplicate(_ a: String, _ b: String) -> Bool {
        let na = normalized(a), nb = normalized(b)
        guard !na.isEmpty, !nb.isEmpty else { return false }
        if na == nb || (na.count >= 4 && nb.contains(na)) || (nb.count >= 4 && na.contains(nb)) { return true }
        let (short, long) = na.count <= nb.count ? (Array(na), Array(nb)) : (Array(nb), Array(na))
        guard short.count >= 4, short.count * 10 >= long.count * 7 else { return false }
        var i = 0
        for c in long where i < short.count && c == short[i] { i += 1 }
        return i == short.count
    }
}
