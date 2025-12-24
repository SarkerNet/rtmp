#!/bin/bash
# install-nginx-rtmp-hls-multiquality.sh
# Script to install NGINX with RTMP module and configure multi-quality HLS outputs on port 80

set -e

# Update system
sudo apt update && sudo apt upgrade -y

# Install dependencies
sudo apt install -y build-essential libpcre3 libpcre3-dev libssl-dev ffmpeg git wget unzip

# Download NGINX and RTMP module
NGINX_VERSION=1.25.5
RTMP_MODULE=https://github.com/arut/nginx-rtmp-module.git

wget http://nginx.org/download/nginx-$NGINX_VERSION.tar.gz
tar -zxvf nginx-$NGINX_VERSION.tar.gz
git clone $RTMP_MODULE

# Build NGINX with RTMP
cd nginx-$NGINX_VERSION
./configure --with-http_ssl_module --add-module=../nginx-rtmp-module
make
sudo make install

# Create NGINX config with multi-quality HLS
sudo tee /usr/local/nginx/conf/nginx.conf > /dev/null <<'EOF'
worker_processes  auto;
events { worker_connections 1024; }

rtmp {
    server {
        listen 1935;
        chunk_size 4096;

        application live {
            live on;
            record off;

            # Transcode into multiple qualities
            exec ffmpeg -i rtmp://localhost/live/$name
                -c:v libx264 -preset veryfast -tune zerolatency -c:a aac -strict -2 -s 1920x1080 -f flv rtmp://localhost/hls/$name_1080
                -c:v libx264 -preset veryfast -tune zerolatency -c:a aac -strict -2 -s 1280x720  -f flv rtmp://localhost/hls/$name_720
                -c:v libx264 -preset veryfast -tune zerolatency -c:a aac -strict -2 -s 854x480   -f flv rtmp://localhost/hls/$name_480;
        }

        application hls {
            live on;
            hls on;
            hls_path /usr/local/nginx/html/hls;
            hls_fragment 3;
            hls_playlist_length 10;
        }
    }
}

http {
    server {
        listen 80;

        location / {
            root /usr/local/nginx/html;
        }

        location /hls {
            types {
                application/vnd.apple.mpegurl m3u8;
                video/mp2t ts;
            }
            root /usr/local/nginx/html;
            add_header Cache-Control no-cache;
        }
    }
}
EOF

# Create HLS directory
sudo mkdir -p /usr/local/nginx/html/hls
sudo chmod -R 755 /usr/local/nginx/html

# Example master playlist generator
STREAMKEY="streamkey"
sudo tee /usr/local/nginx/html/hls/${STREAMKEY}.m3u8 > /dev/null <<EOF
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080
${STREAMKEY}_1080.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=1280x720
${STREAMKEY}_720.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=1500000,RESOLUTION=854x480
${STREAMKEY}_480.m3u8
EOF

# Start NGINX
sudo /usr/local/nginx/sbin/nginx

echo "✅ NGINX with RTMP + multi-quality HLS installed and running!"
echo "Stream ingest: rtmp://your-server/live/streamkey"
echo "Adaptive HLS playback: http://your-server/hls/streamkey.m3u8"
