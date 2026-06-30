---
name: emby-tool-auth
description: Instructions for working on the emby-tool repository when authentication configuration is involved. Use when editing or reviewing scripts, docs, ignore rules, or workflows that mention auth.json, ApiToken, ServerUrl, or Emby connection settings.
---

# Emby Tool Auth

Do not read `auth.json`. Treat it as a local secret file.

If authentication configuration is needed, assume `auth.json` lives beside the PowerShell scripts and has this shape:

```json
{
  "ApiToken": "your-emby-api-token",
  "ServerId": "your-emby-server-id",
  "ServerUrl": "http://your-emby-server"
}
```

When modifying scripts, preserve this precedence:

1. Use explicitly passed parameters first.
2. Fall back to values from `auth.json`.
3. Throw an error if neither source provides the required value.
