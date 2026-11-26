---
name: apk-static-analysis
description: "Static analysis of Android APK/AAB artifacts with the baked mobile toolchain (aapt/aapt2, apktool, jadx, apkid, apkleaks, mobsfscan). Invoke when a task needs to analyze an APK file: manifest review (exported components, debuggable, allowBackup, cleartext, network security config), decompiled Java/Kotlin source review, hardcoded secrets and endpoints, third-party SDK inventory, packing/obfuscation detection, or MASVS-mapped SAST findings."
---
# APK static analysis (aapt, apktool, jadx, apkid, apkleaks, mobsfscan)
Static analysis turns one uploaded APK into: a component/permission inventory, decompiled
source you can audit, extracted secrets and endpoints, and MASVS-mapped findings that flow into
the ARTEX asset graph and findings store with quoted evidence.
## Boundaries (read first)
- Only analyze artifacts you are authorized to test: the operator's own app, an app covered by
  written engagement scope, or an approved lab target. Never analyze, republish or redistribute
  an APK outside the engagement.
- The deliverable is measurement: findings with verbatim quoted evidence (file path + the exact
  string or code excerpt). Never fabricate a finding that the decompiled source does not show.
- Decompiled output stays inside your run directory. Do not upload the source bundle to external
  services; keep everything in the traffic/task store.
## Tools available (baked in this image)
| Tool | Use |
|---|---|
| `aapt2 dump badging FILE.apk` / `aapt dump badging` | package, versionCode/Name, permissions, activities, services, receivers, providers, native ABIs |
| `apktool d -o out/ FILE.apk` | decoded manifest, resources, smali; `apktool b` rebuilds |
| `jadx -d out-src/ FILE.apk` | decompiled Java source (preferred for review over smali) |
| `apkid FILE.apk` | packer/protector/compiler/obfuscator detection (yara rules) |
| `apkleaks -f FILE.apk` | regex-based secret extraction (keys, tokens, URLs) |
| `mobsfscan SRC_DIR` | MobSF semgrep rules over decompiled source, MASVS-mapped findings |
| `jarsigner -verify` / `keytool -printcert -jarfile` | signature scheme and signer certificate chain |
All run as the executor user; no root needed. Build-tools binaries (zipalign, aapt, aapt2) are
x86_64-only: on an arm64 ARTEX image only the Java tools and apksigner (jar) are available.
## Workflow
**Step 1: stage the artifact.** Save or copy the APK into your run directory, e.g. `apk/`. Verify
integrity: `sha256sum apk/*.apk`; record the hash as a fact.
**Step 2: fingerprint without decompiling.**
```bash
aapt2 dump badging apk/target.apk | head -60          # package, permissions, launchable-activity
keytool -printcert -jarfile apk/target.apk            # signer chain, self-signed or CA
apkid apk/target.apk                                  # packer/obfuscation (e.g. DexGuard, Bangcle)
```
Record: application id, versionCode, minSdk/targetSdk, dangerous permissions, signing scheme,
packer verdict. A packer verdict (e.g. "DexGuard") shapes expectations: most high-value strings
will not appear until runtime.
**Step 3: decode and decompile.**
```bash
apktool d -f -o apk/decoded apk/target.apk            # AndroidManifest.xml + resources + smali
jadx --deobf -j 4 -d apk/src apk/target.apk           # readable Java/Kotlin; -j = parallel jobs
```
**Step 4: manifest review (map each check to OWASP MASVS where applicable).** Grep
`apk/decoded/AndroidManifest.xml`:
- `android:debuggable="true"`, `android:allowBackup="true"`, `android:exported="true"` on
  activities/services/receivers/content providers (each exported component = potential entry
  point; list them as facts with the component name);
- `android:usesCleartextTraffic="true"` or a missing `android:networkSecurityConfig`;
- `android:permission` attributes on providers, `grantUriPermissions`,
  `android:name` of custom `Application` classes (look for debug guards);
- services/receivers handling sensitive intents without permission protection.
**Step 5: secrets and endpoints.** `apkleaks -f apk/target.apk -o apk/apkleaks.txt`, then
`rg -i -n "https?://|api\\.?key|secret|token|password|firebase|aws|s3|akid" apk/src --no-heading | head -100`.
Classify each hit: endpoint (register as asset/endpoint in the ARTEX asset graph), embedded
credential (finding with the verbatim string as evidence), or benign. Confirm credentials by
format (Firebase `AIza[0-9A-Za-z_-]{35}`, AWS `AKIA[0-9A-Z]{16}`) — report format matches, not
guesses.
**Step 6: source SAST.** `mobsfscan apk/src --json > apk/mobsfscan.json` and triage the output:
keep MASVS-mapped and high-confidence rules; drop noisy hits you cannot confirm in source. For
every kept finding, quote the source line in the finding evidence.
**Step 7: native libraries (when present).** `unzip -l apk/target.apk | grep 'lib/'`; list ABIs;
`rg -a -n "secret|token|http" apk/decoded/lib --no-heading | head -50` for quick string triage.
For deeper native review use the `rea` skill on the extracted `.so` files.
**Step 8: write back.** Facts: manifest observations, SDK/packer inventory, version. Findings:
one per confirmed weakness (exported sensitive component, cleartext config, embedded secret,
insecure crypto seen in source), each with a verbatim evidence quote. Endpoints discovered in
strings go to the asset graph (see the `mobile-api-testing` skill for testing them). If dynamic
confirmation is possible, hand the next step to the `frida-dynamic-instrumentation` skill.
## Practical notes
- jadx on obfuscated apps produces `a.b.c` class names; `--deobf` renames them, do not cite
  renamed identifiers as evidence without checking the original smali.
- mobsfscan expects source trees, not the APK: point it at the jadx output directory.
- Large APKs: jadx may take minutes; run it once and keep `apk/src` for the whole task.
- Never modify the original APK in place; rebuilds (apktool b) go to a copy if the task needs a
  patched build (see `frida-dynamic-instrumentation` Step 5).
## Completion self-check
- [ ] sha256 of the analyzed artifact recorded as a fact.
- [ ] manifest review checks all run (debuggable/allowBackup/exported/cleartext/NSC) with
      results noted, even if clean.
- [ ] every reported finding carries a verbatim evidence quote with a file path.
- [ ] discovered API endpoints are registered as assets for later testing.
- [ ] no artifact or source bundle left the engagement environment.
