import Foundation
import AppKit
import SwiftUI
import CoreLocation

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

@main @MainActor struct WeatherManagerChecks {
    static func main() async throws {
        assert(NotchWeatherManager.resolvedCity(locality: "北京市", region: "其他区域") == "北京市")
        assert(NotchWeatherManager.resolvedCity(locality: " ", region: "杭州市") == "杭州市")
        assert(NotchWeatherManager.resolvedCity(locality: nil, region: nil) == nil)
        URLProtocol.registerClass(WeatherStub.self)
        UserDefaults.standard.set(true, forKey: "weatherEffectsEnabled")
        UserDefaults.standard.set(try JSONEncoder().encode(WeatherPlace(name: "Saved city", latitude: 39.9, longitude: 116.4)), forKey: "weatherSelectedCity")
        let manager = NotchWeatherManager.shared
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
        print("Weather manager checks passed: enable, disable, 503 cache fallback, city change, toggle reload")
    }
}
