# Henge on an M4 iPad Pro (0.4.0 Supercharged Build)

What this branch (`m4-ipad`) adds on top of `Leviidev/Henge`, tuned specifically for a 13" M4 iPad Pro (`iPad16,5`, 1–2 TB / 16 GB RAM, 4 P-cores + 6 E-cores, iPadOS 27).

## Integrated Engine & Platform Upgrades

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
   - Enabled on the Home screen (`Mac Apps…`) by default: runs arm64 Mac command-line programs sequentially with arguments, working folder, `env.txt`, and `stdin` directly on the M4 hardware MMU at native speed, plus experimental windowed AppKit/Qt/SDL apps.
7. **M4 CPU Features (`BF16` & `I8MM`) and Host Identity**
   - Offers `FEAT_BF16` and `FEAT_I8MM` vector instructions natively when supported by the host chip (`HV_CPU_FEATURES=m1` disables; `HV_MIDR=m4` reports Apple M4 MIDR `0x611f0520`).

## Recommended Settings for 13" M4 iPad Pro (1–2 TB, 16 GB)

| Setting | Where | Recommended Value | Why |
|---|---|---|---|
| **macOS Version** | Install | **Sequoia 15.6.1** | Fastest desktop & Safari; avoid macOS 27's heavy shader/daemon overhead |
| **CPUs** | Home / Mac settings | **3** (default on 4-P-core M4) | Leaves 1 dedicated M4 P-core for Metal GPU replay & UIKit so vCPUs never spill onto E-cores |
| **Memory** | Install / Mac settings | **10 GB** (default on 16 GB iPad; **3 GB** on 8 GB iPad) | Zero guest swap while leaving >5 GB for iPadOS + 2 GB JIT cache |
| **Code cache** | Settings › Performance | **2 GB** (default on 16 GB iPad) | Holds ~7M translated blocks across 8 ring segments |
| **High-priority vCPUs** | Settings › Performance | **On** (`HV_QOS=ui`) | Prevents XNU battery coalition demotion to efficiency cores |
| **Grouped memory accesses** | Settings › Performance | **On** (`HV_GROUPS=1`) | +11% sustained FPS on iPad |
| **Screen** | Mac settings | **Performance** (`1600×1200`) or **Fit** (`1920×1440`) at **60 Hz** | Keeps emulated GPU load low while filling the 4:3 iPad screen |
| **Lighter macOS** | Session › Details | **On** | Disables background indexing and motion overhead inside macOS |
| **Keep shared dyld TLB / Direct user memory (NCE)** | Settings › Performance | **Try On** after Setup Assistant completes | Experimental hardware-MMU / shared-cache acceleration (`PR #157`) |
