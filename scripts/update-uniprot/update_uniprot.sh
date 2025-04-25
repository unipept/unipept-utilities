#! /bin/bash

set -eo pipefail

################################################################################
# This script downloads the latest version of the UniProtKB database, converts #
# it into a suffix array, and organizes the files into the appropriate         #
# directory structure. This setup ensures a server's readiness for deployment  #
# of the Unipept API.                                                          #
################################################################################

################################################################################
#                            Variables and options                             #
################################################################################

# We need to know the location of where we can keep all repositories that are required to generate all input files
SCRATCH_DIR="$HOME"

# Output dir
OUTPUT_DIR="/mnt/data/"

DATABASE_SOURCES="swissprot,trembl"

LOCAL_SSH_KEY=""

REMOTE_ADDRESS=""

REMOTE_PORT="4840"

REMOTE_OUTPUT_DIR="/mnt/data"

################################################################################
#                            Helper Functions                                  #
################################################################################

################################################################################
# checkdep                                                                     #
#                                                                              #
# Checks if a specific dependency is installed on the current system. If the   #
# dependency is missing, an error message is displayed, indicating to the user #
# what needs to be installed. The script exits with status code 6 if the       #
# dependency is not met.                                                       #
#                                                                              #
# Globals:                                                                     #
#   None                                                                       #
#                                                                              #
# Arguments:                                                                   #
#   $1 - Name of the dependency to check (must be recognizable by the system)  #
#   $2 (optional) - Friendly name of the dependency to display in the error    #
#                   message if it's missing                                    #
#                                                                              #
# Outputs:                                                                     #
#   Error message to stderr if the dependency is not found                     #
#                                                                              #
# Returns:                                                                     #
#   Exits with status code 6 if the dependency is not installed                #
################################################################################
checkdep() {
    which "$1" > /dev/null 2>&1 || hash "$1" > /dev/null 2>&1 || {
        echo "Unipept database builder requires ${2:-$1} to be installed." >&2
        exit 6
    }
}

################################################################################
# log                                                                          #
#                                                                              #
# Logs a timestamped message to standard output. The format includes an epoch  #
# timestamp, date, and time for better traceability of script activity.        #
#                                                                              #
# Globals:                                                                     #
#   None                                                                       #
#                                                                              #
# Arguments:                                                                   #
#   $@ - The message to log                                                    #
#                                                                              #
# Outputs:                                                                     #
#   The timestamped log message to stdout                                      #
#                                                                              #
# Returns:                                                                     #
#   None                                                                       #
################################################################################
log() { echo "$(date +'[%s (%F %T)]')" "$@"; }

