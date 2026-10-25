ARG DEBIAN_RELEASE=trixie
ARG DEBIAN_REGISTRY=docker.io/library
FROM ${DEBIAN_REGISTRY}/debian:${DEBIAN_RELEASE}

ARG PVE_MAJOR=9
ENV container=docker
COPY install-container.sh /usr/local/sbin/install-pve-container
RUN /usr/local/sbin/install-pve-container "$PVE_MAJOR" && rm /usr/local/sbin/install-pve-container
# Docker supplies devices and kernel settings. Do not let container services
# change the shared kernel or replace the host's binary format registrations.
RUN systemctl mask systemd-binfmt.service systemd-udevd.service \
      systemd-udevd-control.socket systemd-udevd-kernel.socket \
      systemd-sysctl.service systemd-modules-load.service
COPY container-entrypoint.sh /usr/local/sbin/pve-container-entrypoint
STOPSIGNAL SIGRTMIN+3
EXPOSE 22 8006
HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=3 \
  CMD curl --fail --silent --show-error --cacert /etc/pve/pve-root-ca.pem \
      --resolve "$(hostname):8006:127.0.0.1" "https://$(hostname):8006/api2/json/version" >/dev/null || exit 1
ENTRYPOINT ["/usr/local/sbin/pve-container-entrypoint"]
