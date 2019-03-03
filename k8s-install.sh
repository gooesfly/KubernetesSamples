#!/usr/bin/env bash
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

kube_ver=1.13.3
calico_ver=3.5
tiller_ver=2.13.0
docker_compose_ver=1.23.2
docker_compose_folder="/usr/local/bin/docker-compose"

Green_font_prefix="\033[32m" && Red_font_prefix="\033[31m" && Green_background_prefix="\033[42;37m" && Red_background_prefix="\033[41;37m" && Font_color_suffix="\033[0m"
Info="${Green_font_prefix}[信息]${Font_color_suffix}"
Error="${Red_font_prefix}[错误]${Font_color_suffix}"
Tip="${Green_font_prefix}[注意]${Font_color_suffix}"

host_name="$HOSTNAME"

docker_folder="/usr/bin/docker"
show_msg="/dev/null"

install_type="master"
is_install_dc="n"
master_ip=""
init_token=""
init_hash=""

kubeadm_folder="/usr/bin/kubeadm"
kubelet_folder="/usr/bin/kubelet"
kubectl_folder="/usr/bin/kubectl"

network_cidr="192.168.0.0/16"

# 检查是否为root用户
check_root(){
    [[ $EUID != 0 ]] && echo -e "${Error} 当前账号非ROOT(或没有ROOT权限)，无法继续操作，请使用${Green_background_prefix} sudo su ${Font_color_suffix}来获取临时ROOT权限（执行后会提示输入当前账号的密码）。" && exit 1
}

# 检查是否已安装docker
check_docker(){
#docker -v
#if [ $? -ne 0 ]; then
    if [ -e ${docker_folder} ]; then
            echo -e "${Info} docker 已安装，执行下一步。"
        else
            echo -e "${Info} docker 未安装，开始安装..."
            install_docker
        if [ $? -ne 0 ]; then
            echo -e "${Error} 安装 docker 失败。"
            exit 1
        fi
    fi
}

# 安装docker
install_docker(){
    echo -e "${Info} yum 已更新完毕，开始安装依赖..."
    install_dependences    
    echo -e "${Info} 依赖已安装完毕，开始配置 docker-ce 安装源.."
    config_install_source
    echo -e "${Info} docker-ce 安装源已配置完毕，开始安装..."
    #yum makecache fast
    yum install -y docker-ce > $show_msg
    echo -e "${Info} docker-ce 已安装完毕"
    mkdir -p /etc/docker
    tee /etc/docker/daemon.jso > $show_msg <<EOF
{
    "registry-mirrors": [
        "https://m0livmqr.mirror.aliyuncs.com",
        "https://mirror.ccs.tencentyun.com",
        "https://docker.mirrors.ustc.edu.cn",
        "https://registry.docker-cn.com"
    ]
}
EOF
    systemctl enable docker > $show_msg
    systemctl daemon-reload > $show_msg
    systemctl restart docker > $show_msg
    echo -e "${Info} docker-ce 已启动完毕"
}

install_docker_compose(){
    if [ -e ${docker_compose_folder} ]; then
        echo -e "${Info} docker-compose 已安装，执行下一步。"
    else
        echo -e "${Info} docker-compose 未安装，开始安装..."
        curl -L https://github.com/docker/compose/releases/download/${docker_compose_ver}/docker-compose-`uname -s`-`uname -m` -o ${docker_compose_folder}
        if [ $? -ne 0 ]; then
            echo -e "${Error} docker-compose 安装失败。"
            exit 1
        fi
        echo -e "${Info} docker-compose 安装成功。"
    fi
    chmod +x ${docker_compose_folder}
}

# 更新yum
update_yum(){
    yum update -y > $show_msg
    if [ $? -ne 0 ]; then
        echo -e "${Error} yum 更新失败。"
        exit 1
    fi
}

# 安装依赖
install_dependences(){
    yum install -y yum-utils \
        device-mapper-persistent-data \
        lvm2 > $show_msg
    if [ $? -ne 0 ]; then
        echo -e "${Error} 安装依赖失败。"
        exit 1
    fi
}

# 配置安装源
config_install_source(){
    yum-config-manager \
        --add-repo \
        https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo \
    && yum-config-manager --enable docker-ce-edge > $show_msg
    #备用安装源
    #https://mirrors.cloud.tencent.com/docker-ce/linux/centos/docker-ce.repo \
    #https://mirrors.ustc.edu.cn/docker-ce/linux/centos/docker-ce.repo \
    if [ $? -ne 0 ]; then
        echo -e "${Error} 配置安装源失败。"
        exit 1
    fi
}

# 修改设置
check_setting(){
    swap_size=$(free -m | grep Swap | awk '{ print $2}')
    if [ ${swap_size} != "0" ]; then
        echo -e "${Info} Swap 未关闭，开始关闭..."
        swapoff -a
        sed -i 's/.*swap.*/#&/' /etc/fstab
    else
        echo -e "${Info} Swap 已关闭，执行下一步。"
    fi
    if [ -e "/etc/sysctl.d/k8s.conf" ]; then
        echo -e "${Info} 设置已修改，执行下一步。"
    else
        echo -e "${Info} 设置未修改，开始修改..."
        change_setting
    fi
}
# 修改设置
change_setting(){
    systemctl stop firewalld > $show_msg
    systemctl disable firewalld > $show_msg
    cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_nonlocal_bind = 1
net.ipv4.ip_forward = 1
vm.swappiness=0
EOF
    sysctl --system > $show_msg
    cat > /etc/sysconfig/modules/ipvs.modules <<EOF
#!/bin/bash
modprobe -- ip_vs
modprobe -- ip_vs_rr
modprobe -- ip_vs_wrr
modprobe -- ip_vs_sh
modprobe -- nf_conntrack_ipv4
EOF
    chmod 755 /etc/sysconfig/modules/ipvs.modules && bash /etc/sysconfig/modules/ipvs.modules && lsmod | grep -e ip_vs -e nf_conntrack_ipv4 > $show_msg
    echo -e "${Info} centos 配置已修改"
}

