#!/usr/bin/env bash

DEBUG=$DEBUG

if [ -n "$DEBUG" ]
then
    set -x
fi

LIBSSH_VERSION="$1"

set -Eeuo pipefail

SRC_DIR=/io
PERM_REF_HOST_FILE="${SRC_DIR}/setup.cfg"
DIST_NAME="$(cat "${PERM_REF_HOST_FILE}" | grep '^name = ' | awk '{print$3}' | sed s/-/_/)"
IMPORTABLE_PKG="$(ls "${SRC_DIR}/src/")"  # must contain only one dir

>&2 echo Verifying that $IMPORTABLE_PKG can be the target package...
>/dev/null stat ${SRC_DIR}/src/${IMPORTABLE_PKG}/*.p{y,yx,xd}

if [ -z "$LIBSSH_VERSION" ]
then
    >&2 echo "Please pass libssh version as a first argument of this script ($0)"
    exit 1
fi

PYTHONS="cp38-cp38 cp37-cp37m cp36-cp36m cp35-cp35m cp27-cp27mu cp27-cp27m"


# Avoid creation of __pycache__/*.py[c|o]
export PYTHONDONTWRITEBYTECODE=1

PIP_GLOBAL_ARGS=
if [ -n "$DEBUG" ]
then
    PIP_GLOBAL_ARGS=-vv
fi
GIT_GLOBAL_ARGS="--git-dir=${SRC_DIR}/.git --work-tree=${SRC_DIR}"
TESTS_SRC_DIR="${SRC_DIR}/tests"
BUILD_DIR=`mktemp -d "/tmp/${DIST_NAME}-manylinux1-build.XXXXXXXXXX"`
TESTS_DIR="${BUILD_DIR}/tests"
STATIC_DEPS_PREFIX="${BUILD_DIR}/static-deps"
# FIXME: LIBGIT2_CLONE_DIR="${BUILD_DIR}/libgit2"
# FIXME: LIBGIT2_BUILD_DIR="${LIBGIT2_CLONE_DIR}/build"
# FIXME: export LIBGIT2="${STATIC_DEPS_PREFIX}"
# FIXME:
# libssh needs cmake 3.4.2
#CMAKE_VERSION=3.3.2
#CMAKE_VERSION=3.4.0
#CMAKE_DOWNLOAD_DIR="${BUILD_DIR}/cmake-${CMAKE_VERSION}-Linux-x86_64"

ZLIB_VERSION=1.2.11
ZLIB_DOWNLOAD_DIR="${BUILD_DIR}/zlib-${ZLIB_VERSION}"

LIBSSH_CLONE_DIR="${BUILD_DIR}/libssh"
LIBSSH_BUILD_DIR="${LIBSSH_CLONE_DIR}/build"

ORIG_WHEEL_DIR="${BUILD_DIR}/original-wheelhouse"
WHEEL_DEP_DIR="${BUILD_DIR}/deps-wheelhouse"
MANYLINUX_DIR="${BUILD_DIR}/manylinux-wheelhouse"
WHEELHOUSE_DIR="${SRC_DIR}/dist"
UNPACKED_WHEELS_DIR="${BUILD_DIR}/unpacked-wheels"
VENVS_DIR="${BUILD_DIR}/venvs"

function cleanup_garbage() {
    # clear python cache
    >&2 echo
    >&2 echo
    >&2 echo ===========================================
    >&2 echo Cleaning up python bytecode cache files...
    >&2 echo ===========================================
    >&2 echo
    find "${SRC_DIR}" \
        -type f \
        -name *.pyc -o -name *.pyo \
        -print0 | xargs -0 rm -fv
    find "${SRC_DIR}" \
        -type d \
        -name __pycache__ \
        -print0 | xargs -0 rm -rfv

    # clear python cache
    >&2 echo
    >&2 echo
    >&2 echo ======================================
    >&2 echo Cleaning up files untracked by Git...
    >&2 echo ======================================
    >&2 echo
    git ${GIT_GLOBAL_ARGS} clean -fxd src/ build/ bin/__pycache__/
}

cleanup_garbage

export PYCA_OPENSSL_PATH=/opt/pyca/cryptography/openssl
export OPENSSL_PATH=/opt/openssl

export LDFLAGS="-pthread -ldl '-L${STATIC_DEPS_PREFIX}/lib64' '-L${STATIC_DEPS_PREFIX}/lib'"
export CFLAGS="-fPIC"
#export CPPFLAGS="-lpthread"
export LD_LIBRARY_PATH="${STATIC_DEPS_PREFIX}/lib64:${STATIC_DEPS_PREFIX}/lib:$LD_LIBRARY_PATH"
export PKG_CONFIG_PATH="${STATIC_DEPS_PREFIX}/lib64/pkgconfig:${STATIC_DEPS_PREFIX}/lib/pkgconfig:${OPENSSL_PATH}/lib/pkgconfig:${PYCA_OPENSSL_PATH}/lib/pkgconfig"

ARCH=`uname -m`


>&2 echo
>&2 echo
>&2 echo ========================
>&2 echo Installing system deps...
>&2 echo ========================
>&2 echo
# Install a system package required by our library
yum -y install \
    git libffi-devel \
    pkgconfig \
    cmake3  # ==cmake-3.6
##########
#curl -L https://github.com/Kitware/CMake/releases/download/v${CMAKE_VERSION}/cmake-${CMAKE_VERSION}-Linux-x86_64.tar.gz | \
#    tar xzvC "${BUILD_DIR}" -f -
#/opt/python/cp37-cp37m/bin/pip install --user cmake
#export PATH="/root/.local/bin/:${CMAKE_DOWNLOAD_DIR}/bin:$PATH"
/opt/python/cp37-cp37m/bin/pip install cmake
ln -sfv /opt/python/cp37-cp37m/bin/cmake /usr/local/bin/cmake3
##########

>&2 echo
>&2 echo
>&2 echo =======================
>&2 echo Upgrading auditwheel...
>&2 echo =======================
>&2 echo
/opt/python/cp37-cp37m/bin/python -m pip install --no-compile -U auditwheel ${PIP_GLOBAL_ARGS}

>&2 echo
>&2 echo
>&2 echo ============================================
>&2 echo downloading source of zlib v${ZLIB_VERSION}:
>&2 echo ============================================
>&2 echo
curl https://www.zlib.net/zlib-${ZLIB_VERSION}.tar.gz | \
    tar xzvC "${BUILD_DIR}" -f -

pushd "${ZLIB_DOWNLOAD_DIR}"
./configure \
    --static \
    --prefix="${STATIC_DEPS_PREFIX}" && \
    make -j9 libz.a && \
    make install
popd

>&2 echo
>&2 echo
>&2 echo ================================================
>&2 echo downloading source of libssh v${LIBSSH_VERSION}:
>&2 echo ================================================
>&2 echo
git clone \
    --depth=1 \
    -b "libssh-${LIBSSH_VERSION}" \
    https://git.libssh.org/projects/libssh.git \
    "${LIBSSH_CLONE_DIR}"

mkdir -p "${LIBSSH_BUILD_DIR}"
pushd "${LIBSSH_BUILD_DIR}"
# For some reason, libssh has to be compiled as a shared object.
# If not, imports fail at runtime, with undefined symbols:
# ```python-traceback
# test/units/test_sftp.py:7: in <module>
#     from pylibsshext.sftp import SFTP
# E   ImportError: /opt/python/cp27-cp27m/lib/python2.7/site-packages/pylibsshext/sftp.so: undefined symbol: sftp_get_error
# ```
# Also, when compiled statically, manylinux2010 container turns dist
# into manylinux1 but because of the reason above, it doesn't make sense.
cmake3 "${LIBSSH_CLONE_DIR}" \
    -DCMAKE_INSTALL_PREFIX="${STATIC_DEPS_PREFIX}" \
    -DCMAKE_BUILD_TYPE=MinSizeRel \
    -DBUILD_SHARED_LIBS=ON \
    -DCLIENT_TESTING=OFF \
    -DSERVER_TESTING=OFF \
    -DUNIT_TESTING=OFF \
    -DWITH_GSSAPI=OFF \
    -DWITH_SERVER=OFF \
    -DWITH_PCAP=OFF \
    -DWITH_ZLIB=ON
make
make install/strip
popd

>&2 echo
>&2 echo
>&2 echo ================
>&2 echo Building wheels:
>&2 echo ================
>&2 echo
export CFLAGS="'-I${LIBSSH_CLONE_DIR}/include' '-I${STATIC_DEPS_PREFIX}/include' '-I${BUILD_DIR}/libssh/include' ${CFLAGS}"
for PY in $PYTHONS; do
    PIP_BIN="/opt/python/${PY}/bin/pip"
    cleanup_garbage
    >&2 echo Using "${PIP_BIN}"...
    ${PIP_BIN} install -U 'pip >= 20' setuptools wheel ${PIP_GLOBAL_ARGS}
    ${PIP_BIN} wheel "${SRC_DIR}" -w "${ORIG_WHEEL_DIR}" ${PIP_GLOBAL_ARGS}
done

>&2 echo
>&2 echo
>&2 echo ================
>&2 echo Reparing wheels:
>&2 echo ================
>&2 echo
# Bundle external shared libraries into the wheels
for PY in $PYTHONS; do
    for whl in ${ORIG_WHEEL_DIR}/${DIST_NAME}-*-${PY}-linux_${ARCH}.whl; do
        for MANYLINUX_VER in 1 2010 2014; do
            cleanup_garbage
            >&2 echo Reparing "${whl}" for manylinux${MANYLINUX_VER}_${ARCH}...
            auditwheel repair --plat manylinux${MANYLINUX_VER}_${ARCH} "${whl}" -w ${MANYLINUX_DIR}
        done
    done
done

>&2 echo
>&2 echo
>&2 echo =========================================================
>&2 echo Split manylinux1, manylinux2010 and manylinux2014 wheels:
>&2 echo =========================================================
>&2 echo
mkdir -pv "${MANYLINUX_DIR}"/{1,2010,2014}
for MANYLINUX_VER in 1 2010 2014; do
    mv -v "${MANYLINUX_DIR}"/${DIST_NAME}-*-cp*-cp*-manylinux${MANYLINUX_VER}_${ARCH}.whl "${MANYLINUX_DIR}/${MANYLINUX_VER}/"
done

# Download deps
>&2 echo
>&2 echo
>&2 echo =========================
>&2 echo Downloading dependencies:
>&2 echo =========================
>&2 echo
for PY in $PYTHONS; do
    #for WHEEL_FILE in `ls ${MANYLINUX_DIR}/{1,2010,2014}/${DIST_NAME}-*-${PY}-manylinux{1,2010,2014}_${ARCH}.whl`; do
    for WHEEL_FILE in `ls ${MANYLINUX_DIR}/1/${DIST_NAME}-*-${PY}-manylinux{1,2010,2014}_${ARCH}.whl`; do
        PIP_BIN="/opt/python/${PY}/bin/pip"
        cleanup_garbage
        >&2 echo Downloading ${WHEEL_FILE} deps using ${PIP_BIN}...
        ${PIP_BIN} download -d "${WHEEL_DEP_DIR}" "${WHEEL_FILE}" ${PIP_GLOBAL_ARGS}
    done
done

>&2 echo
>&2 echo ===================
>&2 echo Creating test venvs
>&2 echo ===================
>&2 echo
for PY in $PYTHONS; do
    #for MANYLINUX_VER in 1 2010 2014; do
    for MANYLINUX_VER in 1; do
        VENV_NAME="${PY}-${MANYLINUX_VER}"
        VENV_PATH="${VENVS_DIR}/${VENV_NAME}"
        VENV_BIN="/opt/python/${PY}/bin/virtualenv"

        >&2 echo
        >&2 echo Creating a venv at ${VENV_PATH}...
        ${VENV_BIN} "${VENV_PATH}"
    done
done

# Install packages
>&2 echo
>&2 echo
>&2 echo ============================
>&2 echo Testing wheels installation:
>&2 echo ============================
>&2 echo
for PY in $PYTHONS; do
    #for MANYLINUX_VER in 1 2010 2014; do
    for MANYLINUX_VER in 1; do
        VENV_NAME="${PY}-${MANYLINUX_VER}"
        VENV_PATH="${VENVS_DIR}/${VENV_NAME}"
        PIP_BIN="${VENV_PATH}/bin/pip"
        cleanup_garbage
        >&2 echo Using ${PIP_BIN}...
        ${PIP_BIN} install --no-compile "${DIST_NAME}" --no-index -f "${MANYLINUX_DIR}/${MANYLINUX_VER}/" ${PIP_GLOBAL_ARGS}
    done
done

# Running analysis
>&2 echo
>&2 echo
>&2 echo =============
>&2 echo SMOKE TESTING
>&2 echo =============
>&2 echo
for PY_BIN in `ls ${VENVS_DIR}/*/bin/python`; do
    cleanup_garbage
    >&2 echo
    >&2 echo Smoke-testing ${IMPORTABLE_PKG} imports under ${PY_BIN}...
    $PY_BIN -B -V
    $PY_BIN -B -c "
from __future__ import print_function  # needed for file=sys.stderr

import sys

import ${IMPORTABLE_PKG}
from ${IMPORTABLE_PKG}.version import LIBSSH_VERSION
print('libssh version: {!s}\n'.format(LIBSSH_VERSION))

try:
    from ${IMPORTABLE_PKG}.channel import Channel
except ImportError as imp_exc:
    print(
        'Failed to import Channel from '
        '${IMPORTABLE_PKG}.channel: {!r}'.
        format(imp_exc), file=sys.stderr,
    )
    if sys.version_info[0] != 2:  # FIXME: drop if fixed
        raise
    Channel = None
from ${IMPORTABLE_PKG}.errors import LibsshSessionException
from ${IMPORTABLE_PKG}.session import Session
from ${IMPORTABLE_PKG}.sftp import SFTP

print(
    'imported objects: {!r} {!r} {!r} {!r}\n'.
    format(Channel, LibsshSessionException, Session, SFTP),
    file=sys.stderr,
)
    "
done

cleanup_garbage
>&2 echo
>&2 echo ==============
>&2 echo WHEEL ANALYSIS
>&2 echo ==============
>&2 echo
for PY in $PYTHONS; do
    for MANYLINUX_VER in 1 2010 2014; do
        WHEEL_BIN="/opt/python/${PY}/bin/wheel"
        PLAT_TAG=${PY}-manylinux${MANYLINUX_VER}_${ARCH}
        UNPACKED_DIR=${UNPACKED_WHEELS_DIR}/${PLAT_TAG}
        WHEEL_FILE=`ls ${MANYLINUX_DIR}/${MANYLINUX_VER}/${DIST_NAME}-*-${PLAT_TAG}.whl`
        >&2 echo
        >&2 echo Analysing ${WHEEL_FILE}...
        auditwheel show "${WHEEL_FILE}"
        ${WHEEL_BIN} unpack -d "${UNPACKED_DIR}" "${WHEEL_FILE}"
        # chmod avoids ldd warning about files being non-executable:
        chmod +x "${UNPACKED_DIR}"/${DIST_NAME}-*/{${DIST_NAME}.libs/*.so.*,${IMPORTABLE_PKG}/*.so}
        >&2 echo Verifying that all links in '`*.so`' files of ${WHEEL_FILE} exist...
        ! ldd "${UNPACKED_DIR}"/${DIST_NAME}-*/{${DIST_NAME}.libs/*.so.*,${IMPORTABLE_PKG}/*.so} | grep '=> not found'
    done
done

>&2 echo
>&2 echo
>&2 echo ==================================
>&2 echo Running test suite against wheels:
>&2 echo ==================================
>&2 echo
cp -vr "${TESTS_SRC_DIR}" "${TESTS_DIR}"
cp -v "${SRC_DIR}/pytest.ini" "${TESTS_DIR}/"
#cp -v "${SRC_DIR}/.coveragerc" "${TESTS_DIR}/"
pushd "${TESTS_DIR}"
for PY_BIN in `ls ${VENVS_DIR}/*/bin/python`; do
    cleanup_garbage
    #$PY_BIN -B -m pip install --no-compile Cython pytest pytest-cov pytest-xdist ${PIP_GLOBAL_ARGS}
    $PY_BIN -B -m pip install --no-compile pytest pytest-cov pytest-xdist ${PIP_GLOBAL_ARGS}
    $PY_BIN -B -m pytest "${TESTS_DIR}"
done
popd

>&2 echo
>&2 echo
>&2 echo ==================
>&2 echo SELF-TEST COMPLETE
>&2 echo ==================
>&2 echo

cleanup_garbage

>&2 echo Copying built manylinux wheels back to the host...
chown -R --reference="${PERM_REF_HOST_FILE}" "${MANYLINUX_DIR}"/*
mkdir -pv "${WHEELHOUSE_DIR}"
chown --reference="${PERM_REF_HOST_FILE}" "${WHEELHOUSE_DIR}"
for MANYLINUX_VER in 1 2010 2014; do
    cp -av "${MANYLINUX_DIR}/${MANYLINUX_VER}"/*.whl "${WHEELHOUSE_DIR}/"
done
>&2 echo Final OS-specific wheels for ${DIST_NAME}:
ls -l ${WHEELHOUSE_DIR}
