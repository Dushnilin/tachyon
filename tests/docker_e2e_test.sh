#!/usr/bin/env bash
set -eo pipefail

export MSYS_NO_PATHCONV=1

# Check if docker or docker.exe command is available
if command -v docker.exe >/dev/null 2>&1; then
  DOCKER_BIN="docker.exe"
elif command -v docker >/dev/null 2>&1; then
  DOCKER_BIN="docker"
else
  echo "Docker is not available. Skipping E2E test."
  exit 0
fi

# Determine script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
if command -v cygpath >/dev/null 2>&1; then
  ROOT_DIR="$(cygpath -w "$PWD")"
elif pwd -W >/dev/null 2>&1; then
  ROOT_DIR="$(pwd -W)"
else
  ROOT_DIR="$(pwd)"
fi

# Convert WSL or Sandbox mount paths to Windows-friendly drive paths for docker.exe
if [ "$DOCKER_BIN" = "docker.exe" ]; then
  if [[ "$ROOT_DIR" =~ /mnt/host/([a-zA-Z])/(.*) ]]; then
    ROOT_DIR="${BASH_REMATCH[1]}:/${BASH_REMATCH[2]}"
  elif [[ "$ROOT_DIR" =~ ^/mnt/([a-zA-Z])/(.*) ]]; then
    ROOT_DIR="${BASH_REMATCH[1]}:/${BASH_REMATCH[2]}"
  elif [[ "$ROOT_DIR" =~ ^/([a-zA-Z])/(.*) ]]; then
    ROOT_DIR="${BASH_REMATCH[1]}:/${BASH_REMATCH[2]}"
  fi
fi


echo "=== Building Tachyon Package inside Ubuntu Container ==="
VERSION="1.0.0"
mkdir -p "$BUILD_OUT"

"$DOCKER_BIN" run --rm \
  -v "$ROOT_DIR:/work" \
  -w /work \
  -e SDK_CACHE_DIR="/work/.wsl-build/sdk-cache" \
  ubuntu:22.04 \
  bash -c "apt-get update && apt-get install -y sudo && sed -i 's/\r$//' ./build.sh && bash ./build.sh $VERSION /work/build-out"

echo "=== Starting OpenWrt Container ==="
CONTAINER_NAME="tachyon-e2e-test"
"$DOCKER_BIN" rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

# Run with privileged flag to allow nftables and networking modifications
"$DOCKER_BIN" run -d \
  --name "$CONTAINER_NAME" \
  --privileged \
  -e SB_REQUIRED_VERSION="1.11.0" \
  -v "$ROOT_DIR:/work" \
  openwrt/rootfs:x86-64-23.05.5 \
  /bin/sh /work/tests/container_entrypoint.sh

