import Foundation

/// The organization's Claude API spending from the Admin API's cost report (`GET /v1/organizations/cost_report`, with
/// an Admin API key `sk-ant-admin…`): daily buckets of UTC days, amounts in cents. The API reports what was spent,
/// not the credit left; the remaining balance is estimated from a balance the owner reads in the Console and enters.
struct ClaudeCost: Equatable {
    /// Cents spent per UTC day, by the day's start.
    var days: [Date: Double]
    var fetched: Date

    static let endpoint = "https://api.anthropic.com/v1/organizations/cost_report"
    static let consoleURL = "https://platform.claude.com/settings/billing"
    /// Pages fetched at most per refresh (31 days each).
    static let maxPages = 4

    private static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    static func dayStart(_ date: Date) -> Date { utc.startOfDay(for: date) }

    static func monthStart(_ date: Date) -> Date {
        utc.date(from: utc.dateComponents([.year, .month], from: date)) ?? dayStart(date)
    }

    /// Daily buckets from `start` (the API snaps it to the UTC day), 31 per page.
    static func url(from start: Date, page: String? = nil, endpoint: String = endpoint) -> URL? {
        var c = URLComponents(string: endpoint)
        var items = [URLQueryItem(name: "starting_at", value: ISO8601DateFormatter().string(from: dayStart(start))),
                     URLQueryItem(name: "bucket_width", value: "1d"),
                     URLQueryItem(name: "limit", value: "31")]
        if let page { items.append(URLQueryItem(name: "page", value: page)) }
        c?.queryItems = items
        return c?.url
    }

    /// One page of the report: cents per day (all results of a bucket added up, USD only), and the cursor of the next
    /// page; nil when the answer is not a cost report.
    static func parse(_ data: Data) -> (days: [Date: Double], next: String?)? {
        guard let json = try? JSON.parse(data), let buckets = json["data"]?.array else { return nil }
        let iso = ISO8601DateFormatter()
        var days: [Date: Double] = [:]
        for b in buckets {
            guard let start = b["starting_at"]?.string.flatMap({ iso.date(from: $0) }) else { continue }
            let cents = (b["results"]?.array ?? []).reduce(0.0) { sum, r in
                guard (r["currency"]?.string ?? "USD") == "USD" else { return sum }
                return sum + (r["amount"]?.string.flatMap(Double.init) ?? r["amount"]?.double ?? 0)
            }
            days[start, default: 0] += cents
        }
        let more = json["has_more"]?.bool == true
        return (days, more ? json["next_page"]?.string : nil)
    }

    /// Cents spent on the UTC days from the one containing `start` on.
    func spent(since start: Date) -> Double {
        let first = Self.dayStart(start)
        return days.filter { $0.key >= first }.values.reduce(0, +)
    }

    /// Cents spent today (UTC) and this month (UTC), as of the fetch.
    var today: Double { days[Self.dayStart(fetched)] ?? 0 }
    var month: Double { spent(since: Self.monthStart(fetched)) }

    /// Estimated balance in dollars: the balance read in the Console at `since`, minus what was spent from then on;
    /// `offset` is what had been spent on that UTC day before `since` (already deducted in that balance).
    func remaining(base: Double, since: Date, offset: Double) -> Double {
        base - max(0, spent(since: since) - offset) / 100
    }

    static func dollars(_ cents: Double) -> String { String(format: "$%.2f", cents / 100) }

    /// Lines for the menu and the settings: today, this month, and the estimated balance when one was entered.
    func lines(base: Double, since: Date?, offset: Double) -> [String] {
        var lines = [tr("今日（UTC）花费 ", "Spent today (UTC) ") + Self.dollars(today),
                     tr("本月（UTC）花费 ", "Spent this month (UTC) ") + Self.dollars(month)]
        if base > 0, let since {
            lines.append(tr("估算余额 ", "Estimated balance ") + Self.dollars(remaining(base: base, since: since, offset: offset) * 100))
        }
        return lines
    }
}
