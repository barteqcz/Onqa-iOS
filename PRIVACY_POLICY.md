# Privacy Policy for Onqa (iOS)

Onqa ("the app") is a local radio discovery app. This policy describes how the iOS version handles your information. It mirrors the policy of the [Android app](https://github.com/barteqcz/Onqa/blob/main/PRIVACY_POLICY.md).

## Information the app uses

- **Location (While Using the App).** Your approximate location is used on-device to find radio transmitters near you and to sort stations by distance. While the app is open it follows your location, updating when you move about 1 km. While a station is playing, the app also keeps following your location in the background so it can switch to a transmitter closer to you; iOS shows its location indicator when this happens. Background location is never used when no station is playing, and it requires only the "While Using the App" permission. If you choose a location manually on the map, the app does not use your device location at all.
- **Local preferences.** Favorite stations, theme, accent color and other settings are stored locally on your device (UserDefaults) and are removed when you uninstall the app.

The app does not collect personal identifiers, contact information or browsing history, and it has no analytics or advertising.

## How location is used

Location is used only to query the station catalog stored on your device. It is **not** sent to the Onqa service. We do not sell, trade or rent location data.

## Network requests

- The station catalog is downloaded over HTTPS from `onqa.barteq.cz`. The request does not include your location.
- Station logos and audio streams are loaded directly from broadcasters. These third parties may receive your IP address as part of normal streaming.
- Reverse geocoding (turning coordinates into a city name) is performed by Apple's location services.

## Your choices

You can deny or revoke location access in iOS Settings → Privacy & Security → Location Services and still use the app with a manually chosen location. Deleting the app removes all locally stored data.
