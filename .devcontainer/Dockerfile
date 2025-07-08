# Simplified Dockerfile for quick setup
FROM hexpm/elixir:1.14.5-erlang-25.3.2-ubuntu-jammy-20230126

# Install minimal dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    git \
    curl \
    tesseract-ocr \
    tesseract-ocr-por \
    ffmpeg \
    fish \
    sudo \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user
ARG USERNAME=vscode
ARG USER_UID=1000
ARG USER_GID=$USER_UID

RUN groupadd --gid $USER_GID $USERNAME \
    && useradd --uid $USER_UID --gid $USER_GID -m $USERNAME \
    && echo $USERNAME ALL=\(root\) NOPASSWD:ALL > /etc/sudoers.d/$USERNAME \
    && chmod 0440 /etc/sudoers.d/$USERNAME

USER $USERNAME

# Install Elixir tools
RUN mix local.hex --force && \
    mix local.rebar --force

# Set working directory
WORKDIR /workspaces/plate_reader_system

# Set fish as default shell
RUN sudo chsh -s /usr/bin/fish $USERNAME

CMD ["fish"]