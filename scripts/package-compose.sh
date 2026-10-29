#!/usr/bin/env bash
# Build the compose deploy archive for one release.
# The archive pins the image tag and has no build context, so a server can
# unpack it and run `docker compose up -d` without this repository.
set -euo pipefail

version=${1:?usage: package-compose.sh <version> [image]}
root=$(cd "$(dirname "$0")/.." && pwd)
image=${2:-ghcr.io/annihilater/unfairplay-bot:$version}
name=unfairplay-bot-$version
stage=$root/dist/$name
archive=$root/dist/${name}-compose.tar.gz

rm -rf "$stage"
mkdir -p "$stage"

awk -v image="$image" '
	/^    build: \.$/ { next }
	/^    image: / { print "    image: " image; next }
	{ print }
' "$root/compose.yaml" > "$stage/compose.yaml"

grep -q -F "image: $image" "$stage/compose.yaml"
if grep -q '^    build:' "$stage/compose.yaml"; then
	echo "release compose still has a build key" >&2
	exit 1
fi

cp "$root/.env.example" "$stage/.env.example"

cat > "$stage/DEPLOY.md" <<EOF
# unfairplay-bot $version

镜像：\`$image\`

这个目录是该版本的部署包。镜像在 GHCR 上，不在压缩包里。\`docker compose up\` 会拉取上面这个标签。

\`\`\`sh
cp .env.example .env            # 填入必填项
mkdir -p data ipatool cache secrets/models canary
cp /path/to/your-model.bin secrets/models/
sudo chown -R 10001:10001 data ipatool cache secrets
sudo chmod 700 secrets/models && sudo chmod 600 secrets/models/*.bin
docker compose up -d
\`\`\`

若拉取镜像被拒绝，把 GitHub Packages 里的 \`unfairplay-bot\` 设为公开，或在服务器上 \`docker login ghcr.io\`。

升级时保留 \`.env\`、\`data/\`、\`ipatool/\`、\`cache/\`、\`secrets/\`、\`canary/\`，用新版本部署包里的 \`compose.yaml\` 换掉这一份，然后：

\`\`\`sh
docker compose pull && docker compose up -d
\`\`\`

登录之后不要改 \`compose.yaml\` 里的 MAC 地址。两步验证账号启动后给机器人发 \`/login\`，或执行：

\`\`\`sh
docker compose exec -it bot ipatool auth login --email you@example.com \\
  --keychain-passphrase "\$UNFAIRPLAY_BOT_KEYCHAIN_PASSPHRASE"
\`\`\`
EOF

rm -f "$archive"
tar -C "$root/dist" -czf "$archive" "$name"
echo "$archive"
