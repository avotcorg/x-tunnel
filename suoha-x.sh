#!/usr/bin/env bash
set -euo pipefail
umask 077

CONFIG_FILE="${HOME}/.suoha_tunnel_config"
WG_PROFILE_DIR="${HOME}/.suoha_wg_profiles"
GUARD_LOG_FILE="${HOME}/.suoha_guard.log"

cf_protocol="quic"
cf_ha_connections="2"
cf_profile="2"
cf_profile_prompted="0"
net_tuned="0"
landing_mode="0"
forward_url=""
wg_socks_port=""
guard_enabled="0"
guard_interval="15"
token_prompted="0"

linux_os=("Debian" "Ubuntu" "CentOS" "Fedora" "Alpine")
linux_update=("apt update" "apt update" "yum -y update" "yum -y update" "apk update")
linux_install=("apt -y install" "apt -y install" "yum -y install" "yum -y install" "apk add -f")

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"
REMOTE_LIB_BASE="https://raw.githubusercontent.com/FearW/x-tunnel/refs/heads/main/lib"

# lib 校验模式：strict / permissive
LIB_VERIFY_MODE="${LIB_VERIFY_MODE:-permissive}"

LIB_FILES=(
  "common.sh"
  "net.sh"
  "config.sh"
  "wg.sh"
  "services.sh"
  "guard.sh"
  "cloudflare.sh"
)

if [[ ! -d "${LIB_DIR}" ]]; then
  mkdir -p "${LIB_DIR}"
fi

# lib 文件 sha256 校验表（建议补全后配合 strict 模式）
declare -A LIB_CHECKSUMS=(
  # 示例：
  # ["common.sh"]="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  # ["net.sh"]="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  # ["config.sh"]="cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
  # ["wg.sh"]="dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
  # ["services.sh"]="eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
  # ["guard.sh"]="ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
  # ["cloudflare.sh"]="9999999999999999999999999999999999999999999999999999999999999999"
)

# 早期检查（因为下面校验函数会用到）
if ! command -v curl >/dev/null 2>&1; then
  echo "[ERROR] 缺少命令 curl，请先安装后重试。"
  exit 1
fi
if ! command -v sha256sum >/dev/null 2>&1; then
  echo "[ERROR] 缺少命令 sha256sum，请先安装后重试。"
  exit 1
fi

download_lib_file() {
  local lib_file="$1"
  local dst="${LIB_DIR}/${lib_file}"
  local tmp
  tmp="$(mktemp "${LIB_DIR}/.${lib_file}.tmp.XXXXXX")"

  if ! curl -fL --proto '=https' --tlsv1.2 \
    --connect-timeout 8 --max-time 60 \
    --retry 3 --retry-delay 1 --retry-all-errors \
    "${REMOTE_LIB_BASE}/${lib_file}" -o "${tmp}"; then
    rm -f "${tmp}"
    echo "[ERROR] 下载 ${lib_file} 失败"
    return 1
  fi

  # 有校验值则校验下载内容
  if [[ -n "${LIB_CHECKSUMS[${lib_file}]:-}" ]]; then
    local actual_sum
    actual_sum="$(sha256sum "${tmp}" | awk '{print $1}')"
    if [[ "${actual_sum}" != "${LIB_CHECKSUMS[${lib_file}]}" ]]; then
      rm -f "${tmp}"
      echo "[ERROR] ${lib_file} 校验失败（下载内容哈希不匹配）"
      return 1
    fi
  fi

  mv -f "${tmp}" "${dst}"
  chmod 0644 "${dst}"
}

