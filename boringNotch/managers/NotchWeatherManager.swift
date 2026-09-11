import SwiftUI
import CoreLocation

@MainActor final class NotchWeatherManager: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    static let shared = NotchWeatherManager()
    @Published var enabled = UserDefaults.standard.bool(forKey: "weatherEffectsEnabled") {
        didSet { UserDefaults.standard.set(enabled, forKey: "weatherEffectsEnabled"); restart() }
    }
    @Published private(set) var snapshot: NotchWeatherSnapshot?
    @Published private(set) var status = "天气动效未开启"
    @Published private(set) var selected: WeatherPlace?
    private let location = CLLocationManager()
    private var located: WeatherPlace?
    private var loop: Task<Void, Never>?
    private var request: Task<Void, Never>?
    private var generation = 0
    private var lastAttempt = Date.distantPast
    private var lastLocationRequest = Date.distantPast
    private var cached: NotchWeatherSnapshot?

    override private init() {
        super.init()
        selected = UserDefaults.standard.data(forKey: "weatherSelectedCity").flatMap { try? JSONDecoder().decode(WeatherPlace.self, from: $0) }
        cached = UserDefaults.standard.data(forKey: "weatherSnapshot").flatMap { try? JSONDecoder().decode(NotchWeatherSnapshot.self, from: $0) }
        // Created on the main actor; Core Location delegates use this run loop.
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyKilometer
    }
    func start() { if enabled && loop == nil { restart() } }
    func select(_ place: WeatherPlace?) {
        selected = place
        UserDefaults.standard.set(place.flatMap { try? JSONEncoder().encode($0) }, forKey: "weatherSelectedCity")
        located = nil
        cached = nil
        snapshot = nil
        UserDefaults.standard.removeObject(forKey: "weatherSnapshot")
        restart()
    }
    func restart() {
        generation += 1
        loop?.cancel(); loop = nil
        request?.cancel(); request = nil
        lastAttempt = .distantPast
        lastLocationRequest = .distantPast
        guard enabled else { snapshot = nil; status = "天气动效未开启"; return }
        tick()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                self?.tick()
            }
        }
    }
    private func tick() {
        if let current = snapshot, !current.fresh(at: .now) {
            snapshot = nil
            status = "天气已过期，暂用普通波浪"
        }
        if selected == nil && Date.now.timeIntervalSince(lastLocationRequest) >= 900 {
            lastLocationRequest = .now
            switch location.authorizationStatus {
            case .notDetermined:
                status = "请允许定位，或在下方选择城市"
                location.requestWhenInUseAuthorization()
            case .authorizedAlways, .authorizedWhenInUse: location.requestLocation()
            default:
                located = nil
                snapshot = nil
                generation += 1
                request?.cancel(); request = nil
                status = "定位不可用，请选择城市"
            }
        }
        guard let place = selected ?? located else { return }
        if snapshot == nil, let cached, cached.place.id == place.id, cached.fresh(at: .now) { snapshot = cached }
        guard request == nil, Date.now.timeIntervalSince(lastAttempt) >= 900 else { return }
        fetch(place)
    }
    private func fetch(_ place: WeatherPlace) {
        guard let url = NotchWeatherAPI.forecastURL(place) else { status = "城市坐标无效，请重新选择"; return }
        lastAttempt = .now
        let token = generation
        status = "正在更新天气…"
        request = Task { [weak self] in
            do {
                let data = try await NotchWeatherAPI.data(from: url)
                let value = try NotchWeatherAPI.decode(data, place: place)
                guard let self, !Task.isCancelled, self.generation == token else { return }
                self.snapshot = value; self.cached = value
                UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: "weatherSnapshot")
                self.status = "\(place.name) · \(value.kind.label) · \(value.observed.formatted(date: .omitted, time: .shortened)) 更新"
                self.request = nil
            } catch {
                guard let self, !Task.isCancelled, self.generation == token else { return }
                if self.snapshot?.fresh(at: .now) != true { self.snapshot = nil }
                self.status = self.snapshot == nil ? "天气暂不可用，使用普通波浪；稍后自动更新" : "更新失败，暂用近期天气；稍后自动更新"
                self.request = nil
            }
        }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard enabled, selected == nil else { return }
        lastLocationRequest = .distantPast
        tick()
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard enabled, selected == nil, let value = locations.last, value.horizontalAccuracy >= 0,
              abs(value.timestamp.timeIntervalSinceNow) < 600 else { return }
        // City-scale coordinates are sufficient for these decorative effects.
        let place = WeatherPlace(name: "当前位置", latitude: (value.coordinate.latitude * 100).rounded() / 100,
                                 longitude: (value.coordinate.longitude * 100).rounded() / 100)
        guard place.valid else { return }
        if located?.id != place.id {
            generation += 1; request?.cancel(); request = nil
            snapshot = nil; lastAttempt = .distantPast
        }
        located = place
        tick()
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard enabled, selected == nil else { return }
        status = "定位暂不可用，可在下方选择城市"
    }
}

struct NotchWeatherSettings: View {
    @ObservedObject private var weather = NotchWeatherManager.shared
    @State private var query = ""
    @State private var cities: [WeatherPlace] = []
    @State private var searchStatus = ""
    var body: some View {
        Toggle("天气波浪动效", isOn: $weather.enabled)
        if weather.enabled {
            Text(weather.status).font(.caption).foregroundStyle(.secondary)
            Text("地点：\(weather.selected?.name ?? "当前位置")").font(.caption)
            if weather.selected != nil { Button("使用当前位置") { weather.select(nil) } }
            TextField("搜索城市（定位不可用时可手动选择）", text: $query)
                .task(id: query) {
                    cities = []; searchStatus = ""
                    let name = query.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard name.count >= 2 else { return }
                    do {
                        try await Task.sleep(for: .milliseconds(400))
                        let results = try await NotchWeatherAPI.cities(name)
                        try Task.checkCancellation()
                        cities = results
                        searchStatus = results.isEmpty ? "未找到城市，可尝试拼音或英文名" : ""
                    } catch {
                        if !Task.isCancelled { searchStatus = "城市搜索暂不可用，请稍后修改搜索词" }
                    }
                }
            ForEach(cities) { city in
                Button(city.name) { weather.select(city); query = ""; cities = [] }
            }
            if !searchStatus.isEmpty { Text(searchStatus).font(.caption).foregroundStyle(.secondary) }
            Text("每 15 分钟更新。位置坐标用于向 Open-Meteo 查询天气；歌词出现时隐藏天气粒子。").font(.caption).foregroundStyle(.secondary)
            Link("天气数据：Open-Meteo · CC BY 4.0", destination: URL(string: "https://open-meteo.com/")!).font(.caption)
        }
    }
}
