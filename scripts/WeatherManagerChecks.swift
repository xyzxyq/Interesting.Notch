import Foundation
import AppKit
import SwiftUI
import CoreLocation
import MapKit

private final class WeatherStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var fail = false
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "api.open-meteo.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.fail ? 503 : 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"current\":{\"time\":\(Date.now.timeIntervalSince1970),\"weather_code\":61,\"wind_speed_10m\":2}}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class LocationStub: CLLocationManager {
    override var authorizationStatus: CLAuthorizationStatus { .authorizedAlways }
    override func requestLocation() {}
    override func stopUpdatingLocation() {}
}

private final class DistrictMark: CLPlacemark, @unchecked Sendable {
    override var locality: String? { "厦门市" }
    override var subLocality: String? { "思明区" }
}
private final class GeocoderStub: CLGeocoder {
    var replies: [CLGeocodeCompletionHandler] = []
    var fix: CLLocation?
    override func reverseGeocodeLocation(_ location: CLLocation, preferredLocale locale: Locale?, completionHandler: @escaping CLGeocodeCompletionHandler) {
        fix = location
        replies.append(completionHandler)
    }
    override func cancelGeocode() {}
}

@main @MainActor struct WeatherManagerChecks {
    static func main() async throws {
        assert(NotchWeatherManager.resolvedCity(locality: "北京市", region: "其他区域") == "北京市")
        assert(NotchWeatherManager.resolvedCity(locality: " ", region: "杭州市") == "杭州市")
        assert(NotchWeatherManager.resolvedCity(locality: nil, region: nil) == nil)
        assert(NotchWeatherManager.resolvedCity(locality: "厦门市", region: "福建省", district: "思明区") == "厦门市 · 思明区")
        assert(NotchWeatherManager.resolvedCity(locality: "上海市", region: nil, district: "上海市") == "上海市")
        assert(NotchWeatherManager.resolvedCity(locality: nil, region: nil, district: " ", administrativeArea: "福建省") == "福建省")
        URLProtocol.registerClass(WeatherStub.self)
        UserDefaults.standard.set(true, forKey: "weatherEffectsEnabled")
        UserDefaults.standard.set(try JSONEncoder().encode(WeatherPlace(name: "Saved city", latitude: 39.9, longitude: 116.4)), forKey: "weatherSelectedCity")
        let location = LocationStub()
        let geocoder = GeocoderStub()
        let manager = NotchWeatherManager(location: location, geocoder: geocoder, cityTimeout: 0.1)
        assert(manager.status != "天气动效未开启", "Restored enabled setting retained disabled state")
        try await Task.sleep(for: .milliseconds(200))
        assert(manager.snapshot?.place.name == "Saved city", "Startup did not load saved city's weather")
        manager.enabled = false
        manager.select(WeatherPlace(name: "Mock city", latitude: 39.9, longitude: 116.4))
        assert(manager.cityName == "Mock city")
        manager.enabled = true
        try await Task.sleep(for: .milliseconds(200))
        assert(manager.snapshot?.kind == .rain, "Enabled did not load weather")
        let host = NSHostingView(rootView: Form { Section { NotchWeatherSettings() } }.formStyle(.grouped))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 620), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()
        func fields(_ view: NSView) -> [NSTextField] {
            (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { fields($0) }
        }
        let input = fields(host).first { $0.isEditable }
        assert(input != nil && input!.bounds.width > 200, "Manual city input missing or collapsed")
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/weather-settings-preview.png"))
        window.orderOut(nil)
        let manual = manager.selected
        let weatherBeforeSwitch = manager.snapshot
        manager.select(nil)
        assert(manager.selected == manual && manager.snapshot == weatherBeforeSwitch, "Automatic attempt discarded manual weather")
        manager.locationManager(location, didFailWithError: NSError(domain: kCLErrorDomain, code: CLError.locationUnknown.rawValue))
        assert(manager.selected == manual && manager.snapshot == weatherBeforeSwitch, "Location failure discarded manual city")
        assert(manager.locationNotice?.contains("继续使用手动城市") == true)
        manager.locationManager(location, didUpdateLocations: [CLLocation(latitude: 24.48, longitude: 118.08)])
        assert(manager.selected == nil, "Successful coordinates did not switch to automatic")
        // A geocoder that never calls back must not leave a permanent loading label.
        try await Task.sleep(for: .milliseconds(200))
        assert(manager.locationNotice?.contains("超时") == true)
        assert(!manager.cityName.contains("正在解析") && manager.snapshot != nil)
        geocoder.replies[0]([DistrictMark(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: 24.48, longitude: 118.08)))], nil)
        try await Task.sleep(for: .milliseconds(20))
        assert(!manager.cityName.contains("思明区"), "Late timed-out result overwrote state")
        manager.enabled = false
        manager.enabled = true
        manager.locationManager(location, didUpdateLocations: [CLLocation(latitude: 24.48123, longitude: 118.08123)])
        assert(geocoder.fix?.coordinate.latitude == 24.48123, "Geocoder received rounded coordinates")
        geocoder.replies.last!([DistrictMark(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: 24.48, longitude: 118.08)))], nil)
        try await Task.sleep(for: .milliseconds(60))
        assert(manager.cityName == "厦门市 · 思明区" && manager.locationNotice == nil)
        assert(manager.snapshot?.place.name == "厦门市 · 思明区", "Weather retained loading name")
        let count = geocoder.replies.count
        manager.locationManager(location, didUpdateLocations: [CLLocation(latitude: 24.48123, longitude: 118.08123)])
        assert(geocoder.replies.count == count, "Duplicate fix restarted geocoding")
        manager.enabled = false
        manager.select(manual)
        manager.enabled = true
        try await Task.sleep(for: .milliseconds(200))
        manager.enabled = false
        assert(manager.snapshot == nil, "Disabled retained effects")
        WeatherStub.fail = true
        manager.enabled = true
        try await Task.sleep(for: .milliseconds(200))
        assert(manager.snapshot?.kind == .rain && manager.status.contains("更新失败"), "503 discarded fresh cache")
        manager.select(WeatherPlace(name: "Other city", latitude: 40, longitude: 117))
        try await Task.sleep(for: .milliseconds(200))
        assert(manager.snapshot == nil, "Different city reused old weather")
        WeatherStub.fail = false
        manager.enabled = false
        manager.enabled = true
        try await Task.sleep(for: .milliseconds(200))
        assert(manager.snapshot?.place.name == "Other city", "Toggle did not reload current city")
        manager.enabled = false
        manager.enabled = true
        manager.enabled = false
        try await Task.sleep(for: .milliseconds(200))
        assert(manager.snapshot == nil && manager.status == "天气动效未开启", "Late request repopulated disabled effects")
        manager.select(nil)
        assert(manager.cityName == "尚未获取城市")
        for key in ["weatherEffectsEnabled", "weatherSelectedCity", "weatherSnapshot"] { UserDefaults.standard.removeObject(forKey: key) }
        URLProtocol.unregisterClass(WeatherStub.self)
        print("Weather manager checks passed: city/district, timeout, late callback, raw fix, duplicate fix, enable/disable, 503 cache and toggle reload")
    }
}
