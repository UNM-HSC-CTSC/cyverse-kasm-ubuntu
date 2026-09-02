#!/bin/bash
# vglrun-wrapper.sh - Launch an application with GPU acceleration when available.
#
# The NVIDIA GL/EGL selection variables live here rather than in the image
# environment on purpose. Exported image-wide they apply to every process in the
# container and force all GL clients onto the NVIDIA driver, which cannot render
# against KasmVNC's Xvnc; __EGL_VENDOR_LIBRARY_FILENAMES makes it worse by
# replacing the EGL vendor list instead of extending it, so Mesa/llvmpipe is no
# longer reachable as a fallback and GUI apps break outright. Scoped to this
# wrapper, they only affect a process that explicitly asked for the GPU.

APP=("$@")

# Find vglrun location (check common paths)
if command -v vglrun &>/dev/null; then
    VGLRUN="vglrun"
elif [ -x "/opt/VirtualGL/bin/vglrun" ]; then
    VGLRUN="/opt/VirtualGL/bin/vglrun"
else
    VGLRUN=""
fi

# Check if VirtualGL is available and we have GPU devices
if [ -n "$VGLRUN" ] && [ -d "/dev/dri" ]; then
    echo "Starting with GPU Acceleration via VirtualGL (EGL backend)"
    # -u LIBGL_ALWAYS_SOFTWARE: vnc_startup.sh pins the desktop session to
    # llvmpipe so ordinary GUI apps stop probing a DRM node Mesa cannot drive.
    # An app routed through here is asking for the GPU, so lift that pin.
    exec env -u LIBGL_ALWAYS_SOFTWARE \
             VGL_DISPLAY=egl \
             __GLX_VENDOR_LIBRARY_NAME=nvidia \
             __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/10_nvidia.json \
             "$VGLRUN" "${APP[@]}"
else
    echo "Starting without GPU acceleration (software rendering)"
    exec "${APP[@]}"
fi
