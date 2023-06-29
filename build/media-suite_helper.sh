#!/bin/bash
# shellcheck disable=SC2154,SC2120,SC2119,SC2034,SC1090,SC1117,SC2030,SC2031

if [[ -z ${MSYS+x} ]]; then
    export MSYS=winsymlinks:nativestrict
    touch linktest
    ln -s linktest symlinktest > /dev/null 2>&1
    ln linktest hardlinktest > /dev/null 2>&1
    test -h symlinktest || unset MSYS
    [[ $(stat --printf '%h\n' hardlinktest) -eq 2 ]] || unset MSYS
    rm -f symlinktest hardlinktest linktest
fi

case $cpuCount in
'' | *[!0-9]*) cpuCount=$(($(nproc) / 2)) ;;
esac
: "${bits:=64bit}"
curl_opts=(/usr/bin/curl --connect-timeout 15 --retry 3
    --retry-delay 5 --silent --location --insecure --fail)

if test -n "$(tput colors)" && test "$(tput colors)" -ge 8; then
    bold=$(tput bold)
    blue=$(tput setaf 12)
    orange=$(tput setaf 11)
    purple=$(tput setaf 13)
    green=$(tput setaf 2)
    red=$(tput setaf 1)
    reset=$(tput sgr0)
fi
ncols=72

[[ -f "$LOCALBUILDDIR"/grep.exe ]] &&
    rm -f "$LOCALBUILDDIR"/{7za,wget,grep}.exe

do_simple_print() {
    local plain=false formatString dateValue newline='\n' OPTION OPTIND
    while getopts ':np' OPTION; do
        case "$OPTION" in
        n) newline='' ;;
        p) plain=true ;;
        *) break ;;
        esac
    done
    shift "$((OPTIND - 1))"

    if [[ $timeStamp == y ]]; then
        formatString="${purple}"'%(%H:%M:%S)T'"${reset}"' '
        dateValue='-1'
    elif $plain; then
        formatString='\t'
    fi
    if ! $plain; then
        formatString+="${bold}├${reset} "
    fi
    printf "$formatString"'%b'"${reset}${newline}" $dateValue "$*"
}

do_print_status() {
    local _prefix _prefixpad=0
    if [[ $1 == prefix ]]; then
        _prefix="$2" && shift 2
        _prefixpad=2
    fi
    local name="$1 " color="$2" status="$3" pad
    eval printf -v pad ".%.s" "{1..$ncols}"
    if [[ $timeStamp == y ]]; then
        printf "${purple}"'%(%H:%M:%S)T'"${reset}"' %s%s %s [%s]\n' -1 "$_prefix" "${bold}$name${reset}" \
            "${pad:0:$((ncols - _prefixpad - ${#name} - ${#status} - 12))}" "${color}${status}${reset}"
    else
        printf '%s%s %s [%s]\n' "$_prefix" "${bold}$name${reset}" \
            "${pad:0:$((ncols - _prefixpad - ${#name} - ${#status} - 2))}" "${color}${status}${reset}"
    fi
}

do_print_progress() {
    case $logging$timeStamp in
    yy) printf "${purple}"'%(%H:%M:%S)T'"${reset}"' %s\n' -1 "$([[ $1 =~ ^[a-zA-Z] ]] && echo "${bold}├${reset} ")$*..." ;;
    yn)
        [[ $1 =~ ^[a-zA-Z] ]] &&
            printf '%s' "${bold}├${reset} "
        echo -e "$*..."
        ;;
    *)
        set_title "$* in $(get_first_subdir)"
        if [[ $timeStamp == y ]]; then
            printf "${purple}"'%(%H:%M:%S)T'"${reset}"' %s\n' -1 "${bold}$* in $(get_first_subdir)${reset}"
        else
            echo -e "${bold}$* in $(get_first_subdir)${reset}"
        fi
        ;;
    esac
}

set_title() {
    printf '\033]0;media-autobuild_suite  %s\a' "($bits)${1:+: $1}"
}

do_exit_prompt() {
    if [[ -n $build32$build64 ]]; then # meaning "executing this in the suite's context"
        create_diagnostic
        zip_logs
    fi
    do_prompt "$*"
    [[ -n $build32$build64 ]] && exit 1
}

cd_safe() {
    cd "$1" || do_exit_prompt "Failed changing to directory $1."
}

test_newer() {
    [[ $1 == installed ]] && local installed=y && shift
    local file
    local files=("$@")
    local cmp="${files[-1]}"
    [[ $installed ]] && cmp="$(file_installed "$cmp")"
    [[ ${#files[@]} -gt 1 ]] && unset 'files[-1]'
    [[ -f $cmp ]] || return 0
    for file in "${files[@]}"; do
        [[ $installed ]] && file="$(file_installed "$file")"
        [[ -f $file ]] &&
            [[ $file -nt $cmp ]] && return
    done
    return 1
}

# vcs_get_current_type /build/myrepo
vcs_get_current_type() {
    git -C "${1:-$PWD}" rev-parse --is-inside-work-tree > /dev/null 2>&1 &&
        echo "git" &&
        return 0
    echo "unknown"
    return 1
}

# check_valid_vcs /build/ffmpeg-git
check_valid_vcs() {
    [[ -d ${1:-$PWD}/.git ]] &&
        git -C "${1:-$PWD}/.git" rev-parse HEAD > /dev/null 2>&1
}

# vcs_get_current_head /build/ffmpeg-git
vcs_get_current_head() {
    git -C "${1:-$PWD}" rev-parse HEAD
}

# vcs_test_remote "https://github.com/m-ab-s/media-autobuild_suite.git"
vcs_test_remote() {
    GIT_TERMINAL_PROMPT=0 git ls-remote -q --refs "$1" > /dev/null 2>&1
}

vcs_clean() {
    GIT_TERMINAL_PROMPT=0 \
        git -C "${1:-$PWD}" clean -dffxq \
        -e{recently_{updated,checked},build_successful*,*.{patch,diff},custom_updated,**/ab-suite.*.log} "$@"
}

# vcs_get_latest_tag "libopenmpt-*"
vcs_get_latest_tag() {
    if ! case $1 in
        LATEST) git describe --abbrev=0 --tags "$(git rev-list --tags --max-count=1)" 2> /dev/null ;;
        GREATEST) git describe --abbrev=0 --tags 2> /dev/null ;;
        *\**) git describe --abbrev=0 --tags "$(git tag -l "$1" --sort=-version:refname | head -1)" 2> /dev/null ;;
        *) false ;;
        esac then
        echo "$1"
    fi
}

# vcs_set_url https://github.com/FFmpeg/FFmpeg.git
vcs_set_url() {
    if vcs_test_remote "$1"; then
        git remote set-url origin "$1"
    fi
    git config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
}

# vcs_clone https://gitlab.com/libtiff/libtiff.git tiff v4.1.0
vcs_clone() (
    set -x
    vcsURL=$1 vcsFolder=${2:-$(basename "$vcsURL" .git)}
    [[ -z $vcsURL ]] && return 1

    check_valid_vcs "$vcsFolder-git" && return 0
    rm -rf "$vcsFolder-git"
    case $- in
    *i*) unset GIT_TERMINAL_PROMPT ;;
    *) export GIT_TERMINAL_PROMPT=0 ;;
    esac
    git clone "$vcsURL" "$vcsFolder-git"
    git -C "$vcsFolder-git" reset --hard "${3:-origin/HEAD}"
    check_valid_vcs "$vcsFolder-git"
)

vcs_get_merge_base() {
    git merge-base HEAD "$(vcs_get_latest_tag "$1")"
}

vcs_reset() (
    set -x
    git checkout --no-track -fB ab-suite "$(vcs_get_latest_tag "$1")"
    git log --oneline --no-merges --no-color -n 1 | tee /dev/null
)

vcs_fetch() (
    set -x
    [[ -f $(git rev-parse --git-dir)/shallow ]] && unshallow="--unshallow" || unshallow=''
    git fetch --all -Ppft $unshallow
    git remote set-head -a origin
)

# do_mabs_clone "$vcsURL" "$vcsFolder" "$ref"
# For internal use for fallback links
do_mabs_clone() {
    vcs_test_remote "$1" &&
        log -q git.clone vcs_clone "$1" "$2" "$3"
    check_valid_vcs "$2-git"
}

vcs_ref_to_hash() (
    vcsURL=$1 ref=$2 vcsFolder=${3:-$(basename "$vcsURL" .git)}
    if _ref=$(git ls-remote --refs --exit-code -q -- "$vcsURL" "$ref"); then
        cut -f1 <<< "$_ref"
        return 0
    fi
    if git -C "$vcsFolder-git" rev-parse --verify -q --end-of-options "$ref" 2> /dev/null ||
        git -C "$vcsFolder" rev-parse --verify -q --end-of-options "$ref" 2> /dev/null ||
        git rev-parse --verify -q --end-of-options "$ref" 2> /dev/null; then
        return 0
    fi
    return 1
)

