#!/bin/bash
################################################################################
#
# Linux Deploy CLI
# (C) 2012-2016 Anton Skshidlevsky <meefik@gmail.com>, GPLv3
#
################################################################################

VERSION="2.1.4"

################################################################################
# Common
################################################################################

msg()
{
    echo "$@"
}

is_ok()
{
    if [ $? -eq 0 ]; then
        if [ -n "$2" ]; then
            msg "$2"
        fi
        return 0
    else
        if [ -n "$1" ]; then
            msg "$1"
        fi
        return 1
    fi
}

get_platform()
{
    local arch="$1"
    if [ -z "${arch}" ]; then
        arch=$(uname -m)
    fi
    case "${arch}" in
    arm64|aarch64)
        echo "arm_64"
    ;;
    arm*)
        echo "arm"
    ;;
    i[3-6]86|x86)
        echo "x86"
    ;;
    x86_64|amd64)
        echo "x86_64"
    ;;
    *)
        echo "unknown"
    ;;
    esac
}

get_qemu()
{
    local arch="$1"
    local qemu=""
    local host_platform=$(get_platform)
    local guest_platform=$(get_platform "${arch}")
    if [ "${host_platform}" != "${guest_platform}" ]; then
        case "${guest_platform}" in
        arm*) qemu="qemu-arm-static" ;;
        x86*) qemu="qemu-i386-static" ;;
        *) qemu="" ;;
        esac
    fi
    echo ${qemu}
}

get_uuid()
{
    cat /proc/sys/kernel/random/uuid
}

multiarch_support()
{
    if [ -d "/proc/sys/fs/binfmt_misc" ]; then
        return 0
    else
        return 1
    fi
}

selinux_support()
{
    if [ -d "/sys/fs/selinux" ]; then
        return 0
    else
        return 1
    fi
}

loop_support()
{
    if [ -n "$(losetup -f)" ]; then
        return 0
    else
        return 1
    fi
}

user_home()
{
    [ -e "${CHROOT_DIR}/etc/passwd" ] || return 1
    local user_name="$1"
    [ -n "${user_name}" ] || return 1
    echo $(grep -m1 "^${user_name}:" "${CHROOT_DIR}/etc/passwd" | awk -F: '{print $6}')
}

user_shell()
{
    [ -e "${CHROOT_DIR}/etc/passwd" ] || return 1
    local user_name="$1"
    [ -n "${user_name}" ] || return 1
    echo $(grep -m1 "^${user_name}:" "${CHROOT_DIR}/etc/passwd" | awk -F: '{print $7}')
}

is_mounted()
{
    local mount_point="$1"
    [ -n "${mount_point}" ] || return 1
    if $(grep -q " ${mount_point%/} " /proc/mounts); then
        return 0
    else
        return 1
    fi
}

is_archive()
{
    local src="$1"
    [ -n "${src}" ] || return 1
    if [ -z "${src##*gz}" -o -z "${src##*bz2}" -o -z "${src##*xz}" ]; then
        return 0
    fi
    return 1
}

get_pids()
{
    local pid pidfile pids
    for pid in $*
    do
        pidfile="${CHROOT_DIR}${pid}"
        if [ -e "${pidfile}" ]; then
            pid=$(cat "${pidfile}")
        fi
        if [ -e "/proc/${pid}" ]; then
            pids="${pids} ${pid}"
        fi
    done
    if [ -n "${pids}" ]; then
        echo ${pids}
        return 0
    else
        return 1
    fi
}

is_started()
{
    get_pids $* >/dev/null
}

is_stopped()
{
    is_started $*
    test $? -ne 0
}

kill_pids()
{
    local pids=$(get_pids $*)
    if [ -n "${pids}" ]; then
        kill -9 ${pids}
        return $?
    fi
    return 0
}

remove_files()
{
    local item target
    for item in $*
    do
        target="${CHROOT_DIR}${item}"
        if [ -e "${target}" ]; then
            rm -f "${target}"
        fi
    done
    return 0
}

make_dirs()
{
    local item target
    for item in $*
    do
        target="${CHROOT_DIR}${item}"
        if [ -d "${target%/*}" -a ! -d "${target}" ]; then
            mkdir "${target}"
        fi
    done
    return 0
}

