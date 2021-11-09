#!/usr/bin/env bash

set -eu

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
DATA_DIR="${1:?data dir is required}"
OUTPUT_DIR="${2:?output dir is required}"
CONFIG_PATH="${3:?config path is required}"
DIFF="${4:?diff bool is required}"
REGISTRY="localhost:5000"
CATALOGNAMESPACE="test-catalogs"
REGISTRY_CATALOGNAMESPACE="${REGISTRY}/${CATALOGNAMESPACE}"
BUILDKITD="localhost:1234"

function set_indexdir() {
  if $DIFF; then
    export INDEX_PATH="diff"
  else 
    export INDEX_PATH="latest"
  fi
}

function setup() {
  echo -e "\nSetting up test directory in $DATA_DIR"
  cp -r "$DIR/../operator/testdata/bundles/"* "$DATA_DIR"
  mkdir -p "${DATA_DIR}/index"
  cp -r "${DIR}/../operator/testdata/indices/${INDEX_PATH}/"* "${DATA_DIR}/index/"
  find "$DATA_DIR" -type f -exec sed -i -E 's@REGISTRY_ONLY@'"$REGISTRY"'@g' {} \;
  mkdir -p "$OUTPUT_DIR"
  cp "${DIR}/../operator/testdata/configs/${CONFIG_PATH}" "${OUTPUT_DIR}/"
  find "$DATA_DIR" -type f -exec sed -i -E 's@REGISTRY_CATALOGNAMESPACE@'"$REGISTRY_CATALOGNAMESPACE"'@g' {} \;

}

function build_push_bundles() {
  echo -e "\nBuilding and pushing bundle images"
  for d in `find "${DATA_DIR}" -maxdepth 1 -name *-bundle-*`; do
    local img="${REGISTRY}/$(basename $d | cut -d- -f1)-operator/$(basename $d | cut -d- -f1-2):$(basename $d | cut -d- -f3)"
    pushd $d
    mkdir bundleDocker 
    mv bundle.Dockerfile bundleDocker/Dockerfile
    buildctl --addr tcp://$BUILDKITD build --frontend dockerfile.v0 --local context=. --local dockerfile=bundleDocker --output type=image,name=$img,push=true,registry.insecure=true
    #docker buildx build --push -t $img -f bundle.Dockerfile .
    popd
  done
}

function build_push_related_images() {
  echo -e "\nBuilding and pushing related images"
  for img in `yq eval '.relatedImages[].image' "${DATA_DIR}/index/index/index.yaml" --no-doc`; do
    local tmp=$(mktemp -d ${DATA_DIR}/bundle-image.XXXXX)
    pushd "$tmp"
    echo -e "#!/bin/sh\n\necho \"relatedImage: ${img}\"" > run.sh
    chmod +x run.sh
    cat <<EOF > Dockerfile
FROM gcr.io/distroless/static@sha256:912bd2c2b9704ead25ba91b631e3849d940f9d533f0c15cf4fc625099ad145b1
COPY run.sh /
ENTRYPOINT ["/run.sh"]
EOF
    # Use buildx to create manifest lists to test image association stuff.
    #docker buildx build --push --platform linux/amd64,linux/arm64 -t $img -f Dockerfile .
    buildctl --addr tcp://$BUILDKITD  build --frontend dockerfile.v0 --local context=. --local dockerfile=. --output type=image,name=$img,push=true,registry.insecure=true
    popd
    rm -rf "$tmp"
  done
}

# TODO(estroz): consider regenerating index.yaml with opm.
function build_push_catalog() {
  echo -e "\nBuilding and pushing catalog image"
  local img="${REGISTRY_CATALOGNAMESPACE}/test-catalog:latest"
  pushd "${DATA_DIR}/index"
  mkdir indexDocker
  mv index.Dockerfile indexDocker/Dockerfile
  buildctl --addr tcp://$BUILDKITD  build --frontend dockerfile.v0 --local context=. --local dockerfile=indexDocker --output type=image,name=$img,push=true,registry.insecure=true
  #docker buildx build --push -t $img -f index.Dockerfile .
  popd
}

set_indexdir
setup
build_push_related_images
build_push_bundles
build_push_catalog