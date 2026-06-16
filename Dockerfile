FROM ubuntu:26.04@sha256:f3d28607ddd78734bb7f71f117f3c6706c666b8b76cbff7c9ff6e5718d46ff64

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Europe/Berlin \
    PUID=1000 \
    PGID=1000 \
    # Tool selection — order defines menu order, first entry is the default
    TOOLS=opencode,omp \
    # Pin tool data dirs explicitly so subprocesses find language toolchains reliably
    CARGO_HOME=/home/agent/.cargo \
    RUSTUP_HOME=/home/agent/.rustup \
    # All user tool bins in PATH — inherited by every subprocess after exec gosu
    PATH="/home/agent/.local/bin:/home/agent/.cargo/bin:/home/agent/.opencode/bin:${PATH}"


# Install basic tools
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    gosu \
    openssh-client \
    ripgrep \
    tzdata \
    && apt-get autoremove -y \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Node.js — system-wide, available for workspace projects
RUN apt-get update && apt-get install -y --no-install-recommends --no-install-suggests nodejs npm \
    && apt-get autoremove -y \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Ubuntu 26.04 ships with a default 'ubuntu' user at 1000:1000 — reuse it
RUN usermod -l agent ubuntu && \
    groupmod -n agent ubuntu && \
    usermod -d /home/agent -m agent

RUN mkdir -p /home/agent/.config/opencode \
    /home/agent/.local/share/opencode \
    /home/agent/.omp/agent \
    /home/agent/.omp/logs \
    /home/agent/workspace && \
    chown -R agent:agent /home/agent

# Switch to agent user — HOME is now /home/agent, installs land in the right place
USER agent
WORKDIR /home/agent

# opencode
RUN curl -fsSL https://opencode.ai/install | bash

# omp
RUN curl -fsSL https://omp.sh/install | sh

# Rust — --no-modify-path because PATH is managed via ENV above
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path

# uv + Python
# ARG here (not at top) so changing PYTHON_VERSION only busts cache from this layer onward
ARG PYTHON_VERSION=3.13
ENV PYTHON_VERSION=${PYTHON_VERSION}
RUN curl -LsSf https://astral.sh/uv/install.sh | sh \
    && uv python install ${PYTHON_VERSION}

USER root
WORKDIR /

COPY --chmod=744 entrypoint.sh /

ENTRYPOINT ["./entrypoint.sh"]
