#!/bin/bash

# Please update these carefully, some versions won't work under Wine
NSIS_FILENAME=nsis-3.05-setup.exe
NSIS_URL=https://downloads.sourceforge.net/project/nsis/NSIS%203/3.05/$NSIS_FILENAME
NSIS_SHA256=1a3cc9401667547b9b9327a177b13485f7c59c2303d4b6183e7bc9e6c8d6bfdb

LIBUSB_REPO="https://github.com/libusb/libusb.git"
LIBUSB_COMMIT="c6a35c56016ea2ab2f19115d2ea1e85e0edae155"
# ^ tag v1.0.24

PYINSTALLER_REPO="https://github.com/SomberNight/pyinstaller.git"
PYINSTALLER_COMMIT="80ee4d613ecf75a1226b960a560ee01459e65ddb"
# ^ tag 4.2, plus a custom commit that fixes cross-compilation with MinGW

LIB_GCC_FILENAME=libgcc-6.3.0-1-mingw32-dll-1.tar.xz
LIB_GCC_URL=https://netix.dl.sourceforge.net/project/mingw/MinGW/Base/gcc/Version6/gcc-6.3.0/$LIB_GCC_FILENAME
LIB_GCC_SHA256=8cbfa963f645cc0f81c08df2a3ecbcefc776606f0fb9db7a280d79f05209a1c3

PYTHON_VERSION=3.8.8


# Let's begin!
set -e

here="$(dirname "$(readlink -e "$0")")"

. "$CONTRIB"/build_tools_util.sh

info "Booting wine."
wine 'wineboot'


cd "$CACHEDIR"
mkdir -p $WINEPREFIX/drive_c/tmp

info "Installing Python."
# note: you might need "sudo apt-get install dirmngr" for the following
# keys from https://www.python.org/downloads/#pubkeys
KEYRING_PYTHON_DEV="keyring-electrum-build-python-dev.gpg"
gpg --no-default-keyring --keyring $KEYRING_PYTHON_DEV --import "$here"/gpg_keys/7ED10B6531D7C8E1BC296021FC624643487034E5.asc
if [ "$WIN_ARCH" = "win32" ] ; then
    PYARCH="win32"
elif [ "$WIN_ARCH" = "win64" ] ; then
    PYARCH="amd64"
else
    fail "unexpected WIN_ARCH: $WIN_ARCH"
fi
PYTHON_DOWNLOADS="$CACHEDIR/python$PYTHON_VERSION"
mkdir -p "$PYTHON_DOWNLOADS"
for msifile in core dev exe lib pip tools; do
    echo "Installing $msifile..."
    download_if_not_exist "$PYTHON_DOWNLOADS/${msifile}.msi" "https://www.python.org/ftp/python/$PYTHON_VERSION/$PYARCH/${msifile}.msi"
    download_if_not_exist "$PYTHON_DOWNLOADS/${msifile}.msi.asc" "https://www.python.org/ftp/python/$PYTHON_VERSION/$PYARCH/${msifile}.msi.asc"
    verify_signature "$PYTHON_DOWNLOADS/${msifile}.msi.asc" $KEYRING_PYTHON_DEV
    wine msiexec /i "$PYTHON_DOWNLOADS/${msifile}.msi" /qb TARGETDIR=$WINE_PYHOME
done

break_legacy_easy_install

info "Installing build dependencies."
$WINE_PYTHON -m pip install --no-dependencies --no-warn-script-location \
    --cache-dir "$WINE_PIP_CACHE_DIR" -r "$CONTRIB"/deterministic-build/requirements-build-wine.txt

info "Installing NSIS."
download_if_not_exist "$CACHEDIR/$NSIS_FILENAME" "$NSIS_URL"
verify_hash "$CACHEDIR/$NSIS_FILENAME" "$NSIS_SHA256"
wine "$CACHEDIR/$NSIS_FILENAME" /S


