# `gitpush`

My workflow for deploying personal projects to my VPS.

The goal is intentionally simple: Deploy with a `git push`, like on Heroku.

How it works: 
- Push a repo to a bare Git remote on my VPS (Fedora, but you can adjust for your own distro).
- A tiny `pre-receive` hook delegates to the shared `deploy.sh`, which builds only pushes to `main`.
- Configurations live in the repo.
- `type="static"` apps are synced to `/var/www/<name>` and served by host NGINX.
- `type="proxy"` apps run as Docker containers bound to `127.0.0.1:<port>`, with host NGINX proxying traffic to them.
- Failed builds reject the push.
- No hosted PaaS, no dashboards, no per-app systemd units. 

## Set it up for yourself

0. Install the required tools:

   - Git
   - NGINX
   - rsync
   - Docker
   - [yq](https://github.com/mikefarah/yq/)

	You will require SSH access to your VPS.

	Setup compatible NGINX on your VPS using the [NGINX Setup](#nginx-setup) section.

1. Move `deploy.sh` to your VPS.

2. Configure the Git templates directory:

	```bash
	mkdir -p ~/.config/git/template/hooks
	git config --global init.templateDir "~/.config/git/template"
	```

3. Create the Git `pre-receive` template:

	```bash
	cat > ~/.config/git/template/hooks/pre-receive <<'EOF'
	#!/bin/bash
	
	# Don't forget to change /path/to/deploy.sh
	exec /path/to/deploy.sh "$(basename $(pwd) .git)" "$@"
	
	EOF
	chmod +x ~/.config/git/template/hooks/pre-receive
	```

4. Create a bare Git repo on the VPS that will receive your `git push` requests:

	Note: `deploy.sh` expects all repositories to be created in `$HOME/repos`. You can set the `DEPLOY_REPOS_LOCATION` env var on your VPS to change that.

	```bash
	git init --bare /path/to/repos/repository-name.git
	```

	If the previous step was successful, you'll see `hooks/pre-receive` be automatically created in every repo you init.

5. Add the VPS repository as a remote repository:

	```bash
	git remote add vps username@VPS_IP:/path/to/repos/repository-name.git
	```

	Remember: You need an SSH key setup in `~/.ssh` for `username` at `VPS_IP`.

	You can simplify this by adding a sshd config:
	```
	# ~/.ssh/config
	Host vps
        Hostname VPS_IP
		User username
        IdentityFile /path/to/key/file
        IdentitiesOnly yes
	```

	Which will allow you to change the remote to:
	```bash
	git remote add vps vps:/path/to/repos/repository-name.git
	```

6. Now create a config file `deploy.toml` in the repository. Refer to `sample.proxy.toml` or `sample.static.toml` to see supported configurations. Remember that the config file should also be committed to the repo!

7. `git push vps localbranch:main`

## NGINX Setup

Notes:

- `deploy.sh` expects the universal NGINX convention for configurations where every config file with a `.conf` extension in `/etc/nginx/conf.d/` is loaded by default.
- It writes HTTPS NGINX configs using the first hostname in `hosts`.
- Set up certs on your VPS (Follow [my TLS setup](#my-tls-setup) if you like). The script expects certs for NGINX `server_name` values to be in `/etc/nginx/certs/server_name_dir/*`. Don't forget to generate a `dhparam.pem` for every domain.
- It determines the `server_name_dir` using the first value from the `hosts` setting in your `.toml` config file. It drops the subdomain and uses the remaining domain as the cert directory.
  
  For example, for `hosts=["www.example.com","example.com"]` it expects the files:

	```text
	/etc/nginx/certs/example.com/fullchain.cer
	/etc/nginx/certs/example.com/example.com.key
	/etc/nginx/certs/example.com/dhparam.pem
	```

### My TLS setup


For `shashank.gg`, create the cert directory and DH params:

```bash
sudo mkdir -p /etc/nginx/certs/shashank.gg
sudo openssl dhparam -out /etc/nginx/certs/shashank.gg/dhparam.pem 2048
sudo chown -R kaulsh:kaulsh /etc/nginx/certs
```

Install `acme.sh`:
```bash
curl https://get.acme.sh | sh -s email=my@example.com
```

Issue the cert:
```bash
# Change `--dns <>` based on where your domain is hosted.
# DNS Provider Reference: https://github.com/acmesh-official/acme.sh/wiki/dnsapi
acme.sh --issue --dns dns_dgon -d shashank.gg -d *.shashank.gg
```

Install the certificate into the required directory:

```bash
acme.sh --install-cert -d shashank.gg -d '*.shashank.gg' \
  --cert-file      /etc/nginx/certs/shashank.gg/cert.cer \
  --key-file       /etc/nginx/certs/shashank.gg/shashank.gg.key \
  --fullchain-file /etc/nginx/certs/shashank.gg/fullchain.cer \
  --reloadcmd      "sudo systemctl reload nginx"
```

The wildcard cert covers `shashank.gg` and future subdomains like `app.shashank.gg`. You still need DNS records pointing each host to the VPS.

## What `deploy.sh` Generates

For every deployed app, `deploy.sh` writes an NGINX config to:

```text
/etc/nginx/conf.d/<name>.conf
```

For static apps, NGINX serves `/var/www/<name>` and falls back to `index.html`, which works well for SPAs:

```nginx
location / { try_files $uri $uri/ /index.html; }
```

For proxy apps, NGINX forwards requests to the local Docker-bound port:

```nginx
proxy_pass http://127.0.0.1:<port>;
```

The script runs `sudo nginx -t` before reloading NGINX. If the generated config is invalid, the push is rejected.

## Notes And Gotchas

- Sudo Permissions: The Git hook runs as the SSH user, but deploys need to write NGINX configs, copy files to `/var/www`, manage Docker containers, and reload NGINX. For a personal VPS, the simplest approach is to make your user a sudoer. A stricter setup can allow only the commands used by `deploy.sh`, such as `mkdir`, `rsync`, `restorecon`, `tee`, `nginx -t`, `systemctl reload nginx`, and `docker`.

- Only pushes to `main` deploy. Other branches are ignored.

- `deploy.toml` is required in the repo root. Missing or invalid config rejects the push.

- `hosts` should be an array. It is joined into the NGINX `server_name` list.

- `build.command` is used for `static` apps. `proxy` apps are built with Docker using `build.dockerfile_path`.

- `build.build_location` defaults to `./` for static apps.

- `build.dockerfile_path` defaults to `Dockerfile` for proxy apps.

- `build.docker_volumes` is optional. Host-side directories are created automatically with `sudo mkdir -p`.

- Static deploys call `restorecon` on the served directory when available, which fixes SELinux file contexts on Fedora/RHEL hosts.

- The script uses `git archive "$newrev"` instead of `git checkout` because `pre-receive` hooks run before refs move and inside Git's quarantine environment.

## Troubleshooting

- If a static site returns `403 Forbidden` on Fedora/RHEL, check SELinux labels:

	```bash
	ls -laZ /var/www/<name>
	sudo semanage fcontext -a -t httpd_sys_content_t "/var/www/<name>(/.*)?"
	sudo restorecon -Rv /var/www/<name>
	```

- If NGINX fails to start because it cannot read cert files, make sure the generated config points to `/etc/nginx/certs/<domain>/...` and that those files exist.

