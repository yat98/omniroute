# OmniRoute Docker — WSL persistence + Live WebSocket

Target proyek:

```text
/home/yat/development/tools/omniroute
```

Database persisten:

```text
/home/yat/development/tools/omniroute/data/storage.sqlite
```

## Instalasi

```bash
cd /home/yat/development/tools/omniroute
cp .env.example .env
nano .env
```

Ganti semua `CHANGE_ME`, kemudian:

```bash
chmod +x install-omniroute-docker.sh
./install-omniroute-docker.sh
```

Dashboard:

```text
http://localhost:2229
```

WebSocket:

```text
ws://localhost:22231/live-ws
```

## Pemeriksaan cepat

```bash
docker inspect omniroute \
  --format '{{range .Mounts}}{{println .Type "|" .Source "->" .Destination}}{{end}}'

docker logs omniroute 2>&1 | grep -iE 'LiveWS|WebSocket'

ls -lah /home/yat/development/tools/omniroute/data/storage.sqlite
```

Mount yang benar:

```text
bind | /home/yat/development/tools/omniroute/data -> /app/data
```
