#!/bin/bash

#ROUTER_AUTH=$1
#ROUTER_AUTH 从环境变量获取

# 存储之前的 IPv6 地址
PREVIOUS_IP_FILE="./current_ipv6.txt"
# 路由器接口地址
ROUTER_IP="192.168.1.1"
ROUTER_INTERFACE="https://$ROUTER_IP/JNAP/"

# 将 IPv6 地址转换为完成的地址，不足的在每个段前补齐0
full_ipv6() {
  input_ipv6=$1
  IFS=':' read -ra segments <<<"$input_ipv6"
  for i in "${!segments[@]}"; do
    segments[i]=$(printf "%04x" 0x"${segments[i]}")
  done
  echo "${segments[*]}" | tr ' ' ':'
}

current_ipv6_firewall_rules() {
  current_ipv6=$1
  echo "[
    {
      \"isEnabled\": true,
      \"ipv6Address\": \"$current_ipv6\",
      \"portRanges\": [
        {
          \"protocol\": \"Both\",
          \"firstPort\": 5055,
          \"lastPort\": 5056
        }
      ],
      \"description\": \"zspace-home\"
    },
    {
      \"isEnabled\": true,
      \"ipv6Address\": \"$current_ipv6\",
      \"portRanges\": [
        {
          \"protocol\": \"Both\",
          \"firstPort\": 8050,
          \"lastPort\": 8050
        }
      ],
      \"description\": \"zspace-data\"
    },
    {
      \"isEnabled\": true,
      \"ipv6Address\": \"$current_ipv6\",
      \"portRanges\": [
        {
          \"protocol\": \"Both\",
          \"firstPort\": 22000,
          \"lastPort\": 22000
        }
      ],
      \"description\": \"zspace-synfile\"
    },
    {
       \"isEnabled\": true,
       \"ipv6Address\": \"$current_ipv6\",
       \"portRanges\": [
         {
           \"protocol\": \"Both\",
           \"firstPort\": 9001,
           \"lastPort\": 9001
         }
       ],
       \"description\": \"zspace-mntdisk\"
    }
  ]"
}



# 获取当前的 IPv6 地址
CURRENT_IP=$(ifconfig | grep 'inet6' | awk '{print $3}' | awk -F'/' '{print $1}' | grep -Ev 'fe80.*|fd00.*|::1' | head -n 1)
#CURRENT_IP=$(ifconfig | grep 'inet6' | awk '{print $2}' | head -n 1)
echo "得到当前ipv6地址为 $CURRENT_IP"

# 检查是否存在之前的地址文件
if [[ -f "$PREVIOUS_IP_FILE" ]]; then
  PREVIOUS_IP=$(cat "$PREVIOUS_IP_FILE")
  echo "从历史文件中找到上次 IPv6 地址为 $PREVIOUS_IP 进行比较"
else
  echo "未找到历史地址文件，将使用空地址进行比较"
  PREVIOUS_IP=""
fi

# 比较当前地址与之前的地址
if [[ "$CURRENT_IP" = "$PREVIOUS_IP" ]]; then
  echo "当前 IPv6 地址与历史地址相同，无需更新"
  exit 0
fi

echo "当前 IPv6 地址与历史地址不同，将更新防火墙配置"

# 获取路由器的ipv6防火墙配置
result=$(curl -k $ROUTER_INTERFACE -X POST \
  -H 'User-Agent: Mozilla/5.0 (X11; Linux x86_64; rv:130.0) Gecko/20100101 Firefox/130.0' \
  -H 'Accept: */*' -H 'Accept-Language: en-US,en;q=0.5' -H 'Accept-Encoding: gzip, deflate, br, zstd' \
  -H 'Content-Type: application/json; charset=UTF-8' \
  -H 'X-JNAP-Action: http://linksys.com/jnap/core/Transaction' \
  -H 'Expires: Fri, 10 Oct 2013 14:19:41 GMT' -H 'Cache-Control: no-cache' \
  -H "X-JNAP-Authorization: Basic $ROUTER_AUTH" \
  -H 'X-Requested-With: XMLHttpRequest' \
  -H "Origin: https://$ROUTER_IP" -H 'Connection: keep-alive' \
  -H "Referer: https://$ROUTER_IP/ui/1.0.99.210200/dynamic/home.html" \
  -H 'Sec-Fetch-Dest: empty' -H 'Sec-Fetch-Mode: cors' -H 'Sec-Fetch-Site: same-origin' \
  --data-raw '[{"action":"http://linksys.com/jnap/firewall/GetFirewallSettings","request":{}},{"action":"http://linksys.com/jnap/firewall/GetIPv6FirewallRules","request":{}}]')

