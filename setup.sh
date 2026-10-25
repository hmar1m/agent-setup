#!/usr/bin/env bash
# Veriphex agent setup: prepares a company's own Google Cloud project to run Veriphex's sealed
# agents, once, from Cloud Shell.
#
# It makes a private network whose machines can reach only Google's APIs and the Veriphex hosts
# named below, two service accounts with the least they need, and a small public launcher that
# starts machines only when Veriphex's signature checks out. It creates no key file and grants
# no role to anyone outside this project. Every step checks before it creates, so running it
# again changes nothing; --remove undoes what it made; --dry-run prints every command that would
# change something and runs none.
#
# Usage:
#   bash setup.sh --project P --region us-central1 --veriphex-org SLUG \
#     --place-key '<public key PEM, base64>' --package-repos agents[,repo...] \
#     --executor-hosts host[,host...] [--yes] [--dry-run]
#   bash setup.sh --remove --project P --region us-central1 [--package-repos ...]
# Optional: --builder-account also makes the build account agent-builder@P for Cloud Build (no key).
set -euo pipefail

# ---------------------------------------------------------------------------------------------
# SET PER RELEASE. The launcher image this copy of the script deploys, by digest. The release
# job prints the digest, which is written here when the script is tagged; the all-zero value is
# refused outside a dry run.
LAUNCHER_DIGEST="sha256:e81de7138d2a5abf55ad49f2245f9b1095f3f467099e94851d7c139d229f8553"
SCRIPT_VERSION="1.0.2"
# ---------------------------------------------------------------------------------------------

DEFAULT_RELEASE_REPO="us-docker.pkg.dev/veriphex-releases/public"
DEFAULT_LAUNCHER_IMAGE="${DEFAULT_RELEASE_REPO}/agent-launcher@${LAUNCHER_DIGEST}"

Q1_SENTENCE="The launcher's address is public, and authenticated only by Veriphex's signature. Its code refuses everything unsigned and can only start Veriphex's runtime."

NETWORK="veriphex-agents"
SUBNET="veriphex-agents"
SUBNET_RANGE="10.10.0.0/24"
ROUTER="veriphex-agents-router"
NAT="veriphex-agents-nat"
FW_POLICY="veriphex-agents-policy"
FW_ASSOC="veriphex-agents"
DNS_ZONE_APIS="veriphex-googleapis"
DNS_ZONE_PKG="veriphex-pkg-dev"
RUNTIME_SA_NAME="veriphex-runtime"
LAUNCHER_SA_NAME="veriphex-launcher"
SERVICE="veriphex-launcher"
ROLE_ID="veriphexAgentLauncher"
BUILDER_SA_NAME="agent-builder"
# private.googleapis.com, and restricted.googleapis.com, which Private Google Access answers on.
PGA_RANGES="199.36.153.8/30,199.36.153.4/30"
PGA_ADDRESSES="199.36.153.8,199.36.153.9,199.36.153.10,199.36.153.11"

# What the launcher may do, and nothing more (plan §5.2). compute.images.useReadOnly is NOT here:
# the boot image comes from the public project confidential-space-images, whose owner already
# grants that permission to every authenticated identity on its own images; the permission is
# only needed in the project that owns the image, and this project owns none.
LAUNCHER_PERMISSIONS="compute.disks.create,compute.instances.create,compute.instances.delete,compute.instances.get,compute.instances.list,compute.instances.setLabels,compute.instances.setMetadata,compute.instances.setServiceAccount,compute.subnetworks.use,compute.zoneOperations.get"

# Dns is enabled as well as the five the plan names: Private Google Access needs a private
# zone that points googleapis.com and pkg.dev at private.googleapis.com, or a machine whose
# egress is denied cannot reach Artifact Registry or attestation at all.
APIS="compute.googleapis.com confidentialcomputing.googleapis.com artifactregistry.googleapis.com run.googleapis.com iam.googleapis.com dns.googleapis.com"

PROJECT=""
REGION=""
ORG=""
PLACE_KEY=""
URL_HINT=""
PACKAGE_REPOS=""
MACHINE_TYPE="n2d-standard-2"
ZONES=""
CONTROL_PLANE_HOSTS="proxyme-hszn.onrender.com"
EXECUTOR_HOSTS=""
LAUNCHER_IMAGE="$DEFAULT_LAUNCHER_IMAGE"
RELEASE_REPO="$DEFAULT_RELEASE_REPO"
ASSUME_YES=0
DRY_RUN=0
REMOVE=0
BUILDER=0

say() { printf '%s\n' "$*"; }
stop() { printf '\nStopped: %s\n' "$*" >&2; exit 1; }

