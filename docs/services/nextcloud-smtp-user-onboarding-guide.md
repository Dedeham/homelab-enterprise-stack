# Nextcloud SMTP And User Onboarding Guide

Last updated: 2026-06-26

This guide configures outbound email for Nextcloud so it can send password
reset messages, activity notifications, share notifications, and user
activation emails.

Use this after:

1. Nextcloud works at `https://cloud.example.com`.
2. The dedicated Nextcloud VM stack is running, or the simpler Docker-VM
   Nextcloud stack is running.
3. You control DNS for `example.com`, normally in Cloudflare.
4. You have created a free Brevo account for outbound SMTP.

This guide uses Brevo as the SMTP provider. It does not install a mail server
on the Nextcloud VM. Running your own public mail server from a residential
connection is usually fragile because of blocked ports, IP reputation, reverse
DNS, and spam filtering.

## Target Result

Use this sender identity:

```text
Nextcloud URL:      https://cloud.example.com
Sender address:     nextcloud@example.com
SMTP provider:       Brevo free plan
SMTP host:           smtp-relay.brevo.com
Recommended port:   587 with None/STARTTLS or None, depending on UI wording
Alternative port:   465 with SSL
```

Nextcloud will then support:

- Creating users without manually setting their password.
- Activation emails where users set their own password.
- Password reset emails.
- Share and activity notifications.
- Registration app verification emails if you later enable self-signup.

## Important Decisions

Recommended for this homelab:

- Use invite-only onboarding first.
- Keep public self-registration disabled unless you have a reason to open it.
- Do not put Authelia or Cloudflare Access in front of Nextcloud by default.
  The existing guides already avoid this because desktop and mobile sync
  clients need Nextcloud's own login and app-password flow.
- Use a dedicated SMTP credential for Nextcloud. Do not reuse your personal
  mailbox password.
- Use Brevo's SMTP key for SMTP relay. Do not paste a normal Brevo account
  password into Nextcloud.
- Treat the Nextcloud app/config backup as secret material after SMTP is
  configured, because the SMTP password is stored in Nextcloud configuration.

## Step 1: Create The Brevo Account

Create a free Brevo account:

```text
https://www.brevo.com/pricing/
```

Use an account email you control. Brevo's free plan is enough for this homelab:

```text
300 emails per day
SMTP relay included
No credit card required for signup
```

It is fine if the Brevo login account is a personal Gmail address. That login
email only controls the Brevo account. The sender identity for Nextcloud is the
verified domain sender, for example `nextcloud@example.com`.

After login, open the transactional email area:

```text
Brevo Dashboard -> Transactional -> Settings
```

If Brevo asks you to activate transactional sending or complete account
validation, complete that before configuring Nextcloud.

## Step 2: Choose And Verify The Sender

Use this sender address:

```text
nextcloud@example.com
```

Alternatives:

```text
no-reply@example.com
cloud@example.com
```

Use the same domain as your public Nextcloud hostname. This keeps sender
identity simple:

```text
cloud.example.com sends mail as nextcloud@example.com
```

In Brevo, create the sender:

```text
Brevo Dashboard
-> Senders, Domains & Dedicated IPs
-> Senders
-> Add a sender
```

Set:

| Field | Value |
|---|---|
| From name | `Nextcloud` |
| From email | `nextcloud@example.com` |

Brevo may ask you to verify the sender by email or by domain authentication.
Domain authentication is better because it improves deliverability and lets
Brevo sign outgoing mail with DKIM.

## Step 3: Add Brevo DNS Records In Cloudflare

In Brevo:

```text
Brevo Dashboard
-> Senders, Domains & Dedicated IPs
-> Domains
-> Add a domain
```

Add:

```text
example.com
```

Brevo will show DNS records for your domain. Add those exact records in
Cloudflare:

```text
Cloudflare Dashboard -> example.com -> DNS -> Records
```

Typical Brevo records include:

| Record | Purpose | What to do in Cloudflare |
|---|---|
| DKIM TXT | Lets receivers verify Brevo-signed mail | Copy Brevo's exact TXT name and value |
| SPF TXT | Authorizes Brevo to send mail for your domain | Merge with any existing SPF record |
| DMARC TXT | Tells receivers how to handle SPF/DKIM alignment | Add if you do not already have DMARC |

Do not copy random SPF or DKIM values from examples. Use the values Brevo shows
for your domain.

If you already have an SPF TXT record at `@`, do not create a second SPF record.
Merge Brevo into the existing record.

Example shape only:

