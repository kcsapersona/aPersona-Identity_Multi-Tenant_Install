#!/bin/bash
# update.sh -- Update this Install checkout to a release tag, keep the
# deployment config, and redeploy.
#
# Run from the root of a git clone of the Install repository (the layout the
# README's Quick Start produces).
#
# Usage:
#   ./update.sh                       # latest release, then install
#   ./update.sh --version v0.6.9      # a specific tag, then install
#   ./update.sh --no-install          # only switch files, do not deploy
#
# Everything after the options is passed to install-multi-tenants.sh.
#
# The whole body lives in main() and is called on the last line, so bash has
# parsed the entire file before `git checkout` replaces this very script with
# the new release's copy.

set -euo pipefail
SELF="${BASH_SOURCE[0]}"
main() {
    cd "$(dirname "$SELF")"

    REF="latest"
    RUN_INSTALL=true
    while [[ $# -gt 0 ]]; do
        case $1 in
            --version)    REF="$2"; shift 2 ;;
            --no-install) RUN_INSTALL=false; shift ;;
            -h|--help)    sed -n '2,13p' "$(basename "$SELF")"; exit 0 ;;
            --)           shift; break ;;
            *)            break ;;
        esac
    done

    # Files the installer reads or writes that a release checkout must not clobber.
    CONFIG_FILES=(tenants-config.json apersona_idp_deploy_outputs.json apersona_idp_mgt_deploy_outputs.json)

    git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
        || { echo "ERROR: not a git checkout. Clone the Install repository and run update.sh from its root." >&2; exit 1; }

    # When invoked via sudo, keep git metadata owned by the invoking user so later
    # non-root git commands still work; the installer itself runs as root.
    git_as_owner() {
        if [[ -n "${SUDO_USER:-}" && "$(id -u)" -eq 0 ]]; then sudo -u "$SUDO_USER" git "$@"; else git "$@"; fi
    }

    CURRENT="$(cat VERSION 2>/dev/null || echo unknown)"
    BACKUP=".amfa_update_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP"
    for f in "${CONFIG_FILES[@]}"; do [[ -f "$f" ]] && cp -p "$f" "$BACKUP/"; done
    echo "Config backed up to $BACKUP"

    # Channel tags (latest, pre-release) and re-published version tags move, so
    # always force-fetch the one ref we want.
    git_as_owner fetch --force --no-tags origin "refs/tags/$REF:refs/tags/$REF"
    git_as_owner checkout --force --detach "refs/tags/$REF"

    for f in "${CONFIG_FILES[@]}"; do [[ -f "$BACKUP/$f" ]] && cp -p "$BACKUP/$f" "$f"; done

    NEW="$(cat VERSION 2>/dev/null || echo unknown)"
    echo "Updated $CURRENT -> $NEW ($REF @ $(git rev-parse --short HEAD))"

    if [[ "$RUN_INSTALL" == true ]]; then
        exec ./install-multi-tenants.sh "$@"
    fi
    echo "Next: ./install-multi-tenants.sh"
}
main "$@"
