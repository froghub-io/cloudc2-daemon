#!/bin/sh
set -e
set -o noglob

# Usage:
#   curl ... | ENV_VAR=... sh -
#       or
#   ENV_VAR=... ./install.sh
#
# Example:
#   Installing an agent to point at a daemon:
#     curl ... | CLOUDC2_DAEMON_APPID=xxx sh -
#
# Environment variables:
#   - CLOUDC2_DAEMON_*
#     Environment variables which begin with CLOUDC2_DAEMON_ will be preserved for the
#     systemd service to use.
#
#   - CLOUDC2_DAEMON_APPID
#     Must be set to identify cloudc2-daemon.
#
#   - CLOUDC2_DAEMON_ADVERTISE_ADDRESS
#     Host address and port monitored by gateway.
#     Defaults to https://cloudc2.froghub.cn.
#
#   - CLOUDC2_DAEMON_IPFS_GATEWAY
#     Proxy gateway for downloading filecoin proof parameter data.
#     Defaults to 'https://proof-parameters.s3.cn-south-1.jdcloud-oss.com/ipfs/",
#
#   - CLOUDC2_DAEMON_FIL_PROOFS_PARAMETER_CACHE
#     Directory to store filecoin proofs parameter data, or use
#     /var/local as the default
#
#   - CLOUDC2_DAEMON_INSTALL_SYMLINK
#     If set to 'skip' will not create symlinks, 'force' will overwrite,
#     default will symlink if command does not exist in path.
#
#   - CLOUDC2_DAEMON_INSTALL_VERSION
#     Version of cloudc2-daemon to download from github. Will attempt to download from the
#     stable channel if not specified.
#
#   - CLOUDC2_DAEMON_INSTALL_COMMIT
#     Commit of cloudc2-daemon to download from temporary cloud storage.
#     * (for developer & QA use)
#
#   - CLOUDC2_DAEMON_INSTALL_BIN_DIR
#     Directory to install cloudc2-daemon binary, links, and uninstall script to, or use
#     /usr/local/bin as the default
#
#   - CLOUDC2_DAEMON_INSTALL_SYSTEMD_DIR
#     Directory to install systemd service and environment files to, or use
#     /etc/systemd/system as the default
#
#   - CLOUDC2_DAEMON_INSTALL_NAME
#     Name of systemd service to create, will default from the cloudc2-daemon exec command
#     if not specified. If specified the name will be prefixed with 'cloudc2-daemon-'.
#
#   - CLOUDC2_DAEMON_INSTALL_CHANNEL_URL
#     Channel URL for fetching cloudc2-daemon download URL.
#     Defaults to 'https://update.froghub.cn/v1-release/channels'.
#
#   - CLOUDC2_DAEMON_INSTALL_CHANNEL
#     Channel to use for fetching cloudc2-daemon download URL.
#     Defaults to 'stable'.
#
#   - CLOUDC2_DAEMON_WORKER_PAR
#     The number of parallel operations performed by the worker. The default is automatic

STORAGE_URL=https://cloudc2-daemon.oss-cn-beijing.aliyuncs.com
DOWNLOADER=

# --- helper functions for logs ---
info()
{
    echo '[INFO] ' "$@"
}
warn()
{
    echo '[WARN] ' "$@" >&2
}
fatal()
{
    echo '[ERROR] ' "$@" >&2
    exit 1
}

# --- fatal if no systemd or openrc ---
verify_system() {
    if [ -d /run/systemd ]; then
        HAS_SYSTEMD=true
        return
    fi
    fatal 'Can not find systemd or openrc to use as a process supervisor for cloudc2-daemon'
}

# --- add quotes to command arguments ---
quote() {
    for arg in "$@"; do
        printf '%s\n' "$arg" | sed "s/'/'\\\\''/g;1s/^/'/;\$s/\$/'/"
    done
}

