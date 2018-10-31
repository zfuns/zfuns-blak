#!/data/data/com.termux/files/usr/bin/env perl
use Mojo::Webqq;
my $client = Mojo::Webqq->new();
$client->load("ShowMsg");
$client->load('UploadQRcode'); #上传二维码
$client->load("IRCShell"); #irc服务
$client->load("ZiYue"); #子曰
$client->load("ProgramCode"); #执行编程代码
$client->load("SmartReply",data=>{
		apikey	=> '4c53b48522ac4efdfe5dfb4f6149ae51', #可选，参考http://www.tuling123.com/html/doc/apikey.html 
		friend_reply    => 1, #是否针对好友消息智能回复
		group_reply     => 1, #是否针对群消息智能回复
		notice_reply    => ["对不起，请不要这么频繁的艾特我","对不起，您的艾特次数太多"], #可选，提醒时用语
		notice_limit    => 8 ,  #可选，达到该次数提醒对话次数太多，提醒语来自默认或 notice_reply
		warn_limit      => 60,  #可选,达到该次数，会被警告
		ban_limit       => 70,  #可选,达到该次数会被列入黑名单不再进行回复
		ban_time        => 60,#可选，拉入黑名单时间，默认1200秒
		period          => 600, #可选，限制周期，单位 秒
		is_need_at      => 1,  #默认是1 是否需要艾特才触发回复 仅针对群消息
		keyword         => [qw(Test)], #触发智能回复的关键字
});
$client->run();