verify_or_repair_lib() {
  local lib_file="$1"
  local path="${LIB_DIR}/${lib_file}"
  local expected="${LIB_CHECKSUMS[${lib_file}]:-}"

  # 文件不存在则下载
  if [[ ! -f "${path}" ]]; then
    download_lib_file "${lib_file}" || return 1
  fi

  # 有校验值 -> 每次启动都校验
  if [[ -n "${expected}" ]]; then
    local actual
    actual="$(sha256sum "${path}" | awk '{print $1}')"
    if [[ "${actual}" != "${expected}" ]]; then
      echo "[WARN] ${lib_file} 本地校验失败，尝试重新下载修复..."
      rm -f "${path}"
      download_lib_file "${lib_file}" || return 1
      actual="$(sha256sum "${path}" | awk '{print $1}')"
      if [[ "${actual}" != "${expected}" ]]; then
        echo "[ERROR] ${lib_file} 修复后仍校验失败，已终止。"
        rm -f "${path}"
        return 1
      fi
    fi
  else
    # 无校验值：strict 模式报错，permissive 模式仅警告
    if [[ "${LIB_VERIFY_MODE}" == "strict" ]]; then
      echo "[ERROR] strict 模式要求提供 ${lib_file} 的 SHA256 校验值"
      return 1
    fi
    echo "[WARN] ${lib_file} 未配置 SHA256（当前 permissive 模式）"
  fi
}

for lib_file in "${LIB_FILES[@]}"; do
  verify_or_repair_lib "${lib_file}" || {
    echo "[ERROR] 依赖库校验/修复失败：${lib_file}"
    exit 1
  }
done

# shellcheck source=/dev/null
source "${LIB_DIR}/common.sh"
# shellcheck source=/dev/null
source "${LIB_DIR}/net.sh"
# shellcheck source=/dev/null
source "${LIB_DIR}/config.sh"
# shellcheck source=/dev/null
source "${LIB_DIR}/wg.sh"
# shellcheck source=/dev/null
source "${LIB_DIR}/services.sh"
# shellcheck source=/dev/null
source "${LIB_DIR}/guard.sh"
# shellcheck source=/dev/null
source "${LIB_DIR}/cloudflare.sh"

idx="$(os_index)"
need_cmd screen "$idx"
need_cmd curl "$idx"
need_cmd sed "$idx"
need_cmd grep "$idx"
need_cmd awk "$idx"
need_cmd sha256sum "$idx"

is_valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 65535 ))
}

is_valid_interval() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 86400 ))
}

# 可选依赖：缺失时仅警告
for optional_cmd in ss openssl nc tar; do
  if ! command -v "$optional_cmd" &>/dev/null; then
    echo "[WARN] 可选命令 ${optional_cmd} 未安装，部分功能可能不可用"
  fi
done

cleanup_screens() {
  screen -wipe >/dev/null 2>&1 || true
}

print_install_plan() {
  say "------------------------------"
  say "安装向导步骤："
  say "  1) 选择 Cloudflared 网络与传输档位"
  say "  2) 选择落地模式（直连/HTTP/SOCKS5/WG）"
  say "  3) 设置 x-tunnel token 与端口策略"
  say "  4) 可选绑定 Named Tunnel 域名"
  say "  5) 可选系统优化与健康守护"
  say "------------------------------"
}

confirm_install_plan() {
  say "安装配置预览："
  say "  - 落地模式: $(landing_mode_text "${landing_mode:-0}")"
  if [[ -n "${forward_url:-}" ]]; then
    say "  - 落地地址: ${forward_url}"
  fi
  say "  - 传输协议: ${cf_protocol:-quic}"
  say "  - 并发连接: ${cf_ha_connections:-2}"
  say "  - 固定端口: ${fixp:-0}"
  read -r -p "确认以上配置并开始安装启动？(1.确认[默认],0.返回菜单):" confirm_start
  confirm_start="${confirm_start:-1}"
  [[ "$confirm_start" == "1" ]]
}

if [[ "${1:-}" == "--guard-loop" ]]; then
  load_config || exit 0
  guard_loop
  exit 0
fi

