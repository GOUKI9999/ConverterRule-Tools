#!/bin/bash
set -eu
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "${TEST_DIR:?请指定独立测试目录 TEST_DIR}"
cd "$TEST_DIR"
# 只加载函数，使用桩函数提供输入/转换结果，不执行生产主流程。
source <(awk '/^count_block\(\)/{p=1} /^# ====================== 主流程/{p=0} p && /^[a-zA-Z_]+\(\)/{f=1} f{print} f && /^}/{f=0}' "$PROJECT_DIR/submgr.sh")
log(){ :; }; now(){ echo 100; }; mtime(){ echo 100; }
precheck_raw(){ return 0; }
convert_to(){ cp "$FIXTURE" "$3"; }
save_meta(){ printf 'new baseline\n' > "$1"; }
NODE_MIN_KEEP=1; CUR_MIN_NODES=5; CUR_MIN_RULES=10; CUR_MIN_GROUPS=3
RAW_MAX_AGE_MIN=180; NODE_DROP_PCT=40; LIST_TRUNCATE=15; MODE=full; SKIP_PULL=yes; NAMEPAD=10
WORKDIR="$PWD/fixtures/work"; STATEDIR="$PWD/fixtures/state"; mkdir -p "$WORKDIR" "$STATEDIR"
make_yaml(){
  local f=$1 nodes=$2 rules=$3 groups=$4 tag=$5 i
  { echo "# $tag"; echo 'proxies:'; for ((i=1;i<=nodes;i++)); do echo "  - {name: node$i, type: ss, server: example.com, port: 443, cipher: aes-128-gcm, password: test}"; done
    echo 'proxy-groups:'; for ((i=1;i<=groups;i++)); do echo "  - {name: group$i, type: select, proxies: [DIRECT]}"; done
    echo 'rules:'; for ((i=1;i<=rules;i++)); do echo "  - DOMAIN,example$i.com,DIRECT"; done; } > "$f"
}
check_reject(){
 local label=$1 nodes=$2 rules=$3 groups=$4 before after
 make_yaml "$WORKDIR/TestSub_latest.yml" 10 20 5 good
 make_yaml "$WORKDIR/TestSub_previous.yml" 9 20 5 previous
 echo oldbaseline > "$STATEDIR/Test.meta"
 before=$(md5sum "$WORKDIR/TestSub_latest.yml" "$WORKDIR/TestSub_previous.yml" "$STATEDIR/Test.meta")
 FIXTURE="$PWD/fixtures/input.yml"; make_yaml "$FIXTURE" "$nodes" "$rules" "$groups" "$label"
 REPORT=''; WARN=0
 process_airport Test yaml unused unused unused
 after=$(md5sum "$WORKDIR/TestSub_latest.yml" "$WORKDIR/TestSub_previous.yml" "$STATEDIR/Test.meta")
 if [ "$before" != "$after" ] || [ "$WARN" != 1 ]; then echo "FAIL $label changed protected data or missed warning"; return 1; fi
 echo "PASS $label: latest/previous/baseline preserved"
}
check_reject zero_nodes 0 20 5
check_reject notification_only 1 20 5
check_reject empty_rules 10 0 5
check_reject low_rules 10 2 5
check_reject low_groups 10 20 1
check_reject multiple_failures 1 0 0
FIXTURE="$PWD/fixtures/input.yml"; make_yaml "$FIXTURE" 10 20 5 valid-new
cp "$WORKDIR/TestSub_latest.yml" "$PWD/fixtures/expected-previous.yml"
REPORT=''; WARN=0; process_airport Test yaml unused unused unused
cmp "$FIXTURE" "$WORKDIR/TestSub_latest.yml"
cmp "$PWD/fixtures/expected-previous.yml" "$WORKDIR/TestSub_previous.yml"
echo 'PASS valid result published and previous rotated'
# 首次发布也必须通过数量检查。
mv "$WORKDIR/TestSub_latest.yml" "$PWD/fixtures/removed-latest.yml"
make_yaml "$FIXTURE" 1 20 5 invalid-first
REPORT=''; WARN=0; process_airport Test yaml unused unused unused
[ ! -f "$WORKDIR/TestSub_latest.yml" ]; [ "$WARN" = 1 ]
echo 'PASS invalid first publish rejected'
make_yaml "$FIXTURE" 10 20 5 valid-first
REPORT=''; WARN=0; process_airport Test yaml unused unused unused
cmp "$FIXTURE" "$WORKDIR/TestSub_latest.yml"
echo 'PASS valid first publish'
# 已经低于当前阈值的旧latest不应覆盖仍健康的previous。
make_yaml "$WORKDIR/TestSub_latest.yml" 1 20 5 invalid-old
cp "$WORKDIR/TestSub_previous.yml" "$PWD/fixtures/expected-previous.yml"
make_yaml "$FIXTURE" 10 20 5 repaired
REPORT=''; WARN=0; process_airport Test yaml unused unused unused
cmp "$FIXTURE" "$WORKDIR/TestSub_latest.yml"
cmp "$PWD/fixtures/expected-previous.yml" "$WORKDIR/TestSub_previous.yml"
echo 'PASS invalid old latest does not replace previous'