```text
Existing:
v=spf1 include:_spf.google.com -all

Merged with Brevo:
v=spf1 include:_spf.google.com include:brevo-provided-spf.example -all
```

DKIM and DMARC records should be DNS-only. Do not proxy mail DNS records through
Cloudflare.

DMARC starter record:

```text
Type: TXT
Name: _dmarc
Value: "v=DMARC1; p=none; adkim=s; aspf=s"
```

After adding the records, return to Brevo and click the domain verification
button. DNS can take a few minutes to propagate.

## Step 4: Get Brevo SMTP Credentials

In Brevo:

```text
Brevo Dashboard
-> SMTP & API
-> SMTP
```

Generate or copy an SMTP key. Brevo's own SMTP relay docs say to use an SMTP
key for SMTP relay connections, not a normal API key.

```text
SMTP host:     smtp-relay.brevo.com
SMTP port:     587
Encryption:    None/STARTTLS in Nextcloud, or leave empty/None if your UI uses that wording
SMTP username: your Brevo SMTP login shown in the SMTP tab
SMTP password: generated Brevo SMTP key
```

Brevo also supports:

```text
Port:       465
Encryption: SSL
```

Use port `587` first. Use `465` only if `587` fails or your Brevo account
specifically shows `465` as the required path.

## Step 5: Confirm The Nextcloud VM Can Reach Brevo SMTP

Run this on the Nextcloud VM:

```bash
SMTP_HOST="smtp-relay.brevo.com"
SMTP_PORT="587"

getent hosts "$SMTP_HOST"
openssl s_client -starttls smtp -connect "${SMTP_HOST}:${SMTP_PORT}" -servername "$SMTP_HOST" </dev/null
```

Expected:

- DNS resolves the SMTP host.
- The TCP connection opens.
- The output shows a certificate chain and SMTP capabilities.

If you use port `465`, test SMTPS instead:

```bash
SMTP_HOST="smtp-relay.brevo.com"
SMTP_PORT="465"

openssl s_client -connect "${SMTP_HOST}:${SMTP_PORT}" -servername "$SMTP_HOST" </dev/null
```

The dedicated Nextcloud guide sets UFW to allow outgoing traffic by default, so
outbound SMTP should work unless you later changed host firewall rules.

## Step 6: Configure Brevo SMTP In Nextcloud

Use the web UI first. It avoids putting the SMTP password in shell history.

Open:

```text
https://cloud.example.com
```

Then:

```text
Admin avatar -> Settings -> Administration -> Basic settings -> Email server
```

Set:

| Field | Value |
|---|---|
| Send mode | `SMTP` |
| Encryption | `None/STARTTLS` for port `587` |
| From address | `nextcloud` |
| Mail domain | `example.com` |
| Authentication required | enabled |
| Server address | `smtp-relay.brevo.com` |
| Port | `587` |
| Authentication method | `LOGIN` |
| Username | Brevo SMTP login from the `SMTP & API` page |
| Password | Brevo SMTP key, not your Brevo account password |

The visible sender becomes:

```text
nextcloud@example.com
```

Do not put `nextcloud@example.com` entirely in the `From address` field if
the UI has a separate domain field. Use:

```text
From address: nextcloud
Domain:       example.com
```

If port `587` fails and Brevo support or dashboard tells you to use SMTPS,
switch to:

| Field | Value |
|---|---|
| Encryption | `SSL` |
| Port | `465` |

## Step 7: Send A Test Email

Before testing SMTP, set an email address for your admin account:

```text
Admin avatar -> Personal settings -> Personal info -> Email
```

Then return to:

```text
Administration -> Basic settings -> Email server
```

Click:

```text
Send email
```

Expected:

- The UI says the email was sent.
- The test message arrives at the admin email address.
- The message is not in spam.
- The sender is `nextcloud@example.com`.
- Brevo's transactional logs show the message.

If the test mail fails, fix SMTP before configuring user activation or
registration. Password resets and registration verification depend on the same
mail path.

## Step 8: Optional CLI Configuration

Prefer the UI. Use CLI only for recovery or repeatable rebuilds.

For Brevo on port `587`:

