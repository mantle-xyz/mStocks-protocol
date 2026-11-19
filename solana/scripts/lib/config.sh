# Network configuration for the bash scripts (sourced). NETWORK=mainnet|testnet selects
# config.<network>.toml next to scripts/ (NETWORK may also be a path to a .toml file); `cfg <key>`
# reads a dotted key ("" when unset). Scripts that need a network call `require_network`.
CONFIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

require_network() {
  case ${NETWORK:-} in
    "") echo "set NETWORK=mainnet or NETWORK=testnet" >&2; exit 1 ;;
    /*.toml) CONFIG_FILE=$NETWORK ;;
    *.toml) CONFIG_FILE=${CALLER:-$PWD}/$NETWORK ;;   # relative to the caller's directory (CALLER: before a cd)
    *) CONFIG_FILE=$CONFIG_DIR/config.$NETWORK.toml ;;
  esac
  [ -f "$CONFIG_FILE" ] || { echo "no $CONFIG_FILE for NETWORK=$NETWORK" >&2; exit 1; }
  echo "[$NETWORK] config $CONFIG_FILE" >&2
}

cfg() { # dotted key → value ("" when unset)
  python3 -I -c 'import sys, tomllib
d = tomllib.load(open(sys.argv[1], "rb"))
for k in sys.argv[2].split("."): d = d.get(k, "") if isinstance(d, dict) else ""
print(d)' "$CONFIG_FILE" "$1"
}

cfg_required() { # like cfg, but an empty value is an error
  local v; v=$(cfg "$1")
  [ -n "$v" ] || { echo "$1 is empty in $CONFIG_FILE" >&2; exit 1; }
  printf '%s\n' "$v"
}
