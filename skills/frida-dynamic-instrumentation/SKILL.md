---
name: frida-dynamic-instrumentation
description: "Dynamic runtime analysis of Android apps with Frida and Objection against a rooted device/emulator reachable over adb, or a repackaged (gadget) build. Invoke when a task needs to instrument an APK at runtime: hooking crypto/storage/network APIs, bypassing SSL pinning or root detection, exploring the app with objection, capturing traffic into the ARTEX recording proxy, or dumping runtime state (activities, preferences, keystores)."
---
# Android dynamic instrumentation (Frida + Objection)
Frida injects a JavaScript runtime into a live process; Objection wraps the most common hooks
behind friendly commands. Together they let a worker observe what an app actually does: keys it
derives, pins it checks, requests it sends — and turn those observations into ARTEX findings
with evidence.
## Boundaries (read first)
- Instrument only apps and devices you are authorized to test (own lab, written engagement
  scope). Dynamic instrumentation of an out-of-scope app or device is out of the question.
- The device/emulator is the engagement owner's lab asset: root is required for frida-server
  injection, or the APK must be repackaged with the frida gadget. Never attempt to root or
  modify a device outside the lab.
- Every Bash call (adb, frida, objection) passes through ARTEX's interception gate; an operator
  may require approval for argv prefixes like `["adb","shell"]`. That is intended: instrumentation
  runs on real devices and is worth gating.
## Environment (baked in this image)
- `adb` (Android debug bridge), `frida`, `frida-ps`, `frida-trace`, `frida-ls-devices`,
  `frida-kill`, `objection` (see `objection --help`), Java + `apksigner`/`zipalign` for
  repackaging, `apktool`/`jadx` for unpacking.
- Baked `frida-server` binaries for android `arm`, `arm64`, `x86_64` at
  `/opt/frida-server-android/`, version-matched to the image's frida CLI.
- Container note: there is no USB passthrough. Connect to devices over the network:
  `adb connect host.docker.internal:5555` (host emulators) or `adb connect <ip>:5555`
  (rooted devices with tcpip mode). Verify with `adb devices`.
## Workflow
**Step 0: connect the device.** `adb devices` must list one device. If empty, ask the operator
for the emulator address via task chat; never guess hosts.
**Step 1: start frida-server on the device.**
```bash
bash /app/scripts/mobile/setup-frida-server.sh    # pushes matching version, starts it
frida-ps -U | head -20                            # processes visible == server is healthy
```
If the script fails (no root, SELinux), report the exact error; do not improvise device changes.
**Step 2: identify the app.** From `frida-ps -Ua` (application view) find the package. Cross-check
with the package name recorded by the `apk-static-analysis` skill. Record the package as a fact.
**Step 3: choose spawn vs attach.**
- Spawn (clean state, hooks installed before app code runs):
  `objection --gadget "com.example.app" explore --startup-command "android sslpinning disable"`
  or plain frida: `frida -U -f com.example.app -l hooks/crypto.js --no-pause`.
- Attach (app already running with a logged-in session):
  `frida -U -n "com.example.app"` / `objection -g "com.example.app" explore`.
Prefer spawn for security-control bypasses (pinning, root detection); prefer attach when you
need an authenticated session.
**Step 4: explore with objection.** Inside `explore`, the useful families:
```text
android hooking list activities / services / broadcast_receivers
android hooking watch class_method Class.method --dump-args --dump-return --dump-backtrace
android hooking watch class com.example.Class
android sslpinning disable        # disables common TrustManager/OkHttp pinners
android root disable              # defeats common root checks (on rooted test devices)
android keystore list             # keystore entries; dump requires key grant
android intent launch_activity <name>   # reach an exported activity from the manifest
android memory dump / android heap evaluate ...
```
For anything objection does not cover, write a small frida script (hook
`javax.crypto.Cipher.doFinal`, `java.security.MessageDigest.digest`, `android.app.SharedPreferences$EditorImpl.putString`,
`okhttp3.Request$Builder.url`) — print arguments and returns, save to file, quote the interesting
lines as evidence.
**Step 5: repackage when no root is available.** Patching needs the frida gadget:
```bash
objection patchapk -s apk/target.apk         # apktool b + gadget injection + zipalign + sign
```
objection downloads the matching gadget on first use (network required). The output
`objection-patched.apk` is signed with a debug key — install with `adb install -r` and connect
via `objection -g com.example.app explore` (gadget listens inside the app). Only patch apps the
engagement permits to modify, and note the patched sha256 in the task.
**Step 6: route device traffic into the ARTEX recording proxy.** With the adb server running
inside this container:
```bash
adb -s <serial> reverse tcp:8788 tcp:8788     # device localhost:8788 -> container proxy port
```
then set the device Wi-Fi proxy to `127.0.0.1:8788` (or use the app's proxy setting), install the
ARTEX CA (fetch from the operator's traffic page and install as a user certificate; Android 7+
apps only trust user certs if the app opts in — combine with `android sslpinning disable`), and
browse the app. Captured exchanges land in the same traffic store as every other ARTEX tool
call, so findings can bind request/response evidence directly.
**Step 7: write back.** Facts: instrumentation path used (server vs gadget), package, versions.
Findings: only weaknesses you actually observed at runtime (pinning bypass succeeded on a
finance app = the pinning is the finding; crypto hooked returns hardcoded key = quote the key
material), each with the hook output verbatim. Register endpoint assets you saw the app call
(see `mobile-api-testing` for testing them). Detach and kill the frida session when the intent
completes; leave the device as you found it.
## Practical notes
- frida-server version must match the frida python bindings exactly (they do here: both baked).
- Root detection bypasses (`android root disable`, MagiskHide) are lab tools: document that you
  used them; the finding is the app's reliance on client-side checks, not the bypass itself.
- objection's `sslpinning disable` covers common patterns only; custom pinners need a targeted
  script. Check the `rea` skill for static confirmation of the pinner class before hooking.
- SELinux enforcing devices may block `/data/local/tmp` execution; report the gap instead of
  weakening device policy.
## Completion self-check
- [ ] device identity and ABI recorded; frida-server version matches the CLI.
- [ ] every hook result cited in a finding is pasted verbatim from the tool output.
- [ ] captured traffic went through the ARTEX proxy (bound to the finding) whenever network
      behavior is claimed.
- [ ] no patched/unauthorized build was installed on any device outside the lab.
- [ ] sessions closed; no leftover frida-server processes on the device without the operator's
      knowledge.
