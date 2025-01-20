#!/bin/bash

set -e

CURRENT_DIR=$(pwd)

LCOV_DIR=${CURRENT_DIR}/lcov
LCOV_INSTALL_PREFIX=${CURRENT_DIR}/lcov_install
LCOV_BIN_DIR=${LCOV_INSTALL_PREFIX}/bin

MESON_DIR=${CURRENT_DIR}/meson
MESON_BINARY=${MESON_DIR}/meson.py

OUTDIR=${CURRENT_DIR}/out
POSTGRES_DIR=${CURRENT_DIR}/postgres
POSTGRES_BUILD_DIR=${CURRENT_DIR}/postgres_build
COMMIT_HASH=""

GIT_CLONE_OPTIONS=(
    --depth 1
)

clear_dirs()
{
    printf "Clearing directories\n"
    rm -rf ${LCOV_DIR} ${LCOV_INSTALL_PREFIX} ${MESON_DIR} ${POSTGRES_DIR} ${POSTGRES_BUILD_DIR} ${OUTDIR} lcov-*
    printf "Done\n\n"
}

install_packages()
{
    printf "Installing required packages like make, gcc...\n"
    apt update && \
    apt install build-essential -y
    printf "Done\n\n"
}

install_lcov()
{
    printf "Cloning lcov to ${LCOV_DIR}\n"
    git clone "${GIT_CLONE_OPTIONS[@]}" https://github.com/linux-test-project/lcov.git ${LCOV_DIR}
    printf "Done\n\n"

    printf "Installing lcov to ${LCOV_INSTALL_PREFIX}\n"
    make PREFIX=${LCOV_INSTALL_PREFIX} -C ${LCOV_DIR} install
    printf "Done\n\n"
}

install_meson()
{
    printf "Installing meson to ${MESON_DIR}\n"
    git clone "${GIT_CLONE_OPTIONS[@]}" https://github.com/mesonbuild/meson.git ${MESON_DIR}
    printf "Done\n\n"
}

install_postgres()
{
    printf "Cloning Postgres to ${POSTGRES_DIR}\n"
    git clone "${GIT_CLONE_OPTIONS[@]}" https://github.com/postgres/postgres.git ${POSTGRES_DIR}
    COMMIT_HASH=$(cd ${POSTGRES_DIR} && git rev-parse --short HEAD)
    printf "Done\n\n"
}

build_postgres_meson()
{
    POSTGRES_BUILD_OPTIONS=(
        -Db_coverage=true
        -Dcassert=true
        -Dtap_tests=enabled
        -DPG_TEST_EXTRA="kerberos ldap ssl load_balance libpq_encryption wal_consistency_checking xid_wraparound"
        --buildtype=debug
    )

    install_meson

    printf "Building Postgres to ${POSTGRES_BUILD_DIR} by using meson\n"
    ${MESON_BINARY} setup "${POSTGRES_BUILD_OPTIONS[@]}" ${POSTGRES_BUILD_DIR} ${POSTGRES_DIR}
    ${MESON_BINARY} compile -C ${POSTGRES_BUILD_DIR}
    ${MESON_BINARY} test -C ${POSTGRES_BUILD_DIR}
    printf "Done\n\n"
}

build_postgres_make()
{
    printf "Building Postgres to ${POSTGRES_BUILD_DIR} by using make\n"
    JOBS=8
    POSTGRES_BUILD_DIR=${POSTGRES_DIR}
    cd ${POSTGRES_DIR}
    ./configure --enable-coverage
    make -s -j${JOBS}
    make check -s -j${JOBS}
    cd ${CURRENT_DIR}
    printf "Done\n\n"
}

run_lcov()
{
    LCOV_OPTIONS=(
        --ignore-errors "empty,negative,inconsistent"
        --all
        --capture
        --quiet
        --parallel 25
        # for some reason this does not suffice, --rc branch_coverage=1 is required
        --branch-coverage
        --rc branch_coverage=1
        --include "**${POSTGRES_DIR}/**"
        --directory ${POSTGRES_BUILD_DIR}
        -o lcov-${COMMIT_HASH}
    )

    printf "Running lcov\n"
    ${LCOV_BIN_DIR}/lcov "${LCOV_OPTIONS[@]}"
    printf "Done\n\n"

    GENHTML_OPTIONS=(
        --ignore-errors "unmapped,empty,inconsistent,corrupt,range"
        --quiet
        --legend
        --num-spaces 4
        --branch-coverage
        --rc branch_coverage=1
        --show-details
        --show-proportion
        # genhtml: ERROR: unexpected branch TLA UNC for count 0
        # --show-navigation
    )

    printf "Running genhtml to generate HTML report at lcov-${COMMIT_HASH}-html"
    ${LCOV_BIN_DIR}/genhtml \
     "${GENHTML_OPTIONS[@]}" \
     lcov-${COMMIT_HASH} \
     -o lcov-${COMMIT_HASH}-html
    printf "Done\n\n"
}

# install_packages
clear_dirs
install_lcov
install_postgres
build_postgres_meson
# build_postgres_make
run_lcov