################################################################################
# get_latest_uniprot_version                                                   #
#                                                                              #
# Fetches the latest version of the UniProtKB database by querying the remote  #
# server and parsing the response for the release date.                        #
#                                                                              #
# Globals:                                                                     #
#   None                                                                       #
#                                                                              #
# Arguments:                                                                   #
#   None                                                                       #
#                                                                              #
# Outputs:                                                                     #
#   Sets the LATEST_VERSION variable with the latest release date in YYYY-MM   #
#   format.                                                                    #
#   Prints an error message to stdout and exits if fetching fails.             #
#                                                                              #
# Returns:                                                                     #
#   None                                                                       #
################################################################################
get_latest_uniprot_version() {
    LATEST_VERSION=$(curl -s https://ftp.expasy.org/databases/uniprot/current_release/knowledgebase/complete/reldate.txt | head -n 1 | grep -oP '\d{4}_\d{2}' | sed 's/_/-/')

    if [[ -z "$LATEST_VERSION" ]]; then
        echo "Error: Unable to fetch the latest UniProtKB version."
        exit 1
    fi

    echo "${LATEST_VERSION}"
}

################################################################################
#                           DATA GENERATION FUNCTIONS                          #
################################################################################

setup_directories() {
    local uniprot_version="$1"

    # Delete potential leftovers from previous invocations
    rm -rf "${OUTPUT_DIR:?}/uniprot-${uniprot_version}"

    # Create the required directory structure
    mkdir -p "${OUTPUT_DIR:?}/uniprot-${uniprot_version}"/{suffix-array,tables,temp}
}

################################################################################
# generate_tables                                                              #
#                                                                              #
# Downloads the unipept-database repository and generates all required TSV     #
# files to start building the UniPept suffix array.                            #
#                                                                              #
# Globals:                                                                     #
#   SCRATCH_DIR - Directory where temporary files and repositories are stored. #
#   OUTPUT_DIR - Directory where the tables and temporary files are stored.    #
#                                                                              #
# Arguments:                                                                   #
#   $1 - The UniProt version used to name the directory structure.             #
#                                                                              #
# Outputs:                                                                     #
#   Generates all required TSV files and stores them in the OUTPUT_DIR.        #
#   Logs an error and exits if required files are missing.                     #
#                                                                              #
# Returns:                                                                     #
#   None                                                                       #
################################################################################
generate_tables() {
    local uniprot_version="$1"

    # Cleanup potential old versions of the unipept-database repository
    rm -rf "${SCRATCH_DIR:?}/unipept-database"

    # Download new version of the database repo
    git clone --quiet "https://github.com/unipept/unipept-database.git" "${SCRATCH_DIR:?}/unipept-database"

    log "Successfully cloned unipept-database repo."

    log "Started building and generating Unipept table files."

    # Start the download and generation of all the suffix array tables
    "/${SCRATCH_DIR:?}/unipept-database/scripts/generate_sa_tables.sh" --database-sources "$DATABASE_SOURCES" --output-dir "${OUTPUT_DIR:?}/uniprot-${uniprot_version}/tables" --temp-dir "${OUTPUT_DIR:?}/uniprot-${uniprot_version}/temp"

    # Check if the required files are present and have been generated successfully
    local required_files=(
        "uniprot_entries.tsv.lz4"
        "taxons.tsv.lz4"
        "lineages.tsv.lz4"
        "interpro_entries.tsv.lz4"
        "go_terms.tsv.lz4"
        "ec_numbers.tsv.lz4"
        "reference_proteomes.tsv.lz4"
    )
    
    for file in "${required_files[@]}"; do
        if [[ ! -f "${OUTPUT_DIR:?}/uniprot-${uniprot_version}/tables/$file" ]]; then
            echo "Error: Missing table file: $file"
            exit 2
        fi
    done

    log "Finished building and generating Unipept table files."
}

################################################################################
# build_suffix_array                                                          #
#                                                                              #
# Constructs the binary suffix array file for the UniPept Index. This function #
# uses table files generated by the `generate_tables` function to extract the  #
# necessary columns and build the suffix array. It downloads the latest        #
# Unipept Index repository, compiles the required Rust binary, and executes    #
# the index builder.                                                           #
#                                                                              #
# Globals:                                                                     #
#   SCRATCH_DIR - Directory where temporary repositories and executables are   #
#                 stored.                                                      #
#   OUTPUT_DIR - Directory where the tables and output files are stored.       #
#                                                                              #
# Arguments:                                                                   #
#   $1 - The UniProt version used to locate the directory containing the       #
#        required tables and to name the suffix array outputs.                 #
#                                                                              #
# Outputs:                                                                     #
#   suffix array file in the OUTPUT_DIR.                                       #
#   Logs errors for missing prerequisites or failures during execution.        #
#                                                                              #
# Returns:                                                                     #
#   None                                                                       #
################################################################################
build_suffix_array() {
    local uniprot_version="$1"

    # Cleanup potential old versions of the unipept-index repository
    rm -rf "${SCRATCH_DIR:?}/unipept-index"

    # Download new version of the index repo
    git clone --quiet "https://github.com/unipept/unipept-index.git" "${SCRATCH_DIR:?}/unipept-index"

    log "Successfully cloned unipept-index repo."

    # Run the cargo build command with --release for the specified directory
    cargo build --release --manifest-path "${SCRATCH_DIR:?}/unipept-index/Cargo.toml"

    # Extract the required columns for the suffix array from the uniprot_entries.tsv.lz4 file
    lz4cat "${OUTPUT_DIR:?}/uniprot-${uniprot_version}/tables"/uniprot_entries.tsv.lz4 | cut -f2,4,7,8 > "${OUTPUT_DIR:?}/uniprot-${uniprot_version}/suffix-array"/proteins.tsv

    log "Started building suffix array"

    # Start the construction of the binary suffix array file
    "/${SCRATCH_DIR:?}/unipept-index/target/release/sa-builder" -a "lib-sais" -s 2 -c --database-file "${OUTPUT_DIR:?}/uniprot-${uniprot_version}/suffix-array"/proteins.tsv --output "${OUTPUT_DIR:?}/uniprot-${uniprot_version}/suffix-array/sa.bin"

    log "Finished building suffix array"
}

################################################################################
# extract_and_move_tables                                                      #
#                                                                              #
# Extracts required `.tsv` files for the Unipept database, decompresses them,  #
# and moves them to the appropriate directory structure for further use.       #
# Deletes the original compressed files after extraction.                      #
#                                                                              #
# Globals:                                                                     #
#   OUTPUT_DIR - Directory where the tables and output files are stored.       #
#                                                                              #
# Arguments:                                                                   #
#   $1 - The UniProt version used to locate the directory containing the       #
#        required tables and to name the output directory structure.           #
#                                                                              #
# Outputs:                                                                     #
#   Decompressed `.tsv` files in the `suffix-array/datastore` directory.       #
#   A `.version` file copied to the `suffix-array` directory.                  #
#                                                                              #
# Returns:                                                                     #
#   None                                                                       #
################################################################################
extract_and_move_tables() {
    local uniprot_version="$1"

    local required_files=(
        "taxons.tsv.lz4"
        "lineages.tsv.lz4"
        "interpro_entries.tsv.lz4"
        "go_terms.tsv.lz4"
        "ec_numbers.tsv.lz4"
        "reference_proteomes.tsv.lz4"
    )

    # Ensure the target directory exists
    mkdir -p "${OUTPUT_DIR:?}/uniprot-${uniprot_version}/suffix-array/datastore"

    # Extract all required files and store them in the target directory
    for file in "${required_files[@]}"; do
        local output_file="${OUTPUT_DIR:?}/uniprot-${uniprot_version}/suffix-array/datastore/${file%.lz4}"
        lz4cat "${OUTPUT_DIR:?}/uniprot-${uniprot_version}/tables/$file" > "$output_file"
        # Delete the original compressed file
        rm "${OUTPUT_DIR:?}/uniprot-${uniprot_version}/tables/$file"
    done

    # Copy the .version file that was generated by the database script
    cp "${OUTPUT_DIR:?}/uniprot-${uniprot_version}/tables/.version" "${OUTPUT_DIR:?}/uniprot-${uniprot_version}/suffix-array/.version"

    log "Successfully moved all tables."
}

################################################################################
# setup_opensearch                                                             #
#                                                                              #
# Initializes the OpenSearch instance for the specified UniProt version by     #
# importing protein data. Clones the unipept-database repository, retrieves    #
# the relevant protein entries, and calls the OpenSearch initialization script.#
#                                                                              #
# Globals:                                                                     #
#   SCRATCH_DIR - Directory where temporary files and repositories are stored. #
#   OUTPUT_DIR - Directory where the generated tables and temporary files are  #
#                stored.                                                       #
#                                                                              #
# Arguments:                                                                   #
#   $1 - The UniProt version used to locate the directory containing the data. #
#                                                                              #
# Outputs:                                                                     #
#   Imports protein data to the OpenSearch instance using the provided script. #
#   Logs status and errors during execution.                                   #
#                                                                              #
# Returns:                                                                     #
#   None                                                                       #
################################################################################
setup_opensearch() {
    local uniprot_version="$1"

    # Cleanup potential old versions of the unipept-database repository
    rm -rf "${SCRATCH_DIR:?}/unipept-database"

    # Download new version of the database repo
    git clone --quiet "https://github.com/unipept/unipept-database.git" "${SCRATCH_DIR:?}/unipept-database"

    log "Start importing proteins in OpenSearch instance."

    "/${SCRATCH_DIR:?}/unipept-database/scripts/initialize_opensearch.sh" --uniprot-entries "${OUTPUT_DIR}/uniprot-${uniprot_version}/tables/uniprot_entries.tsv.lz4"

    log "Finished importing proteins in OpenSearch instance."
}

# Copies all required files from a server that already generated a new suffix array for the current UniProtKB version.
copy_existing_database() {
    local uniprot_version="$1"

    local remote_dir="${REMOTE_OUTPUT_DIR}/uniprot-${uniprot_version}/"

    # Check if remote_dir exists on the remote server
    if ! ssh -i "${LOCAL_SSH_KEY}" -p "${REMOTE_PORT}" "${REMOTE_USER}@${REMOTE_ADDRESS}" "[ -d '${remote_dir}' ]"; then
        log "Error: Remote directory '${remote_dir}' does not exist."
        exit 2
    fi

    # Now start copying the generated files on the other server to this machine. First clean up any remains from a
    # previous invocation of this script
    rm -r "${OUTPUT_DIR}/uniprot-${uniprot_version}"

    scp -i "${LOCAL_SSH_KEY}" -P "${REMOTE_PORT}" -r "${REMOTE_USER}@${REMOTE_ADDRESS}:${remote_dir}" "${OUTPUT_DIR}"
}

################################################################################
#                                    Main                                      #
#                                                                              #
# This is the main section of the script where arguments and options are       #
# processed and the generation of output tables is initiated.                  #
################################################################################

################################################################################
# print_help                                                                  #
#                                                                              #
# Displays the usage instructions for the script, including all available      #
# options and their descriptions for each mode.                                #
#                                                                              #
# Globals:                                                                     #
#   SCRATCH_DIR (optional) - Directory for temporary files and executables.    #
#   OUTPUT_DIR (optional)  - Directory where the final output files are stored.#
#   DATABASE_SOURCES (optional) - Subsections of the UniProtKB database to     #
#                                  download (update mode only).                #
#   LOCAL_SSH_KEY (required) - Private key for remote communication (clone).   #
#   REMOTE_ADDRESS (required) - Remote server address (clone mode only).       #
#   REMOTE_USER (optional) - Remote server user, defaults to 'unipept'.        #
#   REMOTE_PORT (optional) - Remote server SCP port, defaults to 4840.         #
#   REMOTE_OUTPUT_DIR (optional) - Remote server database location, defaults   #
#                                  to '/mnt/data' (clone mode only).           #
#                                                                              #
# Arguments:                                                                   #
#   None                                                                       #
#                                                                              #
# Outputs:                                                                     #
#   Usage information along with descriptions for each mode.                   #
#                                                                              #
# Returns:                                                                     #
#   None                                                                       #
################################################################################
print_help() {
    echo "Usage: $0 <mode> [OPTIONS]"
    echo
    echo "Modes:"
    echo "  update                       Updates the UniProtKB database files and generates a new suffix array."
    echo "  clone                        Clones the UniProtKB database files from a remote server that already contains all files for the most recent UniProtKB version."
    echo
    echo "Options (common):"
    echo "  --scratch-dir <path>         Directory where temporary files and executables can be stored (default: ${SCRATCH_DIR})"
    echo "  --output-dir <path>          Directory where the final output files will be stored (default: ${OUTPUT_DIR})"
    echo "  --help                       Show this help message and exit"
    echo
    echo "Options for 'update' mode:"
    echo "  --database-sources <value>   Subsections of the UniProtKB database to download (default: ${DATABASE_SOURCES})"
    echo
    echo "Options for 'clone' mode:"
    echo "  --local-ssh-key <path>       Private key used to communicate with the remote server (required)."
    echo "  --remote-address <value>     Address of the remote server (required)."
    echo "  --remote-user <value>        User on the remote server (default: unipept)."
    echo "  --remote-port <value>        Port of the remote server available for SCP (default: 4840)."
    echo "  --remote-output-dir <value>  Directory on the remote server that stores the database (default: /mnt/data)."
}

################################################################################
# parse_update_arguments                                                       #
#                                                                              #
# Parses arguments for the 'update' mode and updates script variables.         #
#                                                                              #
# Globals:                                                                     #
#   SCRATCH_DIR, OUTPUT_DIR - Common variables updated by parse_common_arguments#
#   DATABASE_SOURCES - Updated based on the --database-sources option          #
#                      (default: "swissprot,trembl").                          #
#                                                                              #
# Arguments:                                                                   #
#   $@ - The command-line arguments passed for the 'update' mode.              #
#                                                                              #
# Outputs:                                                                     #
#   Prints error messages for invalid or missing argument values.              #
#                                                                              #
# Returns:                                                                     #
#   None                                                                       #
################################################################################
parse_update_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --scratch-dir)
                if [[ -n "$2" && "$2" != --* ]]; then
                    SCRATCH_DIR="$2"
                    shift 2
                else
                    echo "Error: --scratch-dir requires a value"
                    exit 1
                fi
                ;;
            --output-dir)
                if [[ -n "$2" && "$2" != --* ]]; then
                    OUTPUT_DIR="$2"
                    shift 2
                else
                    echo "Error: --output-dir requires a value"
                    exit 1
                fi
                ;;
            --database-sources)
                if [[ -n "$2" && "$2" != --* ]]; then
                    DATABASE_SOURCES="$2"
                    shift 2
                else
                    echo "Error: --database-sources requires a value"
                    exit 1
                fi
                ;;
            --help)
                print_help
                exit 0
                ;;
            *)
                echo "Unknown parameter for update mode: $1"
                echo
                print_help
                exit 1
                ;;
        esac
    done
}

