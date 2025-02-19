#!/bin/bash
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS-IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -euxo pipefail

# Detect dataproc image version from its various names
if (! test -v DATAPROC_IMAGE_VERSION) && test -v DATAPROC_VERSION; then
  DATAPROC_IMAGE_VERSION="${DATAPROC_VERSION}"
fi

if [[ $(echo "${DATAPROC_IMAGE_VERSION} >= 2.0" | bc -l) == 1  ]]; then
  readonly LIVY_DEFAULT_VERSION="0.8.0"
  readonly SCALA_DEFAULT_VERSION="2.12"
else
  readonly LIVY_DEFAULT_VERSION="0.7.1"
  readonly SCALA_DEFAULT_VERSION="2.11"
fi

readonly LIVY_VERSION=$(/usr/share/google/get_metadata_value attributes/livy-version || echo ${LIVY_DEFAULT_VERSION})
readonly SCALA_VERSION=$(/usr/share/google/get_metadata_value attributes/scala-version || echo ${SCALA_DEFAULT_VERSION})
readonly LIVY_PKG_NAME="apache-livy-${LIVY_VERSION}-incubating_${SCALA_VERSION}-bin"
readonly LIVY_BASENAME="${LIVY_PKG_NAME}.zip"
readonly LIVY_URL="https://archive.apache.org/dist/incubator/livy/${LIVY_VERSION}-incubating/${LIVY_BASENAME}"
readonly LIVY_TIMEOUT_SESSION=$(/usr/share/google/get_metadata_value attributes/livy-timeout-session || echo 1h)

readonly LIVY_DIR=/usr/local/lib/livy
readonly LIVY_BIN=${LIVY_DIR}/bin
readonly LIVY_CONF=${LIVY_DIR}/conf

# Generate livy configuration file.
function make_livy_conf() {
  cat <<EOF >"${LIVY_CONF}/livy.conf"
livy.spark.master = $(grep spark.master /etc/spark/conf/spark-defaults.conf | cut -d= -f2)
livy.spark.deploy-mode = $(grep spark.submit.deployMode /etc/spark/conf/spark-defaults.conf | cut -d= -f2)
livy.server.session.timeout=$LIVY_TIMEOUT_SESSION
EOF
}

# Generate livy environment file.
function make_livy_env() {
  cat <<EOF >"${LIVY_CONF}/livy-env.sh"
export SPARK_HOME=/usr/lib/spark
export SPARK_CONF_DIR=/etc/spark/conf
export HADOOP_CONF_DIR=/etc/hadoop/conf
export LIVY_LOG_DIR=/var/log/livy
EOF

  if [[ -e /opt/conda/anaconda/bin/python3 ]]; then
    cat <<EOF >>"${LIVY_CONF}/livy-env.sh"
export PYSPARK_PYTHON=/opt/conda/anaconda/bin/python3
export PYSPARK_DRIVER_PYTHON=/opt/conda/anaconda/bin/python3
EOF
  elif [[ -e /opt/conda/miniconda3/bin/python3 ]]; then
    cat <<EOF >>"${LIVY_CONF}/livy-env.sh"
export PYSPARK_PYTHON=/opt/conda/miniconda3/bin/python3
export PYSPARK_DRIVER_PYTHON=/opt/conda/miniconda3/bin/python3
EOF
  fi
}

# Create Livy service.
function create_systemd_unit() {
  cat <<EOF >"/etc/systemd/system/livy.service"
[Unit]
Description=Apache Livy service
After=network.target

[Service]
Group=livy
User=livy
Type=forking
ExecStart=${LIVY_BIN}/livy-server start
ExecStop=${LIVY_BIN}/livy-server stop
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
}

function main() {
  # Only run this initialization action on the master node.
  local role
  role=$(/usr/share/google/get_metadata_value attributes/dataproc-role)
  if [[ ${role} != Master ]]; then
    exit 0
  fi

  # Download Livy binary.
  local temp
  temp=$(mktemp -d -t livy-init-action-XXXX)

  wget -nv --timeout=30 --tries=5 --retry-connrefused "${LIVY_URL}" -P "${temp}"

  unzip -q "${temp}/${LIVY_PKG_NAME}.zip" -d /usr/local/lib/
  ln -s "/usr/local/lib/${LIVY_PKG_NAME}" "${LIVY_DIR}"

  # Create Livy user.
  useradd -G hadoop livy -d /home/livy
  mkdir -p /home/livy
  chown livy:hadoop /home/livy
  
  # Setup livy package.
  chown -R -L livy:livy "${LIVY_DIR}"

  # Generate livy configuration file.
  make_livy_conf

  # Setup log directory.
  mkdir /var/log/livy
  chown -R livy:livy /var/log/livy

  # Cleanup temp files.
  rm -Rf "${temp}"

  # Generate livy environment file.
  make_livy_env

  # Start livy service.
  create_systemd_unit
  systemctl enable livy.service
  systemctl start livy.service
}

main
