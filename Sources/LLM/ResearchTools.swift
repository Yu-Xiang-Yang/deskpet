import Foundation

/// Client-side literature search tools, available to both providers.
enum ResearchTools {
    static let specs: [ToolSpec] = [
        ToolSpec(
            name: "search_arxiv",
            description: "Search arXiv preprints. Returns title, authors, date, abstract excerpt and URL for each match. "
                + "Use English keywords; supports arXiv query syntax such as ti:, au:, abs:, cat:.",
            schema: [
                "type": "object",
                "additionalProperties": false,
                "required": ["query"],
                "properties": [
                    "query": ["type": "string", "description": "Search terms."],
                    "max_results": ["type": "integer", "description": "Number of results, 1-20 (default 8)."],
                ],
            ]),
        ToolSpec(
            name: "search_semantic_scholar",
            description: "Search the Semantic Scholar index of published papers across disciplines. Returns title, authors, "
                + "venue, year, citation count, abstract excerpt and URL. Optionally restrict to a year range like 2022- or 2018-2020.",
            schema: [
                "type": "object",
                "additionalProperties": false,
                "required": ["query"],
                "properties": [
                    "query": ["type": "string", "description": "Search terms."],
                    "limit": ["type": "integer", "description": "Number of results, 1-20 (default 8)."],
                    "year": ["type": "string", "description": "Optional year filter, e.g. 2023- or 2019-2021."],
                ],
            ]),
        ToolSpec(
            name: "search_news",
            description: "Search recent news articles (Bing News, falling back to Google News). Returns title, source, "
                + "publication time, summary and URL, newest first. Use for current events, industry news and market news.",
            schema: [
                "type": "object",
                "additionalProperties": false,
                "required": ["query"],
                "properties": [
                    "query": ["type": "string", "description": "Search terms, in the language of the news wanted."],
                    "max_results": ["type": "integer", "description": "Number of results, 1-15 (default 8)."],
                ],
            ]),
        ToolSpec(
            name: "get_stock_quotes",
            description: "Latest quotes for stocks, indices or ETFs (Yahoo Finance): price, change and change percent versus "
                + "the previous close, currency and quote time. Symbols use Yahoo format: AAPL, NVDA, ^GSPC, ^IXIC, 0700.HK, "
                + "600519.SS, 000001.SZ; a plain 6-digit A-share code is accepted too.",
            schema: [
                "type": "object",
                "additionalProperties": false,
                "required": ["symbols"],
                "properties": [
                    "symbols": ["type": "array", "items": ["type": "string"], "description": "Up to 10 symbols."],
                ],
            ]),
        ToolSpec(
            name: "get_weather",
            description: "Current weather and a daily forecast (up to 7 days) for a city or place name in any language "
                + "(Open-Meteo): conditions, temperature, feels-like, humidity, wind, precipitation probability, UV index.",
            schema: [
                "type": "object",
                "additionalProperties": false,
                "required": ["location"],
                "properties": [
                    "location": ["type": "string", "description": "City or place, e.g. 杭州, Beijing, Tokyo."],
                    "days": ["type": "integer", "description": "Forecast days, 1-7 (default 3)."],
                ],
            ]),
        ToolSpec(
            name: "fetch_webpage",
            description: "Fetch a public web page (http/https) and return its readable text, truncated to about 6000 characters. "
                + "Use to read an article found by a search.",
            schema: [
                "type": "object",
                "additionalProperties": false,
                "required": ["url"],
                "properties": ["url": ["type": "string"]],
            ]),
    ]

    static func run(_ call: ToolCall) async -> ToolResult {
        let cacheKey = call.name + call.input.compactString
        if let cached = await ToolCache.shared.get(cacheKey) {
            return ToolResult(id: call.id, name: call.name, content: cached, isError: false)
        }
        let result = await execute(call)
        if !result.isError, !result.content.hasPrefix("Error") { await ToolCache.shared.set(cacheKey, result.content) }
        return result
    }