usage() {
  sed -n '12,16p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="${2:-}"; shift 2 ;;
    --region) REGION="${2:-}"; shift 2 ;;
    --veriphex-org) ORG="${2:-}"; shift 2 ;;
    --place-key) PLACE_KEY="${2:-}"; shift 2 ;;
    --launcher-url-hint) URL_HINT="${2:-}"; shift 2 ;;
    --package-repos) PACKAGE_REPOS="${2:-}"; shift 2 ;;
    --machine-type) MACHINE_TYPE="${2:-}"; shift 2 ;;
    --zones) ZONES="${2:-}"; shift 2 ;;
    --control-plane-hosts) CONTROL_PLANE_HOSTS="${2:-}"; shift 2 ;;
    --executor-hosts) EXECUTOR_HOSTS="${2:-}"; shift 2 ;;
    --launcher-image) LAUNCHER_IMAGE="${2:-}"; shift 2 ;;
    --release-repo) RELEASE_REPO="${2:-}"; shift 2 ;;
    --yes) ASSUME_YES=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --remove) REMOVE=1; shift ;;
    --builder-account) BUILDER=1; shift ;;
    -h|--help) usage ;;
    *) stop "unknown option $1. Run with --help to see the options." ;;
  esac
done

# --- Commands --------------------------------------------------------------------------------

# A command that only reads. It runs in a dry run too, because the plan depends on what exists.
look() { gcloud "$@" 2>/dev/null; }

# A command that changes something. A dry run prints it and runs nothing.
change() {
  if [ "$DRY_RUN" = 1 ]; then
    printf '[dry run] gcloud'; printf ' %q' "$@"; printf '\n'
  else
    printf '+ gcloud'; printf ' %q' "$@"; printf '\n'
    gcloud "$@"
  fi
}

ask() {
  # ask "question" -> 0 for yes. --yes answers yes; no terminal answer is no.
  if [ "$ASSUME_YES" = 1 ]; then say "$1 [y/N] y"; return 0; fi
  local answer=""
  printf '%s [y/N] ' "$1"
  read -r answer || answer=""
  [ -t 0 ] || printf '%s\n' "$answer"
  case "$answer" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

sha256_hex() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -c1-64; else shasum -a 256 | cut -c1-64; fi
}

# --- Checks on the input ---------------------------------------------------------------------

[ -n "$PROJECT" ] || stop "--project is required."
[ -n "$REGION" ] || stop "--region is required."
printf '%s' "$PROJECT" | grep -Eq '^[a-z][a-z0-9-]{4,28}[a-z0-9]$' || stop "--project $PROJECT is not a Google Cloud project ID."
printf '%s' "$REGION" | grep -Eq '^[a-z]+-[a-z]+[0-9]+$' || stop "--region $REGION is not a Google Cloud region."
ZONES_GIVEN="$ZONES"
[ -n "$ZONES" ] || ZONES="${REGION}-a,${REGION}-b,${REGION}-c"

RUNTIME_SA="${RUNTIME_SA_NAME}@${PROJECT}.iam.gserviceaccount.com"
LAUNCHER_SA="${LAUNCHER_SA_NAME}@${PROJECT}.iam.gserviceaccount.com"
ROLE_NAME="projects/${PROJECT}/roles/${ROLE_ID}"
BUILDER_SA="${BUILDER_SA_NAME}@${PROJECT}.iam.gserviceaccount.com"
BUILDER_BUCKET="${PROJECT}_cloudbuild"
[ "$BUILDER" = 0 ] || APIS="$APIS cloudbuild.googleapis.com"
# The bucket's multi-region: the one that holds the region.
case "$REGION" in
  us-*|northamerica-*|southamerica-*) BUCKET_LOCATION="US" ;;
  europe-*|me-*) BUCKET_LOCATION="EU" ;;
  asia-*|australia-*) BUCKET_LOCATION="ASIA" ;;
  *) BUCKET_LOCATION="$REGION" ;;
esac

# Package repositories, each as LOCATION-docker.pkg.dev/PROJECT/REPO. A bare name means a
# repository in this project and region.
REPO_PATHS=""
if [ -n "$PACKAGE_REPOS" ]; then
  for spec in $(printf '%s' "$PACKAGE_REPOS" | tr ',' ' '); do
    case "$spec" in
      */*) path="${spec%/}" ;;
      *) path="${REGION}-docker.pkg.dev/${PROJECT}/${spec}" ;;
    esac
    printf '%s' "$path" | grep -Eq '^[a-z0-9-]+-docker\.pkg\.dev/[a-z][a-z0-9-]+/[a-z][a-z0-9-]*$' \
      || stop "--package-repos: $spec is not an Artifact Registry Docker repository (LOCATION-docker.pkg.dev/PROJECT/REPO)."
    REPO_PATHS="${REPO_PATHS:+$REPO_PATHS,}$path"
  done
fi
repo_loc() { local h="${1%%/*}"; printf '%s' "${h%-docker.pkg.dev}"; }
repo_project() { local r="${1#*/}"; printf '%s' "${r%%/*}"; }
repo_name() { printf '%s' "${1##*/}"; }