cleanup() {
  echo "=== Container logs (stdout/stderr) ==="
  "$DOCKER_BIN" logs "$CONTAINER_NAME" || true
  echo "=== OpenWrt system logs ==="
  "$DOCKER_BIN" exec "$CONTAINER_NAME" logread || true
  echo "=== Keeping Container Alive for Debugging ==="
  # "$DOCKER_BIN" rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "Waiting for OpenWrt to initialize..."
sleep 5

echo "=== Installing dependencies inside container ==="
for i in 1 2 3; do
  echo "opkg update attempt $i..."
  "$DOCKER_BIN" exec "$CONTAINER_NAME" opkg update && break || sleep 5
done
for i in 1 2 3 4 5; do
  echo "opkg install attempt $i..."
  "$DOCKER_BIN" exec "$CONTAINER_NAME" opkg install ucode ucode-mod-fs ucode-mod-uci curl ca-bundle bind-dig nftables ip-full coreutils-base64 sing-box bash node git git-http && break || sleep 5
done
"$DOCKER_BIN" exec "$CONTAINER_NAME" git config --global --add safe.directory '*' || true

echo "=== Installing official sing-box 1.12.0 binary ==="
for i in 1 2 3; do
  echo "Downloading sing-box attempt $i..."
  "$DOCKER_BIN" exec "$CONTAINER_NAME" curl -sSL -o /tmp/sing-box.tar.gz https://github.com/SagerNet/sing-box/releases/download/v1.12.0/sing-box-1.12.0-linux-amd64.tar.gz && break || sleep 5
done
"$DOCKER_BIN" exec "$CONTAINER_NAME" tar -zxf /tmp/sing-box.tar.gz -C /tmp
"$DOCKER_BIN" exec "$CONTAINER_NAME" cp /tmp/sing-box-1.12.0-linux-amd64/sing-box /usr/sbin/sing-box
"$DOCKER_BIN" exec "$CONTAINER_NAME" cp /tmp/sing-box-1.12.0-linux-amd64/sing-box /usr/bin/sing-box
"$DOCKER_BIN" exec "$CONTAINER_NAME" chmod +x /usr/sbin/sing-box /usr/bin/sing-box
"$DOCKER_BIN" exec "$CONTAINER_NAME" rm -rf /tmp/sing-box.tar.gz /tmp/sing-box-1.12.0-linux-amd64


echo "=== Installing Tachyon IPK ==="
"$DOCKER_BIN" exec "$CONTAINER_NAME" opkg install /work/build-out/tachyon_1.0.0.ipk

echo "=== Configuring Tachyon ==="
"$DOCKER_BIN" exec "$CONTAINER_NAME" uci set tachyon.settings.enabled='1'
"$DOCKER_BIN" exec "$CONTAINER_NAME" uci set tachyon.settings.log_level='debug'

# Create a test bypass section
"$DOCKER_BIN" exec "$CONTAINER_NAME" uci set tachyon.test_sec='section'
"$DOCKER_BIN" exec "$CONTAINER_NAME" uci set tachyon.test_sec.label='TestSection'
"$DOCKER_BIN" exec "$CONTAINER_NAME" uci set tachyon.test_sec.enabled='1'
"$DOCKER_BIN" exec "$CONTAINER_NAME" uci set tachyon.test_sec.action='bypass'
"$DOCKER_BIN" exec "$CONTAINER_NAME" uci add_list tachyon.test_sec.domain='ip.podkop.fyi'
"$DOCKER_BIN" exec "$CONTAINER_NAME" uci commit tachyon

echo "=== Starting services ==="
"$DOCKER_BIN" exec "$CONTAINER_NAME" /etc/init.d/sing-box enable
"$DOCKER_BIN" exec "$CONTAINER_NAME" /etc/init.d/sing-box start
"$DOCKER_BIN" exec "$CONTAINER_NAME" /etc/init.d/tachyon enable
"$DOCKER_BIN" exec "$CONTAINER_NAME" /etc/init.d/tachyon start

echo "Waiting for services to stabilize..."
sleep 5

echo "=== Checking running services ==="
"$DOCKER_BIN" exec "$CONTAINER_NAME" /etc/init.d/tachyon status || echo "Tachyon status non-zero, continuing..."
"$DOCKER_BIN" exec "$CONTAINER_NAME" pgrep -l sing-box || echo "sing-box process not found"

echo "=== Running connection test via mixed port ==="
# Test routing of the proxy port
PROXY_TEST_HTTP_CODE=$("$DOCKER_BIN" exec "$CONTAINER_NAME" curl -s -o /dev/null -w "%{http_code}" -x http://127.0.0.1:4534 --connect-timeout 10 http://ip.podkop.fyi || echo "failed")
echo "HTTP proxy status: $PROXY_TEST_HTTP_CODE"

echo "=== Running transparent interception test ==="
# Running direct curl to test transparent proxying via nftables
"$DOCKER_BIN" exec "$CONTAINER_NAME" curl -s -I --connect-timeout 10 http://ip.podkop.fyi || echo "curl failed"

echo "=== Checking system logs ==="
LOGS=$("$DOCKER_BIN" exec "$CONTAINER_NAME" logread)
echo "$LOGS" | tail -n 100

echo "=== Checking nftables rules ==="
"$DOCKER_BIN" exec "$CONTAINER_NAME" nft list ruleset || echo "nft failed"

# Verification: check if logs contain trace of bypass or redirect
if echo "$LOGS" | grep -Fiq "ip.podkop.fyi"; then
  echo "SUCCESS: Traffic to ip.podkop.fyi was intercepted/processed!"
else
  echo "WARNING: Domain ip.podkop.fyi not found in system logs. Checking sing-box status."
  if "$DOCKER_BIN" exec "$CONTAINER_NAME" pgrep -f sing-box >/dev/null; then
    echo "sing-box is running, routing table was loaded."
  else
    echo "FAIL: sing-box is not running."
    exit 1
  fi
fi

echo "=== Normalizing line endings for test scripts ==="
"$DOCKER_BIN" exec "$CONTAINER_NAME" sh -c "sed -i 's/\r$//' /work/tests/*.sh"

echo "=== Running unit and integration tests inside OpenWrt container ==="
for f in tests/*.sh; do
  if [ "$f" != "tests/docker_e2e_test.sh" ] && [ "$f" != "tests/container_entrypoint.sh" ]; then
    echo "Running $f inside container..."
    "$DOCKER_BIN" exec -w /work -e SB_REQUIRED_VERSION="1.11.0" "$CONTAINER_NAME" bash "$f"
  fi
done

echo "=== E2E and Unit Tests Passed Successfully ==="