clear
say "梭哈模式不需要自己提供域名,使用CF ARGO QUICK TUNNEL创建快速链接"
say "梭哈模式在重启或者脚本再次运行后失效,如果需要使用需要再次运行创建"
printf "\n梭哈是一种智慧!!!梭哈!梭哈!梭哈!梭哈!梭哈!梭哈!梭哈...\n\n"
say "1.梭哈模式"
say "2.停止服务"
say "3.卸载(彻底清理)"
say "4.域名绑定查看"
say "5.热切换落地(直连/HTTP/SOCKS5/WG)"
say "6.健康守护开关"
printf "0.退出脚本\n\n"
read -r -p "请选择模式(默认1):" mode
mode="${mode:-1}"

if [[ "$mode" == "1" ]]; then
  print_install_plan
  prev_ips="${ips:-4}"
  prev_cf_profile="${cf_profile:-2}"
  prev_token="${token:-}"

  if load_config; then
    say "检测到历史配置：可直接回车沿用上次参数（包括落地模式）"
    prev_ips="${ips:-4}"
    prev_cf_profile="${cf_profile:-2}"
    prev_token="${token:-}"
  fi

  say "安装向导说明：先选传输档位，再选落地渠道（直连/HTTP/SOCKS5/WG），最后再配置端口和域名。"

  read -r -p "请选择cloudflared连接模式IPV4或者IPV6(输入4或6,默认${prev_ips}):" ips
  ips="${ips:-$prev_ips}"
  if [[ "$ips" != "4" && "$ips" != "6" ]]; then
    say "请输入正确的cloudflared连接模式"
    exit 1
  fi

  say "传输优化档位：1.稳定优先(HTTP2) 2.速度优先(QUIC+2并发) 3.高吞吐优先(QUIC+4并发)"
  read -r -p "请选择传输优化档位(默认${prev_cf_profile}):" cf_profile
  cf_profile="${cf_profile:-$prev_cf_profile}"
  case "$cf_profile" in
    1) cf_protocol="http2"; cf_ha_connections="1" ;;
    2) cf_protocol="quic"; cf_ha_connections="2" ;;
    3) cf_protocol="quic"; cf_ha_connections="4" ;;
    *)
      say "未识别的档位，已使用默认速度优先(2)"
      cf_profile="2"; cf_protocol="quic"; cf_ha_connections="2"
      ;;
  esac

  configure_landing

  read -r -p "请设置x-tunnel的token(可留空，默认沿用上次):" token
  token="${token:-$prev_token}"

  read -r -p "是否固定ws端口(0.不固定[默认],1.固定):" fixp
  fixp="${fixp:-0}"
  if [[ "$fixp" == "1" ]]; then
    read -r -p "请输入固定ws端口(默认 12345):" wsport
    wsport="${wsport:-12345}"
    if ! is_valid_port "${wsport}"; then
      say "端口不合法，请输入 1-65535"
      exit 1
    fi
  else
    wsport=""
  fi

  read -r -p "是否启用绑定自定义域名(Named Tunnel)(0.不启用[默认],1.启用):" bind_enable
  bind_enable="${bind_enable:-0}"
  cf_tunnel_token=""
  bind_domain=""
  if [[ "$bind_enable" == "1" ]]; then
    say "提示：绑定域名需要你在 Cloudflare Zero Trust 创建 Named Tunnel 并配置 Public Hostname"
    read -r -p "请输入 Cloudflare Tunnel Token(必填):" cf_tunnel_token
    if [[ -z "${cf_tunnel_token:-}" ]]; then
      say "未提供 Tunnel Token，已取消绑定域名功能"
      bind_enable=0
    else
      read -r -p "请输入绑定域名(可留空，仅用于展示和自检):" bind_domain
      bind_domain="${bind_domain:-}"

      if [[ "$fixp" == "0" ]]; then
        say "警告：使用绑定域名时强烈建议固定 ws 端口，否则端口变动会导致 Cloudflare 面板配置失效"
        read -r -p "是否现在固定端口？(1.是[推荐], 0.否): " force_fix
        force_fix="${force_fix:-1}"
        if [[ "$force_fix" == "1" ]]; then
          fixp=1
          read -r -p "请输入固定 ws 端口(默认 12345):" wsport
          wsport="${wsport:-12345}"
          if ! is_valid_port "${wsport}"; then
            say "端口不合法，请输入 1-65535"
            exit 1
          fi
        fi
      fi
    fi
  fi

  read -r -p "是否应用系统网络优化(BBR+FQ)(1.是[默认],0.否):" tune_net
  tune_net="${tune_net:-1}"
  if [[ "$tune_net" == "1" ]]; then
    apply_system_net_tuning
    net_tuned="1"
  else
    net_tuned="0"
  fi

  read -r -p "是否启用健康守护(1.是[默认],0.否):" guard_enabled
  guard_enabled="${guard_enabled:-1}"
  if [[ "$guard_enabled" == "1" ]]; then
    read -r -p "请输入守护巡检间隔秒数(默认15):" guard_interval
    guard_interval="${guard_interval:-15}"
    if ! is_valid_interval "${guard_interval}"; then
      say "守护间隔不合法，请输入 1-86400"
      exit 1
    fi
  fi

  if ! confirm_install_plan; then
    say "已取消本次安装启动，返回菜单"
    exit 0
  fi

  cleanup_screens
  stop_screen x-tunnel
  stop_screen argo
  stop_screen cfbind
  stop_screen wg

  # 先备份配置，失败可回滚；避免直接 remove_config 导致历史丢失
  config_backup=""
  if [[ -f "${CONFIG_FILE}" ]]; then
    config_backup="$(mktemp "${CONFIG_FILE}.bak.XXXXXX")"
    cp -a "${CONFIG_FILE}" "${config_backup}"
  fi

  remove_config
  clear
  sleep 1

  if quicktunnel; then
    [[ -n "${config_backup}" ]] && rm -f "${config_backup}" || true
  else
    say "[ERROR] 启动失败，尝试回滚历史配置..."
    if [[ -n "${config_backup}" && ! -f "${CONFIG_FILE}" ]]; then
      mv -f "${config_backup}" "${CONFIG_FILE}" || true
    fi
    exit 1
  fi