################################################################################
# parse_clone_arguments                                                        #
#                                                                              #
# Parses arguments for the 'clone' mode and updates script variables.          #
#                                                                              #
# Globals:                                                                     #
#   SCRATCH_DIR, OUTPUT_DIR - Common variables updated by parse_common_arguments#
#   LOCAL_SSH_KEY, REMOTE_ADDRESS, REMOTE_USER, REMOTE_PORT, REMOTE_OUTPUT_DIR #
#   - Updated based on respective arguments for the 'clone' mode.              #
#                                                                              #
# Arguments:                                                                   #
#   $@ - The command-line arguments passed for the 'clone' mode.               #
#                                                                              #
# Outputs:                                                                     #
#   Prints error messages for invalid or missing argument values.              #
#                                                                              #
# Returns:                                                                     #
#   None                                                                       #
################################################################################
parse_clone_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --scratch-dir)
                if [[ -n "$2" && "$2" != --* ]]; then
                    SCRATCH_DIR="$2"
                    shift 2
                else
                    echo "Error: --scratch-dir requires a value"
                    exit 1
                fi
                ;;
            --output-dir)
                if [[ -n "$2" && "$2" != --* ]]; then
                    OUTPUT_DIR="$2"
                    shift 2
                else
                    echo "Error: --output-dir requires a value"
                    exit 1
                fi
                ;;
            --local-ssh-key)
                if [[ -n "$2" && "$2" != --* ]]; then
                    LOCAL_SSH_KEY="$2"
                    shift 2
                else
                    echo "Error: --local-ssh-key requires a value"
                    exit 1
                fi
                ;;
            --remote-address)
                if [[ -n "$2" && "$2" != --* ]]; then
                    REMOTE_ADDRESS="$2"
                    shift 2
                else
                    echo "Error: --remote-address requires a value"
                    exit 1
                fi
                ;;
            --remote-user)
                if [[ -n "$2" && "$2" != --* ]]; then
                    REMOTE_USER="$2"
                    shift 2
                else
                    echo "Error: --remote-user requires a value"
                    exit 1
                fi
                ;;
            --remote-port)
                if [[ -n "$2" && "$2" != --* ]]; then
                    REMOTE_PORT="$2"
                    shift 2
                else
                    echo "Error: --remote-port requires a value"
                    exit 1
                fi
                ;;
            --remote-output-dir)
                if [[ -n "$2" && "$2" != --* ]]; then
                    REMOTE_OUTPUT_DIR="$2"
                    shift 2
                else
                    echo "Error: --remote-output-dir requires a value"
                    exit 1
                fi
                ;;
            --help)
                print_help
                exit 0
                ;;
            *)
                echo "Unknown parameter for clone mode: $1"
                echo
                print_help
                exit 1
                ;;
        esac
    done

    # Validate required arguments for clone mode
    if [[ -z "$LOCAL_SSH_KEY" || -z "$REMOTE_ADDRESS" ]]; then
        echo "Error: --local-ssh-key and --remote-address are required for clone mode."
        exit 1
    fi
}

