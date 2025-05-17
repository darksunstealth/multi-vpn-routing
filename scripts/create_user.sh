# Create the WireGuard config directory
mkdir -p "$WG_CONF_DIR"

# Safe escaping for sed replacements
safe() { printf '%s' "$1" | sed 's/[\/&]/\\&/g'; }

# Copy template and secure permissions
sudo cp "$WG_TEMPLATE" "$WG_CONF_DIR/$WIREGUARD_NAME.conf"
sudo chmod 600 "$WG_CONF_DIR/$WIREGUARD_NAME.conf"

# Replace template placeholders with actual values
sudo sed -i -e "s@<privatekey>@$(safe "$PRIVATE_KEY")@" \
            -e "s@<publickey>@$(safe "$PUBKEY")@" \
            -e "s@<allowedips>@$(safe "$CLIENT_ALLOWED_IP")@" \
            -e "s@<listenport>@$(safe "$LISTEN_PORT")@" \
            -e "s@<wg0>@$(safe "$WIREGUARD_NAME")@" \
  "$WG_CONF_DIR/$WIREGUARD_NAME.conf"

WG_CONF="$WG_CONF_DIR/$WIREGUARD_NAME.conf"

# === Create namespace and veth pair ===
sudo ip netns add "$NS"
sudo ip link add "$VETH_ROOT" type veth peer name "$VETH_NS"
sudo ip link set "$VETH_NS" netns "$NS"

# Assign IPs to both sides of the veth
sudo ip addr add "$BRIDGE_IP/30" dev "$VETH_ROOT"
sudo ip link set "$VETH_ROOT" up

sudo ip netns exec "$NS" ip addr add "$NS_IP/30" dev "$VETH_NS"
sudo ip netns exec "$NS" ip link set "$VETH_NS" up
sudo ip netns exec "$NS" ip link set lo up

# Default route from namespace via the bridge IP
sudo ip netns exec "$NS" ip route add default via "$BRIDGE_IP"

# === Start WireGuard inside the namespace ===
sudo ip netns exec "$NS" wg-quick up "$WG_CONF"
sudo ip netns exec "$NS" ip addr add "$SERVER_IP/24" dev "$WIREGUARD_NAME"

# === Host NAT and port forwarding rules ===

# Masquerade traffic leaving through the public interface
sudo iptables -t nat -A POSTROUTING -s "$CLIENT_IP" -o "$DEV_OUT" -j MASQUERADE

# Masquerade traffic from the client into WireGuard
sudo iptables -t nat -A POSTROUTING -s "$CLIENT_IP" -o "$WIREGUARD_NAME" -j MASQUERADE

# Port forwarding (DNAT) from host IP to namespace IP
sudo iptables -t nat -A PREROUTING -p udp -d 51.68.26.231 --dport $LISTEN_PORT -j DNAT --to-destination $NS_IP:$LISTEN_PORT

# Accept forwarded packets
sudo iptables -A FORWARD -s "$NS_IP" -o "$DEV_OUT" -j ACCEPT
sudo iptables -A FORWARD -d "$NS_IP" -m state --state RELATED,ESTABLISHED -j ACCEPT 
sudo iptables -A FORWARD -p udp -d "$NS_IP" --dport $LISTEN_PORT -j ACCEPT

# ✅ Additional related state rule
sudo iptables -A FORWARD -d "$NS_IP" -m state --state RELATED,ESTABLISHED -j ACCEPT

# === NAT inside the namespace ===
sudo ip netns exec "$NS" iptables -t nat -A POSTROUTING -s "$CLIENT_IP" -o "$VETH_NS" -j MASQUERADE

# Fallback NAT from namespace to host's public interface
sudo iptables -t nat -A POSTROUTING -s "$NS_IP" -o ens3 -j MASQUERADE

# Set custom DNS resolver inside namespace
sudo ip netns exec "$NS" bash -c 'echo -e "nameserver 1.1.1.1\nnameserver 8.8.8.8" > /etc/resolv.conf'
