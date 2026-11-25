# Henge on an M4 iPad Pro (`0.5.1`)

What this branch (`m4-ipad`) adds on top of `Leviidev/Henge`, tuned specifically for a 13" M4 iPad Pro (`iPad16,5`, 1–2 TB / 16 GB RAM, 4 P-cores + 6 E-cores, iPadOS 27).

## 1. Integrated Engine & Speed Upgrades

1. **16 GB Guest RAM Address-Space Fix (`PR #121` / `PR #211`)**
   - Releases the 60 GB high virtual-address reservation (`henge_ios_hold_high`) before sizing or booting a virtual Mac, expanding contiguous guest RAM mapping from ~2.5 GB to ~16.9 GB so 16 GB iPads can allocate **8–10 GB guest RAM** outside the app footprint.
2. **8-Segment JIT Code-Cache Ring & Inlined Hot Sysregs (`PR #186`)**
   - Splits the JIT region into an 8-segment ring (`HV_JIT_SEGMENTS=8`) with O(segment) eviction and a single-barrier `icache` clean (eliminating full-cache flushes every 60–90 s and 540 ms `ic ivau` storms), plus zero-trap inlined EL1/EL0 system registers (`SCTLR`, `TTBR1`, `MIDR`, `CNTKCTL`, `UAO`, etc.) and `tr_mu` yield spin.
3. **Cross-vCPU TLB Stall Reduction & iPad GPU Pacing (`PR #218` + `Issue #164`)**
   - Enables `HV_SYNC_WAIT=1`, `HV_RANGE_DROP=256`, and `ijc_va`-aware remote drops by default (cutting cross-CPU TLB acknowledgement waits from up to 76% of a core down to 4–9%), alongside `HV_GROUPS=1` (+11% measured FPS on iPad) and `HV_PVG_VBLANK=1` (cutting display freezes under load from 5/6 to 1/6).
4. **Hardware-MMU Direct User Memory ("NCE") & Shared-Cache TLB Retention (`PR #157`)**
   - Includes `HV_SHARED_KEEP=1` (retains verified shared `dyld` L2 mappings across process switches, where 95.5% of user TLB refills occur) and `HV_EL0_WINDOW=33` (`core/window.c`: maps 8 GB per vCPU of guest EL0 userland straight onto the M4 hardware MMU via `vm_remap`), exposed as one-tap switches in **Settings › Performance**.
5. **Background Keep-Alive & Dynamic Balloon Relief (`PR #214`)**
   - Silent mixed audio keeps iPadOS from suspending and jetsam-killing Henge when switching apps or locking the screen (`KeepAlive.swift`), paired with automatic `virtio-balloon` memory relief under iOS memory pressure.
6. **Native-Speed Mac Apps Without macOS (`tl/` + `PR #219`)**
   - Off by default since 0.5.1 (Settings › Mac Apps): runs arm64 Mac command-line programs with arguments, working folder, `env.txt`, and `stdin` directly on the hardware MMU, plus experimental windowed AppKit/Qt/SDL apps. Running one keeps the address room a Mac's memory needs, so a Mac (or the installer) cannot start in the same launch: Henge says so and asks to be reopened.
7. **M4 CPU Features (`BF16` & `I8MM`) and Host Identity**
   - Offers `FEAT_BF16` and `FEAT_I8MM` vector instructions natively when supported by the host chip (`HV_CPU_FEATURES=m1` disables; `HV_MIDR=m4` reports Apple M4 MIDR `0x611f0520`).

## 2. iPad hardware in the Mac

The Mac's xHCI 1.0 root hub has seven ports (`HV_XHCI_SLOTS=12`). What each one is, and what it is not:

