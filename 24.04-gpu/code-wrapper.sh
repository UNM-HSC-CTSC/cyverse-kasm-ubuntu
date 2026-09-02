#!/bin/bash
# code-wrapper.sh - Launch VS Code with GPU-accelerated WebGL via VirtualGL.
#
# This Chromium build's GL factory only allows the ANGLE/EGL implementation
# on Linux (confirmed via --enable-logging=stderr --v=1: "Requested GL
# implementation (gl=none,angle=none) not found in allowed implementations:
# [(gl=egl-angle,angle=default)]"). The legacy direct-GLX path VirtualGL
# classically targets (--use-gl=desktop) isn't in that allow-list at all and
# gets rejected before VirtualGL's interception ever matters. Chromium's own
# unflagged default also resolves to ANGLE, but onto its Vulkan backend
# (confirmed via chrome://gpu's Dawn info showing a working Vulkan adapter) --
# which VirtualGL cannot intercept, since it only fakes GLX/EGL, not Vulkan.
# --use-angle=gl-egl is what's needed to force ANGLE onto the EGL backend
# specifically, which VirtualGL 3.x+ can see and redirect to the real GPU.
#
# --disable-gpu-sandbox is required for VirtualGL's LD_PRELOAD faker to reach
# the GPU process; --ignore-gpu-blocklist bypasses this environment's
# blocklist entry once a real device is behind it. Verified via chrome://gpu:
# OpenGL/WebGL/Rasterization/Video Decode all hardware-accelerated. Display
# compositing itself stays software-only regardless -- Xvnc has no DRI3 path
# for the proprietary NVIDIA driver (see gpu_acceleration.md in the KasmVNC
# docs: DRI3 is nouveau-only) -- but the actual rendering work now runs on
# the GPU rather than llvmpipe/SwiftShader.
#
# Skipped when reusing an already-running window ($VSCODE_IPC_HOOK_CLI set):
# that path hands off to the lightweight remote-cli client rather than
# launching a fresh Electron/Chromium process, so there's no GPU process here
# to accelerate and injecting these flags would just be noise forwarded to
# the wrong place.
REAL_CODE=/usr/share/code/bin/code

if [ -n "$VSCODE_IPC_HOOK_CLI" ]; then
    exec "$REAL_CODE" "$@"
fi

exec /usr/local/bin/vglrun-wrapper.sh "$REAL_CODE" --use-gl=angle --use-angle=gl-egl --ignore-gpu-blocklist --disable-gpu-sandbox "$@"
