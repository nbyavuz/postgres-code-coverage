#!/bin/bash

set -ex

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

CURRENT_PG_DIR="${PROJECT_DIR}/postgres_current"
BASELINE_PG_DIR="${PROJECT_DIR}/postgres_baseline"

UNIVERSAL_DIFF_FILE="${PROJECT_DIR}/universal_diff"

clear_dirs()
{
    printf "Clearing directories.\n"
    rm -rf ${CURRENT_PG_DIR} ${BASELINE_PG_DIR} ${LCOV_DIR} ${LCOV_INSTALL_PREFIX} ${LCOV_OUTPUT_DIR} ${LCOV_HTML_OUTPUT_DIR} ${UNIVERSAL_DIFF_FILE} ${MESON_DIR}
    printf "Done.\n\n"
}

install_lcov()
{
    printf "Cloning lcov to ${LCOV_DIR}.\n"
    git clone ${LCOV_REPO} --single-branch --branch "v2.3.2" ${LCOV_DIR}
    printf "Done.\n\n"

    printf "Installing lcov to ${LCOV_INSTALL_PREFIX}.\n"
    make PREFIX=${LCOV_INSTALL_PREFIX} -C ${LCOV_DIR} install
    printf "Done.\n\n"
}

install_postgres() {
    printf "Cloning Postgres to %s.\n" "${CURRENT_PG_DIR}"
    git clone "${PG_REPO}" "${CURRENT_PG_DIR}"
    printf "Clone done.\n\n"

    printf "Copying Postgres to %s.\n" "${BASELINE_PG_DIR}"
    rm -rf "${BASELINE_PG_DIR}"
    cp -r "${CURRENT_PG_DIR}" "${BASELINE_PG_DIR}"
    printf "Copy done.\n\n"
}

build_postgres_make()
{
    pg_dir=$1
    hash=$2

    printf "Building Postgres in ${pg_dir} by using make.\n"
    (cd ${pg_dir} && git reset -q --hard ${hash})

    (cd ${pg_dir} && ./configure \
        --enable-coverage \
        --enable-cassert \
        --enable-injection-points \
        --enable-debug \
        --enable-tap-tests \
        --enable-nls \
        --with-gssapi \
        --with-icu \
        --with-ldap \
        --with-libxml \
        --with-libxslt \
        --with-llvm \
        --with-lz4 \
        --with-pam \
        --with-perl \
        --with-python \
        --with-selinux \
        --with-ssl=openssl \
        --with-systemd \
        --with-uuid=ossp \
        --with-zstd \
        --with-tcl --with-tclconfig=/usr/lib/tcl8.6/
    )

    (cd ${pg_dir} && make -s -j16 world-bin)

    printf "Done.\n\n"
}

run_tests_postgres()
{
    pg_dir=$1
    printf "Running tests in ${pg_dir}.\n"
    (cd ${pg_dir} && make -s -j16 check-world)
    printf "Done.\n\n"
}

run_lcov()
{
    pg_dir=$1
    out_file=$2
    initial=$3

    LCOV_OPTIONS=(
        --ignore-errors "gcov,gcov,inconsistent,inconsistent,negative,negative,"
        --all
        --capture
        --parallel 16
        --exclude "/usr/*"
        --filter range
        --branch-coverage
        --rc branch_coverage=1
        --directory "${pg_dir}"
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

    build_postgres_make ${BASELINE_PG_DIR} ${BASELINE_COMMIT_HASH}
    BASELINE_COVERAGE_FILE="${LCOV_OUTPUT_DIR}/baseline_${BASELINE_COMMIT_HASH}"
    run_tests_postgres ${BASELINE_PG_DIR}
    run_lcov ${BASELINE_PG_DIR} ${BASELINE_COVERAGE_FILE}

    printf "Baseline coverage file is generated now.\n\n"
}

get_current_coverage_file()
{
    CURRENT_COMMIT_HASH=$(cd ${CURRENT_PG_DIR} && git rev-parse HEAD)
    CURRENT_COMMIT_DATE=$(cd ${CURRENT_PG_DIR} && git show -s --format=%ci ${CURRENT_COMMIT_HASH})

    printf "Generating current coverage file.\n"

    build_postgres_make ${CURRENT_PG_DIR} ${CURRENT_COMMIT_HASH}
    CURRENT_COVERAGE_FILE="${LCOV_OUTPUT_DIR}/current_${CURRENT_COMMIT_HASH}"
    run_tests_postgres ${CURRENT_PG_DIR}
    run_lcov ${CURRENT_PG_DIR} ${CURRENT_COVERAGE_FILE}

    printf "Current coverage file is generated now.\n\n"
}

run_genhtml()
{
    printf "Generating universal diff file.\n\n"
    (cd ${CURRENT_PG_DIR} &&  git diff --relative --src-prefix="${BASELINE_PG_DIR}/" --dst-prefix="${CURRENT_PG_DIR}/"  ${BASELINE_COMMIT_HASH} ${CURRENT_COMMIT_HASH} > ${UNIVERSAL_DIFF_FILE})
    printf "Done.\n\n"

    GENHTML_OPTIONS=(
        --ignore-errors "range,inconsistent,count,count"
        --parallel 16
        --legend
        --num-spaces 4
        --title "${CURRENT_COMMIT_HASH}"
        --hierarchical
        --show-navigation
        --show-proportion
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
        # --show-details

    )

    printf "Running genhtml to generate HTML report at ${LCOV_HTML_OUTPUT_DIR}.\n"
    echo "Genhtml command is ${LCOV_BIN_DIR}/genhtml ${GENHTML_OPTIONS[@]}"
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
