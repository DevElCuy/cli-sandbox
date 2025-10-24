#!/bin/bash

# --- Configuration ---
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/cli-sandbox"
CONFIG_FILE="$CONFIG_DIR/state.json"
IMAGE_NAME="develcuy/cli-sandbox:latest"
FORCE_USER_SETUP=0
RUN_AS_ROOT=0
CONTAINER_ID=""
TAG=""
CONTAINER_NAME=""
ACTUAL_CONTAINER_NAME=""
CUSTOM_TAG_SET=0

ensure_dependencies() {
    if ! command -v jq &> /dev/null; then echo "Error: jq is not installed." >&2; exit 1; fi
    if ! command -v realpath &> /dev/null; then echo "Error: realpath is not installed." >&2; exit 1; fi
    if ! command -v crc32 &> /dev/null; then echo "Error: crc32 is not installed." >&2; exit 1; fi
}

initialize_config_file() {
    mkdir -p "$CONFIG_DIR"
    [ -f "$CONFIG_FILE" ] || echo "{}" > "$CONFIG_FILE"
}

parse_arguments() {
    DOCKER_OPTS=()
    SCRIPT_ARGS=()
    EXPECT_DOCKER_VALUE=0
    FORCE_USER_SETUP=0
    AFTER_DASH_DASH=0

    for arg in "$@"; do
        if [ "$EXPECT_DOCKER_VALUE" -eq 1 ]; then
            DOCKER_OPTS+=("$arg")
            EXPECT_DOCKER_VALUE=0
            continue
        fi

        if [ "$arg" = "--setup-user" ]; then
            FORCE_USER_SETUP=1
            continue
        fi

        if [ "$arg" = "--root" ]; then
            RUN_AS_ROOT=1
            continue
        fi

        if [ "$AFTER_DASH_DASH" -eq 1 ]; then
            DOCKER_OPTS+=("$arg")
            continue
        fi

        case "$arg" in
            --)
                AFTER_DASH_DASH=1
                ;;
            -*)
                DOCKER_OPTS+=("$arg")
                case "$arg" in
                    -e|-v|-p|-w|-u|-h|--env|--volume|--publish|--workdir|--user|--hostname|--name|--network|--add-host|--device|--label|--mount|--entrypoint)
                        EXPECT_DOCKER_VALUE=1
                        ;;
                esac
                ;;
            *)
                SCRIPT_ARGS+=("$arg")
                ;;
        esac
    done
}

resolve_target_details() {
    TARGET_DIR=${SCRIPT_ARGS[0]:-.}
    ABSOLUTE_PATH=$(realpath "$TARGET_DIR")
    DEFAULT_TAG=$(basename "$ABSOLUTE_PATH" | tr '[:upper:]' '[:lower:]')
    CUSTOM_TAG=${SCRIPT_ARGS[1]:-}
    TAG=${CUSTOM_TAG:-$DEFAULT_TAG}
    if [ -n "$CUSTOM_TAG" ]; then
        CUSTOM_TAG_SET=1
    else
        CUSTOM_TAG_SET=0
    fi
    VALID_TAG_REGEX='^[A-Za-z0-9_.-]+$'

    if [[ ! $TAG =~ $VALID_TAG_REGEX ]]; then
        if [ -z "$CUSTOM_TAG" ]; then
            echo "Error: directory basename '$DEFAULT_TAG' is not a valid container tag. Provide a custom tag (second argument) matching [A-Za-z0-9_.-]." >&2
        else
            echo "Error: provided tag '$CUSTOM_TAG' must match [A-Za-z0-9_.-]." >&2
        fi
        exit 1
    fi

    HOST_UID=$(id -u)
    HOST_GID=$(id -g)

    RAW_HASH=$(crc32 <(printf '%s' "$ABSOLUTE_PATH") 2>/dev/null | tr -d '\n' | tr '[:upper:]' '[:lower:]')
    if [ -z "$RAW_HASH" ]; then
        echo "Error: failed to generate CRC32 hash for '$ABSOLUTE_PATH'." >&2
        exit 1
    fi
    HASH=${RAW_HASH:0:4}
}

