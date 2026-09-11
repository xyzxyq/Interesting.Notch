import Foundation

enum NotchWeatherKind: String, Codable, CaseIterable {
    case rain, wind, clear, cloudy, snow
    var label: String {
        switch self {
        case .rain: return "雨"
        case .wind: return "风"
        case .clear: return "晴"
        case .cloudy: return "阴 / 多云"
        case .snow: return "雪"
        }
    }
    static func classify(code: Int, wind: Double) -> Self? {
        guard wind.isFinite, wind >= 0 else { return nil }
        switch code {
        case 71, 73, 75, 77, 85, 86: return .snow
        case 51, 53, 55, 56, 57, 61, 63, 65, 66, 67, 80, 81, 82, 95, 96, 99: return .rain
        case 0, 1, 2, 3, 45, 48:
            // Visual threshold in m/s, not a meteorological warning category.
            if wind >= 5.5 { return .wind }
            return code <= 1 ? .clear : .cloudy
        default: return nil
        }
    }
}

struct WeatherPlace: Codable, Equatable, Identifiable {
    let name: String
    let latitude: Double
    let longitude: Double
    var id: String { "\(latitude),\(longitude)" }
    var valid: Bool { latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude) }
}

struct NotchWeatherSnapshot: Codable, Equatable {
    let kind: NotchWeatherKind
    let wind: Double
    let observed: Date
    let fetched: Date
    let place: WeatherPlace
    func fresh(at date: Date) -> Bool {
        let age = date.timeIntervalSince(observed)
        return age >= -900 && age < 7200 && date.timeIntervalSince(fetched) >= -900 && date.timeIntervalSince(fetched) < 7200
    }
}

enum NotchWeatherAPI {
    struct Forecast: Decodable {
        struct Current: Decodable { let time: Double; let weather_code: Int; let wind_speed_10m: Double }
        let current: Current
    }
    static func forecastURL(_ place: WeatherPlace) -> URL? {
        guard place.valid else { return nil }
        var url = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        url.queryItems = [URLQueryItem(name: "latitude", value: String(place.latitude)),
                          URLQueryItem(name: "longitude", value: String(place.longitude)),
                          URLQueryItem(name: "current", value: "weather_code,wind_speed_10m"),
                          URLQueryItem(name: "wind_speed_unit", value: "ms"),
                          URLQueryItem(name: "timeformat", value: "unixtime")]
        return url.url
    }
    static func decode(_ data: Data, place: WeatherPlace, now: Date = .now) throws -> NotchWeatherSnapshot {
        let current = try JSONDecoder().decode(Forecast.self, from: data).current
        guard place.valid, current.time.isFinite,
              let kind = NotchWeatherKind.classify(code: current.weather_code, wind: current.wind_speed_10m) else {
            throw URLError(.cannotParseResponse)
        }
        let snapshot = NotchWeatherSnapshot(kind: kind, wind: current.wind_speed_10m,
            observed: Date(timeIntervalSince1970: current.time), fetched: now, place: place)
        guard snapshot.fresh(at: now) else { throw URLError(.cannotParseResponse) }
        return snapshot
    }
    static func data(from url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw URLError(.badServerResponse) }
        guard data.count < 1_000_000 else { throw URLError(.dataLengthExceedsMaximum) }
        try Task.checkCancellation()
        return data
    }
    static func cities(_ query: String) async throws -> [WeatherPlace] {
        struct Search: Decodable {
            struct City: Decodable { let name: String; let latitude: Double; let longitude: Double; let admin1: String?; let country: String? }
            let results: [City]?
        }
        var url = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        url.queryItems = [URLQueryItem(name: "name", value: query), URLQueryItem(name: "count", value: "5"), URLQueryItem(name: "language", value: "zh")]
        let result = try JSONDecoder().decode(Search.self, from: await data(from: url.url!))
        return (result.results ?? []).map { city in
            WeatherPlace(name: [city.name, city.admin1, city.country].compactMap { $0 }.joined(separator: " · "), latitude: city.latitude, longitude: city.longitude)
        }.filter(\.valid)
    }
}
