# Mobile security testing (APK)

ARTEX can plan and execute security tests against Android applications (APK). The mobile
capability is additive: the same engine loop, dual graphs, interception gate and traffic store
drive it, with a baked Android toolchain and three skills that teach the agents how to use it.

## What is included

**Toolchain baked into the image** (pinned releases, checksum-verified in the Dockerfile):

| Tool | Purpose |
|---|---|
| `adb` | device/emulator control (network adb — the container has no USB passthrough) |
| `jadx` | dex → Java/Kotlin decompiler (static review) |
| `apktool` | APK resource/manifest decode and rebuild (smali) |
| `aapt` / `aapt2` | APK badging: package, permissions, components (build-tools r34) |
| `apksigner` / `zipalign` | signing and alignment for patched/repackaged APKs |
| `frida`, `frida-ps`, `frida-trace`, `frida-kill` | runtime instrumentation CLI (frida-tools) |
| `objection` | high-level Frida wrapper: explore, ssl pinning, root checks, intents |
| `frida-server` (android `arm`, `arm64`, `x86_64`) | device-side agent, version-matched to the CLI |
| `androguard` | APK/AXML/DEX analysis library and CLI |
| `apkid` | packer/obfuscator/compiler detection (yara) |
| `apkleaks` | secret extraction from APK artifacts |
| `mobsfscan` | MobSF semgrep rules over decompiled source (MASVS-mapped) |

`frida-server` binaries live under `/opt/frida-server-android/`; their version always matches
the `frida` CLI in the same image, so pushing one to the device keeps client and server in sync.
`scripts/mobile/setup-frida-server.sh` does the push/start automatically.

**Skills** (prompt/playbook material under `skills/`):

- `apk-static-analysis` — manifest review, decompilation, secrets/endpoints, packing detection,
  MASVS SAST from a single APK.
- `frida-dynamic-instrumentation` — runtime hooking with Frida/Objection, SSL-pinning and root
  checks, gadget repackaging, traffic capture into the ARTEX proxy.
- `mobile-api-testing` — turns app-derived endpoints into asset-graph entries and tests them
  with the standard web toolchain (auth bypasses, IDOR, hidden parameters), keeping findings
  bound to recorded traffic.

## Connecting a device or emulator

The ARTEX container has no USB passthrough; adb works over TCP only.

```bash
# Host emulator (Docker Desktop / host-gateway):
adb connect host.docker.internal:5555
# Rooted physical device with tcpip mode enabled on the host:
adb connect 192.168.1.50:5555

adb devices                      # must list exactly one device
bash /app/scripts/mobile/setup-frida-server.sh   # push + start frida-server
frida-ps -Ua                     # list installed apps through frida
```

Device prerequisites for `frida-server` injection: root (`adb root` on emulator images, `su` via
Magisk on rooted devices). Without root, the app must be repackaged with the frida gadget —
`objection patchapk -s target.apk` (needs network for the gadget download on first use) produces
a signed, gadget-enabled build; the skill documents the manual injection path for air-gapped
labs.

## Routing device traffic into the ARTEX traffic store

With the adb server running inside the ARTEX container, the recording proxy on `:8788` can be
reached from the device without changing any bind address:

```bash
adb -s <serial> reverse tcp:8788 tcp:8788     # device localhost:8788 -> container proxy
```

Set the device's Wi-Fi proxy to `127.0.0.1:8788`, install the ARTEX CA as a user certificate
(Android 7+ apps only trust user certs when the app opts in — combine with the skill's
`android sslpinning disable` or patch the app's network security config), and browse the app.
Captured exchanges land in the same traffic store as every other ARTEX tool call, so findings
can bind request/response evidence directly, and the noise governor paces the proxied requests.

## Running a mobile task

Create a task with a goal like one of these; the planner picks the relevant skill(s):

- "Analyze `uploads/app-release.apk` statically: manifest, secrets, endpoints, MASVS findings."
- "Bypass SSL pinning of `com.example.app` on the lab emulator and capture the app's API
  traffic into the traffic store."
- "Test the API endpoints recovered from the app for broken object-level authorization using
  the two lab accounts."

Suggested system settings: approve argv-prefix rules such as `["adb","shell"]` or
`["frida","-U"]` in the interception gate for faster autonomous runs; keep the task budget
defaults (a full static pass plus dynamic runs usually fits well under 50k tokens per worker).

## Scope, legality and limits

- Dynamic instrumentation and repackaging are for authorized lab targets only; the skills state
  the boundaries and agents are expected to respect the scope gate.
- `zipalign`/`aapt`/`aapt2` are x86_64 binaries; on arm64 ARTEX images only the Java tools and
  `apksigner` (jar) are available, so APK repackaging is best done on amd64 deployments.
- `mobsfscan` (and its semgrep engine) is the largest addition to the image; if image size
  matters, it can be dropped from the venv without affecting the other tools.
- iOS (IPA) analysis is not included; the `rea` skill still handles generic static analysis of
  iOS packages when configured on the host.
