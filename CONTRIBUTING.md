# Contributing

Airplayer aims to stay a small, responsive macOS mirroring receiver. Prefer focused changes that preserve picture quality, frame ownership, synchronized presentation, and predictable connection/exit behavior.

## Report a bug

Include the Airplayer version, Mac model, macOS version, sender model/OS, network setup, and reproduction steps. Describe whether the problem affects video, audio, discovery, or reconnecting. Redact personal information from receiver logs.

## Send a change

1. Fork the repository and create a branch.
2. Make the smallest coherent change; explain the user-visible behavior.
3. Run the relevant tests in [Development](docs/DEVELOPMENT.md). For rendering or lifecycle changes, run the UI suite and test a real device where possible.
4. Open a pull request with the change, validation, and any known limitations.

Keep `Vendor/UxPlay` unchanged. Apply integration changes in the build script and document upstream version updates in `THIRD_PARTY.md`. Do not commit build products, logs, device data, or signing credentials.

Contributions are provided under this project's GPL-3.0-or-later license.