# --- add indentation and trailing slash to quoted args ---
quote_indent() {
    printf ' \\\n'
    for arg in "$@"; do
        printf '\t%s \\\n' "$(quote "$arg")"
    done
}

# --- escape most punctuation characters, except quotes, forward slash, and space ---
escape() {
    printf '%s' "$@" | sed -e 's/\([][!#$%&()*;<=>?\_`{|}]\)/\\\1/g;'
}

# --- escape double quotes ---
escape_dq() {
    printf '%s' "$@" | sed -e 's/"/\\"/g'
}

# --- define needed environment variables ---
setup_env() {

info "${CLOUDC2_DAEMON_INSTALL_NAME}"
    # --- use systemd name if defined or create default ---
    if [ -n "${CLOUDC2_DAEMON_INSTALL_NAME}" ]; then
        SYSTEM_NAME=cloudc2-daemon-${CLOUDC2_DAEMON_INSTALL_NAME}
    else
        SYSTEM_NAME=cloudc2-daemon
    fi

    # --- check for invalid characters in system name ---
    valid_chars=$(printf '%s' "${SYSTEM_NAME}" | sed -e 's/[][!#$%&()*;<=>?\_`{|}/[:space:]]/^/g;' )
    if [ "${SYSTEM_NAME}" != "${valid_chars}"  ]; then
        invalid_chars=$(printf '%s' "${valid_chars}" | sed -e 's/[^^]/ /g')
        fatal "Invalid characters for system name:
            ${SYSTEM_NAME}
            ${invalid_chars}"
    fi

    # --- use sudo if we are not already root ---
    SUDO=sudo
    if [ $(id -u) -eq 0 ]; then
        SUDO=
    fi

    # --- use binary install directory if defined or create default ---
    if [ -n "${CLOUDC2_DAEMON_INSTALL_CRON_DIR}" ]; then
        CRON_DIR=${CLOUDC2_DAEMON_INSTALL_CRON_DIR}
    else
        CRON_DIR=/etc/cron.d
    fi

    # --- use binary install directory if defined or create default ---
    if [ -n "${CLOUDC2_DAEMON_INSTALL_BIN_DIR}" ]; then
        BIN_DIR=${CLOUDC2_DAEMON_INSTALL_BIN_DIR}
    else
        # --- use /usr/local/bin if root can write to it, otherwise use /opt/bin if it exists
        BIN_DIR=/usr/local/bin
        if ! $SUDO sh -c "touch ${BIN_DIR}/cloudc2-daemon-ro-test && rm -rf ${BIN_DIR}/cloudc2-daemon-ro-test"; then
            if [ -d /opt/bin ]; then
                BIN_DIR=/opt/bin
            fi
        fi
    fi

    # --- use systemd directory if defined or create default ---
    if [ -n "${CLOUDC2_DAEMON_INSTALL_SYSTEMD_DIR}" ]; then
        SYSTEMD_DIR="${CLOUDC2_DAEMON_INSTALL_SYSTEMD_DIR}"
    else
        SYSTEMD_DIR=/etc/systemd/system
    fi

    # --- set related files from system name ---
    SERVICE_CLOUDC2_DAEMON=${SYSTEM_NAME}.service
    UNINSTALL_SH=${UNINSTALL_SH:-${BIN_DIR}/${SYSTEM_NAME}-uninstall.sh}
    KILLALL_SH=${KILLALL_SH:-${BIN_DIR}/cloudc2-daemon-killall.sh}

    FILE_SERVICE=${SYSTEMD_DIR}/${SERVICE_CLOUDC2_DAEMON}
    FILE_ENV=${SYSTEMD_DIR}/${SERVICE_CLOUDC2_DAEMON}.env
    FILE_START=${BIN_DIR}/${SYSTEM_NAME}-start.sh
    FILE_CRON=${CRON_DIR}/${SYSTEM_NAME}

    # --- get hash of config & exec for currently installed cloudc2-daemon ---
    PRE_INSTALL_HASHES=$(get_installed_hashes)

    # --- setup channel values
    CLOUDC2_DAEMON_INSTALL_CHANNEL_URL=${CLOUDC2_DAEMON_INSTALL_CHANNEL_URL:-'https://update.froghub.cn/v1-release/channels'}
    CLOUDC2_DAEMON_INSTALL_CHANNEL=${CLOUDC2_DAEMON_INSTALL_CHANNEL:-'stable'}
}

