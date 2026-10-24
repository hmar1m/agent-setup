# Veriphex agent setup

`setup.sh` prepares your own Google Cloud project to run Veriphex's sealed agents. Your cloud
admin runs it once, in Cloud Shell, with the command Veriphex shows under **AI apps and agents →
Where agents run**. Cloud Shell already has `gcloud` and is signed in, so nothing is installed.

Every step is one `gcloud` command that also appears in your project's own audit logs. Each step
checks before it creates, so running the script again changes nothing. `--dry-run` prints every
command that would change something and runs none.

## What it creates

Every name starts with `veriphex`.

1. **APIs:** Compute Engine, Confidential Computing, Artifact Registry, Cloud Run, IAM and Cloud
   DNS. Cloud DNS carries the private zones in step 2.
2. **Network `veriphex-agents`:**
   - subnet `veriphex-agents` in your region, with Private Google Access on;
   - Cloud Router `veriphex-agents-router` and Cloud NAT `veriphex-agents-nat`;
   - private DNS zones `veriphex-googleapis` and `veriphex-pkg-dev`, seen only by this network,
     which send Google's API names to `private.googleapis.com`;
   - network firewall policy `veriphex-agents-policy`. Agent machines may reach only Private
     Google Access and Veriphex's control-plane and executor hosts, on HTTPS. Everything else
     out is denied, and everything in is denied.
3. **Service account `veriphex-runtime@<project>`**, which the agent machines run as:
   - `roles/artifactregistry.reader` on each repository you name in `--package-repos`;
   - `roles/confidentialcomputing.workloadUser` and `roles/logging.logWriter` on the project;
   - nothing else.
4. **Service account `veriphex-launcher@<project>`** and the custom role `veriphexAgentLauncher`,
   granted on the project. The role holds only `compute.instances.create`, `.delete`, `.get`,
   `.list`, `.setMetadata`, `.setLabels`, `.setServiceAccount`, `compute.disks.create`,
   `compute.subnetworks.use` and `compute.zoneOperations.get`. The launcher may act as
   `veriphex-runtime` only (`roles/iam.serviceAccountUser` on that one account).
5. **Cloud Run service `veriphex-launcher`**, from Veriphex's launcher image by digest, running as
   `veriphex-launcher@`, with no minimum instances, one CPU and a 180-second request timeout
   (a start may spend up to 100 seconds trying zones).

   The launcher's address is public, and authenticated only by Veriphex's signature. Its code
   refuses everything unsigned and can only start Veriphex's runtime.

   It starts machines only from Veriphex's runtime image, only for packages in the repositories
   you named, only with names starting `vpx-`, and each machine deletes itself when its time is
   up. Every request it receives is in your own Cloud Logging.

With `--builder-account` the script also makes the account your builders use to build agent images
with Cloud Build when they have no Docker (see `GUIDE.md`):
- it enables `cloudbuild.googleapis.com`;
- **Service account `agent-builder@<project>`**, with no key, holding `roles/artifactregistry.writer` on
  each repository you name in `--package-repos` only, `roles/logging.logWriter` on the project, and
  `roles/storage.objectViewer` on `gs://<project>_cloudbuild` only;
- it creates that bucket (uniform access, in the region's multi-region) if it is absent, so the
  binding has a target.

If a repository you name does not exist in this project, the script offers to create it.

At the end it prints:

```
Launcher address: https://veriphex-launcher-….run.app
Runtime account: veriphex-runtime@<project>.iam.gserviceaccount.com
Paste the launcher address into Veriphex: AI apps and agents → Where agents run.
```

## What it does not do

- It creates no key file, for any account.
- It grants no role to Veriphex, or to anyone outside your project. Veriphex holds no Google
  credential at all.
- It opens no port to the internet except the launcher's HTTPS address.

## When it stops

It stops, naming the cause and the fix, when:
- the organisation policy `run.allowedIngress` allows internal traffic only, which would keep
  Veriphex from reaching the launcher;
- the region has too little Confidential VM (N2D) CPU quota for one agent machine;
- the organisation policy `gcp.restrictNonCmekServices` requires your own encryption key for
  Artifact Registry and a repository must be created. Create it yourself with your key, then run
  the script again.

## Options

| Option | Meaning |
|---|---|
| `--project` | your project ID (required) |
| `--region` | e.g. `us-central1` (required) |
| `--veriphex-org` | your Veriphex organisation (required) |
| `--place-key` | the place's public key, base64, from Veriphex (required) |
| `--package-repos` | repositories holding agent packages: `agents`, or `LOCATION-docker.pkg.dev/PROJECT/REPO`, comma-separated (required) |
| `--executor-hosts` | Veriphex executor hosts, comma-separated (required) |
| `--control-plane-hosts` | default `proxyme-hszn.onrender.com` |
| `--machine-type` | default `n2d-standard-2` |
| `--zones` | default `<region>-a,<region>-b,<region>-c`, and `<region>-f` when that zone offers the machine type; tried in order |
| `--launcher-image` | default: this release's launcher, by digest |
| `--release-repo` | default `us-docker.pkg.dev/veriphex-releases/public` |
| `--launcher-url-hint` | the launcher's address, if already known |
| `--builder-account` | also create the Cloud Build account `agent-builder` and its three grants (optional) |
| `--yes` | answer yes to every question |
| `--dry-run` | print what would change; change nothing |
| `--remove` | undo everything the script made |

## Removing it

```
bash setup.sh --remove --project <PROJECT> --region <REGION> --package-repos <repo>[,<repo>...]
```

This deletes any running agent machines, the launcher, the custom role, both service accounts,
the firewall policy, the DNS zones, the NAT, the router, the subnet and the network, and removes
the runtime account's read access from the repositories you name. With `--builder-account` it also
removes the `agent-builder` bindings and account; the `gs://<project>_cloudbuild` bucket stays. It leaves your package
repositories and the APIs as they are, because they hold your own packages and may serve other
work. Then remove the place in Veriphex.
