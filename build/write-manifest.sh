#!/bin/sh
# Write /usr/local/share/kulhar-builder/manifest.json, the contract kulhar
# reads instead of guessing paths and versions. Values come from the
# installed SBCL itself where possible.
#
# Usage: write-manifest.sh ARCH BASE_IMAGE_DIGEST
set -eu

arch=$1
base_digest=$2
out=/usr/local/share/kulhar-builder/manifest.json
versions=/src/versions.json
work=$(mktemp -d)

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

# Shared libraries the sbcl runtime links against, which an image that runs
# it must also provide (e.g. libzstd.so.1 for compressed cores).
ldd "$(line 3)" | awk '$1 ~ /\.so/ && $1 !~ /^linux-vdso/ { sub(".*/", "", $1); print $1 }' >"$work/libs.txt"

. /etc/os-release

mkdir -p "$(dirname "$out")"
jq -n \
  --arg sbcl_version "$(line 1)" \
  --arg asdf_version "$(line 2)" \
  --arg runtime "$(line 3)" \
  --arg core "$(line 4)" \
  --arg home "$(line 5)" \
  --arg contrib "$(line 6)" \
  --rawfile features "$work/features.txt" \
  --rawfile libs "$work/libs.txt" \
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
      runtime_shared_libraries: ($libs | split("\n") | map(select(. != "")))
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
