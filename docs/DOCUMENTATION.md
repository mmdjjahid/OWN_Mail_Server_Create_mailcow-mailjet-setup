# সেলফ-হোস্টেড মেইল সার্ভার — পূর্ণ ডকুমেন্টেশন (Mailcow + Mailjet)

> এই ডকুমেন্টের উদাহরণ মান: ডোমেইন `example.com` ও `example.org`, মেইল হোস্টনেম `mail.example.com`, পাবলিক IP `203.0.113.10`, VM-এর লোকাল IP `192.168.1.50`। সব জায়গায় নিজের মান বসান।

## শুরু করার আগে: কী লাগবে ও কোন ক্রমে করবেন

নতুন কেউ এই ডকুমেন্ট ধরে সার্ভার বানানো থেকে মেইল লগইন ও পাঠানো পর্যন্ত যেতে পারবেন।

**আগে থেকে যা লাগবে**

- নিজের ডোমেইন (এখানে `example.com`, `example.org`) এবং DNS পরিচালনার জন্য Cloudflare অ্যাকাউন্ট
- সার্ভারের হোস্টনেমের জন্য একটা ডোমেইন বা সাবডোমেইন (এখানে `mail.example.com`)
- একটা পাবলিক স্ট্যাটিক IP আর রাউটারে পোর্ট ফরওয়ার্ড করার অধিকার (এখানে MikroTik)
- KVM VM বা আলাদা সার্ভার: অন্তত 6 GiB RAM, 1 GiB swap, 20 GiB ডিস্ক
- একটা বিনামূল্যের Mailjet অ্যাকাউন্ট (বাইরে মেইল পাঠানোর রিলে)

**ধাপগুলো এই ক্রমেই করুন**

| ধাপ | কাজ | কোন ভাগে |
| --- | --- | --- |
| ১ | VM তৈরি, Ubuntu ইনস্টল, Docker ও Mailcow চালু | ভাগ ২ |
| ২ | রাউটারে পোর্ট খোলা ও NAT | ভাগ ৩ |
| ৩ | Cloudflare-এ DNS রেকর্ড | ভাগ ৪ |
| ৪ | Mailjet-এ ডোমেইন যাচাই ও API Key নেওয়া | ভাগ ৫ |
| ৫ | Mailcow-এ ডোমেইন, DKIM, ট্রান্সপোর্ট ও মেইলবক্স | ভাগ ৬ |
| ৬ | মেইল ক্লায়েন্টে লগইন (Outlook, Thunderbird, ফোন) | ভাগ ৭ |
| ৭ | মেইল পাঠিয়ে SPF, DKIM, DMARC যাচাই | ভাগ ৮ (এই কপিতে নেই) |

সার্ভার ইনস্টল স্বয়ংক্রিয় করতে চাইলে সবার নিচের "অটো ইনস্টল স্ক্রিপ্ট" অংশ দেখুন।

## ১. সারসংক্ষেপ ও আর্কিটেকচার

`example.org` আর `example.com` এখন একটা Mailcow সার্ভারে চলে; মেইল আসে সরাসরি আপনার সার্ভারে, আর বাইরে যায় Mailjet রিলে দিয়ে, যাতে Gmail-এ স্প্যামে না পড়ে।

| উপাদান | কী | কোথায় |
| --- | --- | --- |
| মেইল সার্ভার | Mailcow (Docker) — Postfix, Dovecot, Rspamd, SOGo | লোকাল Proxmox KVM VM, Ubuntu |
| মেইল হোস্টনেম | `mail.example.com` | Cloudflare A রেকর্ড → `203.0.113.10` |
| পাবলিক IP | `203.0.113.10` | MikroTik রাউটারে VM-এর (`192.168.1.50`) সাথে NAT করা |
| DNS | Cloudflare | দুটো ডোমেইনই, মেইলের রেকর্ড সব DNS only |
| আউটবাউন্ড রিলে | Mailjet (ফ্রি প্ল্যান: মাসে ৬,০০০, দিনে ২০০) | `in-v3.mailjet.com`, পোর্ট 587 |
| ওয়েবমেইল / অ্যাডমিন | SOGo / Mailcow UI | `https://mail.example.com/SOGo` ও `/admin` |

