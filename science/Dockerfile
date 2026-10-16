# Scientific computing: the base image plus the statistics stack that
# analyses in Python and in R use, so that an analysis runs with nothing
# installed first. A sandbox cannot add it at run time: its root file system
# is read-only, apt needs root, and R without built packages compiles every
# package from source, which takes tens of minutes and fails on a missing
# compiler or system library.
ARG BASE_IMAGE=sandbox-base:latest
FROM ${BASE_IMAGE}

USER root

# --- Python ---
# The libraries are Ubuntu 24.04's packages, as in the base image: built for
# the system Python and for Ubuntu's NumPy, and importable with no setup.
# The packages after pyreadstat are what libpysal, pingouin, and
# pandas-flavor below need.
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3-scipy \
    python3-statsmodels \
    python3-sklearn \
    python3-seaborn \
    python3-networkx \
    python3-shapely \
    python3-geopy \
    python3-pyreadstat \
    python3-geopandas \
    python3-packaging \
    python3-platformdirs \
    python3-tabulate \
    python3-xarray \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# pingouin, spreg, and uv are not in Ubuntu, and Ubuntu's libpysal records
# its version as 0.0.0, so pip takes every requirement on it as unmet: pip
# check fails, and installing a package that needs libpysal would install a
# second one. pip installs these four into /usr/local, outside the home
# directory. Each is pinned to a release whose requirements Ubuntu's
# packages meet: newer releases require NumPy 2, and a NumPy 2 beside
# Ubuntu's SciPy and pandas, which are built against NumPy 1, breaks their
# import. --no-deps keeps pip from fetching any requirement; Ubuntu's
# packages meet them all, and pip check fails the build when one does not.
# The build also fails if a package is installed twice, once by apt and once
# by pip (Ubuntu's xarray carries two records of itself in one directory,
# which is not that), and if a small spreg or pingouin fit fails, since
# spreg's stated requirements are looser than what it imports.
#
# uv is for project environments: `uv venv` and `uv pip install`. It is
# told to prefer the image's Python to downloading one into the home
# directory, and to copy from its cache rather than link, since the cache
# under HOME and a project under /workspace are on different file systems.
# The build does not run it: under QEMU, as when one platform is built on
# another, uv crashes with a segmentation fault, which it does not do on
# its own platform. test.sh runs it.
ARG LIBPYSAL_VERSION=4.13.0
ARG PINGOUIN_VERSION=0.6.1
ARG PANDAS_FLAVOR_VERSION=0.7.0
ARG SPREG_VERSION=1.9.0
ARG UV_VERSION=0.13.1
RUN pip install --no-deps --no-cache-dir \
        "libpysal==${LIBPYSAL_VERSION}" \
        "pingouin==${PINGOUIN_VERSION}" \
        "pandas-flavor==${PANDAS_FLAVOR_VERSION}" \
        "spreg==${SPREG_VERSION}" \
        "uv==${UV_VERSION}" && \
    pip check && \
    python3 -I -c "import collections, importlib.metadata as m, re; \
        found = collections.defaultdict(set); \
        [found[re.sub(r'[-_.]+', '-', d.metadata['Name']).lower()].add(str(d.locate_file(''))) for d in m.distributions()]; \
        twice = {n: p for n, p in found.items() if len(p) > 1}; \
        assert not twice, f'installed twice: {twice}'" && \
    MPLCONFIGDIR=/tmp/mplconfig python3 -I -c "import numpy as np, pingouin, spreg; \
        rng = np.random.default_rng(0); x = rng.normal(size=(60, 1)); y = 2 * x + rng.normal(size=(60, 1)); \
        beta = spreg.OLS(y, x).betas[1, 0]; assert abs(beta - 2) < 0.5, beta; \
        assert len(pingouin.ttest(x[:, 0], y[:, 0])) == 1" && \
    rm -rf /tmp/mplconfig /root/.cache
ENV UV_PYTHON_PREFERENCE=system
ENV UV_LINK_MODE=copy

