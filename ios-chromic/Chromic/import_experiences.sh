#!/bin/bash
# Build-time importer: unpacks every .zip bundle in Experiences/ into the built app under
# <App>.app/Bundled/<name>/, where ExperienceLibrary.swift finds them at runtime.
#
# Runs as a "Run Script" build phase (after Copy Bundle Resources). It can also be run by hand
# for inspection:  SRCROOT=$(pwd) BUILT_PRODUCTS_DIR=/tmp UNLOCALIZED_RESOURCES_FOLDER_PATH=out ./import_experiences.sh
set -euo pipefail

SRC_DIR="${SRCROOT}/Experiences"
DEST="${BUILT_PRODUCTS_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/Bundled"

echo "note: importing sound-walk bundles from ${SRC_DIR}"
rm -rf "${DEST}"
mkdir -p "${DEST}"

shopt -s nullglob
count=0
for zip in "${SRC_DIR}"/*.zip; do
  name="$(basename "${zip}" .zip)"
  out="${DEST}/${name}"
  mkdir -p "${out}"
  /usr/bin/unzip -o -q "${zip}" -d "${out}"
  # If the zip wrapped everything in a single top folder, flatten it so map.json sits at the root.
  if [ ! -f "${out}/map.json" ]; then
    inner="$(find "${out}" -name map.json -maxdepth 2 -print -quit || true)"
    if [ -n "${inner}" ]; then
      innerdir="$(dirname "${inner}")"
      if [ "${innerdir}" != "${out}" ]; then
        mv "${innerdir}"/* "${out}/" 2>/dev/null || true
      fi
    fi
  fi
  echo "note:   + ${name}"
  count=$((count+1))
done

if [ "${count}" -eq 0 ]; then
  echo "warning: no .zip bundles found in ${SRC_DIR} — the app will have no experiences."
fi
echo "note: imported ${count} bundle(s)"