chroot_exec()
{
    unset TMP TEMP TMPDIR LD_PRELOAD LD_DEBUG
    local path="${PATH}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    if [ "$1" = "-u" ]; then
        local username="$2"
        shift 2
    fi
    case "${METHOD}" in
    chroot)
        if [ -n "${username}" ]; then
            if [ $# -gt 0 ]; then
                chroot "${CHROOT_DIR}" /bin/su - ${username} -c "$*"
            else
                chroot "${CHROOT_DIR}" /bin/su - ${username}
            fi
        else
            PATH="${path}" chroot "${CHROOT_DIR}" $*
        fi
    ;;
    proot)
        if [ -z "${PROOT_TMP_DIR}" ]; then
            export PROOT_TMP_DIR="${TEMP_DIR}"
        fi
        local mounts="-b /proc -b /dev -b /sys"
        if [ -n "${MOUNTS}" ]; then
            mounts="${mounts} -b ${MOUNTS// / -b }"
        fi
        local emulator
        if [ -z "${EMULATOR}" ]; then
            EMULATOR=$(get_qemu ${ARCH})
        fi
        if [ -n "${EMULATOR}" ]; then
            emulator="-q ${EMULATOR}"
        fi
        if [ -n "${username}" ]; then
            if [ $# -gt 0 ]; then
                proot -r "${CHROOT_DIR}" -w / ${mounts} ${emulator} -0 -l -e /bin/su - ${username} -c "$*"
            else
                proot -r "${CHROOT_DIR}" -w / ${mounts} ${emulator} -0 -l -e /bin/su - ${username}
            fi
        else
            PATH="${path}" proot -r "${CHROOT_DIR}" -w / ${mounts} ${emulator} -0 -l -e $*
        fi
    ;;
    esac
}

sync_env()
{
    local env_url="$1"
    [ -n "${env_url}" ] || return 1
    msg -n "与服务器同步 ... "
    [ -e "${ENV_DIR}" ] || mkdir -p "${ENV_DIR}"
    wget -q -O - "${env_url}" | tar xz -C "${ENV_DIR}" 1>&2
    is_ok "失败" "完成"
}

################################################################################
# Params
################################################################################

params_read()
{
    local conf_file="$1"
    [ -e "${conf_file}" ] || return 1
    local item key val
    while read item
    do
        key=$(echo ${item} | grep -o '^[0-9A-Z_]\{1,32\}')
        val=${item#${key}=}
        if [ -n "${key}" ]; then
            eval ${key}="${val}"
            if [ -n "${OPTLST##* ${key} *}" ]; then
                OPTLST="${OPTLST}${key} "
            fi
        fi
    done < ${conf_file}
}

params_write()
{
    local conf_file="$1"
    [ -n "${conf_file}" ] || return 1
    echo "# ${conf_file##*/} $(date '+%F %R')" > ${conf_file}
    local key val
    for key in ${OPTLST}
    do
        eval "val=\$${key}"
        if [ -n "${key}" -a -n "${val}" ]; then
            echo "${key}=\"${val}\"" >> ${conf_file}
        fi
    done
}

params_parse()
{
    OPTIND=1
    if [ $# -gt 0 ] ; then
        local item key val
        for item in "$@"
        do
            key=$(expr "${item}" : '--\([0-9a-z-]\{1,32\}=\{0,1\}\)' | tr '\-abcdefghijklmnopqrstuvwxyz' '\_ABCDEFGHIJKLMNOPQRSTUVWXYZ')
            if [ -n "${key##*=*}" ]; then
                val="true"
            else
                key=${key%*=}
                val=$(expr "${item}" : '--[0-9a-z-]\{1,32\}=\(.*\)')
            fi
            if [ -n "${key}" ]; then
                eval ${key}=\"${val}\"
                let OPTIND=OPTIND+1
                if [ -n "${OPTLST##* ${key} *}" ]; then
                    OPTLST="${OPTLST}${key} "
                fi
            fi
        done
    fi
    #echo ${OPTLST} | tr ' ' '\n' | awk '!x[$0]++'
}

params_check()
{
    local params_list="$@"
    local key val params_lost
    for key in ${params_list}
    do
        eval "val=\$${key}"
        if [ -z "${val}" ]; then
            params_lost="${params_lost} ${key}"
        fi
    done
    if [ -n "${params_lost}" ]; then
        if [ "${DEBUG_MODE}" = "true" ]; then
            msg "缺少参数:${params_lost}"
        fi
        return 1
    fi
    return 0
}


################################################################################
# Configs
################################################################################

config_which()
{
    local conf_file="$1"
    if [ -n "${conf_file}" ]; then
        if [ -n "${conf_file##*/*}" ]; then
            conf_file="${CONFIG_DIR}/${conf_file}.conf"
        fi
        echo "${conf_file}"
    fi
}

config_update()
{
    local source_conf="$1"; shift
    local target_conf="$1"; shift
    params_read "${source_conf}"
    params_parse "$@"
    params_write "${target_conf}"
}

config_list()
{
    local conf_file="$1"
    local conf
    for conf in $(ls "${CONFIG_DIR}/")
    do
        (
            unset DISTRIB ARCH SUITE INCLUDE
            . "${CONFIG_DIR}/${conf}"
            formated_desc=$(printf "%-15s %-10s %-10s %-10s %.30s\n" "${conf%.conf}" "${DISTRIB}" "${ARCH}" "${SUITE}" "${INCLUDE}")
            msg "${formated_desc}"
        )
    done
}

config_remove()
{
    local conf_file="$1"
    if [ -e "${conf_file}" ]; then
        rm -f "${conf_file}"
    else
        return 1
    fi
}

################################################################################
# Components
################################################################################

component_is_compatible()
{
    local target="$@"
    [ -n "${target}" ] || return 0
    local item
    for item in ${target}
    do
        case "${DISTRIB}:${ARCH}:${SUITE}" in
        ${item})
            return 0
        ;;
        esac
    done
    return 1
}

component_is_exclude()
{
    local component="$1"
    [ -n "${component}" ] || return 1
    for item in ${EXCLUDE_COMPONENTS}
    do
        case "${component}" in
        ${item}*)
            return 0
        ;;
        esac
    done
    return 1
}