**মেইল আসার পথ:** পাঠকারী সার্ভার → MX `mail.example.com` → `203.0.113.10` → MikroTik dstnat → Mailcow VM → মেইলবক্স।

**মেইল যাওয়ার পথ:** মেইল ক্লায়েন্ট / SOGo → Mailcow (Postfix) → সেন্ডার-ডিপেন্ডেন্ট ট্রান্সপোর্ট → Mailjet → প্রাপক (যেমন Gmail)।

## ২. সার্ভার ও Mailcow ইনস্টল

Mailcow চালাতে KVM VM (LXC নয়), অন্তত 6 GiB RAM, 1 GiB swap আর 20 GiB ডিস্ক লাগে।

**ক) Proxmox-এ VM বানানো**

1. Proxmox ওয়েব UI-তে Ubuntu Server ISO আপলোড করুন, তারপর **Create VM** চাপুন।
2. OS-এ ISO বেছে দিন। System-এ **Qemu Agent** চালু করুন।
3. Disk অন্তত 20 GiB। CPU ২ core-এর বেশি, type `host`। RAM অন্তত 6144 MiB।
4. Network-এ bridge `vmbr0` দিন।
5. VM চালু করে Ubuntu ইনস্টল করুন আর **OpenSSH server** টিক দিন।
6. VM-এর স্থায়ী লোকাল IP ঠিক করুন (রাউটারে DHCP reservation বা VM-এ static IP)। এখানে `192.168.1.50`। এটা বদলালে পরের NAT রুল কাজ করবে না।
7. SSH দিয়ে ঢুকে সার্ভার আপডেট করুন আর হোস্টনেম বসান (কমান্ড নিচে খ-তে)।

**খ) কপি-পেস্ট কমান্ডগুলো (root দিয়ে)**

```bash
# সার্ভার আপডেট ও হোস্টনেম
apt update && apt -y upgrade
hostnamectl set-hostname mail.example.com

# 1 GiB swap (না থাকলে)
fallocate -l 1G /swapfile && chmod 600 /swapfile
mkswap /swapfile && swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab

# Docker (Compose v2 সহ)
curl -fsSL https://get.docker.com | sh
docker compose version

# Mailcow
umask 0022
cd /opt
git clone https://github.com/mailcow/mailcow-dockerized
cd mailcow-dockerized
./generate_config.sh      # hostname: mail.example.com, timezone: Asia/Dhaka
docker compose pull
docker compose up -d
```

শেষ কমান্ডের কয়েক মিনিট পর `docker compose ps` দিয়ে দেখুন সব কনটেইনার `Up`। তারপর ভাগ ৩ (রাউটার) আর ভাগ ৪ (DNS) সারলে বাইরে থেকে `https://mail.example.com/admin` খুলবে।

**সতর্কতা:** UFW/firewalld চালু রাখবেন না, Docker-এর সাথে সংঘর্ষ হয়। RAM কম লাগলে `mailcow.conf`-এ `SKIP_CLAMD=y` আর `SKIP_FTS=y` দেওয়া যায় (অপশনাল)। VM-এর প্রাইভেট IP স্থির (স্ট্যাটিক বা DHCP রিজার্ভেশন) রাখুন।

## ৩. নেটওয়ার্ক: MikroTik NAT ও পোর্ট

বাইরের সার্ভারগুলো যাতে আপনার VM-এ পৌঁছাতে পারে, আর VM-এর আউটগোয়িং ট্রাফিকও একই পাবলিক IP দিয়ে যায়, তার জন্য দুটো NAT রুল লাগে। সিনট্যাক্স RouterOS-এর:

```
/ip firewall nat add action=src-nat chain=srcnat comment=SMTP src-address=192.168.1.50 to-addresses=203.0.113.10

/ip firewall nat add chain=dstnat action=dst-nat dst-address=203.0.113.10 protocol=tcp dst-port=25,80,443,465,587,993 to-addresses=192.168.1.50 comment="Mailcow inbound"
```