# --- set arch and suffix, fatal if architecture not supported ---
setup_verify_arch() {
    if [ -z "$ARCH" ]; then
        ARCH=$(cat /proc/cpuinfo | grep name | cut -f2 -d: | head -n 1 | awk '{print $1}' | cut -f 1 -d '(')
    fi
    case $ARCH in
        AMD)
            ARCH=amd64
            SUFFIX=-${ARCH}
            ;;
        Intel)
            ARCH=intel64
            SUFFIX=-${ARCH}
            ;;
        *)
            fatal "Unsupported architecture $ARCH"
    esac
}

# --- verify existence of network downloader executable ---
verify_downloader() {
    # Return failure if it doesn't exist or is no executable
    [ -x "$(command -v $1)" ] || return 1

    # Set verified executable as our downloader program and return success
    DOWNLOADER=$1
    return 0
}

# --- create temporary directory and cleanup when done ---
setup_tmp() {
    TMP_DIR=$(mktemp -d -t cloudc2-daemon-install.XXXXXXXXXX)
    TMP_HASH=${TMP_DIR}/cloudc2-daemon.hash
    TMP_BIN=${TMP_DIR}/cloudc2-daemon.bin
    cleanup() {
        code=$?
        set +e
        trap - EXIT
        rm -rf ${TMP_DIR}
        exit $code
    }
    trap cleanup INT EXIT
}

# --- use desired cloudc2-daemon version if defined or find version from channel ---
get_release_version() {
     if [ -n "${CLOUDC2_DAEMON_INSTALL_COMMIT}" ]; then
         VERSION_CLOUDC2_DAEMON="commit ${CLOUDC2_DAEMON_INSTALL_COMMIT}"
     elif [ -n "${CLOUDC2_DAEMON_INSTALL_VERSION}" ]; then
         VERSION_CLOUDC2_DAEMON=${CLOUDC2_DAEMON_INSTALL_VERSION}
     else
         info "Finding release for channel ${CLOUDC2_DAEMON_INSTALL_CHANNEL}"
         version_url="${CLOUDC2_DAEMON_INSTALL_CHANNEL_URL}/${CLOUDC2_DAEMON_INSTALL_CHANNEL}"
         case $DOWNLOADER in
             curl)
                 VERSION_CLOUDC2_DAEMON=$(curl -w '%{url_effective}' -L -s -S ${version_url} -o /dev/null | sed -e 's|.*/||')
                 ;;
             wget)
                 VERSION_CLOUDC2_DAEMON=$(wget -SqO /dev/null ${version_url} 2>&1 | grep -i Location | sed -e 's|.*/||')
                 ;;
             *)
                 fatal "Incorrect downloader executable '$DOWNLOADER'"
                 ;;
         esac
     fi
    info "Using ${VERSION_CLOUDC2_DAEMON} as release"
}

# --- download from github url ---
download() {
    [ $# -eq 2 ] || fatal 'download needs exactly 2 arguments'

    case $DOWNLOADER in
        curl)
            curl -o $1 -sfL $2
            ;;
        wget)
            wget -qO $1 $2
            ;;
        *)
            fatal "Incorrect executable '$DOWNLOADER'"
            ;;
    esac

    # Abort if download command failed
    [ $? -eq 0 ] || fatal 'Download failed'
}

