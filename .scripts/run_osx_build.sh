#!/usr/bin/env bash

# -*- mode: jinja-shell -*-

source .scripts/logging_utils.sh

set -xe

MINIFORGE_HOME="${MINIFORGE_HOME:-${HOME}/miniforge3}"
MINIFORGE_HOME="${MINIFORGE_HOME%/}" # remove trailing slash
export CONDA_BLD_PATH="${CONDA_BLD_PATH:-${MINIFORGE_HOME}/conda-bld}"
( startgroup "Provisioning base env with pixi" ) 2> /dev/null
mkdir -p "${MINIFORGE_HOME}"
curl -fsSL https://pixi.sh/install.sh | bash
export PATH="~/.pixi/bin:$PATH"
arch=$(uname -m)
if [[ "$arch" == "x86_64" ]]; then
  arch="64"
fi
sed -i.bak "s/platforms = .*/platforms = [\"osx-${arch}\"]/" pixi.toml
echo "Creating environment"
pixi install --environment build
pixi list --environment build
echo "Activating environment"
eval "$(pixi shell-hook --environment build)"
mv pixi.toml.bak pixi.toml
( endgroup "Provisioning base env with pixi" ) 2> /dev/null

( startgroup "Repairing perl on osx-arm64" ) 2> /dev/null
# TEMPORARY WORKAROUND for https://github.com/conda-forge/perl-feedstock/issues/78 --
# remove once conda-forge ships a fixed perl for osx-arm64.
# perl 5.32.1 build 8_h88b7d96_perl5 (osx-arm64) ships bin/perl and bin/perl5.32.1
# without any LC_RPATH, so their @rpath/perl5/5.32/core_perl/CORE/libperl.dylib
# dependency cannot be resolved and every perl invocation aborts. perl is pulled into
# the build env via git -> conda-forge-ci-setup, and conda-forge-ci-setup's
# download_osx_sdk.sh verifies the SDK tarball with `shasum`, which is a perl script --
# so the job dies before the recipe is even built. Build 7 of the same version has
# `LC_RPATH @loader_path/../lib/`, so put that back and re-sign (arm64 binaries need a
# valid signature). Note: a `conda-smithy rerender` will drop this block.
if [[ "$(uname -m)" == "arm64" ]]; then
  perl_bin="$(command -v perl || true)"
  # only touch the perl from the pixi env, never a system/SIP-protected one
  if [[ "${perl_bin}" == */.pixi/envs/build/bin/perl ]] && ! "${perl_bin}" -e 'exit 0' 2>/dev/null; then
    echo "perl at ${perl_bin} is broken, adding the missing rpath"
    for perl_exe in "${perl_bin}" "${perl_bin}"5.*; do
      [[ -f "${perl_exe}" ]] || continue
      /usr/bin/install_name_tool -add_rpath "@loader_path/../lib/" "${perl_exe}"
      /usr/bin/codesign --force --sign - "${perl_exe}"
    done
    "${perl_bin}" -e 'print "perl is usable again\n"'
  fi
fi
( endgroup "Repairing perl on osx-arm64" ) 2> /dev/null

( startgroup "Configuring conda" ) 2> /dev/null
export CONDA_SOLVER="libmamba"
export CONDA_LIBMAMBA_SOLVER_NO_CHANNELS_FROM_INSTALLED=1





echo -e "\n\nSetting up the condarc and mangling the compiler."
setup_conda_rc ./ ./recipe ./.ci_support/${CONFIG}.yaml

if [[ "${CI:-}" != "" ]]; then
  mangle_compiler ./ ./recipe .ci_support/${CONFIG}.yaml
fi

if [[ "${CI:-}" != "" ]]; then
  echo -e "\n\nMangling homebrew in the CI to avoid conflicts."
  /usr/bin/sudo mangle_homebrew
  /usr/bin/sudo -k
else
  echo -e "\n\nNot mangling homebrew as we are not running in CI"
fi

if [[ "${sha:-}" == "" ]]; then
  sha=$(git rev-parse HEAD)
fi

if [[ "${OSX_SDK_DIR:-}" == "" ]]; then
  if [[ "${CI:-}" == "" ]]; then
    echo "Please set OSX_SDK_DIR to a directory where SDKs can be downloaded to. Aborting"
    exit 1
  else
    export OSX_SDK_DIR=/opt/conda-sdks
    /usr/bin/sudo mkdir -p "${OSX_SDK_DIR}"
    /usr/bin/sudo chown "${USER}" "${OSX_SDK_DIR}"
  fi
else
  if tmpf=$(mktemp "$OSX_SDK_DIR"/tmp.XXXXXXXX 2>/dev/null); then
      rm -f "$tmpf"
      echo "OSX_SDK_DIR is writeable without sudo, continuing"
  else
      echo "User-provided OSX_SDK_DIR is not writeable for current user! Aborting"
      exit 1
  fi
fi

echo -e "\n\nRunning the build setup script."
source run_conda_forge_build_setup



( endgroup "Configuring conda" ) 2> /dev/null

if [[ -f LICENSE.txt ]]; then
  cp LICENSE.txt "recipe/recipe-scripts-license.txt"
fi

if [[ "${BUILD_WITH_CONDA_DEBUG:-0}" == 1 ]]; then
    export CONDA_BLD_PATH="${CONDA_BLD_PATH:-${FEEDSTOCK_ROOT:-$PWD}/build_artifacts}"
    rattler-build debug setup \
        --recipe ./recipe \
        -m ./.ci_support/${CONFIG}.yaml \
        --build-platform "${BUILD_PLATFORM}" \
        --target-platform "${HOST_PLATFORM}" \
        ${BUILD_OUTPUT_ID:+--output-name "${BUILD_OUTPUT_ID}"} \
        ${EXTRA_CB_OPTIONS:-}

    rattler-build debug shell
else

    if [[ "${HOST_PLATFORM}" != "${BUILD_PLATFORM}" ]]; then
        EXTRA_CB_OPTIONS="${EXTRA_CB_OPTIONS:-} --test skip"
    fi

    rattler-build build --recipe ./recipe \
        -m ./.ci_support/${CONFIG}.yaml \
        ${EXTRA_CB_OPTIONS:-} \
        --build-platform "${BUILD_PLATFORM}" \
        --target-platform "${HOST_PLATFORM}" \
        --extra-meta flow_run_id="$flow_run_id" \
        --extra-meta remote_url="$remote_url" \
        --extra-meta sha="$sha"

    ( startgroup "Inspecting artifacts" ) 2> /dev/null

    # inspect_artifacts was only added in conda-forge-ci-setup 4.9.4
    command -v inspect_artifacts >/dev/null 2>&1 && inspect_artifacts --recipe-dir ./recipe -m ./.ci_support/${CONFIG}.yaml || echo "inspect_artifacts needs conda-forge-ci-setup >=4.9.4"

    ( endgroup "Inspecting artifacts" ) 2> /dev/null
    ( startgroup "Validating outputs" ) 2> /dev/null

    validate_recipe_outputs "${FEEDSTOCK_NAME}"

    ( endgroup "Validating outputs" ) 2> /dev/null

    ( startgroup "Uploading packages" ) 2> /dev/null

    if [[ "${UPLOAD_PACKAGES}" != "False" ]] && [[ "${IS_PR_BUILD}" == "False" ]]; then
      upload_package --validate --feedstock-name="${FEEDSTOCK_NAME}" ./ ./recipe ./.ci_support/${CONFIG}.yaml
    fi

    ( endgroup "Uploading packages" ) 2> /dev/null
fi
