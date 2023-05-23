
FROM ubuntu:20.04


ENV DEBIAN_FRONTEND noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends apt-utils
RUN apt-get -y install inotify-tools ca-certificates curl gnupg

RUN install -m 0755 -d /etc/apt/keyrings
RUN curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
RUN chmod a+r /etc/apt/keyrings/docker.gpg
RUN echo \
  "deb [arch="$(dpkg --print-architecture)" signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  "$(. /etc/os-release && echo "$VERSION_CODENAME")" stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null
RUN apt-get update && apt-get -y install docker-ce-cli

RUN    echo "deb-src http://archive.ubuntu.com/ubuntu bionic main" >> /etc/apt/sources.list
RUN    sed 's/main$/main universe/' -i /etc/apt/sources.list
RUN    apt-get update
RUN    apt-get upgrade -y
RUN    apt-get -y install wget vim git libpq-dev tcpdump lua5.1 liblua5.1-dev unzip

# Openresty (Nginx)
RUN  apt-get -y build-dep nginx \
  && apt-get -q -y clean && rm -rf /var/cache/apt/archives/* /var/lib/apt/lists/*
RUN  wget https://openresty.org/download/openresty-1.19.3.2.tar.gz \
  && tar zxvf openresty-1.19.3.2.tar.gz \
  && wget https://github.com/Kong/kong-build-tools/archive/master.tar.gz \
  && tar zvfx master.tar.gz \
  && cd openresty-1.19.3.2/bundle \
  && for i in ../../kong-build-tools-master/openresty-patches/patches/1.19.3.2/*.patch; do patch -p1 < $i; done \
  && cd ../ \
  && ./configure --with-luajit  --with-http_addition_module --with-http_dav_module --with-http_geoip_module --with-http_gzip_static_module --with-http_image_filter_module --with-http_realip_module --with-http_stub_status_module --with-http_ssl_module --with-http_sub_module --with-http_xslt_module --with-ipv6 --with-http_postgres_module --with-pcre-jit \
  && make \
  && make install


ENV PATH $PATH:/usr/local/openresty/nginx/sbin
RUN ln -s /usr/local/openresty/nginx/sbin/nginx /usr/sbin/nginx
COPY ./reload_nginx.sh /usr/local/openresty/bin/nginxReloader.sh
COPY ./docker-entrypoint.sh /usr/local/openresty/bin/docker-entrypoint.sh


RUN wget https://luarocks.org/releases/luarocks-3.3.1.tar.gz
RUN tar zxpf luarocks-3.3.1.tar.gz && cd luarocks-3.3.1 && ./configure && make && make install
RUN luarocks install busted
RUN luarocks install inspect
RUN luarocks install lua-resty-openssl

RUN chmod +x /usr/local/openresty/bin/nginxReloader.sh
RUN chmod +x /usr/local/openresty/bin/docker-entrypoint.sh

WORKDIR /usr/local/lib/lua/lua-resty-kafka

ENTRYPOINT [ "/usr/local/openresty/bin/docker-entrypoint.sh" ]
CMD ["/usr/local/openresty/bin/openresty", "-g", "daemon off;"]