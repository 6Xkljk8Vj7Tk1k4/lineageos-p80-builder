# Build environment for the LineageOS GSI for the Teclast P80, per the LineageOS build guide.
FROM ubuntu:20.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

RUN apt-get update && apt-get install -y \
    bc bison build-essential ccache curl flex g++-multilib gcc-multilib git \
    git-lfs gnupg gperf imagemagick protobuf-compiler python3-protobuf \
    lib32readline-dev lib32z1-dev libdw-dev libelf-dev libgnutls28-dev lz4 \
    libsdl1.2-dev libssl-dev libxml2 libxml2-utils lzop pngcrush rsync \
    schedtool squashfs-tools xsltproc xxd zip zlib1g-dev \
    python3 python-is-python3 wget unzip brotli p7zip-full e2fsprogs \
    openjdk-17-jdk \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -m -s /bin/bash builder
USER builder
WORKDIR /home/builder/android/lineage

RUN mkdir -p /home/builder/bin && \
    curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo > /home/builder/bin/repo && \
    chmod a+x /home/builder/bin/repo

ENV PATH="/home/builder/bin:${PATH}"
ENV USE_CCACHE=1
ENV CCACHE_EXEC=/usr/bin/ccache
ENV CCACHE_DIR=/home/builder/ccache

RUN git config --global user.email "builder@localhost" && \
    git config --global user.name "LineageOS builder" && \
    git config --global color.ui false && \
    # bind-mounted trees are owned by a different uid than "builder"
    git config --global --add safe.directory "*"

# The image is only the environment: build.sh, manifests/ and patches/ come from the
# checkout bind-mounted at /home/builder/repo, so `git pull` needs no image rebuild.
ENTRYPOINT ["/home/builder/repo/build.sh"]