# get source from VCS
# example:
#   do_vcs "url#branch|revision|tag|commit=NAME[ folder]" "folder"
do_vcs() {
    local vcsURL=${1#*::} vcsFolder=$2 vcsCheck=("${_check[@]}")
    local vcsBranch=${vcsURL#*#} ref=origin/HEAD
    local deps=("${_deps[@]}") && unset _deps
    [[ $vcsBranch == "$vcsURL" ]] && unset vcsBranch
    local vcsPotentialFolder=${vcsURL#* }
    if [[ -z $vcsFolder ]] && [[ $vcsPotentialFolder != "$vcsURL" ]]; then
        vcsFolder=$vcsPotentialFolder # if there was a space, use the folder name
    fi
    vcsURL=${vcsURL%#*}
    : "${vcsFolder:=$(basename "$vcsURL" .git)}"  # else just grab from the url like git normally does

    if [[ -n $vcsBranch ]]; then
        ref=${vcsBranch##*=}
        unset vcsBranch
    fi

    cd_safe "$LOCALBUILDDIR"

    rm -f "$vcsFolder-git/custom_updated"

    check_custom_patches "$vcsFolder-git"

    extra_script pre vcs

    # try to see if we can "resolve" the currently provided ref to a commit,
    # excluding special tags that we will resolve later. Ignore it if it's
    # a specific head. glslang's HEAD != their main branch somehow.
    case $ref in
    LATEST | GREATEST | *\**) ;;
    origin/HEAD | origin/* | HEAD) ;;
    *) ref=$(vcs_ref_to_hash "$vcsURL" "$ref" "$vcsFolder") ;;
    esac

    if ! check_valid_vcs "$vcsFolder-git"; then
        rm -rf "$vcsFolder-git"
        do_print_progress "  Running git clone for $vcsFolder"
        if ! do_mabs_clone "$vcsURL" "$vcsFolder" "$ref"; then
            echo "$vcsFolder git seems to be down"
            echo "Try again later or <Enter> to continue"
            do_prompt "if you're sure nothing depends on it."
            unset_extra_script
            return
        fi
        touch "$vcsFolder-git"/recently_{updated,checked}
    fi

    cd_safe "$vcsFolder-git"

    if [[ $ffmpegUpdate == onlyFFmpeg && $vcsFolder != ffmpeg && $vcsFolder != mpv ]] &&
        files_exist "${vcsCheck[@]:-$vcsFolder.pc}"; then
        do_print_status "${vcsFolder} git" "$green" "Already built"
        unset_extra_script
        return 1
    fi

    vcs_set_url "$vcsURL"
    log -q git.fetch vcs_fetch
    oldHead=$(vcs_get_merge_base "$ref")
    do_print_progress "  Running git update for $vcsFolder"
    log -q git.reset vcs_reset "$ref"
    newHead=$(vcs_get_current_head "$PWD")

    vcs_clean

    if [[ $oldHead != "$newHead" || -f custom_updated ]]; then
        touch recently_updated
        rm -f ./build_successful{32,64}bit{,_*}
        if [[ $build32$build64$bits == yesyes64bit ]]; then
            new_updates=yes
            new_updates_packages="$new_updates_packages [$vcsFolder]"
        fi
        {
            echo "$vcsFolder"
            git log --no-merges --pretty="%ci: %an - %h%n    %s" "$oldHead..$newHead"
            echo
        } >> "$LOCALBUILDDIR/newchangelog"
        do_print_status "┌ $vcsFolder git" "$orange" "Updates found"
    elif [[ -f recently_updated && ! -f build_successful$bits${flavor:+_$flavor} ]]; then
        do_print_status "┌ $vcsFolder git" "$orange" "Recently updated"
    elif [[ -n ${vcsCheck[*]} ]] && ! files_exist "${vcsCheck[@]}"; then
        do_print_status "┌ $vcsFolder git" "$orange" "Files missing"
    elif [[ -n ${deps[*]} ]] && test_newer installed "${deps[@]}" "${vcsCheck[0]}"; then
        do_print_status "┌ $vcsFolder git" "$orange" "Newer dependencies"
    else
        do_print_status "$vcsFolder git" "$green" "Up-to-date"
        [[ ! -f recompile ]] && {
            unset_extra_script
            return 1
        }
        do_print_status "┌ $vcsFolder git" "$orange" "Forcing recompile"
        do_print_status prefix "$bold├$reset " "Found recompile flag" "$orange" "Recompiling"
    fi
    extra_script post vcs
    return 0
}

# get source from VCS to a local subfolder
# example:
#   do_vcs_local "url#branch|revision|tag|commit=NAME" "subfolder"
do_vcs_local() {
    local vcsURL=${1#*::} vcsFolder=$2 vcsCheck=("${_check[@]}")
    local vcsBranch=${vcsURL#*#} ref=origin/HEAD
    local deps=("${_deps[@]}") && unset _deps
    [[ $vcsBranch == "$vcsURL" ]] && unset vcsBranch
    vcsURL=${vcsURL%#*}
    : "${vcsFolder:=$(basename "$vcsURL" .git)}"

    if [[ -n $vcsBranch ]]; then
        ref=${vcsBranch##*=}
        [[ ${vcsBranch%%=*}/$ref == branch/${ref%/*} ]] && ref=origin/$ref
    fi

    rm -f "$vcsFolder/custom_updated"

    # try to see if we can "resolve" the currently provided ref, minus the origin/ part,
    # if so, set ref to the ref on the origin, this might make it harder for people who
    # want use multiple remotes other than origin. Converts ref=develop to ref=origin/develop
    # ignore those that use the special tags/branches
    case $ref in
    LATEST | GREATEST | *\**) ;;
    *) git ls-remote --exit-code "$vcsURL" "${ref#origin/}" > /dev/null 2>&1 && ref=origin/${ref#origin/} ;;
    esac

    if ! check_valid_vcs "$vcsFolder"; then
        rm -rf "$vcsFolder"
        rm -rf "$vcsFolder-git"
        do_print_progress "  Running git clone for $vcsFolder"
        if ! do_mabs_clone "$vcsURL" "$vcsFolder" "$ref"; then
            echo "$vcsFolder git seems to be down"
            echo "Try again later or <Enter> to continue"
            do_prompt "if you're sure nothing depends on it."
            # unset_extra_script
            return
        fi
        mv "$vcsFolder-git" "$vcsFolder"
        touch "$vcsFolder"/recently_{updated,checked}
    fi

    cd_safe "$vcsFolder"

    vcs_set_url "$vcsURL"
    log -q git.fetch vcs_fetch
    oldHead=$(vcs_get_merge_base "$ref")
    do_print_progress "  Running git update for $vcsFolder"
    log -q git.reset vcs_reset "$ref"
    newHead=$(vcs_get_current_head "$PWD")

    vcs_clean

    cd ..

    return 0
}

guess_dirname() {
    expr "$1" : '\(.\+\)\.\(tar\(\.\(gz\|bz2\|xz\|lz\)\)\?\|7z\|zip\)$'
}

check_hash() {
    local file="$1" check="$2" md5sum sha256sum
    if [[ -z $file || ! -f $file ]]; then
        return 1
    elif [[ -z $check ]]; then
        # if no hash to check, just check if the file exists
        return 0
    fi

    sha256sum=$(sha256sum "$file" | cut -d' ' -f1)
    if [[ $check == print ]]; then
        echo "$sha256sum"
    else
        md5sum=$(md5sum "$file" | cut -d' ' -f1)
        if [[ $sha256sum == "$check" || $md5sum == "$check" ]]; then
            return 0
        fi
        do_simple_print "${orange}Hash mismatch, file may be broken: ${check} != ${sha256sum} || ${md5sum}"
        return 1
    fi
}

# get wget download
do_wget() {
    local nocd=false norm=false quiet=false notmodified=false hash
    while true; do
        case $1 in
        -c) nocd=true && shift ;;
        -r) norm=true && shift ;;
        -q) quiet=true && shift ;;
        -h) hash="$2" && shift 2 ;;
        -z) notmodified=true && shift ;;
        --)
            shift
            break
            ;;
        *) break ;;
        esac
    done
    local url="$1" archive="$2" dirName="$3" response_code=000 curlcmds=("${curl_opts[@]}") tries=1 temp_file
    if [[ -z $archive ]]; then
        # remove arguments and filepath
        archive=${url%%\?*}
        archive=${archive##*/}
    fi
    if [[ -f $url ]]; then
        return 1
    fi
    archive=${archive:-"$(/usr/bin/curl -sI "$url" | grep -Eo 'filename=.*$' | sed 's/filename=//')"}
    [[ -z $dirName ]] && dirName=$(guess_dirname "$archive")

    $nocd || cd_safe "$LOCALBUILDDIR"
    $notmodified && [[ -f $archive ]] && curlcmds+=(-z "$archive" -R)
    [[ $hash ]] && tries=3

    if [[ -f $archive ]] && [[ $hash ]] && check_hash "$archive" "$hash"; then
        $quiet || do_print_status prefix "${bold}├${reset} " "${dirName:-$archive}" "$green" "File up-to-date"
        tries=0
    fi

    while [[ $tries -gt 0 ]]; do
        temp_file=$(mktemp)
        response_code=$("${curlcmds[@]}" -w "%{http_code}" -o "$temp_file" "$url")

        if [[ -f $archive ]] && diff -q "$archive" "$temp_file" > /dev/null 2>&1; then
            $quiet || do_print_status prefix "${bold}├${reset} " "${dirName:-$archive}" "$green" "File up-to-date"
            rm -f "$temp_file"
            break
        fi

        ((tries -= 1))

        case $response_code in
        2**)
            $quiet || do_print_status "┌ ${dirName:-$archive}" "$orange" "Downloaded"
            check_hash "$temp_file" "$hash" && cp -f "$temp_file" "$archive"
            rm -f "$temp_file"
            break
            ;;
        304)
            $quiet || do_print_status "┌ ${dirName:-$archive}" "$orange" "File up-to-date"
            rm -f "$temp_file"
            break
            ;;
        esac

        if check_hash "$archive" "$hash"; then
            printf '%b\n' "${orange}${archive}${reset}" \
                '\tFile not found online. Using local copy.'
        else
            do_print_status "└ ${dirName:-$archive}" "$red" "Failed"
            printf '%s\n' "Error $response_code while downloading $url" \
                "<Ctrl+c> to cancel build or <Enter> to continue"
            do_prompt "if you're sure nothing depends on it."
            rm -f "$temp_file"
            return 1
        fi
    done

    $norm || add_to_remove "$(pwd)/$archive"
    do_extract "$archive" "$dirName"
    ! $norm && [[ -n $dirName ]] && ! $nocd && add_to_remove
    [[ -z $response_code || $response_code != "304" ]] && return 0
}

real_extract() {
    local archive="$1" dirName="$2" archive_type strip_comp=''
    [[ -z $archive ]] && return 1
    archive_type=$(expr "$archive" : '.\+\(tar\(\.\(gz\|bz2\|xz\|lz\)\)\?\|7z\|zip\)$')
    [[ ! $dirName ]] && dirName=$(guess_dirname "$archive" || echo "${archive}")
    case $archive_type in
    zip | 7z)
        7z x -aoa -o"$dirName" "$archive"
        ;;
    tar*)
        [[ -n $dirName && ! -d $dirName ]] && mkdir -p "$dirName"
        case $archive_type in
        tar\.lz)
            do_pacman_install -m lzip
            lzip -d "$archive"
            ;;
        tar\.*) 7z x -aoa "$archive" ;;
        esac
        [[ $(tar -tf "${archive%.tar*}.tar" | cut -d'/' -f1 | sort -u | wc -l) == 1 ]] && strip_comp="--strip-components=1"
        if ! tar $strip_comp -C "$dirName" -xf "${1%.tar*}.tar"; then
            7z x -aoa "${archive%.tar*}.tar" -o"$dirName"
        fi
        rm -f "${archive%.tar*}.tar"
        ;;
    esac
    local temp_dir
    temp_dir=$(find "$dirName/" -maxdepth 1 ! -wholename "$dirName/")
    if [[ -n $temp_dir && $(wc -l <<< "$temp_dir") == 1 ]]; then
        find "$temp_dir" -maxdepth 1 ! -wholename "$temp_dir" -exec mv -t "$dirName/" {} +
        rmdir "$temp_dir" 2> /dev/null
    fi
}

do_extract() {
    local nocd="${nocd:-false}"
    local archive="$1" dirName="$2"
    # accepted: zip, 7z, tar, tar.gz, tar.bz2 and tar.xz
    [[ -z $dirName ]] && dirName=$(guess_dirname "$archive")
    if [[ $dirName != "." && -d $dirName ]]; then
        if [[ $build32 == "yes" && ! -f \
            "$dirName/build_successful32bit${flavor:+_$flavor}" ]]; then
            rm -rf "$dirName"
        elif [[ $build64 == "yes" && ! -f \
            "$dirName/build_successful64bit${flavor:+_$flavor}" ]]; then
            rm -rf "$dirName"
        fi
    elif [[ -d $dirName ]]; then
        $nocd || cd_safe "$dirName"
        return 0
    elif ! expr "$archive" : '.\+\(tar\(\.\(gz\|bz2\|xz\|lz\)\)\?\|7z\|zip\)$' > /dev/null; then
        return 0
    fi
    log "extract" real_extract "$archive" "$dirName"
    $nocd || cd_safe "$dirName"
}

do_wget_sf() {
    # do_wget_sf "faac/faac-src/faac-1.28/faac-$_ver.tar.bz2" "faac-$_ver"
    local hash
    [[ $1 == "-h" ]] && hash="$2" && shift 2
    local url="https://download.sourceforge.net/$1"
    shift 1
    if [[ -n $hash ]]; then
        do_wget -h "$hash" "$url" "$@"
    else
        do_wget "$url" "$@"
    fi
    local ret=$?
    check_custom_patches
    return $ret
}

do_strip() {
    local cmd exts nostrip file
    local cmd=(strip)
    local nostrip="x265|x265-numa|ffmpeg|ffprobe|ffplay"
    local exts="exe|dll|com|a"
    [[ -f $LOCALDESTDIR/bin-video/mpv.exe.debug ]] && nostrip+="|mpv"
    for file; do
        if [[ $file =~ \.($exts)$ && ! $file =~ ($nostrip)\.exe$ ]]; then
            do_print_progress Stripping
            break
        fi
    done
    for file; do
        local orig_file="$file"
        if ! file="$(file_installed "$orig_file")"; then
            continue
        fi
        if [[ $file =~ \.(exe|com)$ ]] &&
            [[ ! $file =~ ($nostrip)\.exe$ ]]; then
            cmd+=(--strip-all)
        elif [[ $file =~ \.dll$ ]] ||
            [[ $file =~ x265(|-numa)\.exe$ ]]; then
            cmd+=(--strip-unneeded)
        elif ! disabled debug && [[ $file =~ \.a$ ]]; then
            cmd+=(--strip-debug)
        else
            file=""
        fi
        [[ $file ]] &&
            { eval "${cmd[@]}" "$file" 2> /dev/null ||
                eval "${cmd[@]}" "$file" -o "$file.stripped" 2> /dev/null; }
        [[ -f ${file}.stripped ]] && mv -f "${file}"{.stripped,}
    done
}

do_pack() {
    local file
    local cmd=(/opt/bin/upx -9 -qq)
    local nopack=""
    local exts="exe|dll"
    [[ $bits == 64bit ]] && enabled_any libtls openssl && nopack="ffmpeg|mplayer|mpv"
    for file; do
        if [[ $file =~ \.($exts)$ && ! $file =~ ($nopack)\.exe$ ]]; then
            do_print_progress Packing with UPX
            break
        fi
    done
    for file; do
        local orig_file="$file"
        if ! file="$(file_installed "$orig_file")"; then
            continue
        fi
        if [[ $file =~ \.($exts)$ ]] &&
            ! [[ -n $nopack && $file =~ ($nopack)\.exe$ ]]; then
            [[ $stripping == y ]] && cmd+=("--strip-relocs=0")
        else
            file=""
        fi
        [[ $file ]] && eval "${cmd[@]}" "$file"
    done
}

do_zipman() {
    local file files
    local man_dirs=(/local{32,64}/share/man)
    files=$(find "${man_dirs[@]}" -type f \! -name "*.gz" \! -name "*.db" \! -name "*.bz2" 2> /dev/null)
    for file in $files; do
        gzip -9 -n -f "$file"
        rm -f "$file"
    done
}

# check if compiled file exist
do_checkIfExist() {
    local packetName
    packetName="$(get_first_subdir)"
    local packageDir="${LOCALBUILDDIR}/${packetName}"
    local buildSuccessFile="${packageDir}/build_successful${bits}"
    local dry="${dry:-n}"
    local check=()
    if [[ -n $1 ]]; then
        check+=("$@")
    else
        check+=("${_check[@]}")
        unset _check
    fi
    unset_extra_script
    [[ -z ${check[*]} ]] && echo "No files to check" && return 1
    if [[ $dry == y ]]; then
        files_exist -v -s "${check[@]}"
        return $?
    fi
    if files_exist -v "${check[@]}"; then
        [[ $stripping == y ]] && do_strip "${check[@]}"
        [[ $packing == y ]] && do_pack "${check[@]}"
        do_print_status "└ $packetName" "$blue" "Updated"
        [[ $build32 == yes || $build64 == yes ]] && [[ -d $packageDir ]] &&
            touch "$buildSuccessFile"
    else
        [[ $build32 == yes || $build64 == yes ]] && [[ -d $packageDir ]] &&
            rm -f "$buildSuccessFile"
        do_print_status "└ $packetName" "$red" "Failed"
        if ${_notrequired:-false}; then
            printf '%s\n' \
                "$orange"'Package failed to build, but is not required; proceeding with compilation.'"$reset"
        else
            printf '%s\n' \
                '' "Try deleting '$packageDir' and start the script again." \
                'If you are sure there are no dependencies, <Enter> to continue building.'
            do_prompt "Close this window if you wish to stop building."
        fi
    fi
}

