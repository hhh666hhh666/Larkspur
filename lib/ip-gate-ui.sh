#!/usr/bin/env bash
# 「IP 闸门」设置程序（桌面图标打开的就是它，安装为 ~/.local/bin/larkspur-ip-gate）。
# 先现查三个出口 IP 并显示，然后用勾选框切换两个开关，写入 config.sh，立即生效：
#   启动闸门（LARKSPUR_DESKTOP_GATE）：桌面端启动前检查出口 IP，不符就不启动（desktop-gate.sh）
#   运行中守卫（LARKSPUR_IP_GUARD）：运行中检测到出口 IP 不符时运行守卫命令（ipguard.sh）
# 还可以修改期望 IP（LARKSPUR_EXPECTED_IP）。打开或改成会立刻触发守卫的设置时，先弹确认。
set -u
H="${LARKSPUR_HOME:-$HOME/.claude/larkspur}"
CONFIG="$H/config.sh"
Z="${LARKSPUR_ZENITY:-zenity}"
TITLE="IP 闸门"
command -v "$Z" >/dev/null || { echo "需要 zenity" >&2; exit 1; }
[ -f "$CONFIG" ] || { "$Z" --error --title="$TITLE" --text="找不到 $CONFIG，请先安装 Larkspur。"; exit 1; }

cfg() { ( . "$CONFIG" >/dev/null 2>&1; eval "printf '%s' \"\${$1:-$2}\"" ); }
set_config() {   # 与 console.sh 相同：改写 config.sh 里的一项，没有就追加
  local k="$1" esc
  esc=$(printf '%s' "$2" | sed 's/[\\"$`]/\\&/g')
  if grep -q "^$k=" "$CONFIG"; then
    LINE="$k=\"$esc\"" KEY="$k" awk 'index($0, ENVIRON["KEY"] "=") == 1 { print ENVIRON["LINE"]; next } { print }' \
      "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
  else
    printf '%s="%s"\n' "$k" "$esc" >> "$CONFIG"
  fi
  chmod 600 "$CONFIG"
}
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$H/larkspur.log"; }

probe() {   # 现查三个出口，进度条转圈；结果放进 IPS（JSON）和 RC（exit-ips.sh 的退出码）
  local t; t=$(mktemp -d)
  ( "$H/exit-ips.sh" "$(cfg LARKSPUR_EXPECTED_IP '')" > "$t/out"; echo $? > "$t/rc" ) \
    | "$Z" --progress --pulsate --auto-close --no-cancel --title="$TITLE" --text="正在检测出口 IP……" 2>/dev/null
  IPS=$(cat "$t/out" 2>/dev/null); RC=$(cat "$t/rc" 2>/dev/null); rm -rf "$t"
  [ -n "$IPS" ] || IPS='{"cn":"","cf":"","claude":""}'
}
show() { [ -n "$1" ] && printf '%s' "$1" || printf '查不到'; }

while :; do
  exp=$(cfg LARKSPUR_EXPECTED_IP ''); gate=$(cfg LARKSPUR_DESKTOP_GATE on); guard=$(cfg LARKSPUR_IP_GUARD on)
  probe
  cn=$(printf '%s' "$IPS" | jq -r '.cn'); cf=$(printf '%s' "$IPS" | jq -r '.cf'); cl=$(printf '%s' "$IPS" | jq -r '.claude')
  case "$RC" in 0) verdict="三个都相符 ✅" ;; 1) verdict="有不符 ❌" ;; *) verdict="有查不到的，无法确定 ⚠️" ;; esac
  [ -n "$exp" ] || verdict="没有设置期望 IP，闸门和守卫都不起作用"
  note=""; grep -q 'Claude 桌面端的启动闸门' "$HOME/.local/bin/claude-desktop" 2>/dev/null \
    || note=$'\n\n注意：启动闸门程序没有安装（设置期望 IP 后重新运行 Larkspur 的 install.sh）。'
  text="期望 IP：$(show "$exp")
当前出口：国内 $(show "$cn")　·　Cloudflare $(show "$cf")　·　Claude $(show "$cl")
结果：$verdict$note

勾选要启用的功能，点「保存」立即生效："
  sel=$("$Z" --list --checklist --title="$TITLE" --width=680 --height=360 --text="$text" \
        --column="启用" --column="键" --column="功能" --hide-column=2 --print-column=2 --separator=" " \
        --ok-label="保存" --cancel-label="取消" --extra-button="修改期望 IP" --extra-button="重新检测" \
        "$( [ "$gate" = off ] && echo FALSE || echo TRUE )" gate "启动闸门：桌面端启动前检查三个出口 IP，不符就不启动、不联网" \
        "$( [ "$guard" = off ] && echo FALSE || echo TRUE )" guard "运行中守卫：检测到出口 IP 不符时结束所有相关进程" \
        2>/dev/null); rc=$?

  case "$sel" in
    "重新检测") continue ;;
    "修改期望 IP")
      new=$("$Z" --entry --title="$TITLE" --text="期望的出口 IP（三个出口都应是它）：" --entry-text="${exp:-$cl}" 2>/dev/null) || continue
      new=$(printf '%s' "$new" | tr -d '[:space:]')
      if ! printf '%s' "$new" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
        "$Z" --error --title="$TITLE" --text="「$new」不是有效的 IPv4 地址，没有保存。" 2>/dev/null; continue
      fi
      if [ "$guard" != off ] && { [ -n "$cl$cf$cn" ] && { [ "$cl" != "$new" ] || [ "$cf" != "$new" ] || [ "$cn" != "$new" ]; }; }; then
        "$Z" --question --title="$TITLE" --width=460 --text="当前出口和 $new 不一致，运行中守卫是开着的：保存后一分钟内就会结束所有相关进程。确定保存？" \
          --ok-label="确定保存" --cancel-label="取消" 2>/dev/null || continue
      fi
      set_config LARKSPUR_EXPECTED_IP "$new"; log "ip-gate-ui expected=$new"; continue ;;
  esac
  [ "$rc" = 0 ] || exit 0   # 取消或关窗口

  ngate=off; nguard=off
  for k in $sel; do case "$k" in gate) ngate=on ;; guard) nguard=on ;; esac; done
  if [ "$nguard" = on ] && [ "$guard" = off ] && [ "$RC" = 1 ]; then
    "$Z" --question --title="$TITLE" --width=460 --text="现在的出口 IP 不符，打开运行中守卫后一分钟内就会结束所有相关进程。确定打开？" \
      --ok-label="确定打开" --cancel-label="取消" 2>/dev/null || continue
  fi
  set_config LARKSPUR_DESKTOP_GATE "$ngate"; set_config LARKSPUR_IP_GUARD "$nguard"
  log "ip-gate-ui gate=$ngate guard=$nguard"
  [ -x "$H/console.sh" ] && ( "$H/console.sh" refresh >/dev/null 2>&1 & )   # 飞书控制台跟着更新
  w() { [ "$1" = on ] && echo "开" || echo "关"; }
  "$Z" --info --title="$TITLE" --width=360 --text="已保存，立即生效。

启动闸门：$(w "$ngate")
运行中守卫：$(w "$nguard")" 2>/dev/null
  exit 0
done
