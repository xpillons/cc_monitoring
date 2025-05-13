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

exit 0
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
    mkdir -pv /var/spool/slurm/statesave
    dd if=/dev/random of=/var/spool/slurm/statesave/jwt_hs256.key bs=32 count=1
    chown slurm:slurm /var/spool/slurm/statesave/jwt_hs256.key
    chmod 0600 /var/spool/slurm/statesave/jwt_hs256.key
    chown slurm:slurm /var/spool/slurm/statesave
    chmod 0755 /var/spool/slurm/statesave

    # Add to JWT Auth to the slurm.conf
    # Check if the line already exists
    if ! grep -q "AuthAltTypes=auth/jwt" /etc/slurm/slurm.conf; then
        lines_to_insert="AuthAltTypes=auth/jwt\nAuthAltParameters=jwt_key=/var/spool/slurm/statesave/jwt_hs256.key\n"
        sed -i --follow-symlinks '/^Include azure.conf/a '"$lines_to_insert"'' /etc/slurm/slurm.conf
    fi

    # Create an unprivileged user for slurmrestd
    if id "slurmrestd" &>/dev/null; then
        echo "User slurmrestd exists"
    else
        useradd -M -r -s /usr/sbin/nologin -U slurmrestd
    fi    

    # Add user to the docker group
    if getent group docker | grep -qw slurmrestd; then
        echo "User slurmrestd belongs to group docker"
    else
        usermod -aG docker slurmrestd
    fi
    
    newgrp docker

    # Create a socket for the slurmrestd
    mkdir -pv /var/spool/slurmrestd
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
    rm -rf slurm-exporter
    git clone https://github.com/SlinkyProject/slurm-exporter.git
    cd slurm-exporter
    # Equivalent to:  docker build . -t slinky.slurm.net/slurm-exporter:0.3.0
    make docker-build
    popd

    
    # Run Slurm Exporter in a container
    unset SLURM_JWT; export $(scontrol token username="slurmrestd" lifespan=infinite)
    # The following command run sucessfully
    # go run ./cmd/main.go -server http://localhost:6820 -metrics-bind-address ":9080" -per-user-metrics true
    # Added options to specify the local slurmrestd socket and per user metrics
    # public image is ghcr.io/slinkyproject/slurm-exporter:0.2.1
    # Running this doesn't work. 
    # tried this to map localhost inside the container without success. Log Level is not taken into account, starts freeze at Starting exporter
    # docker run -v /var:/var -e SLURM_JWT=${SLURM_JWT} --rm -p 127.0.0.1:9080:8080 --add-host=host.docker.internal:host-gateway \
    #           slinky.slurm.net/slurm-exporter:0.3.0 -server http://host.docker.internal:6820 -per-user-metrics true --zap-log-level=5
    docker run -v /var:/var -e SLURM_JWT=${SLURM_JWT} -d --rm -p 127.0.0.1:${SLURM_EXPORTER_PORT}:8080 --add-host=host.docker.internal:host-gateway \
            slinky.slurm.net/slurm-exporter:0.3.0 -server http://host.docker.internal:6820 -per-user-metrics true -metrics-bind-address ":${SLURM_EXPORTER_PORT}"
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