# Eternal Summer ☀️

> **Zero-freeze, ultra-responsive Linux GUI under extreme system load.**  
> Prioritizes the desktop compositor, shell, audio, and user input above all else—even during 100% CPU spikes, memory exhaustion, and heavy disk I/O.

---

## 🎯 The Problem

By default, Linux distributes system resources relatively evenly between user applications and the desktop environment. Under intense resource usage (e.g., compiling large codebases, AI model training, heavy 3D rendering, runaway browser tabs, or bulk disk writes), modern desktop Linux systems frequently suffer from:

1. **Memory Exhaustion & Page Thrashing**: When RAM fills up and swap is small or slow, the kernel direct-reclaims clean executable pages belonging to the GUI (KWin, Plasma, Qt, Wayland, GPU drivers). Every subsequent mouse move or window redraw forces a synchronous disk read, freezing the desktop.
2. **CPU Starvation**: Heavy multithreaded workloads saturate all CPU cores at standard nice levels (`0`), starving the compositor and window manager of rendering slices.
3. **Dirty Page Bursts**: Default kernel dirty writeback ratios allow gigabytes of unwritten data to accumulate before forcing synchronous writeback, completely stalling interactive disk I/O.
4. **Delayed OOM Killer**: The default in-kernel Out-of-Memory (OOM) killer only acts after the system has already been completely unresponsive and thrashing for minutes.

**Eternal Summer** eliminates these bottlenecks by enforcing hardware-level and cgroup v2 guarantees that grant the GUI absolute priority.

---

## 🚀 Quick Start

### Installation

Clone or open the repository, then run the installer with root privileges:

```bash
cd ~/Documents/eternal_summer
sudo ./eternal_summer.sh
```

The script will automatically detect your user environment, install prerequisites, and configure the entire optimization stack.

### Check Current Status

Inspect live priorities, memory reservations, and daemon health anytime (no root required):

```bash
./eternal_summer.sh status
```

### Prioritizing Custom Applications

You can easily elevate any application (terminal, code editor, game, browser, media player) so it receives real-time CPU priority, high I/O scheduling, and immunity from memory eviction:

```bash
# Add an application (defaults to Nice -10, OOM Score -500)
./eternal_summer.sh add konsole

# Add with custom nice level and OOM score
./eternal_summer.sh add steam -12 -600
./eternal_summer.sh add obs -15 -800

# View all prioritized core and custom applications
./eternal_summer.sh list

# Remove an application from the priority list
./eternal_summer.sh remove konsole
```

> [!TIP]
> The background `gui-priority-guard` daemon continuously watches for prioritized applications. Whenever an application on your list launches, the daemon automatically elevates its nice level, assigns high I/O priority, and applies OOM shielding.

---

### Uninstallation

To cleanly revert all system and user configurations back to distribution defaults:

```bash
sudo ./eternal_summer.sh uninstall
```

---

## 🛡️ Architecture & Components

```
┌─────────────────────────────────────────────────────────────────┐
│                          User Session                           │
│                                                                 │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │  session.slice (CPUWeight=10000, MemoryLow=1.5G)          │  │
│  │  ├─ kwin_wayland / Xwayland (Nice -15, OOMScoreAdj -500)  │  │
│  │  ├─ plasmashell (Nice -10, OOMScoreAdj -500)              │  │
│  │  └─ pipewire / wireplumber (Real-Time Audio)             │  │
│  └───────────────────────────────────────────────────────────┘  │
│                                ▲                                │
│       100x CPU Priority Advantage over Applications             │
│                                ▼                                │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │  app.slice (CPUWeight=100)                                │  │
│  │  └─ Browsers, IDEs, Terminals, User Apps                  │  │
│  └───────────────────────────────────────────────────────────┘  │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │  background.slice (CPUWeight=1)                           │  │
│  │  └─ Baloo file indexer, background maintenance           │  │
│  └───────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
                                ▲
    ┌───────────────────────────┴───────────────────────────┐
    │                 System-Wide Guardians                 │
    │                                                       │
    │  • ZRAM Engine: In-RAM compressed swap pool (zstd)   │
    │  • EarlyOOM: Shields GUI, terminates runaway tasks    │
    │  • GUI Priority Guard: Continuous process supervisor │
    │  • Sysctl Tuning: Throttled dirty I/O writeback       │
    └───────────────────────────────────────────────────────┘
```

