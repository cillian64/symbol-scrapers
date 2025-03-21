#!/bin/sh

# Alpine doesn't have a debuginfod server yet
# export DEBUGINFOD_URLS=""

. $(dirname $0)/../common.sh

URL="http://dl-cdn.alpinelinux.org/alpine"

VERSIONS="
edge
v3.17
v3.18
v3.19
v3.20
v3.21
"

REPOS="
main/x86_64
community/x86_64
"

get_package_urls() {
  # Alpine servers have the '+' character encoded in the URLs
  local package_name=$(echo "${1}" | sed -e 's/+/\%2B/g')
  local dbg_package_name="${package_name}-dbg"
  local url="${URL}"

  find . -name "index.html*" -exec grep -o "${url}.*/\(${package_name}-[0-9].*.apk\|${dbg_package_name}-[0-9].*.apk\)\"" {} \; | \
  cut -d'"' -f1
}

get_package_indexes() {
  local version="${1}"
  echo "${REPOS}" | while read line; do
    [ -z "${line}" ] && continue
    echo "${URL}/${version}/${line}/"
  done | sort -u > indexes.txt
}

fetch_packages() {
  local packages="${1}"
  local version="${2}"
  get_package_indexes "${version}"

  sort indexes.txt | ${WGET} -o wget_packages_urls.log -k -i -

  find . -name "index.html*" | while read path; do
    mv "${path}" "${path}.bak"
    xmllint --nowarning --format --html --output "${path}" "${path}.bak" 2>/dev/null
    rm -f "${path}.bak"
  done

  echo "${1}" | while read line; do
    [ -z "${line}" ] && continue
    get_package_urls ${line} >> unfiltered-packages.txt
  done

  touch packages.txt
  cat unfiltered-packages.txt | while read line; do
    package_name=$(echo "${line}" | rev | cut -d'/' -f1 | rev)
    if ! grep -q -F "${package_name}" SHA256SUMS; then
      echo "${line}" >> packages.txt
    fi
  done

  find . -name "index.html*" -exec rm -f {} \;

  sort packages.txt | ${WGET} -o wget_packages.log -P downloads -c -i -
}

function get_version() {
  package_name="${1}"
  filename="${2}"

  version="${filename##${package_name}-}"
  version="${version%%.apk}"
  printf "${version}"
}

function find_debuginfo_package() {
  package_name="${1}"
  version="${2}"
  find downloads -name "${package_name}-dbg-${version}.apk" -type f
}

function unpack_package() {
  local package_name="${1}"
  local debug_package_name="${2}"
  mkdir packages
  gzip -d -c -q "${package_name}" | tar -C packages -x --warning=no-unknown-keyword
  if [ $? -ne 0 ]; then
    printf "Failed to extract ${package_name}\n" 2>>error.log
  fi
  if [ -n "${debug_package_name}" ]; then
    gzip -d -c -q "${debug_package_name}" | tar -C packages -x --warning=no-unknown-keyword
    if [ $? -ne 0 ]; then
      printf "Failed to extract ${debug_package_name}\n" 2>>error.log
    fi
  fi
}

