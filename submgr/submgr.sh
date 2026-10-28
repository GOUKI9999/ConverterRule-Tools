#!/bin/bash
###############################################################################
# submgr.sh —— 机场订阅统一拉取 / 转换 / 校验 / 通知 引擎（硬化版）
#
# 用法:
#   submgr.sh                  处理所有启用机场（下载→预检→转换→判定→发布→推送）
#   submgr.sh Nerwo CuteCloud  只处理指定机场
#   submgr.sh --check          校验 config.json 语法 + 字段断言，打印摘要，不执行
#   submgr.sh --status         只读体检：每个机场 原始订阅/转换结果/基线 的大小格式与异常标记
#   submgr.sh --report-only    只读：按现有转换结果重算并对比基线、可推送，不下载不转换
#   submgr.sh --dry-run        下载到 /tmp 沙盒校验并报告，绝不触碰 /www，不转换不发布
#   submgr.sh --no-send        完整流程并落盘，但不推送 TG（报告存盘待发）
#   submgr.sh --no-pull        不下载原始订阅，仅用现有原始订阅重新转换→发布→推送（改了 ini/转换规则时用）
#   submgr.sh --pull-only      只刷新 /www 原始订阅，不转换不发布（拉取与抓转解耦，可分别执行）
#   submgr.sh --send-report    只把上次存下的报告推送出去（凌晨更新/中午推送场景）
#
# 安全保证（事故后硬化）:
#   - 原子写：原始订阅/转换结果都先写 .dl 临时文件，校验通过才 mv 替换线上
#   - 双闸门：① 转换前预检原始订阅(格式/大小/污染/新鲜度) ② 转换后校验结果(proxies+rules+节点≥1)
#   - 字段断言：raw_url/convert_url 必须 ^https?://，否则跳过该机场并告警
#   - 发布原则：合法即替换——结果合法且与对外订阅(latest)有任何字节差异即发布，旧版转存为对外订阅备份(previous)；
#               格式错误或低于最低节点/规则/组数量时保留旧版；节点跌幅 ≥ node_drop_pct% 仍发布但告警
#   - 坏数据永远无法替换好数据；--dry-run 对 /www 零写入
###############################################################################
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
set -u

# ---------- 路径与常量 ----------
SELFDIR="$(cd "$(dirname "$0")" && pwd)"
CONF="${SUBMGR_CONF:-$SELFDIR/config.json}"
STATEDIR="${SUBMGR_STATE:-$SELFDIR/state}"          # 可被环境变量覆盖，便于隔离测试
LOG="$SELFDIR/run.log"
REPORTFILE="$SELFDIR/last_report.txt"
SENTMARK="$SELFDIR/last_report.sent"
WORKDIR="${SUBMGR_WORKDIR:-/www}"                   # 对外订阅目录；默认 /www(web根)，测试时指向沙盒
LOCKDIR="/tmp/submgr.lock"
DRYDIR="/tmp/submgr_dry"

# ---------- 参数解析 ----------
MODE="full"          # full | check | status | report | dry | send
SEND="yes"
SKIP_PULL="no"       # --no-pull：跳过下载原始订阅，仅用现有原始订阅重新转换并发布（改了 ini/转换规则时用）
PICK=()
for a in "$@"; do
  case "$a" in
    --check)        MODE="check" ;;
    --status)       MODE="status" ;;
    --report-only)  MODE="report" ;;
    --dry-run)      MODE="dry"; SEND="no" ;;
    --no-send)      SEND="no" ;;
    --no-pull)      SKIP_PULL="yes" ;;
    --pull-only)    MODE="pull" ;;
    --send-report)  MODE="send" ;;
    -h|--help)      sed -n '2,20p' "$0"; exit 0 ;;
    -*)             echo "未知参数: $a（用 --help 看用法）"; exit 2 ;;
    *)              PICK+=("$a") ;;
  esac
done
[ "$MODE" = "full" ] && PERSIST="yes" || PERSIST="no"

# ---------- 基础函数 ----------
ts(){ date "+%m/%d/%y %H:%M:%S"; }
log(){ echo "$(ts) $*" >> "$LOG"; }
note(){ echo "$*"; log "$*"; }
human(){ awk -v b="${1:-0}" 'BEGIN{ if(b<1024)printf "%dB",b; else if(b<1048576)printf "%.1fK",b/1024; else printf "%.1fM",b/1048576 }'; }
mtime(){ stat -c %Y "$1" 2>/dev/null || date -r "$1" +%s 2>/dev/null || echo 0; }
now(){ date +%s; }

# ---------- 配置存在 + 语法校验 ----------
if ! command -v jq >/dev/null 2>&1; then echo "缺少 jq，无法解析配置"; exit 3; fi
if [ ! -f "$CONF" ]; then echo "找不到配置文件: $CONF"; exit 3; fi
if ! jq -e . "$CONF" >/dev/null 2>&1; then
  msg="❌ submgr: config.json 语法错误，本次未执行。请用 submgr.sh --check 检查。"
  echo "$msg"; log "$msg"
  T=$(jq -r '.telegram.token // empty' "$CONF" 2>/dev/null)
  C=$(jq -r '.telegram.chat_id // empty' "$CONF" 2>/dev/null)
  [ -n "$T" ] && [ -n "$C" ] && curl -ksS -m 15 -X POST \
     "https://api.telegram.org/bot$T/sendMessage" \
     --data-urlencode "chat_id=$C" --data-urlencode "text=$msg" >/dev/null 2>&1
  exit 3
fi