### 1. ZRAM In-Memory Compressed Swap
* Creates an ultra-fast compressed swap device (`/dev/zram0`) sized to 100% of RAM using the modern `zstd` compression algorithm.
* Assigned the highest possible swap priority (`32767`), ensuring fast memory compression takes precedence over slow disk swap.
* Completely eliminates direct-reclaim thrashing and protects GUI executable binaries from disk eviction.

### 2. EarlyOOM Protection Daemon
* Continuously checks memory and swap headroom.
* Triggers when available RAM falls below 4% and free swap below 10%.
* **Protected**: `kwin_wayland`, `plasmashell`, `Xwayland`, `pipewire`, `wireplumber`, `sddm`, `plasmalogin`, and system services.
* **Prioritized for termination**: Runaway memory hogs (`cc1plus`, `rustc`, `python`, `node`, `chrome`, `firefox`).
* Prevents multi-minute machine lockups before they can occur.

### 3. Kernel Sysctl Desktop Responsiveness Tuning
* **Dirty I/O Throttling**: Caps dirty bytes to 256MB (`vm.dirty_bytes`) and triggers background flushing at 64MB (`vm.dirty_background_bytes`), eliminating multi-gigabyte disk write stalls.
* **ZRAM Memory Affinity**: Sets `vm.swappiness = 180` and `vm.page-cluster = 0` (reads 1 page at a time with near-zero latency).
* **Metadata Protection**: Sets `vm.vfs_cache_pressure = 50` to keep file and directory structures cached in RAM.
* **Low Latency CPU Slices**: Sets `kernel.sched_cfs_bandwidth_slice_us = 3000` to prevent single compute tasks from monopolizing CPU cores uninterrupted.

### 4. Cgroups v2 Resource Slicing
* Configures systemd controller delegation (`cpu memory io pids`) for user sessions.
* **`session.slice`**: Granted `CPUWeight=10000`, `MemoryLow=1500M`, and `MemoryMin=512M`.
* **`app.slice`**: Assigned `CPUWeight=100`.
* **`background.slice`**: Assigned `CPUWeight=1` (suppresses background indexers like Baloo during user activity).
* Configurations are applied both system-wide (`/etc/systemd/user/`) and synced to the active user's `~/.config/systemd/user/`.

### 5. GUI Priority Guard (`gui-priority-guard.service`)
* A lightweight system daemon that runs in the background.
* Enforces `nice -15`/`-10`, high I/O priority, and `OOMScoreAdjust=-500` on compositor and shell processes.
* Automatically demotes heavy batch/compile workloads (`gcc`, `clang`, `rustc`, `cargo`, `ninja`, `make`, `ffmpeg`, `blender`) to nice `+15` and idle I/O (`ionice -c 3`), ensuring builds never cause UI stutter.

### 6. PAM Real-Time & Nice Limits
* Updates `/etc/security/limits.d/99-gui-priority.conf` allowing non-root desktop users to utilize negative nice values down to `-20`, real-time priorities up to `95`, and unlimited locked memory (`memlock unlimited`).

### 7. Udev I/O Schedulers
* Sets optimal I/O schedulers across storage types (`none` for NVMe, `mq-deadline` for SATA SSDs, `bfq` for HDDs) via `/etc/udev/rules.d/60-gui-ioschedulers.rules`.

---

## 📂 Project Structure

```
eternal_summer/
├── eternal_summer.sh          # Standalone installer, uninstaller, and status tool
└── README.md                  # Comprehensive architectural and usage documentation
```

---

## 💻 Compatibility

* **Tested On**: Ubuntu 24.04 LTS (Noble Numbat), KDE neon (User Edition, Plasma 6 / Wayland)
* **Compatible With**: Debian 12+, Ubuntu 22.04+, Pop!_OS, and Debian-based desktop distributions running systemd and cgroups v2.
