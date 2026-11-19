# EVM signer for cast / forge from a key file (sourced by the Mantle-side scripts). A Foundry keystore
# (encrypted JSON, e.g. from `cast wallet import`) keeps the key out of the process arguments; its
# password is read from the file named by ETH_PASSWORD, else asked for. A raw hex private key also
# works, but ends up in the arguments of cast / forge, where other users of the machine can read it
# (ps), so on mainnet use a keystore.
#   set_signer <key file>; cast send … "${SIGNER[@]}"
set_signer() {
  [ -f "$1" ] || { echo "error: no key file $1" >&2; exit 1; }
  if [ "$(head -c1 "$1")" = "{" ]; then
    SIGNER=(--keystore "$1")
  else
    SIGNER=(--private-key "$(tr -d '[:space:]' <"$1")")
    [ "${NETWORK:-}" != mainnet ] || echo "warning: $1 is a raw private key, passed to cast/forge on the command line; a Foundry keystore avoids that" >&2
  fi
}