component_depends()
{
    local components="$@"
    [ -n "${components}" ] || return 0
    local component conf_file TARGET DEPENDS
    for component in ${components}
    do
        component="${component%/}"
        # check deadlocks
        [ -z "${IGNORE_DEPENDS##* ${component} *}" ] && continue
        IGNORE_DEPENDS="${IGNORE_DEPENDS}${component} "
        # check component exist
        conf_file="${INCLUDE_DIR}/${component}/deploy.conf"
        [ -e "${conf_file}" ] || continue
        # read component variables
        eval $(grep -e '^TARGET=' -e '^DEPENDS=' "${conf_file}")
        # check compatibility
        if [ "${WITHOUT_CHECK}" != "true" ]; then
            component_is_compatible ${TARGET} || continue
        fi
        if [ "${REVERSE_DEPENDS}" = "true" ]; then
            # output
            echo ${component}
            # process depends
            component_depends ${DEPENDS}
        else
            # process depends
            component_depends ${DEPENDS}
            # output
            echo ${component}
        fi
    done
}

component_exec()
{
    local components="$@"
    if [ "${WITHOUT_DEPENDS}" != "true" ]; then
        components=$(IGNORE_DEPENDS=" " component_depends ${components})
    fi
    [ -n "${components}" ] || return 1
    (set -e
        for COMPONENT in ${components}
        do
            COMPONENT_DIR="${INCLUDE_DIR}/${COMPONENT}"
            [ -d "${COMPONENT_DIR}" ] || continue
            unset NAME DESC TARGET PARAMS DEPENDS EXTENDS
            TARGET='*:*:*'
            # read config
            . "${COMPONENT_DIR}/deploy.conf"
            # default functions
            do_install() { return 0; }
            do_configure() { return 0; }
            do_start() { return 0; }
            do_stop() { return 0; }
            do_status() { return 0; }
            do_help() { return 0; }
            # load extends
            for component in ${EXTENDS} ${COMPONENT}
            do
                if [ -e "${INCLUDE_DIR}/${component}/deploy.sh" ]; then
                    . "${INCLUDE_DIR}/${component}/deploy.sh"
                fi
            done
            # exclude components
            component_is_exclude ${COMPONENT} && continue
            # check parameters
            [ "${WITHOUT_CHECK}" != "true" ] && params_check ${PARAMS}
            # exec action
            [ "${DEBUG_MODE}" = "true" ] && msg "## ${COMPONENT} : ${DO_ACTION}"
            set +e
            eval ${DO_ACTION} || exit 1
            set -e
        done
    exit 0)
    is_ok || return 1
}

component_list()
{
    local components="$@"
    local component output DESC
    if [ -z "${components}" ]; then
        components=$(cd "${INCLUDE_DIR}" && find . -type f -name "deploy.conf" | while read f
            do
                component="${f%/*}"
                component="${component#*/}"
                echo "${component}"
            done)
    fi
    components=$(IGNORE_DEPENDS=" " component_depends ${components} | sort)
    for component in $components
    do
        # output
        DESC=''
        eval $(grep '^DESC=' "${INCLUDE_DIR}/${component}/deploy.conf")
        output=$(printf "%-30s %.49s\n" "${component}" "${DESC}")
        msg "${output}"
    done
}

component_dir() {
    echo "${INCLUDE_DIR}/$1"
}

################################################################################
# Containers
################################################################################

container_mounted()
{
    if [ "${METHOD}" = "chroot" ]; then
        is_mounted "${CHROOT_DIR}"
    else
        return 0
    fi
}