if [ "$REMOVE" = 0 ]; then
  [ -n "$ORG" ] || stop "--veriphex-org is required."
  printf '%s' "$ORG" | grep -Eq '^[a-z0-9][a-z0-9_-]{0,62}$' || stop "--veriphex-org $ORG is not a Veriphex organisation name."
  [ -n "$PLACE_KEY" ] || stop "--place-key is required. Copy the whole command from Veriphex."
  [ -n "$REPO_PATHS" ] || stop "--package-repos is required: the repositories that hold your agent packages."
  [ -n "$EXECUTOR_HOSTS" ] || stop "--executor-hosts is required. Copy the whole command from Veriphex."
  PLACE_KEY_PEM="$(printf '%s' "$PLACE_KEY" | base64 --decode 2>/dev/null || true)"
  case "$PLACE_KEY_PEM" in
    "-----BEGIN PUBLIC KEY-----"*"-----END PUBLIC KEY-----"*) ;;
    *) stop "--place-key is not a base64 public key. Copy the whole command from Veriphex." ;;
  esac
  printf '%s' "$LAUNCHER_IMAGE" | grep -Eq '@sha256:[0-9a-f]{64}$' || stop "--launcher-image must name the image by digest (@sha256:...)."
  if [ "$DRY_RUN" = 0 ] && [ "${LAUNCHER_IMAGE##*@}" = "sha256:0000000000000000000000000000000000000000000000000000000000000000" ]; then
    stop "this copy of the setup script names no launcher release. Use the command shown in Veriphex."
  fi
  case "$MACHINE_TYPE" in
    n2d-*|c2d-*|c3d-*|c3-*) ;;
    *) stop "--machine-type $MACHINE_TYPE cannot run as a Confidential VM. Use n2d-standard-2." ;;
  esac
  for h in $(printf '%s,%s' "$CONTROL_PLANE_HOSTS" "$EXECUTOR_HOSTS" | tr ',' ' '); do
    printf '%s' "$h" | grep -Eq '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$' \
      || stop "$h is not a host name (no scheme, no path, no wildcard)."
  done
  if [ -n "$URL_HINT" ]; then
    printf '%s' "$URL_HINT" | grep -Eq '^https://[a-z0-9.-]+$' || stop "--launcher-url-hint must be https://host with no path."
  fi
fi

look projects describe "$PROJECT" --format='value(projectId)' >/dev/null \
  || stop "project $PROJECT was not found, or you cannot see it. Select the right project in Cloud Shell."

# --- Shared checks for what exists ----------------------------------------------------------

has_project_binding() {  # role member
  [ -n "$(look projects get-iam-policy "$PROJECT" --flatten='bindings[].members' \
    --filter="bindings.role=$1 AND bindings.members=$2" --format='value(bindings.role)')" ]
}
has_repo_binding() {  # repo-path role member
  [ -n "$(look artifacts repositories get-iam-policy "$(repo_name "$1")" --project "$(repo_project "$1")" \
    --location "$(repo_loc "$1")" --flatten='bindings[].members' \
    --filter="bindings.role=$2 AND bindings.members=$3" --format='value(bindings.role)')" ]
}
has_sa_binding() {  # sa role member
  [ -n "$(look iam service-accounts get-iam-policy "$1" --project "$PROJECT" --flatten='bindings[].members' \
    --filter="bindings.role=$2 AND bindings.members=$3" --format='value(bindings.role)')" ]
}
has_bucket_binding() {  # bucket role member
  [ -n "$(look storage buckets get-iam-policy "gs://$1" --project "$PROJECT" --flatten='bindings[].members' \
    --filter="bindings.role=$2 AND bindings.members=$3" --format='value(bindings.role)')" ]
}
bucket_exists() { look storage buckets describe "gs://$1" --project "$PROJECT" --format='value(name)' >/dev/null; }
sa_exists() { look iam service-accounts describe "$1" --project "$PROJECT" --format='value(email)' >/dev/null; }
role_exists() { look iam roles describe "$ROLE_ID" --project "$PROJECT" --format='value(name)' >/dev/null; }
# Whether the policy carries the association. gcloud has no `associations list` for a global network
# firewall policy; the policy's own description lists its associations, separated by ';'.
fw_associated() {
  look compute network-firewall-policies describe "$FW_POLICY" --global --project "$PROJECT" \
    --format='value(associations[].name)' | tr ';' '\n' | grep -qx "$FW_ASSOC"
}
zone_exists() { look dns managed-zones describe "$1" --project "$PROJECT" --format='value(name)' >/dev/null; }
record_exists() { [ -n "$(look dns record-sets list --zone "$1" --project "$PROJECT" --name "$2" --type "$3" --format='value(name)')" ]; }

# Effective organisation policy, as JSON (empty when it cannot be read).
policy_json() { look resource-manager org-policies describe "$1" --project "$PROJECT" --effective --format=json || true; }

