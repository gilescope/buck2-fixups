#!/usr/bin/env bash

reindeer buckify
docker build -t buck2-linux .
echo "enter bash shell and run: reindeer buckify && buck2 build //..."
echo "(this allows the buck deamon to stay up while you run several times)"
docker run -it \
  -v ./buck-out-docker:/home/builder/buck-out \
  -v ./third-party/Cargo.toml:/home/builder/third-party/Cargo.toml \
  -v ./third-party/Cargo.lock:/home/builder/third-party/Cargo.lock \
  -v ./third-party/BUCK:/home/builder/third-party/BUCK \
  buck2-linux
