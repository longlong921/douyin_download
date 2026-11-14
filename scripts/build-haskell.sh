#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p build
# Uses the GHC package database, suitable for distro-packaged dependencies.
ghc -O1 -threaded -rtsopts -ihaskell/src -outputdir build haskell/src/Main.hs -o build/douyin-download
ghc -O0 -threaded -ihaskell/src -outputdir build/test haskell/test/Spec.hs -o build/security-tests
build/security-tests
