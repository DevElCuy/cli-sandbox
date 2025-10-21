#!/bin/bash

# --- Configuration ---
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/cli-sandbox"
CONFIG_FILE="$CONFIG_DIR/state.json"
IMAGE_NAME="develcuy/cli-sandbox:latest"
FORCE_USER_SETUP=0
RUN_AS_ROOT=0

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
        INDEX=$(jq -r '.index' <<< "$EXISTING_ENTRY")
    else
        MAX_INDEX=$(jq -r --arg hash "$HASH" '[.[] | select(.hash == $hash) | .index] | max // -1' "$CONFIG_FILE")
        INDEX=$((MAX_INDEX + 1))
        jq --arg path "$ABSOLUTE_PATH" --arg hash "$HASH" --argjson index "$INDEX" \
           '.[$path] = {hash: $hash, index: $index}' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    fi

    CONTAINER_NAME="${TAG}-${HASH}-${INDEX}"
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
    local container_running
    container_running=$(docker ps -q -f "name=^/${CONTAINER_NAME}$")
    local container_created=0

    if [ -z "$container_running" ]; then
        local container_exists
        container_exists=$(docker ps -aq -f "name=^/${CONTAINER_NAME}$")

        if [ -z "$container_exists" ]; then
            # Container doesn't exist - create and start it
            echo "Creating container '$CONTAINER_NAME' for sandbox..."
            local create_opts=()
            for opt in "${DOCKER_OPTS[@]}"; do
                case "$opt" in
                    --rm|-d)
                        continue
                        ;;
                esac
                create_opts+=("$opt")
            done

            if ! docker create \
                --interactive \
                --tty \
                "${create_opts[@]}" \
                --name "$CONTAINER_NAME" \
                -v "$ABSOLUTE_PATH:/sandbox" \
                -w /sandbox \
                "$IMAGE_NAME"; then
                echo "Error: failed to create container '$CONTAINER_NAME'." >&2
                return 1
            fi
            container_created=1

            if ! docker start "$CONTAINER_NAME" &> /dev/null; then
                echo "Error: failed to start container '$CONTAINER_NAME'." >&2
                return 1
            fi
        else
            # Container exists but not running - start it
            echo "Starting existing container '$CONTAINER_NAME'..."
            if ! docker start "$CONTAINER_NAME" &> /dev/null; then
                echo "Error: failed to start container '$CONTAINER_NAME'." >&2
                return 1
            fi
        fi
    fi

    if [ "$container_created" -eq 1 ] || [ "$FORCE_USER_SETUP" -eq 1 ]; then
        echo "Running container setup for host user..."
        if ! docker exec \
            --user root \
            --env TARGET_UID="$HOST_UID" \
            --env TARGET_GID="$HOST_GID" \
            "$CONTAINER_NAME" \
            /usr/local/bin/setup-host-user.sh; then
            echo "Error: host user setup failed." >&2
            return 1
        fi
    fi
}

stage_run() {
    echo "Sandbox target: $ABSOLUTE_PATH"
    echo "Container name: $CONTAINER_NAME"

    local exec_user
    if [ "$RUN_AS_ROOT" -eq 1 ]; then
        exec_user="root"
    else
        exec_user="${HOST_UID}:${HOST_GID}"
    fi

    docker exec -it \
        --user "$exec_user" \
        --workdir /sandbox \
        "$CONTAINER_NAME" \
        bash
    return $?
}

main() {
    ensure_dependencies
    initialize_config_file
    parse_arguments "$@"
    resolve_target_details
    load_or_create_index
    if ! stage_setup; then
        exit 1
    fi
    stage_run
    exit $?
}

main "$@"
