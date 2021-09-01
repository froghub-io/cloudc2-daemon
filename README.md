# cloudc2-daemon


## ubuntu 18.04 到 20.04 需执行以下命令
sudo ln -s /usr/lib/x86_64-linux-gnu/libhwloc.so.15 /usr/lib/x86_64-linux-gnu/libhwloc.so.5

## 环境变量说明（非必填）
* CLOUDC2_DAEMON_INSTALL_COMMIT 指定版本，否则走默认更新
* CLOUDC2_DAEMON_FIL_PROOFS_PARAMETER_CACHE 指定零知识证明文件缓存路径，必须保证当前路径有250G内容以上

## 执行命令
export CLOUDC2_DAEMON_INSTALL_COMMIT=v1.0.0
export CLOUDC2_DAEMON_FIL_PROOFS_PARAMETER_CACHE=/mnt/md0
export CLOUDC2_DAEMON_APPID=你的appID
curl -sfL https://get.froghub.cn | sh -