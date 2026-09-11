import Foundation

@main struct WeatherChecks {
    static func main() async throws {
        for (code, wind, expected) in [(61, 10.0, NotchWeatherKind.rain), (95, 0, .rain), (85, 8, .snow),
                                       (0, 0, .clear), (1, 5.4, .clear), (3, 5.5, .wind), (3, 2, .cloudy), (45, 0, .cloudy)] {
            assert(NotchWeatherKind.classify(code: code, wind: wind) == expected)
        }
        assert(NotchWeatherKind.classify(code: 500, wind: 0) == nil)
        assert(NotchWeatherKind.classify(code: 0, wind: -1) == nil)
        let place = WeatherPlace(name: "Test", latitude: 39.9, longitude: 116.4)
        assert(NotchWeatherAPI.forecastURL(place)?.absoluteString.contains("wind_speed_unit=ms") == true)
        assert(NotchWeatherAPI.forecastURL(WeatherPlace(name: "Invalid", latitude: 91, longitude: 0)) == nil)
        let now = Date(timeIntervalSince1970: 1_000_000)
        let json = Data("{\"current\":{\"time\":1000000,\"weather_code\":73,\"wind_speed_10m\":2}}".utf8)
        let snapshot = try NotchWeatherAPI.decode(json, place: place, now: now)
        assert(snapshot.kind == .snow)
        assert(snapshot.fresh(at: now.addingTimeInterval(7199)))
        assert(!snapshot.fresh(at: now.addingTimeInterval(7200)))
        assert(!snapshot.fresh(at: now.addingTimeInterval(-901)))
        assert((try? NotchWeatherAPI.decode(json, place: place, now: now.addingTimeInterval(7200))) == nil)
        assert((try? NotchWeatherAPI.decode(Data("{}".utf8), place: place, now: now)) == nil)
        let restored = try JSONDecoder().decode(NotchWeatherSnapshot.self, from: JSONEncoder().encode(snapshot))
        assert(restored == snapshot)
        print("Weather checks passed: WMO mapping, wind units, invalid data, cache expiry, persistence")
        if CommandLine.arguments.contains("--live") {
            let cities = try await NotchWeatherAPI.cities("Beijing")
            guard let city = cities.first, let url = NotchWeatherAPI.forecastURL(city) else { fatalError("City search returned no valid result") }
            let current = try NotchWeatherAPI.decode(try await NotchWeatherAPI.data(from: url), place: city)
            assert(current.fresh(at: .now))
            print("Live Open-Meteo city search and weather decode passed (public Beijing test location)")
        }
    }
}
