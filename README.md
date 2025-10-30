# CLI Sandbox Environment

This project provides a containerized and isolated development environment for any folder on your system, using Docker and a bash script as an orchestrator.

The `cuybox.sh` script handles building the necessary Docker image, as well as creating, managing, and connecting to persistent containers, ensuring that each working directory has its own unique and reusable sandbox.

## Features

- **Isolated Environments**: Each sandbox is linked to an absolute directory path, mounting its content into `/sandbox` inside the container.
- **Intelligent Persistence**: Containers are not deleted upon exit. The script automatically reconnects to a container if it's already running or starts it if it's stopped.
- **Unique & Predictable Naming**: Each container's name is generated from a tag (the folder's name or a custom one), a 4-character hash of the path, and an index to resolve collisions (`{tag}-{hash}-{index}`).
- **Path Tracking**: A config file (`$XDG_CONFIG_HOME/cuybox/state.json`, defaulting to `~/.config/cuybox/state.json`) keeps a record of paths and their sandboxes to prevent collisions and manage indices.
- **Pre-configured Environment**: The Docker image comes with `nvm` and the latest version of `Node.js v22` ready to use.
- **Graceful Lifecycle**: Containers run under `tini` with an idle process so they stop quickly and cleanly even after long sessions.
- **Flexibility**: Allows passing custom options directly to the `docker run` command (e.g., to delete a container on exit with `--rm`).

## Prerequisites

Before using the script, ensure you have the following tools installed on your system:

- **Docker**: The engine for creating and running containers.
- **jq**: For command-line JSON processing.
- **coreutils**: Provides `realpath`, `basename`, `cut`, etc.
- **crc32**: For generating short hashes (may be in `libarchive-tools` on some Linux distributions).

## Usage

The `cuybox.sh` script must be executable (`chmod +x cuybox.sh`).

1.  **Start a sandbox in the current directory**:
    ```bash
    ./cuybox.sh
    ```

2.  **Start a sandbox for a specific directory**:
    ```bash
    ./cuybox.sh /path/to/your/project
    ```

3.  **Use a custom tag for the container name**:
    ```bash
    ./cuybox.sh /path/to/your/project my-special-tag
    ```

4.  **Force host user setup**:
    The container configures a matching user when it is created. Re-run the setup on demand with the optional flag:
    ```bash
    ./cuybox.sh /path/to/your/project --setup-user
    ```

5.  **Pass additional parameters to Docker**:
    To create a container that gets deleted upon exit (non-persistent behavior), use the `--rm` flag.
    ```bash
    ./cuybox.sh /path/to/your/project --rm
    ```
    To pass environment variables:
    ```bash
    ./cuybox.sh . -e MY_VARIABLE=my_value
    ```

6.  **Exit the sandbox**:
    Simply type `exit` or press `Ctrl+D`.

## How It Works

- **Dockerfile**: Defines an Ubuntu-based environment with `nvm`, Node.js v22, and `tini` as PID 1. The container idles with `tail -f /dev/null`, so stop and start operations remain fast.
- **cuybox.sh**: This is the orchestrator that:
    1.  Parses arguments to separate script inputs from Docker options.
    2.  Calculates the absolute path of the directory and generates a 4-character `crc32` hash.
    3.  Queries the config file in `$XDG_CONFIG_HOME/cuybox/state.json` (or `~/.config/cuybox/state.json`) to determine the container's index, avoiding collisions.
    4.  Generates a unique and persistent name for the container.
    5.  Checks if the `develcuy/cuybox:latest` Docker image exists and, if not, builds it.
    6.  Creates the container on first run, runs the host-user setup once (or when `--setup-user` is passed), and then executes an interactive shell inside the running container.

## Customization

To add more tools or change the Node.js version, simply edit the `Dockerfile` and remove the local `develcuy/cuybox:latest` image (`docker rmi develcuy/cuybox:latest`). The next time you run `cuybox.sh`, the image will be rebuilt with your changes.