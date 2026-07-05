#!/bin/bash
set -euo pipefail

REPO_NAME="$1"

REPO="${DEPLOY_REPOS_LOCATION:-$HOME/repos}/${REPO_NAME}.git"
WORK="$(mktemp -d)"
DEFAULT_BRANCH="main"
NGINX_CERTS_DIR="/etc/nginx/certs"

cleanup() {
  rm -rf "$WORK"
}
trap cleanup EXIT

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }
}

parse_deploy_toml() {
  local file="deploy.toml"
  local _q='yq -p toml -oy -r'

  APP_NAME="$($_q '.name'                          "$file")"
  APP_TYPE="$($_q '.type'                          "$file")"
  APP_HOST="$($_q '.hosts // [] | join(" ")'       "$file")"
  APP_PORT="$($_q '.port  // ""'                   "$file")"
  BUILD_CMD="$($_q '.build.command           // ""'           "$file")"
  BUILD_OUT="$($_q '.build.build_location   // "./"'         "$file")"
  DOCKERFILE="$($_q '.build.dockerfile_path // "Dockerfile"' "$file")"
  # newline-separated list of "host_path:container_path" strings, or empty
  APP_VOLUMES="$($_q '.build.docker_volumes // [] | .[]' "$file" 2>/dev/null || true)"
  SERVE_DIR="/var/www/${APP_NAME}"

  [[ -z "$APP_NAME" || "$APP_NAME" == "null" ]] && { echo "deploy.toml: 'name' is required" >&2; exit 1; }
  [[ -z "$APP_TYPE" || "$APP_TYPE" == "null" ]] && { echo "deploy.toml: 'type' is required" >&2; exit 1; }
  [[ "$APP_HOST" == "null" ]] && APP_HOST=""
  [[ "$APP_PORT" == "null" ]] && APP_PORT=""
  [[ "$BUILD_CMD"   == "null" ]] && BUILD_CMD=""
  [[ "$BUILD_OUT"   == "null" ]] && BUILD_OUT="./"
  [[ "$DOCKERFILE"  == "null" ]] && DOCKERFILE="Dockerfile"
  [[ "$APP_VOLUMES" == "null" ]] && APP_VOLUMES=""
  return 0
}

cert_domain_from_host() {
  local host="$1"
  local -a parts
  local count
  IFS='.' read -r -a parts <<< "$host"
  count="${#parts[@]}"

  if (( count >= 2 )); then
    printf '%s.%s\n' "${parts[count - 2]}" "${parts[count - 1]}"
  else
    printf '%s\n' "$host"
  fi
}

write_nginx_config() {
  local CONF="/etc/nginx/conf.d/${APP_NAME}.conf"
  local FIRST_HOST="${APP_HOST%% *}"
  local CERT_DOMAIN

  [[ -z "$FIRST_HOST" ]] && { echo "deploy.toml: 'hosts' is required" >&2; exit 1; }

  CERT_DOMAIN="$(cert_domain_from_host "$FIRST_HOST")"
  
  local CERT_DIR="${NGINX_CERTS_DIR}/${CERT_DOMAIN}"

  local SSL_LINES="
    listen 443 ssl;
    ssl_certificate     ${CERT_DIR}/fullchain.cer;
    ssl_certificate_key ${CERT_DIR}/${CERT_DOMAIN}.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_dhparam         ${CERT_DIR}/dhparam.pem;"

  local REDIRECT_BLOCK="
server {
    listen 80;
    server_name ${APP_HOST};
    return 301 https://\$host\$request_uri;
}"

  if [[ "$APP_TYPE" == "static" ]]; then
    sudo tee "$CONF" > /dev/null <<EOF
${REDIRECT_BLOCK}

server {
    ${SSL_LINES}
    server_name ${APP_HOST};

    root ${SERVE_DIR};
    index index.html;
    location / { try_files \$uri \$uri/ /index.html; }
}
EOF

  elif [[ "$APP_TYPE" == "proxy" ]]; then
    sudo tee "$CONF" > /dev/null <<EOF
${REDIRECT_BLOCK}

server {
    ${SSL_LINES}
    server_name ${APP_HOST};

    location / {
        proxy_pass http://127.0.0.1:${APP_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
  fi

  sudo nginx -t
}

require_cmd git
require_cmd rsync
require_cmd docker
require_cmd yq

while read -r oldrev newrev ref; do
  BRANCH="${ref#refs/heads/}"
  [[ "$BRANCH" != "$DEFAULT_BRANCH" ]] && continue

  echo "▶ Deploying ${REPO_NAME} from ${BRANCH}..."

  # git archive avoids ref writes, which are forbidden in the pre-receive quarantine environment
  git --git-dir="$REPO" archive "$newrev" | tar -x -C "$WORK"
 
  cd "$WORK"

  if [[ ! -f deploy.toml ]]; then
    echo "deploy.toml missing in repo root" >&2
    exit 1
  fi

  parse_deploy_toml

  case "$APP_TYPE" in
    static)
      sudo mkdir -p "$SERVE_DIR"
      
      [[ -n "$BUILD_CMD" ]] && eval "$BUILD_CMD"
      
      sudo rsync -a --delete "${BUILD_OUT%/}/" "${SERVE_DIR}/"
      sudo chmod 755 "$SERVE_DIR"

      # Fedora/RHEL: nginx needs httpd_sys_content_t; restorecon alone is not
      # enough until semanage defines a file context for this path.
      if command -v restorecon >/dev/null 2>&1; then
        if command -v semanage >/dev/null 2>&1; then
          sudo semanage fcontext -a -t httpd_sys_content_t "${SERVE_DIR}(/.*)?" 2>/dev/null \
            || sudo semanage fcontext -m -t httpd_sys_content_t "${SERVE_DIR}(/.*)?" 2>/dev/null \
            || true
        fi
        sudo restorecon -Rv "$SERVE_DIR" 2>/dev/null || true
      fi

      write_nginx_config
      
      sudo systemctl reload nginx
      ;;

    proxy)
      [[ -z "$APP_HOST" ]] && { echo "deploy.toml: 'hosts' is required for type=proxy" >&2; exit 1; }
      [[ -z "$APP_PORT" ]] && { echo "deploy.toml: 'port' is required for type=proxy" >&2; exit 1; }

      sudo docker build -f "$DOCKERFILE" -t "${APP_NAME}:latest" .

      # Build -v flags from volumes declared in deploy.toml
      VOLUME_FLAGS=()
      if [[ -n "$APP_VOLUMES" ]]; then
        while IFS= read -r vol; do
          [[ -z "$vol" ]] && continue
          host_path="${vol%%:*}"
          sudo mkdir -p "$host_path"
          VOLUME_FLAGS+=(-v "$vol")
        done <<< "$APP_VOLUMES"
      fi

      # Bind ONLY to localhost — not exposed to internet directly
      sudo docker rm -f "$APP_NAME" 2>/dev/null || true
      
      sudo docker run -d \
        --name "$APP_NAME" \
        --restart unless-stopped \
        -p "127.0.0.1:${APP_PORT}:${APP_PORT}" \
        "${VOLUME_FLAGS[@]+"${VOLUME_FLAGS[@]}"}" \
        "${APP_NAME}:latest"

      write_nginx_config
      
      sudo systemctl reload nginx
      ;;

    *)
      echo "deploy.toml: unknown type '${APP_TYPE}'" >&2
      exit 1
      ;;
  esac

  echo "✓ ${APP_NAME} deployed."
done
