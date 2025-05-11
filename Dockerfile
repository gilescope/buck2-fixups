FROM rust:1.86-bullseye
RUN rustup install nightly-2025-02-16
RUN cargo +nightly-2025-02-16 install --git https://github.com/facebook/buck2.git buck2

RUN cargo +nightly-2025-02-16 install --locked --git https://github.com/facebookincubator/reindeer reindeer
RUN apt-get update && apt-get install -y clang lld protobuf-compiler build-essential \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -m -s /bin/bash builder

WORKDIR /home/builder
ENV CARGO_HOME=/home/builder/.cargo/
COPY . .
# RUN sudo chown -R builder:builder /home/builder

# USER builder
CMD ["bash"]
