Put vless links into one file
```sh
mkdir -p /var/www/fake/sub/xK9mP2qR7vL4/
cat /root/xray/sub-kamil | base64 -w 0 > /var/www/fake/sub/xK9mP2qR7vL4/sub-kamil
```
Change the nginx config
```sh
vim /etc/nginx/sites-available/fake
```
```
server {
    listen 127.0.0.1:8443 ssl;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    set_real_ip_from 127.0.0.1;
    real_ip_header proxy_protocol;

    root /var/www/fake;
    index index.html;

    location /sub/ {
        default_type text/plain;
    }
}
```
Restart the nginx
```sh
nginx -t && systemctl restart nginx
```
Link
```
https://$DOMAIN/sub/xK9mP2qR7vL4/sub-kamil
```