mount_part()
{
    case "$1" in
    root)
        msg -n "/ ... "
        if ! is_mounted "${CHROOT_DIR}" ; then
            [ -d "${CHROOT_DIR}" ] || mkdir -p "${CHROOT_DIR}"
            local mnt_opts
            [ -d "${TARGET_PATH}" ] && mnt_opts="bind" || mnt_opts="rw,relatime"
            mount -o ${mnt_opts} "${TARGET_PATH}" "${CHROOT_DIR}" &&
            mount -o remount,exec,suid,dev "${CHROOT_DIR}"
            is_ok "失败" "完成" || return 1
        else
            msg "跳过"
        fi
    ;;
    proc)
        msg -n "/proc ... "
        local target="${CHROOT_DIR}/proc"
        if ! is_mounted "${target}" ; then
            [ -d "${target}" ] || mkdir -p "${target}"
            mount -t proc proc "${target}"
            is_ok "失败" "完成"
        else
            msg "跳过"
        fi
    ;;
    sys)
        msg -n "/sys ... "
        local target="${CHROOT_DIR}/sys"
        if ! is_mounted "${target}" ; then
            [ -d "${target}" ] || mkdir -p "${target}"
            mount -t sysfs sys "${target}"
            is_ok "失败" "完成"
        else
            msg "跳过"
        fi
    ;;
    selinux)
        selinux_support || return 0
        msg -n "/sys/fs/selinux ... "
        local target="${CHROOT_DIR}/sys/fs/selinux"
        if ! is_mounted "${target}" ; then
            if [ -e "/sys/fs/selinux/enforce" ]; then
                cat /sys/fs/selinux/enforce > "${TEMP_DIR}/selinux_state"
                echo 0 > /sys/fs/selinux/enforce
            fi
            mount -t selinuxfs selinuxfs "${target}" &&
            mount -o remount,ro,bind "${target}"
            is_ok "失败" "完成"
        else
            msg "跳过"
        fi
    ;;
    dev)
        msg -n "/dev ... "
        local target="${CHROOT_DIR}/dev"
        if ! is_mounted "${target}" ; then
            [ -d "${target}" ] || mkdir -p "${target}"
            [ -e "/dev/fd" ] || ln -s /proc/self/fd /dev/
            [ -e "/dev/stdin" ] || ln -s /proc/self/fd/0 /dev/stdin
            [ -e "/dev/stdout" ] || ln -s /proc/self/fd/1 /dev/stdout
            [ -e "/dev/stderr" ] || ln -s /proc/self/fd/2 /dev/stderr
            mount -o bind /dev "${target}"
            is_ok "失败" "完成"
        else
            msg "跳过"
        fi
    ;;
    tty)
        [ ! -e "/dev/tty0" ] || return 0
        msg -n "/dev/tty ... "
        ln -s /dev/null /dev/tty0
        is_ok "失败" "完成"
    ;;
    pts)
        msg -n "/dev/pts ... "
        local target="${CHROOT_DIR}/dev/pts"
        if ! is_mounted "${target}" ; then
            [ -d "${target}" ] || mkdir -p "${target}"
            mount -o "mode=0620,gid=5" -t devpts devpts "${target}"
            is_ok "失败" "完成"
        else
            msg "跳过"
        fi
    ;;
    shm)
        msg -n "/dev/shm ... "
        local target="/dev/shm"
        if [ -L "${target}" ]; then
            target=$(readlink "${target}")
        fi
        target="${CHROOT_DIR}/${target}"
        if ! is_mounted "${target}" ; then
            [ -d "${target}" ] || mkdir -p "${target}"
            mount -t tmpfs tmpfs "${target}"
            is_ok "失败" "完成"
        else
            msg "跳过"
        fi
    ;;
    tun)
        [ ! -e "/dev/net/tun" ] || return 0
        msg -n "/dev/net/tun ... "
        [ -d "/dev/net" ] || mkdir -p /dev/net
        mknod /dev/net/tun c 10 200
        is_ok "失败" "完成"
    ;;
    binfmt_misc)
        multiarch_support || return 0
        local binfmt_dir="/proc/sys/fs/binfmt_misc"
        msg -n "${binfmt_dir} ... "
        if [ ! -e "${binfmt_dir}/register" ]; then
            mount -t binfmt_misc binfmt_misc "${binfmt_dir}"
            is_ok "失败" "完成"
        else
            msg "跳过"
        fi
    ;;
    esac

    return 0
}

