#/!/bin/bash
echo "###########################"
echo "安装依赖"
sleep 2
pkg install curl wget perl make openssl* clang weechat -y
echo "###########################"
echo "安装cpanm"
sleep 2
curl http://share-10066126.cos.myqcloud.com/cpanm.pl|perl - App::cpanminus
echo "###########################"
echo "安装Mojo-webqq"
sleep 2
cpanm --mirror http://mirrors.163.com/cpan/ Mojo::Webqq
echo "###########################"
echo "安装插件"
sleep 2
cpanm --mirror http://mirrors.163.com/cpan/ Mojo::IRC::Server::Chinese
cpanm --mirror http://mirrors.163.com/cpan/ Webqq::Encryption
echo "###########################"
echo "安装完成"
echo "最后在附送一个启动示例脚本"
wget http://funs.ml/file/webqq.pl
echo "文件webqq.pl下载完成"
echo "###########################"
