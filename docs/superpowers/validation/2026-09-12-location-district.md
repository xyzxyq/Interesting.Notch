# Bounded address lookup and district display — 2026-09-12

Evidence: the installed application's persisted weather snapshot contained the literal loading label 正在解析城市…. The old reverse-geocoder awaited completion without an application timeout, restarted on every coordinate callback and stored a transient loading label as a place name. It also requested kilometer accuracy and reverse-geocoded coordinates rounded to 0.01 degrees.

Changes: transient resolving text is now a separate notice. Reverse-geocoding has a 10-second deadline, a per-request identity to reject late callbacks and coalescing for repeated fixes. Timeout/error ends the loading state and retries from the existing one-minute loop while weather continues using coordinates. Existing resolved names are retained for the same coordinate. Address formatting includes city and sublocality (district), with regional fallbacks and duplicate suppression. Core Location requests hundred-meter accuracy; reverse-geocoding uses the original fix while weather coordinates are rounded to 0.001 degrees. No additional location provider, dependencies, or retry button.

Validation:
- WeatherManagerChecks passed city/district formatting, missing fields, duplicate names, never-completing geocoder timeout, late callback rejection, original coordinate forwarding, duplicate-fix suppression, weather/name synchronization, manual-to-automatic transition, cache503, toggle and disabled-state checks. The mock geocoder intentionally ignores cancellation.
- Full Debug xcodebuild succeeded and git diff --check passed. CLGeocoder deprecation warnings remain on macOS26; retained for the project's macOS14 deployment target.
- Built product and stable installed bundle passed ad-hoc codesign verification. Old process quit, new application launched from /Users/zxy/Applications/InterestingNotch Development.app.
- Live read-back after restart confirmed the weather snapshot now contains a concrete city plus district rather than a loading label. User location/coordinates are intentionally not copied into this repository.

More detailed address display does not imply street-level forecast resolution; district availability and actual positioning accuracy depend on the system's fix and placemark response.