container_mount()
{
    [ "${METHOD}" = "chroot" ] || return 0

    if [ $# -eq 0 ]; then
        container_mount root proc sys selinux dev tty pts shm tun binfmt_misc
        return $?
    fi

    params_check TARGET_PATH || return 1

    msg "安装分区: "
    local item
    for item in $*
    do
        mount_part ${item} || return 1
    done

    return 0
}

container_umount()
{
    params_check TARGET_PATH || return 1
    container_mounted || { msg "容器没有安装." ; return 0; }

    msg -n "释放资源 ... "
    local is_release=0
    local lsof_full=$(lsof | awk '{print $1}' | grep -c '^lsof')
    if [ "${lsof_full}" -eq 0 ]; then
        local pids=$(lsof | grep "${CHROOT_DIR%/}" | awk '{print $1}' | uniq)
    else
        local pids=$(lsof | grep "${CHROOT_DIR%/}" | awk '{print $2}' | uniq)
    fi
    kill_pids ${pids}; is_ok "失败" "完成"

    msg "卸载分区: "
    local is_mnt=0
    local mask
    for mask in '.*' '*'
    do
        local parts=$(cat /proc/mounts | awk '{print $2}' | grep "^${CHROOT_DIR%/}/${mask}$" | sort -r)
        local part
        for part in ${parts}
        do
            local part_name=$(echo ${part} | sed "s|^${CHROOT_DIR%/}/*|/|g")
            msg -n "${part_name} ... "
            if [ -z "${part_name##*selinux*}" -a -e "/sys/fs/selinux/enforce" -a -e "${TEMP_DIR}/selinux_state" ]; then
                cat "${TEMP_DIR}/selinux_state" > /sys/fs/selinux/enforce
            fi
            umount ${part}
            is_ok "失败" "完成"
            is_mnt=1
        done
    done
    [ "${is_mnt}" -eq 1 ]; is_ok " ...没有安装"

    msg -n "分离 loop 设备 ... "
    local loop=$(losetup -a | grep "${TARGET_PATH%/}" | awk -F: '{print $1}')
    if [ -n "${loop}" ]; then
        losetup -d "${loop}"
    fi
    is_ok "失败" "完成"

    return 0
}

container_start()
{
    container_mounted || { msg "容器没有安装." ; return 1; }

    DO_ACTION='do_start'
    if [ $# -gt 0 ]; then
        component_exec "$@"
    else
        component_exec "${INCLUDE}"
    fi
}

container_stop()
{
    container_mounted || { msg "容器没有安装." ; return 1; }

    DO_ACTION='do_stop'
    if [ $# -gt 0 ]; then
        component_exec "$@"
    else
        component_exec "${INCLUDE}"
    fi
}

container_shell()
{
    container_mounted || container_mount || return 1

    DO_ACTION='do_start'
    component_exec core

    USER="root"
    SHELL="$(user_shell $USER)"
    HOME="$(user_home $USER)"
    [ -n "${TERM}" ] || TERM="linux"
    [ -n "${PS1}" ] || PS1="\u@\h:\w\\$ "
    export USER SHELL HOME TERM PS1

    if [ -e "${CHROOT_DIR}/etc/motd" ]; then
        msg $(cat "${CHROOT_DIR}/etc/motd")
    fi

    chroot_exec "$@" 2>&1

    return $?
}

rootfs_import()
{
    local rootfs_file="$1"
    [ -n "${rootfs_file}" ] || return 1

    container_mounted || container_mount root || return 1

    case "${rootfs_file}" in
    *gz)
        msg -n "从tar.gz存档导入rootfs ... "
        if [ -e "${rootfs_file}" ]; then
            tar xzvf "${rootfs_file}" -C "${CHROOT_DIR}" 1>&2
        elif [ -z "${rootfs_file##http*}" ]; then
            wget -q -O - "${rootfs_file}" | tar xzv -C "${CHROOT_DIR}" 1>&2
        else
            msg "失败"; return 1
        fi
        is_ok "失败" "完成" || return 1
    ;;
    *bz2)
        msg -n "从tar.bz2归档导入rootfs ... "
        if [ -e "${rootfs_file}" ]; then
            tar xjvf "${rootfs_file}" -C "${CHROOT_DIR}" 1>&2
        elif [ -z "${rootfs_file##http*}" ]; then
            wget -q -O - "${rootfs_file}" | tar xjv -C "${CHROOT_DIR}" 1>&2
        else
            msg "失败"; return 1
        fi
        is_ok "失败" "完成" || return 1
    ;;
    *xz)
        msg -n "从tar.xz归档导入rootfs ... "
        if [ -e "${rootfs_file}" ]; then
            tar xJvf "${rootfs_file}" -C "${CHROOT_DIR}" 1>&2
        elif [ -z "${rootfs_file##http*}" ]; then
            wget -q -O - "${rootfs_file}" | tar xJv -C "${CHROOT_DIR}" 1>&2
        else
            msg "失败"; return 1
        fi
        is_ok "失败" "完成" || return 1
    ;;
    *)
        msg "文件名不正确，仅支持gz，bz2或xz存档."
        return 1
    ;;
    esac
    return 0
}

