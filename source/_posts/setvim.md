title: 设置vim显示行号
date: 2017-03-02
categories: Termux
tags: Termux
---
有时候我们需要在vim中显示行号，但是vim默认是不显示行号的，我们可以进行如下操作:   

第一种：   
按esc进入末行模式，输入命令`:set nu`   
取消显示是`:set nonu`   

第二种：永久显示的方法是修改配置文件：   
输入命令：`vim ~/.vimrc`   
打开后添加`set nu`，保存退出，再次进入vim编辑器，就会自动显示行号了！   
