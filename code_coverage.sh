#!/bin/bash

set -ex

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
BASELINE_PG_DIR="${POSTGRES_DIR}_baseline"
CURRENT_PG_DIR="${POSTGRES_DIR}_current"

BASELINE_COVERAGE_FILE="${LCOV_OUTPUT_DIR}/lcov-${DATE}-baseline"
CURRENT_COVERAGE_FILE="${LCOV_OUTPUT_DIR}/lcov-${DATE}-current"

UNIVERSAL_DIFF_FILE="${CURRENT_DIR}/universal_diff"

GIT_CLONE_OPTIONS=(
    --depth 1
)

clear_dirs()
{
    echo "${POSTGRES_DIR}*"
    printf "Clearing directories.\n"
    rm -rf ${LCOV_DIR} ${LCOV_INSTALL_PREFIX} ${MESON_DIR} ${POSTGRES_DIR}* ${OUTDIR} ${UNIVERSAL_DIFF_FILE} ${LCOV_OUTPUT_DIR}
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

    BASELINE_COMMIT_HASH=$(cd "${POSTGRES_DIR}" && git rev-parse $(git branch -a --list "*REL_*_STABLE*" | awk '{print $NF}' | sort -t'_' -k2,2Vr | head -n1))
    BASELINE_COMMIT_DATE=$(cd "${POSTGRES_DIR}" && git show -s --format=%ci ${BASELINE_COMMIT_HASH})

    CURRENT_COMMIT_HASH=$(cd ${POSTGRES_DIR} && git rev-parse HEAD)
    CURRENT_COMMIT_DATE=$(cd ${POSTGRES_DIR} && git show -s --format=%ci ${CURRENT_COMMIT_HASH})

    printf "Generating universal diff file.\n\n"
    (cd ${POSTGRES_DIR} && git diff --relative --src-prefix="${BASELINE_PG_DIR}/" --dst-prefix="${CURRENT_PG_DIR}/" ${BASELINE_COMMIT_HASH} ${CURRENT_COMMIT_HASH} > ${UNIVERSAL_DIFF_FILE})
    printf "Done.\n\n"

    cp -R ${POSTGRES_DIR} "${BASELINE_PG_DIR}"
    mv ${POSTGRES_DIR} "${CURRENT_PG_DIR}"
}

build_postgres_meson()
{
    POSTGRES_BUILD_OPTIONS=(
        --wipe
        --clearcache
        -Db_coverage=true
        -Dcassert=true
        -Dtap_tests=enabled
        -DPG_TEST_EXTRA="kerberos ldap ssl load_balance libpq_encryption wal_consistency_checking xid_wraparound"
        --buildtype=debug
    )

    install_meson

    pg_dir="$2"
    build_dir="${pg_dir}_build"

    rm -rf ${build_dir}
    printf "Building Postgres to ${build_dir} by using meson. Commit hash is ${1}\n"
    $(cd ${pg_dir} && git reset -q --hard ${1})
    ${MESON_BINARY} setup "${POSTGRES_BUILD_OPTIONS[@]}" "${build_dir}" ${pg_dir}
    ${MESON_BINARY} compile -C ${build_dir}
    ${MESON_BINARY} test --quiet -C ${build_dir}
    printf "Done.\n\n"
}

# Takes commit hash argument as $1.
run_lcov()
{
    pg_dir="$2"
    build_dir="${pg_dir}_build"

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
        --include "**${pg_dir}/**"
        --directory "${build_dir}"
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
    GENHTML_OPTIONS=(
        --ignore-errors "inconsistent,range"
        --parallel 16
        --legend
        --num-spaces 4
        --hierarchical
        --show-navigation
        --show-proportion
        --branch-coverage
        --rc branch_coverage=1
        --date-bins 1,7,30,360
        --title "Differential Code coverage report between ${BASELINE_COMMIT_HASH} and ${CURRENT_COMMIT_HASH}"
        --current-date "${CURRENT_COMMIT_DATE}"
        --baseline-date "${BASELINE_COMMIT_DATE}"
        --annotate-script ${LCOV_DIR}/scripts/gitblame
        --baseline-file ${BASELINE_COVERAGE_FILE}
        --diff-file ${UNIVERSAL_DIFF_FILE}
        --output-directory ${LCOV_HTML_OUTPUT_DIR}/lcov-html-${DATE}
        ${CURRENT_COVERAGE_FILE}
        # genhtml: ERROR: unexpected branch TLA UNC for count 0
        # --show-details
    )

    printf "Running genhtml to generate HTML report at ${LCOV_HTML_OUTPUT_DIR}.\n"
    mkdir -p ${LCOV_HTML_OUTPUT_DIR}
    ${LCOV_BIN_DIR}/genhtml "${GENHTML_OPTIONS[@]}"
    printf "Done.\n\n"
}

get_baseline_coverage_file()
{
    printf "Generating latest release's coverage file.\n"
    build_postgres_meson ${BASELINE_COMMIT_HASH} ${BASELINE_PG_DIR}
    run_lcov $BASELINE_COVERAGE_FILE ${BASELINE_PG_DIR}
    printf "Latest release's coverage file is generated now.\n\n"
}

get_current_coverage_file()
{
    printf "Generating current coverage file.\n"
    build_postgres_meson ${CURRENT_COMMIT_HASH} ${CURRENT_PG_DIR}
    run_lcov ${CURRENT_COVERAGE_FILE} ${CURRENT_PG_DIR}
    printf "Current coverage file is generated now.\n\n"
}


# install_packages
clear_dirs
install_lcov
install_postgres

get_baseline_coverage_file
get_current_coverage_file

run_genhtml
