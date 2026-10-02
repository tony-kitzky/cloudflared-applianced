# CloudflareD-Applianced
Bash scripts to convert a standard, rpm-based Linux server into a bespoke appliance to run Cloudflare's CloudflareD tunnel daemon. The "applianced" server will run CloudflareD as a rootless container. Server OS must use Systemd and Network Manager (not systemd-networkd). Server requires two network adapters. Primary adapter (eth0) must have reachability to Cloudflare via Internet. CloudflareD origin/private traffic egresses the second adapter.

Vibe coded with ChatGPT 5.2 Thinking and Claude Sonnet LLM's between January 20 and October 1, 2026.
