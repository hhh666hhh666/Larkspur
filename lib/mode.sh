#!/usr/bin/env bash
# 用法：mode.sh
# 输出当前的消息接收方式：router（有活动的总控，各会话的飞书消息由总控转发）或 none（没有总控，各会话收不到飞书消息；不允许各会话自己监听）。
. "${LARKSPUR_HOME:-$HOME/.claude/larkspur}/common.sh"
if router_active; then echo router; else echo none; fi
