# `incoming/` — drop mod files here

This folder exists for one reason: **the agent working on this repo cannot reach
ModDB.**

The sandbox it runs in only has outbound network access to `github.com`,
`codeload.github.com`, `api.github.com`, `registry.npmjs.org`, `pypi.org` and
`files.pythonhosted.org`. Everything else is refused at the TLS layer:

```
$ curl https://www.moddb.com/downloads/start/315509
curl: (35) OpenSSL SSL_connect: SSL_ERROR_SYSCALL in connection to www.moddb.com:443
```

But GitHub *is* reachable. So this repo is the delivery route: you download the
mod on your own machine, put the file in here, and the agent pulls it.

## How to put a file here (no terminal needed)

1. Go to <https://github.com/RestoBot0/helloneighborlinux>
2. Switch the branch dropdown to **`arena/50710a4d-helloneighborlinux`**
3. Open the **`incoming`** folder
4. **Add file → Upload files**, then drag the `.zip` in
5. **Commit changes** (leave it committing to the same branch)

### Size limit

GitHub's browser uploader caps out at **25 MB per file**. Anything bigger has to
be split first:

```bash
split -b 20M FoxyReignited.zip FoxyReignited.zip.part-
```

Upload every `*.part-*` piece; they get rejoined on this side with `cat`.

## Rules for this folder

- **Only legitimately-obtained files.** Same standing rule as the rest of this
  project: mods are fine, cracked copies of the base game are not.
- These are **binary blobs in git history**, so keep them small and few.
- Once a file has been analysed and is no longer needed, delete it in a normal
  commit so the working tree stays clean.

## Current contents

| File | Size | Source | Status |
|---|---|---|---|
| _(nothing yet)_ | | | |

## Wanted

| File | Size | Where it comes from |
|---|---|---|
| `Cat_In_The_Hat.zip` | 6.36 MB | <https://www.moddb.com/downloads/cat-in-the-hat> — fits the browser uploader |
| `FoxyReignited.zip` | 26.89 MB | <https://www.moddb.com/mods/foxy-reignited/downloads/foxyreignited> — **too big**, needs splitting |

Known checksums, so a damaged upload gets caught immediately:

```
cb59b42a009d4ac7e87d2ea2e2598b10  Cat_In_The_Hat.zip
37da2176c1c20ecf761fdbdbca63cf55  FoxyReignited.zip
```
