# Henge on an M4 iPad Pro

What this branch changes, and the settings that suit an M4 iPad Pro.

## The CPU the Mac is told it has

Henge's virtual CPU has been an M1: its identity (MIDR) and its features (ID registers) are M1's, because
every device Henge supports, A14 and M1 included, has those features, and the translator copies most
instructions as they are, so the host chip runs them.

- **BF16 and I8MM, when the chip runs them.** A15, M2 and later run two more sets of vector instructions:
  BF16 (bfloat16 dot products and matrix multiplies, BFCVT) and I8MM (8-bit integer matrix multiplies, USDOT).
  They are plain data processing, so the translator copies them like any other vector instruction. The Mac is
  now offered them when the device's own CPU reports them (`hw.optional.arm.FEAT_BF16`, `FEAT_I8MM`), so on an
  M4 iPad macOS's math libraries can use them. On an A14 or M1 device nothing changes.
  `HV_CPU_FEATURES=m1` keeps M1's features exactly, for a Mac that must also start on such a device.
- **M4's identity, if you ask for it.** `HV_MIDR=m4` tells macOS its CPU is an Apple M4 (MIDR `0x611f0520`,
  part `0x052` of T8132 "Donan" in XNU's `proc_reg.h`), so About This Mac reads M4. It is experimental: the
  features stay those above (no SME), and macOS may pick code for a chip by its name alone. Remove the line if
  macOS misbehaves. Any other Apple MIDR (`0x61......`) is accepted as a value; anything else keeps M1's.
- **A saved Mac keeps its CPU.** Instant Resume's identity now includes the CPU (`midr ... bf16 i8mm`), so a Mac
  saved with BF16 offered starts afresh, rather than waking, where it would not be.

Both settings are read from `henge-env.txt` (Files › Henge, one `KEY=VALUE` a line) before each Mac starts,
and the log shows the choice: `hengevm: cpu midr 0x611f0220 bf16 i8mm`. Inside the Mac:

```bash
sysctl hw.optional.arm.FEAT_BF16 hw.optional.arm.FEAT_I8MM machdep.cpu.brand_string
```

## CPUs: the performance cores

A new Mac now gets as many CPUs as the device has performance cores (`hw.perflevel0.physicalcpu`, 2 to 6):
4 on a 1 or 2 TB M4 iPad Pro, 3 on a 256 or 512 GB one. iOS keeps the Mac's CPU threads on those cores;
past them, some run on efficiency cores and hold up the rest each time the Mac's CPUs wait for one another.
An existing CPU setting is kept: lower it on the Home screen if it is above that number.

## Disk size

A new Mac's disk can be 64, 128, 256 or 512 GB (Install › New Mac › Disk); it was always 64 GB before. The disk
is a sparse file, so the device's storage goes only to what macOS writes, and the note under the choice warns
when a size comes near the free space. A Mac that exists keeps its size.

## Tested

13" iPad Pro M4, 1 TB (iPad16,5: 4 performance + 6 efficiency cores, 16 GB), iPadOS 27.0 beta (24A5430a),
macOS 27.2, on 0.3 with the same ID-register change ("Henge M4 test", 2026-11-14):

- a fresh macOS 27.2 install, first boot and setup: no panics;
- a Mac installed before, started cold: `FEAT_BF16: 1`, `FEAT_I8MM: 1`, `Apple M1 (Virtual)`; BFDOT, BFMMLA,
  BFMLALB/T, BFCVT, SMMLA, UMMLA, USMMLA and USDOT all give exact results (9 checks); SMMLA takes 1.61 ns per
  2×8×2 block against 21.43 ns in plain C; no crash reports since boot.

## Settings for an M4 iPad Pro

| Setting | Where | M4 iPad Pro |
|---|---|---|
| CPUs | Home | 4 (1 or 2 TB), 3 (256 or 512 GB) |
| Memory | Install, Mac settings | 8 GB on a 16 GB iPad (1 or 2 TB), 6 GB at most on an 8 GB one |
| Code cache | Settings › Performance | 1.5 GB |
| Screen | Mac settings | Performance (Retina costs a lot of emulated GPU work) |
| Refresh | Settings › Performance | 60 Hz, or 30 Hz in a session's Details |
| Lighter macOS | a session's Details | on |
| macOS | Install | Sequoia 15.6.1 runs best; macOS 27 is the slowest |

`HV_QOS=ui` in `henge-env.txt` runs the Mac's CPUs at the highest iOS priority (testing): try it, and remove
it if the screen stutters.