file_installed() {
    local file silent
    [[ $1 == "-s" ]] && silent=true && shift
    case $1 in
    /* | ./*)
        file="$1"
        ;;
    *.pc)
        file="lib/pkgconfig/$1"
        ;;
    *.a | *.la | *.lib)
        file="lib/$1"
        ;;
    *.h | *.hpp | *.c)
        file="include/$1"
        ;;
    *)
        file="$1"
        ;;
    esac
    [[ ${file::1} != "/" ]] && file="$LOCALDESTDIR/$file"
    ${silent:-false} || echo "$file"
    test -e "$file"
}

files_exist() {
    local verbose list soft ignorebinaries term='\n' file
    while true; do
        case $1 in
        -v) verbose=y && shift ;;
        -l) list=y && shift ;;
        -s) soft=y && shift ;;
        -b) ignorebinaries=y && shift ;;
        -l0) list=y && term='\0' && shift ;;
        --)
            shift
            break
            ;;
        *) break ;;
        esac
    done
    [[ $list ]] && verbose= && soft=y
    for opt; do
        if file=$(file_installed "$opt"); then
            [[ $verbose && $soft ]] && do_print_status "├ $file" "${green}" "Found"
            if [[ $list ]]; then
                if [[ $ignorebinaries && $file =~ .(exe|com)$ ]]; then
                    continue
                fi
                printf "%s%b" "$file" "$term"
            fi
        else
            [[ $verbose ]] && do_print_status prefix "${bold}├${reset} " "$file" "${red}" "Not found"
            [[ ! $soft ]] && return 1
        fi
    done
    return 0
}

pc_exists() {
    for opt; do
        local _pkg=${opt%% *}
        local _check=${opt#$_pkg}
        [[ $_pkg == "$_check" ]] && _check=""
        [[ $_pkg == *.pc ]] || _pkg="${LOCALDESTDIR}/lib/pkgconfig/${_pkg}.pc"
        $PKG_CONFIG --exists --silence-errors "${_pkg}${_check}" || return
    done
}

do_install() {
    [[ $1 == dry ]] && local dryrun=y && shift
    local files=("$@")
    local dest="${files[-1]}"
    [[ ${dest::1} != "/" ]] && dest="$(file_installed "$dest")"
    [[ ${#files[@]} -gt 1 ]] && unset 'files[-1]'
    [[ ${dest: -1:1} == "/" ]] && mkdir -p "$dest"
    if [[ -n $dryrun ]]; then
        echo install -D -p "${files[@]}" "$dest"
    else
        extra_script pre install
        [[ -f "$(get_first_subdir -f)/do_not_install" ]] &&
            return
        install -D -p "${files[@]}" "$dest"
        extra_script post install
    fi
}

do_uninstall() {
    local dry quiet all files
    [[ $1 == dry ]] && dry=y && shift
    [[ $1 == q ]] && quiet=y && shift
    [[ $1 == all ]] && all=y && shift
    if [[ $all ]]; then
        mapfile -t files < <(files_exist -l "$@")
    else
        mapfile -t files < <(files_exist -l -b "$@")
    fi
    if [[ -n ${files[*]} ]]; then
        [[ ! $quiet ]] && do_print_progress Running uninstall
        if [[ $dry ]]; then
            echo "rm -rf ${files[*]}"
        else
            rm -rf "${files[@]}"
        fi
    fi
}

do_pkgConfig() {
    local pkg="${1%% *}"
    local pc_check="${1#$pkg}"
    local pkg_and_version="$pkg"
    [[ $pkg == "$pc_check" ]] && pc_check=""
    local version=$2
    local deps=("${_deps[@]}") && unset _deps
    [[ ! $version && $pc_check ]] && version="${pc_check#*= }"
    [[ "$version" ]] && pkg_and_version="${pkg} ${version}"
    if ! pc_exists "${pkg}"; then
        do_print_status "${pkg_and_version}" "$red" "Not installed"
    elif ! pc_exists "${pkg}${pc_check}"; then
        do_print_status "${pkg_and_version}" "$orange" "Outdated"
    elif [[ -n ${deps[*]} ]] && test_newer installed "${deps[@]}" "${pkg}.pc"; then
        do_print_status "${pkg_and_version}" "$orange" "Newer dependencies"
    elif [[ -n ${_check[*]} ]] && ! files_exist "${_check[@]}"; then
        do_print_status "${pkg_and_version}" "$orange" "Files missing"
    else
        do_print_status "${pkg_and_version}" "$green" "Up-to-date"
        return 1
    fi
}

do_readoptionsfile() {
    local filename="$1"
    if [[ -f $filename ]]; then
        sed -r '# remove commented text
                s/#.*//
                # delete empty lines
                /^\s*$/d
                # remove leading whitespace
                s/^\s+//
                # remove trailing whitespace
                s/\s+$//
                ' "$filename" | tr -d '\r' # cut cr out from any crlf files
        echo "Imported options from ${filename##*/}" >&2
    fi
}

do_readbatoptions() {
    local varname="$1"
    # shellcheck disable=SC1117
    printf '%s\n' "${bat[@]}" |
        sed -En "/set ${varname}=/,/[^^]$/p" |
        sed -E "/^:/d;s/(set ${varname}=| \\^|\")//g;s/ /\\n/g" |
        sed -E '/^#/d;/^[^-]/{s/^/--enable-/g}'
}

do_getFFmpegConfig() {
    local license="${1:-nonfree}"

    FFMPEG_DEFAULT_OPTS=()
    if [[ -f "/trunk/media-autobuild_suite.bat" && $ffmpegChoice =~ (n|z|f) ]]; then
        IFS=$'\r\n' read -d '' -r -a bat < /trunk/media-autobuild_suite.bat
        mapfile -t FFMPEG_DEFAULT_OPTS < <(do_readbatoptions "ffmpeg_options_(builtin|basic)")
        local option
        [[ $ffmpegChoice != n ]] && while read -r option; do
            FFMPEG_DEFAULT_OPTS+=("$option")
        done < <(do_readbatoptions "ffmpeg_options_zeranoe")
        [[ $ffmpegChoice == f ]] && while read -r option; do
            FFMPEG_DEFAULT_OPTS+=("$option")
        done < <(do_readbatoptions "ffmpeg_options_full(|_shared)")
        echo "Imported default FFmpeg options from .bat"
    else
        local custom_opts_file="$LOCALBUILDDIR/ffmpeg_options.txt"
        if [[ -f "$LOCALBUILDDIR/ffmpeg_options_$bits.txt" ]]; then
            custom_opts_file="$LOCALBUILDDIR/ffmpeg_options_$bits.txt"
        fi
        IFS=$'\n' read -d '' -r -a FFMPEG_DEFAULT_OPTS < <(do_readoptionsfile "$custom_opts_file")
        unset FFMPEG_DEFAULT_OPTS_SHARED
        if [[ -f "$LOCALBUILDDIR/ffmpeg_options_shared.txt" ]]; then
            IFS=$'\n' read -d '' -r -a FFMPEG_DEFAULT_OPTS_SHARED < <(
                do_readoptionsfile "$LOCALBUILDDIR/ffmpeg_options_shared.txt"
            )
        fi
    fi

    FFMPEG_OPTS=()
    for opt in "${FFMPEG_BASE_OPTS[@]}" "${FFMPEG_DEFAULT_OPTS[@]}"; do
        [[ -n $opt ]] && FFMPEG_OPTS+=("$opt")
    done

    echo "License: $license"

    # we set these accordingly for static or shared
    do_removeOption "--(en|dis)able-(shared|static)"

    # OK to use GnuTLS for rtmpdump if not nonfree since GnuTLS was built for rtmpdump anyway
    # If nonfree will use SChannel if neither openssl/libtls or gnutls are in the options
    if ! enabled_any libtls openssl gnutls &&
        { enabled librtmp || [[ $rtmpdump == y ]]; }; then
        if [[ $license == nonfree ]] ||
            [[ $license == lgpl* && $rtmpdump == n ]]; then
            do_addOption --enable-openssl
        else
            do_addOption --enable-gnutls
        fi
        do_removeOption "--enable-(gmp|gcrypt|mbedtls)"
    fi

    local _all_tls="--enable-(mbedtls|gnutls|openssl|libtls|schannel)"
    if enabled_any libtls openssl && [[ $license != gpl* ]]; then
        # prefer openssl/libtls if both are in options and not gpl

        # prefer openssl over libtls if both enabled
        local _prefer=libtls
        if enabled openssl; then
            _prefer=openssl
        fi

        do_removeOption "${_all_tls}"
        do_addOption "--enable-${_prefer}"
    elif enabled mbedtls; then
        # prefer mbedtls if any other tls libs are enabled and gpl
        do_removeOption "${_all_tls}"
        do_addOption --enable-mbedtls
    elif enabled gnutls; then
        do_removeOption "${_all_tls}"
        do_addOption --enable-gnutls
    elif ! disabled schannel; then
        # fallback to schannel if no other tls libs are enabled
        do_addOption --enable-schannel
    fi

    enabled_any lib{vo-aacenc,aacplus,utvideo,dcadec,faac,ebur128,ndi_newtek,ndi-newtek,ssh,wavpack} netcdf &&
        do_removeOption "--enable-(lib(vo-aacenc|aacplus|utvideo|dcadec|faac|ebur128|ndi_newtek|ndi-newtek|ssh|wavpack)|netcdf)" &&
        sed -ri 's;--enable-(lib(vo-aacenc|aacplus|utvideo|dcadec|faac|ebur128|ndi_newtek|ndi-newtek|ssh|wavpack)|netcdf);;g' \
            "$LOCALBUILDDIR/ffmpeg_options.txt"
}