info "Compiling libusb..."
(
    cd "$CACHEDIR"
    if [ -f "libusb/libusb/.libs/libusb-1.0.dll" ]; then
        info "libusb-1.0.dll already built, skipping"
        exit 0
    fi
    rm -rf libusb
    mkdir libusb
    cd libusb
    # Shallow clone
    git init
    git remote add origin $LIBUSB_REPO
    git fetch --depth 1 origin $LIBUSB_COMMIT
    git checkout -b pinned "${LIBUSB_COMMIT}^{commit}"
    echo "libusb_1_0_la_LDFLAGS += -Wc,-static" >> libusb/Makefile.am
    ./bootstrap.sh || fail "Could not bootstrap libusb"
    host="$GCC_TRIPLET_HOST"
    LDFLAGS="-Wl,--no-insert-timestamp" ./configure \
        --host=$host \
        --build=$GCC_TRIPLET_BUILD || fail "Could not run ./configure for libusb"
    make -j4 || fail "Could not build libusb"
    ${host}-strip libusb/.libs/libusb-1.0.dll
) || fail "libusb build failed"
cp "$CACHEDIR/libusb/libusb/.libs/libusb-1.0.dll" $WINEPREFIX/drive_c/tmp/  || fail "Could not copy libusb to its destination"

download_if_not_exist $LIB_GCC_FILENAME "$LIB_GCC_URL"
verify_hash $LIB_GCC_FILENAME $LIB_GCC_SHA256
tar Jxfv $LIB_GCC_FILENAME

cp bin/libgcc_s_dw2-1.dll $WINEPREFIX/drive_c/python3/Lib/site-packages/

# copy already built DLLs
cp "$DLL_TARGET_DIR/libsecp256k1-0.dll" $WINEPREFIX/drive_c/tmp/ || fail "Could not copy libsecp to its destination"
cp "$DLL_TARGET_DIR/libzbar-0.dll" $WINEPREFIX/drive_c/tmp/ || fail "Could not copy libzbar to its destination"


info "Building PyInstaller."
# we build our own PyInstaller boot loader as the default one has high
# anti-virus false positives
(
    if [ "$WIN_ARCH" = "win32" ] ; then
        PYINST_ARCH="32bit"
    elif [ "$WIN_ARCH" = "win64" ] ; then
        PYINST_ARCH="64bit"
    else
        fail "unexpected WIN_ARCH: $WIN_ARCH"
    fi
    if [ -f "$CACHEDIR/pyinstaller/PyInstaller/bootloader/Windows-$PYINST_ARCH/runw.exe" ]; then
        info "pyinstaller already built, skipping"
        exit 0
    fi
    cd "$WINEPREFIX/drive_c/electrum-ltfn"
    ELECTRUM_COMMIT_HASH=$(git rev-parse HEAD)
    cd "$CACHEDIR"
    rm -rf pyinstaller
    mkdir pyinstaller
    cd pyinstaller
    # Shallow clone
    git init
    git remote add origin $PYINSTALLER_REPO
    git fetch --depth 1 origin $PYINSTALLER_COMMIT
    git checkout -b pinned "${PYINSTALLER_COMMIT}^{commit}"
    rm -fv PyInstaller/bootloader/Windows-*/run*.exe || true
    # add reproducible randomness. this ensures we build a different bootloader for each commit.
    # if we built the same one for all releases, that might also get anti-virus false positives
    echo "const char *electrum_tag = \"tagged by Electrum@$ELECTRUM_COMMIT_HASH\";" >> ./bootloader/src/pyi_main.c
    pushd bootloader
    # cross-compile to Windows using host python
    python3 ./waf all CC="${GCC_TRIPLET_HOST}-gcc" \
                      CFLAGS="-static \
                              -Wno-dangling-else \
                              -Wno-error=unused-value \
                              -Wno-error=implicit-function-declaration \
                              -Wno-error=int-to-pointer-cast \
                              -Wno-error=stringop-truncation"
    popd
    # sanity check bootloader is there:
    [[ -e "PyInstaller/bootloader/Windows-$PYINST_ARCH/runw.exe" ]] || fail "Could not find runw.exe in target dir!"
) || fail "PyInstaller build failed"
info "Installing PyInstaller."
$WINE_PYTHON -m pip install --no-dependencies --no-warn-script-location ./pyinstaller

info "Wine is configured."