# ===============================================================================================
# --remove
# ===============================================================================================
if [ "$REMOVE" = 1 ]; then
  say "Removing Veriphex agents from project $PROJECT ($REGION)."
  if [ "$DRY_RUN" = 0 ] && ! ask "Delete the launcher, the two service accounts, the network and every Veriphex agent machine?"; then
    stop "nothing was removed."
  fi

  say "Agent machines"
  look compute instances list --project "$PROJECT" --filter='labels.veriphex-copy:*' \
    --format='value(name,zone.basename())' | while read -r name zone; do
      case "$name" in vpx-*) change compute instances delete "$name" --project "$PROJECT" --zone "$zone" --quiet ;; esac
    done || true

  say "Launcher"
  if look run services describe "$SERVICE" --project "$PROJECT" --region "$REGION" --format='value(metadata.name)' >/dev/null; then
    change run services delete "$SERVICE" --project "$PROJECT" --region "$REGION" --quiet
  fi
  if has_project_binding "$ROLE_NAME" "serviceAccount:$LAUNCHER_SA"; then
    change projects remove-iam-policy-binding "$PROJECT" --member "serviceAccount:$LAUNCHER_SA" --role "$ROLE_NAME" --condition=None --quiet
  fi
  if role_exists && [ -z "$(look iam roles describe "$ROLE_ID" --project "$PROJECT" --format='value(deleted)')" ]; then
    change iam roles delete "$ROLE_ID" --project "$PROJECT" --quiet
  fi
  if sa_exists "$LAUNCHER_SA"; then
    change iam service-accounts delete "$LAUNCHER_SA" --project "$PROJECT" --quiet
  fi

  say "Runtime account"
  for role in roles/confidentialcomputing.workloadUser roles/logging.logWriter; do
    if has_project_binding "$role" "serviceAccount:$RUNTIME_SA"; then
      change projects remove-iam-policy-binding "$PROJECT" --member "serviceAccount:$RUNTIME_SA" --role "$role" --condition=None --quiet
    fi
  done
  for repo in $(printf '%s' "$REPO_PATHS" | tr ',' ' '); do
    if has_repo_binding "$repo" roles/artifactregistry.reader "serviceAccount:$RUNTIME_SA"; then
      change artifacts repositories remove-iam-policy-binding "$(repo_name "$repo")" --project "$(repo_project "$repo")" \
        --location "$(repo_loc "$repo")" --member "serviceAccount:$RUNTIME_SA" --role roles/artifactregistry.reader
    fi
  done
  if sa_exists "$RUNTIME_SA"; then
    change iam service-accounts delete "$RUNTIME_SA" --project "$PROJECT" --quiet
  fi

  if [ "$BUILDER" = 1 ]; then
    say "Build account"
    if has_project_binding roles/logging.logWriter "serviceAccount:$BUILDER_SA"; then
      change projects remove-iam-policy-binding "$PROJECT" --member "serviceAccount:$BUILDER_SA" --role roles/logging.logWriter --condition=None --quiet
    fi
    if bucket_exists "$BUILDER_BUCKET" && has_bucket_binding "$BUILDER_BUCKET" roles/storage.objectViewer "serviceAccount:$BUILDER_SA"; then
      change storage buckets remove-iam-policy-binding "gs://$BUILDER_BUCKET" --project "$PROJECT" \
        --member "serviceAccount:$BUILDER_SA" --role roles/storage.objectViewer
    fi
    for repo in $(printf '%s' "$REPO_PATHS" | tr ',' ' '); do
      if has_repo_binding "$repo" roles/artifactregistry.writer "serviceAccount:$BUILDER_SA"; then
        change artifacts repositories remove-iam-policy-binding "$(repo_name "$repo")" --project "$(repo_project "$repo")" \
          --location "$(repo_loc "$repo")" --member "serviceAccount:$BUILDER_SA" --role roles/artifactregistry.writer
      fi
    done
    if sa_exists "$BUILDER_SA"; then
      change iam service-accounts delete "$BUILDER_SA" --project "$PROJECT" --quiet
    fi
  fi

  say "Network"
  if look compute network-firewall-policies describe "$FW_POLICY" --global --project "$PROJECT" --format='value(name)' >/dev/null; then
    if fw_associated; then
      change compute network-firewall-policies associations delete --firewall-policy "$FW_POLICY" --name "$FW_ASSOC" \
        --global-firewall-policy --project "$PROJECT"
    fi
    change compute network-firewall-policies delete "$FW_POLICY" --global --project "$PROJECT" --quiet
  fi
  for zone_pair in "$DNS_ZONE_APIS:googleapis.com." "$DNS_ZONE_PKG:pkg.dev."; do
    zone="${zone_pair%%:*}"; domain="${zone_pair#*:}"
    if zone_exists "$zone"; then
      if record_exists "$zone" "*.$domain" CNAME; then
        change dns record-sets delete "*.$domain" --zone "$zone" --type CNAME --project "$PROJECT"
      fi
      if [ "$zone" = "$DNS_ZONE_APIS" ] && record_exists "$zone" "private.googleapis.com." A; then
        change dns record-sets delete private.googleapis.com. --zone "$zone" --type A --project "$PROJECT"
      fi
      change dns managed-zones delete "$zone" --project "$PROJECT" --quiet
    fi
  done
  if look compute routers nats describe "$NAT" --router "$ROUTER" --region "$REGION" --project "$PROJECT" --format='value(name)' >/dev/null; then
    change compute routers nats delete "$NAT" --router "$ROUTER" --region "$REGION" --project "$PROJECT" --quiet
  fi
  if look compute routers describe "$ROUTER" --region "$REGION" --project "$PROJECT" --format='value(name)' >/dev/null; then
    change compute routers delete "$ROUTER" --region "$REGION" --project "$PROJECT" --quiet
  fi
  if look compute networks subnets describe "$SUBNET" --region "$REGION" --project "$PROJECT" --format='value(name)' >/dev/null; then
    change compute networks subnets delete "$SUBNET" --region "$REGION" --project "$PROJECT" --quiet
  fi
  if look compute networks describe "$NETWORK" --project "$PROJECT" --format='value(name)' >/dev/null; then
    change compute networks delete "$NETWORK" --project "$PROJECT" --quiet
  fi

  say ""
  say "Removed. The package repositories, the APIs and the bucket gs://$BUILDER_BUCKET were left as they were: they hold your own"
  say "packages and may serve other work. Delete a repository yourself with"
  say "  gcloud artifacts repositories delete REPO --location LOCATION --project $PROJECT"
  say "Then remove the place in Veriphex: AI apps and agents → Where agents run."
  exit 0