# ---------- 读取全局配置 ----------
jget(){ jq -r "$1" "$CONF"; }
TG_ENABLE=$(jget '.telegram.enable')
TG_TOKEN=$(jget '.telegram.token')
TG_CHAT=$(jget '.telegram.chat_id')
DL_RETRIES=$(jget '.options.dl_retries // 3')
DL_SLEEP=$(jget '.options.dl_sleep // 10')
DL_TIMEOUT=$(jget '.options.dl_timeout // 60')
RAW_MIN_BYTES=$(jget '.options.raw_min_bytes // 200')
RAW_MAX_RULES=$(jget '.options.raw_max_rules // 200')
CUR_RAW_MAX_RULES="$RAW_MAX_RULES" # 当前机场原始规则上限；默认继承全局，可由机场 raw_max_rules 单独覆盖
RAW_MAX_AGE_MIN=$(jget '.options.raw_max_age_min // 180')
NODE_DROP_PCT=$(jget '.options.node_drop_pct // 40')
NODE_MIN_KEEP=$(jget '.options.node_min_keep // 1')
# 最低数量只接受整数；缺省值兼容旧配置，具体机场可提高阈值。
if ! jq -e '
  def integer_at_least($n): type == "number" and . >= $n and . == floor;
  all(.options | to_entries[] | select(.key == "node_min_keep" or .key == "min_nodes"); .value == null or (.value | integer_at_least(1))) and
  all(.options | to_entries[] | select(.key == "min_rules" or .key == "min_groups"); .value == null or (.value | integer_at_least(0))) and
  (.options.node_min_keep // 1 | integer_at_least(1)) and
  (.options.min_nodes // .options.node_min_keep // 1 | integer_at_least(1)) and
  (.options.min_rules // 0 | integer_at_least(0)) and
  (.options.min_groups // 0 | integer_at_least(0)) and
  all(.airports[];
    ((.min_nodes == null) or (.min_nodes | integer_at_least(1))) and
    ((.min_rules == null) or (.min_rules | integer_at_least(0))) and
    ((.min_groups == null) or (.min_groups | integer_at_least(0))))
' "$CONF" >/dev/null 2>&1; then
  note "submgr: 最低数量配置无效；min_nodes/node_min_keep 须为正整数，min_rules/min_groups 须为非负整数。"
  exit 3
fi
MIN_NODES=$(jget '.options.min_nodes // .options.node_min_keep // 1')
MIN_RULES=$(jget '.options.min_rules // 0')
MIN_GROUPS=$(jget '.options.min_groups // 0')
CUR_MIN_NODES="$MIN_NODES"; CUR_MIN_RULES="$MIN_RULES"; CUR_MIN_GROUPS="$MIN_GROUPS"
load_limits(){
  CUR_MIN_NODES=$(jq -r ".airports[$1].min_nodes // $MIN_NODES" "$CONF")
  CUR_MIN_RULES=$(jq -r ".airports[$1].min_rules // $MIN_RULES" "$CONF")
  CUR_MIN_GROUPS=$(jq -r ".airports[$1].min_groups // $MIN_GROUPS" "$CONF")
}
LIST_TRUNCATE=$(jget '.options.list_truncate // 15')
LOG_KEEP=$(jget '.options.log_keep_lines // 3000')
USER_AGENT=$(jget '.options.user_agent // ""')
CUR_UA="$USER_AGENT"   # 当前机场生效UA：默认=全局，主循环里按机场 .user_agent 覆盖（某些机场只对clash系UA放行/返回正确格式）

# ---------- 计数 / 节点名（已在真实数据验证） ----------
# 统计段内顶层条目：兼容转换结果的 2 空格和机场原生 Clash YAML 的 4 空格；
# 不匹配策略组成员常见的 6/8 空格，避免把组内节点误计为策略组数量。
count_block(){ awk -v sec="$1" '$0 ~ "^"sec":"{f=1;next} /^[a-zA-Z_-]+:/{f=0} f&&(/^  - /||/^    - /){c++} END{print c+0}' "$2" 2>/dev/null; }
count_nodes(){  count_block proxies       "$1"; }
count_rules(){  count_block rules         "$1"; }
count_groups(){ count_block "proxy-groups" "$1"; }   # 策略组数（第三个对照维度）
node_names(){
  sed -n '/^proxies:/,/^[a-zA-Z_-]*:/p' "$1" 2>/dev/null | grep '^  - ' | \
    sed -E 's/^  - \{?[[:space:]]*name:[[:space:]]*//; s/^"([^"]*)".*/\1/; s/^([^,}]*).*/\1/'
}
# 某段每个 `  - ` 条目的名字（兼容块式 name: 与流式 {name: ...}）；用于策略组名增删对比
group_names(){
  awk '$0 ~ "^proxy-groups:"{s=1;next} s&&/^[a-zA-Z_-]+:/{s=0} s&&/^  - /{print}' "$1" 2>/dev/null | \
    sed -E 's/^  - \{?[[:space:]]*name:[[:space:]]*//; s/^"([^"]*)".*/\1/; s/^([^,}]*).*/\1/'
}
# 分段切片：把 clash 文件切成 4 段做对比/总结，4 段正好覆盖全文。
#   默认配置(header) = 不属于 proxies/proxy-groups/rules 的所有行（含文件开头通用设置）
#   sec_body <段名> = 该段 body（不含段头行），段名取 proxies | proxy-groups | rules
sec_body(){ awk -v sec="$1" '$0 ~ "^"sec":"{s=1;next} s&&/^[a-zA-Z_-]+:/{s=0} s{print}' "$2" 2>/dev/null; }
header_body(){ awk '/^proxies:|^proxy-groups:|^rules:/{s=1;next} s&&/^[a-zA-Z_-]+:/{s=0} !s{print}' "$1" 2>/dev/null; }
md5(){ md5sum 2>/dev/null | cut -d' ' -f1; }
meta_get(){ awk -F= -v k="$2" '$1==k{print $2; exit}' "$1" 2>/dev/null; }   # 只取首个匹配，防重复键

# ---------- 文件画像 ----------
# 原始订阅格式分类: clash | base64 | uri | html | empty | unknown
raw_kind(){
  local f="$1"
  [ -s "$f" ] || { echo empty; return; }
  # 只认真正的 HTML/HTTP 错误页；不再用 流量/到期/过期 等词（会与合法节点名重叠误判）。
  # 非订阅的纯文本错误(如"订阅已过期")会落到下面三类都不匹配 → unknown → 同样被拒。
  if head -c 300 "$f" | grep -qiE '<!doctype|<html|<head|<body|<title|404 not found|403 forbidden|bad gateway|access denied'; then echo html; return; fi
  grep -qE '^proxies:' "$f" && { echo clash; return; }
  grep -qE '(vless|vmess|trojan|ss|ssr|hysteria2?|tuic)://' "$f" && { echo uri; return; }
  # base64：兼容 URL-safe 字母表(-_ → +/)与换行，解码出 :// 即认定
  head -c 20000 "$f" | tr -d '\r\n' | tr -- '-_' '+/' | base64 -d 2>/dev/null | grep -qE '://' && { echo base64; return; }
  echo unknown
}

# 原始订阅是否合法（下载校验 / 转换前预检 共用）
valid_raw(){
  local f="$1" sz kind rules
  [ -s "$f" ] || return 1
  sz=$(wc -c < "$f"); [ "$sz" -ge "$RAW_MIN_BYTES" ] || return 1
  kind=$(raw_kind "$f")
  case "$kind" in clash|base64|uri) ;; *) return 1 ;; esac
  # 污染防护：原始订阅不应内置上千条规则（那是转换结果的特征）
  rules=$(count_rules "$f"); [ "${rules:-0}" -le "$CUR_RAW_MAX_RULES" ] || return 1
  return 0
}

# 转换结果是否合法
valid_clash(){
  local f="$1"
  [ -s "$f" ] || return 1
  grep -qE '^proxies:' "$f" || return 1
  grep -qE '^rules:' "$f" || return 1
  [ "$(count_nodes "$f")" -ge 1 ] || return 1
  return 0
}

# 数量阈值独立于格式校验；所有不足项都返回，供日志和报告使用。
result_limit_errors(){
  local f=$1 n r g
  n=$(count_nodes "$f"); r=$(count_rules "$f"); g=$(count_groups "$f")
  [ "$n" -ge "$CUR_MIN_NODES" ] || printf '节点仅%s，最低要求%s\n' "$n" "$CUR_MIN_NODES"
  [ "$r" -ge "$CUR_MIN_RULES" ] || printf '规则仅%s，最低要求%s\n' "$r" "$CUR_MIN_RULES"
  [ "$g" -ge "$CUR_MIN_GROUPS" ] || printf '策略组仅%s，最低要求%s\n' "$g" "$CUR_MIN_GROUPS"
  return 0
}

# 转换前预检：subconverter 即将读取线上 $raw（要求#4）
precheck_raw(){ # name rawfile
  local name=$1 f=$2 kind age
  if ! valid_raw "$f"; then
    kind=$(raw_kind "$f")
    log "[$name] 预检失败 kind=$kind bytes=$(wc -c <"$f" 2>/dev/null) rules=$(count_rules "$f")"
    return 1
  fi
  age=$(( ( $(now) - $(mtime "$f") ) / 60 ))
  if [ "$age" -gt "$RAW_MAX_AGE_MIN" ]; then
    log "[$name] 预检提示：原始订阅已 ${age} 分钟未更新（阈值 ${RAW_MAX_AGE_MIN}），仍继续"
  fi
  log "[$name] 预检通过 kind=$(raw_kind "$f") size=$(human $(wc -c <"$f")) age=${age}m"
  return 0
}

# ---------- 网络抓取 ----------
fetch(){ # url out （UA 用按机场生效的 CUR_UA，为空则不带 -A=curl默认UA）
  if [ -n "$CUR_UA" ]; then
    curl -ksS -A "$CUR_UA" --connect-timeout 15 -m "$DL_TIMEOUT" -o "$2" "$1"
  else
    curl -ksS --connect-timeout 15 -m "$DL_TIMEOUT" -o "$2" "$1"
  fi
}

# 原子下载原始订阅：下到 .dl，校验通过才替换线上；失败绝不覆盖线上好文件
download_raw(){ # name raw bak url burl  -> 0成功(已更新) / 1未更新；并置全局 RAW_STATUS=fresh|stale|bak|none
  local name=$1 raw=$2 bak=$3 url=$4 burl=$5 dl="$2.dl" src i
  RAW_STATUS=none
  # backup_url 可为字符串或数组(主循环已用空格连接)；read -ra 拆分，避免通配符展开
  local -a burls=(); read -ra burls <<< "$burl"
  for src in "$url" "${burls[@]}"; do
    [ -z "$src" ] && continue
    i=1
    while [ "$i" -le "$DL_RETRIES" ]; do
      log "[$name] 下载原始订阅 第${i}次 (${src:0:40}...)"
      if fetch "$src" "$dl" && valid_raw "$dl"; then
        mv "$dl" "$raw"; cp "$raw" "$bak"
        log "[$name] 原始订阅有效已更新 kind=$(raw_kind "$raw") size=$(human $(wc -c <"$raw"))"
        RAW_STATUS=fresh; return 0
      fi
      log "[$name] 第${i}次无效 kind=$(raw_kind "$dl" 2>/dev/null)"; rm -f "$dl"
      i=$((i+1)); [ "$i" -le "$DL_RETRIES" ] && sleep "$DL_SLEEP"
    done
  done
  rm -f "$dl"
  # 拉取失败(上游错误：没拉到今天的新订阅)：绝不覆盖线上。沿用现有合法原始订阅，否则回退到原始订阅备份
  if valid_raw "$raw"; then log "[$name] 拉取失败，沿用现有合法原始订阅"; RAW_STATUS=stale; return 1; fi
  if [ -s "$bak" ] && valid_raw "$bak"; then cp "$bak" "$raw"; log "[$name] 拉取失败，回退到原始订阅备份"; RAW_STATUS=bak; return 1; fi
  log "[$name] 拉取失败，且无合法原始订阅、也无原始订阅备份"; RAW_STATUS=none; return 1
}

# 转换到 .dl（不碰线上 latest）：抓取→密码引号修复→结果合法性闸门
convert_to(){ # name conv_url outdl  -> 0/1；失败时置全局 CONV_ERR=错误摘要(供报告)
  local name=$1 cu=$2 out=$3
  CONV_ERR=""
  log "[$name] 调用 subconverter 转换"
  if ! fetch "$cu" "$out"; then
    CONV_ERR="subconverter 请求失败/不可达"
    log "[$name] 转换请求失败"; rm -f "$out"; return 1
  fi
  sed -i -e '/password/s/\(, password: \)\([^,]*\)\(, \)/\1"\2"\3/g' -e 's/\"\"/\"/g' "$out"
  if ! valid_clash "$out"; then
    local rej="/tmp/submgr_${name}.rej"   # 留样放 /tmp：不在 web 根暴露、不堆积、每机场只留最近一份
    # 提取 subconverter 返回内容的摘要：通常 ini 配置出错时它回一段短文本/HTML 错误，截前 200 字、压成一行
    CONV_ERR=$(head -c 400 "$out" 2>/dev/null | tr '\r\n\t' '   ' | sed -E 's/  +/ /g; s/^ +//; s/ +$//' | cut -c1-200)
    [ -z "$CONV_ERR" ] && CONV_ERR="结果不含 proxies/rules 或节点<1（空响应）"
    log "[$name] 转换结果不合法 nodes=$(count_nodes "$out") 摘要=「$CONV_ERR」 留样 $rej"
    mv "$out" "$rej" 2>/dev/null; rm -f "$out"; return 1
  fi
  return 0
}

# 发布：仅当现有对外订阅“合法”时才转存为对外订阅备份(previous)（避免坏结果覆盖好的对外订阅备份），再用新结果原子替换
publish(){ valid_clash "$2" && [ -z "$(result_limit_errors "$2")" ] && cp "$2" "$3"; mv "$1" "$2"; }   # 仅通过当前阈值的旧latest可轮换到previous
# 记录基线（仅供 --status 展示/留痕；变化判定不依赖它，直接对比当前 latest）
save_meta(){ printf 'nodes=%s\nrules=%s\ngroups=%s\nts=%s\n' "$2" "$3" "$4" "$(now)" > "$1"; }

# 单机场首行：机场名左对齐(NAMEPAD宽) + emoji + 状态词(正常/更新/异常)；emoji 在名字后保证名字列整齐(等宽块内发送)
aline(){ REPORT+="$(printf '%-*s %s %s' "${NAMEPAD:-10}" "$1" "$2" "$3")"$'\n'; }   # 名 emoji 状态词
# 详情续行：只缩进 2 空格(尽量留宽度,避免在手机代码块里再次折行)，每条单独一行 ↳，逐段列出
acont(){ REPORT+="  ↳ $1"$'\n'; }

# 内联名字串：把名单文件压成一行 "＋A ＋B …N个"（截断，无前后多余空格）
inline_names(){ # prefix file
  local prefix=$1 total out
  total=$(wc -l < "$2"); [ "${total:-0}" -eq 0 ] && return
  out=$(head -n "$LIST_TRUNCATE" "$2" | sed "s/^/$prefix/" | tr '\n' ' ' | sed 's/ *$//')
  [ "$total" -gt "$LIST_TRUNCATE" ] && out="$out …${total}个"
  printf '%s' "$out"
}

# 默认配置(header)改了几行：返回新增+删除的行数之和
hdr_changed_lines(){ # oldf newf
  diff <(header_body "$1") <(header_body "$2") 2>/dev/null | grep -cE '^[<>]'
}

# 分段变化(节点/代理组共用)：产出单段内联字符串 DNS_SEG（未变则为空）。
# 例: "节点 159→160(+1) ＋🇭🇰香港05" / "代理组 47→47 顺序调整" / ""(无变化)
# 用法: diff_named_section 标签 旧文件 新文件 取名函数 旧数 新数 段名
diff_named_section(){
  local label=$1 oldf=$2 newf=$3 fn=$4 oc=$5 nc=$6 sec=$7
  local a b add rem d sign
  a=$(mktemp); b=$(mktemp); add=$(mktemp); rem=$(mktemp)
  "$fn" "$oldf" | sort -u > "$a"; "$fn" "$newf" | sort -u > "$b"
  awk 'NR==FNR{x[$0];next} !($0 in x)' "$a" "$b" > "$add"   # 新有旧无
  awk 'NR==FNR{x[$0];next} !($0 in x)' "$b" "$a" > "$rem"   # 旧有新无
  d=$(( nc - oc )); sign=$([ "$d" -ge 0 ] && echo "+$d" || echo "$d")
  if [ -s "$add" ] || [ -s "$rem" ]; then                  # 有增删
    DNS_SEG="${label} ${oc}→${nc}(${sign})"
    [ -s "$add" ] && DNS_SEG="$DNS_SEG $(inline_names '＋' "$add")"
    [ -s "$rem" ] && DNS_SEG="$DNS_SEG $(inline_names '－' "$rem")"
  elif [ "$(sec_body "$sec" "$oldf" | md5)" != "$(sec_body "$sec" "$newf" | md5)" ]; then
    DNS_SEG="${label} ${oc}→${nc} 顺序调整"                 # 数量名单不变但内部字节变
  else
    DNS_SEG=""                                              # 该段无变化 → 不提
  fi
  rm -f "$a" "$b" "$add" "$rem"
}

# ---------- TG 推送（等宽代码块，保证机场名对齐） ----------
tg_send(){
  [ "$TG_ENABLE" = "true" ] || { log "TG 未启用，跳过推送"; return 1; }
  # HTML 转义 &<& 后用 <pre> 包裹成等宽；截断留余量给标签
  local body
  body=$(printf '%s' "${1:0:3800}" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')
  curl -ksS -m 20 -X POST "https://api.telegram.org/bot$TG_TOKEN/sendMessage" \
    --data-urlencode "chat_id=$TG_CHAT" \
    --data-urlencode "parse_mode=HTML" \
    --data-urlencode "text=<pre>${body}</pre>" >/dev/null 2>&1 \
    && { log "TG 已推送"; return 0; } || { log "TG 推送失败"; return 1; }
}

# ---------- 每机场最后状态 ----------
# 每个启用机场独立保存最近一次 full 运行产生的报告片段。
# 第一行是格式化时间，后续是原报告片段。单机场运行只更新自身，不再覆盖其他机场状态。
save_airport_report(){
  local name=$1 fragment=$2 out="$STATEDIR/$1.last_report" tmp="$STATEDIR/$1.last_report.tmp"
  printf '%s\n%s' "$(date '+%m-%d %H:%M')" "$fragment" > "$tmp" && mv "$tmp" "$out"
}

# 按 config.json 中启用机场的顺序，动态汇总每个机场最后一次状态。
# 结果写入全局 LATEST_REPORT；每条首行附状态时间，避免一天多次运行造成歧义。
build_latest_report(){
  local n idx nm f stamp fragment annotated any_warn=0 missing=0
  local aggregate="" pad=4
  n=$(jq '.airports | length' "$CONF")
  for ((idx=0;idx<n;idx++)); do
    [ "$(jq -r ".airports[$idx].enabled" "$CONF")" = "true" ] || continue
    nm=$(jq -r ".airports[$idx].name" "$CONF")
    [ "${#nm}" -gt "$pad" ] && pad=${#nm}
  done
  for ((idx=0;idx<n;idx++)); do
    [ "$(jq -r ".airports[$idx].enabled" "$CONF")" = "true" ] || continue
    nm=$(jq -r ".airports[$idx].name" "$CONF")
    f="$STATEDIR/$nm.last_report"
    if [ ! -s "$f" ]; then
      aggregate+="$(printf '%-*s ⚠️ 无状态快照 [未运行]' "$pad" "$nm")"$'\n'
      any_warn=1; missing=$((missing+1)); continue
    fi
    stamp=$(head -n 1 "$f")
    [ -n "$stamp" ] || stamp="时间未知"
    fragment=$(tail -n +2 "$f")
    annotated=$(printf '%s\n' "$fragment" | awk -v s="$stamp" 'NR==1{print $0"  ["s"]";next}{print}')
    aggregate+="$annotated"$'\n'
    printf '%s' "$fragment" | grep -q '⚠️' && any_warn=1
  done
  LATEST_REPORT="📡 订阅最后状态 $(date '+%m-%d %H:%M')"
  [ "$any_warn" -eq 1 ] && LATEST_REPORT="$LATEST_REPORT ⚠️有异常"
  LATEST_REPORT="$LATEST_REPORT"$'\n'"$aggregate"
  log "汇总每机场最后状态：启用$(jq '[.airports[]|select(.enabled==true)]|length' "$CONF") 缺失${missing}"
}

# ====================== 各模式 ======================
REPORT=""; WARN=0

# ---------- --check ----------
if [ "$MODE" = "check" ]; then
  echo "✅ config.json 语法正确"
  echo "Telegram: enable=$TG_ENABLE chat=$TG_CHAT"
  echo "发布: 格式和最低节点/规则/组数量通过后，有字节差异即发布；跌幅≥${NODE_DROP_PCT}% 仍发布但告警"
  echo "原始订阅: ≥${RAW_MIN_BYTES}B 且 规则≤${RAW_MAX_RULES}; 重试 ${DL_RETRIES} 次"
  echo "机场清单（顺序即处理顺序，被依赖的机场需排前）:"
  n=$(jq '.airports|length' "$CONF")
  for ((i=0;i<n;i++)); do
    en=$(jq -r ".airports[$i].enabled" "$CONF")
    nm=$(jq -r ".airports[$i].name" "$CONF")
    ru=$(jq -r ".airports[$i].raw_url" "$CONF")
    cu=$(jq -r ".airports[$i].convert_url" "$CONF")
    rl=$(jq -r ".airports[$i].raw_max_rules // $RAW_MAX_RULES" "$CONF")
    flag="ok"
    case "$ru" in http://*|https://*) ;; *) flag="raw_url非法!" ;; esac
    case "$cu" in http://*|https://*) ;; *) flag="convert_url非法!" ;; esac
    load_limits "$i"
    printf "  [%s] %-12s ext=%s  原始规则≤%s  最低节点/规则/组=%s/%s/%s  断言=%s\n" "$([ "$en" = true ] && echo 启用 || echo 停用)" "$nm" "$(jq -r ".airports[$i].raw_ext" "$CONF")" "$rl" "$CUR_MIN_NODES" "$CUR_MIN_RULES" "$CUR_MIN_GROUPS" "$flag"
  done
  exit 0
fi

# ---------- --status（只读体检） ----------
if [ "$MODE" = "status" ]; then
  echo "================= submgr 体检 $(date '+%m-%d %H:%M') ================="
  n=$(jq '.airports|length' "$CONF")
  for ((i=0;i<n;i++)); do
    name=$(jq -r ".airports[$i].name" "$CONF")
    ext=$(jq -r ".airports[$i].raw_ext" "$CONF")
    CUR_RAW_MAX_RULES=$(jq -r ".airports[$i].raw_max_rules // $RAW_MAX_RULES" "$CONF")
    load_limits "$i"
    raw="$WORKDIR/$name.$ext"; latest="$WORKDIR/${name}Sub_latest.yml"; prev="$WORKDIR/${name}Sub_previous.yml"
    smeta="$STATEDIR/$name.meta"
    echo "── $name ──"
    if [ -s "$raw" ]; then
      age=$(( ( $(now) - $(mtime "$raw") ) / 60 ))
      printf "  原始订阅: %s  %s  规则%s  %dm前  %s\n" "$(human $(wc -c<"$raw"))" "$(raw_kind "$raw")" "$(count_rules "$raw")" "$age" "$(valid_raw "$raw" && echo 合法 || echo ⚠️异常/污染)"
    else echo "  原始订阅: 缺失"; fi
    if [ -s "$latest" ]; then
      printf "  对外订阅: %s  节点%s 规则%s 策略组%s  %s\n" "$(human $(wc -c<"$latest"))" "$(count_nodes "$latest")" "$(count_rules "$latest")" "$(count_groups "$latest")" "$(valid_clash "$latest" && echo 合法 || echo ⚠️不合法)"
      limit_errors=$(result_limit_errors "$latest")
      [ -z "$limit_errors" ] || printf '  数量保护未通过: %s\n' "$limit_errors"
    else echo "  对外订阅: 缺失"; fi
    if [ -f "$smeta" ]; then
      bn=$(meta_get "$smeta" nodes); br=$(meta_get "$smeta" rules); bg=$(meta_get "$smeta" groups)
      printf "  基线 : 节点%s 规则%s 策略组%s" "$bn" "$br" "${bg:-?}"
      # 脏基线启发式：对外规则与基线差异大 / 原始订阅被污染
      ln=$(count_nodes "$latest" 2>/dev/null); lr=$(count_rules "$latest" 2>/dev/null)
      flag=""
      [ -n "$lr" ] && [ -n "$br" ] && [ "$br" -gt 0 ] && [ "$(( lr>br ? lr-br : br-lr ))" -gt 2000 ] && flag="$flag ⚠️规则与对外差异大"
      valid_raw "$raw" || flag="$flag ⚠️原始订阅异常"
      echo "$flag"
    else echo "  基线 : 未建立"; fi
  done
  echo "================================================================="
  exit 0
fi

# ---------- --send-report ----------
if [ "$MODE" = "send" ]; then
  if [ -f "$SENTMARK" ]; then note "上次报告已推送过，跳过（重发: rm $SENTMARK）"; exit 0; fi
  build_latest_report
  printf '%s\n' "$LATEST_REPORT" > "$REPORTFILE.tmp" && mv "$REPORTFILE.tmp" "$REPORTFILE"
  tg_send "$LATEST_REPORT" && : > "$SENTMARK"
  exit 0
fi

# ====================== 处理单个机场 ======================
process_airport(){
  local name=$1 ext=$2 raw_url=$3 backup_url=$4 conv_url=$5
  local raw="$WORKDIR/$name.$ext"  bak="$WORKDIR/${name}back.$ext"
  local latest="$WORKDIR/${name}Sub_latest.yml"  prev="$WORKDIR/${name}Sub_previous.yml"
  local smeta="$STATEDIR/$name.meta"

  # ---- report-only：只读分析现有对外订阅 ----
  if [ "$MODE" = "report" ]; then
    if [ ! -s "$latest" ]; then aline "$name" "⚠️" "对外订阅缺失"; WARN=1; return; fi
    local ok; ok=$(valid_clash "$latest" && echo "" || echo " ⚠️不合法")
    aline "$name" "📄" "对外订阅 节点$(count_nodes "$latest") 规则$(count_rules "$latest") 策略组$(count_groups "$latest")${ok}"
    return
  fi

  # ---- dry-run：下载到沙盒校验，绝不碰 /www，不转换 ----
  if [ "$MODE" = "dry" ]; then
    mkdir -p "$DRYDIR"; local dl="$DRYDIR/$name.$ext"
    if fetch "$raw_url" "$dl" && valid_raw "$dl"; then
      aline "$name" "🧪" "下载OK $(raw_kind "$dl") $(human $(wc -c<"$dl")) 规则$(count_rules "$dl")(未发布)"
    else
      aline "$name" "⚠️" "下载/校验失败 $(raw_kind "$dl" 2>/dev/null)(dry-run)"; WARN=1
    fi
    rm -f "$dl"
    return
  fi

  # ---- pull-only：只刷新 /www 原始订阅，不转换不发布 ----
  if [ "$MODE" = "pull" ]; then
    download_raw "$name" "$raw" "$bak" "$raw_url" "$backup_url" || true
    local rawage=0; [ -s "$raw" ] && rawage=$(( ( $(now) - $(mtime "$raw") ) / 60 ))
    case "$RAW_STATUS" in
      fresh) aline "$name" "⬇️" "原始订阅已更新 $(raw_kind "$raw") $(human $(wc -c<"$raw"))" ;;
      stale) aline "$name" "⚠️" "拉取失败,沿用现有原始订阅(${rawage}m前)"; WARN=1 ;;
      bak)   aline "$name" "⚠️" "拉取失败,已用原始订阅备份"; WARN=1 ;;
      none)  aline "$name" "⚠️" "拉取失败,无可用原始订阅"; WARN=1 ;;
    esac
    return
  fi

  # ================= full：真正流程 =================
  # 阶段1：上游拉取（--no-pull 跳过=人为，不算异常）。RAW_STATUS=fresh|skip|stale|bak|none
  if [ "$SKIP_PULL" = "yes" ]; then
    RAW_STATUS=skip; log "[$name] --no-pull：跳过下载，用现有原始订阅重转换"
  else
    download_raw "$name" "$raw" "$bak" "$raw_url" "$backup_url" || true
  fi
  local rawage=0; [ -s "$raw" ] && rawage=$(( ( $(now) - $(mtime "$raw") ) / 60 ))
  # 原始订阅侧说明：拉取真失败(stale/bak/none)才算异常并加 raw_note；fresh/skip 不提
  local raw_note="" raw_bad=0
  case "$RAW_STATUS" in
    stale) raw_note="原始订阅拉取失败,沿用现有(${rawage}m前)"; raw_bad=1; WARN=1 ;;
    bak)   raw_note="原始订阅拉取失败,已用备份";              raw_bad=1; WARN=1 ;;
    none)  raw_note="原始订阅拉取失败,无可用";                raw_bad=1; WARN=1 ;;
  esac
  # 发布类分支的首行 emoji+状态词：拉取真失败=⚠️异常，否则=🔄更新；纯异常分支恒为 ⚠️异常
  # 原始订阅失败说明(raw_note)与各变化段，统一拆成缩进 ↳ 续行，保证首行短、名字列对齐、不折行
  local em wd
  if [ "$raw_bad" -eq 1 ]; then em="⚠️"; wd="异常"; else em="🔄"; wd="更新"; fi

  # 阶段2：转换前预检
  if ! precheck_raw "$name" "$raw"; then
    aline "$name" "⚠️" "异常"
    acont "${raw_note:-原始订阅无效(格式/大小/污染)}"
    acont "跳过转换,保留对外订阅"
    WARN=1; return
  fi

  # 阶段3：转换 + 结果闸门（转换失败：保留现有对外订阅，附 subconverter 错误）
  local dl="$latest.dl"
  if ! convert_to "$name" "$conv_url" "$dl"; then
    aline "$name" "⚠️" "异常"
    [ -n "$raw_note" ] && acont "$raw_note"
    acont "转换失败(疑似ini错误),保留对外订阅"
    acont "subconverter: ${CONV_ERR:-未知错误}"
    WARN=1; return
  fi

  # 阶段4：格式和每机场最低数量均通过，才允许首次发布或轮换。
  local new_nodes new_rules new_groups
  new_nodes=$(count_nodes "$dl"); new_rules=$(count_rules "$dl"); new_groups=$(count_groups "$dl")

  local limit_errors limit_error
  limit_errors=$(result_limit_errors "$dl")
  if [ -n "$limit_errors" ]; then
    mv "$dl" "/tmp/submgr_${name}.rej"
    aline "$name" "⚠️" "异常"
    [ -n "$raw_note" ] && acont "$raw_note"
    while IFS= read -r limit_error; do
      acont "$limit_error"
      log "[$name] 转换数量检查失败：$limit_error"
    done <<< "$limit_errors"
    acont "保留现有对外订阅和备份"
    WARN=1; return
  fi

  if [ ! -s "$latest" ] || ! valid_clash "$latest"; then   # 对外缺失/损坏/首次 → 直接建立
    publish "$dl" "$latest" "$prev"; save_meta "$smeta" "$new_nodes" "$new_rules" "$new_groups"
    aline "$name" "$em" "$wd"
    [ -n "$raw_note" ] && acont "$raw_note"
    acont "首次建立 节点$new_nodes 规则$new_rules 策略组$new_groups"
    return
  fi

  if cmp -s "$dl" "$latest"; then                    # 逐字节一致 → 内容无变化
    rm -f "$dl"
    if [ "$raw_bad" -eq 1 ]; then
      aline "$name" "⚠️" "异常"; acont "$raw_note"; acont "对外订阅无变化"
    else
      aline "$name" "➖" "正常"
    fi
    return
  fi

  # 有差异 → 只列变化的段(默认配置/节点/代理组/规则)，拼成一行；发布并轮换
  local cur_nodes cur_rules cur_groups
  cur_nodes=$(count_nodes "$latest"); cur_rules=$(count_rules "$latest"); cur_groups=$(count_groups "$latest")
  local segs=() hl rd signr
  hl=$(hdr_changed_lines "$latest" "$dl"); [ "${hl:-0}" -gt 0 ] && segs+=("默认配置 修改${hl}行")
  diff_named_section "节点"   "$latest" "$dl" node_names  "$cur_nodes"  "$new_nodes"  proxies
  [ -n "$DNS_SEG" ] && segs+=("$DNS_SEG")
  diff_named_section "代理组" "$latest" "$dl" group_names "$cur_groups" "$new_groups" "proxy-groups"
  [ -n "$DNS_SEG" ] && segs+=("$DNS_SEG")
  rd=$(( new_rules - cur_rules ))
  if [ "$rd" -ne 0 ]; then signr=$([ "$rd" -ge 0 ] && echo "+$rd" || echo "$rd"); segs+=("规则 ${cur_rules}→${new_rules}(${signr})")
  elif [ "$(sec_body rules "$latest" | md5)" != "$(sec_body rules "$dl" | md5)" ]; then segs+=("规则 顺序调整"); fi
  local drop=0; [ "$cur_nodes" -gt 0 ] && drop=$(( (cur_nodes-new_nodes)*100/cur_nodes ))
  [ "$cur_nodes" -gt 0 ] && [ "$drop" -ge "$NODE_DROP_PCT" ] && { segs+=("⚠️节点骤降${drop}%可回滚"); WARN=1; }
  [ "${#segs[@]}" -eq 0 ] && segs+=("内容有变")   # 兜底：字节有差异但未落到四段(理论上不会)
  aline "$name" "$em" "$wd"                        # 首行: 名 emoji 更新/异常
  [ -n "$raw_note" ] && acont "$raw_note"          # 原始订阅失败说明(若有)单独一行
  local s; for s in "${segs[@]}"; do acont "$s"; done   # 每个变化段各占一缩进行

  publish "$dl" "$latest" "$prev"
  save_meta "$smeta" "$new_nodes" "$new_rules" "$new_groups"
}

