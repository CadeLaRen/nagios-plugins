#!/usr/bin/env bash
#  vim:ts=4:sts=4:sw=4:et
#
#  Author: Hari Sekhon
#  Date: 2016-01-26 23:36:03 +0000 (Tue, 26 Jan 2016)
#
#  https://github.com/harisekhon/nagios-plugins
#
#  License: see accompanying Hari Sekhon LICENSE file
#
#  If you're using my code you're welcome to connect with me on LinkedIn and optionally send me feedback
#
#  https://www.linkedin.com/in/harisekhon
#

set -euo pipefail
[ -n "${DEBUG:-}" ] && set -x

srcdir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

cd "$srcdir/.."

. "$srcdir/utils.sh"

echo "
# ============================================================================ #
#                                  C o n s u l
# ============================================================================ #
"

export CONSUL_VERSIONS="${@:-${CONSUL_VERSIONS:-latest 0.1 0.2 0.3 0.4 0.5 0.6 0.7}}"

CONSUL_HOST="${DOCKER_HOST:-${CONSUL_HOST:-${HOST:-localhost}}}"
CONSUL_HOST="${CONSUL_HOST##*/}"
CONSUL_HOST="${CONSUL_HOST%%:*}"
export CONSUL_HOST

export CONSUL_PORT="${CONSUL_PORT:-8500}"

export DOCKER_IMAGE="harisekhon/consul"
export DOCKER_CONTAINER="nagios-plugins-consul-test"

export MNTDIR="/pl"

startupwait 10

if ! is_docker_available; then
    echo 'WARNING: Docker not found, skipping Consul checks!!!'
    exit 0
fi

dockerexec(){
    docker exec "$DOCKER_CONTAINER-dev" $MNTDIR/$@
}

test_consul(){
    local version="$1"
    echo "Setting up Consul $version test container"
    hr
    local DOCKER_CMD="agent -dev -data-dir /tmp -client 0.0.0.0"
    launch_container "$DOCKER_IMAGE:$version" "$DOCKER_CONTAINER" $CONSUL_PORT
    if [ -n "${NOTESTS:-}" ]; then
        return 0
    fi
    when_ports_available $startupwait $CONSUL_HOST $CONSUL_PORT
    hr
    local testkey="nagios/consul/testkey1"
    echo "Writing random value to test key $testkey"
    local random_val=$RANDOM
    curl -X PUT -d "$random_val" "http://$CONSUL_HOST:$CONSUL_PORT/v1/kv/$testkey"
    echo
    hr
    if [ "$version" = "latest" ]; then
        local version="*"
    fi
    set +e
    found_version=$(docker exec "$DOCKER_CONTAINER" consul version | head -n1 | tee /dev/stderr | sed 's/.*v//')
    set -e
    if [[ "$found_version" != $version* ]]; then
        echo "Docker container version does not match expected version! (found '$found_version', expected '$version')"
        exit 1
    fi
    hr
    echo "Consul version $found_version"
    hr
    ./check_consul_peer_count.py
    hr
    ./check_consul_key.py -k /nagios/consul/testkey1 -r "^$random_val$" -v
    hr
    echo "writing deterministic test key to check thresholds"
    curl -X PUT -d "5" "http://$CONSUL_HOST:$CONSUL_PORT/v1/kv/$testkey"
    echo
    hr
    ./check_consul_key.py -k /nagios/consul/testkey1 -r '^\d$' -w 5 -v
    hr
    ./check_consul_key.py -k /nagios/consul/testkey1 -r '^\d$' -c 5 -v
    hr
    ./check_consul_key.py -k /nagios/consul/testkey1 -r '^\d$' -w 5 -c 5 -v
    hr
    echo "checking threshold failures are caught correctly"
    hr
    set +o pipefail
    ./check_consul_key.py -k /nagios/consul/testkey1 -r '^\d$' -w 4 -c 5 -v | tee /dev/stderr | grep --color=yes ^WARNING
    hr
    ./check_consul_key.py -k /nagios/consul/testkey1 -r '^\d$' -w 4 -c 4 -v | tee /dev/stderr | grep --color=yes ^CRITICAL
    set -o pipefail
    hr
    ./check_consul_write.py -v
    hr
    delete_container
    echo

    hr
    echo "Setting up Consul-dev $version test container"
    hr
    local DOCKER_OPTS="-v $srcdir/..:$MNTDIR"
    local DOCKER_CMD=""
    launch_container "$DOCKER_IMAGE-dev:$version" "$DOCKER_CONTAINER-dev"

    hr
    dockerexec check_consul_version.py
    hr
    delete_container "$DOCKER_CONTAINER-dev"
    echo
}

for version in $(ci_sample $CONSUL_VERSIONS); do
    test_consul $version
done