# --- download hash from github url ---
download_hash() {
    info "${CLOUDC2_DAEMON_INSTALL_COMMIT}"
    if [ -n "${CLOUDC2_DAEMON_INSTALL_COMMIT}" ]; then
        HASH_URL=${STORAGE_URL}/${CLOUDC2_DAEMON_INSTALL_COMMIT}/sha256sum-${ARCH}.txt
    else
        HASH_URL=${STORAGE_URL}/${VERSION_CLOUDC2_DAEMON}/sha256sum-${ARCH}.txt
    fi
    info "Downloading hash ${HASH_URL}"
    download ${TMP_HASH} ${HASH_URL}
    HASH_EXPECTED=$(grep " cloudc2-daemon${SUFFIX}" ${TMP_HASH})
    HASH_EXPECTED=${HASH_EXPECTED%%[[:blank:]]*}

}

# --- check hash against installed version ---
installed_hash_matches() {
    if [ -x ${BIN_DIR}/cloudc2-daemon ]; then
        HASH_INSTALLED=$(sha256sum ${BIN_DIR}/cloudc2-daemon)
        HASH_INSTALLED=${HASH_INSTALLED%%[[:blank:]]*}
        if [ "${HASH_EXPECTED}" = "${HASH_INSTALLED}" ]; then
            return
        fi
    fi
    return 1
}

# --- download binary from github url ---
download_binary() {
    if [ -n "${CLOUDC2_DAEMON_INSTALL_COMMIT}" ]; then
        BIN_URL=${STORAGE_URL}/${CLOUDC2_DAEMON_INSTALL_COMMIT}/cloudc2-daemon${SUFFIX}
    else
        BIN_URL=${STORAGE_URL}/${VERSION_CLOUDC2_DAEMON}/cloudc2-daemon${SUFFIX}
    fi
    info "Downloading binary ${BIN_URL}"
    download ${TMP_BIN} ${BIN_URL}
}

# --- verify downloaded binary hash ---
verify_binary() {
    info "Verifying binary download"
    HASH_BIN=$(sha256sum ${TMP_BIN})
    HASH_BIN=${HASH_BIN%%[[:blank:]]*}
    if [ "${HASH_EXPECTED}" != "${HASH_BIN}" ]; then
        fatal "Download sha256 does not match ${HASH_EXPECTED}, got ${HASH_BIN}"
    fi
}

# --- setup permissions and move binary to system directory ---
setup_binary() {
    chmod 755 ${TMP_BIN}
    info "Installing cloudc2-daemon to ${BIN_DIR}/cloudc2-daemon"
    $SUDO chown root:root ${TMP_BIN}
    $SUDO mv -f ${TMP_BIN} ${BIN_DIR}/cloudc2-daemon
}

# --- download and verify cloudc2-daemon ---
download_and_verify() {
    setup_verify_arch
    verify_downloader curl || verify_downloader wget || fatal 'Can not find curl or wget for downloading files'
    setup_tmp
    get_release_version
    download_hash

    if installed_hash_matches; then
        info 'Skipping binary downloaded, installed cloudc2-daemon matches hash'
        return
    fi

    download_binary
    verify_binary
    setup_binary
}

# --- add additional utility links ---
create_symlinks() {
    [ "${CLOUDC2_DAEMON_INSTALL_SYMLINK}" = skip ] && return

    for cmd in cloudc2-daemon; do
        if [ ! -e ${BIN_DIR}/${cmd} ] || [ "${CLOUDC2_DAEMON_INSTALL_SYMLINK}" = force ]; then
            which_cmd=$(command -v ${cmd} 2>/dev/null || true)
            if [ -z "${which_cmd}" ] || [ "${CLOUDC2_DAEMON_INSTALL_SYMLINK}" = force ]; then
                info "Creating ${BIN_DIR}/${cmd} symlink to cloudc2-daemon"
                $SUDO ln -sf cloudc2-daemon ${BIN_DIR}/${cmd}
            else
                info "Skipping ${BIN_DIR}/${cmd} symlink to cloudc2-daemon, command exists in PATH at ${which_cmd}"
            fi
        else
            info "Skipping ${BIN_DIR}/${cmd} symlink to cloudc2-daemon, already exists"
        fi
    done
}

