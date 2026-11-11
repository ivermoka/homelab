# Notes on deploying my portfolio 


## First: adding Dockerfile to portfolio repo

This wasnt any hocus pocus stuff, but had some issues with multiple pages. 

Solution was to add a `nginx.conf` with 
```
server {
  listen 80;
  root /usr/share/nginx/html;
  absolute_redirect off; # This is the important line here. It makes redirect happen relative - i.e. :8080/projects, not /projects. 
  index index.html;
  location / {
    try_files $uri $uri/ $uri.html =404;
  }
  error_page 404 /404.html;
}
```

## Publish docker image to ghcr.io (github)

I havent published to this GitHub image stuff before, but it was basically the same as to artifactory.

```
name: Build and push image

on:
  push:
    branches: [main]

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    steps:
      - uses: actions/checkout@v4

      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - uses: docker/build-push-action@v6
        with:
          context: .
          push: true
          tags: |
            ghcr.io/ivermoka/${{ github.sha }}
            ghcr.io/ivermoka/portfolio:latest
```

Where it just builds on push to main, then uses `ghcr.io` as its registry. 


## Manifests for portfolio

This was the most difficult step. I wanted to have the same sorta structure as I do at work, with Helm Charts & a defined entrypoint to the application.

This was done by adding `clusters/home/apps/portfolio.yaml`, with basically exactly the same contents as any other `gli` application; `Application` with:
 - metadata (name, namespace)
 - spec
    - source (homelab github repo (will probably be replaced with a ReplicaSet), and the values location (`apps/portfolio`) )
    - destination (namespace its deployed to. I.e. portfolio)

The `apps/portfolio` (values location) contains the Helm Chart (boilerplate), values (replicaCount & name).
Namely, the files under `templates/` are important. They define the deployment, ingress and service.

### deployment.yaml

Defines docker image to use, pod health endpoints and its resource quotas.

### ingress.yaml

Defines ingress settings and sets `traefik` as its ingress handler. Plus the service's path.

Ingress makes the HTTP / HTTPS service available using "protocol-aware" configuriation mechanism, that understands web concepts (URIs, hostnames, paths and more).
This makes it possible to actually access the services defined in browser.

### service.yaml

Basically just repeats the port used and the app name. 


## root-app.yaml

Also defined this root-app config file, which acts as a "common" entrypoint for ArgoCD. I.e. you don't have to manually apply each new service's `/apps/xxx.yaml` (the actual entrypoints to the seperate manifests, which again point to its values).
It looks for every yaml file under `clusters/home/apps/` and applies each one.


