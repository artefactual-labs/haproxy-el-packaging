# haproxy-el-packaging

GoReleaser-based packaging pipeline that produces modern HAProxy RPMs for Enterprise Linux (Rocky, Alma, RHEL). We built it because the stock repositories still ship HAProxy 2.4, while we rely on 2.8 for JA3 fingerprinting and Prometheus metrics support. The same workflow can target EL9 or EL8 by switching the container base image.

## Layout

- `.goreleaser.yml` – Release definition invoking the build script and producing RPM artifacts.
- `versions.env` – Version pins for HAProxy and the RPM release number.
- `scripts/build-haproxy.sh` – Builds HAProxy inside a Rocky Linux container (EL9 by default) and populates `build/rootfs/` with binaries and assets.
- `config/`, `systemd/`, `logrotate/` – Configuration files included in the package.
- `packaging/scripts/` – RPM lifecycle scripts (postinstall/preremove/postremove).

## Prerequisites

- `podman` (preferred) or `docker` available on the build host.
- GoReleaser v2.x (`go install github.com/goreleaser/goreleaser/v2@latest`).

## Building locally

```bash
export HAPROXY_VERSION=2.8.16
export PACKAGE_RELEASE=1
# Switch to EL8 tooling instead of EL9 if needed.
# export ROCKY_BASE_IMAGE=rockylinux:8

goreleaser release --skip=publish --clean --snapshot
```

Artifacts will be written to `dist/`, including the RPM file (e.g., `haproxy-2.8.16-1.x86_64.rpm`).

## GitHub Actions outline

1. Checkout the repository with full history (required by GoReleaser).
2. Install `podman` (or `docker`) and GoReleaser.
3. `source versions.env` if you want to use the defaults, or set `HAPROXY_VERSION`/`PACKAGE_RELEASE` explicitly.
4. Run `goreleaser release --clean` for a real release or add `--snapshot` for CI verification jobs.

## Updating HAProxy

1. Adjust `HAPROXY_VERSION` in `versions.env`.
2. Update the release notes/changelog if needed.
3. Run the build locally or via CI to validate.
4. Trigger the release workflow when you are ready to publish.

> **Tip:** Override `HAPROXY_BUILD_TARGETS` if you need a different container image map (default builds EL9 and EL8 from `rockylinux:9` and `rockylinux:8`).

## Release workflow

Trigger the **Release** workflow manually from GitHub Actions once the repository is in the desired state:

- Provide the release version (for example, `2.8.16-1`). This value becomes the git tag.
- Optionally set `package_release` (defaults to `1` and feeds the RPM release field).
- The workflow builds EL9 and EL8 RPMs, tags the commit, and publishes a release whose notes include the upstream HAProxy version from `versions.env`.
