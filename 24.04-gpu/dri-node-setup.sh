#!/bin/bash
# dri-node-setup.sh - point KasmVNC at whichever GPU we were actually allocated.
#
# KasmVNC's Xvnc initializes GBM against the default DRM node
# (/dev/dri/card0 + /dev/dri/renderD128) and treats failure as fatal:
#
#   (EE) Fatal server error:
#   (EE) Failed to create gbm
#
# On a multi-GPU host the NVIDIA device plugin injects only the DRM nodes for
# the GPU it actually allocated -- e.g. card4/renderD131 for GPU 4 -- so the
# default node is absent and the desktop dies during startup. Which GPU is
# allocated varies per launch, so the app appears to work intermittently
# (roughly 1 launch in 5 on a 5-GPU node, whenever GPU 0 is drawn).
#
# Two independent belts here, because either alone can be defeated:
#
#   1. Symlink the allocated node onto the name Xvnc hardcodes. open(2) follows
#      symlinks, so any code path that reaches for the default name gets a
#      working node. Needs a writable /dev/dri, hence sudo.
#   2. Print the allocated render node on stdout so vnc_startup.sh can pass it
#      as -drinode. Covers the case where /dev/dri is not writable and the
#      symlink cannot be created.
#
# Deliberately does NOT set KASM_EGL_CARD/KASM_RENDERD. Those steer VirtualGL
# rather than Xvnc's GBM init, so they do not fix this, and setting them
# switches XFCE onto a VirtualGL path whose libvglfaker.so/libdlfaker.so this
# image cannot preload -- noisy ld.so errors and no working interception.
#
# stdout is the resolved render node (or empty). All logging goes to stderr.
set -u

DEFAULT_CARD=/dev/dri/card0
DEFAULT_RENDER=/dev/dri/renderD128

log () {
    echo "dri-node-setup: $*" >&2
}

# Lowest-numbered node matching a glob, version-sorted so card10 does not sort
# ahead of card4. Prints nothing when the glob matches no existing file.
first_node () {
    local pattern="$1" node matches=()

    for node in $pattern; do
        [ -e "$node" ] && matches+=("$node")
    done

    [ ${#matches[@]} -eq 0 ] && return 0

    printf '%s\n' "${matches[@]}" | sort -V | head -n1
}

# Symlink a hardcoded default name onto the node we were actually given.
link_default_node () {
    local default_node="$1" allocated="$2"

    if [ -e "$default_node" ]; then
        log "$default_node already present; no link needed"
        return 0
    fi

    if [ -z "$allocated" ]; then
        log "no node available for $default_node; leaving it absent"
        return 0
    fi

    if ln -s "$allocated" "$default_node" 2>/dev/null \
        || sudo -n ln -s "$allocated" "$default_node" 2>/dev/null; then
        log "linked $default_node -> $allocated"
    else
        log "could not link $default_node -> $allocated (is /dev/dri writable?)"
    fi
}

if [ ! -d /dev/dri ]; then
    log "/dev/dri absent; starting without GPU nodes"
    exit 0
fi

card="$(first_node '/dev/dri/card*')"
render="$(first_node '/dev/dri/renderD*')"

# shellcheck disable=SC2012  # DRM node names are always plain alphanumerics
log "DRI nodes present: $(ls -1 /dev/dri 2>/dev/null | tr '\n' ' ')"

link_default_node "$DEFAULT_CARD" "$card"
link_default_node "$DEFAULT_RENDER" "$render"

# Prefer the real node over the symlink we just made: if the link failed, this
# is the only thing that keeps Xvnc alive.
if [ -n "$render" ]; then
    echo "$render"
elif [ -e "$DEFAULT_RENDER" ]; then
    echo "$DEFAULT_RENDER"
fi

exit 0
