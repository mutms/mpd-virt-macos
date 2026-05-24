#!/bin/sh
# Friendly post-install message for `make install`.
#
# Inputs (env):
#   BIN    — absolute path to the just-installed binary
#   BINDIR — directory that contains BIN (the one that needs to be on PATH)
#
# Output: prints success + (optionally) PATH-setup instructions for the
# user's login shell + a `rehash` / `hash -r` hint when the binary's
# directory IS on PATH but the shell's command-hash table may be stale.

set -eu

# ANSI helpers (no-op if stdout isn't a TTY).
if [ -t 1 ]; then
    GREEN=$(printf '\033[32m')
    YELLOW=$(printf '\033[33m')
    BOLD=$(printf '\033[1m')
    RESET=$(printf '\033[0m')
else
    GREEN=""
    YELLOW=""
    BOLD=""
    RESET=""
fi

printf '\n%s✓ Installed%s %s\n\n' "${GREEN}" "${RESET}" "${BIN}"

# Detect shell from $SHELL (the user's login shell). Falls back to
# zsh on macOS since that's the system default since Catalina.
shell_path="${SHELL:-/bin/zsh}"
shell_name=$(basename "${shell_path}")
case "${shell_name}" in
    zsh)  rc_file="$HOME/.zshrc";     rehash_cmd="rehash"      ;;
    bash) rc_file="$HOME/.bashrc";    rehash_cmd="hash -r"     ;;
    fish) rc_file="$HOME/.config/fish/config.fish"; rehash_cmd="" ;;
    *)    rc_file="$HOME/.profile";   rehash_cmd="hash -r"     ;;
esac

# Is BINDIR already on PATH?
on_path=0
case ":${PATH}:" in
    *":${BINDIR}:"*) on_path=1 ;;
esac

if [ "${on_path}" -eq 1 ]; then
    if [ -n "${rehash_cmd}" ]; then
        printf '%sTip%s: if `mpd-virt` doesn'\''t resolve in an existing shell, refresh the command-hash table:\n' "${BOLD}" "${RESET}"
        printf '    %s\n\n' "${rehash_cmd}"
    fi
    exit 0
fi

# BINDIR is not on PATH — print add-to-PATH instructions for the
# detected shell.
printf '%s⚠ %s is not on your PATH.%s Add it:\n\n' "${YELLOW}" "${BINDIR}" "${RESET}"
case "${shell_name}" in
    fish)
        printf '    fish_add_path %s\n\n' "${BINDIR}"
        printf 'Then open a new fish session (or `source %s`).\n\n' "${rc_file}"
        ;;
    *)
        printf '    echo '\''export PATH="%s:$PATH"'\'' >> %s\n' "${BINDIR}" "${rc_file}"
        printf '    source %s\n\n' "${rc_file}"
        if [ -n "${rehash_cmd}" ]; then
            printf 'After sourcing, run `%s` to refresh the shell'\''s command-hash table.\n\n' "${rehash_cmd}"
        fi
        ;;
esac