# --- create killall script ---
create_killall() {
    info "Creating killall script ${KILLALL_SH}"
    $SUDO tee ${KILLALL_SH} >/dev/null << \EOF
#!/bin/sh
[ $(id -u) -eq 0 ] || exec sudo $0 $@

set -x

for service in /etc/systemd/system/cloudc2-daemon*.service; do
    [ -s $service ] && systemctl stop $(basename $service)
done

for service in /etc/init.d/cloudc2-daemon*; do
    [ -x $service ] && $service stop
done

pschildren() {
    ps -e -o ppid= -o pid= | \
    sed -e 's/^\s*//g; s/\s\s*/\t/g;' | \
    grep -w "^$1" | \
    cut -f2
}

pstree() {
    for pid in $@; do
        echo $pid
        for child in $(pschildren $pid); do
            pstree $child
        done
    done
}

killtree() {
    kill -9 $(
        { set +x; } 2>/dev/null;
        pstree $@;
        set -x;
    ) 2>/dev/null
}


killtree $({ set +x; } 2>/dev/null; set -x)

EOF
    $SUDO chmod 755 ${KILLALL_SH}
    $SUDO chown root:root ${KILLALL_SH}
}

# --- create uninstall script ---
create_uninstall() {
    info "Creating uninstall script ${UNINSTALL_SH}"
    $SUDO tee ${UNINSTALL_SH} >/dev/null << EOF
#!/bin/sh
set -x
[ \$(id -u) -eq 0 ] || exec sudo \$0 \$@

${KILLALL_SH}

if command -v systemctl; then
    systemctl disable ${SYSTEM_NAME}
    systemctl reset-failed ${SYSTEM_NAME}
    systemctl daemon-reload
fi
if command -v rc-update; then
    rc-update delete ${SYSTEM_NAME} default
fi

rm -f ${FILE_SERVICE}
rm -f ${FILE_ENV}
rm -f ${FILE_START}
rm -f ${FILE_CRON}

remove_uninstall() {
    rm -f ${UNINSTALL_SH}
}
trap remove_uninstall EXIT

if (ls ${SYSTEMD_DIR}/cloudc2-daemon*.service || ls /etc/init.d/cloudc2-daemon*) >/dev/null 2>&1; then
    set +x; echo 'Additional cloudc2-daemon services installed, skipping uninstall of cloudc2-daemon'; set -x
    exit
fi

for cmd in cloudc2-daemon; do
    if [ -L ${BIN_DIR}/\$cmd ]; then
        rm -f ${BIN_DIR}/\$cmd
    fi
done

rm -rf /etc/froghub/cloudc2-daemon
rm -f ${BIN_DIR}/cloudc2-daemon
rm -f ${KILLALL_SH}

EOF
    $SUDO chmod 755 ${UNINSTALL_SH}
    $SUDO chown root:root ${UNINSTALL_SH}
}

# --- disable current service if loaded --
systemd_disable() {
    $SUDO systemctl disable ${SYSTEM_NAME} >/dev/null 2>&1 || true
    $SUDO rm -f /etc/systemd/system/${SERVICE_CLOUDC2_DAEMON} || true
    $SUDO rm -f /etc/systemd/system/${SERVICE_CLOUDC2_DAEMON}.env || true
}

# --- capture current env and create file containing cloudc2-daemon variables ---
create_env_file() {
    info "env: Creating environment file ${FILE_ENV}"
    info "${FILE_ENV}"
    $SUDO touch ${FILE_ENV}
    $SUDO chmod 0600 ${FILE_ENV}
    env | grep 'CLOUDC2_DAEMON_' | $SUDO tee ${FILE_ENV} >/dev/null
    env | grep -Ei '^(NO|HTTP|HTTPS)_PROXY' | $SUDO tee -a ${FILE_ENV} >/dev/null
}

