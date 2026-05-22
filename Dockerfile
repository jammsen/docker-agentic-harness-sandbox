FROM ubuntu:26.04@sha256:f3d28607ddd78734bb7f71f117f3c6706c666b8b76cbff7c9ff6e5718d46ff64

ENV DEBIAN_FRONTEND=noninteractive

# Add here whatever dev-tools you need
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    git \
    openssh-client \
    nodejs \
    npm \
    && rm -rf /var/lib/apt/lists/*

# # install uv for python development
# COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /usr/local/bin/
# ENV PYTHON_VERSION="3.13"

# Ubuntu 26.04 ships with a default 'ubuntu' user at 1000:1000 — reuse it
RUN usermod -l opencode ubuntu && \
    groupmod -n opencode ubuntu && \
    usermod -d /home/opencode -m opencode

RUN mkdir -p /home/opencode/.config/opencode \
    /home/opencode/.local/share/opencode \
    /home/opencode/workspace && \
    chown -R opencode:opencode /home/opencode

USER opencode
WORKDIR /home/opencode

# install rust via rustup tools as recomended
# RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
# Make cargo/rustup available for subsequent RUN steps
# ENV PATH="/home/opencode/.cargo/bin:/home/opencode/.opencode/bin:$PATH"

RUN curl -fsSL https://opencode.ai/install | bash

ENV PATH="/home/opencode/.opencode/bin:$PATH"
ENV HOME=/home/opencode

# # optional install python in a specific version
# RUN uv python install ${PYTHON_VERSION}

WORKDIR /home/opencode/workspace
ENTRYPOINT ["opencode"]
