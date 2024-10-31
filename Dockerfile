FROM alpine:latest

ENV TZ=Asia/Shanghai
ENV LANG en_US.UTF-8

RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

RUN apk add --no-cache bash curl jq vim

WORKDIR /root

ADD ./add_local_ipv6_firewall_linksys.sh /root
RUN chmod +x ./add_local_ipv6_firewall_linksys.sh

# 创建一个 Cron 任务，每分钟执行 add_local_ipv6_firewall_linksys脚本
RUN echo "* * * * * /bin/bash /root/add_local_ipv6_firewall_linksys.sh" >> /etc/crontabs/root

# 启动 Cron 服务
CMD ["crond", "-f"]
