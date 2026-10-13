#!/bin/sh
# Install the pinned dependency tools (Quicklisp client, qlot, ocicl) under
# /usr/local, verifying every download against versions.json.
set -eu

versions=/src/versions.json
lib=/usr/local/lib/kulhar-builder
bin=/usr/local/bin

die() { echo "install-tools: $*" >&2; exit 1; }
field() { jq -er ".tools.$1" "$versions" || die "no .tools.$1 in versions.json"; }
fetch() { # URL SHA256 OUT
  curl -fsSL --retry 5 --retry-all-errors -o "$3" "$1"
  echo "$2  $3" | sha256sum -c - >/dev/null || die "checksum mismatch for $1"
}

work=$(mktemp -d)
mkdir -p "$lib" "$bin"

# Quicklisp client, with no dist. load-quicklisp.lisp copies it into a
# writable home on first use; kulhar installs the dist it wants.
fetch "$(field quicklisp_client.tar_url)" "$(field quicklisp_client.tar_sha256)" "$work/quicklisp.tar"
fetch "$(field quicklisp_client.setup_url)" "$(field quicklisp_client.setup_sha256)" "$work/setup.lisp"
mkdir -p "$lib/quicklisp"
tar -xf "$work/quicklisp.tar" -C "$lib/quicklisp"
install -m 0644 "$work/setup.lisp" "$lib/quicklisp/setup.lisp"
[ "$(cat "$lib/quicklisp/quicklisp/version.txt")" = "$(field quicklisp_client.version)" ] \
  || die "Quicklisp client version does not match versions.json"

# qlot. The release tarball bundles its dependencies, so this needs no
# network. setup.sh compiles qlot; ASDF writes the fasls next to the sources
# (see asdf-output-translations.conf) so containers don't recompile them.
fetch "$(field qlot.url)" "$(field qlot.sha256)" "$work/qlot.tar.gz"
tar -xzf "$work/qlot.tar.gz" -C "$lib"
sh "$lib/qlot/scripts/setup.sh" >/dev/null
ln -sf ../lib/kulhar-builder/qlot/bin/qlot "$bin/qlot"

# ocicl. Its source vendors its dependencies; build the executable with this
# image's SBCL rather than running setup.lisp, which writes into $HOME.
fetch "$(field ocicl.url)" "$(field ocicl.sha256)" "$work/ocicl.tar.gz"
tar -xzf "$work/ocicl.tar.gz" -C "$work"
(
  cd "$work/ocicl"
  sbcl --dynamic-space-size 3072 --noinform --non-interactive --no-sysinit --no-userinit \
    --eval '(load "runtime/asdf.lisp")' \
    --eval '(asdf:initialize-source-registry (list :source-registry :ignore-inherited-configuration (list :tree (uiop:getcwd))))' \
    --eval '(asdf:make :ocicl)' >/dev/null
  install -m 0755 ocicl "$bin/ocicl"
)

rm -rf "$work"