fi

# ===============================================================================================
# Setup
# ===============================================================================================
say "Veriphex agent setup $SCRIPT_VERSION for project $PROJECT ($REGION), organisation $ORG."
say "It creates: network $NETWORK, service accounts $RUNTIME_SA_NAME and $LAUNCHER_SA_NAME, the role"
say "$ROLE_ID, and the Cloud Run service $SERVICE. It creates no key file and grants nothing to"
say "anyone outside this project."
if [ "$DRY_RUN" = 1 ]; then
  say "Dry run: commands that would change something are printed and not run."
elif ! ask "Continue?"; then
  stop "nothing was changed."
fi

# --- Organisation policies that would block the launcher -------------------------------------
# run.allowedIngress: the launcher must accept traffic from the internet, because Veriphex has
# no Google identity and no network inside this project.
ingress_policy="$(policy_json run.allowedIngress)"
if printf '%s' "$ingress_policy" | tr -d ' \n' | grep -Eq '"(allValues|allValue)":"DENY"|"denyAll":true'; then
  ingress_blocked=1
elif printf '%s' "$ingress_policy" | tr -d ' \n' | grep -Eq '"allowedValues":\['; then
  if printf '%s' "$ingress_policy" | tr -d ' \n' | grep -Eq '"allowedValues":\[[^]]*"(is:)?all"'; then ingress_blocked=0; else ingress_blocked=1; fi
elif printf '%s' "$ingress_policy" | tr -d ' \n' | grep -Eq '"deniedValues":\[[^]]*"(is:)?all"'; then
  ingress_blocked=1
else
  ingress_blocked=0
fi
if [ "$ingress_blocked" = 1 ]; then
  stop "the organisation policy run.allowedIngress allows Cloud Run services to accept internal traffic only, so Veriphex could never reach the launcher. Fix: an organisation policy administrator allows the value \"all\" for run.allowedIngress on project $PROJECT (IAM & Admin → Organisation policies → Allowed ingress settings (Cloud Run)), then run this command again."
fi

# --- 1. APIs ---------------------------------------------------------------------------------
say "1. APIs"
enabled="$(look services list --enabled --project "$PROJECT" --format='value(config.name)' || true)"
missing=""
for api in $APIS; do
  printf '%s\n' "$enabled" | grep -qx "$api" || missing="$missing $api"
done
if [ -n "$missing" ]; then
  # shellcheck disable=SC2086
  change services enable $missing --project "$PROJECT"
else
  say "   already enabled"
fi

# --- Zones -------------------------------------------------------------------------------------
# The launcher tries the zones in order and moves on when one has no machine free. Zone f joins
# the default list where it offers the machine type (us-central1-f does; most regions have no f).
if [ -z "$ZONES_GIVEN" ] && look compute machine-types describe "$MACHINE_TYPE" --zone "${REGION}-f" \
    --project "$PROJECT" --format='value(name)' | grep -qx "$MACHINE_TYPE"; then
  ZONES="${ZONES},${REGION}-f"
fi
say "   Zones: $ZONES"

# --- Confidential VM quota -------------------------------------------------------------------
family="$(printf '%s' "${MACHINE_TYPE%%-*}" | tr '[:lower:]' '[:upper:]')"
metric="${family}_CPUS"
vcpus="${MACHINE_TYPE##*-}"
case "$vcpus" in ''|*[!0-9]*) vcpus=2 ;; esac
quota_line="$(look compute regions describe "$REGION" --project "$PROJECT" --flatten=quotas \
  --format='csv[no-heading](quotas.metric,quotas.limit,quotas.usage)' | grep "^${metric}," || true)"
if [ -n "$quota_line" ]; then
  limit="$(printf '%s' "$quota_line" | cut -d, -f2 | cut -d. -f1)"
  usage="$(printf '%s' "$quota_line" | cut -d, -f3 | cut -d. -f1)"
  if [ $((limit - usage)) -lt "$vcpus" ]; then
    stop "the Confidential VM quota in $REGION is too small: $metric has $((limit - usage)) of $limit CPUs free, and one agent machine ($MACHINE_TYPE) needs $vcpus. Fix: request more $metric in $REGION (IAM & Admin → Quotas), then run this command again."
  fi
elif [ "$DRY_RUN" = 1 ] && [ -n "$missing" ]; then
  say "   (dry run: the $metric quota is read once Compute Engine is enabled)"
else
  stop "the Confidential VM quota in $REGION could not be read: $metric is not listed for this project. Fix: check that Compute Engine is enabled and request $metric in $REGION (IAM & Admin → Quotas), then run this command again."
fi

