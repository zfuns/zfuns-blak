title: Termux安装jekyll和hexo
date: 2017-4-18
categories: Termux
tags: Termux
---

### 安装jekyll
```
 apt install ruby-dev libffi-dev clang make    
 gem install jekyll   
 gem install rdiscount   
 gem install bundler   
 jekyll new blog   
 cd blog   
 jekyll serve   
```

### 安装hexo   
```
 apt install git nodejs   
 npm install -g hexo   
 mkdir blog   
 cd blog   
 hexo init   
 hexo s -g   
```
    