```bash
cd /opt/docker/nextcloud

docker exec --user www-data nextcloud php occ config:system:set mail_smtpmode --value="smtp"
docker exec --user www-data nextcloud php occ config:system:set mail_smtphost --value="smtp-relay.brevo.com"
docker exec --user www-data nextcloud php occ config:system:set mail_smtpport --type=integer --value=587
docker exec --user www-data nextcloud php occ config:system:set mail_smtpsecure --value=""
docker exec --user www-data nextcloud php occ config:system:set mail_smtpauth --type=boolean --value=true
docker exec --user www-data nextcloud php occ config:system:set mail_smtpauthtype --value="LOGIN"
docker exec --user www-data nextcloud php occ config:system:set mail_smtpname --value="your_brevo_smtp_login"
docker exec --user www-data nextcloud php occ config:system:set mail_from_address --value="nextcloud"
docker exec --user www-data nextcloud php occ config:system:set mail_domain --value="example.com"
```

Set the password last. This can expose the secret in shell history, so prefer
the UI when possible:

```bash
read -rsp "SMTP password/token: " SMTP_PASS
echo
docker exec --user www-data nextcloud php occ config:system:set mail_smtppassword --value="$SMTP_PASS"
unset SMTP_PASS
```

For Brevo port `465` with SMTPS, use:

```bash
docker exec --user www-data nextcloud php occ config:system:set mail_smtpport --type=integer --value=465
docker exec --user www-data nextcloud php occ config:system:set mail_smtpsecure --value="ssl"
```

## Step 9: Invite Users Without Setting Their Password

After SMTP test email works:

```text
Admin avatar -> Users
```

Open the lower-left gear/settings area and enable:

```text
Show email address
Send email to new users
```

Create the user:

| Field | Value |
|---|---|
| Login name | user's stable username |
| Email | user's real email address |
| Password | leave empty |
| Groups | normal non-admin group |
| Quota | set a sane quota |

Expected:

- Nextcloud sends an activation email.
- The user clicks the activation link.
- The user sets their own password.
- The user logs in with Nextcloud's own login flow.
- The user can create app passwords for desktop and mobile clients.

This is the recommended onboarding flow for a private homelab because you
control who gets an account, but you do not know or handle their password.

## Step 10: Optional Self-Signup With Registration App

Use this only after invite-only onboarding works.

Install the app:

```bash
cd /opt/docker/nextcloud
docker exec --user www-data nextcloud php occ app:install registration
docker exec --user www-data nextcloud php occ app:enable registration
```

Then configure it in the Nextcloud web UI:

```text
Admin avatar -> Administration settings -> Registration
```

Recommended settings:

| Setting | Recommendation |
|---|---|
| Email verification | Required |
| Admin approval | Required |
| Allowed email domains | Restrict if possible |
| Default group | Normal non-admin users group |
| Default quota | Set before opening registration |
| Terms of service | Enable if you want users to accept rules |

Do not enable unrestricted public signups on an internet-exposed Nextcloud
instance. At minimum, require email verification and admin approval.

## Step 11: Password Policy And 2FA

Open:

```text
Admin avatar -> Administration settings -> Security
```

Recommended baseline:

- Minimum password length: at least `12`.
- Forbid common passwords.
- Enable breached-password checks if you are comfortable with the external
  hashed check.
- Require 2FA for the admin account.
- Encourage normal users to enable 2FA.
- Use app passwords for desktop and mobile clients.

Do not use the same password for TrueNAS, Proxmox, router, Vaultwarden, and
Nextcloud accounts.

## Step 12: Backup Impact

SMTP settings are stored in Nextcloud's configuration, not in this repository.

Dedicated VM deployment:

```text
/opt/docker/nextcloud/html/config/config.php
```

The dedicated backup helper archives the local Nextcloud app/config directory.
After SMTP is configured, that archive contains secret material. Keep
`/mnt/nc-backups` and off-server copies protected.

If the SMTP credential is exposed:

1. Disable or rotate the Brevo SMTP key.
2. Create a new Brevo SMTP key.
3. Update Nextcloud SMTP settings.
4. Send a test email.
5. Check Brevo transactional logs for unexpected sent mail.

## Troubleshooting

### Test email does not send

Check:

```bash
docker logs --tail=100 nextcloud
docker exec --user www-data nextcloud php occ log:watch
```

Common causes:

- Wrong Brevo SMTP login.
- Normal Brevo account password used instead of Brevo SMTP key.
- Brevo account or transactional sending is not activated yet.
- Brevo sender/domain is not verified.
- DNS cannot resolve the SMTP host from the Nextcloud VM.
- Outbound firewall rules were tightened after the base guide.

### Brevo returns `525 5.7.1 Unauthorized IP address`

This means Nextcloud reached Brevo, but Brevo refused SMTP authentication from
the public IP address your home internet connection used for outbound mail.

