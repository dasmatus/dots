#!/usr/bin/env bash
# Rofi file manager — navigate directories, open files with xdg-open.
# Usage: rofi-files.sh [starting-directory]

DIR="${1:-$HOME}"
THEME="$HOME/.config/rofi/themes/tokyonight.rasi"

rofi_cmd() {
    rofi -dmenu -i \
         -theme "$THEME" \
         -p " $DIR" \
         -kb-remove-char-back "BackSpace" \
         -kb-custom-1 "ctrl+h" \
         "$@"
}

file_icon() {
    local name="$1"
    local ext="${name##*.}"
    case "${ext,,}" in
        png|jpg|jpeg|gif|bmp|svg|webp|ico|tiff|tga|ppm|pgm) echo "󰋩" ;;
        mp4|mkv|avi|mov|webm|flv|wmv|m4v|ogv)               echo "󰎁" ;;
        mp3|flac|wav|ogg|m4a|aac|opus|wma)                  echo "󰝚" ;;
        pdf)                                                  echo "󰈦" ;;
        zip|tar|gz|xz|bz2|7z|rar|zst|lz4)                  echo "󰗄" ;;
        sh|bash|zsh|fish)                                     echo "" ;;
        py)                                                   echo "" ;;
        js|ts|jsx|tsx)                                        echo "󰌞" ;;
        json|yaml|yml|toml|ini|conf|cfg)                     echo "" ;;
        md|markdown)                                          echo "󰍔" ;;
        txt)                                                  echo "󰈙" ;;
        html|htm)                                             echo "󰌝" ;;
        css|scss|sass)                                        echo "󰌜" ;;
        rs)                                                   echo "" ;;
        go)                                                   echo "" ;;
        c|h)                                                  echo "" ;;
        cpp|cc|cxx|hpp)                                       echo "" ;;
        java)                                                 echo "" ;;
        rb)                                                   echo "" ;;
        lua)                                                  echo "" ;;
        vim)                                                  echo "" ;;
        *)                                                    echo "" ;;
    esac
}

build_entries() {
    local show_hidden="$1"
    entries=()
    [[ "$DIR" != "/" ]] && entries+=("..")

    local find_args=()
    if [[ "$show_hidden" != "1" ]]; then
        find_args=(\( -name ".*" -prune \) -o -print0)
    else
        find_args=(-print0)
    fi

    while IFS= read -r -d $'\0' item; do
        local name="${item##*/}"
        if [[ -d "$item" ]]; then
            entries+=(" $name/")
        else
            entries+=("$(file_icon "$name") $name")
        fi
    done < <(find "$DIR" -maxdepth 1 -mindepth 1 "${find_args[@]}" 2>/dev/null | sort -z)
}

SHOW_HIDDEN=0

while true; do
    build_entries "$SHOW_HIDDEN"

    choice=$(printf '%s\n' "${entries[@]}" | rofi_cmd)
    exit_code=$?

    if [[ $exit_code -eq 10 ]]; then
        SHOW_HIDDEN=$(( 1 - SHOW_HIDDEN ))
        continue
    fi

    # Cancelled
    [[ $exit_code -ne 0 ]] && exit 0
    [[ -z "$choice" ]] && exit 0

    # Strip the leading icon + space
    name="${choice#* }"
    name="${name%/}"

    if [[ "$choice" == ".." ]]; then
        DIR="$(dirname "$DIR")"
    elif [[ "$choice" == *"/" || -d "$DIR/$name" ]]; then
        DIR="$DIR/$name"
    else
        xdg-open "$DIR/$name" &
        exit 0
    fi
done
