#!/bin/bash

set -e

PROJECT_DIR=$(cd "$(dirname "$0")" && pwd)
# Maybe only +%Y%m%d as this script will run daily.
DATE=$(date +%Y-%m-%d)
MOVE_FILES_TO_APACHE="${1:-false}"

PG_REPO=https://github.com/postgres/postgres.git
LCOV_REPO=https://github.com/linux-test-project/lcov.git
MESON_REPO=https://github.com/mesonbuild/meson.git

LCOV_DIR=${PROJECT_DIR}/lcov
LCOV_INSTALL_PREFIX=${PROJECT_DIR}/lcov_install
LCOV_BIN_DIR=${LCOV_INSTALL_PREFIX}/bin
LCOV_OUTPUT_DIR=${PROJECT_DIR}/lcov-outputs
LCOV_HTML_OUTPUT_DIR=${PROJECT_DIR}/lcov-html-outputs

MESON_DIR=${PROJECT_DIR}/meson
MESON_BINARY=${MESON_DIR}/meson.py

CURRENT_COMMIT_HASH=""
CURRENT_COVERAGE_FILE=""
CURRENT_COMMIT_DATE=""
CURRENT_PG_DIR="${PROJECT_DIR}/postgres_current"
CURRENT_PG_BUILD_DIR="${PROJECT_DIR}/postgres_current_build"

BASELINE_COMMIT_HASH=""
BASELINE_COVERAGE_FILE=""
BASELINE_COMMIT_DATE=""
BASELINE_VERSION=""
BASELINE_PG_DIR="${PROJECT_DIR}/postgres_baseline"
BASELINE_PG_BUILD_DIR="${PROJECT_DIR}/postgres_baseline_build"

UNIVERSAL_DIFF_FILE="${PROJECT_DIR}/universal_diff"

clear_dirs()
{
    printf "Clearing directories.\n"
    rm -rf ${LCOV_DIR} ${LCOV_INSTALL_PREFIX} ${LCOV_OUTPUT_DIR} ${LCOV_HTML_OUTPUT_DIR} ${CURRENT_PG_DIR} ${CURRENT_PG_BUILD_DIR} ${BASELINE_PG_DIR} ${BASELINE_PG_BUILD_DIR} ${UNIVERSAL_DIFF_FILE} ${MESON_DIR}
    printf "Done.\n\n"
}

install_lcov()
{
    printf "Cloning lcov to ${LCOV_DIR}.\n"
    git clone ${LCOV_REPO} --single-branch --branch "v2.3.1" ${LCOV_DIR}
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

    git clone ${MESON_REPO} --single-branch --branch "1.7.2" ${MESON_DIR}
    printf "Done.\n\n"
}

install_postgres()
{
    printf "Cloning Postgres to ${CURRENT_PG_DIR}.\n"
    git clone ${PG_REPO} ${CURRENT_PG_DIR}
    printf "Done.\n\n"

    printf "Copying Postgres to ${BASELINE_PG_DIR}.\n"
    cp -r ${CURRENT_PG_DIR} ${BASELINE_PG_DIR}
    printf "Done.\n\n"
}

build_postgres_meson()
{
    pg_dir=$1
    build_dir=$2
    hash=$3

    POSTGRES_BUILD_OPTIONS=(
        --wipe
        --clearcache
        -Db_coverage=true
        -Dcassert=true
        -Dinjection_points=true
        -Dllvm=enabled
        -Dtap_tests=enabled
        -Duuid=e2fs
        --buildtype=debugoptimized
        -DPG_TEST_EXTRA="kerberos ldap ssl load_balance libpq_encryption wal_consistency_checking xid_wraparound"
    )

    install_meson

    printf "Building Postgres to ${build_dir} by using meson.\n"
    $(cd ${pg_dir} && git reset -q --hard ${hash})
    ${MESON_BINARY} setup "${POSTGRES_BUILD_OPTIONS[@]}" ${build_dir} ${pg_dir}
    ${MESON_BINARY} compile -C ${build_dir}
    ${MESON_BINARY} test --quiet -C ${build_dir}
    printf "Done.\n\n"
}

