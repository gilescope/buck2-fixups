#!/usr/bin/env bash

reindeer buckify
docker build -t buck2-linux .
echo "enter bash shell and run: reindeer buckify && buck2 build //..."
echo "(this allows the buck deamon to stay up while you run several times)"
docker run -it \
  -v ./buck-out-docker:/home/builder/buck-out \
  -v ./Cargo.toml:/home/builder/Cargo.toml \
  -v ./Cargo.lock:/home/builder/Cargo.lock \
  -v ./BUCK:/home/builder/BUCK \
  buck2-linux
