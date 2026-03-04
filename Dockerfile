###############################################
# Flutter Android ARM64 Docker Image
#
# Custom image for building Android APKs on
# ARM64 (Apple Silicon) CI runners with OrbStack.
#
# Solves: AAPT2 x86_64 binary crash on ARM64 Linux.
# Uses ARM64-native build-tools from lzhiyong/android-sdk-tools
# and system clang-19 to replace NDK's x86_64 toolchain.
#
# gen_snapshot: Flutter 3.38.3 has no linux-arm64 build.
# OrbStack runs x86_64 ELFs natively via binfmt_misc (kernel level).
# We create a linux-arm64/gen_snapshot wrapper that calls linux-x64/gen_snapshot
# directly. libc6:amd64 provides /lib64/ld-linux-x86-64.so.2 needed by the ELF.
###############################################

FROM ubuntu:24.04

LABEL maintainer="ruslankolmakov"
LABEL description="Flutter 3.38.3 + Android SDK 36 for ARM64 Linux"

# ── Versions ─────────────────────────────────
ARG FLUTTER_VERSION=3.38.3
ARG ANDROID_SDK_TOOLS_VERSION=11076708
ARG BUILD_TOOLS_VERSION=36.0.0
ARG PLATFORM_VERSION=android-36
ARG JAVA_VERSION=21
ARG ARM64_TOOLS_VERSION=35.0.2

# ── Environment ──────────────────────────────
ENV ANDROID_HOME=/opt/android-sdk \
    ANDROID_SDK_ROOT=/opt/android-sdk \
    FLUTTER_HOME=/opt/flutter \
    JAVA_HOME=/usr/lib/jvm/java-${JAVA_VERSION}-openjdk-arm64
ENV PATH="${FLUTTER_HOME}/bin:${FLUTTER_HOME}/bin/cache/dart-sdk/bin:${ANDROID_HOME}/cmdline-tools/latest/bin:${ANDROID_HOME}/platform-tools:${ANDROID_HOME}/build-tools/${BUILD_TOOLS_VERSION}:${PATH}"

