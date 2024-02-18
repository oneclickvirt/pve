#!/bin/bash -e

apt install -y bison flex swig autoconf automake libtool gettext git python3-setuptools
git clone https://gitlab.com/apparmor/apparmor.git /tmp/apparmor || true
cd /tmp/apparmor
git checkout apparmor-3.0
export PYTHON=/usr/bin/python3
export PYTHON_VERSION=3
export PYTHON_VERSIONS=python3
export PYTHONPATH=$(realpath libraries/libapparmor/swig/python)
cd ./libraries/libapparmor
sh ./autogen.sh
sh ./configure --prefix=/usr --with-perl --with-python
make
#make check
make install
cd ../../parser
make
#make check
make install
apparmor_parser --version
echo $?