# ====================== 主流程 ======================
mkdir -p "$STATEDIR"
if ! mkdir "$LOCKDIR" 2>/dev/null; then note "另一个 submgr 实例仍在运行，退出"; exit 1; fi
trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT
log "=============== 运行开始 (mode=$MODE) ==============="

ACOUNT=$(jq '.airports | length' "$CONF")

# 预先算出将处理的机场名最大宽度，用于报告左对齐
NAMEPAD=4
for (( idx=0; idx<ACOUNT; idx++ )); do
  [ "$(jq -r ".airports[$idx].enabled" "$CONF")" = "true" ] || continue
  nm=$(jq -r ".airports[$idx].name" "$CONF")
  if [ "${#PICK[@]}" -gt 0 ]; then
    s=1; for p in "${PICK[@]}"; do [ "$p" = "$nm" ] && s=0; done; [ "$s" -eq 1 ] && continue
  fi
  [ "${#nm}" -gt "$NAMEPAD" ] && NAMEPAD=${#nm}
done

for (( idx=0; idx<ACOUNT; idx++ )); do
  [ "$(jq -r ".airports[$idx].enabled" "$CONF")" = "true" ] || continue
  name=$(jq -r ".airports[$idx].name" "$CONF")
  ext=$(jq -r ".airports[$idx].raw_ext // \"yaml\"" "$CONF")
  raw_url=$(jq -r ".airports[$idx].raw_url" "$CONF")
  backup_url=$(jq -r ".airports[$idx].backup_url // \"\" | if type==\"array\" then join(\" \") else . end" "$CONF")   # 支持字符串或数组(多个备用地址按顺序尝试)
  conv_url=$(jq -r ".airports[$idx].convert_url" "$CONF")
  # 按机场 UA 覆盖（缺省回退全局 USER_AGENT）。fetch 读取 CUR_UA
  CUR_UA=$(jq -r ".airports[$idx].user_agent // \"\"" "$CONF")
  [ -z "$CUR_UA" ] && CUR_UA="$USER_AGENT"
  # 完整 Clash 原始订阅可能自带少量规则；仅对明确配置的机场放宽，不影响全局污染保护。
  CUR_RAW_MAX_RULES=$(jq -r ".airports[$idx].raw_max_rules // $RAW_MAX_RULES" "$CONF")
  load_limits "$idx"

  if [ "${#PICK[@]}" -gt 0 ]; then
    skip=1; for p in "${PICK[@]}"; do [ "$p" = "$name" ] && skip=0; done
    [ "$skip" -eq 1 ] && continue
  fi

  # 字段断言：URL 必须 http(s)，否则跳过该机场并告警
  case "$raw_url" in http://*|https://*) ;; *) note "⛔ $name raw_url 非法"; aline "$name" "⚠️" "raw_url 非法,跳过"; WARN=1; continue ;; esac
  case "$conv_url" in http://*|https://*) ;; *) note "⛔ $name convert_url 非法"; aline "$name" "⚠️" "convert_url 非法,跳过"; WARN=1; continue ;; esac

  note "----- 处理 $name -----"
  report_before="$REPORT"
  process_airport "$name" "$ext" "$raw_url" "$backup_url" "$conv_url"
  if [ "$MODE" = "full" ]; then
    report_fragment="${REPORT#"$report_before"}"
    [ -n "$report_fragment" ] && save_airport_report "$name" "$report_fragment"
  fi
done

# 汇总
HEADER="📡 订阅更新 $(date '+%m-%d %H:%M')"
[ "$WARN" -eq 1 ] && HEADER="$HEADER ⚠️有异常"
[ "$MODE" = "dry" ] && HEADER="$HEADER [DRY-RUN]"
[ "$MODE" = "report" ] && HEADER="$HEADER [REPORT-ONLY]"
[ "$MODE" = "pull" ] && HEADER="$HEADER [仅拉取]"          # 人为只拉取，非异常
[ "$SKIP_PULL" = "yes" ] && HEADER="$HEADER [仅转换]"       # 人为只转换(--no-pull)，非异常
FULLMSG="$HEADER"$'\n'"$REPORT"
if [ "$MODE" = "full" ]; then
  build_latest_report
  FULLMSG="$LATEST_REPORT"
fi
echo "==================== 报告 ===================="; echo "$FULLMSG"; echo "=============================================="

if [ "$MODE" = "full" ]; then
  printf '%s\n' "$FULLMSG" > "$REPORTFILE.tmp" && mv "$REPORTFILE.tmp" "$REPORTFILE"
  rm -f "$SENTMARK"
fi
if [ "$SEND" = "yes" ] && [ "$MODE" != "dry" ]; then
  tg_send "$FULLMSG" && [ "$MODE" = "full" ] && : > "$SENTMARK"
else
  [ "$MODE" = "full" ] && note "本次不推送；报告已存 $REPORTFILE，可 --send-report 延迟推送"
fi

if [ -f "$LOG" ] && [ "$(wc -l < "$LOG")" -gt "$LOG_KEEP" ]; then
  tail -n "$LOG_KEEP" "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi
log "=============== 运行结束 ==============="
exit 0