rootfs_export()
{
    local rootfs_file="$1"
    [ -n "${rootfs_file}" ] || return 1

    container_mounted || container_mount root || return 1

    case "${rootfs_file}" in
    *gz)
        msg -n "将rootfs导出为tar.gz存档 ... "
        tar czvf "${rootfs_file}" --exclude='./dev' --exclude='./sys' --exclude='./proc' -C "${CHROOT_DIR}" . 1>&2
        is_ok "失败" "完成" || return 1
    ;;
    *bz2)
        msg -n "将rootfs导出为tar.bz2归档 ... "
        tar cjvf "${rootfs_file}" --exclude='./dev' --exclude='./sys' --exclude='./proc' -C "${CHROOT_DIR}" . 1>&2
        is_ok "失败" "完成" || return 1
    ;;
    *xz)
        msg -n "将rootfs导出为tar.xz存档 ... "
        tar cJvf "${rootfs_file}" --exclude='./dev' --exclude='./sys' --exclude='./proc' -C "${CHROOT_DIR}" . 1>&2
        is_ok "失败" "完成" || return 1
    ;;
    *)
        msg "文件名不正确，仅支持gz，bz2或xz存档."
        return 1
    ;;
    esac
}

container_status()
{
    local model=$(getprop ro.product.model)
    if [ -n "${model}" ]; then
        msg -n "设备: "
        msg "${model}"
    fi

    local android=$(getprop ro.build.version.release)
    if [ -n "${android}" ]; then
        msg -n "安卓: "
        msg "${android}"
    fi

    msg -n "构架: "
    msg "$(uname -m)"

    msg -n "内核: "
    msg "$(uname -r)"

    msg -n "运存: "
    local mem_total=$(grep ^MemTotal /proc/meminfo | awk '{print $2}')
    let mem_total=${mem_total}/1024
    local mem_free=$(grep ^MemFree /proc/meminfo | awk '{print $2}')
    let mem_free=${mem_free}/1024
    msg "${mem_free}/${mem_total} MB"

    msg -n "Swap: "
    local swap_total=$(grep ^SwapTotal /proc/meminfo | awk '{print $2}')
    let swap_total=${swap_total}/1024
    local swap_free=$(grep ^SwapFree /proc/meminfo | awk '{print $2}')
    let swap_free=${swap_free}/1024
    msg "${swap_free}/${swap_total} MB"

    msg -n "SELinux: "
    selinux_support && msg "yes" || msg "no"

    msg -n "Loop 设备: "
    loop_support && msg "yes" || msg "no"

    msg -n "支持 binfmt_misc: "
    multiarch_support && msg "yes" || msg "no"

    msg -n "支持的文件系统: "
    local supported_fs=$(printf '%s ' $(grep -v nodev /proc/filesystems | sort))
    msg "${supported_fs}"

    [ -n "${CHROOT_DIR}" ] || return 0

    msg -n "安装的系统: "
    local linux_version=$([ -r "${CHROOT_DIR}/etc/os-release" ] && . "${CHROOT_DIR}/etc/os-release"; [ -n "${PRETTY_NAME}" ] && echo "${PRETTY_NAME}" || echo "未知")
    msg "${linux_version}"

    msg "组件状态: "
    local DO_ACTION='do_status'
    component_exec "${INCLUDE}"

    msg "挂载的部件: "
    local is_mnt=0
    local item
    for item in $(grep "${CHROOT_DIR%/}" /proc/mounts | awk '{print $2}' | sed "s|${CHROOT_DIR%/}/*|/|g")
    do
        msg "* ${item}"
        local is_mnt=1
    done
    [ "${is_mnt}" -ne 1 ] && msg " ...没有挂载"

    msg "可用挂载点: "
    local is_mountpoints=0
    local mp
    for mp in $(grep -v "${CHROOT_DIR%/}" /proc/mounts | grep ^/ | awk '{print $2":"$3}')
    do
        local part=$(echo ${mp} | awk -F: '{print $1}')
        local fstype=$(echo ${mp} | awk -F: '{print $2}')
        local block_size=$(stat -c '%s' -f ${part})
        local available=$(stat -c '%a' -f ${part} | awk '{printf("%.1f",$1*'${block_size}'/1024/1024/1024)}')
        local total=$(stat -c '%b' -f ${part} | awk '{printf("%.1f",$1*'${block_size}'/1024/1024/1024)}')
        if [ -n "${available}" -a -n "${total}" ]; then
            msg "* ${part}  ${available}/${total} GB (${fstype})"
            is_mountpoints=1
        fi
    done
    [ "${is_mountpoints}" -ne 1 ] && msg " ...没有挂载点"

    msg "可用分区: "
    local is_partitions=0
    local dev
    for dev in /sys/block/*/dev
    do
        if [ -f ${dev} ]; then
            local devname=$(echo ${dev} | sed -e 's@/dev@@' -e 's@.*/@@')
            [ -e "/dev/${devname}" ] && local devpath="/dev/${devname}"
            [ -e "/dev/block/${devname}" ] && local devpath="/dev/block/${devname}"
            [ -n "${devpath}" ] && local parts=$(fdisk -l ${devpath} | grep ^/dev/ | awk '{print $1}')
            local part
            for part in ${parts}
            do
                local size=$(fdisk -l ${part} | grep 'Disk.*bytes' | awk '{ sub(/,/,""); print $3" "$4}')
                local type=$(fdisk -l ${devpath} | grep ^${part} | tr -d '*' | awk '{str=$6; for (i=7;i<=10;i++) if ($i!="") str=str" "$i; printf("%s",str)}')
                msg "* ${part}  ${size} (${type})"
                local is_partitions=1
            done
        fi
    done
    [ "${is_partitions}" -ne 1 ] && msg " ...没有可用的分区"
}

