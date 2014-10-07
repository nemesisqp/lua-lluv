#! /bin/bash

source .travis/platform.sh

cd $TRAVIS_BUILD_DIR

git clone https://github.com/joyent/libuv.git

cd libuv

mkdir -p build
git clone http://git.chromium.org/external/gyp.git build/gyp

if [ "$PLATFORM" == "macosx" ]; then
  ./gyp_uv.py -f xcode && xcodebuild -ARCHS="x86_64" -project uv.xcodeproj -configuration Release -target All;
else
  ./gyp_uv.py -f make && BUILDTYPE=Release CFLAGS=-fPIC make -C build;
fi

cd $TRAVIS_BUILD_DIR
