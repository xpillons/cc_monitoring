#!/bin/bash
set -e
script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SPEC_FILE_ROOT="$script_dir/../files"
PROM_CONFIG=/opt/prometheus/prometheus.yml

source "$SPEC_FILE_ROOT/common.sh"

SLURM_EXPORTER_PORT=9080

if ! is_monitoring_enabled; then
    exit 0
fi

# Only install Slurm Exporter on Scheduler
if ! is_scheduler ; then
    echo "Do not install the Slurm Exporter since this is not the scheduler." 
    exit 0
fi

echo "Installing Slurm Exporter..."

install_prerequisites() {
    # This should ALL be installed and configured by cyclecloud-slurm project in the future

    # See: https://github.com/benmcollins/libjwt
    if command -v apt-get &> /dev/null; then
        apt-get install -y git libjansson-dev libjwt-dev
    else 
        dnf install -y libjansson-devel libjwt-dev
    fi

    # Configure JWT and slurmrestd

    # Create a local key
    mkdir -p /var/spool/slurm/statesave
    dd if=/dev/random of=/var/spool/slurm/statesave/jwt_hs256.key bs=32 count=1
    chown slurm:slurm /var/spool/slurm/statesave/jwt_hs256.key
    chmod 0600 /var/spool/slurm/statesave/jwt_hs256.key
    chown slurm:slurm /var/spool/slurm/statesave
    chmod 0755 /var/spool/slurm/statesave

    # Add to JWT Auth to the slurm.conf
    lines_to_insert="AuthAltTypes=auth/jwt\nAuthAltParameters=jwt_key=/var/spool/slurm/statesave/jwt_hs256.key\n"
    sed -i '/^# Additional config/i '"$lines_to_insert"'' /etc/slurm/slurm.conf

    # Create an unprivileged user for slurmrestd
    useradd -M -r -s /usr/sbin/nologin -U slurmrestd

    # Add user to the docker group
    usermod -aG docker slurmrestd
    newgrp docker


    # Create a socket for the slurmrestd
    mkdir /var/spool/slurmrest
    touch /var/spool/slurmrestd/slurmrestd.socket
    chown -R slurmrestd:slurmrestd /var/spool/slurmrestd

    # Configure the slurmrestd:
     cat <<EOF > /etc/default/slurmrestd
SLURMRESTD_OPTIONS="-u slurmrestd -g slurmrestd"
SLURMRESTD_LISTEN=:6820,unix:/var/spool/slurmrestd/slurmrestd.socket
EOF
    chmod 644 /etc/default/slurmrestd

    # Restart the slurmrestd:
    systemctl stop slurmrestd.service
    systemctl start slurmrestd.service
    systemctl status slurmrestd.service
}


install_slurm_exporter() {

    # Build the exporter
    pushd /tmp
    git clone https://github.com/SlinkyProject/slurm-exporter.git
    cd slurm-exporter
    # Equivalent to:  docker build . -t slinky.slurm.net/slurm-exporter:0.3.0
    make docker-build
    popd

    
    # Run Slurm Exporter in a container
    unset SLURM_JWT; export $(scontrol token)
    docker run -v /var:/var -e SLURM_JWT=${SLURM_JWT} -d -rm \
           -p ${SLURM_EXPORTER_PORT}:8080 slinky.slurm.net/slurm-exporter:0.3.0
}

function add_scraper() {
    INSTANCE_NAME=$(hostname)

    yq eval-all '. as $item ireduce ({}; . *+ $item)' $PROM_CONFIG $SPEC_FILE_ROOT/slurm_exporter.yml > tmp.yml
    mv -vf tmp.yml $PROM_CONFIG

    # update the configuration file
    sed -i "s/instance_name/$INSTANCE_NAME/g" $PROM_CONFIG

    systemctl restart prometheus
}

if is_scheduler ; then
    install_prerequisites
    install_slurm_exporter
    install_yq
    add_scraper
fi