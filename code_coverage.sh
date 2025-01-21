#!/bin/bash

set -e

CURRENT_DIR=$(pwd)
# Maybe only +%Y%m%d as this script will run daily.
DATE=$(date +%Y%m%d-%H%M%S)

PG_REPO=https://github.com/postgres/postgres.git
LCOV_REPO=https://github.com/linux-test-project/lcov.git
MESON_REPO=https://github.com/mesonbuild/meson.git

LCOV_DIR=${CURRENT_DIR}/lcov
LCOV_INSTALL_PREFIX=${CURRENT_DIR}/lcov_install
LCOV_BIN_DIR=${LCOV_INSTALL_PREFIX}/bin
LCOV_OUTPUT_DIR=${CURRENT_DIR}/lcov-outputs
LCOV_HTML_OUTPUT_DIR=${CURRENT_DIR}/lcov-html-outputs

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
    rm -rf ${LCOV_DIR} ${LCOV_INSTALL_PREFIX} ${MESON_DIR} ${POSTGRES_DIR} ${POSTGRES_BUILD_DIR} ${OUTDIR} ${UNIVERSAL_DIFF_FILE} ${LCOV_OUTPUT_DIR}
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
    git clone "${GIT_CLONE_OPTIONS[@]}" ${LCOV_REPO} ${LCOV_DIR}
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

    git clone "${GIT_CLONE_OPTIONS[@]}" ${MESON_REPO} ${MESON_DIR}
    printf "Done.\n\n"
}

install_postgres()
{
    printf "Cloning Postgres to ${POSTGRES_DIR}.\n"
    git clone ${PG_REPO} ${POSTGRES_DIR}
    printf "Done.\n\n"

    CURRENT_COMMIT_HASH=$(cd ${POSTGRES_DIR} && git rev-parse HEAD)
    CURRENT_COMMIT_DATE=$(cd ${POSTGRES_DIR} && git show -s --format=%ci ${CURRENT_COMMIT_HASH})
}

build_postgres_meson()
{
    POSTGRES_BUILD_OPTIONS=(
        --wipe
        --clearcache
        -Db_coverage=true
        -Dcassert=true
        -Dtap_tests=enabled
        #-DPG_TEST_EXTRA="kerberos ldap ssl load_balance libpq_encryption wal_consistency_checking xid_wraparound"
        --buildtype=debug
    )

    install_meson

    rm -rf ${POSTGRES_BUILD_DIR}
    printf "Building Postgres to ${POSTGRES_BUILD_DIR} by using meson.\n"
    $(cd ${POSTGRES_DIR} && git reset -q --hard ${1})
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
        -o ${1}
    )

    printf "Running lcov.\n"
    mkdir -p ${LCOV_OUTPUT_DIR}
    ${LCOV_BIN_DIR}/lcov "${LCOV_OPTIONS[@]}"
    printf "Done.\n\n"
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
        --date-bins 1,7,30,360
        --current-date "${CURRENT_COMMIT_DATE}"
        --baseline-date "${PREV_COMMIT_DATE}"
        --annotate-script ${LCOV_DIR}/scripts/gitblame
        --baseline-file ${PREV_COVERAGE_FILE}
        --diff-file ${UNIVERSAL_DIFF_FILE}
        --output-directory ${LCOV_HTML_OUTPUT_DIR}/lcov-html-${DATE}
        ${CURRENT_COVERAGE_FILE}
        # genhtml: ERROR: unexpected branch TLA UNC for count 0
        # --show-navigation
        # --show-details
        # --show-proportion
    )

    printf "Running genhtml to generate HTML report at ${LCOV_HTML_OUTPUT_DIR}.\n"
    mkdir -p ${LCOV_HTML_OUTPUT_DIR}
    ${LCOV_BIN_DIR}/genhtml "${GENHTML_OPTIONS[@]}"
    printf "Done.\n\n"
}

get_prev_coverage_file()
{
    PREV_COMMIT_HASH=$(cd ${POSTGRES_DIR} && git rev-parse $(git branch -a --list "*REL_*_STABLE*" | awk '{print $NF}' | sort -t'_' -k2,2Vr | head -n1))
    PREV_COMMIT_DATE=$(cd ${POSTGRES_DIR} && git show -s --format=%ci ${PREV_COMMIT_HASH})

    printf "Generating latest release's coverage file.\n"
    build_postgres_meson ${PREV_COMMIT_HASH}
    PREV_COVERAGE_FILE="${LCOV_OUTPUT_DIR}/lcov-${DATE}-prev"
    run_lcov $PREV_COVERAGE_FILE
    printf "Latest release's coverage file is generated now.\n\n"
}

get_current_coverage_file()
{
    printf "Generating current coverage file.\n"
    build_postgres_meson ${CURRENT_COMMIT_HASH}
    CURRENT_COVERAGE_FILE="${LCOV_OUTPUT_DIR}/lcov-${DATE}-current"
    run_lcov ${CURRENT_COVERAGE_FILE}
    printf "Current coverage file is generated now.\n\n"
}

# install_packages
clear_dirs
install_lcov
install_postgres

get_prev_coverage_file
get_current_coverage_file

run_genhtml
