# postgres-code-coverage

This repository provides a helper script, **`code_coverage.sh`**, for generating **differential code coverage reports** using `lcov` and `genhtml`.
It is designed to be used both locally and in CI environments.

---

## Usage

```bash
./code_coverage.sh <INSTALL_PACKAGES> <N_PARALLEL>
```

---

### Arguments

---

**INSTALL_PACKAGES** is used for installing Postgres dependencies. Available values are `true` and `false`. It is `false` as default.

**N_PARALLEL** is used for setting number of parallel jobs to be used in `lcov` and `genhtml`. It is default to 1.

---

### General Usage


```bash
./code_coverage.sh false 16
```

---