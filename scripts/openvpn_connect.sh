# Create namespace if it doesn't exist
sudo ip netns add "$NS" 2>/dev/null || true

# Create veth pair and assign each end to its namespace
sudo ip link add "$VETH_ROOT" type veth peer name "$VETH_NS"
sudo ip link set "$VETH_NS" netns "$NS"
sudo ip link set "$VETH_ROOT" netns "$NS_WIRE"

# Assign IP addresses to each end of the veth pair
sudo ip netns exec "$NS_WIRE" ip addr add "$BRIDGE_IP/24" dev "$VETH_ROOT"
sudo ip netns exec "$NS_WIRE" ip link set "$VETH_ROOT" up
sudo ip netns exec "$NS" ip addr add "$NS_IP/24" dev "$VETH_NS"
sudo ip netns exec "$NS" ip link set "$VETH_NS" up

# Set up NAT for traffic from the internal namespace to the outer one
sudo ip netns exec "$NS_WIRE" iptables -t nat -A POSTROUTING -s "$BRIDGE_IP/24" -o "$VS_WIRE" -j MASQUERADE

# Remove existing default route inside outer namespace (temporary before VPN)
sudo ip netns exec "$NS_WIRE" ip route del default || true

# Configure DNS resolvers for the inner namespace
sudo mkdir -p "/etc/netns/$NS"
RESOLV_PATH="/etc/netns/$NS/resolv.conf"
sudo tee "$RESOLV_PATH" > /dev/null <<EOF
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF

# === Connectivity check before starting VPN ===
if sudo ip netns exec "$NS" ping -c 1 1.1.1.1 >/dev/null 2>&1; then
  echo "✅ Ping to 1.1.1.1 successful"
else
  echo "❌ No connectivity to 1.1.1.1 inside namespace '$NS'"
fi

if sudo ip netns exec "$NS" curl -s --max-time 5 https://ifconfig.me >/dev/null; then
  echo "✅ Namespace '$NS' has internet and working DNS"
else
  echo "⚠️ Unable to access https://ifconfig.me"
fi

# === Start OpenVPN ===
sudo ip netns exec "$NS" bash -c "
  nohup openvpn \
    --config '$OVPN_CFG' \
    --auth-user-pass '$AUTH_FILE' \
    --script-security 2 \
    --log '$LOG' \
    --dev tun1 \
    --persist-tun \
    --persist-key \
  > /dev/null 2>&1 &
"

# === Wait for tun1 to come up and set as default route ===
MAX_RETRIES=15
RETRY_COUNT=0

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
  if sudo ip netns exec "$NS" ip link show tun1 >/dev/null 2>&1; then
    IP_OUT=$(sudo ip netns exec "$NS" curl -s --interface tun1 --max-time 5 ifconfig.me || true)
    if [[ "$IP_OUT" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "🌍 VPN tunnel established via tun1 – Public IP: $IP_OUT"
      sudo ip netns exec "$NS" ip route del default
      sudo ip netns exec "$NS" ip route add default dev tun1 metric 10
      break
    fi
  fi
  echo "⌛ Waiting for VPN to establish... ($RETRY_COUNT/$MAX_RETRIES)"
  sleep 1
  RETRY_COUNT=$((RETRY_COUNT + 1))
done

# === Routing rules ===
sudo ip rule add from "$CLIENT_IP" lookup "$TABLE_NAME"
sudo ip route flush table "$TABLE_NAME" 2>/dev/null || true
sudo ip netns exec "$NS" iptables -t nat -A POSTROUTING -o tun1 -j MASQUERADE
sudo ip route add default via "$NS_IP" dev "$VETH_ROOT" table "$TABLE_NAME"
