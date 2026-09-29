# Reverse Proxy Configuration

> **This directory is REDUNDANT** and can be safely deleted.
>
> The reverse proxy (Traefik) is fully configured in `configs/docker/traefik/`:
> - `docker-compose.yml` — Traefik container definition
> - `traefik.yml` — Traefik static configuration
> - `dynamic/middlewares.yml` — Reusable middleware (security headers, rate limiting, etc.)
> - `.env.example` — Environment variables template
>
> This directory exists from an earlier version of the project structure.
> All reverse proxy configuration has moved to `configs/docker/traefik/`.
