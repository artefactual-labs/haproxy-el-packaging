#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build"

if [ -f "${ROOT_DIR}/versions.env" ]; then
  # shellcheck disable=SC1091
  source "${ROOT_DIR}/versions.env"
fi

: "${HAPROXY_VERSION:?Set HAPROXY_VERSION (e.g. 2.8.16)}"
: "${PACKAGE_RELEASE:=1}"
: "${HAPROXY_BUILD_TARGETS:=el9=rockylinux:9 el8=rockylinux:8}"

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
  safe_rm_rf "${BUILD_DIR}"
  mkdir -p "${BUILD_DIR}"
}

prepare_host_assets() {
  local rootfs_dir=$1

  install -d -m0755 "${rootfs_dir}/etc/haproxy"
  install -d -m0755 "${rootfs_dir}/etc/logrotate.d"
  install -d -m0755 "${rootfs_dir}/etc/sysconfig"
  install -d -m0755 "${rootfs_dir}/usr/lib/systemd/system"
  install -d -m0755 "${rootfs_dir}/usr/lib/sysusers.d"

  install -D -m0644 "${ROOT_DIR}/config/haproxy.cfg" "${rootfs_dir}/etc/haproxy/haproxy.cfg"
  install -D -m0644 "${ROOT_DIR}/logrotate/haproxy" "${rootfs_dir}/etc/logrotate.d/haproxy"
  install -D -m0644 "${ROOT_DIR}/systemd/haproxy.service" "${rootfs_dir}/usr/lib/systemd/system/haproxy.service"
  install -D -m0644 "${ROOT_DIR}/systemd/haproxy.sysconfig" "${rootfs_dir}/etc/sysconfig/haproxy"
  install -D -m0644 "${ROOT_DIR}/systemd/haproxy.sysusers" "${rootfs_dir}/usr/lib/sysusers.d/haproxy.conf"
}

build_inside_container() {
  local runtime=$1
  local image=$2
  local rootfs_dir=$3
  local variant=$4

  log "Building HAProxy ${HAPROXY_VERSION} for ${variant} using ${runtime} with base ${image}"

  local host_uid host_gid
  host_uid="$(id -u)"
  host_gid="$(id -g)"

  local build_script
  build_script=$(cat <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

HAPROXY_VERSION="$1"
BUILD_VARIANT="${BUILD_VARIANT:-}"

dnf -y install dnf-plugins-core >/dev/null
if [ "${BUILD_VARIANT}" = "el9" ]; then
  dnf config-manager --set-enabled crb >/dev/null
elif [ "${BUILD_VARIANT}" = "el8" ]; then
  dnf config-manager --set-enabled powertools >/dev/null
else
  dnf config-manager --set-enabled crb >/dev/null 2>&1 || true
  dnf config-manager --set-enabled powertools >/dev/null 2>&1 || true
fi
dnf -y upgrade --refresh >/dev/null
dnf -y install \
  gcc make \
  openssl-devel pcre2-devel lua-devel systemd-devel \
  readline-devel zlib-devel \
  tar gzip shadow-utils pkgconf-pkg-config \
  diffutils \
  libatomic >/dev/null
if ! dnf -y install curl-minimal >/dev/null; then
  dnf -y install curl >/dev/null
fi

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
install -d -m0755 /work/rootfs/usr/bin
install -d -m0755 /work/rootfs/usr/share/haproxy

install -m0755 admin/halog/halog /work/rootfs/usr/bin/halog
install -m0755 admin/iprange/iprange /work/rootfs/usr/bin/iprange
install -m0755 admin/iprange/ip6range /work/rootfs/usr/bin/ip6range

cp -a examples/errorfiles /work/rootfs/usr/share/haproxy/errorfiles

if [ -n "${HOST_UID:-}" ] && [ -n "${HOST_GID:-}" ]; then
  chown -R "${HOST_UID}:${HOST_GID}" /work/rootfs
fi

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
    -v "${rootfs_dir}:/work/rootfs:${mount_opts}" \
    -v "${tmpdir}/build.sh:/work/build.sh:ro" \
    -e HOST_UID="${host_uid}" \
    -e HOST_GID="${host_gid}" \
    -e BUILD_VARIANT="${variant}" \
    "${image}" \
    bash /work/build.sh "${HAPROXY_VERSION}"

  rm -rf "${tmpdir}"
}

safe_rm_rf() {
  local target=$1
  [ -z "${target}" ] && return 0
  if rm -rf "${target}" 2>/dev/null; then
    return 0
  fi
  if command -v sudo >/dev/null 2>&1; then
    sudo rm -rf "${target}"
    return 0
  fi
  chmod -R u+w "${target}" 2>/dev/null || true
  rm -rf "${target}"
}

main() {
  clean_build_dirs

  local runtime
  runtime="$(container_runtime)" || {
    log "Neither podman nor docker is available; cannot build HAProxy natively."
    exit 1
  }

  IFS=' ' read -r -a targets <<< "${HAPROXY_BUILD_TARGETS}"
  if [ "${#targets[@]}" -eq 0 ]; then
    log "No build targets defined via HAPROXY_BUILD_TARGETS."
    exit 1
  fi

  for entry in "${targets[@]}"; do
    [ -z "${entry}" ] && continue
    if [[ "${entry}" != *=* ]]; then
      log "Invalid entry '${entry}' in HAPROXY_BUILD_TARGETS (expected variant=image)."
      exit 1
    fi
    local variant="${entry%%=*}"
    local image="${entry#*=}"
    if [ -z "${variant}" ] || [ -z "${image}" ]; then
      log "Invalid entry '${entry}' in HAPROXY_BUILD_TARGETS (empty variant or image)."
      exit 1
    fi

    local rootfs_dir="${BUILD_DIR}/rootfs-${variant}"
    safe_rm_rf "${rootfs_dir}"
    mkdir -p "${rootfs_dir}"
    prepare_host_assets "${rootfs_dir}"
    build_inside_container "${runtime}" "${image}" "${rootfs_dir}" "${variant}"
    log "HAProxy rootfs ready under ${rootfs_dir}"
  done
}

main "$@"
