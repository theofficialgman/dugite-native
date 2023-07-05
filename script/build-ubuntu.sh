#!/bin/bash -e
#
# Compiling Git for Linux and bundling Git LFS from upstream.
#

set -eu -o pipefail

if [[ -z "${SOURCE}" ]]; then
  echo "Required environment variable SOURCE was not set"
  exit 1
fi

if [[ -z "${DESTINATION}" ]]; then
  echo "Required environment variable DESTINATION was not set"
  exit 1
fi

if [[ -z "${CURL_INSTALL_DIR}" ]]; then
  echo "Required environment variable CURL_INSTALL_DIR was not set"
  exit 1
fi

if [[ -z "${ZLIB_INSTALL_DIR}" ]]; then
  echo "Required environment variable ZLIB_INSTALL_DIR was not set"
  exit 1
fi

if [[ -z "${OPENSSL_INSTALL_DIR}" ]]; then
  echo "Required environment variable OPENSSL_INSTALL_DIR was not set"
  exit 1
fi

case "$TARGET_ARCH" in
  "x64")
    DEPENDENCY_ARCH="amd64"
    export CC="x86_64-linux-gcc -no-pie"
    PREFIX="x86_64-linux" 
    OPENSSL_TARGET="linux-x86_64" ;;
  "x86")
    DEPENDENCY_ARCH="x86"
    export CC="i686-linux-gcc"
    PREFIX="i686-linux"
    OPENSSL_TARGET="linux-x86" ;;
  "arm64")
    DEPENDENCY_ARCH="arm64"
    export CC="aarch64-linux-gcc -no-pie"
    PREFIX="aarch64-linux" 
    OPENSSL_TARGET="linux-aarch64" ;;
  "arm")
    DEPENDENCY_ARCH="arm"
    export CC="arm-linux-gcc"
    PREFIX="arm-linux"
    OPENSSL_TARGET="linux-armv4" ;;
  *)
    exit 1 ;;
esac

export PKG_CONFIG="pkg-config"

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
GIT_LFS_VERSION="$(jq --raw-output '.["git-lfs"].version[1:]' dependencies.json)"
GIT_LFS_CHECKSUM="$(jq --raw-output ".\"git-lfs\".files[] | select(.arch == \"$DEPENDENCY_ARCH\" and .platform == \"linux\") | .checksum" dependencies.json)"
GIT_LFS_FILENAME="$(jq --raw-output ".\"git-lfs\".files[] | select(.arch == \"$DEPENDENCY_ARCH\" and .platform == \"linux\") | .name" dependencies.json)"

# shellcheck source=script/compute-checksum.sh
source "$CURRENT_DIR/compute-checksum.sh"
# shellcheck source=script/check-static-linking.sh
source "$CURRENT_DIR/check-static-linking.sh"

echo " -- Building vanilla zlib at $ZLIB_INSTALL_DIR instead of distro-specific version"

ZLIB_FILE_NAME="zlib-1.2.13"
ZLIB_FILE="$ZLIB_FILE_NAME.tar.gz"

cd /tmp || exit 1
curl -LO "https://zlib.net/$ZLIB_FILE"
tar -xf $ZLIB_FILE

(
cd $ZLIB_FILE_NAME || exit 1
./configure --prefix="$ZLIB_INSTALL_DIR"
make install
)

echo " -- Building vanilla OpenSSL3 at $OPENSSL_INSTALL_DIR instead of distro-specific version"

OPENSSL_FILE_NAME="openssl-3.1.1"
OPENSSL_FILE="$OPENSSL_FILE_NAME".tar.gz

cd /tmp || exit 1
curl -LO https://github.com/openssl/openssl/releases/download/"$OPENSSL_FILE_NAME"/"$OPENSSL_FILE"
tar -xf "$OPENSSL_FILE"

(
cd $OPENSSL_FILE_NAME || exit 1
CC=gcc ./Configure "$OPENSSL_TARGET" --prefix="$OPENSSL_INSTALL_DIR" --cross-compile-prefix="$PREFIX"- -static no-pic
make install
)

echo " -- Building vanilla curl at $CURL_INSTALL_DIR instead of distro-specific version"

CURL_FILE_NAME="curl-8.1.2"
CURL_FILE="$CURL_FILE_NAME.tar.gz"

cd /tmp || exit 1
curl -LO "https://curl.haxx.se/download/$CURL_FILE"
tar -xf $CURL_FILE

