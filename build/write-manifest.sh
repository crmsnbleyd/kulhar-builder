#!/bin/sh
# Write /usr/local/share/kulhar-builder/manifest.json, the contract kulhar
# reads instead of guessing paths and versions. Runs in the final stage so
# the package versions it records are the ones the image ships. Values come
# from the installed SBCL and dpkg where possible.
#
# Usage: write-manifest.sh ARCH BASE_IMAGE_DIGEST
set -eu

arch=$1
base_digest=$2
share=/usr/local/share/kulhar-builder
out=$share/manifest.json
status_dir=$share/dpkg-status.d
versions=/src/versions.json
work=$(mktemp -d)

# Packages in gcr.io/distroless/cc-debian12 (its /var/lib/dpkg/status.d,
# checked at sha256:e5d81ddde149641e2a9ba55be4545bc125c67de07508b03ba4c22e6eb0ded5aa).
# tests/smoke.sh runs the sbcl runtime in that image to keep this honest.
distroless_cc_packages=" base-files ca-certificates gcc-12-base libc6 libgcc-s1 libgomp1 libssl3 libstdc++6 media-types netbase tzdata "

die() { echo "write-manifest: $*" >&2; exit 1; }

sbcl --noinform --non-interactive --no-sysinit --no-userinit \
  --eval '(require :asdf)' \
  --eval "(with-open-file (s \"$work/lisp.txt\" :direction :output)
            (format s \"~A~%~A~%~A~%~A~%~A~%~A~%\"
                    (lisp-implementation-version)
                    (asdf:asdf-version)
                    (namestring (truename sb-ext:*runtime-pathname*))
                    (namestring (truename sb-ext:*core-pathname*))
                    (namestring (truename (sb-int:sbcl-homedir-pathname)))
                    (namestring (truename (merge-pathnames \"contrib/\" (sb-int:sbcl-homedir-pathname))))))" \
  --eval "(with-open-file (s \"$work/features.txt\" :direction :output)
            (dolist (f *features*) (format s \"~(~A~)~%\" f)))"

line() { sed -n "${1}p" "$work/lisp.txt"; }

# The shared libraries the sbcl runtime links against. An image that runs
# the runtime must provide each of them at the path dpkg records. For those
# that distroless/cc-debian12 lacks, also point at the file to copy, its
# copyright notice and dpkg status.d metadata, so vulnerability scanners
# still see the package in the runtime image.
mkdir -p "$status_dir"
: >"$work/libs.jsonl"
ldd "$(line 3)" | awk '/=>/ { print $3; next } $1 ~ /^\// { print $1 }' | while read -r resolved; do
  soname=${resolved##*/}
  # /lib is a symlink to /usr/lib here, so dpkg may know either spelling.
  path=''
  owner=''
  for candidate in "$resolved" "/usr${resolved}" "${resolved#/usr}"; do
    if owner=$(dpkg-query -S "$candidate" 2>/dev/null); then
      path=$candidate
      break
    fi
  done
  [ -n "$path" ] || die "no package owns $resolved"
  pkg=${owner%%:*}
  version=$(dpkg-query -W -f '${Version}' "$pkg")
  case $distroless_cc_packages in
    *" $pkg "*)
      jq -nc --arg soname "$soname" --arg path "$path" --arg pkg "$pkg" --arg version "$version" \
        '{soname: $soname, path: $path, package: $pkg, package_version: $version,
          in_distroless_cc_debian12: true}' >>"$work/libs.jsonl"
      ;;
    *)
      copyright=/usr/share/doc/$pkg/copyright
      [ -f "$copyright" ] || die "$copyright is missing"
      dpkg-query -s "$pkg" | grep -v '^Status:' >"$status_dir/$pkg"
      cp "$(dpkg-query --control-path "$pkg" md5sums)" "$status_dir/$pkg.md5sums"
      jq -nc --arg soname "$soname" --arg path "$path" --arg source "$(readlink -f "$path")" \
        --arg pkg "$pkg" --arg version "$version" --arg copyright "$copyright" \
        --arg status "$status_dir/$pkg" --arg md5sums "$status_dir/$pkg.md5sums" \
        '{soname: $soname, path: $path, source: $source, package: $pkg, package_version: $version,
          in_distroless_cc_debian12: false, copyright: $copyright,
          dpkg_status: $status, dpkg_md5sums: $md5sums}' >>"$work/libs.jsonl"
      ;;
  esac
done

. /etc/os-release

jq -n \
  --arg sbcl_version "$(line 1)" \
  --arg asdf_version "$(line 2)" \
  --arg runtime "$(line 3)" \
  --arg core "$(line 4)" \
  --arg home "$(line 5)" \
  --arg contrib "$(line 6)" \
  --rawfile features "$work/features.txt" \
  --slurpfile libs "$work/libs.jsonl" \
  --arg arch "$arch" \
  --arg machine "$(uname -m)" \
  --arg debian_release "$VERSION_ID" \
  --arg debian_codename "$VERSION_CODENAME" \
  --arg debian_version "$(cat /etc/debian_version)" \
  --arg base_digest "$base_digest" \
  --slurpfile versions "$versions" \
  '{
    schema_version: 1,
    sbcl: {
      version: $sbcl_version,
      runtime: $runtime,
      core: $core,
      home: $home,
      contrib_dir: $contrib,
      features: ($features | split("\n") | map(select(. != ""))),
      runtime_shared_libraries: $libs
    },
    asdf_version: $asdf_version,
    architecture: $arch,
    machine_type: $machine,
    debian: {
      release: $debian_release,
      codename: $debian_codename,
      version: $debian_version
    },
    base_image: {
      name: "docker.io/library/debian:\($debian_codename)-slim",
      digest: $base_digest
    },
    tools: {
      quicklisp_client: {
        version: $versions[0].tools.quicklisp_client.version,
        client_dir: "/usr/local/lib/kulhar-builder/quicklisp/",
        loader: "/usr/local/share/kulhar-builder/load-quicklisp.lisp",
        home_env: "KULHAR_QUICKLISP_HOME"
      },
      qlot: {
        version: $versions[0].tools.qlot.version,
        executable: "/usr/local/bin/qlot",
        cache_env: "QLOT_CACHE_DIRECTORY"
      },
      ocicl: {
        version: $versions[0].tools.ocicl.version,
        executable: "/usr/local/bin/ocicl"
      }
    }
  }' >"$out"

rm -rf "$work"
cat "$out"
