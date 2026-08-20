FROM kasmweb/ubuntu-noble-nvidia-pytorch:1.18.0-rolling-daily

# Default timezone for the UNM deployment
ENV TZ=America/Denver

# =============================================================================
# NVIDIA GPU Configuration
# =============================================================================
# Enable GPU visibility and configure driver capabilities for compute, graphics, and display.
#
# Deliberately NOT set image-wide: __GLX_VENDOR_LIBRARY_NAME, VGL_DISPLAY and
# __EGL_VENDOR_LIBRARY_FILENAMES. Those are inherited by every process in the
# container, so they force *all* GL clients onto the NVIDIA driver -- and
# __EGL_VENDOR_LIBRARY_FILENAMES replaces the EGL vendor list outright rather
# than adding to it, which hides Mesa and removes the software fallback. The
# desktop here is KasmVNC's Xvnc, which has no NVIDIA X driver, so GUI apps
# (Chrome, VS Code, anything GTK/Electron) must render through Mesa/llvmpipe
# exactly as they do in the working non-GPU image. Apps that genuinely want the
# GPU go through /usr/local/bin/vglrun-wrapper.sh, which sets these itself.
ENV NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility,graphics,display

USER root

# =============================================================================
# System Packages Installation
# =============================================================================
# Combine all apt operations into a single layer to minimize image size
RUN apt-get update && apt-get install -y --no-install-recommends \
    # OpenGL/EGL libraries for GPU rendering
    libgl1 \
    libgl1-mesa-dri \
    libegl1 \
    libgles2 \
    libglvnd0 \
    libglvnd-dev \
    # Mesa's GLX/EGL vendor libraries. These are what GUI apps actually render
    # with on Xvnc (llvmpipe); without them libglvnd has no vendor to fall back
    # to once the NVIDIA vendor fails to initialise against a non-NVIDIA X server.
    libglx-mesa0 \
    libegl-mesa0 \
    # X11 libraries for GLX support
    libxau-dev \
    libxdmcp-dev \
    libxcb1-dev \
    libxext-dev \
    libx11-dev \
    libx11-xcb1 \
    # GPU testing and verification tools.
    #
    # vulkan-tools is deliberately absent. Kasm's /usr/bin/google-chrome wrapper
    # probes for it -- `command -v vulkaninfo` plus a check for a non-CPU
    # PHYSICAL_DEVICE_TYPE -- and, when found, launches Chrome with
    # --use-angle=vulkan. On a GPU node that probe succeeds, so merely
    # installing vulkan-tools silently switches Chrome onto an ANGLE/Vulkan
    # backend that cannot present through Xvnc. The non-GPU image never
    # installs it, which is why Chrome behaves there. Install it interactively
    # if you need to inspect Vulkan devices.
    mesa-utils \
    mesa-utils-extra \
    glmark2 \
    # VirtualGL dependencies
    libxtst6 \
    libxv1 \
    libglu1-mesa \
    # Development tools and utilities
    lsb-release \
    apt-transport-https \
    curl \
    wget \
    libfreetype6-dev \
    pkg-config \
    gcc \
    less \
    software-properties-common \
    apt-utils \
    glances \
    htop \
    nano \
    sudo \
    # GNOME desktop environment
    gnome-session \
    gnome-shell \
    gnome-control-center \
    gnome-terminal \
    gnome-system-monitor \
    gnome-tweaks \
    # Additional utilities for AI CLI tools
    locales \
    neofetch \
    figlet \
    w3m-img \
    imagemagick \
    s3fs \
    socat \
    bubblewrap \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# =============================================================================
# NodeJS Installation (for AI CLI Tools)
# =============================================================================
# Install NodeJS 20.x for Claude Code, OpenAI Codex, and Gemini CLI
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get update && \
    apt-get install -y nodejs && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# =============================================================================
# GitHub CLI Installation
# =============================================================================
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg && \
    chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null && \
    apt-get update && apt-get install -y gh && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# =============================================================================
# NVIDIA EGL Configuration
# =============================================================================
# Configure libglvnd to route EGL calls to NVIDIA libraries
RUN mkdir -p /usr/share/glvnd/egl_vendor.d && \
    echo '{"file_format_version":"1.0.0","ICD":{"library_path":"libEGL_nvidia.so.0"}}' \
    > /usr/share/glvnd/egl_vendor.d/10_nvidia.json

