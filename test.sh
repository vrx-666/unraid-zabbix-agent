#!/bin/bash
# Check the plugin without Unraid: the agent download matches its SHA256, the config passes
# "zabbix_agentd -T", every key of the "Linux by Zabbix agent" template is allowed and
# everything dangerous is denied. Needs docker and python3.
set -euo pipefail
cd "$(dirname "$0")"
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

# Files and download from the .plg (entities resolved by the XML parser).
python3 -I - zabbix-agent.plg "$W" <<'EOF'
import sys, os, xml.etree.ElementTree as ET
plg, out = sys.argv[1], sys.argv[2]
for f in ET.parse(plg).getroot().iter("FILE"):
    name = f.get("Name", "")
    if f.find("URL") is not None:
        open(f"{out}/download", "w").write(f"{f.find('URL').text.strip()} {f.find('SHA256').text.strip()}\n")
    elif name.startswith("/etc/zabbix/"):
        os.makedirs(f"{out}/etc/zabbix", exist_ok=True)
        open(out + name, "w").write(f.find("INLINE").text.lstrip())
EOF
read -r URL SHA < "$W/download"
curl -fsSL --retry 3 -o "$W/agent.tar.gz" "$URL"
echo "$SHA  $W/agent.tar.gz" | sha256sum -c
tar -xzf "$W/agent.tar.gz" -C "$W" ./sbin/zabbix_agentd ./bin/zabbix_get

# Template keys, with discovery macros replaced by real names inside the container.
curl -fsSL --retry 3 https://raw.githubusercontent.com/zabbix/zabbix/release/7.0/templates/os/linux/template_os_linux.yaml \
  | sed -nE "s/^ +key: '?([^']*)'?$/\1/p" | grep -v '^zabbix\[' \
  | sed -e 's/{#IFNAME}/lo/g' -e 's/{#DEVNAME}/loop0/g' -e 's/{#FSNAME}/\//g' | sort -u > "$W/allowed"
[ "$(wc -l < "$W/allowed")" -gt 50 ] || { echo "Template keys not found" >&2; exit 1; }
printf '%s\n' unraid.array.state unraid.disks 'unraid.smart.health[sda]' >> "$W/allowed"

cat > "$W/denied" <<'EOF'
system.run[id]
system.run[id,nowait]
vfs.file.contents[/etc/shadow]
vfs.file.contents[/sys/../etc/shadow]
vfs.file.contents["/sys/../etc/shadow"]
vfs.file.contents[/sys/block/../../etc/shadow]
vfs.file.contents[/sys/class/net/lo/../../../../etc/shadow]
vfs.file.contents[/sys/block/x/../../../proc/self/stat]
vfs.file.contents["/sys/class/net/lo/../../../../proc/self/net/../stat"]
vfs.fs.size[/,../x]
system.cpu.util[,,../x]
system.cpu.util[,,,../x]
vfs.file.cksum[/etc/shadow,sha256]
vfs.file.get[/etc/passwd]
vfs.file.regexp[/etc/shadow,root]
vfs.dir.get[/]
web.page.get[127.0.0.1]
net.tcp.port[127.0.0.1,22]
proc.get
unraid.smart.health[../../etc/shadow]
EOF

# Fake smartctl that records its argument count: unraid.smart.health must hand the device over as ONE argument,
# so a parameter like "sda -s off" cannot reach smartctl as extra options (CA review, PR #3).
printf '#!/bin/sh\necho $# > /tmp/smartctl.argc\n' > "$W/smartctl"; chmod 755 "$W/smartctl"

# Test settings instead of the generated ones (no PSK, so zabbix_get can connect).
mkdir -p "$W/boot"
printf 'Server=127.0.0.1\nHostname=test\n' > "$W/boot/zabbix_agentd.conf"

docker run --rm -v "$W:/w:ro" -v "$W/boot:/boot/config/plugins/zabbix-agent:ro" -v "$W/etc/zabbix:/etc/zabbix:ro" \
  debian:trixie-slim bash -c '
  set -e
  cp /w/smartctl /usr/local/bin/smartctl
  /w/sbin/zabbix_agentd -T -c /etc/zabbix/zabbix_agentd.conf
  /w/sbin/zabbix_agentd -c /etc/zabbix/zabbix_agentd.conf
  sleep 2
  # Template items computed on the server (dependent, calculated) are no agent keys: skip them.
  printf "LogType=console\nHostname=t\nServer=127.0.0.1\n" > /tmp/open.conf
  while read -r k; do
    case "$k" in unraid.*) echo "$k";; *) /w/sbin/zabbix_agentd -c /tmp/open.conf -t "$k" 2>&1 | grep -q "Unsupported item key" || echo "$k";; esac
  done < /w/allowed > /tmp/allowed
  fail=0
  check() {  # $1 = allowed|denied, keys on stdin
    while read -r k; do
      r=$(/w/bin/zabbix_get -s 127.0.0.1 -k "$k" 2>&1 || true)
      if [[ "$r" == *"Unsupported item key"* ]]; then got=denied; else got=allowed; fi
      [ "$got" = "$1" ] || { echo "FAIL ($1 expected): $k -> ${r:0:80}"; fail=1; }
    done
  }
  check allowed < /tmp/allowed
  check denied < /w/denied
  /w/bin/zabbix_get -s 127.0.0.1 -k "unraid.smart.health[sda -s off]" >/dev/null 2>&1 || true
  [ "$(cat /tmp/smartctl.argc 2>/dev/null)" = 4 ] || { echo "FAIL: unraid.smart.health passes extra arguments to smartctl"; fail=1; }
  [ $fail = 0 ] && echo "PASS: $(wc -l < /tmp/allowed) allowed, $(wc -l < /w/denied) denied"
  exit $fail'
