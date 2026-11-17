#!/usr/bin/env bash
# Dumps the mainnet programs used by the tests into tests/fixtures/ (gitignored): Token-2022, and
# Squads v4 with its program config account (for local-squads-e2e.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p tests/fixtures
solana program dump -u m TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb tests/fixtures/token2022.so
solana program dump -u m SQDS4ep65T869zMMBKyuUq6aD6EgTu8psMjkvj52pCf tests/fixtures/squads_v4.so
solana account -u m BSTq9w3kZwNwpBXJEvTZz2G9ZTNyKBvoSeXMvwb4cNZr --output json -o tests/fixtures/squads_program_config.json >/dev/null