# =============================================================================
# NVIDIA Library Path Configuration
# =============================================================================
# Add NVIDIA library paths to ld.so configuration
RUN echo '/usr/local/nvidia/lib' >> /etc/ld.so.conf.d/nvidia.conf && \
    echo '/usr/local/nvidia/lib64' >> /etc/ld.so.conf.d/nvidia.conf && \
    ldconfig

# =============================================================================
# GPU Utility Scripts
# =============================================================================
# Copy and configure VirtualGL wrapper and GPU verification scripts
COPY vglrun-wrapper.sh /usr/local/bin/vglrun-wrapper.sh
COPY verify-gpu.sh /usr/local/bin/verify-gpu.sh
RUN chmod +x /usr/local/bin/vglrun-wrapper.sh /usr/local/bin/verify-gpu.sh

# =============================================================================
# Go Language Installation
# =============================================================================
# Install Go for building GoCommands
RUN wget -q -c https://dl.google.com/go/go1.25.0.linux-amd64.tar.gz -O - | tar -xz -C /usr/local
ENV PATH=$PATH:/usr/local/go/bin

# =============================================================================
# CyVerse Integration
# =============================================================================
# Configure data-store directory for CSI driver mounts and install GoCommands
WORKDIR /home/kasm-user/data-store

RUN mkdir -p /home/kasm-user/.irods && \
    echo '{"irods_host": "swcacti1.unm.edu", "irods_port": 1247, "irods_user_name": "$IPLANT_USER", "irods_zone_name": "swcactiZone"}' | envsubst > /home/kasm-user/.irods/irods_environment.json

# ~/scratch for temporary storage that isn't backed by the data store
RUN mkdir -p /home/kasm-user/scratch

