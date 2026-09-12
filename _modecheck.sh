#!/usr/bin/env bash
# Does this filesystem/location actually honour POSIX mode bits (umask)?
set -uo pipefail
D="$(mktemp -d)"
probe="$D/probe.conf"
( umask 077; : > "$probe" )
echo "probe path : $probe"
echo "umask now  : $(umask)"
echo "stat -c %a : $(stat -c '%a' "$probe" 2>&1)"
echo "stat -f %Lp: $(stat -f '%Lp' "$probe" 2>&1)"

# Same test in the workspace (Dropbox) directory rather than /tmp.
W="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
probe2="$W/_mode_probe.conf"
( umask 077; : > "$probe2" )
echo "workspace  : $(stat -c '%a' "$probe2" 2>&1)"
chmod 600 "$probe2" 2>/dev/null
echo "after chmod: $(stat -c '%a' "$probe2" 2>&1)"
rm -f "$probe2"
rm -rf "$D"
