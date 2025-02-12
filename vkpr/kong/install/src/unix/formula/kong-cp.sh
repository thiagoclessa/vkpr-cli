#!/usr/bin/env bash

createKongSecrets() {
  # shellcheck source=src/util.sh
  source "$(dirname "$0")"/unix/formula/files.sh

  ## Create Kong tls secret to communicate between planes
  $VKPR_KUBECTL create secret tls kong-cluster-cert \
    --cert=$VKPR_HOME/certs/cluster.crt --key=$VKPR_HOME/certs/cluster.key $KONG_NAMESPACE && \
    $VKPR_KUBECTL label secret kong-cluster-cert app.kubernetes.io/instance=kong app.kubernetes.io/managed-by=vkpr $KONG_NAMESPACE 2> /dev/null

  ## Create Kong cookie config
  $VKPR_KUBECTL create secret generic kong-session-config \
    --from-file=/tmp/config/admin_gui_session_conf \
    --from-file=/tmp/config/portal_session_conf $KONG_NAMESPACE && \
  $VKPR_KUBECTL label secret kong-session-config app.kubernetes.io/instance=kong app.kubernetes.io/managed-by=vkpr $KONG_NAMESPACE 2> /dev/null

  ## Create Kong RBAC password
  $VKPR_KUBECTL create secret generic kong-enterprise-superuser-password \
    --from-literal="password=$VKPR_ENV_KONG_RBAC_ADMIN_PASSWORD" $KONG_NAMESPACE && \
    $VKPR_KUBECTL label secret kong-enterprise-superuser-password app.kubernetes.io/instance=kong app.kubernetes.io/managed-by=vkpr $KONG_NAMESPACE 2> /dev/null

  ## Check if exist postgresql password secret in Kong namespace, if not, create one
  if ! $VKPR_KUBECTL get secret $KONG_NAMESPACE | grep -q "$PG_SECRET"; then
    PG_PASSWORD=$($VKPR_KUBECTL get secret "$PG_SECRET" -o=jsonpath="{.data.postgres-password}" -n "$VKPR_ENV_POSTGRESQL_NAMESPACE" | base64 -d -)
    $VKPR_KUBECTL create secret generic "$PG_SECRET" \
      --from-literal="postgres-password=$PG_PASSWORD" $KONG_NAMESPACE && \
      $VKPR_KUBECTL label secret "$PG_SECRET" app.kubernetes.io/instance=kong app.kubernetes.io/managed-by=vkpr $KONG_NAMESPACE 2> /dev/null
  fi

  if [[ $VKPR_ENV_KONG_KEYCLOAK_OPENID == "true" ]]; then
    $VKPR_KUBECTL create secret generic kong-idp-config \
      --from-file="$(dirname "$0")"/utils/admin_gui_auth_conf $KONG_NAMESPACE && \
      $VKPR_KUBECTL label secret kong-idp-config app.kubernetes.io/instance=kong app.kubernetes.io/managed-by=vkpr $KONG_NAMESPACE 2> /dev/null
  fi
}

