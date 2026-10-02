#!/usr/bin/env sh

# This is the Docker entrypoint, not a test. It overwrites /etc/config/network
# and disables the firewall, which on a real OpenWrt box drops the LAN
# addressing and the guest stops answering on the network. tests/run_all.sh
# skips it for that reason; refuse to run at all when there is no container
# around, so a stray `for t in tests/*.sh` cannot take a router down.
if [ ! -e /.dockerenv ] && [ ! -e /run/.containerenv ] && ! grep -qsE '(docker|containerd|lxc)' /proc/1/cgroup; then
  echo "container_entrypoint.sh: refusing to run outside a container" >&2
  exit 1
fi

# Capture current IP, netmask, and gateway of eth0 (Docker's configuration) safely
ETH0_IP=$(ip -o -4 addr show eth0 | head -n 1 | awk '{print $4}' | cut -d/ -f1)
ETH0_NETMASK_LEN=$(ip -o -4 addr show eth0 | head -n 1 | awk '{print $4}' | cut -d/ -f2)
GATEWAY=$(ip -4 route show default | head -n 1 | awk '{print $3}')

echo "=== Entrypoint: Captured IP=${ETH0_IP}/${ETH0_NETMASK_LEN}, Gateway=${GATEWAY} ==="

if [ -n "$ETH0_IP" ] && [ -n "$GATEWAY" ]; then
  # Directly overwrite /etc/config/network with a clean static config on eth0
  cat <<EOF > /etc/config/network
config interface 'loopback'
	option device 'lo'
	option proto 'static'
	option ipaddr '127.0.0.1'
	option netmask '255.0.0.0'

config globals 'globals'
	option ula_prefix 'fd1d:8f1c:37e7::/48'

config interface 'lan'
	option device 'eth0'
	option proto 'static'
	option ipaddr '${ETH0_IP}/${ETH0_NETMASK_LEN}'
	option gateway '${GATEWAY}'
	list dns '${GATEWAY}'
EOF
  echo "=== Entrypoint: Network config written directly to /etc/config/network ==="
else
  echo "=== Entrypoint: Failed to capture network settings, keeping default config ==="
fi

# Disable firewall service to avoid blocking rulesets
if [ -e /etc/init.d/firewall ]; then
  /etc/init.d/firewall disable
fi

# Disable opkg signature check to bypass transient sig download failures
if [ -e /etc/opkg.conf ]; then
  sed -i 's/option check_signature/# option check_signature/g' /etc/opkg.conf
  echo "=== Entrypoint: Disabled opkg signature check ==="
fi

# Execute original OpenWrt init
exec /sbin/init