load_or_create_index() {
    EXISTING_ENTRY=$(jq -r --arg path "$ABSOLUTE_PATH" '.[$path]' "$CONFIG_FILE")

    if [ "$EXISTING_ENTRY" != "null" ]; then
        INDEX=$(jq -r '.index // -1' <<< "$EXISTING_ENTRY")
        STORED_HASH=$(jq -r '.hash // ""' <<< "$EXISTING_ENTRY")
        CONTAINER_ID=$(jq -r '.container_id // ""' <<< "$EXISTING_ENTRY")
        STORED_TAG=$(jq -r '.tag // ""' <<< "$EXISTING_ENTRY")
        if [ -n "$STORED_TAG" ] && [ "$CUSTOM_TAG_SET" -eq 0 ]; then
            TAG="$STORED_TAG"
        fi
    else
        MAX_INDEX=$(jq -r --arg hash "$HASH" '[.[] | select(.hash == $hash) | .index] | max // -1' "$CONFIG_FILE")
        INDEX=$((MAX_INDEX + 1))
        STORED_HASH=""
        CONTAINER_ID=""
    fi

    if [ "$INDEX" -lt 0 ] || [ "$STORED_HASH" != "$HASH" ]; then
        MAX_INDEX=$(jq -r --arg hash "$HASH" '[.[] | select(.hash == $hash) | .index] | max // -1' "$CONFIG_FILE")
        INDEX=$((MAX_INDEX + 1))
        CONTAINER_ID=""
        if ! persist_container_metadata ""; then
            return 1
        fi
    fi

    CONTAINER_NAME="${TAG}-${HASH}-${INDEX}"
}

refresh_container_name() {
    if [ -z "$CONTAINER_ID" ]; then
        ACTUAL_CONTAINER_NAME=""
        return
    fi

    local inspected_name
    if inspected_name=$(docker inspect --format '{{ .Name }}' "$CONTAINER_ID" 2>/dev/null); then
        ACTUAL_CONTAINER_NAME="${inspected_name#/}"
    else
        ACTUAL_CONTAINER_NAME=""
    fi
}

persist_container_metadata() {
    local container_id_value="${1:-}"
    if ! jq --arg path "$ABSOLUTE_PATH" \
             --arg hash "$HASH" \
             --argjson index "$INDEX" \
             --arg tag "$TAG" \
             --arg container_id "$container_id_value" \
             '.[$path] = {hash: $hash, index: $index, tag: $tag} + (if $container_id == "" then {} else {container_id: $container_id} end)' \
             "$CONFIG_FILE" > "$CONFIG_FILE.tmp"; then
        echo "Error: failed to update sandbox state for '$ABSOLUTE_PATH'." >&2
        return 1
    fi
    if ! mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"; then
        echo "Error: failed to persist sandbox state for '$ABSOLUTE_PATH'." >&2
        return 1
    fi
}

