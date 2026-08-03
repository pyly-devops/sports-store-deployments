{{/*
================================================================================
  sports-store — template helpers

  Four jobs live here:
    1. sports-store.svc        — apply serviceDefaults to one service entry
    2. sports-store.image      — build an image ref AND refuse to ship `latest`
    3. sports-store.labels     — the standard label set, in one place
    4. sports-store.secretName — resolve created-vs-existing Secret names

  Everything else is deliberately not abstracted. A helper that saves three
  lines but has to be read twice to understand one manifest is a net loss.
================================================================================
*/}}


{{/*
--------------------------------------------------------------------------------
  sports-store.svc — merge one service's overrides over serviceDefaults.

  THE MERGE IS SHALLOW, AND THAT IS THE POINT.

  The obvious implementation is Sprig's `merge`, which is a DEEP merge. It is
  wrong here for two separate reasons:

    1. `merge` MUTATES its first argument. Passing .Values.serviceDefaults
       directly means the first service through the range permanently poisons
       the defaults for the other five. (deepCopy fixes only this half.)

    2. Deep-merging securityContext is actively harmful. The gateway overrides
       securityContext to drop runAsNonRoot — its nginx master must start as
       root to chown /var/cache/nginx. A deep merge would helpfully re-add
       `runAsNonRoot: true` from the defaults and crashloop the pod, and the
       error message would point at the pod, not at this helper.

  So: top-level keys replace wholesale. `securityContext`, `resources`,
  `service` and `probes` are each all-or-nothing per service. Predictable beats
  clever when the failure mode is a crashlooping pod.

  Takes a dict: (dict "svc" $override "defaults" $.Values.serviceDefaults)
  Returns YAML — callers pipe through `fromYaml`.
--------------------------------------------------------------------------------
*/}}
{{- define "sports-store.svc" -}}
{{- $out := deepCopy .defaults -}}
{{- range $key, $value := .svc -}}
{{- $_ := set $out $key $value -}}
{{- end -}}
{{- $out | toYaml -}}
{{- end -}}


{{/*
--------------------------------------------------------------------------------
  sports-store.image — assemble <registry>/<repository>:<tag>.

  The `fail` is the point of this helper existing at all. "Image tags are
  <semver>-<7-char-git-hash>, never latest" is a project non-negotiable, and a
  rule that lives only in a README gets broken during a demo. Here it is a
  render-time error: the chart will not template, let alone install.

  It also catches the emptier failure — a values file that forgot to set a tag
  would otherwise render `repo:` and let Docker default to `latest` silently.

  Takes: (dict "svc" $svc "name" $name "registry" $.Values.imageRegistry)
--------------------------------------------------------------------------------
*/}}
{{- define "sports-store.image" -}}
{{- $tag := .svc.image.tag | toString -}}
{{- if or (empty $tag) (eq $tag "latest") -}}
{{- fail (printf "\n\nservices.%s.image.tag is %q.\nImage tags must be <semver>-<7-char-git-hash> (e.g. 1.2.0-a1b2c3d) — `latest` and empty are refused.\nSet it in values.yaml or in environments/<env>/images/%s.yaml.\n" .name (default "<empty>" $tag) .name) -}}
{{- end -}}
{{- with .registry }}{{ trimSuffix "/" . }}/{{ end }}{{ .svc.image.repository }}:{{ $tag }}
{{- end -}}


{{/*
--------------------------------------------------------------------------------
  sports-store.labels — the recommended app.kubernetes.io/* set.

  NOTE these are the *rich* labels, safe to change. They are NOT what the
  Deployment selector or the Service selector use — see sports-store.selectorLabels.

  Takes: (dict "ctx" $ "name" $name "component" $svc.component)
--------------------------------------------------------------------------------
*/}}
{{- define "sports-store.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .ctx.Chart.Name .ctx.Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/name: {{ .name }}
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
app.kubernetes.io/version: {{ .ctx.Chart.AppVersion | quote }}
app.kubernetes.io/component: {{ .component }}
app.kubernetes.io/part-of: sports-store
app.kubernetes.io/managed-by: {{ .ctx.Release.Service }}
{{- end -}}


{{/*
--------------------------------------------------------------------------------
  sports-store.selectorLabels — ONE short, stable key.

  A Deployment's spec.selector is IMMUTABLE after creation. Putting the full
  label set in it means that bumping the chart version changes
  helm.sh/chart, which changes the selector, which makes `helm upgrade` fail
  with "field is immutable" and requires deleting the Deployment to recover.

  `app: <name>` never changes. The rich labels above are free to.
--------------------------------------------------------------------------------
*/}}
{{- define "sports-store.selectorLabels" -}}
app: {{ .name }}
{{- end -}}


{{/*
--------------------------------------------------------------------------------
  sports-store.secretName / sports-store.mongoSecretName

  DELIBERATELY NOT release-prefixed, and identical whether the chart creates the
  Secrets or consumes existing ones.

  Two reasons a `{{ .Release.Name }}-app-secrets` style name is wrong here:

    1. mongodb.auth.existingSecret in values.yaml has to name the MongoDB Secret
       as a plain string. Subchart values cannot be templated, so a release-
       prefixed name would silently diverge from it the moment the release was
       called anything other than "sports-store" — and the failure mode is an
       auth error inside a subchart pod, a long way from the cause.

    2. apply-secrets.sh and the future External Secrets Operator both create
       these by fixed name. Consumers should not have to care which mechanism
       produced them.

  Trade, stated rather than discovered: with `create: true` in a namespace where
  apply-secrets.sh has already run, Helm will refuse to adopt the existing
  Secrets. Pick one mechanism per namespace — that is the intent, not a bug.
--------------------------------------------------------------------------------
*/}}
{{- define "sports-store.secretName" -}}
{{- required "secrets.appSecretName must be set" .Values.secrets.appSecretName -}}
{{- end -}}

{{- define "sports-store.mongoSecretName" -}}
{{- required "secrets.mongoSecretName must be set" .Values.secrets.mongoSecretName -}}
{{- end -}}


{{/*
--------------------------------------------------------------------------------
  sports-store.mongoUri — build the connection string ONCE.

  All five services currently get the same URI: the database name is hardcoded
  in each service's database.py (client["auth_db"], ...) rather than read from
  the URI. Generating it in one place is what stops the five copies drifting
  apart after a password change.

  authSource=admin because the root user lives in the admin database, not in the
  application databases.

  Only ever called when secrets.create is true.
--------------------------------------------------------------------------------
*/}}
{{- define "sports-store.mongoUri" -}}
{{- $u := required "secrets.mongodbRootUser is required when secrets.create is true" .Values.secrets.mongodbRootUser -}}
{{- $p := required "secrets.mongodbRootPassword is required when secrets.create is true — pass it with --set or a gitignored values file, never a committed one" .Values.secrets.mongodbRootPassword -}}
{{- printf "mongodb://%s:%s@mongodb:27017/?authSource=admin" $u $p -}}
{{- end -}}
