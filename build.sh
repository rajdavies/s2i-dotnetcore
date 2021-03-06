#!/bin/bash
#
# Build Docker images and run tests.
#
# PRE: Docker daemon running, s2i binary available.
#
# Supported environment variables:
#
# -----------------------------------------------------
# TEST_OPENSHIFT  If 'true' run tests to make sure
#                 released images work against the
#                 test application used in OpenShift
#
# VERSIONS     The list of versions to build/test.
#              Defaults to all versions. i.e "1.0 1.1".
# -----------------------------------------------------
#
# Usage:
#       $ sudo ./build.sh
#       $ sudo VERSIONS=1.0 ./build.sh
#

if [ "${DEBUG}" == "true" ]; then
  set -x
fi

base_image_name() {
  local version=$1
  local v_no_dot=$(echo ${version} | sed 's/\.//g')
  if [[ "$version" == 1* ]]; then
    echo "dotnetcore-${v_no_dot}";
  else
    echo "dotnet-${v_no_dot}";
  fi
}

image_exists() {
  docker inspect $1 &>/dev/null
}

check_result_msg() {
  local retval=$1
  local msg=$2
  if [ ${retval} -ne 0 ]; then
    echo 1>&2 "${msg}"
    exit 1
  fi
}

build_image() {
  local path=$1
  local name=$2
  if ! image_exists ${name}; then
    echo "Building Docker image ${name} ..."
    if [ ! -d "${path}" ]; then
      echo "No directory found at given location '${path}'. Skipping this image."
      return
    fi
    pushd ${path} &>/dev/null
      docker build -f Dockerfile.rhel7 -t ${name} .
      check_result_msg $? "Building Docker image ${name} FAILED!"
    popd &>/dev/null
  fi
}

test_images() {
  local path=$1
  echo "Running tests..."
  ${path}/run
  check_result_msg $? "Tests FAILED!"
}

VERSIONS="${VERSIONS:-1.0 1.1 2.0}"

for v in ${VERSIONS}; do
  if [ "$v" == "1.0" ] || [ "$v" == "1.1" ]; then
    build_name="dotnet/$(base_image_name ${v})-rhel7"

    # Build the build image
    build_image "${v}" "${build_name}"
    test_images "${v}/test"

    if [ "$TEST_OPENSHIFT" = "true" ]; then
      build_name="registry.access.redhat.com/${build_name}:latest"
      pushd ${v} &>/dev/null
        echo "Running OpenShift tests on image ${build_name} ..."
        IMAGE_NAME="${build_name}" OPENSHIFT_ONLY=true ./test/run
        check_result_msg $? "Tests for image ${build_name} FAILED!"
      popd &>/dev/null
    fi
  else
    build_name="dotnet/$(base_image_name ${v})-rhel7"
    runtime_name="dotnet/$(base_image_name ${v})-runtime-rhel7"

    # Build the runtime image
    build_image "${v}/runtime" "${runtime_name}"
    test_images "${v}/runtime/test"

    # Build the build image
    build_image "${v}/build" "${build_name}"
    test_images "${v}/build/test"

    if [ "$TEST_OPENSHIFT" = "true" ]; then
      build_name="registry.access.redhat.com/${build_name}:latest"
      runtime_name="registry.access.redhat.com/${runtime_name}:latest"
      pushd ${v} &>/dev/null
        echo "Running OpenShift tests on image ${runtime_name} ..."
        IMAGE_NAME="${runtime_name}" OPENSHIFT_ONLY=true ./runtime/test/run
        check_result_msg $? "Tests for image ${runtime_name} FAILED!"

        echo "Running OpenShift tests on image ${build_name} ..."
        IMAGE_NAME="${build_name}" RUNTIME_IMAGE_NAME="${runtime_name}" OPENSHIFT_ONLY=true ./build/test/run
        check_result_msg $? "Tests for image ${build_name} FAILED!"
      popd &>/dev/null
    fi
  fi
done

echo "ALL builds and tests were successful!"
exit 0