if [[ $# -lt 1 ]]; then
  echo "Error: Mode must be specified as the first argument ('kmer' or 'tryptic')."
  print_help
  exit 1
fi

MODE="$1"  # First argument specifies the mode
shift      # Remove mode from arguments

# Utilities that are required for both modes of this script
checkdep lz4
checkdep curl
checkdep cargo "Rust toolchain"
checkdep git



UNIPROTKB_VERSION=$(get_latest_uniprot_version)

log "UniProtKB version is: $UNIPROTKB_VERSION"

if [[ "$MODE" == *"update"* ]]; then
    parse_update_arguments "$@"

    checkdep uuidgen
    checkdep pv
    checkdep pigz

    setup_directories "$UNIPROTKB_VERSION"
    generate_tables "$UNIPROTKB_VERSION"
    build_suffix_array "$UNIPROTKB_VERSION"
    extract_and_move_tables "$UNIPROTKB_VERSION"
    setup_opensearch "$UNIPROTKB_VERSION"
elif [["$MODE" == *"clone"* ]]; then
    parse_clone_arguments "$@"

    checkdep scp
    checkdep ssh

    # First, copy all files from the remote server to the local server.
    copy_existing_database "$UNIPROTKB_VERSION"
    # Then, start filling the database
    setup_opensearch "$UNIPROTKB_VERSION"
else
    echo "Error: Invalid mode '$MODE'. Supported modes are 'update' and 'clone'."
    exit 1
fi

exit 0