Install_Master(){
    install_type="master"
    Install_DC
    Init_Cidr
}
Init_Cidr(){
    echo && read -e -p "Network Cidr ?[默认:192.168.0.0/16]：" cidr
    if [[ -e ${cidr} ]]; then
        network_cidr="${cidr}"
    fi
}

Install_Cluster(){
    install_type="cluster"
    Install_DC
    echo && read -e -p "Master IP:Port ?：" m_ip
    master_ip="${m_ip}"
    echo && read -e -p "Init Token ?：" m_token
    init_token="${m_token}"
    echo && read -e -p "Init Hash ?：" m_hash
    init_hash="${m_hash}"
}
Install_DC(){
    echo && read -e -p "是否安装 docker-compose ?[y/N]：" ins_dc
    if [[ ${ins_dc} == [Yy] ]]; then
        is_install_dc="y"
    fi
}

check_kube3(){
    if [ -e ${kubelet_folder} ] && [ -e ${kubeadm_folder} ] && [ -e ${kubectl_folder} ]; then
        echo -e "${Info} kubelet kubeadm kubectl 已安装，执行下一步。"
    else
        echo -e "${Info} kubelet kubeadm kubectl 开始安装..."
        cat > /etc/yum.repos.d/kubrenetes.repo << EOF
[kubernetes]
name=Kubernetes Repo
baseurl=https://mirrors.aliyun.com/kubernetes/yum/repos/kubernetes-el7-x86_64/
gpgcheck=0
gpgkey=https://mirrors.aliyun.com/kubernetes/yum/doc/yum-key.gpg
EOF
        yum install -y kubelet kubeadm kubectl
        if [ $? -ne 0 ]; then
            echo -e "${Error} kubelet kubeadm kubectl 安装失败。"
            exit 1
        fi
        systemctl enable kubelet && systemctl start kubelet
        echo -e "${Info} kubelet kubeadm kubectl 安装成功。"
    fi
}

init_master(){
    kubectl get node > $show_msg
    if [ $? -ne 0 ]; then
        echo -e "${Info} Master 初始化中..."
        kubeadm init \
            --image-repository registry.aliyuncs.com/google_containers \
            --pod-network-cidr=${network_cidr} \
            --ignore-preflight-errors=cri \
            --kubernetes-version=${kube_ver} > $show_msg
        if [ $? -ne 0 ]; then
            echo -e "${Error} kubeadm init 失败。"
            exit 1
        fi
        mkdir -p $HOME/.kube
        sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
        sudo chown $(id -u):$(id -g) $HOME/.kube/config
        kubectl taint nodes --all node-role.kubernetes.io/master-
        echo -e "${Info} Master 初始化成功。"
    else
        echo -e "${Info} Master 已存在，执行下一步。"
    fi
}

init_network(){
    echo -e "${Info} 初始化 Kubernets 网络插件..."
    kubectl apply -f https://docs.projectcalico.org/v${calico_ver}/getting-started/kubernetes/installation/hosted/etcd.yaml > $show_msg
    kubectl apply -f https://docs.projectcalico.org/v${calico_ver}/getting-started/kubernetes/installation/hosted/calico.yaml > $show_msg
    echo -e "${Info} 初始化 Kubernets 网络插件成功。"
}

# init_helm(){
#     echo -e "${Info} 初始化 Helm 。"
#     curl https://raw.githubusercontent.com/helm/helm/master/scripts/get | bash
#     helm init --upgrade --tiller-image registry.cn-hangzhou.aliyuncs.com/google_containers/tiller:v${tiller_ver} --stable-repo-url https://kubernetes.oss-cn-hangzhou.aliyuncs.com/charts
#     helm repo update
#     kubectl create serviceaccount --namespace kube-system tiller
#     kubectl create clusterrolebinding tiller-cluster-rule --clusterrole=cluster-admin --serviceaccount=kube-system:tiller
#     kubectl patch deploy --namespace kube-system tiller-deploy -p '{"spec":{"template":{"spec":{"serviceAccount":"tiller"}}}}'
# }

init_cluster(){
    echo -e "${Info} Cluster 初始化中..."
    kubeadm join ${master_ip} --token ${init_token} --discovery-token-ca-cert-hash ${init_hash}
    if [ $? -ne 0 ]; then
        echo -e "${Error} Cluster 初始化失败。"
        exit 1
    fi
    echo -e "${Info} Cluster 初始化完成。"
}

init_config(){    
    check_root    
    echo -e "  请选择
        1. 安装为 Master
        2. 安装为 Cluster"
    echo && read -e -p "[1-2]：" num
    case "$num" in
        1)
        Install_Master
        ;;
        2)
        Install_Cluster
        ;;
        *)
        echo -e "${Error} 请输入正确的数字 [1-2]" && exit 1
        ;;
    esac
    echo && read -e -p "是否显示安装信息 ?[y/N]：" is_show
    if [[ ${is_show} == [Yy] ]]; then
        show_msg="/dev/tty"
    fi
}

# 初始化
init_config

# 开始执行脚本
echo -e "${Info} yum 准备开始更新..."
update_yum
check_docker
if [[ ${is_install_dc} == [Yy] ]]; then
    install_docker_compose
fi
check_setting
check_kube3
if [ ${install_type} == "master" ]; then
    init_master
    init_network
    # init_helm
elif [ ${install_type} == "cluster" ]; then
    init_cluster
fi