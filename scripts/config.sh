#!/bin/bash
# from
# https://github.com/oneclickvirt/pve
# 2024.03.12

divert_install_script() {
  local package_name=$1
  local divert_script="/usr/local/sbin/${package_name}-install"
  local install_script="/var/lib/dpkg/info/${package_name}.postinst"
  if [ -x "$(command -v yum)" ]; then
    divert_script="/usr/local/sbin/${package_name}-install"
    install_script="/var/lib/rpm/centos/${package_name}.postinst"
  fi
  ln -sf "${divert_script}" "${install_script}"
  echo '#!/bin/bash' >"${divert_script}"
  echo 'exit 1' >>"${divert_script}"
  chmod +x "${divert_script}"
}

if [ -x "$(command -v apt-get)" ]; then
  echo "Package: zmap nmap masscan medusa apache2-utils hping3
Pin: release *
Pin-Priority: -1" | sudo tee -a /etc/apt/preferences
fi

if [ -x "$(command -v apt-get)" ]; then
  sudo apt-get update
elif [ -x "$(command -v yum)" ]; then
  sudo yum update
fi

divert_install_script "zmap"
divert_install_script "nmap"
divert_install_script "masscan"
divert_install_script "medusa"
divert_install_script "hping3"
divert_install_script "apache2-utils"
rm -rf "$0"
