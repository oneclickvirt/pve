#!/bin/bash
# from
# https://github.com/oneclickvirt/pve
# 2025.07.04
cd /mnt/wireless || exit 1
for i in {1..6}; do
    INSTALLED_PACKAGES=""
    FAILED_PACKAGES=""
    for deb in *.deb; do
        if apt install -y "./$deb" &>/dev/null; then
            INSTALLED_PACKAGES="$INSTALLED_PACKAGES $deb"
        else
            FAILED_PACKAGES="$FAILED_PACKAGES $deb"
        fi
    done
done
apt-get install -f -y &>/dev/null
if [ -n "$INSTALLED_PACKAGES" ]; then
    echo "Successfully installed packages:$INSTALLED_PACKAGES"
else
    echo "No new packages were installed"
fi
if [ -n "$FAILED_PACKAGES" ]; then
    echo "Failed to install packages:$FAILED_PACKAGES"
fi
rfkill unblock wifi
WIFI_INTERFACE=$(ip a | grep -o "wlp[^:]*" | head -1)
if [ -z "$WIFI_INTERFACE" ]; then
    echo "Could not detect WiFi interface"
    exit 1
fi
echo "Detected WiFi interface: $WIFI_INTERFACE"
while true; do
    read -p "Enter WiFi SSID: " SSID
    read -p "Enter WiFi Password: " PASSWORD
    echo "WiFi Configuration:"
    echo "SSID: $SSID"
    echo "Password: $PASSWORD"
    read -p "Is this correct? (y/n): " CONFIRM
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        break
    else
        echo "Please re-enter the WiFi credentials..."
    fi
done
rm -rf /etc/wpa_supplicant/wpa_supplicant.conf
wpa_passphrase "$SSID" "$PASSWORD" >> /etc/wpa_supplicant/wpa_supplicant.conf
if [ ! -f /etc/systemd/system/wpa_supplicant.service ]; then
    cat > /etc/systemd/system/wpa_supplicant.service << EOF
[Unit]
Description=WPA supplicant
Before=network.target
After=dbus.service
Wants=network.target
IgnoreOnIsolate=true

[Service]
Type=dbus
BusName=fi.w1.wpa_supplicant1
ExecStart=/sbin/wpa_supplicant -u -s -c /etc/wpa_supplicant/wpa_supplicant.conf -i $WIFI_INTERFACE
Restart=always

[Install]
WantedBy=multi-user.target
Alias=dbus-fi.w1.wpa_supplicant1.service
EOF
    systemctl daemon-reload
fi
if ! grep -q "^auto $WIFI_INTERFACE$" /etc/network/interfaces; then
    if grep -q "^iface $WIFI_INTERFACE inet \(auto\|static\|manual\)" /etc/network/interfaces; then
        echo "Found existing iface configuration for $WIFI_INTERFACE, commenting it out..."
        cp /etc/network/interfaces /etc/network/interfaces.backup
        sed -i "/^iface $WIFI_INTERFACE inet \(auto\|static\|manual\)/,/^$/s/^/#/" /etc/network/interfaces
    fi
    cat >> /etc/network/interfaces << EOF
auto $WIFI_INTERFACE
iface wlp2s0 inet dhcp
EOF
    echo "Added network interface configuration for $WIFI_INTERFACE"
else
    echo "Network interface $WIFI_INTERFACE already configured"
fi
ifup $WIFI_INTERFACE
sleep 5
ip link set $WIFI_INTERFACE up
sleep 5
systemctl restart networking
sleep 5
echo "Waiting for network to stabilize..."
sleep 5
if [ ! -f /usr/local/bin/dns-setup.sh ]; then
    cat > /usr/local/bin/dns-setup.sh << 'EOF'
#!/bin/bash
sleep 60
DNS_SERVER="144.144.144.144"
RESOLV_CONF="/etc/resolv.conf"
rfkill unblock wifi
WPA_STATUS=$(systemctl is-active wpa_supplicant 2>/dev/null)
if [ "$WPA_STATUS" != "active" ] && [ "$WPA_STATUS" != "activating" ]; then
    systemctl start wpa_supplicant || systemctl restart wpa_supplicant
fi
if ! grep -q "^nameserver 8.8.8.8$" ${RESOLV_CONF}; then
    echo "nameserver 8.8.8.8" >>${RESOLV_CONF}
fi
if ! grep -q "^nameserver 144.144.144.144$" ${RESOLV_CONF}; then
    echo "nameserver 144.144.144.144" >>${RESOLV_CONF}
fi
EOF
    chmod +x /usr/local/bin/dns-setup.sh
fi
cat > /etc/systemd/system/dns-setup.service << EOF
[Unit]
Description=DNS Setup Service (One-time)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/dns-setup.sh
User=root
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable dns-setup.service
DNS_SERVER="144.144.144.144"
RESOLV_CONF="/etc/resolv.conf"
rfkill unblock wifi
sleep 3
WPA_STATUS=$(systemctl is-active wpa_supplicant 2>/dev/null)
systemctl start wpa_supplicant
sleep 5
if ! grep -q "^nameserver 8.8.8.8$" ${RESOLV_CONF}; then
    echo "nameserver 8.8.8.8" >>${RESOLV_CONF}
fi
if ! grep -q "^nameserver 144.144.144.144$" ${RESOLV_CONF}; then
    echo "nameserver 144.144.144.144" >>${RESOLV_CONF}
fi
sleep 3
echo "Testing network connectivity..."
RETRY_COUNT=0
MAX_WAIT=180
WAIT_TIMES=(40 80 120 180)
while [ $RETRY_COUNT -lt ${#WAIT_TIMES[@]} ]; do
    if curl -s --connect-timeout 10 ip.sb > /dev/null; then
        echo "Network connectivity test successful"
        echo "Your public IP is: $(curl -s ip.sb)"
        echo "WiFi setup completed successfully"
        echo "DNS setup service enabled - will run once after network is online"
        echo "Check service status with: systemctl status dns-setup.service"
        exit 0
    else
        CURRENT_WAIT=${WAIT_TIMES[$RETRY_COUNT]}
        echo "Network connectivity test failed (attempt $((RETRY_COUNT + 1)))"
        echo "Waiting ${CURRENT_WAIT} seconds before restarting services..."
        sleep $CURRENT_WAIT
        echo "Restarting wpa_supplicant and networking services..."
        systemctl restart wpa_supplicant
        sleep 5
        systemctl restart networking
        sleep 5
        echo "Services restarted, testing connectivity again..."
        RETRY_COUNT=$((RETRY_COUNT + 1))
    fi
done
echo "Network connectivity test failed after all retry attempts"
echo "Tried waiting: ${WAIT_TIMES[*]} seconds respectively"
echo "Please restart the system and try again"
echo "You can also manually check the following:"
echo "1. systemctl status wpa_supplicant"
echo "2. systemctl status networking"
echo "3. ip a (check if $WIFI_INTERFACE has an IP address)"
echo "4. ping baidu.com (test basic connectivity)"