# --- Package repositories -------------------------------------------------------------------
say "Package repositories"
for repo in $(printf '%s' "$REPO_PATHS" | tr ',' ' '); do
  name="$(repo_name "$repo")"; loc="$(repo_loc "$repo")"; rproject="$(repo_project "$repo")"
  if look artifacts repositories describe "$name" --project "$rproject" --location "$loc" --format='value(name)' >/dev/null; then
    say "   $repo exists"
    continue
  fi
  [ "$rproject" = "$PROJECT" ] || stop "repository $repo does not exist, and it is in another project. Create it there, then run this command again."
  ask "Create repository $name in $loc?" || stop "repository $repo does not exist. Create it, or name one that does, then run this command again."
  cmek_policy="$(policy_json gcp.restrictNonCmekServices)"
  if printf '%s' "$cmek_policy" | tr -d ' \n' | grep -Eq '"deniedValues":\[[^]]*artifactregistry\.googleapis\.com'; then
    stop "the organisation policy gcp.restrictNonCmekServices requires a customer-managed encryption key for Artifact Registry, so this script cannot create $name. Fix: create the repository yourself with your Cloud KMS key (gcloud artifacts repositories create $name --location $loc --repository-format=docker --kms-key KEY), then run this command again."
  fi
  change artifacts repositories create "$name" --project "$rproject" --location "$loc" \
    --repository-format=docker --description="Agent packages run by Veriphex"
done

# --- 2. Network ------------------------------------------------------------------------------
say "2. Network $NETWORK"
if ! look compute networks describe "$NETWORK" --project "$PROJECT" --format='value(name)' >/dev/null; then
  change compute networks create "$NETWORK" --project "$PROJECT" --subnet-mode=custom
fi
if ! look compute networks subnets describe "$SUBNET" --region "$REGION" --project "$PROJECT" --format='value(name)' >/dev/null; then
  change compute networks subnets create "$SUBNET" --project "$PROJECT" --network "$NETWORK" --region "$REGION" \
    --range "$SUBNET_RANGE" --enable-private-ip-google-access
elif [ "$(look compute networks subnets describe "$SUBNET" --region "$REGION" --project "$PROJECT" --format='value(privateIpGoogleAccess)')" != "True" ]; then
  change compute networks subnets update "$SUBNET" --project "$PROJECT" --region "$REGION" --enable-private-ip-google-access
fi
if ! look compute routers describe "$ROUTER" --region "$REGION" --project "$PROJECT" --format='value(name)' >/dev/null; then
  change compute routers create "$ROUTER" --project "$PROJECT" --network "$NETWORK" --region "$REGION"
fi
if ! look compute routers nats describe "$NAT" --router "$ROUTER" --region "$REGION" --project "$PROJECT" --format='value(name)' >/dev/null; then
  change compute routers nats create "$NAT" --project "$PROJECT" --router "$ROUTER" --region "$REGION" \
    --nat-all-subnet-ip-ranges --auto-allocate-nat-external-ips
fi
# Private Google Access through private.googleapis.com: Google's API names resolve, on this
# network only, to the ranges the firewall policy below allows.
if ! zone_exists "$DNS_ZONE_APIS"; then
  change dns managed-zones create "$DNS_ZONE_APIS" --project "$PROJECT" --dns-name googleapis.com. \
    --visibility private --networks "$NETWORK" --description "Private Google Access for Veriphex agents"
fi
if ! record_exists "$DNS_ZONE_APIS" private.googleapis.com. A; then
  change dns record-sets create private.googleapis.com. --zone "$DNS_ZONE_APIS" --project "$PROJECT" --type A --ttl 300 --rrdatas "$PGA_ADDRESSES"
fi
if ! record_exists "$DNS_ZONE_APIS" '*.googleapis.com.' CNAME; then
  change dns record-sets create '*.googleapis.com.' --zone "$DNS_ZONE_APIS" --project "$PROJECT" --type CNAME --ttl 300 --rrdatas private.googleapis.com.
fi
if ! zone_exists "$DNS_ZONE_PKG"; then
  change dns managed-zones create "$DNS_ZONE_PKG" --project "$PROJECT" --dns-name pkg.dev. \
    --visibility private --networks "$NETWORK" --description "Private Google Access for Veriphex agents"
fi
if ! record_exists "$DNS_ZONE_PKG" '*.pkg.dev.' CNAME; then
  change dns record-sets create '*.pkg.dev.' --zone "$DNS_ZONE_PKG" --project "$PROJECT" --type CNAME --ttl 300 --rrdatas private.googleapis.com.
fi

# --- 3. Runtime service account --------------------------------------------------------------
# Created before the firewall policy, whose egress rules target it.
say "3. Service account $RUNTIME_SA"
if ! sa_exists "$RUNTIME_SA"; then
  change iam service-accounts create "$RUNTIME_SA_NAME" --project "$PROJECT" --display-name "Veriphex agent runtime"
fi
for repo in $(printf '%s' "$REPO_PATHS" | tr ',' ' '); do
  if ! has_repo_binding "$repo" roles/artifactregistry.reader "serviceAccount:$RUNTIME_SA"; then
    change artifacts repositories add-iam-policy-binding "$(repo_name "$repo")" --project "$(repo_project "$repo")" \
      --location "$(repo_loc "$repo")" --member "serviceAccount:$RUNTIME_SA" --role roles/artifactregistry.reader
  fi
