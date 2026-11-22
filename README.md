<img width="150" alt="dfggdfgdfdg" src="https://github.com/user-attachments/assets/4b919397-4e25-400f-9b5e-356125befe10" />
<br>

# Onqa (for iOS 26+)

**Minimum requirement:** iOS 26 or later.

Main repository can be found [here](https://github.com/barteqcz/Onqa). This is a port for iOS.

## How to install?

1. Download the .ipa file that is pinned to the releases to your PC
2. Enable Developer Mode in your iPhone/iPad
3. Use [iLoader](https://iloader.app/) to sign the app with your Apple Account and sideload it to your device
4. Go to General -> VPN & Device Management and click on your Apple Account address to trust your account

**Note:** You will have to refresh the trust every 7 days.

## Why it's not on AppStore

Apple requires a Developer Account which is 99$/year to be able to put apps on AppStore.

## Why you shouldn't take the .ipa files from *actions*

The repository includes a manually triggered unit-test workflow, but IPA builds do not run the test suite and are not end-to-end validated on a physical device. Audio playback, lock-screen controls, background location, transmitter switching while travelling, and UI/accessibility behavior still need device testing. Use the IPA attached to a release for stable distribution.