helper()
{
cat <<EOF


Linux 布署 ${VERSION}
(c) 2012-2016 Anton Skshidlevsky, GPLv3

用法:
   ${0##*/} [OPTIONS] COMMAND ...

OPTIONS:
   -p NAME - 配置文件
   -d - 启用调试模式
   -t - 启用跟踪模式

COMMANDS:
   config [...] [PARAMETERS] [NAME ...] - 配置管理
      - 无参数显示配置列表
      -r - 删除当前配置
      -i FILE - 导入配置
      -x - 转储当前配置
      -l - 指定或连接组件的依赖关系列表
      -a - 所有组件的列表没有检查兼容性
   deploy [...] [-n NAME] [NAME ...] - 安装分发和包含组件
      -m - 在部署之前安装容器
      -i - 安装不配置
      -c - 配置不安装
      -n NAME - 跳过安装这个组件
   import FILE|URL - 从存档(tgz,tbz2或txz)中导入一个rootfs到当前容器
   export FILE - 将当前容器导出为rootfs存档（tgz,tbz2或txz）
   shell [-u USER] [COMMAND] - 在容器中执行指定的命令，默认为/bin/bash
      -u USER - 切换到指定的用户
   mount - 挂载容器
   umount - 卸载容器
   start [-m] [NAME ...] - 启动所有包含或指定的组件
      -m - 开始前挂载容器
   stop [-u] [NAME ...] - 停止所有包含或指定的组件
      -u - 停止后卸载容器
   sync URL - 与服务器的操作环境同步
   status [NAME ...] - 显示容器和组件的状态
   help [NAME ...] - 显示帮助信息和组件帮助

EOF
echo ${ENV_DIR}
}

do_info()
{
cat <<EOF
Name: ${COMPONENT}
Description: ${DESC}
Target: ${TARGET}
Depends: ${DEPENDS}
Help:

EOF
}

################################################################################

# init env
umask 0022
unset LANG
if [ -z "${ENV_DIR}" ]; then
    ENV_DIR=$(readlink "$0")
    ENV_DIR="${ENV_DIR%/*}"
    if [ -z "${ENV_DIR}" ]; then
        ENV_DIR=`pwd`
    fi
fi
if [ -e "${ENV_DIR}/cli.conf" ]; then
    . "${ENV_DIR}/cli.conf"
fi
if [ -z "${CONFIG_DIR}" ]; then
    CONFIG_DIR="${ENV_DIR}/config"
fi
if [ -z "${INCLUDE_DIR}" ]; then
    INCLUDE_DIR="${ENV_DIR}/include"
fi
if [ -z "${TEMP_DIR}" ]; then
    TEMP_DIR="${ENV_DIR}/tmp"
fi
if [ -z "${CHROOT_DIR}" ]; then
    CHROOT_DIR="${ENV_DIR}/mnt"
fi

# parse options
OPTIND=1
while getopts :p:dt FLAG
do
    case "${FLAG}" in
    p)
        PROFILE="${OPTARG}"
    ;;
    d)
        DEBUG_MODE="true"
    ;;
    t)
        TRACE_MODE="true"
    ;;
    *)
        if [ ${OPTIND} -gt 1 ]; then
            let OPTIND=OPTIND-1
        fi
        break
    ;;
    esac
done
shift $((OPTIND-1))

# log level
exec 3>&1
if [ "${DEBUG_MODE}" != "true" -a "${TRACE_MODE}" != "true" ]; then
    exec 2>/dev/null
fi
if [ "${TRACE_MODE}" = "true" ]; then
    set -x
fi

# which config
CONF_FILE=$(config_which "${PROFILE}")
PROFILE=$(basename "${CONF_FILE}" ".conf")

# read config
OPTLST=" " # space is required
params_read "${CONF_FILE}"

# fix params
WITHOUT_CHECK="false"
WITHOUT_DEPENDS="false"
REVERSE_DEPENDS="false"
EXCLUDE_COMPONENTS=""
case "${METHOD}" in
proot)
    CHROOT_DIR="${TARGET_PATH}"
