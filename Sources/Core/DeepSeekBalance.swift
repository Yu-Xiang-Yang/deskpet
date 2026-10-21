import Foundation

/// The DeepSeek account balance (`GET https://api.deepseek.com/user/balance`): per currency the total, the granted
/// part (gifts, may expire) and the topped-up part, and whether the balance still suffices for API calls.
struct DeepSeekBalance: Equatable {
    struct Account: Equatable {
        var currency: String
        var total: Double
        var granted: Double
        var toppedUp: Double
    }

    var available: Bool
    var accounts: [Account]
    var fetched: Date

    /// The balance endpoint on the host of a DeepSeek base URL ("https://api.deepseek.com/v1"); nil for other providers.
    static func endpoint(baseURL: String) -> URL? {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespaces)), let host = url.host,
              host.hasSuffix("deepseek.com") else { return nil }
        var c = URLComponents()
        c.scheme = url.scheme ?? "https"
        c.host = host
        c.port = url.port
        c.path = "/user/balance"
        return c.url
    }

    static func parse(_ data: Data, fetched: Date = Date()) -> DeepSeekBalance? {
        guard let json = try? JSON.parse(data), let available = json["is_available"]?.bool,
              let infos = json["balance_infos"]?.array else { return nil }
        func amount(_ v: JSON?) -> Double { v?.string.flatMap(Double.init) ?? v?.double ?? 0 }
        let accounts = infos.compactMap { i -> Account? in
            guard let currency = i["currency"]?.string else { return nil }
            return Account(currency: currency, total: amount(i["total_balance"]), granted: amount(i["granted_balance"]),
                           toppedUp: amount(i["topped_up_balance"]))
        }
        return DeepSeekBalance(available: available, accounts: accounts, fetched: fetched)
    }

    static func money(_ value: Double, _ currency: String) -> String {
        let symbol = ["CNY": "¥", "USD": "$"][currency] ?? currency + " "
        return symbol + String(format: "%.2f", value)
    }

    /// "¥110.00" (several currencies joined by " · "), or a note when the account is empty.
    var short: String {
        accounts.isEmpty ? tr("无余额信息", "no balance") : accounts.map { Self.money($0.total, $0.currency) }.joined(separator: " · ")
    }

    /// One line per currency for the menu: total, then granted and topped-up parts.
    var lines: [String] {
        accounts.map { a in
            tr("\(Self.money(a.total, a.currency))（赠送 \(Self.money(a.granted, a.currency)) · 充值 \(Self.money(a.toppedUp, a.currency))）",
               "\(Self.money(a.total, a.currency)) (granted \(Self.money(a.granted, a.currency)) · topped up \(Self.money(a.toppedUp, a.currency)))")
        }
    }

    /// The balance below which the pet warns: ¥10 or $1.50.
    static func lowMark(_ currency: String) -> Double { currency == "USD" ? 1.5 : 10 }

    var isLow: Bool { !available || accounts.contains { $0.total < Self.lowMark($0.currency) } }
}

/// Whether the low-balance warning was given (it is given again only after the balance recovered).
struct DeepSeekBalanceAlertState: Codable, Equatable {
    var warned = false
}

enum DeepSeekBalanceAlerts {
    /// The warning due for `balance`, if any; updates `state` so that it is given once per low spell.
    static func evaluate(_ balance: DeepSeekBalance, state: inout DeepSeekBalanceAlertState) -> (text: String, motion: PetMotion)? {
        guard balance.isLow else { state.warned = false; return nil }
        guard !state.warned else { return nil }
        state.warned = true
        if !balance.available {
            return (tr("DeepSeek 余额已经不够调用了（\(balance.short)），我可能没法回答你了，记得充值～",
                       "The DeepSeek balance no longer covers API calls (\(balance.short)). Please top it up~"), .surprised)
        }
        return (tr("DeepSeek 余额只剩 \(balance.short) 了，记得及时充值～", "Only \(balance.short) left on DeepSeek. Time to top up~"), .surprised)
    }
}
