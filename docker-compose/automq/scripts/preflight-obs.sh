#!/usr/bin/env bash
set -euo pipefail

automq_dir="${AUTOMQ_DIR:-/data/automq}"
obsutil="${OBSUTIL_BIN:-${automq_dir}/tools/obsutil/obsutil_linux_amd64_5.8.3/obsutil}"
work_dir="$(mktemp -d)"
trap 'rm -rf -- "${work_dir}"' EXIT
chmod 0700 "${work_dir}"

cd "${automq_dir}"
set -a
# shellcheck disable=SC1091
. ./.env
set +a

access_key="$(tr -d '\r\n' < secrets/obs-access-key)"
secret_key="$(tr -d '\r\n' < secrets/obs-secret-key)"
config="${work_dir}/obsutil.config"
: > "${config}"
chmod 0600 "${config}"
printf 'CHECK: configure temporary OBS client\n'
"${obsutil}" config -i="${access_key}" -k="${secret_key}" \
  -e="${AUTOMQ_OBS_ENDPOINT}" -config="${config}"
unset access_key secret_key

# SSE-OBS changes the object ETag, so validate integrity with a post-download
# SHA-256 comparison instead of obsutil's ETag-based -vmd5 check.
"${obsutil}" rm "obs://${AUTOMQ_OBS_BUCKET}/automq-preflight/" \
  -config="${config}" -r -f >/dev/null 2>&1 || true

head -c 65536 /dev/urandom > "${work_dir}/small.bin"
head -c 20971520 /dev/urandom > "${work_dir}/multipart.bin"
prefix="automq-preflight/$(date +%Y%m%d%H%M%S)"

printf 'CHECK: upload small and multipart objects\n'
"${obsutil}" cp "${work_dir}/small.bin" \
  "obs://${AUTOMQ_OBS_BUCKET}/${prefix}/small.bin" \
  -config="${config}"
"${obsutil}" cp "${work_dir}/multipart.bin" \
  "obs://${AUTOMQ_OBS_BUCKET}/${prefix}/multipart.bin" \
  -config="${config}" -threshold=1048576 -ps=5242880

printf 'CHECK: download and verify object hashes\n'
"${obsutil}" cp "obs://${AUTOMQ_OBS_BUCKET}/${prefix}/small.bin" \
  "${work_dir}/small.read" -config="${config}" >/dev/null
"${obsutil}" cp "obs://${AUTOMQ_OBS_BUCKET}/${prefix}/multipart.bin" \
  "${work_dir}/multipart.read" -config="${config}" >/dev/null

test "$(sha256sum "${work_dir}/small.bin" | cut -d' ' -f1)" = \
  "$(sha256sum "${work_dir}/small.read" | cut -d' ' -f1)"
test "$(sha256sum "${work_dir}/multipart.bin" | cut -d' ' -f1)" = \
  "$(sha256sum "${work_dir}/multipart.read" | cut -d' ' -f1)"

printf 'CHECK: delete preflight objects\n'
"${obsutil}" rm "obs://${AUTOMQ_OBS_BUCKET}/${prefix}/small.bin" \
  -config="${config}" -f >/dev/null
"${obsutil}" rm "obs://${AUTOMQ_OBS_BUCKET}/${prefix}/multipart.bin" \
  -config="${config}" -f >/dev/null
if "${obsutil}" ls "obs://${AUTOMQ_OBS_BUCKET}/${prefix}/" \
  -config="${config}" -limit=10 2>&1 | grep -Eq 'small\.bin|multipart\.bin'; then
  printf 'FAIL: OBS preflight objects remain after delete\n' >&2
  exit 1
fi

printf 'PASS: OBS small-object put, get, hash, and delete\n'
printf 'PASS: OBS multipart put, get, hash, and delete\n'