(
cd $CURL_FILE_NAME || exit 1
./configure --disable-shared --with-zlib="$ZLIB_INSTALL_DIR" --with-openssl="$OPENSSL_INSTALL_DIR" --prefix="$CURL_INSTALL_DIR" --host="$PREFIX" --target="$PREFIX"
make install
)

echo " -- Building git at $SOURCE to $DESTINATION"

(
cd "$SOURCE" || exit 1
make clean
make configure
OPENSSLDIR="$OPENSSL_INSTALL_DIR" CFLAGS='-Wall -g -O2 -fstack-protector --param=ssp-buffer-size=4 -Wformat -Werror=format-security -U_FORTIFY_SOURCE' \
  LDFLAGS='-Wl,-Bsymbolic-functions -Wl,-z,relro' ac_cv_iconv_omits_bom=no ac_cv_fread_reads_directories=no ac_cv_snprintf_returns_bogus=no \
  ./configure --host="$PREFIX" \
  --with-curl="$CURL_INSTALL_DIR" --with-zlib="$ZLIB_INSTALL_DIR" \
  --prefix=/
sed -i "s/STRIP = strip/STRIP = $PREFIX-strip/" Makefile
DESTDIR="$DESTINATION" \
  NO_TCLTK=1 \
  NO_GETTEXT=1 \
  make strip install
)

if [[ "$GIT_LFS_VERSION" ]]; then
  echo "-- Bundling Git LFS"
  GIT_LFS_FILE=git-lfs.tar.gz
  GIT_LFS_URL="https://github.com/git-lfs/git-lfs/releases/download/v${GIT_LFS_VERSION}/${GIT_LFS_FILENAME}"
  echo "-- Downloading from $GIT_LFS_URL"
  curl -sL -o $GIT_LFS_FILE "$GIT_LFS_URL"
  COMPUTED_SHA256=$(compute_checksum $GIT_LFS_FILE)
  if [ "$COMPUTED_SHA256" = "$GIT_LFS_CHECKSUM" ]; then
    echo "Git LFS: checksums match"
    SUBFOLDER="$DESTINATION/libexec/git-core"
    tar -xvf $GIT_LFS_FILE -C "$SUBFOLDER" --strip-components=1 --exclude='*.sh' --exclude="*.md"

    if [[ ! -f "$SUBFOLDER/git-lfs" ]]; then
      echo "After extracting Git LFS the file was not found under libexec/git-core/"
      echo "aborting..."
      exit 1
    fi
  else
    echo "Git LFS: expected checksum $GIT_LFS_CHECKSUM but got $COMPUTED_SHA256"
    echo "aborting..."
    exit 1
  fi
else
  echo "-- Skipped bundling Git LFS (set GIT_LFS_VERSION to include it in the bundle)"
fi


(
# download CA bundle and write straight to temp folder
# for more information: https://curl.haxx.se/docs/caextract.html
echo "-- Adding CA bundle"
cd "$DESTINATION" || exit 1
mkdir -p ssl
curl -sL -o ssl/cacert.pem https://curl.haxx.se/ca/cacert.pem
)

if [[ ! -f "$DESTINATION/ssl/cacert.pem" ]]; then
  echo "-- Skipped bundling of CA certificates (failed to download them)"
fi


echo "-- Removing server-side programs"
rm "$DESTINATION/bin/git-cvsserver"
rm "$DESTINATION/bin/git-receive-pack"
rm "$DESTINATION/bin/git-upload-archive"
rm "$DESTINATION/bin/git-upload-pack"
rm "$DESTINATION/bin/git-shell"

echo "-- Removing unsupported features"
rm "$DESTINATION/libexec/git-core/git-svn"
rm "$DESTINATION/libexec/git-core/git-p4"

set +eu

echo "-- Static linking research"
check_static_linking "$DESTINATION"

set -eu -o pipefail

if [ "$TARGET_ARCH" == "x64" ]; then
(
echo "-- Testing clone operation with generated binary"

TEMP_CLONE_DIR=/tmp/clones
mkdir -p $TEMP_CLONE_DIR

cd "$DESTINATION/bin" || exit 1
./git --version
GIT_CURL_VERBOSE=1 \
  GIT_TEMPLATE_DIR="$DESTINATION/share/git-core/templates" \
  GIT_SSL_CAINFO="$DESTINATION/ssl/cacert.pem" \
  GIT_EXEC_PATH="$DESTINATION/libexec/git-core" \
  PREFIX="$DESTINATION" \
  ./git clone https://github.com/git/git.github.io "$TEMP_CLONE_DIR/git.github.io"
)
fi

set +eu
