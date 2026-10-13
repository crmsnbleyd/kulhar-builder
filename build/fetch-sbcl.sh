#!/bin/sh
# Download the SBCL source release named in versions.json, verify it, and
# unpack it into DEST.
#
# SBCL publishes a PGP-signed list of SHA-256 sums of the *uncompressed*
# tarballs (sbcl-X.Y.Z-crhodes.asc). We check that the signature was made by
# the key pinned in versions.json, that the signed list agrees with the
# checksum pinned in versions.json, and that the download matches both.
#
# Usage: fetch-sbcl.sh VERSION DEST
set -eu

version=$1
dest=$2
versions=/src/versions.json
keyfile=/src/keys/sbcl-release-signing-key.asc

die() { echo "fetch-sbcl: $*" >&2; exit 1; }
field() { jq -er --arg v "$version" ".sbcl[\$v].$1" "$versions" || die "no .sbcl[\"$version\"].$1 in versions.json"; }

source_url=$(field source_url)
checksums_url=$(field checksums_url)
want=$(field source_tar_sha256)
fpr=$(field signing_key_fingerprint)

work=$(mktemp -d)
export GNUPGHOME="$work/gnupg"
mkdir -m 700 "$GNUPGHOME"

gpg --batch --quiet --import "$keyfile"
gpg --batch --with-colons --fingerprint "$fpr" | grep -q "^fpr:::::::::$fpr:" \
  || die "$keyfile does not contain key $fpr"

curl -fsSL --retry 5 --retry-all-errors -o "$work/source.tar.bz2" "$source_url"
curl -fsSL --retry 5 --retry-all-errors -o "$work/checksums.asc" "$checksums_url"

gpg --batch --status-fd 3 --output "$work/checksums.txt" \
  --decrypt "$work/checksums.asc" 3>"$work/gpg-status" \
  || die "bad signature on $checksums_url"
grep -q "^\[GNUPG:\] VALIDSIG $fpr " "$work/gpg-status" \
  || die "$checksums_url is not signed by $fpr"

published=$(awk -v f="sbcl-$version-source.tar" '$2 == f { print $1 }' "$work/checksums.txt")
[ -n "$published" ] || die "signed checksum list has no entry for sbcl-$version-source.tar"
[ "$published" = "$want" ] \
  || die "versions.json says $want but the signed list says $published"

bunzip2 -c "$work/source.tar.bz2" >"$work/source.tar"
actual=$(sha256sum "$work/source.tar" | cut -d' ' -f1)
[ "$actual" = "$want" ] || die "checksum mismatch: expected $want, got $actual"

mkdir -p "$dest"
tar -xf "$work/source.tar" -C "$dest" --strip-components=1
rm -rf "$work"
echo "fetch-sbcl: verified SBCL $version source (sha256 $want, signed by $fpr)"