stage_setup() {
    # 1. Ensure image exists
    if ! docker image inspect "$IMAGE_NAME" &> /dev/null; then
        echo "Image '$IMAGE_NAME' not found. Building it now..."
        local dockerfile_dir
        dockerfile_dir=$(dirname "$(realpath "$0")")
        if ! docker build -t "$IMAGE_NAME" "$dockerfile_dir"; then
            echo "Error: Docker image build failed." >&2
            return 1
        fi
    fi

    # 2. Ensure container exists and is running
    local container_created=0
    if [ -n "$CONTAINER_ID" ]; then
        if ! docker container inspect "$CONTAINER_ID" &> /dev/null; then
            CONTAINER_ID=""
        fi
    fi
    refresh_container_name

    local container_running=""
    if [ -n "$CONTAINER_ID" ]; then
        container_running=$(docker ps -q -f "id=$CONTAINER_ID")
    fi

    if [ -z "$CONTAINER_ID" ]; then
        echo "Creating container '$CONTAINER_NAME' for sandbox..."
        local create_opts=()
        local skip_next=0
        for opt in "${DOCKER_OPTS[@]}"; do
            if [ "$skip_next" -eq 1 ]; then
                skip_next=0
                continue
            fi
            case "$opt" in
                --rm|-d)
                    continue
                    ;;
                --name)
                    skip_next=1
                    continue
                    ;;
                --name=*)
                    continue
                    ;;
            esac
            create_opts+=("$opt")
        done

        local new_container_id
        if ! new_container_id=$(docker create \
            --interactive \
            --tty \
            "${create_opts[@]}" \
            --name "$CONTAINER_NAME" \
            --label cli-sandbox.tag="$TAG" \
            --label cli-sandbox.hash="$HASH" \
            --label cli-sandbox.index="$INDEX" \
            -v "$ABSOLUTE_PATH:/sandbox" \
            -w /sandbox \
            "$IMAGE_NAME"); then
            echo "Error: failed to create sandbox container." >&2
            return 1
        fi
        CONTAINER_ID=$(printf '%s' "$new_container_id" | tr -d ' \n\r')
        if [ -z "$CONTAINER_ID" ]; then
            echo "Error: received empty container ID from docker create." >&2
            return 1
        fi
        if ! persist_container_metadata "$CONTAINER_ID"; then
            return 1
        fi
        refresh_container_name
        container_created=1

        if ! docker start "$CONTAINER_ID" &> /dev/null; then
            echo "Error: failed to start container '$CONTAINER_ID'." >&2
            return 1
        fi
        refresh_container_name
    elif [ -z "$container_running" ]; then
        echo "Starting existing container '$CONTAINER_ID'..."
        if ! docker start "$CONTAINER_ID" &> /dev/null; then
            echo "Error: failed to start container '$CONTAINER_ID'." >&2
            return 1
        fi
        refresh_container_name
    fi

    if [ "$container_created" -eq 1 ] || [ "$FORCE_USER_SETUP" -eq 1 ]; then
        echo "Running container setup for host user..."
        if ! docker exec \
            --user root \
            --env TARGET_UID="$HOST_UID" \
            --env TARGET_GID="$HOST_GID" \
            "$CONTAINER_ID" \
            /usr/local/bin/setup-host-user.sh; then
            echo "Error: host user setup failed." >&2
            return 1
        fi
    fi
}

stage_run() {
    echo "Sandbox target: $ABSOLUTE_PATH"
    refresh_container_name
    if [ -n "$ACTUAL_CONTAINER_NAME" ]; then
        echo "Container name: $ACTUAL_CONTAINER_NAME"
    else
        echo "Container name: (unavailable)"
    fi
    echo "Container ID: $CONTAINER_ID"

    local exec_user
    if [ "$RUN_AS_ROOT" -eq 1 ]; then
        exec_user="root"
    else
        exec_user="${HOST_UID}:${HOST_GID}"
    fi

    local prompt_hostname="${ACTUAL_CONTAINER_NAME:-$CONTAINER_NAME}"
    local exec_args=(docker exec -it --user "$exec_user" --workdir /sandbox)
    if [ -n "$prompt_hostname" ]; then
        exec_args+=(--env CLI_SANDBOX_HOSTNAME="$prompt_hostname")
    fi
    exec_args+=("$CONTAINER_ID" bash)
    "${exec_args[@]}"
    return $?
}

main() {
    ensure_dependencies
    initialize_config_file
    parse_arguments "$@"
    resolve_target_details
    if ! load_or_create_index; then
        exit 1
    fi
    if ! stage_setup; then
        exit 1
    fi
    stage_run
    exit $?
}

main "$@"
