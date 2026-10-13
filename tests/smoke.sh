#!/bin/sh
# Smoke-test a freshly built kulhar builder image before it is pushed.
#
# Usage: tests/smoke.sh IMAGE SBCL_VERSION
#
# Every check runs as an arbitrary UID with no /etc/passwd entry, because
# kulhar runs the image as the host user's UID. The qlot, ocicl and Quicklisp
# checks need network access, and point every cache at a mounted volume to
# show the cache paths can be overridden. Needs docker and jq on the host.
set -eu

image=$1
version=$2
uid=${SMOKE_UID:-4242}
fixtures=$(cd "$(dirname "$0")/fixtures" && pwd)
failures=0
sbcl='sbcl --noinform --non-interactive --no-sysinit --no-userinit'

# A volume rather than a bind mount, so files the test UID creates can be
# cleaned up without root on the host.
cache=$(docker volume create)
trap 'docker volume rm -f "$cache" >/dev/null' EXIT
docker run --rm --user 0 -v "$cache:/cache" --entrypoint chmod "$image" 1777 /cache

run() {
  docker run --rm --user "$uid:$uid" \
    -v "$fixtures:/fixtures:ro" -v "$cache:/cache" \
    -e KULHAR_QUICKLISP_HOME=/cache/quicklisp \
    -e QLOT_CACHE_DIRECTORY=/cache/qlot \
    -e XDG_CACHE_HOME=/cache/xdg-cache \
    -e XDG_DATA_HOME=/cache/xdg-data \
    "$image" sh -euc "$1"
}

check() {
  name=$1
  shift
  printf '\n=== %s\n' "$name"
  if "$@"; then
    printf -- '--- PASS: %s\n' "$name"
  else
    printf -- '--- FAIL: %s\n' "$name"
    failures=$((failures + 1))
  fi
}

manifest=$(docker run --rm --user "$uid:$uid" "$image" cat /usr/local/share/kulhar-builder/manifest.json)

no_passwd_entry() {
  run "id; if getent passwd $uid; then echo 'UID $uid unexpectedly has a passwd entry'; exit 1; fi
       touch \"\$HOME/probe\" && echo \"HOME=\$HOME is writable\""
}

sbcl_version() {
  got=$(run "sbcl --version")
  echo "sbcl --version: $got"
  [ "$got" = "SBCL $version" ] || return 1
  got=$(echo "$manifest" | jq -r .sbcl.version)
  echo "manifest sbcl.version: $got"
  [ "$got" = "$version" ] || return 1
  got=$(docker image inspect "$image" --format '{{ index .Config.Labels "kulhar.builder.sbcl-version" }}')
  echo "label kulhar.builder.sbcl-version: $got"
  [ "$got" = "$version" ]
}

manifest_matches_image() {
  arch=$(docker image inspect "$image" --format '{{ .Architecture }}')
  echo "image architecture: $arch"
  echo "$manifest" | jq -e --arg a "$arch" '.architecture == $a and .debian.codename == "bookworm"
    and (.sbcl.features | index("sb-core-compression")) != null' >/dev/null
}

requires() {
  run "$sbcl --eval '(require :asdf)' --eval '(require :sb-sprof)' --eval '(require :sb-posix)' \
         --eval '(format t \"ASDF ~A, sb-sprof and sb-posix loaded~%\" (asdf:asdf-version))'"
}

compile_fasl() {
  run "cd \"\$HOME\" && $sbcl \
         --eval '(load (compile-file \"/fixtures/hello.lisp\" :output-file (merge-pathnames \"hello.fasl\" (user-homedir-pathname))))' \
         --eval '(assert (string= (kulhar-smoke:greeting) \"hello from a fasl\"))' \
         --eval '(write-line (kulhar-smoke:greeting))'"
}

save_core() {
  run "cd \"\$HOME\"
       for compression in nil t; do
         $sbcl --eval '(load \"/fixtures/hello.lisp\")' \
               --eval \"(sb-ext:save-lisp-and-die \\\"hello.core\\\" :toplevel (function kulhar-smoke:main) :compression \$compression)\"
         out=\$(sbcl --core hello.core --noinform)
         echo \"compression \$compression: \$out\"
         [ \"\$out\" = 'hello from a saved core' ]
       done"
}

gcc_runs() {
  run "cd \"\$HOME\" && gcc -o hello /fixtures/hello.c && ./hello | grep -qx 'hello from gcc' && gcc --version | head -1"
}

manifest_paths_exist() {
  paths=$(echo "$manifest" | jq -r '[.. | strings | select(startswith("/"))] | unique | .[]')
  echo "$paths"
  run "for p in $(echo "$paths" | tr '\n' ' '); do test -e \"\$p\" || { echo \"missing: \$p\"; exit 1; }; done"
}

no_build_leftovers() {
  run "for p in /usr/bin/sbcl /usr/lib/sbcl /tmp/sbcl /src; do
         if test -e \$p; then echo \"unexpected: \$p\"; exit 1; fi
       done"
}

quicklisp() {
  run "$sbcl --load /usr/local/share/kulhar-builder/load-quicklisp.lisp \
         --eval '(assert (null (ql-dist:all-dists)))' \
         --eval '(ql-dist:install-dist \"http://beta.quicklisp.org/dist/quicklisp/2026-01-01/distinfo.txt\" :prompt nil)' \
         --eval '(ql:quickload :alexandria :silent t)' \
         --eval '(format t \"alexandria from ~A~%\" (asdf:system-source-directory :alexandria))'
       test -f /cache/quicklisp/setup.lisp && test -d /cache/quicklisp/dists/quicklisp"
}

qlot_install() {
  # qlot --version exits 255 even on success, so check what it prints.
  qlot_version=$(echo "$manifest" | jq -r .tools.qlot.version)
  run "mkdir \"\$HOME/qlot-project\" && cd \"\$HOME/qlot-project\" && cp /fixtures/qlfile .
       { qlot --version || true; } | grep -x 'Qlot $qlot_version'
       qlot install
       test -f qlfile.lock && ls .qlot/dists/*/software | grep alexandria
       qlot exec $sbcl --eval '(asdf:load-system :alexandria)' --eval '(write-line \"alexandria loads under qlot exec\")'
       test -d /cache/qlot"
}

ocicl_install() {
  run "mkdir \"\$HOME/ocicl-project\" && cd \"\$HOME/ocicl-project\" && cp /fixtures/ocicl.csv .
       ocicl version | grep -E '^ocicl version: +$(echo "$manifest" | jq -r .tools.ocicl.version)\$'
       ocicl install
       ls ocicl | grep alexandria"
}

check "UID $uid has no passwd entry and HOME is writable" no_passwd_entry
check "sbcl --version, manifest and label agree on $version" sbcl_version
check "manifest matches the image" manifest_matches_image
check "require ASDF, sb-sprof and sb-posix" requires
check "compile a file to a FASL and load it" compile_fasl
check "save-lisp-and-die core runs under the image's sbcl --core" save_core
check "gcc compiles and runs a C program" gcc_runs
check "every path in the manifest exists" manifest_paths_exist
check "no bootstrap SBCL, source tree or build files" no_build_leftovers
check "Quicklisp: no dist preloaded, install a dist, quickload" quicklisp
check "qlot install against fixtures/qlfile" qlot_install
check "ocicl install against fixtures/ocicl.csv" ocicl_install

if [ "$failures" -ne 0 ]; then
  printf '\n%d check(s) failed\n' "$failures"
  exit 1
fi
printf '\nall checks passed\n'