done
for role in roles/confidentialcomputing.workloadUser roles/logging.logWriter; do
  if ! has_project_binding "$role" "serviceAccount:$RUNTIME_SA"; then
    change projects add-iam-policy-binding "$PROJECT" --member "serviceAccount:$RUNTIME_SA" --role "$role" --condition=None
  fi
done

# --- Firewall policy -------------------------------------------------------------------------
say "   Firewall policy $FW_POLICY"
if ! look compute network-firewall-policies describe "$FW_POLICY" --global --project "$PROJECT" --format='value(name)' >/dev/null; then
  change compute network-firewall-policies create "$FW_POLICY" --global --project "$PROJECT" \
    --description "Veriphex agents: egress only to Google APIs and Veriphex; no ingress"
fi
rule_exists() { look compute network-firewall-policies rules describe "$1" --firewall-policy "$FW_POLICY" --global-firewall-policy --project "$PROJECT" --format='value(priority)' >/dev/null; }
VERIPHEX_HOSTS="$CONTROL_PLANE_HOSTS,$EXECUTOR_HOSTS"
if ! rule_exists 1000; then
  change compute network-firewall-policies rules create 1000 --firewall-policy "$FW_POLICY" --global-firewall-policy --project "$PROJECT" \
    --direction EGRESS --action allow --layer4-configs tcp:443 --dest-fqdns "$VERIPHEX_HOSTS" \
    --target-service-accounts "$RUNTIME_SA" --description "Veriphex control plane and executor"
fi
if ! rule_exists 1100; then
  change compute network-firewall-policies rules create 1100 --firewall-policy "$FW_POLICY" --global-firewall-policy --project "$PROJECT" \
    --direction EGRESS --action allow --layer4-configs tcp:443 --dest-ip-ranges "$PGA_RANGES" \
    --target-service-accounts "$RUNTIME_SA" --description "Private Google Access"
fi
if ! rule_exists 65000; then
  change compute network-firewall-policies rules create 65000 --firewall-policy "$FW_POLICY" --global-firewall-policy --project "$PROJECT" \
    --direction EGRESS --action deny --layer4-configs all --dest-ip-ranges 0.0.0.0/0 \
    --target-service-accounts "$RUNTIME_SA" --description "Everything else out"
fi
if ! rule_exists 65001; then
  change compute network-firewall-policies rules create 65001 --firewall-policy "$FW_POLICY" --global-firewall-policy --project "$PROJECT" \
    --direction INGRESS --action deny --layer4-configs all --src-ip-ranges 0.0.0.0/0 --description "Everything in"
fi
if ! fw_associated; then
  change compute network-firewall-policies associations create --firewall-policy "$FW_POLICY" --network "$NETWORK" \
    --name "$FW_ASSOC" --global-firewall-policy --project "$PROJECT"
fi

# --- 4. Launcher service account and its role ------------------------------------------------
say "4. Service account $LAUNCHER_SA and role $ROLE_ID"
if ! sa_exists "$LAUNCHER_SA"; then
  change iam service-accounts create "$LAUNCHER_SA_NAME" --project "$PROJECT" --display-name "Veriphex agent launcher"
fi
if ! role_exists; then
  change iam roles create "$ROLE_ID" --project "$PROJECT" --title "Veriphex agent launcher" \
    --description "Start and delete Veriphex agent machines" --permissions "$LAUNCHER_PERMISSIONS" --stage GA
else
  if [ -n "$(look iam roles describe "$ROLE_ID" --project "$PROJECT" --format='value(deleted)')" ]; then
    change iam roles undelete "$ROLE_ID" --project "$PROJECT"
  fi
  have="$( (look iam roles describe "$ROLE_ID" --project "$PROJECT" --format='value(includedPermissions)' || true) | tr ';,' '\n\n' | sort | tr '\n' ',' | sed 's/,$//')"
  want="$(printf '%s' "$LAUNCHER_PERMISSIONS" | tr ',' '\n' | sort | tr '\n' ',' | sed 's/,$//')"
  if [ "$have" != "$want" ]; then
    change iam roles update "$ROLE_ID" --project "$PROJECT" --permissions "$LAUNCHER_PERMISSIONS" --quiet
  fi
fi
if ! has_project_binding "$ROLE_NAME" "serviceAccount:$LAUNCHER_SA"; then
  change projects add-iam-policy-binding "$PROJECT" --member "serviceAccount:$LAUNCHER_SA" --role "$ROLE_NAME" --condition=None
fi
if ! has_sa_binding "$RUNTIME_SA" roles/iam.serviceAccountUser "serviceAccount:$LAUNCHER_SA"; then
  change iam service-accounts add-iam-policy-binding "$RUNTIME_SA" --project "$PROJECT" \
    --member "serviceAccount:$LAUNCHER_SA" --role roles/iam.serviceAccountUser
fi

