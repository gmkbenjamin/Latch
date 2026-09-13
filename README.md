# Latch

Unlock your Mac from iPhone or iPad. Pair once, then unlock over **Wi‑Fi**, **Bluetooth**, or **Tailscale / VPN**.

## How it works

1. **Latch** on the Mac (menu bar) listens on TCP port **47331** and advertises over Bonjour + Bluetooth LE. The lock icon follows the session even when the menu is closed.
2. Pair from **Latch** on iOS by scanning the QR code or entering the PIN.
3. Unlock / lock from the phone — Face ID / Touch ID / passcode when **Require Face ID / Touch ID** is on.

Traffic uses **Curve25519 ECDH + AES-GCM**. Requests are HMAC-signed with the pairing secret.

## Tailscale / VPN

Bonjour does not cross Tailscale. Latch still works remotely:

1. Install Tailscale (or your VPN) on both Mac and iPhone.
2. On the Mac menu bar panel, note the **Reachable at** address (Tailscale `100.x.x.x` is preferred).
3. On iPhone, under **VPN / Tailscale**, save that IP or MagicDNS name for the selected Mac (port `47331`).
4. Turn **Bluetooth only** off. Unlock / lock as usual.

The pairing QR also embeds the Mac’s preferred address when available.

Allow incoming connections for Latch if macOS asks (firewall).

## Mac options

| Option | What it does |
|--------|----------------|
| **Mac login password** | Stored so Latch can type it at the lock screen. Return in the field saves/updates it. |
| **Keychain / On disk** | **Keychain** keeps the password in the macOS Keychain (`AfterFirstUnlockThisDeviceOnly`). **On disk** writes AES-GCM ciphertext to `~/Library/Application Support/Latch/loginPassword.secret`; the wrapping key stays in Keychain. Switching copies an already-saved password automatically. |
| **Open at login** | Starts Latch after you log in. Requires `/Applications/Latch.app`. |
| **Bluetooth only** | Disable Wi‑Fi unlock; the phone must be nearby. |
| **Listen for unlock requests** | Turn the companion listener off without quitting. |

## iOS options

| Option | What it does |
|--------|----------------|
| **Bluetooth only** | Ignore Wi‑Fi / VPN; unlock only nearby over Bluetooth |
| **Unlock on launch** | Cold-open the app to unlock the selected Mac |
| **Require Face ID / Touch ID** | On by default. Turning it **off** requires Face ID / Touch ID (not passcode). |
| **VPN / Tailscale** | Saved host:port when you’re not on the same LAN |
| **Paired Macs** | Pair multiple Macs; long-press to remove |

## Requirements

- macOS 14+ / iOS 17+
- Same Wi‑Fi, Bluetooth nearby, **or** a VPN/Tailscale path between devices
- Apple Developer signing for your devices
- **Accessibility** permission for Latch on the Mac

## Setup

```bash
cd "Unlock screen"
./build-mac.sh          # Release → /Applications/Latch.app
./build-ios.sh          # install on a connected iPhone
```

Or in Xcode: `xcodegen generate` then open `Latch.xcodeproj`.

1. Set your **Team** on `LatchMac` and `LatchiOS`.
2. Run **Latch** from `/Applications` → save your login password (Keychain or On disk) → enable Accessibility → optionally turn on **Open at login**.
3. Run **Latch** on your phone → allow Local Network / Bluetooth.
4. Scan the QR (or enter the PIN) from the Mac menu bar panel.
5. Lock the Mac (`⌃⌘Q`), then unlock from the phone.

## Caveats

- **Session lock only.** Latch unlocks the lock screen while a user is still logged in (`⌃⌘Q`). It does **not** unlock FileVault, the boot login window, or a Mac that has been fully logged out / restarted.
- **One Mac user session.** Latch runs in the account that launched it and stores **that** user’s password. It is not a Fast User Switching tool. If another account is at the login window, Latch may type the wrong password or fail. Each Mac user who wants unlock needs their own Latch run, password save, Accessibility grant, and phone pairing.
- **Keep Latch running.** The menu bar app must stay open for unlock / lock / status to work. Use **Open at login** (from `/Applications/Latch.app`) so it starts after you log in. It does not run before login / at the FileVault screen.
- **Accessibility required.** macOS must allow Latch to control the computer. Grant it for the binary you actually run (prefer `/Applications/Latch.app`). Debug builds from DerivedData are a different path and need their own toggle.
- **Password storage.** Keychain holds the login password directly. On disk encrypts it with AES-GCM; only the wrapping key is in Keychain. Pairing secrets stay as files under `~/Library/Application Support/Latch/`. Anyone with access to that user account can still unlock; this is a personal convenience tool, not hardened enterprise software.
- **Biometrics on iPhone.** Turning off Face ID / Touch ID requires Face ID / Touch ID first. After that, anyone who can open the Latch app can unlock paired Macs.
- **Bonjour ≠ Tailscale.** Local discovery does not cross Tailscale/VPN. Save the Mac’s Tailscale IP or MagicDNS name on iPhone (port **47331**), turn **Bluetooth only** off, and allow Latch through the Mac firewall if prompted.
- **Same clocks.** Unlock requests are time-checked; large clock skew between Mac and iPhone can cause auth failures.
- **Personal use.** App Store–style distribution would need extra hardening (stronger attestation, etc.). Treat this as a private, signed-for-your-devices project.

## Project layout

| Path | Role |
|------|------|
| `Mac/` | macOS menu bar companion |
| `iOS/` | iPhone / iPad app |
| `Shared/` | Protocol, crypto, network helpers |
| `project.yml` | XcodeGen project definition |
| `build-mac.sh` / `build-ios.sh` | Sign, build, and install |