| পোর্ট | কাজ |
| --- | --- |
| 25 | মেইল গ্রহণ (SMTP) |
| 80 | Let's Encrypt যাচাই (ACME) আর HTTP→HTTPS |
| 443 | অ্যাডমিন UI, SOGo ওয়েবমেইল |
| 465 | SMTP (SSL/TLS) — ক্লায়েন্ট সেন্ড |
| 587 | SMTP (STARTTLS) — ক্লায়েন্ট সেন্ড |
| 993 | IMAP (SSL/TLS) |

## ৪. Cloudflare DNS রেকর্ড

মেইলের সব রেকর্ড **DNS only** (সাদা/ধূসর মেঘ) রাখতে হবে। Proxied (কমলা মেঘ) রাখলে মেইল আর Let's Encrypt যাচাই ভাঙে।

**সার্ভারের নাম (`example.com` জোনে, একবার)**

| Type | Name | Content |
| --- | --- | --- |
| A | `mail` | `203.0.113.10` |

**প্রতি ডোমেইনে (`example.com` আর `example.org` আলাদাভাবে)**

| Type | Name | Content | কাজ |
| --- | --- | --- | --- |
| MX | `@` | `mail.example.com` (Priority 10) | মেইল গ্রহণ |
| TXT | `@` | `v=spf1 include:spf.mailjet.com ip4:203.0.113.10 ~all` | SPF — কারা পাঠাতে পারবে |
| TXT | `_dmarc` | `v=DMARC1; p=quarantine` (পরীক্ষার সময় `p=none`) | DMARC |
| TXT | `dkim._domainkey` | Mailcow-এর DKIM মান | Mailcow-সাইন করা মেইলের জন্য |
| TXT | `mailjet._domainkey` | Mailjet-এর DKIM মান (`k=rsa; p=...`) | Mailjet-সাইন করা মেইলের জন্য |
| TXT | Mailjet-এর দেওয়া নাম | Mailjet-এর দেওয়া মান | ডোমেইন মালিকানা যাচাই |
| CNAME | `autodiscover`, `autoconfig` | `mail.example.com` | ক্লায়েন্ট অটো-সেটআপ (অপশনাল) |
| SRV | `_autodiscover._tcp` | `0 443 mail.example.com` | Outlook autodiscover (অপশনাল) |

## ৫. Mailjet রিলে সেটআপ

Mailjet ফ্রি প্ল্যানে মাসে ৬,০০০ আর দিনে ২০০টি মেইল পাঠানো যায়। বেশি ভলিউমে (বিজ্ঞাপনী মেইল) ব্যবহার করবেন না।

1. **অ্যাকাউন্ট:** mailjet.com-এ Free প্ল্যানে সাইন আপ, ইমেইল কনফার্ম।
2. **ডোমেইন যোগ:** Account → Sender domains & addresses → Add domain (দুটো ডোমেইনই)।
3. **মালিকানা যাচাই:** Mailjet যে TXT রেকর্ড দেখায় তা Cloudflare-এ বসান (DNS only)। সফল হলে স্ট্যাটাস **Pending থেকে Active** হয় (DNS প্রচারে কয়েক মিনিট থেকে কয়েক ঘণ্টা লাগতে পারে)। সেখানকার "Validate my domain" বাটন অটো-কানেক্ট (Cloudflare OAuth) পপআপ দেখায়; ওটা ডিসমিস করে বাকি কাজ ম্যানুয়ালি করা যায়।
4. **SPF/DKIM অথেনটিকেশন:** Account → Sender domains & addresses → **SPF/DKIM Authentication** ট্যাব → ডোমেইনের gear → Setup SPF/DKIM Authentication। সেখানের SPF (`@`) আর DKIM (`mailjet._domainkey`) রেকর্ড Cloudflare-এ বসান। DKIM মান লম্বা (২০৪৮ বিট কী), তাই হাতে টাইপ না করে **copy আইকন** দিয়ে নিন, এক লাইনে পেস্ট করুন। সবুজ হলে দেখাবে "Your SPF record looks good!" আর "Your DKIM looks good!"।
5. **SMTP ক্রেডেনশিয়াল:** API → API Key Management → Primary API Key। ইউজারনেম = API Key, পাসওয়ার্ড = Secret Key। SMTP হোস্ট `in-v3.mailjet.com`, পোর্ট 587।

