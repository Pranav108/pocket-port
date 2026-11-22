#!/bin/bash
set -euo pipefail

configure_path() {
    local profile path_line
    case "${SHELL:-}" in
        */zsh) profile="${ZDOTDIR:-$HOME}/.zshrc" ;;
        */bash)
            profile="$HOME/.bash_profile"
            if [[ ! -e "$profile" ]]; then
                if [[ -e "$HOME/.bash_login" ]]; then
                    profile="$HOME/.bash_login"
                elif [[ -e "$HOME/.profile" ]]; then
                    profile="$HOME/.profile"
                fi
            fi
            ;;
        *) return 1 ;;
    esac
    if [[ "$1" == "$HOME/.local/bin" ]]; then
        path_line='export PATH="$HOME/.local/bin:$PATH"'
    else
        printf -v path_line 'export PATH=%q:$PATH' "$1"
    fi
    if ! grep -Fqx -- "$path_line" "$profile" 2>/dev/null; then
        printf '\n%s\n' "$path_line" >> "$profile" || return 1
    fi
    printf 'Open a new Terminal window to run pocket-port.\n'
}

main() (
    local add_to_path=false
    if [[ "${1:-}" == --add-to-path ]]; then
        add_to_path=true
        shift
    fi
    if [[ $# -ne 0 ]]; then
        echo 'Usage: bash install.sh [--add-to-path]' >&2
        return 2
    fi

    if [[ "$(uname -s)" != Darwin ]]; then
        echo 'PocketPort requires macOS 14 or later.' >&2
        return 1
    fi
    local version
    version=$(sw_vers -productVersion)
    if (( ${version%%.*} < 14 )); then
        echo 'PocketPort requires macOS 14 or later.' >&2
        return 1
    fi
    if ! xcrun --find swift >/dev/null 2>&1; then
        echo 'Install the Apple Command Line Tools with xcode-select --install, then rerun this command.' >&2
        return 1
    fi

    local bin_dir="${POCKETPORT_INSTALL_DIR:-$HOME/.local/bin}"
    staged=''
    local build_output
    work=$(mktemp -d "${TMPDIR:-/tmp}/pocket-port-install.XXXXXXXX")
    trap 'rm -rf "$work"; if [[ -n "$staged" ]]; then rm -f "$staged"; fi' EXIT

    git clone --depth 1 --branch main https://github.com/Pranav108/pocket-port.git "$work/source"
    TMPDIR="$work" swift build --package-path "$work/source" -c release --product pocket-port
    build_output=$(TMPDIR="$work" swift build --package-path "$work/source" -c release --show-bin-path)
    mkdir -p "$bin_dir"
    if [[ -d "$bin_dir/pocket-port" ]]; then
        printf '%s is a directory. Choose a different install directory.\n' "$bin_dir/pocket-port" >&2
        return 1
    fi
    staged=$(mktemp "$bin_dir/.pocket-port.XXXXXXXX")
    install -m 755 "$build_output/pocket-port" "$staged"
    mv -f "$staged" "$bin_dir/pocket-port"
    printf 'Installed %s\n' "$bin_dir/pocket-port"

    local shortcut
    for shortcut in pocketport pp; do
        if [[ -e "$bin_dir/$shortcut" || -L "$bin_dir/$shortcut" ]] || command -v "$shortcut" >/dev/null 2>&1; then
            continue
        fi
        if ln -s pocket-port "$bin_dir/$shortcut"; then
            printf 'Installed shortcut %s\n' "$bin_dir/$shortcut"
        else
            printf 'Use pocket-port. Could not install shortcut %s.\n' "$shortcut" >&2
        fi
    done

    case ":$PATH:" in
        *":$bin_dir:"*) printf 'Run pocket-port --help to verify the installation.\n' ;;
        *)
            if ! "$add_to_path" || ! configure_path "$bin_dir"; then
                printf 'Add %s to your PATH, or run %s/pocket-port --help.\n' "$bin_dir" "$bin_dir"
            fi
            ;;
    esac
)

main "$@"