# --- R ---
# R comes from CRAN's repository for Ubuntu 24.04, which carries current
# releases; Ubuntu's own R is 4.3. The signing key is vendored in this
# context, as the base image does for NodeSource, and the build asserts its
# fingerprint, so an edit to cran.gpg.key cannot swap the trust anchor
# unnoticed. R_VERSION pins the release.
#
# Only r-base-core comes from apt. Every R package, the recommended ones
# among them, comes from one source below, so that compiled packages match
# each other: lme4, for one, is built against a specific Matrix.
#
# The other packages here are the shared libraries the built R packages
# link against: GDAL, GEOS, PROJ, and udunits for spdep's spatial stack, and
# libuv and the image, text, and network libraries for tidyverse. The R
# step below fails the build if any is missing.
ARG R_VERSION=4.6.1
ARG CRAN_KEY_FPR=E298A3A825C0D65DFD57CBB651716619E084DAB9
COPY cran.gpg.key /tmp/cran.gpg.key
RUN gpg --show-keys --with-colons --with-fingerprint /tmp/cran.gpg.key \
        | awk -F: '$1 == "fpr" { print $10; exit }' \
        | grep -qx "${CRAN_KEY_FPR}" \
        || { echo "cran.gpg.key does not match CRAN_KEY_FPR" >&2; exit 1; } && \
    gpg --dearmor -o /usr/share/keyrings/cran.gpg /tmp/cran.gpg.key && \
    rm /tmp/cran.gpg.key && \
    echo "deb [signed-by=/usr/share/keyrings/cran.gpg] https://cloud.r-project.org/bin/linux/ubuntu noble-cran40/" \
        > /etc/apt/sources.list.d/cran.list && \
    apt-get update && apt-get install -y --no-install-recommends \
    "r-base-core=${R_VERSION}-*" \
    libgdal34t64 \
    libgeos-c1t64 \
    libproj25 \
    libudunits2-0 \
    libuv1t64 \
    libxml2 \
    libcurl4t64 \
    libfontconfig1 \
    libfreetype6 \
    libharfbuzz0b \
    libfribidi0 \
    libpng16-16t64 \
    libtiff6 \
    libjpeg-turbo8 \
    libwebp7 \
    && R --version | head -n 1 | grep -q "^R version ${R_VERSION} " \
    || { echo "R is not ${R_VERSION}: $(R --version | head -n 1)" >&2; exit 1; } && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# The site profile points install.packages() at Posit Package Manager's
# built packages for Ubuntu 24.04, at the snapshot date it names, and
# creates the user library under HOME; it explains both. The packages below
# are installed through it, so the build checks what a session relies on.
#
# The build fails if a package was built from source rather than installed
# built, if an install failed, if a package's shared object lacks a library,
# or if a package does not load. R_PACKAGES are the packages an analysis
# asks for by name; R_RECOMMENDED are those every R installation carries,
# which a session expects to find.
ARG R_PACKAGES="tidyverse lme4 lmerTest ordinal car emmeans afex psych spdep"
ARG R_RECOMMENDED="boot class cluster codetools foreign KernSmooth lattice MASS Matrix mgcv nlme nnet rpart spatial survival"
COPY --chmod=0644 Rprofile.site /etc/R/Rprofile.site
RUN Rscript -e "install.packages(strsplit('${R_RECOMMENDED} ${R_PACKAGES}', ' ')[[1]], \
            lib = '/usr/local/lib/R/site-library', Ncpus = parallel::detectCores())" \
        > /tmp/r-install.log 2>&1 \
        || { cat /tmp/r-install.log; exit 1; } && \
    if grep -E 'installing \*source\* package|non-zero exit status' /tmp/r-install.log; then \
        echo 'an R package was built from source or failed to install' >&2; exit 1; \
    fi && \
    missing="$(find /usr/local/lib/R/site-library -name '*.so' -exec ldd {} + 2>/dev/null \
        | awk '/:$/ { file = $1 } /not found/ { print file, $1 }')" && \
    if [ -n "${missing}" ]; then \
        echo "R packages lack shared libraries:" >&2; echo "${missing}" >&2; exit 1; \
    fi && \
    Rscript -e "for (p in strsplit('${R_RECOMMENDED} ${R_PACKAGES}', ' ')[[1]]) \
            suppressPackageStartupMessages(library(p, character.only = TRUE))" && \
    rm -rf /tmp/r-install.log /tmp/Rtmp* /root/R

# --- The package list ---
# What the image holds, per package manager, written from what is installed
# (list-packages says how). An orchestrator reads it to check the packages a
# session asks for against the image before the session starts, and a
# release publishes it in catalog.json.
COPY --chmod=0755 list-packages /usr/local/libexec/sandbox-images/list-packages
RUN mkdir -p /usr/share/sandbox-images && \
    /usr/local/libexec/sandbox-images/list-packages > /usr/share/sandbox-images/packages.json && \
    jq -e '.pip.scipy and .pip.pingouin and .pip.uv and .cran.lme4 and .cran.Matrix' \
        /usr/share/sandbox-images/packages.json >/dev/null \
    || { echo 'packages.json lacks a package the image installs' >&2; exit 1; }

USER agent
