# syntax=docker/dockerfile:1
#
# Multi-stage build: `docker compose up -d --build` (or `docker build .`) produces
# the complete image from source. No prebuilt binary in the build context is needed,
# so a fresh `git clone` builds — dist/ is git-ignored and is no longer required.
#
#   frontend (web) -> Go binary with embedded UI (build) -> runtime image
#
# The Go binary is produced by build.sh with the same flags the release workflow's
# binaries job uses, so the image binary and the published release binary come from
# one source.

# ---------------------------------------------------------------- frontend ---
# Pinned to the Node 22 line the CI/release workflows use. On the build platform
# only; the frontend static export is architecture-independent.
FROM --platform=$BUILDPLATFORM node:22-bookworm-slim@sha256:e9f565d32859f0cbfb52125eafe8be39390f24dac302dc3cdf566e8ba3ab21ee AS web
ENV NEXT_TELEMETRY_DISABLED=1
WORKDIR /src/web
COPY web/package.json web/package-lock.json ./
RUN npm ci --ignore-scripts
COPY web/ ./
RUN npm run build:static

# ------------------------------------------------------------- Go binary ---
# Pinned to the exact Go release go.mod requires. The official image sets
# GOTOOLCHAIN=local, so a floating 1.26 tag that lags go.mod fails the build;
# bump this together with the go line in go.mod. The binary is CGO-free, so this
# stage runs on the build platform and cross-compiles to $TARGETARCH without QEMU.
FROM --platform=$BUILDPLATFORM golang:1.26.11-bookworm@sha256:dc40a13b61304647ed7e5d581d246b86413dfc29d63c6d018310feb93cd98fc0 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
# Reuse the frontend built above; build.sh skips its own frontend step.
COPY --from=web /src/web/out ./server/webui/dist
ARG ARTEX_VERSION=dev
ARG TARGETOS
ARG TARGETARCH
# Same flags as the release binaries job (ARTEX_COMPRESS=0, -trimpath,
# -X main.version), driven through build.sh so there is one build path.
RUN ARTEX_SKIP_FRONTEND=1 \
    ARTEX_SKIP_NPM_CI=1 \
    ARTEX_COMPRESS=0 \
    ARTEX_OUTPUT=/out/artex \
    ARTEX_BUILD_VERSION="${ARTEX_VERSION}" \
    bash ./build.sh --target "${TARGETOS:-linux}/${TARGETARCH:-amd64}"

