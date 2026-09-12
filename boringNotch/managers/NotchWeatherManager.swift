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
    private let location: CLLocationManager
    @Published private(set) var locationNotice: String?
    private var switchingToAutomatic = false
    @Published private var located: WeatherPlace?
    var cityName: String { selected?.name ?? located?.name ?? "尚未获取城市" }
    private let geocoder: CLGeocoder
    private let cityTimeout: TimeInterval
    private var cityToken: UUID?
    private var needsCityResolution = false
    private var lastFix: CLLocation?
    private var lastCityAttempt = Date.distantPast
    private var cityRequest: Task<Void, Never>?
    static func resolvedCity(locality: String?, region: String?, district: String? = nil, administrativeArea: String? = nil) -> String? {
        func clean(_ value: String?) -> String? {
            let text = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.isEmpty ? nil : text
        }
        let area = clean(district)
        let city = [clean(locality), clean(region), clean(administrativeArea)].compactMap { $0 }.first
        guard let city else { return area }
        return area.map { city == $0 || city.hasSuffix($0) ? city : "\(city) · \($0)" } ?? city
    }
    private static func isResolvedName(_ name: String) -> Bool {
        !["正在解析", "城市名称暂不可用", "位置已获取", "尚未获取", "当前位置"].contains { name.hasPrefix($0) }
    }
    private var loop: Task<Void, Never>?
    private var request: Task<Void, Never>?
    private var generation = 0
    private var lastAttempt = Date.distantPast
    private var lastLocationRequest = Date.distantPast
    private var locationRetryInterval: TimeInterval = 900
    private var lastAuthorization: CLAuthorizationStatus?
    private var cached: NotchWeatherSnapshot?

    init(location: CLLocationManager = CLLocationManager(), geocoder: CLGeocoder = CLGeocoder(), cityTimeout: TimeInterval = 10) {
        self.location = location
        self.geocoder = geocoder
        self.cityTimeout = cityTimeout
        super.init()
        selected = UserDefaults.standard.data(forKey: "weatherSelectedCity").flatMap { try? JSONDecoder().decode(WeatherPlace.self, from: $0) }
        cached = UserDefaults.standard.data(forKey: "weatherSnapshot").flatMap { try? JSONDecoder().decode(NotchWeatherSnapshot.self, from: $0) }
        // Created on the main actor; Core Location delegates use this run loop.
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyHundredMeters
        start()
    }
    func start() { if enabled && loop == nil { restart() } }
    func select(_ place: WeatherPlace?) {
        if place == nil, enabled, selected != nil {
            switchingToAutomatic = true
            locationNotice = "正在尝试自动定位，暂时保留手动城市"
            restart()
            return
        }
        switchingToAutomatic = false
        locationNotice = nil
        selected = place
        UserDefaults.standard.set(place.flatMap { try? JSONEncoder().encode($0) }, forKey: "weatherSelectedCity")
        located = nil
        needsCityResolution = false
        lastFix = nil
        cached = nil
        snapshot = nil
        UserDefaults.standard.removeObject(forKey: "weatherSnapshot")
        restart()
    }
    func restart() {
        generation += 1
        location.stopUpdatingLocation()
        cancelCityResolution()
        lastCityAttempt = .distantPast
        loop?.cancel(); loop = nil
        request?.cancel(); request = nil
        lastAttempt = .distantPast
        lastLocationRequest = .distantPast
        guard enabled else { switchingToAutomatic = false; locationNotice = nil; snapshot = nil; status = "天气动效未开启"; return }
        if !switchingToAutomatic { locationNotice = nil }
        status = "正在启动天气…"
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
        if (selected == nil || switchingToAutomatic) && Date.now.timeIntervalSince(lastLocationRequest) >= locationRetryInterval {
            lastLocationRequest = .now
            lastAuthorization = location.authorizationStatus
            switch location.authorizationStatus {
            case .notDetermined:
                status = "请允许定位，或在下方选择城市"
                location.requestWhenInUseAuthorization()
            case .authorizedAlways, .authorizedWhenInUse:
                if located == nil { status = "定位已授权，正在获取城市位置…" }
                location.stopUpdatingLocation()
                location.requestLocation()
            default:
                if switchingToAutomatic {
                    locationNotice = "自动定位未获许可，继续使用手动城市"
                    switchingToAutomatic = false
                    break
                }
                cancelCityResolution()
                located = nil
                snapshot = nil
                generation += 1
                request?.cancel(); request = nil
                status = "定位不可用，请选择城市"
            }
        }
        guard let place = selected ?? located else { return }
        if selected == nil, needsCityResolution, cityToken == nil, Date.now.timeIntervalSince(lastCityAttempt) >= 60 {
            resolveCity(for: place, location: lastFix ?? CLLocation(latitude: place.latitude, longitude: place.longitude))
        }
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
                let displayPlace = self?.located.flatMap { $0.id == place.id ? $0 : nil } ?? place
                let value = try NotchWeatherAPI.decode(data, place: displayPlace)
                guard let self, !Task.isCancelled, self.generation == token else { return }
                self.snapshot = value; self.cached = value
                UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: "weatherSnapshot")
                self.status = "\(value.place.name) · \(value.kind.label) · \(value.observed.formatted(date: .omitted, time: .shortened)) 更新"
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
        guard enabled, (selected == nil || switchingToAutomatic), lastAuthorization != manager.authorizationStatus else { return }
        lastAuthorization = manager.authorizationStatus
        lastLocationRequest = .distantPast
        tick()
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard enabled, (selected == nil || switchingToAutomatic), let value = locations.last, value.horizontalAccuracy >= 0,
              abs(value.timestamp.timeIntervalSinceNow) < 600 else { return }
        // Weather uses roughly 100 m coordinates; reverse geocoding uses the original fix.
        let place = WeatherPlace(name: "位置已获取", latitude: (value.coordinate.latitude * 1000).rounded() / 1000,
                                 longitude: (value.coordinate.longitude * 1000).rounded() / 1000)
        guard place.valid else { return }
        lastFix = value
        if switchingToAutomatic {
            switchingToAutomatic = false
            locationNotice = nil
            selected = nil
            UserDefaults.standard.removeObject(forKey: "weatherSelectedCity")
        }
        let changed = located?.id != place.id
        if changed {
            cancelCityResolution()
            generation += 1; request?.cancel(); request = nil
            snapshot = nil; lastAttempt = .distantPast
            located = cached.flatMap { $0.place.id == place.id && Self.isResolvedName($0.place.name) ? $0.place : nil } ?? place
            needsCityResolution = true
            lastCityAttempt = .distantPast
        }
        locationRetryInterval = 900
        if cityToken == nil, changed || Date.now.timeIntervalSince(lastCityAttempt) >= 60 {
            resolveCity(for: located ?? place, location: value)
        }
        tick()
    }
    private func cancelCityResolution() {
        if locationNotice == "正在解析城市与区域…" { locationNotice = nil }
        cityToken = nil
        cityRequest?.cancel(); cityRequest = nil
        geocoder.cancelGeocode()
    }
    private func resolveCity(for place: WeatherPlace, location fix: CLLocation) {
        guard cityToken == nil else { return }
        let token = UUID()
        cityToken = token
        lastCityAttempt = .now
        locationNotice = "正在解析城市与区域…"
        cityRequest = Task { [weak self] in
            guard let timeout = self?.cityTimeout else { return }
            do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
            self?.finishCity(nil, place: place, token: token, timedOut: true)
        }
        geocoder.reverseGeocodeLocation(fix, preferredLocale: .current) { [weak self] marks, _ in
            Task { @MainActor in
                let name = marks?.first.flatMap {
                    Self.resolvedCity(locality: $0.locality, region: $0.subAdministrativeArea,
                                      district: $0.subLocality, administrativeArea: $0.administrativeArea)
                }
                self?.finishCity(name, place: place, token: token, timedOut: false)
            }
        }
    }
    private func finishCity(_ name: String?, place: WeatherPlace, token: UUID, timedOut: Bool) {
        guard cityToken == token, enabled, selected == nil, located?.id == place.id else { return }
        cancelCityResolution()
        needsCityResolution = name == nil
        let previous = located?.name
        let displayName = name ?? previous.flatMap { Self.isResolvedName($0) ? $0 : nil } ?? "位置已获取，城市／区域暂不可用"
        let named = WeatherPlace(name: displayName, latitude: place.latitude, longitude: place.longitude)
        located = named
        locationNotice = name == nil ? "地址解析\(timedOut ? "超时" : "暂不可用")，一分钟后自动重试；天气仍按设备坐标查询" : nil
        if let current = snapshot, current.place.id == place.id {
            let updated = NotchWeatherSnapshot(kind: current.kind, wind: current.wind, observed: current.observed,
                                              fetched: current.fetched, place: named)
            snapshot = updated; cached = updated
            UserDefaults.standard.set(try? JSONEncoder().encode(updated), forKey: "weatherSnapshot")
            status = "\(named.name) · \(updated.kind.label) · \(updated.observed.formatted(date: .omitted, time: .shortened)) 更新"
        }
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard enabled, selected == nil || switchingToAutomatic else { return }
        location.stopUpdatingLocation()
        if switchingToAutomatic {
            locationRetryInterval = 60
            locationNotice = "自动定位失败，继续使用手动城市；一分钟后自动重试"
            return
        }
        let code = (error as? CLError)?.code
        if code == .denied {
            cancelCityResolution()
            located = nil
            snapshot = nil
            generation += 1
            request?.cancel(); request = nil
            status = "系统未允许定位，请手动选择城市"
        } else {
            locationRetryInterval = 60
            status = "系统暂未返回位置，一分钟后自动重试；也可手动选择城市"
        }
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
            if let notice = weather.locationNotice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
            }
            Text("地点：\(weather.cityName)").font(.caption)
            if weather.selected != nil { Button("使用当前位置") { weather.select(nil) } }
            VStack(alignment: .leading, spacing: 8) {
                Text("手动选择城市")
                TextField("城市名称", text: $query, prompt: Text("例如：北京 / Beijing"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("城市名称")
                Text("输入至少两个字或字母，再点击下方搜索结果。")
                    .font(.caption).foregroundStyle(.secondary)
            }
                .task(id: query) {
                    cities = []; searchStatus = ""
                    let name = query.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard name.count >= 2 else { return }
                    searchStatus = "正在搜索城市…"
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
                Button {
                    weather.select(city); query = ""; cities = []
                } label: {
                    HStack {
                        Image(systemName: "mappin.and.ellipse")
                        Text(city.name)
                        Spacer()
                        Text("选择").foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if !searchStatus.isEmpty { Text(searchStatus).font(.caption).foregroundStyle(.secondary) }
            Text("每 15 分钟更新。位置坐标用于向 Open-Meteo 查询天气；歌词出现时隐藏天气粒子。").font(.caption).foregroundStyle(.secondary)
            Link("天气数据：Open-Meteo · CC BY 4.0", destination: URL(string: "https://open-meteo.com/")!).font(.caption)
        }
    }
}