    private static func execute(_ call: ToolCall) async -> ToolResult {
        do {
            let output: String
            switch call.name {
            case "search_arxiv":
                output = try await arxiv(query: call.input["query"]?.string ?? "",
                                         max: clamp(call.input["max_results"]?.int ?? 8))
            case "search_semantic_scholar":
                output = try await semanticScholar(query: call.input["query"]?.string ?? "",
                                                   limit: clamp(call.input["limit"]?.int ?? 8),
                                                   year: call.input["year"]?.string)
            case "search_news", "web_search":
                // "web_search" is Claude's server tool; other models sometimes call it anyway.
                output = try await news(query: call.input["query"]?.string ?? "",
                                        max: min(max(call.input["max_results"]?.int ?? 8, 1), 15))
            case "get_stock_quotes":
                output = await quotes((call.input["symbols"]?.array ?? []).compactMap(\.string))
            case "get_weather":
                output = try await Weather.lookup(location: call.input["location"]?.string ?? "",
                                                  days: min(max(call.input["days"]?.int ?? 3, 1), 7))
            case "fetch_webpage":
                output = try await webpage(call.input["url"]?.string ?? "")
            default:
                return ToolResult(id: call.id, name: call.name, content: "Unknown tool \(call.name)", isError: true)
            }
            return ToolResult(id: call.id, name: call.name, content: output, isError: false)
        } catch {
            return ToolResult(id: call.id, name: call.name, content: "Error: \(error.localizedDescription)", isError: true)
        }
    }

    private static func clamp(_ n: Int) -> Int { min(max(n, 1), 20) }

    /// GET with a short timeout. HTTP 429/503 is retried once after a second; a host that keeps refusing is
    /// skipped for a minute, so that a throttled source fails fast and the model moves on to another one.
    static func get(_ url: URL, browserAgent: Bool = false) async throws -> Data {
        let host = url.host ?? ""
        if await ToolCache.shared.isCoolingDown(host) {
            throw LLMError.api("\(host) is rate-limiting requests; use another source.")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue(browserAgent ? "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
                                      : "DeskPet/1.0 (macOS desktop assistant)", forHTTPHeaderField: "user-agent")
        for attempt in 0..<2 {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status) { return data }
            if status == 429 || status == 503 {
                if attempt == 0 { try await Task.sleep(nanoseconds: 1_000_000_000); continue }
                await ToolCache.shared.coolDown(host, seconds: 60)
                throw LLMError.api("\(host) is rate-limiting requests (HTTP \(status)); use another source.")
            }
            throw LLMError.http(status: status, body: String(decoding: data.prefix(500), as: UTF8.self))
        }
        throw LLMError.badResponse(host)
    }

    // MARK: arXiv

    static func arxiv(query: String, max: Int) async throws -> String {
        var components = URLComponents(string: "https://export.arxiv.org/api/query")!
        let hasField = query.range(of: #"\b(ti|au|abs|cat|all):"#, options: .regularExpression) != nil
        components.queryItems = [
            URLQueryItem(name: "search_query", value: hasField ? query : "all:\(query)"),
            URLQueryItem(name: "start", value: "0"),
            URLQueryItem(name: "max_results", value: String(max)),
            URLQueryItem(name: "sortBy", value: "relevance"),
        ]
        let entries = ArxivAtomParser.parse(try await get(components.url!))
        if entries.isEmpty { return "No arXiv results for: \(query)" }
        return entries.enumerated().map { i, e in
            let authors = e.authors.prefix(5).joined(separator: ", ") + (e.authors.count > 5 ? " et al." : "")
            return "[\(i + 1)] \(e.title)\n    Authors: \(authors)\n    Published: \(e.published.prefix(10))\n"
                + "    URL: \(e.url)\n    Abstract: \(e.summary.prefix(600))"
        }.joined(separator: "\n\n")
    }

    // MARK: Semantic Scholar

    static func semanticScholar(query: String, limit: Int, year: String?) async throws -> String {
        var components = URLComponents(string: "https://api.semanticscholar.org/graph/v1/paper/search")!
        var items = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "fields", value: "title,authors,year,venue,citationCount,abstract,url,externalIds"),
        ]
        if let year, !year.isEmpty { items.append(URLQueryItem(name: "year", value: year)) }
        components.queryItems = items
        let json = try JSON.parse(try await get(components.url!))
        let papers = json["data"]?.array ?? []
        if papers.isEmpty { return "No Semantic Scholar results for: \(query)" }
        return papers.enumerated().map { i, p in
            let names = (p["authors"]?.array ?? []).compactMap { $0["name"]?.string }
            let authors = names.prefix(5).joined(separator: ", ") + (names.count > 5 ? " et al." : "")
            var url = p["url"]?.string ?? ""
            if let doi = p["externalIds"]?["DOI"]?.string { url = "https://doi.org/\(doi)" }
            else if let arxiv = p["externalIds"]?["ArXiv"]?.string { url = "https://arxiv.org/abs/\(arxiv)" }
            let abstract = p["abstract"]?.string.map { String($0.prefix(600)) } ?? "(no abstract)"
            return "[\(i + 1)] \(p["title"]?.string ?? "?")\n    Authors: \(authors)\n"
                + "    Venue/Year: \(p["venue"]?.string ?? "") \(p["year"]?.int.map(String.init) ?? "")\n"
                + "    Citations: \(p["citationCount"]?.int ?? 0)\n    URL: \(url)\n    Abstract: \(abstract)"
        }.joined(separator: "\n\n")
    }
}

