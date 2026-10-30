# Zella Voice: sign-in email templates

Paste these into **Supabase > Authentication > Emails > Templates** (one tab per template: Subject, then the
message body as HTML). They are sent from `Zella Voice <no-reply@zellavoice.com>` through Resend (custom SMTP).

Every link uses `token_hash`, so the app opens `/welcome` and asks the person to press a button first. Mail
scanners (Gmail, Outlook) that open links early then can't use the link up (see `docs/GO_LIVE.md`).
`/welcome` handles invite, recovery, signup, magiclink and email_change (`EMAIL_LINK_TYPES` in
`web/src/authErrors.js`); any other page with a `token_hash` is sent there too (`web/src/App.jsx`).

- `{{ .RedirectTo }}` is the address the app asked for: `/welcome` for invitations and password resets.
- `{{ .SiteURL }}` is set in Authentication > URL Configuration. After hosting it is `https://app.zellavoice.com`.

The app itself still says "Zella AI" until the rebrand.

## Invite user

Subject: `You're invited to Zella Voice`

```html
<div style="font-family:Arial,Helvetica,sans-serif;max-width:520px;margin:0 auto;padding:24px;color:#1f2430">
  <h2 style="margin:0 0 16px;font-size:20px">You're invited to Zella Voice</h2>
  <p style="line-height:1.5">You've been added to a business on Zella Voice, the AI receptionist that answers calls and books appointments.</p>
  <p style="line-height:1.5">Press the button to accept the invitation and choose your password.</p>
  <p style="margin:24px 0"><a href="{{ .RedirectTo }}?token_hash={{ .TokenHash }}&type=invite" style="background:#1f2430;color:#ffffff;text-decoration:none;padding:12px 20px;border-radius:8px;display:inline-block">Accept your invitation</a></p>
  <p style="line-height:1.5;color:#5b6170;font-size:13px">This link works once. If you weren't expecting this, you can ignore this email.</p>
  <p style="line-height:1.5;color:#5b6170;font-size:13px">Questions? Write to <a href="mailto:support@zellavoice.com">support@zellavoice.com</a>.</p>
</div>
```

## Reset password

Subject: `Reset your Zella Voice password`

```html
<div style="font-family:Arial,Helvetica,sans-serif;max-width:520px;margin:0 auto;padding:24px;color:#1f2430">
  <h2 style="margin:0 0 16px;font-size:20px">Reset your password</h2>
  <p style="line-height:1.5">Someone asked to reset the password for your Zella Voice account ({{ .Email }}).</p>
  <p style="margin:24px 0"><a href="{{ .RedirectTo }}?token_hash={{ .TokenHash }}&type=recovery" style="background:#1f2430;color:#ffffff;text-decoration:none;padding:12px 20px;border-radius:8px;display:inline-block">Choose a new password</a></p>
  <p style="line-height:1.5;color:#5b6170;font-size:13px">This link works once and expires soon. If you didn't ask for this, ignore this email: your password stays the same.</p>
  <p style="line-height:1.5;color:#5b6170;font-size:13px">Need help? <a href="mailto:support@zellavoice.com">support@zellavoice.com</a></p>
</div>
```

## Magic link

Subject: `Your Zella Voice sign-in link`

```html
<div style="font-family:Arial,Helvetica,sans-serif;max-width:520px;margin:0 auto;padding:24px;color:#1f2430">
  <h2 style="margin:0 0 16px;font-size:20px">Sign in to Zella Voice</h2>
  <p style="margin:24px 0"><a href="{{ .SiteURL }}/welcome?token_hash={{ .TokenHash }}&type=magiclink" style="background:#1f2430;color:#ffffff;text-decoration:none;padding:12px 20px;border-radius:8px;display:inline-block">Sign in</a></p>
  <p style="line-height:1.5;color:#5b6170;font-size:13px">This link works once and expires soon. If you didn't ask to sign in, ignore this email.</p>
</div>
```

## Confirm signup

Subject: `Confirm your email for Zella Voice`

```html
<div style="font-family:Arial,Helvetica,sans-serif;max-width:520px;margin:0 auto;padding:24px;color:#1f2430">
  <h2 style="margin:0 0 16px;font-size:20px">Confirm your email</h2>
  <p style="line-height:1.5">Press the button to confirm {{ .Email }} for your Zella Voice account.</p>
  <p style="margin:24px 0"><a href="{{ .SiteURL }}/welcome?token_hash={{ .TokenHash }}&type=signup" style="background:#1f2430;color:#ffffff;text-decoration:none;padding:12px 20px;border-radius:8px;display:inline-block">Confirm email</a></p>
  <p style="line-height:1.5;color:#5b6170;font-size:13px">If you didn't create an account, ignore this email.</p>
</div>
```

## Change email address

Subject: `Confirm your new email for Zella Voice`

```html
<div style="font-family:Arial,Helvetica,sans-serif;max-width:520px;margin:0 auto;padding:24px;color:#1f2430">
  <h2 style="margin:0 0 16px;font-size:20px">Confirm your new email</h2>
  <p style="line-height:1.5">Press the button to change your Zella Voice sign-in email from {{ .Email }} to {{ .NewEmail }}.</p>
  <p style="margin:24px 0"><a href="{{ .SiteURL }}/welcome?token_hash={{ .TokenHash }}&type=email_change" style="background:#1f2430;color:#ffffff;text-decoration:none;padding:12px 20px;border-radius:8px;display:inline-block">Confirm new email</a></p>
  <p style="line-height:1.5;color:#5b6170;font-size:13px">If you didn't ask for this, write to <a href="mailto:support@zellavoice.com">support@zellavoice.com</a> straight away.</p>
</div>
```

## Reauthentication

Subject: `Your Zella Voice verification code`

```html
<div style="font-family:Arial,Helvetica,sans-serif;max-width:520px;margin:0 auto;padding:24px;color:#1f2430">
  <h2 style="margin:0 0 16px;font-size:20px">Your verification code</h2>
  <p style="font-size:28px;letter-spacing:6px;font-weight:bold;margin:16px 0">{{ .Token }}</p>
  <p style="line-height:1.5;color:#5b6170;font-size:13px">Enter this code in Zella Voice to confirm it's you. Never share it with anyone, including Zella staff.</p>
</div>
```
