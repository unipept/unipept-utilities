#! /bin/bash

set -eo pipefail

# This script downloads the most recent version of the UniProtKB database, converts it to a suffix array and moves
# all files into the right directory structure such that it can directly be deployed as Unipept API

################################################################################
#                            Variables and options                             #
################################################################################

# We need to know the location of where we can keep all repositories that are required to generate all input files
SCRATCH_DIR="$HOME"

# Output dir
OUTPUT_DIR="/mnt/data/"

DATABASE_SOURCES="swissprot,trembl"

TASKS="build_index,setup_database"

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
    LATEST_VERSION=$(curl -s https://ftp.uniprot.org/pub/databases/uniprot/current_release/knowledgebase/complete/reldate.txt | head -n 1 | grep -oP '\d{4}_\d{2}' | sed 's/_/-/')

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
    required_files=(
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

    required_files=(
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
# setup_mariadb_database                                                       #
#                                                                              #
# Deletes any existing protein data stored in the MariaDB database for the     #
# specified UniProt version, recreates the database structure, imports all     #
# required data, and builds the necessary indices for efficient querying.      #
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
#   Modifies the MariaDB database with cleared data, new structure,            #
#   imported data, and computed indices.                                       #
#   Logs warnings and errors during execution.                                 #
#                                                                              #
# Returns:                                                                     #
#   None                                                                       #
################################################################################
setup_mariadb_database() {
    uniprot_version="$1"

    log "Start setting up MariaDB database."

    # Clear any data left from a previous version, and setup the database structure
    mariadb -uroot -punipept < "${SCRATCH_DIR}/unipept-database/schemas_suffix_array/structure_no_index.sql"

    log "Start importing uniprot_entries."

    # Import all uniprot entries into the database (currently without computing the indices)
    lz4cat "${OUTPUT_DIR}/uniprot-${uniprot_version}/tables/uniprot_entries.tsv.lz4" | mariadb  --local-infile=1 -uroot -punipept unipept -e "LOAD DATA LOCAL INFILE '/dev/stdin' INTO TABLE uniprot_entries;SHOW WARNINGS" 2>&1

    log "Start indexing of uniprot_entries."

    # Now start computing the indices on the uniprot_entries table
    mariadb -uroot -punipept < "${SCRATCH_DIR}/unipept-database/schemas_suffix_array/structure_index_only.sql"

    log "Finished setting up MariaDB database."
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
# options and their descriptions.                                              #
#                                                                              #
# Globals:                                                                     #
#   SCRATCH_DIR (optional) - Directory for temporary files and executables.    #
#   OUTPUT_DIR (optional)  - Directory where the final output files are stored.#
#   DATABASE_SOURCES (optional) - Subsections of the UniProtKB database to     #
#                                  download (default: "swissprot,trembl").     #
#   TASKS (optional) - List of tasks to perform, comma-separated               #
#                      (default: "build_index,setup_database").                #
#                                                                              #
# Arguments:                                                                   #
#   None                                                                       #
#                                                                              #
# Outputs:                                                                     #
#   Usage information along with the current default values for options.       #
#                                                                              #
# Returns:                                                                     #
#   None                                                                       #
################################################################################
print_help() {
    echo "Usage: $0 [OPTIONS]"
    echo
    echo "Options:"
    echo "  --scratch-dir <path>        Directory where temporary files and executables can be stored (default: ${SCRATCH_DIR})"
    echo "  --output-dir <path>         Directory where the final output files will be stored (default: ${OUTPUT_DIR})"
    echo "  --database-sources <value>  Subsections of the UniProtKB database to download (default: ${DATABASE_SOURCES})"
    echo "  --tasks <value>             Comma-separated list of tasks to perform (default: ${TASKS})"
    echo "                              Supported tasks:"
    echo "                                - build_index: Download and parse the most recent UniProtKB database."
    echo "                                  This task will also generate a new suffix array that can be used by the Unipept API."
    echo "                                - setup_database: Initialize a mariadb database with the new uniprot entries"
    echo "                                  available in the <OUTPUT_DIR>/uniprot-<UNIPROTKB_VERSION>/tables/uniprot_entries.tsv.lz4 file."
    echo "                                  If this file is not present, you can generate it using the build_index step."
    echo "  --help                      Show this help message and exit"
}

################################################################################
# parse_arguments                                                              #
#                                                                              #
# Parses command-line arguments and updates the corresponding script variables.#
# Validates arguments to ensure required values are provided for each option.  #
#                                                                              #
# Globals:                                                                     #
#   SCRATCH_DIR - Updated based on the --scratch-dir option (default: "~").    #
#   OUTPUT_DIR - Updated based on the --output-dir option                      #
#                (default: "/mnt/data/").                                      #
#   DATABASE_SOURCES - Updated based on the --database-sources option          #
#                      (default: "swissprot,trembl").                          #
#   TASKS - Updated based on the --tasks option                                #
#           (default: "build_index,setup_database").                           #
#                                                                              #
# Arguments:                                                                   #
#   $@ - The command-line arguments passed to the script.                      #
#                                                                              #
# Outputs:                                                                     #
#   Prints error messages for invalid or missing argument values.              #
#                                                                              #
# Returns:                                                                     #
#   None                                                                       #
################################################################################
parse_arguments() {
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
            --tasks)
                if [[ -n "$2" && "$2" != --* ]]; then
                    TASKS="$2"
                    shift 2
                else
                    echo "Error: --tasks requires a value"
                    exit 1
                fi
                ;;
            --help)
                print_help
                exit 0
                ;;
            *)
                echo "Unknown parameter: $1"
                echo
                print_help
                exit 1
                ;;
        esac
    done
}

checkdep lz4
checkdep curl
checkdep cargo "Rust toolchain"
checkdep git

UNIPROTKB_VERSION=$(get_latest_uniprot_version)

log "UniProtKB version is: $UNIPROTKB_VERSION"

parse_arguments "$@"

if [[ "$TASKS" == *"build_index"* ]]; then
    setup_directories "$UNIPROTKB_VERSION"
    generate_tables "$UNIPROTKB_VERSION"
    build_suffix_array "$UNIPROTKB_VERSION"
    extract_and_move_tables "$UNIPROTKB_VERSION"
fi


if [[ "$TASKS" == *"setup_database"* ]]; then
    setup_mariadb_database "$UNIPROTKB_VERSION"
fi

exit 0