elif [[ "$mode" == "2" ]]; then
  cleanup_screens
  stop_screen x-tunnel
  stop_screen argo
  stop_screen cfbind
  stop_screen wg
  stop_guard
  clear
  say "已停止服务（配置已保留，下次启动可沿用）"

elif [[ "$mode" == "3" ]]; then
  cleanup_screens
  stop_screen x-tunnel
  stop_screen argo
  stop_screen cfbind
  stop_screen wg
  stop_guard
  rm -f "${SCRIPT_DIR}/cloudflared-linux" "${SCRIPT_DIR}/x-tunnel-linux" "${SCRIPT_DIR}/wireproxy-linux" "${SCRIPT_DIR}/wireproxy.conf"
  rm -f "${HOME}/.suoha_wireproxy.log"
  rm -rf "${WG_PROFILE_DIR}"
  rm -rf "${LIB_DIR}"
  remove_config
  rm -f "${GUARD_LOG_FILE}"
  clear
  say "已卸载并彻底清理：服务、二进制、lib库、WG配置、日志与配置记录"

elif [[ "$mode" == "4" ]]; then
  view_domains

elif [[ "$mode" == "5" ]]; then
  hot_switch_landing

elif [[ "$mode" == "6" ]]; then
  if load_config; then
    if screen_exists guard; then
      stop_guard
      save_config
      say "已关闭健康守护"
    else
      read -r -p "请输入守护巡检间隔秒数(默认15):" guard_interval
      guard_interval="${guard_interval:-15}"
      if ! is_valid_interval "${guard_interval}"; then
        say "守护间隔不合法，请输入 1-86400"
        exit 1
      fi
      start_guard
      save_config
    fi
  else
    say "未找到运行配置，请先启动(选项1)"
  fi

else
  say "退出成功"
  exit 0
fi