**সতর্কতা:** Secret Key আর Mailjet-এর লগইন পাসওয়ার্ড কাউকে দেবেন না, চ্যাটে বা স্ক্রিনশটেও নয়। লগইন পাসওয়ার্ড বদলাতে Account Information → Profile ("Update profile") → Change password। সুরক্ষার জন্য এখানেই Two-factor authentication চালু করুন।

## ৬. Mailcow কনফিগ: ডোমেইন, ট্রান্সপোর্ট, মেইলবক্স

অ্যাডমিন UI: `https://mail.example.com/admin`।

**১. ডোমেইন যোগ:** E-Mail → Configuration → Domains → Add domain। প্রতিটার পাশে **DNS** বাটন চাপলে Mailcow দেখায় কোন রেকর্ড দরকার আর কোনটা সবুজ টিক পেয়েছে (পরীক্ষার উপায়)।

**২. DKIM (Mailcow-এর):** ডোমেইন Edit পেজের নিচে DKIM কী দেখায়, বা System → Configuration → Options → ARC/DKIM keys। না থাকলে সেখান থেকে তৈরি করুন, তারপর `dkim._domainkey` TXT রেকর্ড Cloudflare-এ বসান।

**৩. Mailjet ট্রান্সপোর্ট তৈরি (একবার):** System → Configuration → Routing → Sender-dependent transports → Add।

| ঘর | মান |
| --- | --- |
| Host | `[in-v3.mailjet.com]:587` (বর্গাকার বন্ধনী **অবশ্য** লাগবে) |
| Username | Mailjet API Key |
| Password | Mailjet Secret Key |

**Add** চাপুন, তারপর তালিকার **Test** বাটন চালান। বন্ধনী ছাড়া (`in-v3.mailjet.com:587`) দিলে Postfix MX খোঁজে আর সংযোগ ব্যর্থ হতে পারে। ক্রেডেনশিয়াল Mailcow-এ plain text-এ সংরক্ষিত থাকে।

**৪. প্রতি ডোমেইনে ট্রান্সপোর্ট অ্যাসাইন (গুরুত্বপূর্ণ):** E-Mail → Configuration → Domains → ডোমেইনের **Edit** → *Sender-dependent transports* ড্রপডাউনে `ID 1: [in-v3.mailjet.com]:587` বেছে **Save changes**। এটা `None / Inherit` থাকলে মেইল রিলে না গিয়ে বাসার IP থেকে সরাসরি যাবে আর স্প্যামে পড়বে।

**৫. মেইলবক্স বানানো:** E-Mail → Configuration → Mailboxes → Add mailbox। Username (বামঅংশ, যেমন `info`), ডোমেইন, Full name আর Password দিন। পাসওয়ার্ড লম্বা (১২+ অক্ষর) রাখুন, আর কোথাও স্ক্রিনশট বা চ্যাটে পাঠাবেন না।

## ৭. মেইল ক্লায়েন্ট সেটআপ

সব ক্লায়েন্টে সার্ভারের নাম `mail.example.com`, আর ইউজারনেম **পুরো ইমেইল ঠিকানা** (যেমন `info@example.com`, শুধু `info` নয়)।

| বিষয় | সার্ভার | পোর্ট | নিরাপত্তা |
| --- | --- | --- | --- |
| IMAP (পড়া) | `mail.example.com` | 993 | SSL/TLS |
| SMTP (পাঠানো) | `mail.example.com` | 587 | STARTTLS |
| SMTP (বিকল্প) | `mail.example.com` | 465 | SSL/TLS |