# ------------------------------------------------------- third-party tools ---
# Web-recon toolbox (drost-community take 1, #100): pinned release binaries, staged
# on the build platform and copied into /usr/local/bin of the runtime image so hunt
# workers can run them directly through their Bash tool. Versions pinned per tool;
# upgrade deliberately.
#
# Every archive is verified against a SHA-256 written down here, per asset and per
# architecture, not against the *_checksums.txt of its own GitHub release. Checking
# against that file catches a corrupted or swapped download and a moved tag, but the
# digest and the artifact it describes come from the same publisher and the same
# release: a replacement asset and a replacement checksums file agree with each
# other and the build passes. Pinning the digest here moves that decision out of the
# build, so a swapped asset fails unless the diff that swaps it also changes the
# digest a reviewer reads.
#
# Cost: a version bump is now three edits (the version ARG and the two digests), and
# a publisher re-uploading an asset under the same tag breaks the build until the
# digest is bumped on purpose. That is the trade: the build stops trusting the
# channel it downloads from.
#
# sqlmap has no release binaries: it is a shallow clone of a pinned tag, checked
# against the expected commit, which is the same idea.
FROM --platform=$BUILDPLATFORM debian:bookworm-slim@sha256:734a72b3d6142a71993b4bc580ca01d8ca687f77a2c422d96a961d3376b179bc AS tools
ARG TARGETARCH
ARG NUCLEI_VERSION=v3.11.1
ARG NUCLEI_SHA256_AMD64=ea63d4ae232808cd7c6bc00d0142428e231fab59dae01042246097d195835ab6
ARG NUCLEI_SHA256_ARM64=8044e3d9768ba0a744b2872c1a87e813006f013da97ca9f50f7661a4203bec07
ARG HTTPX_VERSION=v1.12.0
ARG HTTPX_SHA256_AMD64=9d8439e8b6c9aa7d1e2314817a392e00d5178da3af5652f7475f88868f418f76
ARG HTTPX_SHA256_ARM64=fd7b123c1dfbc3d69f19f524e4eebcd6ec06b9a6cbd56813c76f11645197331e
ARG SUBFINDER_VERSION=v2.17.0
ARG SUBFINDER_SHA256_AMD64=a39c3e5c7a26ef3c430915c4d6cbf7716a00f26769a75e9405aba796142eba37
ARG SUBFINDER_SHA256_ARM64=24913d49dddc1d3a5e99a4a7580da5be980959b9415b96f52c4f7f4124392190
ARG KATANA_VERSION=v1.8.0
ARG KATANA_SHA256_AMD64=cb027ae99d0757061b70c07a15c7a80f62c5a535ab52c4a329f80c4b0a7309d2
ARG KATANA_SHA256_ARM64=80e269210727a855511ffac8dfb01297b2344742acec71a35e8ba4a67a90f0f2
ARG FFUF_VERSION=v2.3.0
ARG FFUF_SHA256_AMD64=b2a3c725fcb9da175159682f54d6e9149f2905b00d84d155e7efc5d599975ceb
ARG FFUF_SHA256_ARM64=e2d712615d53da797ee929006e41f2df5a7960a5353133db9c150ddaa22ae4e8
ARG DALFOX_VERSION=v3.2.4
ARG DALFOX_SHA256_AMD64=c11cfd2f8261973f0a2a2a1eba5a147ce77712a29acfa6343f9847fb8bb7eca2
ARG DALFOX_SHA256_ARM64=fd56b0b7da2d06868cd73b504f41d21314629feffcd5bdc97718db1c9dd2fa70
ARG SQLMAP_VERSION=1.9.9
ARG SQLMAP_COMMIT=cceda39208b5aad478de2c3f731df4239d9881f6
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git unzip \
    && rm -rf /var/lib/apt/lists/*
RUN set -eux; \
    case "${TARGETARCH:-amd64}" in \
      amd64) PD_ARCH=amd64; FFUF_ARCH=amd64; DALFOX_ARCH=x86_64; \
             NUCLEI_SUM="$NUCLEI_SHA256_AMD64"; HTTPX_SUM="$HTTPX_SHA256_AMD64"; \
             SUBFINDER_SUM="$SUBFINDER_SHA256_AMD64"; KATANA_SUM="$KATANA_SHA256_AMD64"; \
             FFUF_SUM="$FFUF_SHA256_AMD64"; DALFOX_SUM="$DALFOX_SHA256_AMD64" ;; \
      arm64) PD_ARCH=arm64; FFUF_ARCH=arm64; DALFOX_ARCH=aarch64; \
             NUCLEI_SUM="$NUCLEI_SHA256_ARM64"; HTTPX_SUM="$HTTPX_SHA256_ARM64"; \
             SUBFINDER_SUM="$SUBFINDER_SHA256_ARM64"; KATANA_SUM="$KATANA_SHA256_ARM64"; \
             FFUF_SUM="$FFUF_SHA256_ARM64"; DALFOX_SUM="$DALFOX_SHA256_ARM64" ;; \
      *) echo "unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    mkdir -p /out; \
    fetch() { base="$1"; asset="$2"; want="$3"; name="$4"; \
      rm -rf /tmp/t; mkdir -p /tmp/t/x; \
      curl -fsSL "$base/$asset" -o "/tmp/t/$asset"; \
      if [ -z "$want" ]; then echo "no pinned digest for $asset" >&2; exit 1; fi; \
      got="$(sha256sum "/tmp/t/$asset" | cut -d' ' -f1)"; \
      if [ "$want" != "$got" ]; then echo "checksum mismatch for $asset: want $want got $got" >&2; exit 1; fi; \
      case "$asset" in *.zip) unzip -q "/tmp/t/$asset" -d /tmp/t/x ;; *) tar -xzf "/tmp/t/$asset" -C /tmp/t/x ;; esac; \
      find /tmp/t/x -type f -name "$name" -exec install -m 0755 {} /out/ \; ; \
      [ -x "/out/$name" ] || { echo "$name not found in $asset" >&2; exit 1; }; \
      rm -rf /tmp/t; }; \
    gh="https://github.com"; \
    fetch "$gh/projectdiscovery/nuclei/releases/download/$NUCLEI_VERSION" \
      "nuclei_${NUCLEI_VERSION#v}_linux_${PD_ARCH}.zip" "$NUCLEI_SUM" nuclei; \
    fetch "$gh/projectdiscovery/httpx/releases/download/$HTTPX_VERSION" \
      "httpx_${HTTPX_VERSION#v}_linux_${PD_ARCH}.zip" "$HTTPX_SUM" httpx; \
    fetch "$gh/projectdiscovery/subfinder/releases/download/$SUBFINDER_VERSION" \
      "subfinder_${SUBFINDER_VERSION#v}_linux_${PD_ARCH}.zip" "$SUBFINDER_SUM" subfinder; \
    fetch "$gh/projectdiscovery/katana/releases/download/$KATANA_VERSION" \
      "katana_${KATANA_VERSION#v}_linux_${PD_ARCH}.zip" "$KATANA_SUM" katana; \
    fetch "$gh/ffuf/ffuf/releases/download/$FFUF_VERSION" \
      "ffuf_${FFUF_VERSION#v}_linux_${FFUF_ARCH}.tar.gz" "$FFUF_SUM" ffuf; \
    fetch "$gh/hahwul/dalfox/releases/download/$DALFOX_VERSION" \
      "dalfox-${DALFOX_VERSION}-linux-${DALFOX_ARCH}-musl.tar.gz" "$DALFOX_SUM" dalfox; \
    git clone --quiet --depth 1 --branch "$SQLMAP_VERSION" https://github.com/sqlmapproject/sqlmap /opt/sqlmap; \
    commit="$(git -C /opt/sqlmap rev-parse HEAD)"; \
    if [ "$commit" != "$SQLMAP_COMMIT" ]; then echo "sqlmap commit mismatch: want $SQLMAP_COMMIT got $commit" >&2; exit 1; fi; \
    rm -rf /opt/sqlmap/.git

# -------------------------------------------------------- nuclei templates ---
# nuclei ships no templates in the binary: on first run it clones
# projectdiscovery/nuclei-templates into $HOME/nuclei-templates. Where the process
# cannot reach github.com that install fails softly — it logs "nuclei-templates are
# not installed, installing...", then "no templates found in path", and exits 0, so a
# scan starts with an empty template set and looks like a broken tool. That is the
# normal case behind an egress allowlist, and the case for every agent-run scan: the
# executor's HOME is /app/data/exec-home, not the root-owned home the image is
# built with. Bake the set at a fixed path instead, and point nuclei at it with
# NUCLEI_TEMPLATES_DIR in the runtime stage, so the lookup does not depend on HOME or
# on which user the process runs as. Tag and commit are both pinned and asserted: a
# moved tag fails the build rather than silently changing the template set.
ARG NUCLEI_TEMPLATES_VERSION=v10.5.1
ARG NUCLEI_TEMPLATES_COMMIT=79fb682760ab3d5b0e22afbb44709353cbebf023
RUN set -eux; \
    git clone --quiet --depth 1 --branch "$NUCLEI_TEMPLATES_VERSION" \
      https://github.com/projectdiscovery/nuclei-templates /opt/nuclei-templates; \
    commit="$(git -C /opt/nuclei-templates rev-parse HEAD)"; \
    if [ "$commit" != "$NUCLEI_TEMPLATES_COMMIT" ]; then echo "nuclei-templates commit mismatch: want $NUCLEI_TEMPLATES_COMMIT got $commit" >&2; exit 1; fi; \
    rm -rf /opt/nuclei-templates/.git; \
    count="$(find /opt/nuclei-templates -name '*.yaml' | wc -l)"; \
    echo "baked nuclei templates: $count"; \
    test "$count" -gt 10000

# ---------------------------------------------------- mobile-security tools ---
# Android/APK testing toolbox for the mobile skills: jadx (dex/java decompiler),
# apktool (manifest/resource decode + rebuild), Android build-tools (aapt, aapt2,
# zipalign, apksigner) and frida-server device agents. Everything is pinned and
# verified against the official sha256 digest of the exact release asset (GitHub
# release digests for jadx/apktool/frida; the Google repository zip for
# build-tools), the same idea as the tools stage above.
#
# jadx and apktool are pure Java, so they are architecture-independent. Google
# ships build-tools linux binaries for x86_64 only: on an arm64 build the native
# tools are pruned here and only the Java apksigner jar survives. frida-server
# binaries target the ANDROID device ABIs, so all of them are staged regardless
# of the image architecture; the runtime frida CLI is pinned to the same version
# in the venv block below, keeping client and device agent version-exact.
FROM --platform=$BUILDPLATFORM debian:bookworm-slim@sha256:734a72b3d6142a71993b4bc580ca01d8ca687f77a2c422d96a961d3376b179bc AS mobile-tools
ARG TARGETARCH
ARG JADX_VERSION=1.5.7
ARG JADX_SHA256=1755e4242ade71a077438723689f404079592ec7764a3a0572f98fef94ebcbf3
ARG APKTOOL_VERSION=3.0.3
ARG APKTOOL_SHA256=dbf930b076c6b9be08d57c449cacefc3bdd6b71ebd59b3066fc0e1f5b14f9423
ARG BUILD_TOOLS_SHA256=e858c4b60069d0431051b225d384413b1643e1289b00a4825aed347f25bd510f
ARG FRIDA_VERSION=17.27.6
ARG FRIDA_SERVER_ARM_SHA256=7ee46853e538a645f4a107a6af35ba73acd9b7ffa28c64d1a3e2eaaaa89e41a9
ARG FRIDA_SERVER_ARM64_SHA256=1a803a00d1e2e7c0426f13f9097d8e4275c96ffa2030fea374e860c97d226b75
ARG FRIDA_SERVER_X86_64_SHA256=5d3030f90fc110fc91249c392e1f1402522f89753a6404e83884fdaa31a04bf0
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl unzip xz-utils openjdk-17-jre-headless \
    && rm -rf /var/lib/apt/lists/*
RUN set -eux; \
    mkdir -p /out-mobile/jadx /out-mobile/apktool /out-mobile/build-tools /out-mobile/frida; \
    curl -fsSL "https://github.com/skylot/jadx/releases/download/v${JADX_VERSION}/jadx-${JADX_VERSION}.zip" -o /tmp/jadx.zip; \
    got="$(sha256sum /tmp/jadx.zip | cut -d' ' -f1)"; \
    [ "$got" = "$JADX_SHA256" ] || { echo "jadx checksum mismatch: want $JADX_SHA256 got $got" >&2; exit 1; }; \
    unzip -q /tmp/jadx.zip -d /out-mobile/jadx; \
    /out-mobile/jadx/bin/jadx --version; \
    curl -fsSL "https://github.com/iBotPeaches/Apktool/releases/download/v${APKTOOL_VERSION}/apktool_${APKTOOL_VERSION}.jar" -o /out-mobile/apktool/apktool.jar; \
    got="$(sha256sum /out-mobile/apktool/apktool.jar | cut -d' ' -f1)"; \
    [ "$got" = "$APKTOOL_SHA256" ] || { echo "apktool checksum mismatch: want $APKTOOL_SHA256 got $got" >&2; exit 1; }; \
    java -jar /out-mobile/apktool/apktool.jar --version; \
    rm -f /tmp/jadx.zip
RUN set -eux; \
    curl -fsSL "https://dl.google.com/android/repository/build-tools_r34-linux.zip" -o /tmp/bt.zip; \
    got="$(sha256sum /tmp/bt.zip | cut -d' ' -f1)"; \
    [ "$got" = "$BUILD_TOOLS_SHA256" ] || { echo "build-tools checksum mismatch: want $BUILD_TOOLS_SHA256 got $got" >&2; exit 1; }; \
    unzip -q /tmp/bt.zip -d /tmp/bt; \
    mv /tmp/bt/android-14 /out-mobile/build-tools/tools; \
    rm -f /tmp/bt.zip; \
    if [ "${TARGETARCH:-amd64}" != "amd64" ]; then \
      echo "build-tools linux binaries are x86_64-only; keeping the Java apksigner for arm64"; \
      find /out-mobile/build-tools/tools -maxdepth 1 -type f ! -name apksigner -delete; \
    fi; \
    /out-mobile/build-tools/tools/apksigner --version
RUN set -eux; \
    for abi in arm arm64 x86_64; do \
      case "$abi" in \
        arm) want="$FRIDA_SERVER_ARM_SHA256" ;; \
        arm64) want="$FRIDA_SERVER_ARM64_SHA256" ;; \
        x86_64) want="$FRIDA_SERVER_X86_64_SHA256" ;; \
      esac; \
      curl -fsSL "https://github.com/frida/frida/releases/download/${FRIDA_VERSION}/frida-server-${FRIDA_VERSION}-android-${abi}.xz" -o /tmp/fs.xz; \
      got="$(sha256sum /tmp/fs.xz | cut -d' ' -f1)"; \
      [ "$got" = "$want" ] || { echo "frida-server ${abi} checksum mismatch: want $want got $got" >&2; exit 1; }; \
      xz -dc /tmp/fs.xz > "/out-mobile/frida/frida-server-${FRIDA_VERSION}-android-${abi}"; \
      chmod 0755 "/out-mobile/frida/frida-server-${FRIDA_VERSION}-android-${abi}"; \
      rm -f /tmp/fs.xz; \
    done; \
    ls -la /out-mobile/frida

# ---------------------------------------------------------------- runtime ---
FROM python:3.12-slim-bookworm@sha256:935c3c5b12357a7e10caa9c1e6ca5692344d97cf229832ef584be2cec9fc03df
ARG TARGETARCH
# Common tools: ripgrep / curl / vim, plus a set of recon staples (add/remove as needed).
# adb + a JRE serve the mobile skills (device control, apktool/jadx/apksigner);
# adb here is the container-side client only — devices connect over the network
# (the container has no USB passthrough), see docs/mobile-security-testing.md.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates ripgrep curl wget vim git jq unzip xz-utils \
      dnsutils iputils-ping netcat-openbsd inetutils-telnet whois nmap \
      arp-scan arping fping iproute2 netdiscover net-tools nfs-common \
      python3-impacket python3-paramiko python3-scapy rpcbind sqlite3 xxd \
      hashcat hydra john ncrack openssh-client ssh-audit sshpass \
      adb openjdk-17-jre-headless \
    && rm -rf /var/lib/apt/lists/*
# Node 22 from the official nodejs.org tarball: bookworm's apt nodejs is 18,
# Playwright requires >=20, and 20 is end-of-life. 22 matches the CI and release
# workflows. Verified against a digest pinned here rather than against the fetched
# SHASUMS256.txt, for the reason given at the tools stage.
ARG NODE_VERSION=22.23.4
ARG NODE_SHA256_AMD64=1805bcd35e6815559bd2eb97db438d3fdb0eb3a5e6a977b7c1badca76337e9ce
ARG NODE_SHA256_ARM64=6287aa46b6c375d816e63ae66d024fbbfd70404825aabdfdf898a970871d2f4b
RUN set -eux; \
    case "${TARGETARCH:-amd64}" in \
      amd64) NODE_ARCH=x64; want="$NODE_SHA256_AMD64" ;; \
      arm64) NODE_ARCH=arm64; want="$NODE_SHA256_ARM64" ;; \
      *) echo "unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    base="https://nodejs.org/dist/v${NODE_VERSION}"; \
    asset="node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz"; \
    curl -fsSL "$base/$asset" -o "/tmp/$asset"; \
    [ -n "$want" ] || { echo "no pinned digest for $asset" >&2; exit 1; }; \
    got="$(sha256sum "/tmp/$asset" | cut -d' ' -f1)"; \
    if [ "$want" != "$got" ]; then echo "checksum mismatch for $asset: want $want got $got" >&2; exit 1; fi; \
    tar -xJf "/tmp/$asset" -C /usr/local --strip-components=1 --no-same-owner; \
    rm -f "/tmp/$asset"; \
    node --version; npm --version
# Pinned, checksum-verified recon binaries and the sqlmap checkout from the tools stage,
# plus the baked nuclei template set (see the tools stage for why it is baked).
COPY --from=tools /out/ /usr/local/bin/
COPY --from=tools /opt/sqlmap /opt/sqlmap
COPY --from=tools /opt/nuclei-templates /opt/nuclei-templates
# Mobile toolchain from the mobile-tools stage (see that stage for what lands where).
COPY --from=mobile-tools /out-mobile/jadx /opt/jadx
COPY --from=mobile-tools /out-mobile/apktool /opt/apktool
COPY --from=mobile-tools /out-mobile/build-tools /opt/android-build-tools
COPY --from=mobile-tools /out-mobile/frida /opt/frida-server-android
# Read by nuclei in preference to $HOME/nuclei-templates, so root and the executor
# resolve the same set. The directory stays root-owned and world-readable; scans
# never need to write to it. The second variable keeps the set frozen: without it a
# start with network access runs the routine template update against the public
# repository, which rewrites the baked tree (and, on a slow link, adds tens of MB to
# the writable layer for a result the bake already provides).
ENV NUCLEI_TEMPLATES_DIR=/opt/nuclei-templates \
    DISABLE_NUCLEI_TEMPLATES_PUBLIC_DOWNLOAD=true \
    FRIDA_SERVER_DIR=/opt/frida-server-android
# -duc is what keeps this a check rather than an update: `nuclei -tl` runs the
# automatic nuclei/templates update check first, so it could replace the pinned set
# with the latest release inside the layer we are about to inspect.
RUN set -eux; \
    ln -s /opt/sqlmap/sqlmap.py /usr/local/bin/sqlmap; \
    ln -s /opt/jadx/bin/jadx /usr/local/bin/jadx; \
    printf '#!/bin/sh\nexec java -jar /opt/apktool/apktool.jar "$@"\n' > /usr/local/bin/apktool; \
    chmod 0755 /usr/local/bin/apktool; \
    ln -s /opt/android-build-tools/tools/apksigner /usr/local/bin/apksigner; \
    if [ "${TARGETARCH:-amd64}" = "amd64" ]; then \
      ln -s /opt/android-build-tools/tools/zipalign /usr/local/bin/zipalign; \
      ln -s /opt/android-build-tools/tools/aapt /usr/local/bin/aapt; \
      ln -s /opt/android-build-tools/tools/aapt2 /usr/local/bin/aapt2; \
    fi; \
    nuclei -version >/dev/null; httpx -version; subfinder -version; katana -version; \
    ffuf -V >/dev/null; dalfox --version >/dev/null; sqlmap --version >/dev/null; \
    jadx --version >/dev/null; apktool --version >/dev/null; apksigner --version >/dev/null; \
    adb version >/dev/null; \
    templates="$(nuclei -tl -silent -duc | wc -l)"; \
    echo "nuclei templates visible at build time: $templates"; \
    test "$templates" -gt 10000

# bbot recursive recon orchestrator (#117): blacklanternsecurity/bbot, AGPL-3.0
# (same license as ARTEX; standalone CLI dependency, not linked code). Pinned
# version, own venv to isolate from the image python. Module dependencies are
# preinstalled (--install-all-deps) so scans never need pip at runtime, which
# would fail under a program's egress allowlist.
ARG BBOT_VERSION=3.0.2
# arm64: bbot's Chrome and retirejs's Node are x86-64; use native builds.
RUN set -eux; \
    python -m venv /opt/bbot; \
    /opt/bbot/bin/pip install --no-cache-dir "bbot==${BBOT_VERSION}"; \
    ln -s /opt/bbot/bin/bbot /usr/local/bin/bbot; \
    if [ "${TARGETARCH:-amd64}" = "arm64" ]; then \
      apt-get update; \
      apt-get install -y --no-install-recommends chromium; \
      rm -rf /var/lib/apt/lists/*; \
      bbot_dir="$(/opt/bbot/bin/python -c 'import bbot, os; print(os.path.dirname(bbot.__file__))')"; \
      sed -i 's/linux-x64/linux-arm64/g' "$bbot_dir/modules/retirejs.py"; \
    fi; \
    bbot -y --install-all-deps; \
    if [ "${TARGETARCH:-amd64}" = "arm64" ]; then \
      printf '\nmodules:\n  gowitness:\n    chrome_path: /usr/bin/chromium\n' >> /root/.config/bbot/bbot.yml; \
    fi; \
    bbot --version >/dev/null; \
    bbot --dry-run -t example.com -m wafw00f,paramminer_getparams,lightfuzz,sslcert,gowitness,retirejs >/dev/null 2>&1 || true; \
    bbot --dry-run -t example.com -m wafw00f,paramminer_getparams,lightfuzz,sslcert,gowitness,retirejs --no-color >/tmp/bbot-dry.log 2>&1 || true; \
    ! grep -qE "Installing|ERRR|CRITICAL" /tmp/bbot-dry.log || { cat /tmp/bbot-dry.log; exit 1; }


# Mobile security venv: frida CLI, objection, androguard, apkid, apkleaks and
# mobsfscan, all pinned. Own venv to isolate from the image python, same as bbot.
# frida (python bindings) is pinned to the same version as the frida-server
# device agents staged above, so adb-pushed instrumentation is version-exact.
# mobsfscan pulls the MobSF semgrep rule set (semgrep is the largest single
# dependency in this block); drop it there if image size matters.
ARG FRIDA_TOOLS_VERSION=14.13.2
ARG FRIDA_PY_VERSION=17.27.6
ARG OBJECTION_VERSION=1.12.5
ARG ANDROGUARD_VERSION=4.1.4
ARG APKID_VERSION=3.2.0
ARG APKLEAKS_VERSION=2.6.3
ARG MOBSFSCAN_VERSION=1.2.0
RUN set -eux; \
    python -m venv /opt/mobilesec; \
    /opt/mobilesec/bin/pip install --no-cache-dir \
      "frida==${FRIDA_PY_VERSION}" \
      "frida-tools==${FRIDA_TOOLS_VERSION}" \
      "objection==${OBJECTION_VERSION}" \
      "androguard==${ANDROGUARD_VERSION}" \
      "apkid==${APKID_VERSION}" \
      "apkleaks==${APKLEAKS_VERSION}" \
      "mobsfscan==${MOBSFSCAN_VERSION}"; \
    for c in frida frida-ps frida-ls-devices frida-trace frida-kill objection apkid apkleaks mobsfscan androguard; do \
      ln -s "/opt/mobilesec/bin/$c" "/usr/local/bin/$c"; \
    done; \
    frida --version; objection version


# Preinstall Playwright MCP and CLI (globally) so no network download is needed at runtime.
# @playwright/mcp: the seeded browser MCP runs the playwright-mcp binary directly.
# `npx @playwright/mcp` is not used: it queries the npm registry on every start even
# with the package installed globally.
# @playwright/cli: provides playwright-cli, verified with --help right after install.
# Then install playwright (browser management) and preinstall chromium plus its system
# dependencies via --with-deps. @playwright/mcp and @playwright/cli bundle their own
# playwright-core, which expects a different Chromium build than
# playwright@PLAYWRIGHT_VERSION installs, so that build is installed as well (second
# install line); without it neither can launch a browser. All three packages are
# pinned; upgrade deliberately.
ARG PLAYWRIGHT_MCP_VERSION=0.0.83
ARG PLAYWRIGHT_CLI_VERSION=0.1.22
ARG PLAYWRIGHT_VERSION=1.64.1
# playwright-core's exports map hides cli.js from require.resolve, so run the
# binary npm links for @playwright/mcp instead: it is the copy MCP actually
# loads, and it installs the Chromium revision that copy expects.
RUN npm install -g "@playwright/mcp@${PLAYWRIGHT_MCP_VERSION}" "@playwright/cli@${PLAYWRIGHT_CLI_VERSION}" "playwright@${PLAYWRIGHT_VERSION}" \
    && playwright-cli --help \
    && playwright install --with-deps chromium \
    && "$(npm root -g)/@playwright/mcp/node_modules/.bin/playwright-core" install chromium \
    && rm -rf /var/lib/apt/lists/*
# Agent processes run as the executor with HOME and XDG_CACHE_HOME in the data
# directory (server/execpriv_unix.go); the browsers installed above stay in root's
# cache, which /root's 0711 lets the executor reach.
ENV PLAYWRIGHT_BROWSERS_PATH=/root/.cache/ms-playwright
WORKDIR /app
# Binary compiled from source in the build stage above.
COPY --from=build /out/artex /app/artex
# Daemon startup script: relaunches the process after a crash and forwards SIGTERM
# to artex — docker stop only signals PID 1; without forwarding, artex never receives it,
# cannot shut down gracefully, and is hard-killed by SIGKILL after 10 seconds.
COPY start.sh /app/start.sh
RUN chmod +x /app/artex /app/start.sh && mkdir -p -m 0700 /app/keys \
    && chmod 0711 /root
# No setuid or setgid programs (su, passwd, mount, bbot's chrome_sandbox, ...): an
# agent process runs as the executor and must not regain root through one, even
# when the container runs without docker-compose.yml's no-new-privileges.
RUN find / -xdev -perm /6000 -type f -exec chmod a-s {} +
COPY skills/ /app/skills/
# Operator-facing helper the frida skill runs through Bash (pushes the baked
# frida-server to the connected device); kept out of the agent workspace on
# purpose — it lives at a fixed absolute path.
COPY scripts/mobile/ /app/scripts/mobile/
RUN chmod 0755 /app/scripts/mobile/*.sh
# persistence points: data/ (traffic index, task files, transcripts) and keys/ (jwt.key, secret.key, via ARTEX_JWT_KEY_DIR)
VOLUME ["/app/data", "/app/keys"]
EXPOSE 8787 8788
ENTRYPOINT ["/app/start.sh"]
CMD ["-addr", ":8787", "-proxy", ":8788"]
