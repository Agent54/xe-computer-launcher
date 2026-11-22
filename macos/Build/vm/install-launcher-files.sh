#!/bin/sh
set -eu
mkdir -p /opt/xe/runtime /opt/xe/guest-worker /etc/docker
cp /opt/image-runtime/start-services.sh /opt/image-runtime/cleanup-docker-pid.sh /opt/xe/runtime/
cp /opt/image-runtime/daemon.json /etc/docker/daemon.json
cp -R /opt/image-router/. /opt/xe/guest-worker/
chmod 755 /opt/xe/runtime/*.sh /opt/xe/guest-worker/start-router.sh
cd /opt/xe/guest-worker
sha256sum -c checksums.txt
./lib/ld-linux-aarch64.so.1 --library-path ./lib ./workerd --version

# Adapt the pinned DinD entrypoint once, in the image. Keep its networking setup;
# replace recursive PID cleanup without a PATH shim. Tini owns both services
# as the image entrypoint, so Docker does not need a second init process.
entrypoint=/usr/local/bin/dockerd-entrypoint.sh
test "$(grep -Fc "find /run /var/run -iname 'docker*.pid' -delete || :" "$entrypoint")" = 1
sed -i "/find \/run \/var\/run -iname 'docker\*.pid' -delete || :/c\\
    /opt/xe/runtime/cleanup-docker-pid.sh" "$entrypoint"
grep -Fq '/opt/xe/runtime/cleanup-docker-pid.sh' "$entrypoint"
test "$(grep -Fc 'set -- docker-init -- "$@"' "$entrypoint")" = 1
sed -i 's/set -- docker-init -- "\$@"/: # docker-init is the launcher image entrypoint/' "$entrypoint"
/bin/sh -n "$entrypoint"
