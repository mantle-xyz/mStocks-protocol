#!/usr/bin/env bash
# Dumps the mainnet Token-2022 program used by the tests into tests/fixtures/ (gitignored).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p tests/fixtures
solana program dump -u m TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb tests/fixtures/token2022.so
