import Foundation

/// Checks the owner's local forecast every 20 minutes and announces changes worth knowing
/// (rain soon, severe weather, a much colder or rainy tomorrow) through the pet.
@MainActor
final class WeatherWatcher {
    private let settings = AppSettings.shared
    private let announce: (String, PetMotion) -> Void
    private var timer: Timer?
    private var checking = false
    private var state: WeatherAlertState {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(state), forKey: "weatherAlertState") }
    }

    init(announce: @escaping (String, PetMotion) -> Void) {
        self.announce = announce
        state = UserDefaults.standard.data(forKey: "weatherAlertState")
            .flatMap { try? JSONDecoder().decode(WeatherAlertState.self, from: $0) } ?? WeatherAlertState()
    }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 20 * 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.check() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in self?.check() }
    }

    /// Runs one check now (also used by the settings' test button); `force` ignores the on/off setting.
    func check(force: Bool = false, report: ((String) -> Void)? = nil) {
        let city = settings.city.trimmingCharacters(in: .whitespacesAndNewlines)
        guard force || settings.weatherAlerts, !city.isEmpty, !checking else {
            if city.isEmpty { report?(tr("请先在“主人信息”里填写所在城市。", "Set your city under About me first.")) }
            return
        }
        checking = true
        Task { @MainActor in
            defer { self.checking = false }
            guard let snapshot = try? await Weather.snapshot(location: city) else {
                report?(tr("暂时无法获取 \(city) 的天气。", "Weather for \(city) is unavailable right now."))
                return
            }
            var s = self.state
            let alerts = WeatherAlerts.evaluate(snapshot, now: Date(), state: &s)
            self.state = s
            for alert in alerts {
                let (text, motion) = WeatherAlerts.message(alert, place: snapshot.place)
                self.announce(text, motion)
            }
            report?(alerts.isEmpty ? tr("\(snapshot.place)：近期天气没有需要提醒的变化。", "\(snapshot.place): nothing to announce.")
                                   : tr("已发出 \(alerts.count) 条天气提醒。", "\(alerts.count) weather alert(s) sent."))
        }
    }
}