# --- capture current start and create file containing cloudc2-daemon variables ---
create_start_file() {
    info "sh: Creating sh file ${FILE_START}"
    $SUDO touch ${FILE_START}
    $SUDO chmod 0755 ${FILE_START}
    curl -sfL https://get.froghub.cn/start.sh | $SUDO tee ${FILE_START} >/dev/null
}

# --- capture current cron and create file containing cloudc2-daemon variables ---
create_cron_file() {
    info "cron: Creating cron file ${FILE_CRON}"
    info "${FILE_CRON}"
    $SUDO tee ${FILE_CRON} >/dev/null << EOF
*/1 * * * * root bash ${FILE_START}

EOF
    $SUDO chmod 600 ${FILE_CRON}
    $SUDO chown root:root ${FILE_CRON}
}

# --- capture current cron and remove file containing cloudc2-daemon variables ---
remove_cron_file() {
  info "cron: Removeing cron file ${FILE_CRON}"
  $SUDO rm -f ${FILE_CRON}
}

# --- write systemd service file ---
create_systemd_service_file() {
    info "systemd: Creating service file ${FILE_SERVICE}"
    $SUDO tee ${FILE_SERVICE} >/dev/null << EOF
[Unit]
Description=CLOUDC2_DAEMON
Documentation=https://www.froghub.io
Wants=network-online.target
After=network-online.target

[Install]
WantedBy=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes

EOF
}

# --- write systemd or openrc service file ---
create_service_file() {
    create_systemd_service_file
    return 0
}

# --- get hashes of the current cloudc2-daemon bin and service files
get_installed_hashes() {
    $SUDO sha256sum ${BIN_DIR}/cloudc2-daemon ${FILE_SERVICE} ${FILE_ENV} 2>&1 || true
}

# --- enable and start systemd service ---
systemd_enable() {
    info "systemd: Enabling ${SYSTEM_NAME} unit"
    $SUDO systemctl enable cron >/dev/null
    $SUDO systemctl daemon-reload >/dev/null
}

systemd_start() {
    info "systemd: Starting ${SYSTEM_NAME}"
    pid=$(ps x | grep "${SYSTEM_NAME} daemon" | grep -v grep | awk '{print $1}')
    if [ -n "$pid" ]; then
      kill -9 $pid
    fi
    create_cron_file
    $SUDO systemctl restart cron
}

systemd_stop() {
    info "systemd: Stoping ${SYSTEM_NAME}"
    pid=$(ps x | grep "${SYSTEM_NAME} daemon" | grep -v grep | awk '{print $1}')
    if [ -n "$pid" ]; then
      kill -9 $pid
    fi
    pid=$(ps x | grep "${SYSTEM_NAME} worker" | grep -v grep | awk '{print $1}')
    if [ -n "$pid" ]; then
      kill -9 $pid
    fi
    remove_cron_file
    $SUDO systemctl restart cron
}

# --- startup systemd or openrc service ---
service_enable_and_start() {

    systemd_enable
    systemd_start

    return 0
}

# --- startup systemd or openrc service ---
service_start() {

    systemd_start

    return 0
}

# --- stoptup systemd or openrc service ---
service_stop() {

    systemd_stop

    return 0
}

# --- run the install process --
{
    case "$1" in
        stop)
            setup_env "$@"
            service_stop
        ;;
        restart)
            setup_env "$@"
            service_start
        ;;
        update)
            setup_env "$@"
            download_and_verify
        ;;
        (*)
            verify_system
            setup_env "$@"
            download_and_verify
            create_symlinks
            create_killall
            create_uninstall
            systemd_disable
            create_env_file
            create_start_file
            create_service_file
            service_enable_and_start
        ;;
    esac
}