Find the public outbound IP from the Nextcloud VM:

```bash
curl -4 https://ifconfig.me
```

This is the WAN egress IP Brevo sees. It is not the Nextcloud VM's LAN IP and
not the Cloudflare Tunnel hostname.

Then in Brevo, authorize that IP or remove the SMTP key's IP restriction if the
dashboard allows unrestricted use for that key:

```text
Brevo Dashboard
-> SMTP & API
-> SMTP
-> Authorized IPs / IP restrictions
```

Add the public IPv4 address from the `curl` command. After saving, send the
Nextcloud test email again.

If your ISP changes your WAN IP often, this can break later. In that case,
either update the authorized IP when it changes or use a Brevo SMTP key without
IP restriction if your account security policy allows it.

### Brevo returns `502 5.7.0 Your SMTP account is not yet activated`

This means the SMTP credentials and server are being reached, but Brevo has not
activated transactional SMTP sending for the account yet.

This is separate from using a Gmail address as your Brevo login and separate
from adding the domain. A Brevo account can exist, a domain can be added, and
SMTP can still remain inactive until Brevo's account validation allows
transactional sending.

The message may say `sendinblue.com`. That is expected legacy wording because
Brevo used to be called Sendinblue. It does not mean you configured the wrong
provider. Do not click links or trust random emails because of that wording;
open Brevo directly in the browser and use the in-dashboard support/contact
flow.

In Brevo, check:

```text
Brevo Dashboard
-> Transactional
-> Settings
```

and:

```text
Brevo Dashboard
-> SMTP & API
-> SMTP
```

Complete any requested profile, sender, domain, or account validation steps.
If Brevo still says SMTP is inactive and there is no visible activate button,
contact Brevo support from inside the Brevo dashboard and ask them to activate
transactional SMTP sending for your account/domain. Tell them it is for
Nextcloud account invitations and password reset emails.

After Brevo activates SMTP, send the Nextcloud test email again.

### Brevo rejects the sender

Make sure:

- `nextcloud@example.com` exists as a Brevo sender or the domain is
  authenticated in Brevo.
- SPF includes Brevo.
- DKIM is enabled and passing.
- The sender address is allowed by the Brevo account.

### Emails arrive in spam

Check:

- SPF record exists and has only one TXT SPF record for the root domain.
- DKIM record matches Brevo's selector.
- DMARC exists.
- From domain matches the verified domain.
- New domains may need time and low sending volume to build reputation.

### Registration says email could not be sent

Fix the basic Nextcloud test email first. The Registration app uses the same
mail path.

### Password reset links use the wrong URL

Check that the public URL is correct:

```bash
docker exec --user www-data nextcloud php occ config:system:get overwrite.cli.url
docker exec --user www-data nextcloud php occ config:system:get overwriteprotocol
```

Expected for the homelab:

```text
https://cloud.example.com
https
```

The dedicated compose file already sets these through:

```text
OVERWRITEPROTOCOL=https
OVERWRITECLIURL=https://cloud.${DOMAIN}
```

## Validation Checklist

| Check | Expected |
|---|---|
| Brevo account | Free account created and transactional sending active |
| SMTP sender | `nextcloud@example.com` exists in Brevo |
| DNS SPF | Brevo is authorized; only one SPF record exists |
| DNS DKIM | Brevo DKIM record exists and verifies |
| DNS DMARC | At least monitor-only policy exists |
| Nextcloud SMTP | UI uses `smtp-relay.brevo.com`, port `587`, auth enabled |
| Test email | Arrives at admin email address |
| Brevo logs | Test email appears in transactional logs |
| Invite flow | User can set their own password from activation email |
| Password reset | Reset email arrives and link uses `https://cloud.example.com` |
| Registration app | Not enabled unless email verification and admin approval are configured |
| Secrets | SMTP credential is not committed to git |

## References

- Nextcloud 33 email configuration:
  <https://docs.nextcloud.com/server/33/admin_manual/configuration_server/email_configuration.html>
- Nextcloud user management and activation emails:
  <https://docs.nextcloud.com/server/latest/admin_manual/configuration_user/user_configuration.html>
- Nextcloud password policy:
  <https://docs.nextcloud.com/server/latest/admin_manual/configuration_user/user_password_policy.html>
- Nextcloud Registration app:
  <https://github.com/nextcloud/registration>
- Brevo pricing:
  <https://www.brevo.com/pricing/>
- Brevo SMTP relay integration:
  <https://developers.brevo.com/docs/smtp-integration>
