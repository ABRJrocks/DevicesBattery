# DevicesBattery

Menu bar app showing battery % of your Mac, AirPods / Bluetooth accessories, and
iPhone/iPad — all wirelessly. Menu bar shows the lowest battery; click for the full list.

## Install

```bash
./install.sh
```

Builds, installs to `/Applications/DevicesBattery.app`, and launches. To start at
login: System Settings → General → Login Items → add DevicesBattery.

## How it reads each device

| Device | Method | Setup needed |
|---|---|---|
| Mac | `pmset` | none |
| AirPods, BT keyboards/mice (connected to Mac) | `system_profiler SPBluetoothDataType` | none |
| AirPods connected to your iPhone instead | BLE proximity-pairing broadcasts (plaintext) | allow Bluetooth on first launch |
| iPhone / iPad over Wi-Fi | `libimobiledevice` (network lockdown) | one-time, below |

## One-time iPhone setup

1. `brew install libimobiledevice` (already done if you ran this session's setup)
2. Plug iPhone into the Mac via USB once → tap **Trust** on the phone
3. Finder → select the iPhone → General tab → check **"Show this iPhone when on Wi-Fi"** → Apply
4. Unplug. From then on battery is read over Wi-Fi (same network).

Caveats: a deeply asleep or Low-Power-Mode iPhone may not answer until it wakes;
the app just shows it again on the next poll (every 60s).

## AirPods-on-iPhone caveats

Shown as "AirPods (nearby)" — best-effort, appears only when no AirPods are
connected to the Mac. Identity is "nearest broadcasting AirPods" (RSSI-gated),
L/R can occasionally be swapped, and broadcasts stop a while after the case lid
closes. Format is Apple-private (same parsing as the open-source
[AirBattery](https://github.com/lihaoyun6/AirBattery) app) and could change in
a future AirPods firmware.
