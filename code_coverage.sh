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

CURRENT_COMMIT_HASH=""
CURRENT_COVERAGE_FILE=""
CURRENT_COMMIT_DATE=""
PREV_COMMIT_HASH=""
PREV_COVERAGE_FILE=""
PREV_COMMIT_DATE=""

UNIVERSAL_DIFF_FILE="${CURRENT_DIR}/universal_diff"

GIT_CLONE_OPTIONS=(
    --depth 1
)

clear_dirs()
{
    printf "Clearing directories.\n"
    rm -rf ${LCOV_DIR} ${LCOV_INSTALL_PREFIX} ${MESON_DIR} ${POSTGRES_DIR} ${POSTGRES_BUILD_DIR} ${OUTDIR} ${UNIVERSAL_DIFF_FILE} lcov-*
    printf "Done.\n\n"
}

install_packages()
{
    printf "Installing required packages like make, gcc...\n"
    apt update && \
    apt install build-essential git -y
    printf "Done.\n\n"
}

install_lcov()
{
    printf "Cloning lcov to ${LCOV_DIR}.\n"
    git clone "${GIT_CLONE_OPTIONS[@]}" https://github.com/linux-test-project/lcov.git ${LCOV_DIR}
    printf "Done.\n\n"

    printf "Installing lcov to ${LCOV_INSTALL_PREFIX}.\n"
    make PREFIX=${LCOV_INSTALL_PREFIX} -C ${LCOV_DIR} install
    printf "Done.\n\n"
}

install_meson()
{
    printf "Installing meson to ${MESON_DIR}.\n"

    if [ -e ${MESON_BINARY} ]; then
        printf "Meson is already installed, continue.\n\n"
        return
    fi

    git clone "${GIT_CLONE_OPTIONS[@]}" https://github.com/mesonbuild/meson.git ${MESON_DIR}
    printf "Done.\n\n"
}

install_postgres()
{
    printf "Cloning Postgres to ${POSTGRES_DIR}.\n"
    git clone https://github.com/postgres/postgres.git ${POSTGRES_DIR}
    printf "Done.\n\n"
}

build_postgres_meson()
{
    POSTGRES_BUILD_OPTIONS=(
        --wipe
        --clearcache
        -Db_coverage=true
        -Dcassert=true
        -Dtap_tests=enabled
        # -DPG_TEST_EXTRA="kerberos ldap ssl load_balance libpq_encryption wal_consistency_checking xid_wraparound"
        --buildtype=debug
    )

    install_meson

    rm -rf ${POSTGRES_BUILD_DIR}
    printf "Building Postgres to ${POSTGRES_BUILD_DIR} by using meson.\n"
    ${MESON_BINARY} setup "${POSTGRES_BUILD_OPTIONS[@]}" ${POSTGRES_BUILD_DIR} ${POSTGRES_DIR}
    ${MESON_BINARY} compile -C ${POSTGRES_BUILD_DIR}
    ${MESON_BINARY} test --quiet -C ${POSTGRES_BUILD_DIR}
    printf "Done.\n\n"
}

# Takes commit hash argument as $1.
run_lcov()
{
    LCOV_OPTIONS=(
        --ignore-errors "empty,empty,negative,negative,inconsistent,inconsistent,gcov,gcov"
        --all
        --capture
        --quiet
        --parallel 16
        --filter range
        # for some reason this does not suffice, --rc branch_coverage=1 is required
        --branch-coverage
        --rc branch_coverage=1
        --include "**${POSTGRES_DIR}/**"
        --directory ${POSTGRES_BUILD_DIR}
        -o lcov-${1}
    )

    printf "Running lcov.\n"
    ${LCOV_BIN_DIR}/lcov "${LCOV_OPTIONS[@]}"
    printf "Done.\n\n"
}

read_previous_coverage_file()
{
    PREV_COVERAGE_FILE=$(ls old-* 2>/dev/null | head -n 1)

    if [ -e "$PREV_COVERAGE_FILE" ]; then
        prinft "File found: $PREV_COVERAGE_FILE.\n"
    else
        printf "No file found.\n"
        printf "Retrieving commit hash from one day before...\n"
        PREV_COMMIT_HASH=$(cd ${POSTGRES_DIR} && git log -1 --before="1 day ago" --pretty=format:%h)
        PREV_COMMIT_DATE=$(cd ${POSTGRES_DIR} && git show -s --format=%ci ${PREV_COMMIT_HASH})
        printf "Previous commit hash = ${PREV_COMMIT_HASH}.\n"
    fi
}

# Takes commit hash argument as $1.
run_genhtml()
{
    printf "Generating universal diff file.\n\n"
    (cd ${POSTGRES_DIR} && git diff --relative ${PREV_COMMIT_HASH} ${CURRENT_COMMIT_HASH} > ${UNIVERSAL_DIFF_FILE})
    printf "Done.\n\n"

    GENHTML_OPTIONS=(
        --ignore-errors "path,path,package,package,unmapped,empty,inconsistent,inconsistent,corrupt,mismatch,mismatch,child,child,range,range"
        --parallel 16
        --quiet
        --legend
        --num-spaces 4
        --branch-coverage
        --rc branch_coverage=1
        --date-bins 1
        --current-date "${CURRENT_COMMIT_DATE}"
        --baseline-date "${PREV_COMMIT_DATE}"
        --annotate-script ${LCOV_DIR}/scripts/gitblame
        --baseline-file ${PREV_COVERAGE_FILE}
        --diff-file ${UNIVERSAL_DIFF_FILE}
        --output-directory ${CURRENT_DIR}/lcov-html-diff
        ${CURRENT_DIR}/${CURRENT_COVERAGE_FILE}
        # genhtml: ERROR: unexpected branch TLA UNC for count 0
        # --show-navigation
        # --show-details
        # --show-proportion
    )

    printf "Running genhtml to generate HTML report at lcov-html-diff.\n"
    ${LCOV_BIN_DIR}/genhtml "${GENHTML_OPTIONS[@]}"
    printf "Done.\n\n"
}

get_prev_coverage_file()
{
    printf "Reading previous coverage file.\n"
    read_previous_coverage_file

    if [ -n "$PREV_COMMIT_HASH" ]; then
        printf "Previous coverage file not found, getting it by building Postgres...\n"
        (cd ${POSTGRES_DIR} && git reset --hard ${PREV_COMMIT_HASH})
        build_postgres_meson
        run_lcov ${PREV_COMMIT_HASH}
        PREV_COVERAGE_FILE="lcov-${PREV_COMMIT_HASH}"
        printf "Previous coverage file is generated now.\n\n"
    fi
}

get_current_coverage_file()
{
    printf "Generating current coverage file.\n"
    (cd ${POSTGRES_DIR} && git reset --hard origin)
    CURRENT_COMMIT_HASH=$(cd ${POSTGRES_DIR} && git log -1 --pretty=format:%h)
    CURRENT_COMMIT_DATE=$(cd ${POSTGRES_DIR} && git show -s --format=%ci ${CURRENT_COMMIT_HASH})
    build_postgres_meson
    run_lcov ${CURRENT_COMMIT_HASH}
    CURRENT_COVERAGE_FILE="lcov-${CURRENT_COMMIT_HASH}"
    printf "Current coverage file is generated now.\n\n"
}

# install_packages
clear_dirs
install_lcov
install_postgres

get_prev_coverage_file
get_current_coverage_file

run_genhtml
