# Self-hosted mail server: Mailcow + Mailjet relay

Mailcow (Docker) on a local Proxmox KVM VM, DNS on Cloudflare, outbound mail
relayed through Mailjet so Gmail and others do not treat it as spam.

Full guide (Bengali): [docs/DOCUMENTATION.md](docs/DOCUMENTATION.md)

## Quick start

```bash
sudo MAIL_HOSTNAME=mail.example.com TZ_NAME=Asia/Dhaka bash install-mailcow.sh
```

The script checks the server, sets hostname/timezone/swap, installs Docker,
clones Mailcow into `/opt/mailcow-dockerized`, generates the config, pulls the
images and starts everything. Re-running it skips steps already done.

Requirements: KVM VM (not LXC), 6 GiB RAM or more, 20 GiB disk, ports
25/80/443/465/587/993 free, and an A record for the mail hostname
(Cloudflare: DNS only, proxy off).

## What the script does not do (manual steps)

1. Router: NAT and port forward 25, 80, 443, 465, 587, 993 to the VM.
2. Cloudflare DNS per domain: MX, SPF, DKIM, DMARC, autodiscover/autoconfig.
3. Mailjet: add and verify the domain (ownership TXT, SPF include, DKIM), get
   the API Key and Secret Key.
4. Mailcow admin: add domain, enable DKIM, add the sender-dependent transport
   `[in-v3.mailjet.com]:587`, assign it to each domain, create mailboxes.
5. After the first login, change the default admin password and enable 2FA.

## DNS records (per domain)

| Type | Name | Content |
| --- | --- | --- |
| MX | `@` | `mail.example.com` (priority 10) |
| TXT | `@` | `v=spf1 include:spf.mailjet.com ip4:<public-ip> ~all` |
| TXT | `_dmarc` | `v=DMARC1; p=quarantine` (use `p=none` while testing) |
| TXT | `dkim._domainkey` | Mailcow DKIM value |
| TXT | `mailjet._domainkey` | Mailjet DKIM value |
| CNAME | `autodiscover`, `autoconfig` | `mail.example.com` |

## Mail client settings

| Protocol | Server | Port | Security |
| --- | --- | --- | --- |
| IMAP | `mail.example.com` | 993 | SSL/TLS |
| SMTP | `mail.example.com` | 587 | STARTTLS |
| SMTP (alt) | `mail.example.com` | 465 | SSL/TLS |

Username is the full email address. Webmail: `https://mail.example.com/SOGo`.
Admin: `https://mail.example.com/admin`.

## Security

Never commit passwords, the Mailjet Secret Key or `mailcow.conf`.
