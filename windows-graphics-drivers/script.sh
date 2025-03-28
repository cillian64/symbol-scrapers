#!/bin/sh

. $(dirname $0)/../common.sh

URL="https://www.techpowerup.com"
AMD_PATH="download/amd-radeon-graphics-drivers/"
AMD_SYMBOL_SERVER="SRV*store*https://msdl.microsoft.com/download/symbols;SRV*store*https://download.amd.com/dir/bin"
INTEL_PATH="download/intel-graphics-drivers/"
INTEL_SYMBOL_SERVER="SRV*store*https://msdl.microsoft.com/download/symbols;SRV*store*https://software.intel.com/sites/downloads/symbols"
NVIDIA_PATH="download/nvidia-geforce-graphics-drivers/"
NVIDIA_SYMBOL_SERVER="SRV*store*https://msdl.microsoft.com/download/symbols;SRV*store*https://driver-symbols.nvidia.com"

# Maximum number of drivers we'll process in one go. Set this before calling
# fetch_and_process_drivers(). We don't want to put too much load on
# TechPowerUp's resources.
max_left_to_process=10

# The first arguent is the path used to fetch the drivers, the second is the
# symbol server to be used when dumping the symbols
function fetch_and_process_drivers() {
  local url="${URL}/${1}"
  local symbol_server="${2}"
  touch index.html

  count=$(wc -l < SHA256SUMS)

  # Sometimes we get an empty response so try multiple times
  while [ $(stat -c%s index.html) -eq 0 ]; do
    curl -s --output index.html "${url}"
  done

  local driver_name=""
  local driver_id=""
  grep -o "\(name=\"id\" value=\"[0-9]\+\"\|<div class=\"filename\".*\)" index.html | while read line; do
    # Odd lines contain the filename and even lines the ID
    if [ -z "${driver_name}" ]; then
      driver_name=$(echo "${line}" | cut -d'>' -f2 | cut -d'<' -f1)
    else
      driver_id=$(echo "${line}" | cut -d'"' -f4)

      if ! grep -q "${driver_name}" SHA256SUMS; then
        if [ "${max_left_to_process}" -le 0 ]; then
          break
        fi

        # We haven't seen this driver yet, process it
        download_driver "${url}" "${driver_id}"
        mkdir tmp
        expand_archives "downloads/${driver_name}"
        dump_dlls tmp "${symbol_server}"
        rm -rf tmp "downloads/${driver_name}"
        add_driver_to_list "${driver_name}"

        max_left_to_process=$((max_left_to_process - 1))
      fi

      # Move on to the next driver
      driver_name=""
      driver_id=""
    fi
  done

  # We're done
  rm -f index.html

  count=$(($(wc -l < SHA256SUMS) - count))
  max_left_to_process=$((max_left_to_process - count))
}

function download_driver() {
  local url="${1}"
  local driver_id="${2}"

  local server_id=$(curl -s "${url}" -d "id=${driver_id}" | grep -m 1 -o "name=\"server_id\" value=\"[0-9]\+\"" | cut -d'"' -f4)
  local location=$(curl -s -i "${url}" -d "id=${driver_id}&server_id=${server_id}" | grep "^location:" | tr -d "\r" | cut -d' ' -f2)
  printf "Downloading ${driver_name} from ${location}\n"
  curl -s --output-dir downloads --remote-name "${location}"
}

function expand_archives() {
  local path="${1}"
  local output_dir="$(mktemp --tmpdir=tmp -d)"
  local archive_size=$(du -b -s "${path}" | cut -f1)

  # Try unpacking the driver as a cabinet file. Note that we don't check the
  # extension because they sometimes come as .exe, and it's not possible to
  # tell them apart from regular executables when they do.
  if ! cabextract -q -d "${output_dir}" "${path}"; then
    # Not a cabinet file, try again with 7-zip
    7zz -y -bso0 -bd -o"${output_dir}" x "${path}"
  else
    # Check that the unpacked size is larger than the archive. If it isn't then
    # cabextract partially failed to unpack the archive but returned a success.
    local unpacked_size=$(du -b -s "${output_dir}" | cut -f1)

    if [ ${archive_size} -gt ${unpacked_size} ]; then
        # Partial failure, better try again with 7-zip
        rm -rf "${output_dir}"
        7zz -y -bso0 -bd -o"${output_dir}" x "${path}"
    fi
  fi

  # If we just expanded a cabinet archive, it might contain more archives, try
  # expanding them too.
  find "${output_dir}" -regex "${output_dir}/a[0-9]+" | while read archive; do
    expand_archives "${archive}"
  done

  # Recursively unpack other archives. We look for four different types of
  # archives at the moment: executables (which are often cabinet files),
  # cabinet files, ZIP archives and MSI files.
  find "${output_dir}" -iname "*.exe" -o -iname "*.cab" -o -iname "*.zip" -o -iname "*.msi" | while read archive; do
    expand_archives "${archive}"
  done

  # Finally unpack all packed DLLs.
  find "${output_dir}" -iname "*.dl_" -type f | while read dll; do
    7zz -y -bso0 -bd -o"$(dirname ${dll})" x "${dll}"
  done
}

function dump_dlls() {
  local path="${1}"
  local symbol_server="${2}"

  local count=$(find tmp -iname "*.dll" -type f | wc -l)
  printf "Found ${count} DLLs\n"

  find tmp -iname "*.dll" -type f | while read file; do
    if file "${file}" | grep -q -v "Mono/.Net"; then
      printf "Dumping ${file}\n"
      "${DUMP_SYMS}" --inlines --store symbols --symbol-server "${symbol_server}" --verbose error "${file}"
    fi
  done
}

function remove_temp_files() {
  rm -rf downloads store symbols tmp symbols*.zip
}

function add_driver_to_list() {
  local driver_name="${1}"
  local driver_date=$(date "+%s")
  printf "${driver_name},${driver_date}\n" >> SHA256SUMS
}

mkdir -p downloads symbols

fetch_and_process_drivers "${AMD_PATH}" "${AMD_SYMBOL_SERVER}"
fetch_and_process_drivers "${INTEL_PATH}" "${INTEL_SYMBOL_SERVER}"
fetch_and_process_drivers "${NVIDIA_PATH}" "${NVIDIA_SYMBOL_SERVER}"

create_symbols_archive

upload_symbols

reprocess_crashes

remove_temp_files
