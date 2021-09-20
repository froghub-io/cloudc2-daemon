#! /bin/bash
export PATH="/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin"
pid=$(ps x | grep "cloudc2-daemon daemon" | grep -v grep | awk '{print $1}')
if [ -n "$pid" ]; then
  kill -9 $pid
fi
pid=$(ps x | grep "cloudc2-daemon worker" | grep -v grep | awk '{print $1}')
if [ -n "$pid" ]; then
  kill -9 $pid
fi