function process_packages() {
  local package_name="${1}"
  local debug_package_name="${2:-${package_name}}"
  find downloads -name "${package_name}-[0-9]*.apk" -type f | grep -v -e "-dbg-" | while read package; do
    local package_filename="${package##downloads/}"
    local version=$(get_version "${package_name}" "${package_filename}")
    local debuginfo_package=$(find_debuginfo_package "${debug_package_name}" "${version}")

    if [ -n "${debuginfo_package}" ]; then
      unpack_package ${package} ${debuginfo_package}
    else
      printf "***** Could not find debuginfo for ${package_filename}\n"
      unpack_package ${package}
    fi

    find packages -type f | grep -v debug | while read path; do
      if file "${path}" | grep -q ": *ELF" ; then
        local build_id=$(get_build_id "${path}")

        if [ -z "${build_id}" ]; then
          printf "Skipping ${path} because it does not have a GNU build id\n"
          continue
        fi

        local debuginfo_path="$(find_debuginfo "${path}" "${version}")"

        truncate -s 0 error.log
        local tmpfile=$(mktemp --tmpdir=tmp)
        printf "Writing symbol file for ${path} ${debuginfo_path} ... "
        if [ -n "${debuginfo_path}" ]; then
          ${DUMP_SYMS} --inlines "${path}" "${debuginfo_path}" 1> "${tmpfile}" 2> error.log
        else
          ${DUMP_SYMS} --inlines "${path}" 1> "${tmpfile}" 2> error.log
        fi

        if [ -s "${tmpfile}" -a -z "${debuginfo_path}" ]; then
          printf "done w/o debuginfo\n"
        elif [ -s "${tmpfile}" ]; then
          printf "done\n"
        else
          printf "something went terribly wrong!\n"
        fi

        if [ -s error.log ]; then
          printf "***** error log for package ${package} ${path} ${debuginfo_path}\n"
          cat error.log
          printf "***** error log for package ${package} ${path} ${debuginfo_path} ends here\n"
        fi

        # Copy the symbol file and debug information
        debugid=$(head -n 1 "${tmpfile}" | cut -d' ' -f4)
        filename="$(basename "${path}")"
        mkdir -p "symbols/${filename}/${debugid}"
        cp "${tmpfile}" "symbols/${filename}/${debugid}/${filename}.sym"
        local soname=$(get_soname "${path}")
        if [ -n "${soname}" ]; then
          if [ "${soname}" != "${filename}" ]; then
            mkdir -p "symbols/${soname}/${debugid}"
            cp "${tmpfile}" "symbols/${soname}/${debugid}/${soname}.sym"
          fi
        fi

        rm -f "${tmpfile}"
      fi
    done

    rm -rf packages
  done
}

function remove_temp_files() {
  rm -rf downloads symbols packages tmp symbols*.zip indexes.txt packages.txt \
         unfiltered-packages.txt crashes.list symbols.list
}

remove_temp_files
mkdir -p symbols

packages="
alsa-lib
aom-libs
brotli-libs
busybox-binsh
cairo
cairo-gobject cairo
cups-libs
dbus-libs
dconf
ffmpeg-libavcodec
ffmpeg-libavutil
ffmpeg-libswresample
firefox
firefox-esr
fontconfig
freetype
fribidi
gdk-pixbuf
glib
graphite2
gtk+3.0
harfbuzz
icu-libs
lame-libs
libatk-1.0
libatk-bridge-2.0
libbsd
libbz2
libcrypto3
libdav1d
libdrm
libepoxy
libevent
libexpat
libffi
libgcc
libintl
libjpeg-turbo
libjxl
libmount
libpciaccess
libpng
libpulse
libssl3
libstdc++
libtheora
libva
libva-vdpau-driver
libvorbis
libvpx
libwebp
libwebpdemux
libwebpmux
libx11
libxau
libxbcommon
libxcb
libxcomposite
libxcursor
libxdamage
libxdmcp
libxext
libxfixes
libxft
libxi
libxinerama
libxrandr
libxrender
libxshmfence
libxxf86vm
llvm17-libs
mesa
mesa-dri-gallium mesa
mesa-egl mesa
mesa-gbm mesa
mesa-glapi mesa
mesa-gles mesa
mesa-gl mesa
mesa-osmesa mesa
mesa-va-gallium mesa
mesa-vdpau-gallium mesa
mesa-vulkan-ati mesa
mesa-vulkan-intel mesa
mesa-vulkan-layers mesa
mesa-vulkan-swrast mesa
mesa-xatracker mesa
musl
nspr
nss
opus
pango
pciutils-libs
pcre2
pipewire
pipewire-libs
pixman
rav1e-libs
scudo-malloc
sqlite-libs
wayland
wayland-libs-client wayland
wayland-libs-cursor wayland
wayland-libs-egl wayland
x264-libs
x265-libs
zlib
"

echo "${VERSIONS}" | while read version; do
  [ -z "${version}" ] && continue
  mkdir -p downloads tmp
  fetch_packages "${packages}" "${version}"

  echo "${packages}" | while read line; do
    [ -z "${line}" ] && continue
    process_packages ${line}
  done

  cat unfiltered-packages.txt | rev | cut -d'/' -f1 | rev | sed -e "s/$/,$(date "+%s")/" >> SHA256SUMS.new
  rm -rf downloads tmp indexes.txt packages.txt unfiltered-packages.txt
done

mv -f SHA256SUMS.new SHA256SUMS

create_symbols_archive

upload_symbols

reprocess_crashes

remove_temp_files
