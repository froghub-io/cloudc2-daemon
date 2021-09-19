#! /bin/bash
export PATH="/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin"
set -a
source /etc/systemd/system/cloudc2-daemon.service.env
set +a
pid=$(ps x | grep "cloudc2-daemon daemon" | grep -v grep | awk '{print $1}')
if [ ! $pid ]; then
  nohup cloudc2-daemon daemon > /var/log/cloudc2-daemon.log 2>&1 &
fi