FROM nginx

RUN openssl dhparam -out /etc/nginx/dhparam.pem 2048

COPY 90-dummy-cert.sh /docker-entrypoint.d
COPY 99-generate-nginx-conf.sh /docker-entrypoint.d

COPY nginx.conf.template /etc/nginx/nginx.conf.template
