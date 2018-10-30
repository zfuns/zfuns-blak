# 一个获取网络相关的脚本
# by zfuns

# 获取外网ip
get_ip(){
	ip=`curl -s ip.cip.cc`
	echo $ip
}

# 获取ip
get_nat_ip(){
        nat_ip=`echo ${_tmp#*-> }|cut -d ' ' -f1`
        if [[ -z $net_ip ]] ;then
                ifo=`ip addr | grep 'inet ' | grep global`
                ifo=${ifo#*inet\ }
                nat_ip=${ifo%%/*}
        fi
        echo $nat_ip
}

# 检测网卡是否开启
is_up(){
        if [ -z `get_ip` ];then
                echo "网络已关闭"
        else
                echo "网络已开启"
        fi
}
get_ip=`get_ip`
get_nat_ip=`get_nat_ip`
get_up=`is_up`
get_type=`getprop gsm.network.type`
get_operator=`getprop gsm.operator.alpha`
get_dns1=`getprop net.dns1`
get_dns2=`getprop net.dns1`
echo "--------------------------"
echo "-外网ip: $get_ip		"
echo "-内网ip: $get_nat_ip	"
echo "-网络状态: $get_up        "
echo "-网络类型: $get_type      "
echo "-运营商: $get_operator    "
echo "-DNS1: $get_dns1          "
echo "-DNS2: $get_dns2          "
echo "--------------------------"
