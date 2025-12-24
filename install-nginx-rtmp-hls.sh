#!/bin/bash
set -e # Stop on error

# =========================================================
# Sarker Net - NGINX RTMP Adaptive Bitrate (FIXED)
# Location: /tmp/hls
# =========================================================

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
  echo "Please run as root (sudo ./install_fixed.sh)"
  exit
fi

echo "--- 1. Installing Dependencies ---"
apt-get update -y
apt-get install -y build-essential libpcre3 libpcre3-dev libssl-dev zlib1g-dev git ffmpeg curl

# Ensure www-data user exists
if ! id "www-data" &>/dev/null; then
    useradd -r -s /bin/false www-data
fi

echo "--- 2. Downloading Nginx & RTMP Module ---"
cd /tmp
rm -rf nginx-1.24.0 nginx-rtmp-module # Cleanup old
wget -q https://nginx.org/download/nginx-1.24.0.tar.gz
tar -zxf nginx-1.24.0.tar.gz
git clone https://github.com/arut/nginx-rtmp-module.git

echo "--- 3. Compiling Nginx ---"
cd nginx-1.24.0
./configure --prefix=/usr/local/nginx \
            --user=www-data \
            --group=www-data \
            --with-http_ssl_module \
            --add-module=../nginx-rtmp-module \
            --with-cc-opt="-Wno-error" # Prevent strict compiler errors

make
make install

echo "--- 4. Setting up Directories ---"
# Create HLS directory in /tmp (RAM)
mkdir -p /tmp/hls
chown -R www-data:www-data /tmp/hls
chmod 777 /tmp/hls

echo "--- 5. Configuring Nginx (nginx.conf) ---"
# We locate the ffmpeg binary to be safe
FFMPEG_BIN=$(which ffmpeg)

cat > /usr/local/nginx/conf/nginx.conf <<EOF
worker_processes  auto;
events {
    worker_connections  1024;
}

rtmp {
    server {
        listen 1935;
        chunk_size 4096;

        # INPUT APP: Push here (rtmp://ip/hls/streamname)
        application hls {
            live on;
            record off;

            # EXEC FFMPEG: Transcode to 3 Qualities
            # Note: This is one long command to prevent newline errors
            exec $FFMPEG_BIN -i rtmp://localhost/hls/\$name -async 1 -vsync -1 \
              -c:a aac -b:a 128k -c:v libx264 -b:v 2500k -f flv -g 60 -r 30 -s 1280x720 -preset superfast -profile:v baseline rtmp://localhost/abr/\$name_hi \
              -c:a aac -b:a 128k -c:v libx264 -b:v 1000k -f flv -g 60 -r 30 -s 854x480  -preset superfast -profile:v baseline rtmp://localhost/abr/\$name_mid \
              -c:a aac -b:a 64k  -c:v libx264 -b:v 600k  -f flv -g 60 -r 30 -s 426x240  -preset superfast -profile:v baseline rtmp://localhost/abr/\$name_low;
        }

        # OUTPUT APP: Internal use only (Generates HLS files)
        application abr {
            live on;
            hls on;
            hls_path /tmp/hls;
            hls_nested on;
            
            hls_fragment 4;
            hls_playlist_length 60;
            hls_cleanup on;

            # Master Playlist Variants
            hls_variant _hi  BANDWIDTH=2628000,RESOLUTION=1280x720;
            hls_variant _mid BANDWIDTH=1128000,RESOLUTION=854x480;
            hls_variant _low BANDWIDTH=664000,RESOLUTION=426x240;
        }
    }
}

http {
    include       mime.types;
    default_type  application/octet-stream;
    sendfile        on;
    keepalive_timeout  65;

    server {
        listen       80;
        server_name  localhost;

        # Playback URL: http://ip/hls/streamname.m3u8
        location /hls {
            # Disable Cache
            add_header Cache-Control no-cache;

            # CORS (Cross-Origin Resource Sharing)
            add_header 'Access-Control-Allow-Origin' '*' always;
            add_header 'Access-Control-Expose-Headers' 'Content-Length';

            if (\$request_method = 'OPTIONS') {
                add_header 'Access-Control-Allow-Origin' '*';
                add_header 'Access-Control-Max-Age' 1728000;
                add_header 'Content-Type' 'text/plain charset=UTF-8';
                add_header 'Content-Length' 0;
                return 204;
            }

            types {
                application/vnd.apple.mpegurl m3u8;
                video/mp2t ts;
            }
            alias /tmp/hls;
        }

        location / {
            root   html;
            index  index.html index.htm;
        }
    }
}
EOF

echo "--- 6. Creating System Service ---"
cat > /lib/systemd/system/nginx.service <<EOF
[Unit]
Description=The NGINX HTTP and reverse proxy server
After=syslog.target network-online.target remote-fs.target nss-lookup.target
Wants=network-online.target

[Service]
Type=forking
PIDFile=/usr/local/nginx/logs/nginx.pid
ExecStartPre=/usr/local/nginx/sbin/nginx -t
ExecStart=/usr/local/nginx/sbin/nginx
ExecReload=/usr/local/nginx/sbin/nginx -s reload
ExecStop=/bin/kill -s QUIT \$MAINPID
PrivateTmp=false 
# Note: PrivateTmp=false is needed so Nginx can write to /tmp/hls visible to others

[Install]
WantedBy=multi-user.target
EOF

echo "--- 7. Starting Nginx ---"
systemctl daemon-reload
# Stop any existing nginx first
systemctl stop nginx || true
systemctl enable nginx
systemctl start nginx

# Check status
if systemctl is-active --quiet nginx; then
    IP=$(curl -s ifconfig.me || hostname -I | awk '{print $1}')
    echo ""
    echo "✅ INSTALLATION SUCCESSFUL"
    echo "----------------------------------------------------"
    echo "1. Stream to OBS:"
    echo "   Server: rtmp://$IP:1935/hls"
    echo "   Key:    stream"
    echo ""
    echo "2. Watch in Player (VLC/Browser):"
    echo "   URL:    http://$IP/hls/stream.m3u8"
    echo "----------------------------------------------------"
else
    echo "❌ ERROR: Nginx failed to start. Check logs: cat /usr/local/nginx/logs/error.log"
fi