- **ওয়েবমেইল:** `https://mail.example.com/SOGo` — কোনো সেটআপ লাগে না। অ্যাডমিন প্যানেল (`/admin`) আলাদা।
- **ফোনের মেইল অ্যাপ:** "Other / IMAP" বেছে উপরের মান দিন। Google, Outlook.com বা Yahoo প্রোভাইডার বেছবেন না।
- **SMTP পাসওয়ার্ড:** IMAP-এর পাসওয়ার্ডই।

## অটো ইনস্টল স্ক্রিপ্ট (`install-mailcow.sh`) চালানোর নিয়ম

নতুন Ubuntu/Debian সার্ভারে এক সাথে Docker, swap আর Mailcow বসাতে এই স্ক্রিপ্ট ব্যবহার করুন। রাউটার (পোর্ট ফরওয়ার্ড), Cloudflare DNS, Mailjet আর Mailcow-এর ভেতরের কাজ (ডোমেইন, DKIM, ট্রান্সপোর্ট, মেইলবক্স) স্ক্রিপ্ট করে না, সেগুলো উপরের ভাগগুলো মেনে হাতে করতে হবে।

**শুরুর আগে ঠিক করুন**

- সার্ভার KVM VM (LXC নয়), অন্তত 6 GiB RAM আর 20 GiB ডিস্ক
- Cloudflare-এ `mail.example.com`-এর A রেকর্ড (DNS only) দিয়ে রাখা, না হলে SSL certificate আসবে না
- 25, 80, 443, 465, 587, 993 পোর্ট খালি থাকা (nginx, apache, postfix চললে স্ক্রিপ্ট বন্ধ করার অনুমতি চাইবে)

**ধাপে ধাপে চালানো**

1. স্ক্রিপ্টের ফাইল `install-mailcow.sh` সার্ভারে আনুন, যেমন `scp install-mailcow.sh root@192.168.1.50:/root/`।
2. SSH দিয়ে সার্ভারে ঢুকুন।
3. চালান (নিজের হোস্টনেম দিন):

   ```bash
   sudo MAIL_HOSTNAME=mail.example.com TZ_NAME=Asia/Dhaka bash install-mailcow.sh
   ```

   `MAIL_HOSTNAME` না দিলে স্ক্রিপ্ট নিজেই জিজ্ঞেস করবে।
4. শেষ হওয়ার পর `docker compose ps` দিয়ে দেখুন সব কনটেইনার `Up`: `cd /opt/mailcow-dockerized && docker compose ps`
5. `https://mail.example.com/admin`-এ লগইন করুন (`admin` / `moohoo`) আর **সাথে সাথে পাসওয়ার্ড বদলান ও 2FA চালু করুন**।
6. তারপর ভাগ ৩ (রাউটার) থেকে শুরু করে বাকি ভাগগুলো ক্রমে সারুন।

**স্ক্রিপ্ট যা যা করে**

| ধাপ | কাজ |
| --- | --- |
| চেক | root, OS, KVM, RAM, ডিস্ক, পোর্ট দখল আর DNS যাচাই |
| সিস্টেম | আপডেট, hostname, timezone, সময় সিঙ্ক, 1 GiB swap |
| Docker | Docker ও Compose v2 ইনস্টল |
| Mailcow | `/opt/mailcow-dockerized`-এ ক্লোন, config তৈরি, image pull, চালু |

**মনে রাখুন**

- স্ক্রিপ্ট মাঝপথে থামলে আবার চালানো নিরাপদ; আগে হয়ে যাওয়া ধাপ স্কিপ হয়।
- RAM 6 GiB-এর কম হলে স্ক্রিপ্ট ClamAV আর FTS বন্ধ (`SKIP_CLAMD=y`, `SKIP_FTS=y`) করে দেয়।
- UFW চালু থাকলে স্ক্রিপ্ট শুধু সতর্ক করে, নিজে বন্ধ করে না।
- নতুন সার্ভারে প্রথমবার চালানোর সময় আউটপুটটা দেখে নিন, তারপর বাকি ধাপে যান।
