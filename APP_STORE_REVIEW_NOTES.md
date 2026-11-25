# App Store review notes

## Background location

Onqa uses location in GPS mode to find nearby radio stations and select the appropriate transmitter as the listener travels. Location updates continue in the background only while audio playback is active; when playback stops or GPS mode is disabled, background location tracking is not needed. This behavior supports uninterrupted radio listening while driving through different transmitter coverage areas. The app uses `CLLocationManager` with a 100 m desired accuracy (not navigation-grade accuracy) and a 1 km distance filter. Before a fix can trigger transmitter recalculation, it must be no more than 30 seconds old and its horizontal accuracy must be within 10% of the smallest nearby transmitter coverage radius, capped at 500 m (half the movement threshold). This prevents stale or very imprecise fixes from causing unnecessary station switches while remaining appropriate for the catalog's broad transmitter coverage areas.

## Media transport security

The app streams radio audio from broadcaster-provided endpoints. Some stream URLs may use HTTP, which is why `NSAllowsArbitraryLoadsForMedia` is enabled specifically for media loads. The exception is not intended to relax App Transport Security for the app's general catalog or API traffic.

## Release verification

The CI workflow runs unit tests, but it does not exercise real audio playback, background execution, transmitter switching, lock-screen controls, or the full UI on physical hardware. Before submitting a release, verify those flows on a supported iPhone, including location permission denial/recovery and Dynamic Type / VoiceOver behavior.


## Minimum operating system

This release requires iOS 26 or later. It uses MapKit reverse-geocoding requests and Core Location (`CLLocationManager`) updates with an explicit When In Use service session. A background activity session is held during active playback so the app can continue selecting the appropriate radio transmitter while driving.