extension ResearchTools {
    // MARK: News

    static func news(query: String, max: Int) async throws -> String {
        var items: [RSSParser.Item] = []
        var bing = URLComponents(string: "https://www.bing.com/news/search")!
        bing.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "format", value: "rss"),
                           URLQueryItem(name: "qft", value: "sortbydate=\"1\"")]
        if let data = try? await get(bing.url!, browserAgent: true) { items = RSSParser.parse(data) }
        if items.isEmpty {
            var google = URLComponents(string: "https://news.google.com/rss/search")!
            let zh = query.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF }
            google.queryItems = [URLQueryItem(name: "q", value: query + " when:7d"),
                                 URLQueryItem(name: "hl", value: zh ? "zh-CN" : "en-US"),
                                 URLQueryItem(name: "gl", value: zh ? "CN" : "US"),
                                 URLQueryItem(name: "ceid", value: zh ? "CN:zh-Hans" : "US:en")]
            items = RSSParser.parse(try await get(google.url!, browserAgent: true))
        }
        if items.isEmpty { return "No news found for: \(query)" }
        let sorted = items.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }.prefix(max)
        let format = ISO8601DateFormatter()
        return sorted.enumerated().map { i, item in
            let when = item.date.map { format.string(from: $0) } ?? item.pubDate
            let summary = item.summary.isEmpty ? "" : "\n    Summary: \(item.summary.prefix(300))"
            return "[\(i + 1)] \(item.title)\n    Source: \(item.source)  Published: \(when)\n    URL: \(item.link)\(summary)"
        }.joined(separator: "\n\n")
    }

    // MARK: Quotes

    /// A plain 6-digit A-share code becomes a Yahoo symbol (Shanghai .SS for 5/6/9…, Shenzhen .SZ otherwise).
    static func yahooSymbol(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces).uppercased()
        if s.hasPrefix("SH") || s.hasPrefix("SZ"), s.count == 8, Int(s.dropFirst(2)) != nil {
            return String(s.dropFirst(2)) + (s.hasPrefix("SH") ? ".SS" : ".SZ")
        }
        if s.count == 6, Int(s) != nil {
            s += ["5", "6", "9"].contains(s.prefix(1)) ? ".SS" : ".SZ"
        }
        return s
    }

    static func quotes(_ symbols: [String]) async -> String {
        guard !symbols.isEmpty else { return "No symbols given." }
        var lines: [String] = []
        for raw in symbols.prefix(10) {
            let symbol = yahooSymbol(raw)
            let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? symbol
            guard let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(encoded)?range=1d&interval=1d"),
                  let data = try? await get(url, browserAgent: true),
                  let meta = (try? JSON.parse(data))?["chart"]?["result"]?[0]?["meta"],
                  let price = meta["regularMarketPrice"]?.double else {
                lines.append("\(raw): quote unavailable")
                continue
            }
            let previous = meta["chartPreviousClose"]?.double ?? meta["previousClose"]?.double
            var line = "\(meta["longName"]?.string ?? meta["shortName"]?.string ?? symbol) (\(symbol)): "
                + String(format: "%.2f %@", price, meta["currency"]?.string ?? "")
            if let previous, previous > 0 {
                let change = price - previous
                line += String(format: ", %+.2f (%+.2f%%) vs previous close %.2f", change, change / previous * 100, previous)
            }
            if let t = meta["regularMarketTime"]?.double {
                line += ", as of " + ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: t))
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Web pages

    static func webpage(_ address: String) async throws -> String {
        guard let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased()),
              let host = url.host?.lowercased(), !isPrivateHost(host) else {
            return "Only public http(s) URLs can be fetched."
        }
        let data = try await get(url, browserAgent: true)
        let html = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        let text = readableText(html)
        return text.isEmpty ? "The page has no readable text." : String(text.prefix(6000))
    }

    /// Refuses local and private network addresses, so that model-chosen URLs cannot reach the local machine or LAN.
    static func isPrivateHost(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".localhost") || !host.contains(".") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4 {
            switch (parts[0], parts[1]) {
            case (10, _), (127, _), (0, _), (169, 254), (192, 168): return true
            case (172, 16...31): return true
            default: return false
            }
        }
        return host.contains(":")  // IPv6 literals
    }

    static func readableText(_ html: String) -> String {
        var s = html
        for pattern in ["(?is)<(script|style|noscript|svg|head|nav|footer)[^>]*>.*?</\\1>", "(?s)<!--.*?-->"] {
            s = s.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        s = s.replacingOccurrences(of: "(?i)<(br|/p|/div|/h[1-6]|/li|/tr)[^>]*>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        for (entity, char) in ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'"] {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        let lines = s.components(separatedBy: .newlines)
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { $0.count > 1 }
        return lines.joined(separator: "\n")
    }
}

/// Weather from Open-Meteo (free, no key): geocoding of place names in any language, current conditions
/// and a daily forecast.
enum Weather {
    struct Place { var name: String; var region: String; var latitude: Double; var longitude: Double }

    static func geocode(_ query: String) async throws -> Place? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let zh = trimmed.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF }
        // "杭州市" or "西湖区" may not match; retry without the administrative suffix.
        var candidates = [trimmed]
        if zh, let last = trimmed.last, "市区县省".contains(last), trimmed.count > 2 { candidates.append(String(trimmed.dropLast())) }
        for name in candidates {
            var c = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
            c.queryItems = [URLQueryItem(name: "name", value: name), URLQueryItem(name: "count", value: "1"),
                            URLQueryItem(name: "language", value: zh ? "zh" : "en")]
            let json = try JSON.parse(try await ResearchTools.get(c.url!))
            if let r = json["results"]?[0], let lat = r["latitude"]?.double, let lon = r["longitude"]?.double {
                let region = [r["country"]?.string, r["admin1"]?.string].compactMap { $0 }.joined(separator: " ")
                return Place(name: r["name"]?.string ?? name, region: region, latitude: lat, longitude: lon)
            }
        }
        return nil
    }

    /// A readable report: current conditions and `days` days of forecast.
    static func lookup(location: String, days: Int) async throws -> String {
        guard let place = try await geocode(location) else { return tr("找不到地点：", "Unknown place: ") + location }
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            URLQueryItem(name: "latitude", value: String(place.latitude)),
            URLQueryItem(name: "longitude", value: String(place.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m,precipitation"),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,uv_index_max"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: String(days)),
        ]
        let json = try JSON.parse(try await ResearchTools.get(c.url!))
        var lines = ["\(place.name)（\(place.region)）"]
        if let cur = json["current"] {
            var line = tr("当前：", "Now: ") + describe(cur["weather_code"]?.int ?? -1)
            if let t = cur["temperature_2m"]?.double { line += String(format: "，%.0f°C", t) }
            if let f = cur["apparent_temperature"]?.double { line += String(format: tr("，体感 %.0f°C", ", feels like %.0f°C"), f) }
            if let h = cur["relative_humidity_2m"]?.double { line += String(format: tr("，湿度 %.0f%%", ", humidity %.0f%%"), h) }
            if let w = cur["wind_speed_10m"]?.double { line += String(format: tr("，风速 %.0f km/h", ", wind %.0f km/h"), w) }
            if let p = cur["precipitation"]?.double, p > 0 { line += String(format: tr("，降水 %.1f mm", ", precipitation %.1f mm"), p) }
            lines.append(line)
        }
        if let daily = json["daily"], let dates = daily["time"]?.array {
            for (i, d) in dates.enumerated() {
                var line = (d.string ?? "") + "：" + describe(daily["weather_code"]?[i]?.int ?? -1)
                if let lo = daily["temperature_2m_min"]?[i]?.double, let hi = daily["temperature_2m_max"]?[i]?.double {
                    line += String(format: "，%.0f–%.0f°C", lo, hi)
                }
                if let p = daily["precipitation_probability_max"]?[i]?.double { line += String(format: tr("，降水概率 %.0f%%", ", rain chance %.0f%%"), p) }
                if let uv = daily["uv_index_max"]?[i]?.double { line += String(format: tr("，紫外线 %.0f", ", UV %.0f"), uv) }
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Structured forecast for weather alerts: current conditions, the next 12 hours and today/tomorrow.
    static func snapshot(location: String) async throws -> WeatherSnapshot? {
        guard let place = try await cachedPlace(location) else { return nil }
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            URLQueryItem(name: "latitude", value: String(place.latitude)),
            URLQueryItem(name: "longitude", value: String(place.longitude)),
            URLQueryItem(name: "current", value: "weather_code,precipitation"),
            URLQueryItem(name: "hourly", value: "weather_code,temperature_2m,precipitation_probability,precipitation,wind_speed_10m"),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "timeformat", value: "unixtime"),
            URLQueryItem(name: "forecast_days", value: "2"),
            URLQueryItem(name: "forecast_hours", value: "12"),
        ]
        let json = try JSON.parse(try await ResearchTools.get(c.url!))
        let h = json["hourly"]
        let times = h?["time"]?.array ?? []
        let hours = times.indices.compactMap { i -> WeatherSnapshot.Hour? in
            guard let t = times[i].double else { return nil }
            return WeatherSnapshot.Hour(time: Date(timeIntervalSince1970: t), code: h?["weather_code"]?[i]?.int ?? -1,
                                        temperature: h?["temperature_2m"]?[i]?.double ?? 0,
                                        precipitationProbability: h?["precipitation_probability"]?[i]?.double ?? 0,
                                        precipitation: h?["precipitation"]?[i]?.double ?? 0,
                                        windSpeed: h?["wind_speed_10m"]?[i]?.double ?? 0)
        }
        let d = json["daily"]
        return WeatherSnapshot(place: place.name, currentCode: json["current"]?["weather_code"]?.int ?? -1,
                               currentPrecipitation: json["current"]?["precipitation"]?.double ?? 0, hours: hours,
                               todayMax: d?["temperature_2m_max"]?[0]?.double, tomorrowMax: d?["temperature_2m_max"]?[1]?.double,
                               tomorrowMin: d?["temperature_2m_min"]?[1]?.double, tomorrowCode: d?["weather_code"]?[1]?.int,
                               tomorrowPrecipitationProbability: d?["precipitation_probability_max"]?[1]?.double)
    }

    /// Geocoding result cached for a day (the place does not move).
    private static func cachedPlace(_ location: String) async throws -> Place? {
        let key = "geo:" + location
        if let cached = await ToolCache.shared.get(key, maxAge: 86_400), let data = cached.data(using: .utf8),
           let p = try? JSON.parse(data), let lat = p["lat"]?.double, let lon = p["lon"]?.double {
            return Place(name: p["name"]?.string ?? location, region: p["region"]?.string ?? "", latitude: lat, longitude: lon)
        }
        guard let place = try await geocode(location) else { return nil }
        let entry: JSON = ["name": .string(place.name), "region": .string(place.region),
                           "lat": .number(place.latitude), "lon": .number(place.longitude)]
        await ToolCache.shared.set(key, entry.compactString)
        return place
    }

    /// One line for the pet's context, cached for 30 minutes per place.
    static func brief(_ city: String) async -> String? {
        if let cached = await ToolCache.shared.get("weather-brief:" + city, maxAge: 1800) { return cached }
        guard let report = try? await lookup(location: city, days: 1) else { return nil }
        let line = report.replacingOccurrences(of: "\n", with: "；")
        await ToolCache.shared.set("weather-brief:" + city, line)
        return line
    }

    /// WMO weather interpretation codes.
    static func describe(_ code: Int) -> String {
        let zh: [Int: String] = [0: "晴", 1: "大致晴朗", 2: "局部多云", 3: "阴", 45: "雾", 48: "雾凇", 51: "小毛毛雨", 53: "毛毛雨",
                                 55: "较强毛毛雨", 56: "冻毛毛雨", 57: "冻毛毛雨", 61: "小雨", 63: "中雨", 65: "大雨", 66: "冻雨",
                                 67: "强冻雨", 71: "小雪", 73: "中雪", 75: "大雪", 77: "雪粒", 80: "阵雨", 81: "中等阵雨",
                                 82: "强阵雨", 85: "阵雪", 86: "强阵雪", 95: "雷阵雨", 96: "雷阵雨伴冰雹", 99: "强雷阵雨伴冰雹"]
        let en: [Int: String] = [0: "clear", 1: "mainly clear", 2: "partly cloudy", 3: "overcast", 45: "fog", 48: "rime fog",
                                 51: "light drizzle", 53: "drizzle", 55: "dense drizzle", 56: "freezing drizzle", 57: "freezing drizzle",
                                 61: "light rain", 63: "rain", 65: "heavy rain", 66: "freezing rain", 67: "heavy freezing rain",
                                 71: "light snow", 73: "snow", 75: "heavy snow", 77: "snow grains", 80: "showers", 81: "moderate showers",
                                 82: "violent showers", 85: "snow showers", 86: "heavy snow showers", 95: "thunderstorm",
                                 96: "thunderstorm with hail", 99: "severe thunderstorm with hail"]
        return (L10n.current == .zh ? zh[code] : en[code]) ?? tr("未知", "unknown")
    }
}