run_lcov()
{
    pg_dir=$1
    build_dir=$2
    out_file=$3

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
        -o "${out_file}"
    )

    printf "Running lcov.\n"
    mkdir -p ${LCOV_OUTPUT_DIR}
    ${LCOV_BIN_DIR}/lcov "${LCOV_OPTIONS[@]}"
    printf "Done.\n\n"
}

get_baseline_coverage_file()
{
    BASELINE_COMMIT_HASH=$(cd ${BASELINE_PG_DIR} && git rev-parse $(cd ${BASELINE_PG_DIR} && git branch -a --list "*REL_*_STABLE*" | awk '{print $NF}' | sort -t'_' -k2,2Vr | head -n1))
    BASELINE_COMMIT_DATE=$(cd ${BASELINE_PG_DIR} && git show -s --format=%ci ${BASELINE_COMMIT_HASH})

    printf "Generating baseline coverage file.\n"
    build_postgres_meson ${BASELINE_PG_DIR} ${BASELINE_PG_BUILD_DIR} ${BASELINE_COMMIT_HASH}
    BASELINE_COVERAGE_FILE="${LCOV_OUTPUT_DIR}/${BASELINE_COMMIT_HASH}"
    run_lcov ${BASELINE_PG_DIR} ${BASELINE_PG_BUILD_DIR} ${BASELINE_COVERAGE_FILE}
    printf "Baseline coverage file is generated now.\n\n"
}

get_current_coverage_file()
{
    CURRENT_COMMIT_HASH=$(cd ${CURRENT_PG_DIR} && git rev-parse HEAD)
    CURRENT_COMMIT_DATE=$(cd ${CURRENT_PG_DIR} && git show -s --format=%ci ${CURRENT_COMMIT_HASH})

    printf "Generating current coverage file.\n"
    build_postgres_meson ${CURRENT_PG_DIR} ${CURRENT_PG_BUILD_DIR} ${CURRENT_COMMIT_HASH}
    CURRENT_COVERAGE_FILE="${LCOV_OUTPUT_DIR}/${CURRENT_COMMIT_HASH}"
    run_lcov ${CURRENT_PG_DIR} ${CURRENT_PG_BUILD_DIR} ${CURRENT_COVERAGE_FILE}
    printf "Current coverage file is generated now.\n\n"
}

run_genhtml()
{
    printf "Generating universal diff file.\n\n"
    (cd ${CURRENT_PG_DIR} && git diff --relative ${BASELINE_COMMIT_HASH} ${CURRENT_COMMIT_HASH} > ${UNIVERSAL_DIFF_FILE})
    printf "Done.\n\n"

    GENHTML_OPTIONS=(
        --ignore-errors "path,path,package,package,unmapped,empty,inconsistent,inconsistent,corrupt,mismatch,mismatch,child,child,range,range,parallel,parallel"
        --parallel 16
        --quiet
        --legend
        --num-spaces 4
        --title "${CURRENT_COMMIT_HASH}"
        --hierarchical
        --branch-coverage
        --rc branch_coverage=1
        --date-bins 1,7,30,360
        --current-date "${CURRENT_COMMIT_DATE}"
        --baseline-date "${BASELINE_COMMIT_DATE}"
        --annotate-script ${LCOV_DIR}/scripts/gitblame
        --baseline-file ${BASELINE_COVERAGE_FILE}
        --diff-file ${UNIVERSAL_DIFF_FILE}
        --output-directory ${LCOV_HTML_OUTPUT_DIR}/${DATE}
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

move_files_to_apache()
{
    printf "Moving files to the /var/www/html/.\n"
    sudo sh -c "cp -R \"${LCOV_HTML_OUTPUT_DIR}/${DATE}\" /var/www/html/"
    (sudo sh -c "cd /var/www/html && ls -d */ | sed 's#/##' | jq -R -s -c 'split(\"\n\")[:-1]' > /var/www/html/dates.json")
    sudo sh -c "cp \"${PROJECT_DIR}/index.html\" /var/www/html/index.html"
    printf "Done.\n\n"
}

clear_dirs
install_lcov
install_postgres
get_baseline_coverage_file
get_current_coverage_file
run_genhtml

if [ "$MOVE_FILES_TO_APACHE" = "true" ]; then
    move_files_to_apache
fi
