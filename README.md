# kulhar-builder

Builder images for **[kulhar](https://codeberg.org/crmsnbleyd/kulhar)**, published to
`ghcr.io/crmsnbleyd/kulhar-builder`.

> **kulhar lives on Codeberg: <https://codeberg.org/crmsnbleyd/kulhar>.**
> Report kulhar bugs, ask questions and send contributions there. This GitHub
> repository only builds the builder images. Its issues are for problems with
> the images themselves.

kulhar builds OCI images from an ASDF system without a Dockerfile. It runs its
two build steps (save a core with the project's dependencies, then compile the
project to FASLs) inside a builder container. A saved SBCL core and its FASLs
only work with the exact SBCL build that produced them, on the same OS and
architecture, so this image provides that SBCL:

- SBCL built from the signed upstream source release, with `--fancy` (zstd core
  compression, threads, xref for internals);
- Debian 12 "bookworm", the same release as kulhar's runtime base
  `gcr.io/distroless/cc-debian12`;
- `linux/amd64` and `linux/arm64`, each built natively (no emulation);
- a C toolchain (`gcc`, `libc6-dev`, `make`, `pkg-config`), because CFFI's
  groveller compiles C while some libraries load, plus `git` and `ca-certificates`;
- the Quicklisp client (no dist installed), qlot and ocicl.

This repository does **not** contain kulhar's source code.

For now the image is built from a hand-written [`Dockerfile`](Dockerfile).
Once kulhar can build its own builder image, the Dockerfile will be replaced.

## Tags

| Tag | Example | Meaning |
| --- | --- | --- |
| `sbcl-<version>-bookworm-<YYYYMMDD>` | `sbcl-2.6.9-bookworm-20261013` | Immutable. One build on one day (UTC). Never overwritten. |
| `sbcl-<version>-bookworm` | `sbcl-2.6.9-bookworm` | Moves to the newest dated build of that SBCL version. |

Every tag is a multi-architecture index covering `linux/amd64` and `linux/arm64`.
There is no `latest` tag.

The images are rebuilt every month to pick up Debian security fixes, so the
moving tag changes even when the SBCL version doesn't. SBCL itself is identical
across rebuilds of one version, but the surrounding Debian packages are not.

### Why kulhar pins builder images by digest

A core or FASL built in one builder image is only guaranteed to load under the
SBCL runtime from that same image. kulhar also copies the `sbcl` runtime and
`sbcl.core` out of the builder image into the images it builds. If kulhar
referred to the builder by a moving tag, two builds of the same project could
quietly use different builder images, and its build cache could mix FASLs
across them. So kulhar records the builder as
`ghcr.io/crmsnbleyd/kulhar-builder@sha256:…`. Tags are only for people
choosing which digest to pin. Even the dated tags are pinned by digest,
because registries can't enforce tag immutability.

To find the digest behind a tag:

```bash
docker buildx imagetools inspect ghcr.io/crmsnbleyd/kulhar-builder:sbcl-2.6.9-bookworm
```

## Contract: paths and manifest

These paths are stable for a given major version of the manifest
(`schema_version`):

| Path | What |
| --- | --- |
| `/usr/local/bin/sbcl` | SBCL runtime binary |
| `/usr/local/lib/sbcl/sbcl.core` | SBCL core |
| `/usr/local/lib/sbcl/contrib/` | Contrib modules (`sb-posix`, `sb-sprof`, …) |
| `/usr/local/share/kulhar-builder/manifest.json` | Machine-readable contract (below) |
| `/usr/local/share/kulhar-builder/load-quicklisp.lisp` | Loads the Quicklisp client |
| `/usr/local/lib/kulhar-builder/quicklisp/` | Pristine Quicklisp client (read-only) |
| `/usr/local/bin/qlot`, `/usr/local/bin/ocicl` | Dependency tools |

kulhar reads `manifest.json` rather than relying on the table above. It looks
like this (abridged; `features` lists all of `*features*`):

```json
{
  "schema_version": 1,
  "sbcl": {
    "version": "2.6.9",
    "runtime": "/usr/local/bin/sbcl",
    "core": "/usr/local/lib/sbcl/sbcl.core",
    "home": "/usr/local/lib/sbcl/",
    "contrib_dir": "/usr/local/lib/sbcl/contrib/",
    "features": ["sb-core-compression", "sb-thread", "x86-64", "linux", "..."],
    "runtime_shared_libraries": ["libzstd.so.1", "libm.so.6", "libc.so.6", "..."]
  },
  "asdf_version": "3.3.x",
  "architecture": "amd64",
  "machine_type": "x86_64",
  "debian": { "release": "12", "codename": "bookworm", "version": "12.x" },
  "base_image": {
    "name": "docker.io/library/debian:bookworm-slim",
    "digest": "sha256:…"
  },
  "tools": {
    "quicklisp_client": {
      "version": "2021-02-13",
      "client_dir": "/usr/local/lib/kulhar-builder/quicklisp/",
      "loader": "/usr/local/share/kulhar-builder/load-quicklisp.lisp",
      "home_env": "KULHAR_QUICKLISP_HOME"
    },
    "qlot": { "version": "1.8.4", "executable": "/usr/local/bin/qlot", "cache_env": "QLOT_CACHE_DIRECTORY" },
    "ocicl": { "version": "2.20.0", "executable": "/usr/local/bin/ocicl" }
  }
}
```

`runtime_shared_libraries` lists what the `sbcl` runtime links against (from
`ldd`). An image that runs the copied runtime has to provide all of them. In
particular, `libzstd.so.1` is **not** part of `gcr.io/distroless/cc-debian12`.

`base_image.digest` is the digest of the multi-architecture `debian:bookworm-slim`
index that both Dockerfile stages start from. The final stage runs
`apt-get upgrade`, so installed Debian packages can be newer than the ones in
that base.

To read it:

```bash
docker run --rm ghcr.io/crmsnbleyd/kulhar-builder:sbcl-2.6.9-bookworm \
  cat /usr/local/share/kulhar-builder/manifest.json
```

## Running as any UID

kulhar runs the image as the host user's UID, which usually has no entry in
the image's `/etc/passwd`. The image works that way: everything a build writes
goes under world-writable, sticky directories.

| Variable | Default | Used by |
| --- | --- | --- |
| `HOME` | `/home/kulhar` | SBCL (`user-homedir-pathname`), git |
| `XDG_CACHE_HOME` | `/var/cache/kulhar/xdg-cache` | ASDF's FASL cache |
| `XDG_DATA_HOME` | `/var/cache/kulhar/xdg-data` | ocicl's global directory |
| `KULHAR_QUICKLISP_HOME` | `/var/cache/kulhar/quicklisp` | Quicklisp dists and local projects |
| `QLOT_CACHE_DIRECTORY` | `/var/cache/kulhar/qlot` | qlot's download cache |
| `XDG_CONFIG_DIRS` | `/usr/local/etc/xdg:/etc/xdg` | ASDF config shipped with the image (see below) |

To persist every cache, mount one host directory at `/var/cache/kulhar`.
Each variable can also be pointed somewhere else on its own. The working
directory is `/workspace`.

The Quicklisp variable is deliberately **not** `QUICKLISP_HOME`. `qlot exec`
uses `QUICKLISP_HOME` whenever it is set, so a global value would break it.

The qlot sources under `/usr/local/lib/kulhar-builder/` are compiled at image
build time. Their FASLs sit next to the sources, through an ASDF
output-translations file in `/usr/local/etc/xdg`, so containers don't
recompile qlot. If you replace `XDG_CONFIG_DIRS`, keep `/usr/local/etc/xdg` in it.

### Quicklisp

The Quicklisp client is installed with **no dist**. kulhar picks and pins the
dist for each build. To use it directly:

```bash
sbcl --load /usr/local/share/kulhar-builder/load-quicklisp.lisp \
     --eval '(ql-dist:install-dist "http://beta.quicklisp.org/dist/quicklisp/2026-01-01/distinfo.txt" :prompt nil)' \
     --eval '(ql:quickload :alexandria)'
```

`load-quicklisp.lisp` copies the client into `$KULHAR_QUICKLISP_HOME` on first
use, and again when the image's client version changes. Dists and local
projects stay there across image updates.

## Verifying an image

Each published index has a build provenance attestation, made with
`actions/attest-build-provenance` and pushed to the registry next to the image:

```bash
gh attestation verify \
  oci://ghcr.io/crmsnbleyd/kulhar-builder:sbcl-2.6.9-bookworm-20261013 \
  --repo crmsnbleyd/kulhar-builder
```

Verify the digest you actually pin (`oci://ghcr.io/crmsnbleyd/kulhar-builder@sha256:…`).

**The attestations name this GitHub repository, `github.com/crmsnbleyd/kulhar-builder`,
as the build source, not the kulhar repository on Codeberg.** They prove that
this repository's workflow built the image. They say nothing about kulhar's own
source.

## Building a custom builder image

If a dependency needs native headers or tools at build time, extend this image.
Pin the base by digest, as kulhar does:

```dockerfile
FROM ghcr.io/crmsnbleyd/kulhar-builder:sbcl-2.6.9-bookworm-20261013@sha256:…

USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends libsqlite3-dev libssl-dev \
 && rm -rf /var/lib/apt/lists/*
```

Then point kulhar at your image's digest. Keep these in mind:

- Don't replace or rebuild SBCL. Cores and FASLs are tied to this exact build.
- Don't remove or move anything listed in `manifest.json`.
- Libraries your application loads at **runtime** also have to be in the
  runtime image, not just the builder.
- Don't set `USER` to a named user. kulhar chooses the UID when it runs the image.

## How the images are built

[`versions.json`](versions.json) lists every SBCL version that is built, with its
source URL, the published SHA-256, and the fingerprint of the key that signs
SBCL releases. It also pins the Quicklisp client, qlot and ocicl.

- **SBCL**: `build/fetch-sbcl.sh` downloads the source tarball and the release's
  signed checksum list (`sbcl-<version>-crhodes.asc`). It verifies the signature
  against the key in [`keys/`](keys) (Christophe Rhodes,
  `D683 9CA0 A67F 74D9 DFB7 0922 EBD5 95A9 100D 63CD`), checks that the signed
  checksum equals the one in `versions.json`, and checks the download against
  it. Any mismatch fails the build. SBCL is bootstrapped with Debian's `sbcl`
  package, which is not shipped in the final image.
- **Quicklisp client**: checked against the SHA-256 in Quicklisp's client-info
  file. Quicklisp does not sign its client files.
- **qlot** and **ocicl**: checked against the SHA-256 GitHub publishes for each
  release asset. For ocicl that sum also appears in the release's `SHA256SUMS`.
  ocicl is compiled from its source release with this image's SBCL. ocicl has
  no arm64 Linux binary, and its source vendors all of its dependencies.
- **Base image**: `debian:bookworm-slim`, pinned by digest in the `Dockerfile`.

**SBCL's own test suite is not run in CI.** The `RUN_SBCL_TESTS=yes` build
argument runs it. In a trial on SBCL 2.6.9/arm64, the suite took about 6 minutes
on a fast workstation, where SBCL itself built in about 1 minute. It failed
`run-program.impure.lisp / (RUN-PROGRAM MINIMIZES-ZOMBIES)` because a
`docker build` step has no init process to reap zombie processes. Running the
suite would make every CI build several times longer and need a skip list for
container-only failures. `tests/smoke.sh` checks what kulhar depends on instead.

### Workflow

[`.github/workflows/build.yml`](.github/workflows/build.yml) runs on:

- **pushes to `trunk`** that touch the Dockerfile, `versions.json`, the build
  scripts, keys, tests or the workflow: build and smoke-test only, nothing is pushed;
- **`workflow_dispatch`** (optionally for one SBCL version) and a **monthly
  schedule**: build, test and publish.

Each SBCL version × architecture is built natively on `ubuntu-24.04` or
`ubuntu-24.04-arm`, with `SOURCE_DATE_EPOCH` set to the commit time. The image
is smoke-tested as UID 4242, which has no passwd entry, and then pushed by
digest only. A merge job then checks that the dated tag does not exist yet. If
it already exists, the run **fails rather than overwrite it**, so a second
publish on the same UTC day fails. The merge job creates the two-architecture
index with `docker buildx imagetools create`, tags it with the dated and moving
tags, and pushes a build provenance attestation.

To run the smoke tests locally (needs Docker, `jq`, and network access for the
qlot, ocicl and Quicklisp checks):

```bash
docker buildx build --load --build-arg SBCL_VERSION=2.6.9 -t kulhar-builder:dev .
```

```bash
sh tests/smoke.sh kulhar-builder:dev 2.6.9
```

### Adding an SBCL version

1. Download `sbcl-<version>-crhodes.asc` from the release's SourceForge folder
   and verify it: `gpg --import keys/sbcl-release-signing-key.asc && gpg --decrypt sbcl-<version>-crhodes.asc`.
2. Add an entry to `versions.json` with the `sbcl-<version>-source.tar` sum from
   the signed list. That is the sum of the **uncompressed** tarball.
3. Push to `trunk` to build and test, then run the workflow manually to publish.

## Maintainer setup

The workflow can't do these steps:

1. **Make the package public after the first publish.** New GHCR packages are
   private. Open <https://github.com/users/crmsnbleyd/packages/container/kulhar-builder/settings>
   and, under *Danger Zone*, change visibility to **Public**. Until then, kulhar
   users can't pull the image anonymously.
2. **Confirm the package is linked to this repository.** The same settings page
   should list `crmsnbleyd/kulhar-builder` under *Repository source*, and the
   repository's *Packages* sidebar should show `kulhar-builder`. The
   `org.opencontainers.image.source` label normally links them on first push.
   If not, use *Connect repository*. Under *Manage Actions access*, check that
   this repository has the **Write** role, so `GITHUB_TOKEN` can keep pushing.
3. **Keep Actions enabled** for scheduled runs. GitHub disables schedules in
   repositories with no activity for 60 days.

No secrets need to be configured. The workflow only uses `GITHUB_TOKEN`.

## License

[MIT](LICENSE). This covers the build scripts in this repository. The images
contain SBCL (mostly public domain, some BSD-style licensed parts), Debian
packages, Quicklisp (MIT), qlot (MIT) and ocicl (MIT), each under its own
license. kulhar itself is licensed separately; see its repository.