;;
*)
    METHOD="chroot"
;;
esac

# make dirs
[ -d "${CONFIG_DIR}" ] || mkdir "${CONFIG_DIR}"
[ -d "${INCLUDE_DIR}" ] || mkdir "${INCLUDE_DIR}"
[ -d "${TEMP_DIR}" ] || mkdir "${TEMP_DIR}"
[ -d "${CHROOT_DIR}" ] || mkdir "${CHROOT_DIR}"

# exec command
OPTCMD="$1"; shift
case "${OPTCMD}" in
config|conf)
    if [ $# -eq 0 ]; then
        config_list "${CONF_FILE}"
        exit $?
    fi
    conf_file="${CONF_FILE}"

    # parse options
    OPTIND=1
    while getopts :i:rxla FLAG
    do
        case "${FLAG}" in
        r)
            config_remove "${CONF_FILE}"
            exit $?
        ;;
        x)
            dump_flag="true"
        ;;
        i)
            conf_file=$(config_which "${OPTARG}")
        ;;
        l)
            list_flag="true"
        ;;
        a)
            WITHOUT_CHECK="true"
        ;;
        *)
            if [ ${OPTIND} -gt 1 ]; then
                let OPTIND=OPTIND-1
            fi
            break
        ;;
        esac
    done
    shift $((OPTIND-1))

    if [ "${dump_flag}" = "true" ]; then
        [ -e "${CONF_FILE}" ] && cat "${CONF_FILE}"
    elif [ "${list_flag}" = "true" ]; then
        if [ $# -eq 0 ]; then
            if [ "${WITHOUT_CHECK}" = "true" ]; then
                component_list
            else
                component_list "${INCLUDE}"
            fi
        else
            component_list "$@"
        fi
    else
        config_update "${conf_file}" "${CONF_FILE}" "$@"
    fi
;;
deploy)
    DO_ACTION='do_install && do_configure'

    # parse options
    OPTIND=1
    while getopts :n:mic FLAG
    do
        case "${FLAG}" in
        m)
            mount_flag="true"
        ;;
        i)
            DO_ACTION='do_install'
        ;;
        c)
            DO_ACTION='do_configure'
        ;;
        n)
            EXCLUDE_COMPONENTS="${EXCLUDE_COMPONENTS} ${OPTARG}"
        ;;
        *)
            if [ ${OPTIND} -gt 1 ]; then
                let OPTIND=OPTIND-1
            fi
            break
        ;;
        esac
    done
    shift $((OPTIND-1))

    if [ "${mount_flag}" = "true" ]; then
        container_mount || exit 1
    fi

    if [ $# -gt 0 ]; then
        component_exec "$@"
    else
        component_exec "${INCLUDE}"
    fi
;;
import)
    rootfs_import "$@"
;;
export)
    rootfs_export "$@"
;;
shell)
    container_shell "$@"
;;
mount)
    container_mount
;;
umount)
    container_umount
;;
start)
    # parse options
    OPTIND=1
    while getopts :m FLAG
    do
        case "${FLAG}" in
        m)
            mount_flag="true"
        ;;
        *)
            if [ ${OPTIND} -gt 1 ]; then
                let OPTIND=OPTIND-1
            fi
            break
        ;;
        esac
    done
    shift $((OPTIND-1))

    if [ "${mount_flag}" = "true" ]; then
        container_mount || exit 1
    fi

    container_start "$@"
;;
stop)
    # parse options
    OPTIND=1
    while getopts :u FLAG
    do
        case "${FLAG}" in
        u)
            umount_flag="true"
        ;;
        *)
            if [ ${OPTIND} -gt 1 ]; then
                let OPTIND=OPTIND-1
            fi
            break
        ;;
        esac
    done
    shift $((OPTIND-1))

    container_stop "$@" || exit 1

    if [ "${umount_flag}" = "true" ]; then
        container_umount
    fi
;;
sync)
    sync_env "$@"
;;
status)
    if [ $# -gt 0 ]; then
        DO_ACTION='do_status'
        component_exec "$@"
    else
        container_status
    fi
;;
help)
    if [ $# -eq 0 ]; then
        helper
        if [ -n "${INCLUDE}" ]; then
            msg "参数: "
            WITHOUT_CHECK="true"
            REVERSE_DEPENDS="true"
            DO_ACTION='do_help'
            component_exec "${INCLUDE}" ||
            msg -e '   包含的组件没有参数.\n'
        fi
    else
        WITHOUT_CHECK="true"
        WITHOUT_DEPENDS="true"
        DO_ACTION='do_info && do_help'
        component_exec "$@"
    fi
;;

*)
    helper
;;
esac
