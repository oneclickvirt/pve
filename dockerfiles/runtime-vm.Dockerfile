ARG UBUNTU_IMAGE=ubuntu:24.04
FROM ${UBUNTU_IMAGE}
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates cloud-image-utils curl openssh-client python3 qemu-system-x86 qemu-utils \
    && rm -rf /var/lib/apt/lists/* && mkdir -p /input
COPY dockerfiles/verify-container.py /checks/
COPY tests/pve_container_runtime.py /checks/
ENTRYPOINT ["python3", "/checks/verify-container.py"]