# 判断请求是否成功 .result 是否为 OK
isResultOk=$(echo "$result" | jq '.responses[1].result')
if [[ "$isResultOk" != '"OK"' ]]; then
  echo "请求GetFirewallSettings失败，请检查路由器是否在线"
  echo "$result"
  exit 1
fi

# 使用 jq 解析 isIPv6FirewallEnabled
isIPv6FirewallEnabledOk=$(echo "$result" | jq '.responses[0].result')
if [[ "$isIPv6FirewallEnabledOk" != '"OK"' ]]; then
  echo "请求isIPv6FirewallEnabled失败，请检查路由器情况"
  exit 2
fi
isIPv6FirewallEnabled=$(echo "$result" | jq '.responses[0].output.isIPv6FirewallEnabled')

# 如果防火墙未开启，则直接返回
if [[ "$isIPv6FirewallEnabled" != "true" ]]; then
  echo "IPv6 防火墙未开启，无需更新"
  exit 0
fi

# 如果防火墙配置已包含当前ipv6，则直接返回
getIPv6FirewallRulesOk=$(echo "$result" | jq '.responses[1].result')
if [[ "$getIPv6FirewallRulesOk" != '"OK"' ]]; then
  echo "请求GetFirewallSettings失败，请检查路由器情况"
  exit 3
fi
current_full_ipv6=$(full_ipv6 "$CURRENT_IP")
current_firewall_rules=$(echo "$result" | jq -e ".responses[1].output.rules[] | select(.isEnabled==true) | select(.ipv6Address == \"$current_full_ipv6\")" | jq -s ".")

# 如果当前防火墙配置不为空，则直接返回
if [[ "$current_firewall_rules" != "[]" ]]; then
  echo "当前防火墙配置已包含当前ipv6，无需更新"
  exit 0
fi

# 组装变更防火墙配置的命令，在原rule上追加本机防火墙配置
local_ipv6_firewall_rules=$(current_ipv6_firewall_rules "$CURRENT_IP" "$ROUTER_INTERFACE" "$ROUTER_AUTH" "$ROUTER_IP")
router_firewall_rules=$(echo "$result" | jq -e ".responses[1].output.rules[]" | jq -s ".")
update_firewall_rules=$(echo "$router_firewall_rules" "$local_ipv6_firewall_rules" | jq -c -s '.[0] + .[1]')
echo "即将更新防火墙配置为 $update_firewall_rules"

result=$(curl -k $ROUTER_INTERFACE -X POST \
  -H 'User-Agent: Mozilla/5.0 (X11; Linux x86_64; rv:130.0) Gecko/20100101 Firefox/130.0' \
  -H 'Accept: */*' -H 'Accept-Language: en-US,en;q=0.5' -H 'Accept-Encoding: gzip, deflate, br, zstd' \
  -H 'Content-Type: application/json; charset=UTF-8' -H 'X-JNAP-Action: http://linksys.com/jnap/core/Transaction' \
  -H 'Expires: Fri, 10 Oct 2013 14:19:41 GMT' -H 'Cache-Control: no-cache' \
  -H "X-JNAP-Authorization: Basic $ROUTER_AUTH" \
  -H 'X-Requested-With: XMLHttpRequest' -H "Origin: https://$ROUTER_IP" \
  -H 'Connection: keep-alive' -H "Referer: https://$ROUTER_IP/ui/1.0.99.210200/dynamic/home.html" \
  -H 'Sec-Fetch-Dest: empty' -H 'Sec-Fetch-Mode: cors' -H 'Sec-Fetch-Site: same-origin' -H 'Priority: u=0' \
  --data-raw "[{\"action\":\"http://linksys.com/jnap/firewall/SetIPv6FirewallRules\",\"request\":{\"rules\":$update_firewall_rules}}]")

# 判断请求是否成功 .result 是否为 OK
isResultOk=$(echo "$result" | jq '.responses[0].result')
if [[ "$isResultOk" != '"OK"' ]]; then
  echo "请求SetIPv6FirewallRules失败，请检查路由器是否在线 $result"
  exit 4
fi

echo "更新路由器防火墙规则成功"

# 更新之前的地址
echo "$CURRENT_IP" >"$PREVIOUS_IP_FILE"
echo "更新文件成功，当前 IPv6 地址为 $CURRENT_IP"