# Install GoCommands for CyVerse data management
RUN cd /usr/local/bin/ && \
    GOCMD_VER=$(curl -L -s https://raw.githubusercontent.com/cyverse/gocommands/main/VERSION.txt) && \
    curl -L -s https://github.com/cyverse/gocommands/releases/download/${GOCMD_VER}/gocmd-${GOCMD_VER}-linux-amd64.tar.gz | tar zxvf -

# =============================================================================
# User Configuration
# =============================================================================
# Configure sudo access for kasm-user
ARG LOCAL_USER=kasm-user
ARG PRIV_CMDS='ALL'

RUN usermod -aG sudo ${LOCAL_USER} && \
    echo "${LOCAL_USER} ALL=NOPASSWD: ${PRIV_CMDS}" >> /etc/sudoers

# =============================================================================
# VNC Configuration
# =============================================================================
# Copy KASM VNC configuration and startup scripts
COPY kasmvnc_defaults.yaml /usr/share/kasmvnc/kasmvnc_defaults.yaml
COPY vnc_startup.sh /dockerstartup/vnc_startup.sh
# Points Xvnc at the GPU the NVIDIA device plugin actually allocated; without it
# the desktop dies with "Failed to create gbm" whenever it lands on a GPU other
# than card0. Invoked from vnc_startup.sh.
COPY dri-node-setup.sh /dockerstartup/dri-node-setup.sh
RUN chmod +x /dockerstartup/vnc_startup.sh /dockerstartup/dri-node-setup.sh

# Remove pyenv references from every shell startup file to prevent startup errors.
# The nvidia-pytorch base wires pyenv into the system-wide init, not just the
# user's .bashrc, and pyenv itself is unreachable as kasm-user -- so each new
# interactive shell printed "pyenv: command not found" once per init hook.
# Python here is managed by conda, so the hooks are pure noise.
#
# A deletion can land inside an if/fi block and leave the file unparseable -- and
# an unparseable /etc/bash.bashrc or /etc/profile.d entry breaks the environment
# of every interactive shell, and so of every GUI app launched from one. Edit a
# copy and keep it only if it still parses; otherwise restore the original and
# accept the cosmetic pyenv warning.
RUN for f in /etc/bash.bashrc /etc/profile /etc/profile.d/*.sh \
    /home/kasm-user/.bashrc /home/kasm-user/.bash_profile \
    /home/kasm-user/.profile; do \
    [ -f "$f" ] || continue; \
    grep -q pyenv "$f" || continue; \
    sed '/pyenv/d' "$f" > "$f.nopyenv"; \
    if bash -n "$f.nopyenv"; then \
    cat "$f.nopyenv" > "$f"; \
    else \
    echo "WARNING: $f left unchanged; pyenv removal would not parse"; \
    fi; \
    rm -f "$f.nopyenv"; \
    done

# The strip above is a build-time edit, and the base image undoes it at runtime:
# its /dockerstartup/custom_startup.sh chain appends the pyenv setup back into
# ~/.bashrc on every container start, which vnc_startup.sh invokes. Racing a
# background process is fragile, so answer the call instead of chasing the
# caller. `eval "$(pyenv init -)"` and `eval "$(pyenv virtualenv-init -)"` -- the
# pair responsible for the two "pyenv: command not found" lines per terminal --
# both evaluate to nothing and succeed.
#
# pyenv is missing rather than broken: it lives in /home/kasm-default-profile,
# which is only copied into $HOME by kasm_default_profile.sh, and this image
# overrides ENTRYPOINT to skip that. If that is ever restored, the real pyenv
# takes over here automatically.
RUN printf '%s\n' \
    '#!/bin/sh' \
    '# No-op stand-in; see the Dockerfile for why. Defers to a real pyenv.' \
    '[ -x "$HOME/.pyenv/bin/pyenv" ] && exec "$HOME/.pyenv/bin/pyenv" "$@"' \
    'exit 0' \
    > /usr/local/bin/pyenv && \
    chmod +x /usr/local/bin/pyenv

# Create cache directory for conda with proper ownership
RUN mkdir -p /home/kasm-user/.cache && chown -R kasm-user:kasm-user /home/kasm-user/.cache

# Stop VS Code prompting "Choose password for new keyring" on first launch.
#
# VS Code stores secrets through libsecret, which asks the Secret Service to
# unlock a keyring; with gnome-keyring-daemon running in the session and no
# keyring yet created, that surfaces as a modal password prompt before the user
# has done anything. In an ephemeral container desktop there is nothing durable
# to protect, and the prompt blocks the window.
#
# "basic" switches VS Code to its own obfuscated file store, matching what Kasm
# already does for Chrome (--password-store=basic in its google-chrome wrapper).
# argv.json is VS Code's documented runtime-argument file and stays editable, so
# a user who wants the keyring can revert it.
RUN mkdir -p /home/kasm-user/.vscode && \
    printf '{\n  "password-store": "basic"\n}\n' > /home/kasm-user/.vscode/argv.json && \
    chown -R kasm-user:kasm-user /home/kasm-user/.vscode

# =============================================================================
# Switch to kasm-user for User-Space Installations
# =============================================================================
USER kasm-user

# =============================================================================
# AI CLI Tools Installation
# =============================================================================
# Install Claude Code, OpenAI Codex, and Google Gemini CLI
RUN npm config set prefix /home/kasm-user/.npm-global && \
    export PATH=/home/kasm-user/.npm-global/bin:$PATH && \
    npm install -g @anthropic-ai/claude-code @google/gemini-cli @openai/codex && \
    npm cache clean --force

# Install OpenCode (https://opencode.ai/)
# --no-modify-path is required: the installer otherwise hangs the Docker build
RUN curl -fsSL https://opencode.ai/install | bash -s -- --no-modify-path

ENV PATH="/home/kasm-user/.npm-global/bin:/home/kasm-user/.opencode/bin:${PATH}"

# =============================================================================
# Miniconda and Mamba Installation
# =============================================================================
# Install Miniconda package manager and mamba for faster dependency resolution
RUN curl -fsSL -o /tmp/Miniconda3-latest-Linux-x86_64.sh \
    https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh \
    && bash /tmp/Miniconda3-latest-Linux-x86_64.sh -b -p /home/kasm-user/miniconda3 \
    && rm /tmp/Miniconda3-latest-Linux-x86_64.sh \
    && /home/kasm-user/miniconda3/bin/conda init bash

ENV PATH="/home/kasm-user/miniconda3/bin:${PATH}"

# Install mamba using conda (use classic solver with no-plugins flag)
RUN /home/kasm-user/miniconda3/bin/conda --no-plugins install -y --solver=classic -c conda-forge mamba && \
    /home/kasm-user/miniconda3/bin/conda clean -afy

# =============================================================================
# Container Startup
# =============================================================================
# Default working directory is the home directory. The data-store WORKDIR
# above only needs to exist for the CSI driver's mount path (set separately
# in the DE/K8s config), not to be where the session actually lands.
WORKDIR /home/kasm-user

ENTRYPOINT [ "/dockerstartup/vnc_startup.sh" ]