# ── System packages ──────────────────────────
# Note: dpkg --add-architecture amd64 + archive.ubuntu.com source enables x86_64 packages.
# libc6:amd64 provides /lib64/ld-linux-x86-64.so.2 required by gen_snapshot
# (Flutter 3.38.3 only ships linux-x64/gen_snapshot; OrbStack runs it via binfmt_misc).
RUN dpkg --add-architecture amd64 && \
    # ports.ubuntu.com doesn't serve amd64; add archive.ubuntu.com for amd64 packages
    sed -i 's|URIs: http://ports.ubuntu.com/ubuntu-ports/|Architectures: arm64\nURIs: http://ports.ubuntu.com/ubuntu-ports/|g' \
        /etc/apt/sources.list.d/ubuntu.sources && \
    printf 'Types: deb\nURIs: http://archive.ubuntu.com/ubuntu\nSuites: noble noble-updates noble-security\nComponents: main\nArchitectures: amd64\nSigned-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg\n' \
        > /etc/apt/sources.list.d/amd64.sources && \
    apt-get update && apt-get install -y --no-install-recommends \
    curl \
    git \
    unzip \
    xz-utils \
    zip \
    ca-certificates \
    openssh-client \
    openjdk-${JAVA_VERSION}-jdk-headless \
    # ARM64-native LLVM toolchain (replaces NDK's x86_64 clang)
    clang-19 \
    lld-19 \
    llvm-19 \
    # ARM64-native cmake & ninja (replaces SDK's x86_64 cmake)
    cmake \
    ninja-build \
    # x86_64 glibc for gen_snapshot (x86_64 ELF needs /lib64/ld-linux-x86-64.so.2)
    libc6:amd64 \
    && rm -rf /var/lib/apt/lists/*

# ── Android SDK (cmdline-tools) ──────────────
RUN mkdir -p ${ANDROID_HOME}/cmdline-tools && \
    curl -fsSL "https://dl.google.com/android/repository/commandlinetools-linux-${ANDROID_SDK_TOOLS_VERSION}_latest.zip" \
      -o /tmp/cmdline-tools.zip && \
    unzip -q /tmp/cmdline-tools.zip -d /tmp/cmdline-tools && \
    mv /tmp/cmdline-tools/cmdline-tools ${ANDROID_HOME}/cmdline-tools/latest && \
    rm -rf /tmp/cmdline-tools.zip /tmp/cmdline-tools

# ── Accept licenses & install SDK components ─
# cmake;3.22.1: used by Flutter/AGP for native builds (x86_64 → replaced below)
RUN yes | sdkmanager --licenses > /dev/null 2>&1 && \
    sdkmanager --install \
      "platform-tools" \
      "build-tools;${BUILD_TOOLS_VERSION}" \
      "platforms;${PLATFORM_VERSION}" \
      "ndk;27.0.12077973" \
      "ndk;28.0.12674087" \
      "ndk;28.2.13676358" \
      "cmake;3.22.1"

# ── ARM64-native build-tools & platform-tools ──
# Google ships x86_64-only Linux binaries.
# We replace them with ARM64-native builds from lzhiyong/android-sdk-tools.
RUN curl -fsSL "https://github.com/lzhiyong/android-sdk-tools/releases/download/${ARM64_TOOLS_VERSION}/android-sdk-tools-static-aarch64.zip" \
      -o /tmp/arm64-tools.zip && \
    unzip -q /tmp/arm64-tools.zip -d /tmp/arm64-tools && \
    # Replace x86_64 build-tools with ARM64 versions
    for tool in aapt2 aapt aidl zipalign dexdump split-select; do \
      if [ -f "/tmp/arm64-tools/build-tools/${tool}" ]; then \
        cp "/tmp/arm64-tools/build-tools/${tool}" "${ANDROID_HOME}/build-tools/${BUILD_TOOLS_VERSION}/${tool}" && \
        chmod +x "${ANDROID_HOME}/build-tools/${BUILD_TOOLS_VERSION}/${tool}"; \
      fi; \
    done && \
    # Replace x86_64 platform-tools with ARM64 versions
    for tool in adb fastboot sqlite3 etc1tool hprof-conv e2fsdroid mke2fs make_f2fs make_f2fs_casefold sload_f2fs; do \
      if [ -f "/tmp/arm64-tools/platform-tools/${tool}" ]; then \
        cp "/tmp/arm64-tools/platform-tools/${tool}" "${ANDROID_HOME}/platform-tools/${tool}" && \
        chmod +x "${ANDROID_HOME}/platform-tools/${tool}"; \
      fi; \
    done && \
    rm -rf /tmp/arm64-tools.zip /tmp/arm64-tools

# ── ARM64-native cmake & ninja (SDK override) ──
# SDK cmake is x86_64-only. Replace with system ARM64 binaries.
RUN ln -sf /usr/bin/cmake ${ANDROID_HOME}/cmake/3.22.1/bin/cmake && \
    ln -sf /usr/bin/ninja ${ANDROID_HOME}/cmake/3.22.1/bin/ninja

# ── ARM64-native NDK toolchain (clang/lld/llvm) ──
# NDK ships x86_64 clang, lld, llvm-ar, etc.
# Replace with system ARM64 clang-19 and LLVM tools for ALL installed NDKs.
# Key: use wrapper script (not symlink) for clang so we can pass --resource-dir
# to point to NDK's own clang resource dir (contains libatomic, libclang_rt, etc.).
# Also create libgcc.a linker scripts (NDK maps -lgcc to clang builtins internally).
RUN for ndk_dir in ${ANDROID_HOME}/ndk/*/; do \
      [ -d "${ndk_dir}" ] || continue; \
      ndk_bin="${ndk_dir}toolchains/llvm/prebuilt/linux-x86_64/bin"; \
      [ -d "${ndk_bin}" ] || continue; \
      ndk_ver=$(basename "${ndk_dir}"); \
      echo "Patching NDK ${ndk_ver}"; \
      \
      # Find NDK's clang resource dir version (e.g. 18, 19)
      clang_res_ver=$(ls "${ndk_dir}toolchains/llvm/prebuilt/linux-x86_64/lib/clang/" 2>/dev/null | head -1); \
      ndk_res_dir="${ndk_dir}toolchains/llvm/prebuilt/linux-x86_64/lib/clang/${clang_res_ver}"; \
      \
      # Replace clang binary with wrapper script that uses NDK resource dir
      for clang_bin in "${ndk_bin}"/clang-[0-9]*; do \
        [ -f "${clang_bin}" ] || continue; \
        rm -f "${clang_bin}"; \
        printf '#!/bin/sh\nexec /usr/lib/llvm-19/bin/clang -resource-dir %s "$@"\n' "${ndk_res_dir}" > "${clang_bin}"; \
        chmod +x "${clang_bin}"; \
      done; \
      \
      # Replace LLVM tools with system ARM64 symlinks
      for tool in lld ld.lld ld64.lld llvm-ar llvm-as llvm-nm llvm-objcopy llvm-objdump \
                  llvm-ranlib llvm-readelf llvm-readobj llvm-size llvm-strings llvm-strip \
                  llvm-symbolizer llvm-dwp llvm-cov llvm-profdata; do \
        if [ -f "/usr/lib/llvm-19/bin/${tool}" ] && [ -f "${ndk_bin}/${tool}" ]; then \
          rm -f "${ndk_bin}/${tool}" && \
          ln -s "/usr/lib/llvm-19/bin/${tool}" "${ndk_bin}/${tool}"; \
        fi; \
      done; \
      \
      # Create libgcc.a linker script for each ABI (redirects -lgcc to clang builtins)
      # Copy builtins into sysroot so linker finds them (ld.lld searches within sysroot)
      sysroot="${ndk_dir}toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib"; \
      for abi_dir in "${sysroot}"/*/; do \
        abi=$(basename "${abi_dir}"); \
        case "${abi}" in \
          aarch64-linux-android) builtins_arch="aarch64-android" ;; \
          arm-linux-androideabi)  builtins_arch="arm-android" ;; \
          x86_64-linux-android)  builtins_arch="x86_64-android" ;; \
          i686-linux-android)    builtins_arch="i386-android" ;; \
          riscv64-linux-android) builtins_arch="riscv64-android" ;; \
          *) continue ;; \
        esac; \
        builtins_file="libclang_rt.builtins-${builtins_arch}.a"; \
        builtins_src="${ndk_res_dir}/lib/linux/${builtins_file}"; \
        if [ -f "${builtins_src}" ]; then \
          cp "${builtins_src}" "${abi_dir}${builtins_file}"; \
          echo "INPUT(-latomic ${builtins_file})" > "${abi_dir}libgcc.a"; \
        fi; \
      done; \
    done

# ── Override AGP's Maven AAPT2 with ARM64 version ──
# AGP downloads its own x86_64 aapt2 from Maven Central.
# This gradle property forces AGP to use our ARM64 binary instead.
RUN mkdir -p /root/.gradle && \
    echo "android.aapt2FromMavenOverride=${ANDROID_HOME}/build-tools/${BUILD_TOOLS_VERSION}/aapt2" \
      >> /root/.gradle/gradle.properties

# ── Flutter SDK ──────────────────────────────
RUN git clone --depth 1 --branch ${FLUTTER_VERSION} \
      https://github.com/flutter/flutter.git ${FLUTTER_HOME} && \
    flutter precache --android && \
    flutter doctor --android-licenses 2>/dev/null; true

# ── gen_snapshot ARM64 wrapper ────────────────
# Flutter 3.38.3 does not publish linux-arm64/gen_snapshot.
# Create a linux-arm64/gen_snapshot that calls the linux-x64 binary directly.
# OrbStack runs x86_64 ELFs via kernel-level binfmt_misc; libc6:amd64 provides
# the x86_64 dynamic linker (/lib64/ld-linux-x86-64.so.2) needed by the binary.
RUN for dir in ${FLUTTER_HOME}/bin/cache/artifacts/engine/android-*-release/; do \
      x64_bin="${dir}linux-x64/gen_snapshot"; \
      arm64_dir="${dir}linux-arm64"; \
      [ -f "${x64_bin}" ] || continue; \
      mkdir -p "${arm64_dir}"; \
      printf '#!/bin/sh\nexec "%s" "$@"\n' "${x64_bin}" \
        > "${arm64_dir}/gen_snapshot"; \
      chmod +x "${arm64_dir}/gen_snapshot"; \
      echo "Created gen_snapshot wrapper for $(basename ${dir})"; \
    done

# ── Verify installation ─────────────────────
RUN java -version && \
    aapt2 version && \
    adb version && \
    flutter doctor -v; true

WORKDIR /app