- **Port 1 (`HV_XDEV_KBD`)**: Apple Virtual USB HID Keyboard + Mac system shortcut pass-through (`⌘Space`, `⌘Tab`, `⌘Q`, `⌘W`, `⌘H`, `.defersSystemGestures`).
- **Port 2 (`HV_XDEV_TP`)**: Apple Magic Trackpad 2 native multi-touch gestures (two-finger inertial scroll, three-finger Mission Control / Spaces).
- **Port 3 (`HV_XDEV_CAMERA`) + `virtio-snd` Capture (`PR #100`)**: Live Front & Back iPad Camera (`UVC` MJPEG up to 1080p with horizontal flip & live switching) + `48 kHz` physical Microphone input.
- **Port 4 (`HV_XDEV_MOUSE`) + `HengeAudio` + Logitech BLE HID++ (`PR #191`)**: 5-button wheel mouse, Logitech BLE HID++ direct pointer channel, and automatic Bluetooth/AirPods audio route recovery.
- **Port 5 (`HV_XDEV_TABLET`) (`PR #90` + Auto-Pencil)**: Sub-pixel absolute USB tablet digitizer with palm rejection — touching the Mac screen with **Apple Pencil** automatically engages direct sub-pixel pen input even while finger gestures stay in Magic Trackpad mode.
- **Port 6 (`HV_XDEV_BT`) (`PR #84` + `BluetoothBridge.swift`)**: an emulated Broadcom `BCM20702A0` USB Bluetooth controller (`bt-transport-override=10`). With **Show nearby Bluetooth LE devices in macOS** on (off by default), Henge scans with `CBCentralManager` while macOS scans and passes what it hears as advertising reports, so macOS can list nearby BLE devices. macOS cannot connect to them: there is no data path behind the controller, a connection request fails as a real controller's does (0x3E), and classic Bluetooth is absent. Pair keyboards, mice and headphones with iPadOS; Henge forwards their input and sound. `HV_NO_BT=1` leaves the port empty.
- **External folder in the shared folder (`share.c` + `Sharing.swift`)**: a USB-C drive's folder (or any Files folder) picked in **Details › Sharing** appears as `~/Henge/External` on the Mac, through the same network share as the Shared folder. It is not a disk mounted in macOS, and files are read over that share. Not yet tried on a device.
- **Live iPad Battery, Charging & Wi-Fi Menu Bar (`HostStatusBridge.swift` + `henge-agent.m`)**: Streams real-time iPad battery percentage, charging status (`⚡`), thermal state, Wi-Fi/Ethernet IPv4 address, and external USB drive status to a native macOS menu bar item (`iPad 94% ⚡`).
- **Port 7 (`HV_XDEV_PAD`) + `GamepadBridge.swift`**: a USB game controller the Mac can see, a Sony DualShock 4 (`054C:09CC`), plugged in while a controller (DualSense, DualShock, Xbox, MFi) is connected to the iPad and pulled when it goes; its buttons, sticks and triggers go over at 120 Hz. `henge.gamepad.mode = pointer` gives the old behaviour instead (the controller moves the pointer and presses keys), and `HV_NO_GAMEPAD=1` leaves the port empty. New in 0.5.1 and not yet tried against macOS.

## 3. Recommended Settings for 13" M4 iPad Pro (1–2 TB, 16 GB)

| Setting | Where | Recommended Value | Why |
|---|---|---|---|
| **macOS Version** | Install | **Sequoia 15.6.1** | Fastest desktop & Safari; avoid macOS 27's heavy shader/daemon overhead |
| **CPUs** | Home / Mac settings | **3 or 4** on a 4-P-core M4 | Measured on a 1 TB M4 during boot and login: 6 CPUs did no more work per second than 4, and waited on each other more |
| **Memory** | Install / Mac settings | **10 GB** by default on a 16 GB iPad (**3 GB** on 8 GB); try **8 GB** | Measured on a 1 TB M4 (15.4 GB): with a 10 GB Mac iPadOS compressed 6–7.7 GB of Henge's memory during first boot, and 6.6–8.8 GB with 12 GB |
| **Code cache** | Settings › Performance | **1.5 GB** (the default on a 16 GB iPad, and the most there is) | The engine keeps a 1.5 GB hole where translated code may run. 0.5.0 offered 2 GB without enlarging it: on a 1 TB M4 the region landed where code cannot execute and JIT failed at every launch (device log: "claiming 2048 MiB", "MAP_JIT cannot execute here"). 0.5.1 removes the choice |
| **High-priority vCPUs** | Settings › Performance | **On** (`HV_QOS=ui`) | Prevents XNU battery coalition demotion to efficiency cores |
| **Grouped memory accesses** | Settings › Performance | **On** (`HV_GROUPS=1`) | +11% sustained FPS on iPad |
| **Screen** | Mac settings | **Performance** (`1600×1200`) or **Fit** (`1920×1440`) at **60 Hz** | Keeps emulated GPU load low while filling the 4:3 iPad screen |
| **Lighter macOS** | Session › Details | **On** | Disables background indexing and motion overhead inside macOS |
| **Keep shared dyld TLB / Direct user memory (NCE)** | `Documents/henge-env.txt` only | **Off** | Experimental (`PR #157`). 0.5.0 offered them as switches; with Direct user memory on, a 1 TB M4 gave the Mac 5,632 MB of the 11,264 it asked for and then ran without the feature. 0.5.1 removes the switches |
