#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build"
ROOTFS_DIR="${BUILD_DIR}/rootfs"

if [ -f "${ROOT_DIR}/versions.env" ]; then
  # shellcheck disable=SC1091
  source "${ROOT_DIR}/versions.env"
fi

: "${HAPROXY_VERSION:?Set HAPROXY_VERSION (e.g. 2.8.16)}"
: "${PACKAGE_RELEASE:=1}"
: "${ROCKY_BASE_IMAGE:=rockylinux:9}"

log() {
  printf '[build-haproxy] %s\n' "$*" >&2
}

container_runtime() {
  if command -v podman >/dev/null 2>&1; then
    echo podman
    return
  fi
  if command -v docker >/dev/null 2>&1; then
    echo docker
    return
  fi
  return 1
}

clean_build_dirs() {
  rm -rf "${BUILD_DIR}"
  mkdir -p "${ROOTFS_DIR}"
}

prepare_host_assets() {
  install -d -m0755 "${ROOTFS_DIR}/etc/haproxy"
  install -d -m0755 "${ROOTFS_DIR}/etc/logrotate.d"
  install -d -m0755 "${ROOTFS_DIR}/etc/sysconfig"
  install -d -m0755 "${ROOTFS_DIR}/usr/lib/systemd/system"
  install -d -m0755 "${ROOTFS_DIR}/usr/lib/sysusers.d"

  install -D -m0644 "${ROOT_DIR}/config/haproxy.cfg" "${ROOTFS_DIR}/etc/haproxy/haproxy.cfg"
  install -D -m0644 "${ROOT_DIR}/logrotate/haproxy" "${ROOTFS_DIR}/etc/logrotate.d/haproxy"
  install -D -m0644 "${ROOT_DIR}/systemd/haproxy.service" "${ROOTFS_DIR}/usr/lib/systemd/system/haproxy.service"
  install -D -m0644 "${ROOT_DIR}/systemd/haproxy.sysconfig" "${ROOTFS_DIR}/etc/sysconfig/haproxy"
  install -D -m0644 "${ROOT_DIR}/systemd/haproxy.sysusers" "${ROOTFS_DIR}/usr/lib/sysusers.d/haproxy.conf"
}

build_inside_container() {
  local runtime
  runtime="$(container_runtime)" || {
    log "Neither podman nor docker is available; cannot build HAProxy natively."
    exit 1
  }

  log "Building HAProxy ${HAPROXY_VERSION} using ${runtime} with base ${ROCKY_BASE_IMAGE}"

  local build_script
  build_script=$(cat <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

HAPROXY_VERSION="$1"

dnf -y install dnf-plugins-core >/dev/null
dnf config-manager --set-enabled crb >/dev/null
dnf -y upgrade --refresh >/dev/null
dnf -y install \
  gcc make \
  openssl-devel pcre2-devel lua-devel systemd-devel \
  readline-devel zlib-devel \
  tar gzip curl-minimal shadow-utils pkgconf-pkg-config \
  libatomic >/dev/null

curl -fsSL "https://www.haproxy.org/download/${HAPROXY_VERSION%.*}/src/haproxy-${HAPROXY_VERSION}.tar.gz" -o /tmp/haproxy.tar.gz
tar -xf /tmp/haproxy.tar.gz -C /tmp
cd "/tmp/haproxy-${HAPROXY_VERSION}"

make -j"$(nproc)" TARGET=linux-glibc CPU=generic \
  USE_OPENSSL=1 USE_PCRE2=1 USE_LUA=1 USE_ZLIB=1 USE_SYSTEMD=1 USE_PROMEX=1

make admin/halog/halog
pushd admin/iprange >/dev/null
make
popd >/dev/null

make install-bin DESTDIR=/work/rootfs PREFIX=/usr TARGET=linux2628
make install-man DESTDIR=/work/rootfs PREFIX=/usr

install -d -m0755 /work/rootfs/var/lib/haproxy
install -d -m0755 /work/rootfs/usr/share/haproxy

install -m0755 admin/halog/halog /work/rootfs/usr/bin/halog
install -m0755 admin/iprange/iprange /work/rootfs/usr/bin/iprange
install -m0755 admin/iprange/ip6range /work/rootfs/usr/bin/ip6range

cp -a examples/errorfiles /work/rootfs/usr/share/haproxy/errorfiles

rm -f /tmp/haproxy.tar.gz
EOF
)

  local tmpdir
  tmpdir=$(mktemp -d)
  printf '%s\n' "${build_script}" > "${tmpdir}/build.sh"

  local mount_opts="rw"
  if [ "${runtime}" = "podman" ]; then
    mount_opts="rw,Z"
  fi

  ${runtime} run --rm \
    -v "${ROOTFS_DIR}:/work/rootfs:${mount_opts}" \
    -v "${tmpdir}/build.sh:/work/build.sh:ro" \
    "${ROCKY_BASE_IMAGE}" \
    bash /work/build.sh "${HAPROXY_VERSION}"

  rm -rf "${tmpdir}"
}

main() {
  clean_build_dirs
  prepare_host_assets
  build_inside_container
  log "HAProxy rootfs ready under ${ROOTFS_DIR}"
}

main "$@"