# --- Build account (optional) ----------------------------------------------------------------
if [ "$BUILDER" = 1 ]; then
  say "Build account $BUILDER_SA"
  if ! sa_exists "$BUILDER_SA"; then
    change iam service-accounts create "$BUILDER_SA_NAME" --project "$PROJECT" --display-name "Agent image builds (Cloud Build)"
  fi
  for repo in $(printf '%s' "$REPO_PATHS" | tr ',' ' '); do
    if ! has_repo_binding "$repo" roles/artifactregistry.writer "serviceAccount:$BUILDER_SA"; then
      change artifacts repositories add-iam-policy-binding "$(repo_name "$repo")" --project "$(repo_project "$repo")" \
        --location "$(repo_loc "$repo")" --member "serviceAccount:$BUILDER_SA" --role roles/artifactregistry.writer
    fi
  done
  if ! has_project_binding roles/logging.logWriter "serviceAccount:$BUILDER_SA"; then
    change projects add-iam-policy-binding "$PROJECT" --member "serviceAccount:$BUILDER_SA" --role roles/logging.logWriter --condition=None
  fi
  if ! bucket_exists "$BUILDER_BUCKET"; then
    change storage buckets create "gs://$BUILDER_BUCKET" --project "$PROJECT" --location "$BUCKET_LOCATION" --uniform-bucket-level-access
  fi
  if ! bucket_exists "$BUILDER_BUCKET" || ! has_bucket_binding "$BUILDER_BUCKET" roles/storage.objectViewer "serviceAccount:$BUILDER_SA"; then
    change storage buckets add-iam-policy-binding "gs://$BUILDER_BUCKET" --project "$PROJECT" \
      --member "serviceAccount:$BUILDER_SA" --role roles/storage.objectViewer
  fi
fi

# --- 5. Launcher -----------------------------------------------------------------------------
say "5. Launcher $SERVICE"
say ""
say "$Q1_SENTENCE"
say ""

service_url() { look run services describe "$SERVICE" --project "$PROJECT" --region "$REGION" --format='value(status.url)' || true; }
PENDING_URL="https://pending.invalid"

env_file="$(mktemp "${TMPDIR:-/tmp}/veriphex-launcher-env.XXXXXX")"
trap 'rm -f "$env_file"' EXIT
write_env() {  # launcher-url
  {
    printf 'VERIPHEX_PLACE_PUBLIC_KEY: |\n'
    printf '%s\n' "$PLACE_KEY_PEM" | sed '/^$/d; s/^/  /'
    printf 'VERIPHEX_LAUNCHER_URL: "%s"\n' "$1"
    printf 'VERIPHEX_RELEASE_REPO: "%s"\n' "$RELEASE_REPO"
    printf 'ALLOWED_PACKAGE_REPOS: "%s"\n' "$REPO_PATHS"
    printf 'PROJECT: "%s"\n' "$PROJECT"
    printf 'ZONES: "%s"\n' "$ZONES"
    printf 'SUBNET: "%s"\n' "$SUBNET"
    printf 'RUNTIME_SERVICE_ACCOUNT: "%s"\n' "$RUNTIME_SA"
    printf 'MACHINE_TYPE: "%s"\n' "$MACHINE_TYPE"
    printf 'LAUNCHER_VERSION: "%s"\n' "$SCRIPT_VERSION"
  } >"$env_file"
}
config_label() {  # A fingerprint of what is deployed, so a second run can tell nothing changed.
  { printf '%s\n%s\n' "$LAUNCHER_IMAGE" "$LAUNCHER_SA"; cat "$env_file"; } | sha256_hex | cut -c1-16
}
show_env() {
  [ "$DRY_RUN" = 1 ] || return 0
  sed -n '/^[A-Z_]*: /p' "$env_file" | sed 's/^\([A-Z_]*\): "\{0,1\}\([^"]*\)"\{0,1\}$/[dry run]   env \1=\2/; s/^\(\[dry run\]   env VERIPHEX_PLACE_PUBLIC_KEY=\)|$/\1(the place key, PEM)/'
}

url="$(service_url)"
env_url="${url:-${URL_HINT:-$PENDING_URL}}"
write_env "$env_url"
label="$(config_label)"
current_label="$(look run services describe "$SERVICE" --project "$PROJECT" --region "$REGION" --format='value(metadata.labels.veriphex-config)' || true)"
if [ -n "$url" ] && [ "$current_label" = "$label" ]; then
  say "   already deployed"
else
  change run deploy "$SERVICE" --project "$PROJECT" --region "$REGION" --image "$LAUNCHER_IMAGE" \
    --service-account "$LAUNCHER_SA" --no-invoker-iam-check --ingress all \
    --min-instances 0 --max-instances 3 --cpu 1 --memory 512Mi --timeout 180 \
    --env-vars-file "$env_file" --labels "veriphex-config=$label,veriphex-org=$ORG" --quiet
  show_env
  url="$(service_url)"
  if [ -z "$url" ] && [ "$DRY_RUN" = 1 ]; then url="${URL_HINT:-https://veriphex-launcher-<known after deploy>.run.app}"; fi
  [ -n "$url" ] || stop "the launcher was deployed but Cloud Run reported no address. Run this command again."
  if [ "$url" != "$env_url" ]; then
    write_env "$url"
    change run services update "$SERVICE" --project "$PROJECT" --region "$REGION" \
      --update-env-vars "VERIPHEX_LAUNCHER_URL=$url" --update-labels "veriphex-config=$(config_label)" --quiet
  fi
fi

say ""
say "Launcher address: $url"
say "Runtime account: $RUNTIME_SA"
say "Paste the launcher address into Veriphex: AI apps and agents → Where agents run."
