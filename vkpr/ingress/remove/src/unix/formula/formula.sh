#!/bin/sh

runFormula() {  
  echo "VKPR Ingress remove"
  $VKPR_HELM uninstall ingress -n $VKPR_K8S_NAMESPACE || echoColor "red" "VKPR Ingress not found"
}
