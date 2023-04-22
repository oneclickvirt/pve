#!/bin/bash
# from https://github.com/spiritLHLS/pve

divert_install_script() {
  local package_name=$1
  local divert_script="/usr/local/sbin/${package_name}-install"
  local install_script="/var/lib/dpkg/info/${package_name}.postinst"
  ln -sf "${divert_script}" "${install_script}"
  sh -c "echo '#!/bin/bash' > ${divert_script}"
  sh -c "echo 'exit 1' >> ${divert_script}"
  chmod +x "${divert_script}"
}

echo "Package: zmap nmap masscan medusa
Pin: release *
Pin-Priority: -1" | sudo tee -a /etc/apt/preferences
divert_install_script "zmap"
divert_install_script "nmap"
divert_install_script "masscan"
divert_install_script "medusa"
rm -rf "$0"