settingKong() {
  local PG_HOST="postgres-postgresql.${VKPR_ENV_POSTGRESQL_NAMESPACE}"
  local PG_SECRET="postgres-postgresql"

  if $VKPR_KUBECTL get pod -n "$VKPR_ENV_POSTGRESQL_NAMESPACE" | grep -q pgpool; then
    PG_HOST="postgres-postgresql-pgpool.${VKPR_ENV_POSTGRESQL_NAMESPACE}"
    PG_SECRET="postgres-postgresql-postgresql"
  fi

  YQ_VALUES=".podLabels.[\"app.kubernetes.io/managed-by\"] = \"vkpr\" |
    .env.pg_host = \"$PG_HOST\" |
    .env.pg_password.valueFrom.secretKeyRef.name = \"$PG_SECRET\" |
    .env.cluster_control_plane = \"$KONG_CP_URL\" |
    .env.cluster_telemetry_endpoint = \"$KONG_TELEMETRY_URL\"
  "

  if [[ "$VKPR_ENV_GLOBAL_DOMAIN" != "localhost" ]]; then
    YQ_VALUES="$YQ_VALUES |
      .admin.ingress.hostname = \"api.manager.$VKPR_ENV_GLOBAL_DOMAIN\" |
      .manager.ingress.hostname = \"manager.$VKPR_ENV_GLOBAL_DOMAIN\" |
      .portal.ingress.hostname = \"portal.$VKPR_ENV_GLOBAL_DOMAIN\" |
      .portalapi.ingress.hostname = \"api.portal.$VKPR_ENV_GLOBAL_DOMAIN\" |
      .env.admin_gui_url = \"https://manager.$VKPR_ENV_GLOBAL_DOMAIN\" |
      .env.admin_api_uri = \"https://api.manager.$VKPR_ENV_GLOBAL_DOMAIN\" |
      .env.portal_api_url = \"https://api.portal.$VKPR_ENV_GLOBAL_DOMAIN\" |
      .env.portal_gui_host = \"portal.$VKPR_ENV_GLOBAL_DOMAIN\"
    "
  fi

  if [[ "$VKPR_ENV_GLOBAL_SECURE" == true ]]; then
    info "Creating proxy certificate..."
    $VKPR_YQ eval ".spec.dnsNames[0] = \"$VKPR_ENV_GLOBAL_DOMAIN\"" "$(dirname "$0")"/utils/proxy-certificate.yaml |\
      $VKPR_KUBECTL apply -n $VKPR_ENV_KONG_NAMESPACE -f -
    YQ_VALUES="$YQ_VALUES |
      .env.portal_gui_protocol = \"https\" |
      .proxy.annotations.[\"external-dns.alpha.kubernetes.io/hostname\"] = \"$VKPR_ENV_GLOBAL_DOMAIN\" |
      .admin.ingress.annotations.[\"kubernetes.io/tls-acme\"] = \"true\" |
      .admin.ingress.annotations.[\"konghq.com/protocols\"] = \"https\" |
      .admin.ingress.tls = \"admin-kong-cert\" |
      .manager.ingress.annotations.[\"kubernetes.io/tls-acme\"] = \"true\" |
      .manager.ingress.annotations.[\"konghq.com/protocols\"] = \"https\" |
      .manager.ingress.tls = \"manager-kong-cert\" |
      .portal.ingress.annotations.[\"kubernetes.io/tls-acme\"] = \"true\" |
      .portal.ingress.annotations.[\"konghq.com/protocols\"] = \"https\" |
      .portal.ingress.tls = \"portal-kong-cert\" |
      .portalapi.ingress.annotations.[\"kubernetes.io/tls-acme\"] = \"true\" |
      .portalapi.ingress.annotations.[\"konghq.com/protocols\"] = \"https\" |
      .portalapi.ingress.tls = \"portalapi-kong-cert\"
    "
  fi

  if [[ "$VKPR_ENV_KONG_METRICS" == "true" ]] && [[ $(checkPodName "$VKPR_ENV_GRAFANA_NAMESPACE" "prometheus-stack-grafana") == "true" ]]; then
    createGrafanaDashboard "$(dirname "$0")/utils/dashboard.json" "$VKPR_ENV_GRAFANA_NAMESPACE"
    $VKPR_KUBECTL apply -f "$(dirname "$0")/utils/alerts.yaml" "$VKPR_ENV_GRAFANA_NAMESPACE"
    YQ_VALUES="$YQ_VALUES |
      .serviceMonitor.enabled = \"true\" |
      .serviceMonitor.namespace = \"$VKPR_ENV_KONG_NAMESPACE\" |
      .serviceMonitor.interval = \"30s\" |
      .serviceMonitor.scrapeTimeout = \"30s\" |
      .serviceMonitor.labels.release = \"prometheus-stack\" |
      .serviceMonitor.targetLabels[0] = \"prometheus-stack\"
    "
    if [[ "$VKPR_ENV_KONG_VITALS_STRATEGY" == "true" ]]; then
      YQ_VALUES="$YQ_VALUES |
        .env.vitals = \"on\" |
        .env.vitals_strategy = \"prometheus\" |
        .env.vitals_statsd_address = \"statsd-kong:9125\" |
        .env.vitals_tsdb_address = \"prometheus-stack-kube-prom-prometheus:9090\" |
        .env.vitals_statsd_prefix = \"kong-vitals\"
      "
      $VKPR_KUBECTL apply $KONG_NAMESPACE -f "$(dirname "$0")/utils/kong-service-monitor.yaml"
    fi
  fi

  if [[ "$VKPR_ENV_KONG_HA" == "true" ]]; then
    YQ_VALUES="$YQ_VALUES |
      .autoscaling.enabled = \"true\" |
      .autoscaling.minReplicas = \"3\" |
      .autoscaling.maxReplicas = \"5\" |
      .autoscaling.targetCPUUtilizationPercentage = \"80%\" |
      .topologySpreadConstraints[0].maxSkew = 1 |
      .topologySpreadConstraints[0].topologyKey = \"kubernetes.io/hostname\" |
      .topologySpreadConstraints[0].whenUnsatisfiable = \"DoNotSchedule\" |
      .topologySpreadConstraints[0].labelSelector.matchLabels.vkpr = \"true\" |
      .podDisruptionBudget.enabled = \"true\" |
      .podDisruptionBudget.maxUnavailable = \"60%\" |
      .ingressController.resources.limits.cpu = \"100m\" |
      .ingressController.resources.limits.memory = \"256Mi\" |
      .ingressController.resources.requests.cpu = \"50m\" |
      .ingressController.resources.requests.memory = \"128Mi\" |
      .resources.limits.cpu = \"512m\" |
      .resources.limits.memory = \"1G\" |
      .resources.requests.cpu = \"100m\" |
      .resources.requests.memory = \"128Mi\"
    "
  fi

  if [[ "$VKPR_ENV_KONG_KEYCLOAK_OPENID" == "true" ]]; then
    YQ_VALUES="$YQ_VALUES |
      enterprise.rbac.admin_gui_auth = \"openid-connect\" |
      enterprise.rbac.admin_gui_auth_conf_secret = \"kong-idp-config\"
    "
  fi

  settingKongProvider

  debug "YQ_CONTENT = $YQ_VALUES"
}

settingKongProvider(){
  if [[ "$VKPR_ENVIRONMENT" == "okteto" ]]; then
    OKTETO_NAMESPACE=$($VKPR_KUBECTL config get-contexts --no-headers | grep "\*" | xargs | awk -F " " '{print $NF}')
    HELM_ARGS="--skip-crds"
    YQ_VALUES="$YQ_VALUES |
        del(.portal.ingress) |
        del(.admin.ingress) |
        del(.portalapi.ingress) |
        del(.manager.ingress) |
        del(.ingressController) |
        .ingressController.enabled = false |
        .ingressController.installCRDs = false |
        .admin.ingress.enabled = false |
        .manager.ingress.enabled = false |
        .portal.ingress.enabled = false |
        .portalapi.ingress.enabled = false |
        .admin.annotations.[\"dev.okteto.com/auto-ingress\"] = \"true\" |
        .manager.annotations.[\"dev.okteto.com/auto-ingress\"] = \"true\" |
        .portal.annotations.[\"dev.okteto.com/auto-ingress\"] = \"true\" |
        .portalapi.annotations.[\"dev.okteto.com/auto-ingress\"] = \"true\" |
        .env.admin_gui_url = \"https://kong-kong-manager-$OKTETO_NAMESPACE.cloud.okteto.net\" |
        .env.admin_api_uri = \"https://kong-kong-admin-$OKTETO_NAMESPACE.cloud.okteto.net\" |
        .env.portal_gui_host = \"kong-kong-portal-$OKTETO_NAMESPACE.cloud.okteto.net\" |
        .env.portal_api_url = \"https://kong-kong-portalapi-$OKTETO_NAMESPACE.cloud.okteto.net\" |
        .env.portal_gui_protocol = \"https\" |
        .env.pg_host = \"postgres-postgresql\" |
        .env.pg_password.valueFrom.secretKeyRef.key = \"postgres-password\"
      "
  fi
}

if [[ $DRY_RUN == false ]]; then
  installDB
  createKongSecrets
fi
settingKong