/// Recent tool results (10 minutes) and hosts that are rate-limiting.
actor ToolCache {
    static let shared = ToolCache()
    private var results: [String: (date: Date, value: String)] = [:]
    private var cooldowns: [String: Date] = [:]

    func get(_ key: String, maxAge: TimeInterval = 600) -> String? {
        guard let entry = results[key], Date().timeIntervalSince(entry.date) < maxAge else { return nil }
        return entry.value
    }

    func set(_ key: String, _ value: String) {
        if results.count > 200 { results = results.filter { Date().timeIntervalSince($0.value.date) < 86_400 } }
        results[key] = (Date(), value)
    }

    func coolDown(_ host: String, seconds: TimeInterval) { cooldowns[host] = Date().addingTimeInterval(seconds) }

    func isCoolingDown(_ host: String) -> Bool { (cooldowns[host] ?? .distantPast) > Date() }
}

/// Minimal RSS 2.0 parser (Bing News, Google News).
final class RSSParser: NSObject, XMLParserDelegate {
    struct Item { var title = "", link = "", summary = "", pubDate = "", source = ""; var date: Date? }

    private var items: [Item] = []
    private var current: Item?
    private var text = ""

    static func parse(_ data: Data) -> [Item] {
        let delegate = RSSParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.items
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        if name == "item" { current = Item() }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, foundCDATA data: Data) { text += String(decoding: data, as: UTF8.self) }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "item": if let item = current, !item.title.isEmpty { items.append(item) }; current = nil
        case "title": current?.title = value
        case "link": current?.link = value
        case "description":
            current?.summary = ResearchTools.readableText(value).replacingOccurrences(of: "\n", with: " ")
        case "pubDate": current?.pubDate = value; current?.date = Self.dateFormatter.date(from: value)
        case "source", "News:Source": current?.source = value
        default: break
        }
    }
}

/// Minimal Atom parser for the arXiv API.
final class ArxivAtomParser: NSObject, XMLParserDelegate {
    struct Entry { var title = "", summary = "", published = "", url = "", authors: [String] = [] }

    private var entries: [Entry] = []
    private var current: Entry?
    private var text = ""
    private var inAuthor = false

    static func parse(_ data: Data) -> [Entry] {
        let delegate = ArxivAtomParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.entries
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        switch name {
        case "entry": current = Entry()
        case "author": inAuthor = true
        case "link":
            if attributes["rel"] == "alternate" || (attributes["type"] == "text/html"), let href = attributes["href"] {
                current?.url = href
            }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        switch name {
        case "entry": if let e = current { entries.append(e) }; current = nil
        case "title": current?.title = value
        case "summary": current?.summary = value
        case "published": current?.published = value
        case "id": if current?.url.isEmpty == true { current?.url = value }
        case "name": if inAuthor { current?.authors.append(value) }
        case "author": inAuthor = false
        default: break
        }
    }
}