do_changeFFmpegConfig() {
    local license="${1:-nonfree}"
    do_print_progress Changing options to comply to "$license"
    # if w32threads is disabled, pthreads is used and needs this cflag
    # decklink includes zvbi, which requires pthreads
    if disabled w32threads || enabled pthreads || enabled_all decklink libzvbi || enabled libvmaf; then
        do_removeOption --enable-w32threads
        do_addOption --disable-w32threads
    fi

    # add options for static kvazaar
    enabled libkvazaar && do_addOption --extra-cflags=-DKVZ_STATIC_LIB

    # get libs restricted by license
    local config_script=configure
    [[ $(get_first_subdir) != "ffmpeg-git" ]] && config_script="$LOCALBUILDDIR/ffmpeg-git/configure"
    [[ -f $config_script ]] || do_exit_prompt "There's no configure script to retrieve libs from"
    eval "$(sed -n '/EXTERNAL_LIBRARY_GPL_LIST=/,/^"/p' "$config_script" | tr -s '\n' ' ')"
    eval "$(sed -n '/HWACCEL_LIBRARY_NONFREE_LIST=/,/^"/p' "$config_script" | tr -s '\n' ' ')"
    eval "$(sed -n '/EXTERNAL_LIBRARY_NONFREE_LIST=/,/^"/p' "$config_script" | tr -s '\n' ' ')"
    eval "$(sed -n '/EXTERNAL_LIBRARY_VERSION3_LIST=/,/^"/p' "$config_script" | tr -s '\n' ' ')"

    # handle gpl libs
    local gpl
    read -ra gpl <<< "${EXTERNAL_LIBRARY_GPL_LIST//_/-} gpl"
    if [[ $license == gpl* || $license == nonfree ]] &&
        { enabled_any "${gpl[@]}" || ! disabled postproc; }; then
        do_addOption --enable-gpl
    else
        do_removeOptions "${gpl[*]/#/--enable-} --enable-postproc --enable-gpl"
    fi

    # handle (l)gplv3 libs
    local version3
    read -ra version3 <<< "${EXTERNAL_LIBRARY_VERSION3_LIST//_/-}"
    if [[ $license =~ (l|)gplv3 || $license == nonfree ]] && enabled_any "${version3[@]}"; then
        do_addOption --enable-version3
    else
        do_removeOptions "${version3[*]/#/--enable-} --enable-version3"
    fi

    local nonfreehwaccel
    read -ra nonfreehwaccel <<< "(${HWACCEL_LIBRARY_NONFREE_LIST//_/-}"
    if [[ $license == "nonfree" ]] && enabled_any "${nonfreehwaccel[@]}"; then
        do_addOption --enable-nonfree
    else
        do_removeOptions "${nonfreehwaccel[*]/#/--enable-} --enable-nonfree"
    fi

    # cuda-only workarounds
    if verify_cuda_deps; then
        if enabled libnpp; then
            echo -e "${orange}FFmpeg and related apps will depend on CUDA SDK to run!${reset}"
            local fixed_CUDA_PATH
            fixed_CUDA_PATH="$(cygpath -sm "$CUDA_PATH")"
            if [[ $fixed_CUDA_PATH != "${fixed_CUDA_PATH// /}" ]]; then
                # Assumes CUDA_PATH backwards is version/CUDA/NVIDIA GPU Computing Toolkit/rest of the path
                # Strips the onion to the rest of the path
                {
                    cat << EOF
@echo off
fltmc > NUL 2>&1 || echo Elevation required, right click the script and click 'Run as administrator'. & echo/ & pause & exit /b 1
cd /d "$(dirname "$(dirname "$(dirname "$(cygpath -sw "$CUDA_PATH")")")")"
EOF
                    # Generate up to 4 shortnames
                    for _n in 1 2 3 4; do
                        printf 'fsutil file setshortname "NVIDIA GPU Computing Toolkit" NVIDIA~%d || ' "$_n"
                    done
                    echo 'echo Failed to set a shortname for your CUDA_PATH'
                } > "$LOCALBUILDDIR/cuda.bat"
                do_simple_print "${orange}Spaces detected in the CUDA path"'!'"$reset"
                do_simple_print "Path returned by windows: ${bold}$fixed_CUDA_PATH${reset}"
                do_simple_print "A script to create the missing short paths for your CUDA_PATH"
                do_simple_print "was created at $(cygpath -m "$LOCALBUILDDIR/cuda.bat")"
                do_simple_print "Please run that script as an administrator and rerun the suite"
                do_simple_print "${red}This will break FFmpeg compilation, so aborting early"'!'"${reset}"
                logging=n compilation_fail "do_changeFFmpegConfig"
            fi
            do_addOption "--extra-cflags=-I$fixed_CUDA_PATH/include"
            do_addOption "--extra-ldflags=-L$fixed_CUDA_PATH/lib/x64"
        fi
        if enabled cuda-nvcc; then
            local fixed_CUDA_PATH_UNIX
            fixed_CUDA_PATH_UNIX="$(cygpath -u "$CUDA_PATH")"
            nvcc.exe --help &> /dev/null || export PATH="$PATH:$fixed_CUDA_PATH_UNIX/bin"
            echo -e "${orange}FFmpeg and related apps will depend on Nvidia drivers!${reset}"
        fi
    else
        do_removeOption "--enable-(libnpp|cuda-nvcc)"
    fi

    # handle gpl-incompatible libs
    local nonfreegpl
    read -ra nonfreegpl <<< "${EXTERNAL_LIBRARY_NONFREE_LIST//_/-}"
    if enabled_any "${nonfreegpl[@]}"; then
        if [[ $license == "nonfree" ]] && enabled gpl; then
            do_addOption --enable-nonfree
        elif [[ $license == gpl* ]]; then
            do_removeOptions "${nonfreegpl[*]/#/--enable-}"
        fi
        # no lgpl here because they are accepted with it
    fi

    if ! disabled debug "debug=gdb"; then
        # fix issue with ffprobe not working with debug and strip
        do_addOption --disable-stripping
    fi

    # both openssl and mbedtls don't need gcrypt/gmp for rtmpe
    enabled_any openssl mbedtls && do_removeOption "--enable-(gcrypt|gmp)"

    # remove libs that don't work with shared
    if [[ $ffmpeg =~ "shared" || $ffmpeg =~ "both" ]]; then
        FFMPEG_OPTS_SHARED=()
        for opt in "${FFMPEG_OPTS[@]}" "${FFMPEG_DEFAULT_OPTS_SHARED[@]}"; do
            FFMPEG_OPTS_SHARED+=("$opt")
        done
    fi
    if [[ $ffmpeg == "bothstatic" ]]; then
        do_removeOption "--enable-(opencl|opengl|cuda-nvcc|libnpp|libopenh264)"
    fi
}

opt_exists() {
    local array="${1}[@]" && shift 1
    local opt value
    for opt; do
        for value in "${!array}"; do
            [[ $value =~ $opt ]] && return
        done
    done
    return 1
}

enabled() {
    test "${FFMPEG_OPTS[*]}" != "${FFMPEG_OPTS[*]#--enable-$1}"
}

disabled() {
    test "${FFMPEG_OPTS[*]}" != "${FFMPEG_OPTS[*]#--disable-$1}"
}

enabled_any() {
    local opt
    for opt; do
        enabled "$opt" && return 0
    done
    return 1
}

disabled_any() {
    local opt
    for opt; do
        disabled "$opt" && return 0
    done
    return 1
}

enabled_all() {
    local opt
    for opt; do
        enabled "$opt" || return 1
    done
    return 0
}

disabled_all() {
    local opt
    for opt; do
        disabled "$opt" || return 1
    done
    return 0
}

do_getMpvConfig() {
    local MPV_TEMP_OPTS=()
    MPV_OPTS=()
    if [[ -f "/trunk/media-autobuild_suite.bat" && $ffmpegChoice =~ (n|z|f) ]]; then
        IFS=$'\r\n' read -d '' -r -a bat < /trunk/media-autobuild_suite.bat
        mapfile -t MPV_TEMP_OPTS < <(do_readbatoptions "mpv_options_(builtin|basic)")
        local option
        [[ $ffmpegChoice == f ]] && while read -r option; do
            [[ -n $option ]] && MPV_TEMP_OPTS+=("$option")
        done < <(do_readbatoptions "mpv_options_full")
        echo "Imported default mpv options from .bat"
    else
        IFS=$'\n' read -d '' -r -a MPV_TEMP_OPTS < <(do_readoptionsfile "$LOCALBUILDDIR/mpv_options.txt")
    fi
    do_removeOption MPV_TEMP_OPTS \
        "--(en|dis)able-(vapoursynth-lazy|libguess|static-build|enable-gpl3|egl-angle-lib|encoding|crossc|dvdread|libass)"
    for opt in "${MPV_TEMP_OPTS[@]}"; do
        [[ -n $opt ]] && MPV_OPTS+=("$opt")
    done
}

mpv_enabled() {
    local option
    [[ $mpv == n ]] && return 1
    for option in "${MPV_OPTS[@]}"; do
        [[ $option =~ "--enable-$1"$ ]] && return
    done
    return 1
}

mpv_disabled() {
    local option
    [[ $mpv == n ]] && return 0
    for option in "${MPV_OPTS[@]}"; do
        [[ $option =~ "--disable-$1"$ ]] && return
    done
    return 1
}

mpv_enabled_any() {
    local opt
    for opt; do
        mpv_enabled "$opt" && return 0
    done
    return 1
}

mpv_disabled_any() {
    local opt
    for opt; do
        mpv_disabled "$opt" && return 0
    done
    return 1
}

mpv_enabled_all() {
    local opt
    for opt; do
        mpv_enabled "$opt" || return 1
    done
}

mpv_disabled_all() {
    local opt
    for opt; do
        mpv_disabled "$opt" || return 1
    done
}

mpv_enable() {
    local opt newopts=()
    for opt in "${MPV_OPTS[@]}"; do
        if [[ $opt =~ "--disable-$1"$ ]]; then
            newopts+=("--enable-$1")
        else
            newopts+=("$opt")
        fi
    done
    MPV_OPTS=("${newopts[@]}")
}

mpv_disable() {
    local opt newopts=()
    for opt in "${MPV_OPTS[@]}"; do
        if [[ $opt =~ "--enable-$1"$ ]]; then
            newopts+=("--disable-$1")
        else
            newopts+=("$opt")
        fi
    done
    MPV_OPTS=("${newopts[@]}")
}

do_addOption() {
    local varname="$1" array opt
    if [[ ${varname#--} == "$varname" ]]; then
        array="$varname" && shift 1
    else
        array="FFMPEG_OPTS"
    fi
    for opt; do
        ! opt_exists "$array" "$opt" && declare -ag "$array+=(\"$opt\")"
    done
}

do_removeOption() {
    local varname="$1"
    local arrayname
    if [[ ${varname#--} == "$varname" ]]; then
        arrayname="$varname" && shift 1
    else
        arrayname="FFMPEG_OPTS"
    fi

    local option="$1"
    local basearray temp=()
    basearray="${arrayname}[@]"
    local orig=("${!basearray}")

    for ((i = 0; i < ${#orig[@]}; i++)); do
        if [[ ! ${orig[$i]} =~ ^${option}$ ]]; then
            temp+=("${orig[$i]}")
        fi
    done
    # shellcheck disable=SC1117,SC1083
    eval "$arrayname"=\(\"\${temp[@]}\"\)
}

do_removeOptions() {
    local option
    local shared=$2
    for option in $1; do
        do_removeOption "$option" "$shared"
    done
}

do_patch() {
    local binarypatch="--binary"
    case $1 in -p) binarypatch="" && shift ;; esac
    local patch="${1%% *}"     # Location or link to patch.
    local patchName="${1##* }" # Basename of file. (test-diff-files.diff)
    local am=false             # Use git am to apply patch. Use with .patch files
    local strip=${3:-1}        # Leading directories to strip. "patch -p${strip}"
    [[ $patchName == "$patch" ]] && patchName="${patch##*/}"
    [[ $2 == am ]] && am=true

    # hack for URLs without filename
    patchName=${patchName:-"$(/usr/bin/curl -sI "$patch" | grep -Eo 'filename=.*$' | sed 's/filename=//')"}
    [[ -z $patchName ]] &&
        printf '%b\n' "${red}Failed to apply patch '$patch'" \
            "Patch without filename, ignoring. Specify an explicit filename.${reset}" &&
        return 1

    # Just don't. Make a fork or use the suite's directory as the root for
    # your diffs or manually edit the scripts if you are trying to modify
    # the helper and compile scripts. If you really need to, use patch instead.
    # Else create a patch file for the individual folders you want to apply
    # the patch to.
    [[ $PWD == "$LOCALBUILDDIR" ]] &&
        do_exit_prompt "Running patches in the build folder is not supported.
        Please make a patch for individual folders or modify the script directly"

    # Filter out patches that would require curl; else
    # check if the patch is a local patch and copy it to the current dir
    if ! do_wget -c -r -q "$patch" "$patchName" && [[ -f $patch ]]; then
        patch="$(
            cd_safe "$(dirname "$patch")"
            printf '%s' "$(pwd -P)" '/' "$(basename -- "$patch")"

        )" # Resolve fullpath
        [[ ${patch%/*} != "$PWD" ]] && cp -f "$patch" "$patchName" > /dev/null 2>&1
    fi

    if [[ -f $patchName ]]; then
        if $am; then
            git apply -3 --check --ignore-space-change --ignore-whitespace "$patchName" > /dev/null 2>&1 &&
                git am -q -3 --ignore-whitespace --no-gpg-sign "$patchName" > /dev/null 2>&1 &&
                return 0
            git am -q --abort > /dev/null 2>&1
        else
            patch --dry-run $binarypatch -s -N -p"$strip" -i "$patchName" > /dev/null 2>&1 &&
                patch $binarypatch -s -N -p"$strip" -i "$patchName" &&
                return 0
        fi
        printf '%b\n' "${orange}${patchName}${reset}" \
            '\tPatch could not be applied with `'"$($am && echo "git am" || echo "patch")"'`. Continuing without patching.'
    else
        printf '%b\n' "${orange}${patchName}${reset}" \
            '\tPatch not found anywhere. Continuing without patching.'
    fi
    return 1
}

do_custom_patches() {
    local patch
    for patch in "$@"; do
        [[ ${patch##*.} == "patch" ]] && do_patch "$patch" am
        [[ ${patch##*.} == "diff" ]] && do_patch "$patch"
    done
}

do_cmake() {
    local bindir=""
    local root=".."
    local cmake_build_dir=""
    while [[ -n $* ]]; do
        case "$1" in
        global | audio | video)
            bindir="-DCMAKE_INSTALL_BINDIR=$LOCALDESTDIR/bin-$1"
            shift
            ;;
        builddir=*)
            cmake_build_dir="${1#*=}"
            shift
            ;;
        skip_build_dir)
            local skip_build_dir=y
            shift
            ;;
        *)
            if [[ -d "./$1" ]]; then
                [[ -n $skip_build_dir ]] && root="./$1" || root="../$1"
                shift
            elif [[ -d "../$1" ]]; then
                root="../$1"
                shift
            fi
            break
            ;;
        esac
    done

    [[ -z $skip_build_dir ]] && create_build_dir "$cmake_build_dir"
    # use this array to pass additional parameters to cmake
    local cmake_extras=()
    extra_script pre cmake
    [[ -f "$(get_first_subdir -f)/do_not_reconfigure" ]] &&
        return
    # shellcheck disable=SC2086
    log "cmake" cmake "$root" -G Ninja -DBUILD_SHARED_LIBS=off \
        -DCMAKE_TOOLCHAIN_FILE="$LOCALDESTDIR/etc/toolchain.cmake" \
        -DCMAKE_INSTALL_PREFIX="$LOCALDESTDIR" -DUNIX=on \
        -DCMAKE_BUILD_TYPE=Release $bindir "$@" "${cmake_extras[@]}"
    extra_script post cmake
    unset cmake_extras
}

do_ninja() {
    extra_script pre ninja
    [[ -f "$(get_first_subdir -f)/do_not_build" ]] &&
        return
    log "build" ninja "$@"
    extra_script post ninja
}

do_ninjainstall() {
    extra_script pre install
    [[ -f "$(get_first_subdir -f)/do_not_install" ]] &&
        return
    cpuCount=1 log "install" ninja install "$@"
    extra_script post install
}

do_cmakeinstall() {
    do_cmake "$@"
    do_ninja
    do_ninjainstall
}

do_meson() {
    local bindir=""
    local root=".."
    case "$1" in
    global | audio | video)
        bindir="--bindir=bin-$1"
        ;;
    *)
        [[ -d "./$1" ]] && root="../$1" || bindir="$1"
        ;;
    esac
    shift 1

    create_build_dir
    # use this array to pass additional parameters to meson
    local meson_extras=()
    extra_script pre meson
    [[ -f "$(get_first_subdir -f)/do_not_reconfigure" ]] &&
        return
    # shellcheck disable=SC2086
    PKG_CONFIG="pkgconf --keep-system-libs --keep-system-cflags" CC=${CC/ccache /}.bat CXX=${CXX/ccache /}.bat \
        log "meson" meson setup "$root" --default-library=static --buildtype=release \
        --prefix="$LOCALDESTDIR" --backend=ninja $bindir "$@" "${meson_extras[@]}"
    extra_script post meson
    unset meson_extras
}

do_mesoninstall() {
    do_meson "$@"
    do_ninja
    do_ninjainstall
}

do_rust() {
    log "rust.update" "$RUSTUP_HOME/bin/cargo.exe" update
    # use this array to pass additional parameters to cargo
    local rust_extras=()
    extra_script pre rust
    [[ -f "$(get_first_subdir -f)/do_not_reconfigure" ]] &&
        return
    PKG_CONFIG_ALL_STATIC=true \
        CC="ccache clang" \
        log "rust.build" "$RUSTUP_HOME/bin/cargo.exe" build \
        --target="$CARCH"-pc-windows-gnu \
        --jobs="$cpuCount" "${@:---release}" "${rust_extras[@]}"
    extra_script post rust
    unset rust_extras
}

do_rustinstall() {
    log "rust.update" "$RUSTUP_HOME/bin/cargo.exe" update
    # use this array to pass additional parameters to cargo
    local rust_extras=()
    extra_script pre rust
    [[ -f "$(get_first_subdir -f)/do_not_reconfigure" ]] &&
        return
    PKG_CONFIG_ALL_STATIC=true \
        CC="ccache clang" \
        PKG_CONFIG="$LOCALDESTDIR/bin/ab-pkg-config" \
        log "rust.install" "$RUSTUP_HOME/bin/cargo.exe" install \
        --target="$CARCH"-pc-windows-gnu \
        --jobs="$cpuCount" "${@:---path=.}" "${rust_extras[@]}"
    extra_script post rust
    unset rust_extras
}

compilation_fail() {
    [[ -z $build32$build64 ]] && return 1
    local reason="$1"
    local operation="${reason,,}"
    if [[ $logging == y ]]; then
        echo "Likely error (tail of the failed operation logfile):"
        tail "ab-suite.${operation}.log"
        echo "${red}$reason failed. Check $(pwd -W)/ab-suite.$operation.log${reset}"
    fi
    if ${_notrequired:-false}; then
        echo "This isn't required for anything so we can move on."
        return 1
    else
        echo "${red}This is required for other packages, so this script will exit.${reset}"
        create_diagnostic
        zip_logs
        echo "Make sure the suite is up-to-date before reporting an issue. It might've been fixed already."
        $([[ $noMintty == y ]] && echo echo || echo do_prompt) "Try running the build again at a later time."
        exit 1
    fi
}

strip_ansi() {
    local txtfile newfile
    for txtfile; do
        [[ $txtfile != "${txtfile//stripped/}" ]] && continue
        local name="${txtfile%.*}" ext="${txtfile##*.}"
        [[ $txtfile != "$name" ]] &&
            newfile="$name.stripped.$ext" || newfile="$txtfile-stripped"
        sed -r "s/\x1b[[(][0-9;?]*[a-zA-Z]|\x1b\][0-9];//g" "$txtfile" > "$newfile"
    done
}

zip_logs() {
    local failed url
    failed=$(get_first_subdir)
    strip_ansi "$LOCALBUILDDIR"/*.log
    rm -f "$LOCALBUILDDIR/logs.zip"
    (
        cd "$LOCALBUILDDIR" > /dev/null || do_exit_prompt "Did you delete /build?"
        {
            echo /trunk/media-autobuild_suite.bat
            [[ $failed != . ]] && find "$failed" -name "*.log"
            find . -maxdepth 1 -name "*.stripped.log" -o -name "*_options.txt" -o -name "media-suite_*.sh" \
                -o -name "last_run" -o -name "media-autobuild_suite.ini" -o -name "diagnostics.txt" -o -name "patchedFolders"
        } | sort -uo failedFiles
        7za -mx=9 a logs.zip -- @failedFiles > /dev/null && rm failedFiles
    )
    # [[ ! -f $LOCALBUILDDIR/no_logs && -n $build32$build64 && $autouploadlogs = y ]] &&
    #     url="$(cd "$LOCALBUILDDIR" && /usr/bin/curl -sF'file=@logs.zip' https://0x0.st)"
    echo
    if [[ $url ]]; then
        echo "${green}All relevant logs have been anonymously uploaded to $url"
        echo "${green}Copy and paste ${red}[logs.zip]($url)${green} in the GitHub issue.${reset}"
    elif [[ -f "$LOCALBUILDDIR/logs.zip" ]]; then
        echo "${green}Attach $(cygpath -w "$LOCALBUILDDIR/logs.zip") to the GitHub issue.${reset}"
    else
        echo "${red}Failed to generate logs.zip!${reset}"
    fi
}

log() {
    local errorOut=true quiet=false ret OPTION OPTIND
    while getopts ':qe' OPTION; do
        case "$OPTION" in
        e) errorOut=false ;;
        q) quiet=true ;;
        *) break ;;
        esac
    done
    shift "$((OPTIND - 1))"

    [[ $1 == quiet ]] && quiet=true && shift # Temp compat with old style just in case
    local name="${1// /.}" _cmd="$2" extra
    shift 2
    $quiet || do_print_progress Running "$name"
    [[ $_cmd =~ ^(make|ninja)$ ]] && extra="-j$cpuCount"

    if [[ $logging == "y" ]]; then
        printf 'CPPFLAGS: %s\nCFLAGS: %s\nCXXFLAGS: %s\nLDFLAGS: %s\n%s %s\n' "$CPPFLAGS" "$CFLAGS" "$CXXFLAGS" "$LDFLAGS" "$_cmd${extra:+ $extra}" "$*" > "ab-suite.$name.log"
        $_cmd $extra "$@" >> "ab-suite.$name.log" 2>&1 ||
            { [[ $extra ]] && $_cmd -j1 "$@" >> "ab-suite.$name.log" 2>&1; }
    else
        $_cmd $extra "$@" || { [[ $extra ]] && $_cmd -j1 "$@"; }
    fi

    case ${ret:=$?} in
    0) return 0 ;;
    *) $errorOut && compilation_fail "$name" || return $ret ;;
    esac
}

create_build_dir() {
    local print_build_dir=false nocd=${nocd:-false} norm=false build_root build_dir getoptopt OPTARG OPTIND
    while getopts ":pcrC:" getoptopt; do
        case $getoptopt in
        p) print_build_dir=true ;;
        c) nocd=true ;;
        r) norm=true ;;
        C) build_root="$OPTARG" ;;
        \?)
            echo "Invalid Option: -$OPTARG" 1>&2
            return 1
            ;;
        :)
            echo "Invalid option: $OPTARG requires an argument" 1>&2
            return 1
            ;;
        esac
    done
    shift $((OPTIND - 1))

    build_dir="${build_root:+$build_root/}build${1:+-$1}-$bits"
    [[ -z $build_root && -d ../$build_dir ]] && cd_safe ..

    if [[ -d $build_dir && ! -f $(get_first_subdir -f)/do_not_clean ]]; then
        $norm || rm -rf "$build_dir" ||
            (cd_safe "$build_dir" && rm -rf ./*)
    fi
    [[ ! -d $build_dir ]] && mkdir -p "$build_dir"
    $nocd || cd_safe "$build_dir"
    $print_build_dir && printf '%s\n' "$build_dir"
}

get_external_opts() {
    local array="$1"
    local pkgname
    pkgname="$(get_first_subdir)"
    local optsfile="$LOCALBUILDDIR/${pkgname%-*}_options.txt"
    if [[ -n $array ]]; then
        # shellcheck disable=SC2034
        IFS=$'\n' read -d '' -r -a tmp < <(do_readoptionsfile "$optsfile")
        declare -ag "$array+=(\"\${tmp[@]}\")"
    else
        do_readoptionsfile "$optsfile"
    fi
}

do_separate_conf() {
    local bindir=""
    local last config_path
    case "$1" in
    global | audio | video)
        bindir="--bindir=$LOCALDESTDIR/bin-$1"
        ;;
    *) bindir="$1" ;;
    esac
    shift 1
    for last; do true; done
    if test -x "${last}/configure"; then
        config_path="$last"
    else
        config_path=".."
        create_build_dir
    fi
    do_configure --disable-shared --enable-static "$bindir" "$@"
}

do_separate_confmakeinstall() {
    do_separate_conf "$@"
    do_make
    do_makeinstall
    cd_safe ..
}

do_configure() {
    # use this array to pass additional parameters to configure
    local conf_extras=()
    extra_script pre configure
    [[ -f "$(get_first_subdir -f)/do_not_reconfigure" ]] &&
        return
    log "configure" ${config_path:-.}/configure --prefix="$LOCALDESTDIR" "$@" \
        "${conf_extras[@]}"
    extra_script post configure
    unset conf_extras
}

do_qmake() {
    extra_script pre qmake
    log "qmake" qmake "$@"
    extra_script post qmake
}

do_make() {
    extra_script pre make
    [[ -f "$(get_first_subdir -f)/do_not_build" ]] &&
        return
    log "make" make "$@"
    extra_script post make
}

do_makeinstall() {
    extra_script pre install
    [[ -f "$(get_first_subdir -f)/do_not_install" ]] &&
        return
    log "install" make install "$@"
    extra_script post install
}

do_hide_pacman_sharedlibs() {
    local packages="$1"
    local revert="$2"
    local files
    files="$(pacman -Qql "$packages" 2> /dev/null | /usr/bin/grep .dll.a)"

    for file in $files; do
        if [[ -f "${file%*.dll.a}.a" ]]; then
            if [[ -z $revert ]]; then
                mv -f "${file}" "${file}.dyn"
            elif [[ -n $revert && -f "${file}.dyn" && ! -f ${file} ]]; then
                mv -f "${file}.dyn" "${file}"
            elif [[ -n $revert && -f "${file}.dyn" ]]; then
                rm -f "${file}.dyn"
            fi
        fi
    done
}

do_hide_all_sharedlibs() {
    local dryrun="${dry:-n}"
    local files
    files="$(find /mingw{32,64}/lib /mingw{32/i686,64/x86_64}-w64-mingw32/lib -name "*.dll.a" 2> /dev/null)"
    local tomove=()
    for file in $files; do
        [[ -f ${file%*.dll.a}.a ]] && tomove+=("$file")
    done
    if [[ -n ${tomove[*]} ]]; then
        if [[ $dryrun == "n" ]]; then
            printf '%s\0' "${tomove[@]}" | xargs -0ri mv -f '{}' '{}.dyn'
        else
            printf '%s\n' "${tomove[@]}"
        fi
    fi
}

do_unhide_all_sharedlibs() {
    local dryrun="${dry:-n}"
    local files
    files="$(find /mingw{32,64}/lib /mingw{32/i686,64/x86_64}-w64-mingw32/lib -name "*.dll.a.dyn" 2> /dev/null)"
    local tomove=()
    local todelete=()
    for file in $files; do
        if [[ -f ${file%*.dyn} ]]; then
            todelete+=("$file")
        else
            tomove+=("${file%*.dyn}")
        fi
    done
    if [[ $dryrun == "n" ]]; then
        printf '%s\n' "${todelete[@]}" | xargs -ri rm -f '{}'
        printf '%s\n' "${tomove[@]}" | xargs -ri mv -f '{}.dyn' '{}'
    else
        printf 'rm %s\n' "${todelete[@]}"
        printf '%s\n' "${tomove[@]}"
    fi
}

do_pacman_install() {
    local pkg msyspackage=false pkgs
    while true; do
        case "$1" in
        -m) msyspackage=true && shift ;;
        *) break ;;
        esac
    done
    for pkg; do
        if ! $msyspackage && [[ $pkg != "${MINGW_PACKAGE_PREFIX}-"* ]]; then
            pkgs="${pkgs:+$pkgs }${MINGW_PACKAGE_PREFIX}-${pkg}"
        else
            pkgs="${pkgs:+$pkgs }${pkg}"
        fi
    done

    for pkg in $pkgs; do
        pacman -Qqe "$pkg" > /dev/null 2>&1 && continue
        do_simple_print -n "Installing ${pkg#$MINGW_PACKAGE_PREFIX-}... "
        if pacman -S --overwrite "/usr/*" --overwrite "/mingw64/*" --overwrite "/mingw32/*" --noconfirm --ask=20 --needed "$pkg" > /dev/null 2>&1; then
            pacman -D --asexplicit "$pkg" > /dev/null
            if $msyspackage; then
                /usr/bin/grep -q "^${pkg}$" /etc/pac-msys-extra.pk > /dev/null 2>&1 ||
                    echo "${pkg}" >> /etc/pac-msys-extra.pk
            else
                /usr/bin/grep -q "^${pkg#$MINGW_PACKAGE_PREFIX-}$" /etc/pac-mingw-extra.pk > /dev/null 2>&1 ||
                    echo "${pkg#$MINGW_PACKAGE_PREFIX-}" >> /etc/pac-mingw-extra.pk
            fi
            echo "done"
        else
            echo "failed"
        fi
    done
    sort -uo /etc/pac-mingw-extra.pk{,} > /dev/null 2>&1
    sort -uo /etc/pac-msys-extra.pk{,} > /dev/null 2>&1
    do_hide_all_sharedlibs
}

do_pacman_remove() {
    local pkg msyspackage=false pkgs
    while true; do
        case "$1" in
        -m) msyspackage=true && shift ;;
        *) break ;;
        esac
    done
    for pkg; do
        if ! $msyspackage && [[ $pkg != "${MINGW_PACKAGE_PREFIX}-"* ]]; then
            pkgs="${pkgs:+$pkgs }${MINGW_PACKAGE_PREFIX}-${pkg}"
        else
            pkgs="${pkgs:+$pkgs }${pkg}"
        fi
    done

    for pkg in $pkgs; do
        if $msyspackage; then
            [[ -f /etc/pac-msys-extra.pk ]] &&
                sed -i "/^${pkg}$/d" /etc/pac-msys-extra.pk > /dev/null 2>&1
        else
            [[ -f /etc/pac-mingw-extra.pk ]] &&
                sed -i "/^${pkg#$MINGW_PACKAGE_PREFIX-}$/d" /etc/pac-mingw-extra.pk > /dev/null 2>&1
        fi
        pacman -Qqe "$pkg" > /dev/null 2>&1 || continue
        do_simple_print -n "Uninstalling ${pkg#$MINGW_PACKAGE_PREFIX-}... "
        do_hide_pacman_sharedlibs "$pkg" revert
        if pacman -Rs --noconfirm --ask=20 "$pkg" > /dev/null 2>&1; then
            echo "done"
        else
            pacman -D --asdeps "$pkg" > /dev/null 2>&1
            echo "failed"
        fi
    done
    sort -uo /etc/pac-mingw-extra.pk{,} > /dev/null 2>&1
    sort -uo /etc/pac-msys-extra.pk{,} > /dev/null 2>&1
    do_hide_all_sharedlibs
    return 0
}

do_prompt() {
    # from http://superuser.com/a/608509
    while read -r -s -e -t 0.1; do :; done
    read -r -p "$1" ret
}

do_autoreconf() {
    extra_script pre autoreconf
    log "autoreconf" autoreconf -fiv "$@"
    extra_script post autoreconf
}

do_autoupdate() {
    extra_script pre autoupdate
    log "autoupdate" autoupdate "$@"
    extra_script post autoupdate
}

do_autogen() {
    extra_script pre autogen
    log "autogen" ./autogen.sh "$@"
    extra_script post autogen
}

get_first_subdir() {
    local subdir="${PWD#*$LOCALBUILDDIR/}" fullpath=false OPTION OPTIND
    while getopts ':f' OPTION; do
        case "$OPTION" in
        f) fullpath=true ;;
        *) break ;;
        esac
    done
    shift "$((OPTIND - 1))"

    if [[ $subdir != "$PWD" ]]; then
        $fullpath && printf '%s' "$LOCALBUILDDIR/"
        echo "${subdir%%/*}"
    else
        $fullpath && echo "$PWD" || echo "."
    fi
}

clean_html_index() {
    local url="$1"
    local filter="${2:-(?<=href=\")[^\"]+\.(tar\.(gz|bz2|xz)|7z)}"
    "${curl_opts[@]}" -l "$url" | grep -ioP "$filter" | sort -uV
}

get_last_version() {
    local filelist="$1"
    local filter="$2"
    local version="$3"
    local ret
    ret="$(/usr/bin/grep -E "$filter" <<< "$filelist" | sort -V | tail -1)"
    [[ -n $version ]] && ret="$(/usr/bin/grep -oP "$version" <<< "$ret")"
    echo "$ret"
}

create_debug_link() {
    for file; do
        if [[ -f $file && ! -f "$file".debug ]]; then
            echo "Stripping and creating debug link for ${file##*/}..."
            objcopy --only-keep-debug "$file" "$file".debug
            if [[ ${file: -3} == "dll" ]]; then
                strip --strip-debug "$file"
            else
                strip --strip-all "$file"
            fi
            objcopy --add-gnu-debuglink="$file".debug "$file"
        fi
    done
}

get_vs_prefix() {
    unset vsprefix
    local winvsprefix
    local regkey="/HKLM/software/vapoursynth/path"
    local embedded
    embedded="$(find "$LOCALDESTDIR"/bin-video -iname vspipe.exe)"
    if [[ -n $embedded ]]; then
        # look for .dlls in bin-video
        vsprefix="${embedded%/*}"
    elif [[ $bits == 64bit ]] && winvsprefix="$(regtool -q get "$regkey")"; then
        # check in native HKLM for installed VS (R31+)
        [[ -n $winvsprefix && -f "$winvsprefix/core64/vspipe.exe" ]] &&
            vsprefix="$(cygpath -u "$winvsprefix")/core64"
    elif winvsprefix="$(regtool -qW get "$regkey")"; then
        # check in 32-bit registry for installed VS
        [[ -n $winvsprefix && -f "$winvsprefix/core${bits%bit}/vspipe.exe" ]] &&
            vsprefix="$(cygpath -u "$winvsprefix/core${bits%bit}")"
    elif [[ -n $(command -v vspipe.exe 2> /dev/null) ]]; then
        # last resort, check if vspipe is in path
        vsprefix="$(dirname "$(command -v vspipe.exe)")"
    fi
    if [[ -n $vsprefix && -f "$vsprefix/vapoursynth.dll" && -f "$vsprefix/vsscript.dll" ]]; then
        local bitness
        bitness="$(file "$vsprefix/vapoursynth.dll")"
        { [[ $bits == 64bit && $bitness == *x86-64* ]] ||
            [[ $bits == 32bit && $bitness == *80386* ]]; } &&
            return 0
    else
        return 1
    fi
}

get_cl_path() {
    { type cl.exe && cl --help; } > /dev/null 2>&1 && return 0

    local _suite_vswhere=/opt/bin/vswhere.exe _sys_vswhere
    if _sys_vswhere=$(cygpath -u "$(cygpath -F 0x002a)/Microsoft Visual Studio/Installer/vswhere.exe") &&
        "$_sys_vswhere" -help > /dev/null 2>&1; then
        vswhere=$_sys_vswhere
    elif [[ -e $_suite_vswhere ]] &&
        $_suite_vswhere -help > /dev/null 2>&1; then
        vswhere=$_suite_vswhere
    elif (
        cd "$LOCALBUILDDIR" 2> /dev/null || return 1
        do_wget -c -r -q "https://github.com/Microsoft/vswhere/releases/latest/download/vswhere.exe"
        ./vswhere.exe -help > /dev/null 2>&1 || return 1
        do_install vswhere.exe /opt/bin/
    ); then
        vswhere=$_suite_vswhere
    else
        return 1
    fi

    local _hostbits=HostX64 _arch=x64
    [[ $(uname -m) != x86_64 ]] && _hostbits=HostX86
    [[ $bits == 32bit ]] && _arch=x86

    local basepath
    if basepath=$(cygpath -u "$("$vswhere" -latest -all -find "VC/Tools/MSVC/*/bin/${_hostbits:-HostX64}/${_arch:-x64}" | sort -uV | tail -1)") &&
        "$basepath/cl.exe" /? > /dev/null 2>&1; then
        export PATH="$basepath:$PATH"
        return 0
    else
        return 1
    fi
}

get_java_home() {
    local javahome version
    local javabasereg="/HKLM/software/javasoft"
    local regkey="$javabasereg/java development kit"
    export JAVA_HOME=
    export JDK_HOME=""
    if ! regtool -q check "$regkey"; then
        echo "no version of JDK found"
        return
    fi

    version="$(regtool -q get "$regkey/CurrentVersion")"
    [[ $(vercmp "$version" 1.8) != 0 ]] &&
        echo "JDK 1.8 required, 9 doesn't work" && return
    javahome="$(regtool -q get "$regkey/$version/JavaHome")"
    javahome="$(cygpath -u "$javahome")"
    [[ -f "$javahome/bin/java.exe" ]] &&
        export JAVA_HOME="$javahome"
}

# can only retrieve the dll version if it's actually in the ProductVersion field
get_dll_version() (
    dll=$1
    [[ -f $dll ]] || return 1
    version="$(7z l "$dll" | grep 'ProductVersion:' | sed 's/.*ProductVersion: //')"
    [[ -n $version ]] || return 1
    echo "$version"
)

get_api_version() {
    local header="$1"
    [[ -n $(file_installed "$header") ]] && header="$(file_installed "$header")"
    local line="$2"
    local column="$3"
    [[ ! -f $header ]] && printf '' && return
    /usr/bin/grep "${line:-VERSION}" "$header" | awk '{ print $c }' c="${column:-3}" | sed 's|"||g'
}

hide_files() {
    local reverse=false echo_cmd
    [[ $1 == "-R" ]] && reverse=true && shift
    [[ $dryrun == y ]] && echo_cmd="echo"
    for opt; do
        if ! $reverse; then
            [[ -f $opt ]] && $echo_cmd mv -f "$opt" "$opt.bak"
        else
            [[ -f "$opt.bak" ]] && $echo_cmd mv -f "$opt.bak" "$opt"
        fi
    done
}

hide_conflicting_libs() {
    # meant for rude build systems
    local reverse=false
    [[ $1 == "-R" ]] && reverse=true && shift
    local priority_prefix
    local -a installed
    mapfile -t installed < <(find "$LOCALDESTDIR/lib" -maxdepth 1 -name "*.a")
    if ! $reverse; then
        hide_files "${installed[@]//$LOCALDESTDIR/$MINGW_PREFIX}"
    else
        hide_files -R "${installed[@]//$LOCALDESTDIR/$MINGW_PREFIX}"
    fi
    if [[ -n $1 ]]; then
        priority_prefix="$1"
        mapfile -t installed < <(find "$priority_prefix/lib" -maxdepth 1 -name "*.a")
        if ! $reverse; then
            hide_files "${installed[@]//$1/$LOCALDESTDIR}"
        else
            hide_files -R "${installed[@]//$1/$LOCALDESTDIR}"
        fi
    fi
}

hide_libressl() {
    local _hide_files=(include/openssl
        lib/lib{crypto,ssl,tls}.{,l}a
        lib/pkgconfig/openssl.pc
        lib/pkgconfig/lib{crypto,ssl,tls}.pc)
    local reverse=n
    local _f
    [[ $1 == "-R" ]] && reverse=y && shift
    for _f in ${_hide_files[*]}; do
        _f="$LOCALDESTDIR/$_f"
        if [[ $reverse == n ]]; then
            [[ -e $_f ]] && mv -f "$_f" "$_f.bak"
        else
            [[ -e "$_f.bak" ]] && mv -f "$_f.bak" "$_f"
        fi
    done
}

add_to_remove() {
    echo "${1:-$(get_first_subdir -f)}" >> "$LOCALBUILDDIR/_to_remove"
}

clean_suite() {
    do_simple_print -p "${orange}Deleting status files...${reset}"
    cd_safe "$LOCALBUILDDIR" > /dev/null
    find . -maxdepth 2 -name recently_updated -delete
    find . -maxdepth 2 -regex ".*build_successful\(32\|64\)bit\(_\\w+\)?\$" -delete
    echo -e "\\n\\t${green}Zipping man files...${reset}"
    do_zipman

    if [[ $deleteSource == y ]]; then
        echo -e "\\t${orange}Deleting temporary build dirs...${reset}"
        find . -maxdepth 5 -name "ab-suite.*.log" -delete
        find . -maxdepth 5 -type d -name "build-*bit" -exec rm -rf {} +
        find . -maxdepth 2 -type d -name "build" -exec test -f "{}/CMakeCache.txt" ';' -exec rm -rf {} ';'

        if [[ -f _to_remove ]]; then
            echo -e "\\n\\t${orange}Deleting source folders...${reset}"
            grep -E "^($LOCALBUILDDIR|/trunk$LOCALBUILDDIR)" < _to_remove |
                grep -Ev "^$LOCALBUILDDIR/(patches|extras|$)" | sort -u | xargs -r rm -rf
        fi
        if [[ $(du -s /var/cache/pacman/pkg/ | cut -f1) -gt 1000000 ]]; then
            echo -e "\\t${orange}Deleting unneeded Pacman packages...${reset}"
            pacman -Sc --noconfirm
        fi
    fi

    rm -f {firstrun,firstUpdate,secondUpdate,pacman,mingw32,mingw64}.log diagnostics.txt \
        logs.zip _to_remove ./*.stripped.log

    [[ -f last_run ]] && mv last_run last_successful_run && touch last_successful_run
    [[ -f CHANGELOG.txt ]] && cat CHANGELOG.txt >> newchangelog
    unix2dos -n newchangelog CHANGELOG.txt 2> /dev/null && rm -f newchangelog
}

create_diagnostic() {
    local cmd cmds=("uname -a" "pacman -Qe" "pacman -Qd")
    local _env envs=(MINGW_{PACKAGE_PREFIX,CHOST,PREFIX} MSYSTEM CPATH
        LIBRARY_PATH {LD,C,CPP,CXX}FLAGS PATH)
    do_print_progress "  Creating diagnostics file"
    git -C /trunk rev-parse --is-inside-work-tree > /dev/null 2>&1 &&
        cmds+=("git -C /trunk log -1 --pretty=%h")
    {
        echo "Env variables:"
        for _env in "${envs[@]}"; do
            printf '\t%s=%s\n' "$_env" "${!_env}"
        done
        echo
        for cmd in "${cmds[@]}"; do
            printf '\t%s\n%s\n\n' "$cmd": "$($cmd)"
        done
    } > "$LOCALBUILDDIR/diagnostics.txt"
}

create_winpty_exe() {
    local exename="$1"
    local installdir="$2"
    shift 2
    [[ -f "${installdir}/${exename}".exe ]] && mv "${installdir}/${exename}"{.,_}exe
    # shellcheck disable=SC2016
    printf '%s\n' "#!/usr/bin/env bash" "$@" \
        'if [[ -t 1 ]]; then' \
        '/usr/bin/winpty "$( dirname ${BASH_SOURCE[0]} )/'"${exename}"'.exe" "$@"' \
        'else "$( dirname ${BASH_SOURCE[0]} )/'"${exename}"'.exe" "$@"; fi' \
        > "${installdir}/${exename}"
    [[ -f "${installdir}/${exename}"_exe ]] && mv "${installdir}/${exename}"{_,.}exe
}

create_ab_pkgconfig() {
    # from https://stackoverflow.com/a/8088167
    local script_file
    IFS=$'\n' read -r -d '' script_file << 'EOF' || true
#!/bin/sh

while true; do
case $1 in
    --libs|--libs-*) libs_args+=" $1"; shift ;;
    --static) static="--static"; shift ;;
    --* ) base_args+=" $1"; shift ;;
    * ) break ;;
esac
done

[[ -n $PKGCONF_STATIC ]] && static="--static"

run_pkgcfg() {
    "$MINGW_PREFIX/bin/pkgconf" --keep-system-libs --keep-system-cflags "$@" || exit 1
}

deduplicateLibs() {
    otherflags="$(run_pkgcfg $static $base_args "$@")"
    unordered="$(run_pkgcfg $static $libs_args "$@")"
    libdirs="$(printf '%s\n' $unordered | grep '^-L' | tr '\n' ' ')"
    unordered="${unordered//$libdirs}"
    ord_libdirs=""
    for libdir in $libdirs; do
        libdir="$(cygpath -m ${libdir#-L})"
        ord_libdirs+=" -L$libdir"
    done
    ord_libdirs="$(printf '%s\n' $ord_libdirs | awk '!x[$0]++' | tr '\n' ' ')"
    ord_libs="$(printf '%s\n' $unordered | tac | awk '!x[$0]++' | tac | tr '\n' ' ')"
    printf '%s ' $otherflags $ord_libdirs $ord_libs
    echo
}

if [[ -n $libs_args ]]; then
    deduplicateLibs "$@"
else
    run_pkgcfg $static $base_args $libs_args "$@"
fi
EOF
    mkdir -p "$LOCALDESTDIR"/bin > /dev/null 2>&1
    [[ -f "$LOCALDESTDIR"/bin/ab-pkg-config ]] &&
        diff -q <(printf '%s' "$script_file") "$LOCALDESTDIR"/bin/ab-pkg-config > /dev/null ||
        printf '%s' "$script_file" > "$LOCALDESTDIR"/bin/ab-pkg-config
    [[ -f "$LOCALDESTDIR"/bin/ab-pkg-config.bat ]] ||
        printf '%s\r\n' "@echo off" "" "bash $LOCALDESTDIR/bin/ab-pkg-config %*" > "$LOCALDESTDIR"/bin/ab-pkg-config.bat
    [[ -f "$LOCALDESTDIR"/bin/ab-pkg-config-static.bat ]] ||
        printf '%s\r\n' "@echo off" "" "bash $LOCALDESTDIR/bin/ab-pkg-config --static %*" > "$LOCALDESTDIR"/bin/ab-pkg-config-static.bat
}

create_ab_ccache() {
    local bin temp_file ccache_path=false ccache_win_path=
    temp_file=$(mktemp)
    if [[ $ccache == y ]] && type ccache > /dev/null 2>&1; then
        ccache_path="$(command -v ccache)"
        ccache_win_path=$(cygpath -m "$ccache_path")
    fi
    mkdir -p "$LOCALDESTDIR"/bin > /dev/null 2>&1
    for bin in {$MINGW_CHOST-,}{gcc,g++} clang{,++} cc cpp c++; do
        type "$bin" > /dev/null 2>&1 || continue
        cat << EOF > "$temp_file"
@echo off >nul 2>&1
rem() { "\$@"; }
rem test -f nul && rm nul
rem $ccache_path --help > /dev/null 2>&1 && $ccache_path $(command -v $bin) "\$@" || $(command -v $bin) "\$@"
rem exit \$?
$ccache_win_path $(cygpath -m "$(command -v $bin)") %*
EOF
        diff -q "$temp_file" "$LOCALDESTDIR/bin/$bin.bat" > /dev/null 2>&1 || cp -f "$temp_file" "$LOCALDESTDIR/bin/$bin.bat"
        chmod +x "$LOCALDESTDIR/bin/$bin.bat"
    done
    rm "$temp_file"
}

create_cmake_toolchain() {
    local _win_paths mingw_path
    _win_paths=$(cygpath -pm "$LOCALDESTDIR:$MINGW_PREFIX:$MINGW_PREFIX/$MINGW_CHOST")
    mingw_path=$(cygpath -m "$MINGW_PREFIX/include")
    local toolchain_file=(
        "SET(CMAKE_RC_COMPILER_INIT windres)"
        ""
        "LIST(APPEND CMAKE_PROGRAM_PATH $(cygpath -m "$LOCALDESTDIR/bin"))"
        "SET(CMAKE_FIND_ROOT_PATH $_win_paths)"
        "SET(CMAKE_PREFIX_PATH $_win_paths)"
        "SET(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)"
        "SET(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)"
        "SET(CMAKE_BUILD_TYPE Release)"
        "LIST(APPEND CMAKE_CXX_IMPLICIT_INCLUDE_DIRECTORIES $mingw_path)"
        "LIST(APPEND CMAKE_C_IMPLICIT_INCLUDE_DIRECTORIES $mingw_path)"
        "SET(CMAKE_NO_SYSTEM_FROM_IMPORTED ON)"
    )

    mkdir -p "$LOCALDESTDIR"/etc > /dev/null 2>&1
    [[ -f "$LOCALDESTDIR"/etc/toolchain.cmake ]] &&
        diff -q <(printf '%s\n' "${toolchain_file[@]}") "$LOCALDESTDIR"/etc/toolchain.cmake > /dev/null ||
        printf '%s\n' "${toolchain_file[@]}" > "$LOCALDESTDIR"/etc/toolchain.cmake
}

get_signature() {
    # get_signature 96865171 0F3BE490
    # adds keys to gpg keychain for verifying
    for keyserver in keys.openpgp.org pool.sks-keyservers.net keyserver.ubuntu.com pgp.mit.edu; do
        gpg --keyserver "$keyserver" --receive-keys "$@" && break
    done > /dev/null 2>&1
}

check_signature() {
    # check_signature -k 96865171 gnutls-3.6.8.tar.xz.sig gnutls-3.6.8.tar.xz
    # check_signature -k 1528635D8053A57F77D1E08630A59377A7763BE6 http://libsdl.org/release/SDL2-2.0.10.tar.gz.sig SDL2-2.0.10.tar.gz
    # run in the same directory as the files. Works with .sig and some .asc
    # file needs to start with -----BEGIN PGP SIGNATURE-----
    local key=()
    while true; do
        case $1 in
        -k) key+=("$2") && shift 2 ;; # keys to retrieve using get_signature
        --)
            shift
            break
            ;;
        *) break ;;
        esac
    done
    local sigFile=$1
    shift

    # Get name of sig file
    local sigFileName=${sigFile##*/}
    sigFileName=${sigFileName:-"$(/usr/bin/curl -sI "$sigFile" | grep -Eo 'filename=.*$' | sed 's/filename=//')"}
    [[ -z $sigFileName ]] && echo "Sig file not set" && return 1

    # Download sig file if url/cp file if local file
    if ! do_wget -c -r -q "$sigFile" "$sigFileName" && [[ -f $sigFile ]]; then
        sigFile="$(
            cd_safe "$(dirname "$sigFile")"
            printf '%s' "$(pwd -P)" '/' "$(basename -- "$sigFile")"
        )"
        [[ ${sigFile%/*} != "$PWD" ]] && cp -f "$sigFile" "$sigFileName" > /dev/null 2>&1
    fi

    # Retrive keys
    [[ -n ${key[0]} ]] && get_signature "${key[@]}"

    # Verify file is correct
    # $? 1 Bad sig or file integrity compromised
    # $? 2 no-pub-key or no file
    gpg --auto-key-retrieve --keyserver hkps://hkps.pool.sks-keyservers.net --verify "$sigFileName" "$@" > /dev/null 2>&1
    case $? in
    1) do_exit_prompt "Failed to verify integrity of ${sigFileName%%.sig}" ;;
    2) do_exit_prompt "Failed to find gpg key or no file found for ${sigFileName%%.sig}" ;;
    esac
}

do_jq() {
    local jq_file="$jq_file" output_raw_string=true
    # Detect if in pipe, useful for curling github api
    if [[ ! -t 0 ]]; then
        jq_file=/dev/stdin
    elif [[ -f $1 ]]; then
        jq_file="$1" && shift
    fi
    for a in "$@"; do
        grep -q -- ^- <<< "$a" && output_raw_string=false
    done
    if $output_raw_string; then
        jq -r "$*" < "$jq_file"
    else
        jq "$@" < "$jq_file"
    fi
}

grep_or_sed() {
    local grep_re="$1"
    local grep_file="$2"
    [[ ! -f $grep_file ]] && return
    local sed_re="$3"
    shift 3
    local sed_files=("$grep_file")
    [[ -n $1 ]] && sed_files=("$@")

    /usr/bin/grep -q -- "$grep_re" "$grep_file" ||
        /usr/bin/sed -ri -- "$sed_re" "${sed_files[@]}"
}

grep_and_sed() {
    local grep_re="$1"
    local grep_file="$2"
    [[ ! -f $grep_file ]] && return
    local sed_re="$3"
    shift 3
    local sed_files=("$grep_file")
    [[ -n $1 ]] && sed_files=("$@")

    /usr/bin/grep -q -- "$grep_re" "$grep_file" &&
        /usr/bin/sed -ri -- "$sed_re" "${sed_files[@]}"
}

compare_with_zeranoe() {
    local comparison="${1:-builtin}"
    local zeranoebase="https://ffmpeg.zeranoe.com/builds/readme"
    local zeranoe32 zeranoe64
    zeranoe32="$(curl -s "${zeranoebase}"/win32/static/ffmpeg-latest-win32-static-readme.txt |
        sed -n '/Configuration/,/Libraries/{/\s*--/{s/\s*//gp}}' | sort)"
    zeranoe64="$(curl -s "${zeranoebase}"/win64/static/ffmpeg-latest-win64-static-readme.txt |
        sed -n '/Configuration/,/Libraries/{/\s*--/{s/\s*//gp}}' | sort)"
    local localopts32=""
    local localopts64=""
    if [[ $comparison == "custom" ]]; then
        local custom32="$LOCALBUILDDIR/ffmpeg_options_32bit.txt"
        local custom64="$LOCALBUILDDIR/ffmpeg_options_64bit.txt"
        local custom="$LOCALBUILDDIR/ffmpeg_options.txt"
        [[ -f $custom32 ]] || custom32="$custom"
        [[ -f $custom64 ]] || custom64="$custom"
        if [[ -f $custom32 ]]; then
            IFS=$'\n' read -d '' -r localopts32 < <(do_readoptionsfile "$custom32")
        fi
        if [[ -f $custom64 ]]; then
            IFS=$'\n' read -d '' -r localopts64 < <(do_readoptionsfile "$custom64")
        fi
    else
        IFS=$'\r\n' read -d '' -r -a bat < /trunk/media-autobuild_suite.bat
        localopts32="$(do_readbatoptions "ffmpeg_options_(builtin|basic|zeranoe)" | sort)"
        localopts64="$localopts32"
    fi
    echo "Missing options from zeranoe 32-bits in $comparison options:"
    comm -23 <(echo "$zeranoe32") <(echo "$localopts32")
    printf '\n'
    echo "Missing options from zeranoe 64-bits in $comparison options:"
    comm -23 <(echo "$zeranoe64") <(echo "$localopts64")
    printf '\n'
}

fix_cmake_crap_exports() {
    local _dir="$1"
    # noop if passed directory is not valid
    test -d "$_dir" || return 1

    local _mixeddestdir _oldDestDir _cmakefile
    declare -a _cmakefiles

    _mixeddestdir="$(cygpath -m "$LOCALDESTDIR")"
    mapfile -t _cmakefiles < <(grep -Plr '\w:/[\w/]*local(?:32|64)' "$_dir"/*.cmake)

    # noop if array is empty
    test ${#_cmakefiles[@]} -lt 1 && return

    for _cmakefile in "${_cmakefiles[@]}"; do
        # find at least one
        _oldDestDir="$(grep -oP -m1 '\w:/[\w/]*local(?:32|64)' "$_cmakefile")"

        # noop if there's no expected install prefix found
        [[ -z $_oldDestDir ]] && continue
        # noop if old and current install prefix are equal
        [[ $_mixeddestdir == "$_oldDestDir" ]] && continue

        # use perl for the matching and replacing, a bit simpler than with sed
        perl -i -p -e 's;([A-Z]:/.*?)local(?:32|64);'"$_mixeddestdir"'\2;' "$_cmakefile"
    done
}

verify_cuda_deps() {
    enabled cuda-sdk && do_removeOption --enable-cuda-sdk && do_addOption --enable-cuda-nvcc
    if enabled_any libnpp cuda-nvcc && [[ $license != "nonfree" ]]; then
        do_removeOption "--enable-(cuda-nvcc|libnpp)"
    fi
    if enabled libnpp && [[ $bits == 32bit ]]; then
        echo -e "${orange}libnpp is only supported in 64-bit.${reset}"
        do_removeOption --enable-libnpp
    fi
    if enabled_any libnpp cuda-nvcc && [[ -z $CUDA_PATH || ! -d $CUDA_PATH ]]; then
        echo -e "${orange}CUDA_PATH environment variable not set or directory does not exist.${reset}"
        do_removeOption "--enable-(cuda-nvcc|libnpp)"
    fi
    if enabled libnpp && [[ ! -f "$CUDA_PATH/lib/x64/nppc.lib" ]]; then
        do_removeOption --enable-libnpp
    fi
    if ! disabled cuda-llvm && do_pacman_install clang; then
        do_removeOption --enable-cuda-nvcc
    else
        do_removeOption --enable-cuda-llvm
        do_addOption --disable-cuda-llvm
    fi
    if enabled cuda-nvcc; then
        if ! get_cl_path; then
            echo -e "${orange}MSVC cl.exe not found in PATH or through vswhere; needed by nvcc.${reset}"
            do_removeOption --enable-cuda-nvcc
        elif enabled cuda-nvcc && ! nvcc.exe --help &> /dev/null &&
            ! "$(cygpath -sm "$CUDA_PATH")/bin/nvcc.exe" --help &> /dev/null; then
            echo -e "${orange}nvcc.exe not found in PATH or installed in CUDA_PATH.${reset}"
            do_removeOption --enable-cuda-nvcc
        fi
    fi
    enabled_any libnpp cuda-nvcc || ! disabled cuda-llvm
}

check_custom_patches() {
    local _basedir=$1 vcsFolder=${1%-*}
    if [[ -z $1 ]]; then
        _basedir=$(get_first_subdir)
        vcsFolder=${_basedir%-*}
    fi
    [[ -f $LOCALBUILDDIR/${vcsFolder}_extra.sh ]] || return
    export REPO_DIR=$LOCALBUILDDIR/$_basedir
    export REPO_NAME=$vcsFolder
    do_print_progress "  Found ${vcsFolder}_extra.sh. Sourcing script"
    source "$LOCALBUILDDIR/${vcsFolder}_extra.sh"
    echo "$vcsFolder" >> "$LOCALBUILDDIR/patchedFolders"
    sort -uo "$LOCALBUILDDIR/patchedFolders"{,}
}

extra_script() {
    local stage="$1"
    local commandname="$2"
    local vcsFolder="${REPO_DIR%-*}"
    vcsFolder="${vcsFolder#*build/}"
    if [[ $commandname =~ ^(make|ninja)$ ]] &&
        type "_${stage}_build" > /dev/null 2>&1; then
        pushd "${REPO_DIR}" > /dev/null 2>&1 || true
        do_print_progress "Running ${stage} build from ${vcsFolder}_extra.sh"
        log -q "${stage}_build" "_${stage}_build"
        popd > /dev/null 2>&1 || true
    elif type "_${stage}_${commandname}" > /dev/null 2>&1; then
        pushd "${REPO_DIR}" > /dev/null 2>&1 || true
        do_print_progress "Running ${stage} ${commandname} from ${vcsFolder}_extra.sh"
        log -q "${stage}_${commandname}" "_${stage}_${commandname}"
        popd > /dev/null 2>&1 || true
    fi
}

unset_extra_script() {
    # The current repository folder (/build/ffmpeg-git)
    unset REPO_DIR
    # The repository name (ffmpeg)
    unset REPO_NAME
    # Should theoretically be the same as REPO_NAME with
    unset vcsFolder

    # Each of the _{pre,post}_<Command> means that there is a "_pre_<Command>"
    # and "_post_<Command>"

    # Runs before cloning or fetching a git repo and after
    unset _{pre,post}_vcs

    # Runs before and after building rust packages (do_rust)
    unset _{pre,post}_rust

    ## Pregenerational hooks

    # Runs before and after running autoreconf -fiv (do_autoreconf)
    unset _{pre,post}_autoreconf

    # Runs before and after running ./autogen.sh (do_autogen)
    unset _{pre,post}_autogen

    # Generational hooks

    # Runs before and after running ./configure (do_separate_conf, do_configure)
    unset _{pre,post}_configure

    # Runs before and after running cmake (do_cmake)
    unset _{pre,post}_cmake

    ## Build hooks

    # Runs before and after runing make (do_make)
    unset _{pre,post}_make

    # Runs before and after running meson (do_meson)
    unset _{pre,post}_meson

    # Runs before and after running ninja (do_ninja)
    unset _{pre,post}_ninja

    unset _{pre,post}_qmake

    # Runs before and after running make, meson, ninja, and waf (Generic hook for the previous build hooks)
    # If this is present, it will override the other hooks
    # Use for mpv and python waf based stuff.
    unset _{pre,post}_build

    ## Post build hooks

    # Runs before and after either ninja install
    # or make install or using install
    # (do_makeinstall, do_ninjainstall, do_install)
    unset _{pre,post}_install
}

create_extra_skeleton() {
    local overwrite
    while true; do
        case $1 in
        -f) overwrite=y && shift ;;
        --)
            shift
            break
            ;;
        *) break ;;
        esac
    done
    local extraName="$1"
    [[ -z $extraName ]] &&
        printf '%s\n' \
            'Usage: create_extra_skeleton [-f] <vcs folder name without the vcs type suffix>' \
            'For example, to create a ffmpeg_extra.sh skeleton file in '"$LOCALBUILDDIR"':' \
            '> create_extra_skeleton ffmpeg' && return 1
    [[ -f "$LOCALBUILDDIR/$extraName"_extra.sh && -z $overwrite ]] &&
        echo "$LOCALBUILDDIR/$extraName_extra.sh already exists. Use -f if you are sure you want to overwrite it." && return 1

    IFS=$'\n' read -r -d '' script_file << 'EOF' || true
#!/bin/bash

# Force to the suite to think the package has updates to recompile.
# Alternatively, you can use "touch recompile" for a similar effect.
#touch custom_updated

# Commands to run before and after cloning a repo
_pre_vcs() {
    # ref changes the branch/commit/tag that you want to clone
    ref=research
}

# Commands to run before and after running cmake (do_cmake)
_pre_cmake(){
    # Installs libwebp
    #do_pacman_install libwebp
    # Downloads the patch and then applies the patch
    #do_patch "https://gist.githubusercontent.com/1480c1/9fa9292afedadcea2b3a3e067e96dca2/raw/50a3ed39543d3cf21160f9ad38df45d9843d8dc5/0001-Example-patch-for-learning-purpose.patch"
    # Change directory to the build folder
    #cd_safe "build-${bits}"

    # Add additional options to suite's cmake execution
    #cmake_extras=(-DENABLE_SWEET_BUT_BROKEN_FEATURE=on)

    # To bypass the suite's cmake execution completely, create a do_not_reconfigure file in the repository root:
    #touch "$(get_first_subdir -f)/do_not_reconfigure"

    true
}

_post_cmake(){
    # Run cmake directly with custom options. $LOCALDESTDIR refers to local64 or local32
    #cmake .. -G"Ninja" -DCMAKE_INSTALL_PREFIX="$LOCALDESTDIR" \
    #    -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER=clang \
    #    -DBUILD_SHARED_LIBS=off -DENABLE_TOOLS=off
    true
}

# Runs before and after building rust packages (do_rust)
_pre_rust() {
    # Add additional options to suite's rust (cargo) execution
    #rust_extras=(--no-default-features --features=binaries)

    # To bypass the suite's cargo execution completely, create a do_not_reconfigure file in the repository root:
    #touch "$(get_first_subdir -f)/do_not_reconfigure"

    true
}
_post_rust() {
    true
}

# Runs before and after running meson (do_meson)
_pre_meson() {
    # Add additional options to suite's rust (cargo) execution
    #meson_extras=(-Denable_tools=true)

    # To bypass the suite's meson execution completely, create a do_not_reconfigure file in the repository root:
    #touch "$(get_first_subdir -f)/do_not_reconfigure"

    true
}
_post_meson() {
    true
}

# Runs before and after running autoreconf -fiv (do_autoreconf)
_pre_autoreconf() {
    true
}
_post_autoreconf() {
    true
}

# Runs before and after running ./autogen.sh (do_autogen)
_pre_autogen() {
    true
}
_post_autogen() {
    true
}

# Commands to run before and after running configure on a Autoconf/Automake/configure-using package
_pre_configure(){
    true
    #
    # Apply a patch from ffmpeg's patchwork site.
    #do_patch "https://patchwork.ffmpeg.org/patch/12563/mbox/" am
    #
    # Apply a local patch inside the directory where is "ffmpeg_extra.sh"
    #patch -p1 -i "$LOCALBUILDDIR/ffmpeg-0001-my_patch.patch"
    #
    # Add extra configure options to ffmpeg (ffmpeg specific)
    # If you want to add something to ffmpeg not within the suite already
    # you will need to install it yourself, either through pacman
    # or compiling from source.
    #FFMPEG_OPTS+=(--enable-libsvthevc)
    #
}
_post_configure(){
    true
}

# Runs before and after runing make (do_make)
_pre_make(){
    # To bypass the suite's make execution completely, create a do_not_build file in the repository root:
    #touch "$(get_first_subdir -f)/do_not_build"
    true
}
_post_make(){
    true
    # Don't run configure again.
    #touch "$(get_first_subdir -f)/do_not_reconfigure"
    # Don't clean the build folder on each successive run.
    # This is for if you want to keep the current build folder as is and just recompile only.
    #touch "$(get_first_subdir -f)/do_not_clean"
}

# Runs before and after running ninja (do_ninja)
_pre_ninja() {
    # To bypass the suite's ninja execution completely, create a do_not_build file in the repository root:
    #touch "$(get_first_subdir -f)/do_not_build"
    true
}
_post_ninja() {
    true
}

# Runs before and after running make, meson, ninja, and waf (Generic hook for the previous build hooks)
# If this is present, it will override the other hooks
# Use for mpv and python waf based stuff.
_pre_build() {
    # To bypass the suite's build execution completely, create a do_not_build file in the repository root:
    #touch "$(get_first_subdir -f)/do_not_build"
    true
}
_post_build() {
    true
}

# Runs before and after either ninja install
# or make install or using install
# (do_makeinstall, do_ninjainstall, do_install)
_pre_install() {
    # To bypass the suite's install completely, create a do_not_install file in the repository root:
    #touch "$(get_first_subdir -f)/do_not_install"
    true
}
_post_install() {
    true
}

EOF
    printf '%s' "$script_file" > "${LOCALBUILDDIR}/${extraName}_extra.sh"
    echo "Created skeleton file ${LOCALBUILDDIR}/${extraName}_extra.sh"
}

# if you absolutely need to remove some of these,
# add a "-e '!<hardcoded rule>'"  option
# ex: "-e '!/recently_updated'"
safe_git_clean() {
    git clean -xfd \
        -e "/build_successful*" \
        -e "/recently_updated" \
        -e '/custom_updated' \
        -e '**/ab-suite.*.log' \
        "${@}"
}
